#!/bin/bash

# ============================================================
#  Sing-box 节点新增: VLESS + WS + TLS (CDN)
#  - 核心: 自动识别路径 + 写入 Inbounds
#  - 特性: 自动生成自签名证书 (适配 Cloudflare Full 模式)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: VLESS + WS + TLS (CDN) ...${PLAIN}"

# 1. 智能路径查找
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")
for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done
if [[ -z "$CONFIG_FILE" ]]; then CONFIG_FILE="/usr/local/etc/sing-box/config.json"; fi

CONFIG_DIR=$(dirname "$CONFIG_FILE")
# 证书目录随配置文件目录变动
CERT_DIR="${CONFIG_DIR}/certs" 
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")

echo -e "${GREEN}>>> 锁定配置文件: ${CONFIG_FILE}${PLAIN}"

# 2. 依赖检查
if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    if [ -f /etc/debian_version ]; then apt update -y && apt install -y jq openssl; fi
fi

# 3. 参数配置
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

read -p "请输入 WebSocket 路径 (默认 /ws): " WS_PATH
[[ -z "$WS_PATH" ]] && WS_PATH="/ws"
if [[ "${WS_PATH:0:1}" != "/" ]]; then WS_PATH="/$WS_PATH"; fi

# 4. 生成证书
echo -e "${YELLOW}生成自签名证书...${PLAIN}"
mkdir -p "$CERT_DIR"
CERT_FILE="${CERT_DIR}/${DOMAIN}_${PORT}.crt"
KEY_FILE="${CERT_DIR}/${DOMAIN}_${PORT}.key"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 -subj "/CN=$DOMAIN" >/dev/null 2>&1

# 5. 生成 UUID
UUID=$($SB_BIN generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)

# 6. 写入配置
NODE_TAG="WS-TLS-${PORT}"

# A. 初始化/清理
if [[ ! -f "$CONFIG_FILE" ]]; then mkdir -p "$CONFIG_DIR"; echo '{"inbounds":[],"outbounds":[]}' > "$CONFIG_FILE"; fi
tmp_clean=$(mktemp)
jq --argjson port "$PORT" 'del(.inbounds[]? | select(.listen_port == $port))' "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"

# B. 构造 Inbound JSON
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

# C. 写入
tmp_add=$(mktemp)
jq --argjson new "$NODE_JSON" 'if .inbounds == null then .inbounds = [] else . end | .inbounds += [$new]' "$CONFIG_FILE" > "$tmp_add" && mv "$tmp_add" "$CONFIG_FILE"

# 7. 重启
systemctl restart sing-box
sleep 1
if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}配置写入成功！${PLAIN} Tag: ${NODE_TAG}"
    echo -e "${YELLOW}可以使用菜单 [5. 查看节点] 获取链接。${PLAIN}"
else
    echo -e "${RED}启动失败。${PLAIN}"
fi
