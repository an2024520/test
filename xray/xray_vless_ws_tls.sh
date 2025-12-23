#!/bin/bash

# ============================================================
#  模块八：VLESS + WS + TLS (CDN) (v1.1 Auto)
#  - 升级: 自动生成自签证书 (无需手动上传文件)
#  - 适配: auto_deploy.sh 自动化调用
#  - 修复: Tag + Port 双重清理
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray_core/xray"
CERT_DIR="/usr/local/etc/xray/certs"

echo -e "${GREEN}>>> [Xray] 智能添加节点: VLESS + WS + TLS (CDN) ...${PLAIN}"

# 1. 环境准备
if [[ ! -f "$XRAY_BIN" ]]; then echo -e "${RED}错误: 未找到 Xray 核心！${PLAIN}"; exit 1; fi
if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then apt update -y && apt install -y jq openssl; fi

mkdir -p "$(dirname "$CONFIG_FILE")"
mkdir -p "$CERT_DIR"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"blocked","protocol":"blackhole"}],"routing":{"rules":[]}}' > "$CONFIG_FILE"
fi

# 2. 参数获取
if [[ "$AUTO_SETUP" == "true" ]]; then
    echo -e "${GREEN}>>> [自动模式] 读取参数...${PLAIN}"
    PORT=${XRAY_WS_TLS_PORT:-8443}
    DOMAIN=${XRAY_WS_TLS_DOMAIN}
    WS_PATH=${XRAY_WS_TLS_PATH:-"/ws"}
    
    if [[ -z "$DOMAIN" ]]; then echo -e "${RED}错误: 必须提供域名!${PLAIN}"; exit 1; fi
else
    echo -e "${YELLOW}--- 配置 Xray CDN 节点 ---${PLAIN}"
    while true; do
        read -p "请输入监听端口 (默认 8443): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=8443 && break
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            PORT="$CUSTOM_PORT"
            break
        else echo -e "${RED}无效端口。${PLAIN}"; fi
    done

    read -p "请输入域名 (例如: vps.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && exit 1
    
    read -p "请输入 WS 路径 (默认 /ws): " CUSTOM_PATH
    WS_PATH=${CUSTOM_PATH:-"/ws"}
fi

if [[ "${WS_PATH:0:1}" != "/" ]]; then WS_PATH="/$WS_PATH"; fi

# 3. 证书生成 (自动自签)
echo -e "${YELLOW}自动生成自签证书 (适配 CF Full Mode)...${PLAIN}"
CERT_FILE="${CERT_DIR}/${DOMAIN}_${PORT}.crt"
KEY_FILE="${CERT_DIR}/${DOMAIN}_${PORT}.key"

openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -days 3650 -subj "/CN=$DOMAIN" >/dev/null 2>&1

if [[ ! -f "$CERT_FILE" ]]; then echo -e "${RED}证书生成失败！${PLAIN}"; exit 1; fi

# 4. 核心执行
UUID=$($XRAY_BIN uuid)
NODE_TAG="Xray-WS-TLS-${PORT}"

# [修复] Tag + Port 双重清理
tmp0=$(mktemp)
jq --argjson p "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[]? | select(.port == $p or .tag == $tag))' \
   "$CONFIG_FILE" > "$tmp0" && mv "$tmp0" "$CONFIG_FILE"

NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg sni "$DOMAIN" \
    --arg path "$WS_PATH" \
    --arg cert "$CERT_FILE" \
    --arg key "$KEY_FILE" \
    '{
      tag: $tag,
      listen: "0.0.0.0",
      port: ($port | tonumber),
      protocol: "vless",
      settings: {
        clients: [{id: $uuid, flow: ""}],
        decryption: "none"
      },
      streamSettings: {
        network: "ws",
        security: "tls",
        tlsSettings: {
          serverName: $sni,
          certificates: [{ certificateFile: $cert, keyFile: $key }]
        },
        wsSettings: { path: $path }
      },
      sniffing: { enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true }
    }')

tmp=$(mktemp)
jq --argjson new "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 5. 重启与输出
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    PUBLIC_IP=$(curl -s4 ifconfig.me)
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=tls&encryption=none&type=ws&path=${WS_PATH}&sni=${DOMAIN}&fp=chrome#${NODE_TAG}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [Xray] WS+TLS (CDN) 部署成功！      ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "绑定域名    : ${YELLOW}${DOMAIN}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"

    if [[ "$AUTO_SETUP" == "true" ]]; then
        LOG_FILE="/root/xray_nodes.txt"
        echo "Tag: ${NODE_TAG} | ${SHARE_LINK}" >> "$LOG_FILE"
        echo -e "${SKYBLUE}>>> [自动记录] 已追加至: ${LOG_FILE}${PLAIN}"
    fi
else
    echo -e "${RED}启动失败！journalctl -u xray -e${PLAIN}"
    [[ "$AUTO_SETUP" == "true" ]] && exit 1
fi
