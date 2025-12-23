#!/bin/bash

# ============================================================
#  Sing-box 节点新增: VLESS + WS + TLS (CDN) (v1.3 Auto)
#  - 核心: 自动生成自签证书 (适配 Cloudflare Full 模式)
#  - 升级: 支持 auto_deploy.sh 自动化调用
#  - 修复: Tag + Port 双重清理
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: VLESS + WS + TLS (CDN) ...${PLAIN}"

# --- 1. 环境准备 ---
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")
for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done
[[ -z "$CONFIG_FILE" ]] && CONFIG_FILE="/usr/local/etc/sing-box/config.json"

CONFIG_DIR=$(dirname "$CONFIG_FILE")
CERT_DIR="${CONFIG_DIR}/certs"
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")

echo -e "${GREEN}>>> 锁定配置文件: ${CONFIG_FILE}${PLAIN}"

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    apt update -y && apt install -y jq openssl
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$CONFIG_DIR"
    echo '{"inbounds":[],"outbounds":[]}' > "$CONFIG_FILE"
fi

# --- 2. 参数获取 ---
if [[ "$AUTO_SETUP" == "true" ]]; then
    echo -e "${GREEN}>>> [自动模式] 读取参数...${PLAIN}"
    PORT=${SB_WS_TLS_PORT:-8443}
    DOMAIN=${SB_WS_TLS_DOMAIN}
    WS_PATH=${SB_WS_TLS_PATH:-"/ws"}
    
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}错误: 自动模式下必须提供域名 (SB_WS_TLS_DOMAIN)!${PLAIN}"
        exit 1
    fi
else
    echo -e "${YELLOW}--- 配置 VLESS-WS-TLS (CDN) ---${PLAIN}"
    while true; do
        read -p "请输入监听端口 (默认 8443): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=8443 && break
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            PORT="$CUSTOM_PORT"
            break
        else
            echo -e "${RED}无效端口。${PLAIN}"
        fi
    done

    read -p "请输入域名 (例如: vps.example.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then echo -e "${RED}错误: 必须输入域名!${PLAIN}"; exit 1; fi

    read -p "请输入 WebSocket 路径 (默认 /ws): " CUSTOM_PATH
    WS_PATH=${CUSTOM_PATH:-"/ws"}
fi

# 格式化路径
if [[ "${WS_PATH:0:1}" != "/" ]]; then WS_PATH="/$WS_PATH"; fi

# --- 3. 证书生成 (Auto Self-Signed) ---
echo -e "${YELLOW}正在生成自签名证书 (适配 CF Full 模式)...${PLAIN}"
mkdir -p "$CERT_DIR"
CERT_FILE="${CERT_DIR}/${DOMAIN}_${PORT}.crt"
KEY_FILE="${CERT_DIR}/${DOMAIN}_${PORT}.key"

# 使用 EC 密钥，更高效
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -days 3650 -subj "/CN=$DOMAIN" >/dev/null 2>&1

if [[ ! -f "$CERT_FILE" ]]; then
    echo -e "${RED}证书生成失败！${PLAIN}"; exit 1
fi

# --- 4. 核心执行 ---
UUID=$($SB_BIN generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
NODE_TAG="WS-TLS-${PORT}"

# [PRO 修复] Tag + Port 双重清理
tmp0=$(mktemp)
jq --argjson p "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[]? | select(.listen_port == $p or .tag == $tag))' \
   "$CONFIG_FILE" > "$tmp0" && mv "$tmp0" "$CONFIG_FILE"

# 构建 JSON
# 注意: TLS 需要监听 :: 或 0.0.0.0 以供 CDN 访问
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg path "$WS_PATH" \
    --arg cert "$CERT_FILE" \
    --arg key "$KEY_FILE" \
    '{
        "type": "vless",
        "tag": $tag,
        "listen": "::",
        "listen_port": ($port | tonumber),
        "users": [{ "uuid": $uuid }],
        "transport": { "type": "ws", "path": $path },
        "tls": {
            "enabled": true,
            "certificate_path": $cert,
            "key_path": $key
        }
    }')

tmp=$(mktemp)
jq --argjson new "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# --- 5. 重启与输出 ---
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    PUBLIC_IP=$(curl -s4m5 https://api.ip.sb/ip || curl -s4 ifconfig.me)
    # 链接中 security=tls
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=tls&encryption=none&type=ws&path=${WS_PATH}&sni=${DOMAIN}&fp=chrome#${NODE_TAG}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}  [Sing-box] WS+TLS (CDN) 部署成功！    ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "监听端口    : ${YELLOW}${PORT}${PLAIN}"
    echo -e "绑定域名    : ${YELLOW}${DOMAIN}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "${GRAY}* 提示: 请确保 Cloudflare SSL 设置为 'Full' 或 'Full (Strict)'${PLAIN}"

    if [[ "$AUTO_SETUP" == "true" ]]; then
        LOG_FILE="/root/sb_nodes.txt"
        echo "Tag: ${NODE_TAG} | ${SHARE_LINK}" >> "$LOG_FILE"
        echo -e "${SKYBLUE}>>> [自动记录] 已追加至: ${LOG_FILE}${PLAIN}"
    fi
else
    echo -e "${RED}启动失败。${PLAIN}"
    [[ "$AUTO_SETUP" == "true" ]] && exit 1
fi
