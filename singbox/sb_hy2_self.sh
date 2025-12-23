#!/bin/bash

# ============================================================
#  Sing-box 节点新增: Hysteria 2 + Self-Signed (v1.1 Auto)
#  - 协议: Hysteria 2 (UDP) + 自签证书 (bing.com)
#  - 升级: 支持 auto_deploy.sh 自动化调用
#  - 修复: Tag + Port 双重清理
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: Hysteria 2 (自签证书版) ...${PLAIN}"

# --- 1. 环境准备 ---
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")
for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done
[[ -z "$CONFIG_FILE" ]] && CONFIG_FILE="/usr/local/etc/sing-box/config.json"

CONFIG_DIR=$(dirname "$CONFIG_FILE")
META_FILE="${CONFIG_FILE}.meta"
CERT_DIR="${CONFIG_DIR}/cert"
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")

echo -e "${GREEN}>>> 锁定配置文件: ${CONFIG_FILE}${PLAIN}"

if [[ ! -f "$SB_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Sing-box 核心！${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    apt update -y && apt install -y jq openssl
fi

# 初始化
if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$CONFIG_DIR"
    echo '{"log":{"level":"info","timestamp":false},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],"route":{"rules":[]}}' > "$CONFIG_FILE"
fi
mkdir -p "$CERT_DIR"

# --- 2. 参数获取 (自动/手动分流) ---
if [[ "$AUTO_SETUP" == "true" ]]; then
    # >>> 自动模式 >>>
    echo -e "${GREEN}>>> [自动模式] 读取参数...${PLAIN}"
    PORT=${PORT:-10086} # Hy2 默认端口
    echo -e "端口: ${GREEN}$PORT${PLAIN}"
else
    # >>> 手动模式 >>>
    echo -e "${YELLOW}--- 配置 Hysteria 2 参数 ---${PLAIN}"
    while true; do
        read -p "请输入 UDP 监听端口 (默认 10086): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=10086 && break
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            PORT="$CUSTOM_PORT"
            break
        else
            echo -e "${RED}无效端口。${PLAIN}"
        fi
    done
fi

# 密码生成 (自动/手动共用)
# 使用 Hex 生成，避免特殊字符导致的客户端兼容性问题
PASSWORD=$(openssl rand -hex 16)
OBFS_PASS=$(openssl rand -hex 8)
echo -e "${YELLOW}已自动生成高强度认证信息。${PLAIN}"

# --- 3. 证书生成 ---
echo -e "${YELLOW}正在生成自签证书 (CN=bing.com)...${PLAIN}"
# 为每个端口生成独立的证书，防止冲突
openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
    -keyout "$CERT_DIR/self_${PORT}.key" \
    -out "$CERT_DIR/self_${PORT}.crt" \
    -days 36500 -subj "/CN=bing.com" 2>/dev/null

if [[ ! -f "$CERT_DIR/self_${PORT}.crt" ]]; then
    echo -e "${RED}错误: 证书生成失败！${PLAIN}"
    exit 1
fi
CERT_PATH="$CERT_DIR/self_${PORT}.crt"
KEY_PATH="$CERT_DIR/self_${PORT}.key"

# --- 4. 核心执行 ---
NODE_TAG="Hy2-Self-${PORT}"

# [修复] 双重清理：同端口 OR 同Tag
tmp0=$(mktemp)
jq --argjson port "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[]? | select(.listen_port == $port or .tag == $tag))' \
   "$CONFIG_FILE" > "$tmp0" && mv "$tmp0" "$CONFIG_FILE"

# 构建 JSON (Hysteria 2)
# Hy2 是 UDP 直连协议，必须监听 "::" 或 "0.0.0.0"
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg pass "$PASSWORD" \
    --arg obfs "$OBFS_PASS" \
    --arg cert "$CERT_PATH" \
    --arg key "$KEY_PATH" \
    '{
        "type": "hysteria2",
        "tag": $tag,
        "listen": "::",
        "listen_port": ($port | tonumber),
        "users": [{ "password": $pass }],
        "obfs": {
            "type": "salamander",
            "password": $obfs
        },
        "tls": {
            "enabled": true,
            "certificate_path": $cert,
            "key_path": $key
        }
    }')

tmp=$(mktemp)
jq --argjson new_node "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 存根 Meta
if [[ ! -f "$META_FILE" ]]; then echo "{}" > "$META_FILE"; fi
tmp_meta=$(mktemp)
jq --arg tag "$NODE_TAG" --arg pass "$PASSWORD" --arg obfs "$OBFS_PASS" \
   '. + {($tag): {"type": "hy2-self", "pass": $pass, "obfs": $obfs}}' "$META_FILE" > "$tmp_meta" && mv "$tmp_meta" "$META_FILE"

# --- 5. 重启与输出 ---
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    PUBLIC_IP=$(curl -s4m5 https://api.ip.sb/ip || curl -s4 ifconfig.me)
    NODE_NAME="$NODE_TAG"
    
    # 构造链接
    SHARE_LINK="hysteria2://${PASSWORD}@${PUBLIC_IP}:${PORT}?insecure=1&obfs=salamander&obfs-password=${OBFS_PASS}&sni=bing.com#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}   [Sing-box] Hy2 (自签) 节点部署成功   ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "端口 (UDP)  : ${YELLOW}${PORT}${PLAIN}"
    echo -e "认证密码    : ${YELLOW}${PASSWORD}${PLAIN}"
    echo -e "混淆密码    : ${YELLOW}${OBFS_PASS}${PLAIN}"
    echo -e "跳过验证    : ${RED}是 (Allow Insecure)${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    # 自动模式日志记录
    if [[ "$AUTO_SETUP" == "true" ]]; then
        LOG_FILE="/root/sb_nodes.txt"
        echo "Tag: ${NODE_TAG} | ${SHARE_LINK}" >> "$LOG_FILE"
        echo -e "${SKYBLUE}>>> [自动记录] 节点信息已追加至: ${LOG_FILE}${PLAIN}"
    fi
else
    echo -e "${RED}启动失败！请检查日志: journalctl -u sing-box -e${PLAIN}"
    [[ "$AUTO_SETUP" == "true" ]] && exit 1
fi
