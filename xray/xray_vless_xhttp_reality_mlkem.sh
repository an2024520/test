#!/bin/bash

# ============================================================
#  模块四：VLESS + XHTTP + Reality + ENC (VLESS内层加密版)
#  - 协议: VLESS (开启 vlessenc 加密/填充)
#  - 传输: XHTTP (HTTP/3)
#  - 伪装: Reality
#  - 核心要求: Xray-core v25.x+
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 核心路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray_core/xray"

echo -e "${GREEN}>>> [模块四] 部署 VLESS-ENC (内层加密) + XHTTP + Reality ...${PLAIN}"

# 1. 环境与核心版本检查
if [[ ! -f "$XRAY_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Xray 核心！请先运行 [模块一]。${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}安装依赖 (jq, openssl)...${PLAIN}"
    apt update -y && apt install -y jq openssl
fi

# 检查 vlessenc 命令支持 (Xray v25+ 特性)
if "$XRAY_BIN" help | grep -q "vlessenc"; then
    echo -e "${GREEN}>>> 检测到 Xray 核心支持 VLESS Encryption (ENC)！${PLAIN}"
else
    echo -e "${RED}致命错误: 当前 Xray 核心不支持 vlessenc 命令。${PLAIN}"
    echo -e "${RED}请升级到 Xray-core v25.9+ 版本。${PLAIN}"
    exit 1
fi

# 2. 配置文件初始化
if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat <<EOF > "$CONFIG_FILE"
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "blocked", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      { "type": "field", "outboundTag": "blocked", "ip": ["geoip:private"] }
    ]
  }
}
EOF
fi

# 3. 用户配置 (自动/手动)
if [[ "$AUTO_SETUP" == "true" ]]; then
    PORT="${PORT:-2088}" 
    echo -e "    端口 (PORT): ${GREEN}${PORT}${PLAIN}"
    SNI="www.microsoft.com"
else
    echo -e "${YELLOW}--- 配置参数 ---${PLAIN}"
    while true; do
        read -p "请输入监听端口 (默认 2088): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=2088 && break
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            PORT="$CUSTOM_PORT"
            break
        else
            echo -e "${RED}无效端口。${PLAIN}"
        fi
    done

    echo -e "${YELLOW}请选择伪装域名 (SNI):${PLAIN}"
    echo -e "  1. www.microsoft.com (推荐)"
    echo -e "  2. www.cloudflare.com"
    read -p "选择: " s
    case $s in
        2) SNI="www.cloudflare.com" ;;
        *) SNI="www.microsoft.com" ;;
    esac
fi

# 4. 生成密钥 (抗噪修正版)
echo -e "${YELLOW}正在生成密钥...${PLAIN}"

UUID=$($XRAY_BIN uuid)
SHORT_ID=$(openssl rand -hex 4)
XHTTP_PATH="/$(openssl rand -hex 6)"

# [Reality] 标准 X25519
RAW_REALITY=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$RAW_REALITY" | grep "Private" | awk -F ": " '{print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$RAW_REALITY" | grep "Public" | awk -F ": " '{print $2}' | tr -d ' \r\n')

# [VLESS ENC] 使用 grep/awk 提取，避免 logs 干扰 jq
# vlessenc 输出示例可能包含日志，但 JSON 部分为: "decryption": "...",
RAW_ENC=$($XRAY_BIN vlessenc)

# 提取 decryption (用于服务端) - 查找包含 decryption 的行，提取冒号后的内容，去引号
SERVER_DECRYPTION=$(echo "$RAW_ENC" | grep '"decryption":' | head -n1 | awk -F '"' '{print $4}')

# 提取 encryption (用于客户端)
CLIENT_ENCRYPTION=$(echo "$RAW_ENC" | grep '"encryption":' | head -n1 | awk -F '"' '{print $4}')

if [[ -z "$SERVER_DECRYPTION" ]] || [[ -z "$CLIENT_ENCRYPTION" ]]; then
    echo -e "${RED}错误: 无法生成 VLESS ENC 密钥！${PLAIN}"
    echo -e "${RED}调试信息 - 原始输出:${PLAIN}"
    echo "$RAW_ENC"
    exit 1
fi

echo -e "VLESS Enc Key : ${SKYBLUE}${SERVER_DECRYPTION:0:10}...${PLAIN}"
echo -e "Reality Key   : ${SKYBLUE}X25519${PLAIN}"

# 5. 注入节点配置
NODE_TAG="Xray-XHTTP-ENC-${PORT}"

# 清理旧配置
tmp_clean=$(mktemp)
jq --argjson p "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[]? | select(.port == $p or .tag == $tag))' \
   "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"

# 构建节点 JSON
# 注意: settings.decryption 填入 SERVER_DECRYPTION
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg path "$XHTTP_PATH" \
    --arg sni "$SNI" \
    --arg pk "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" \
    --arg deckey "$SERVER_DECRYPTION" \
    '{
      tag: $tag,
      listen: "0.0.0.0",
      port: ($port | tonumber),
      protocol: "vless",
      settings: {
        clients: [{id: $uuid, flow: ""}],
        decryption: $deckey
      },
      streamSettings: {
        network: "xhttp",
        xhttpSettings: {
            path: $path,
            host: $sni
        },
        security: "reality",
        realitySettings: {
          show: false,
          dest: ($sni + ":443"),
          serverNames: [$sni],
          privateKey: $pk,
          shortIds: [$sid]
        }
      },
      sniffing: { enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true }
    }')

tmp_add=$(mktemp)
jq --argjson new_node "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp_add" && mv "$tmp_add" "$CONFIG_FILE"

# 6. 重启与输出
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    PUBLIC_IP=$(curl -s4 ifconfig.me)
    # 分享链接中 encryption 参数填入 CLIENT_ENCRYPTION
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=${CLIENT_ENCRYPTION}&pbk=${PUBLIC_KEY}&headerType=none&type=xhttp&sni=${SNI}&sid=${SHORT_ID}&path=${XHTTP_PATH}&fp=chrome#${NODE_TAG}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [ENC] VLESS加密版 部署成功！        ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "核心协议    : ${SKYBLUE}VLESS (ENC Enabled)${PLAIN}"
    echo -e "传输协议    : ${SKYBLUE}XHTTP + Reality${PLAIN}"
    echo -e "监听端口    : ${YELLOW}${PORT}${PLAIN}"
    echo -e "SNI         : ${YELLOW}${SNI}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [通用分享链接] (需 Xray v25+ 客户端):"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    # OpenClash / Meta 格式输出
    echo -e "🐱 [Mihomo / Meta YAML配置]:"
    echo -e "${YELLOW}"
    cat <<EOF
- name: "${NODE_TAG}"
  type: vless
  server: ${PUBLIC_IP}
  port: ${PORT}
  uuid: ${UUID}
  network: xhttp
  tls: true
  udp: true
  flow: ""
  servername: ${SNI}
  client-fingerprint: chrome
  # 注意: 目前 Mihomo 可能尚未完全支持 VLESS ENC 参数，请以客户端实际支持为准
  xhttp-opts:
    path: ${XHTTP_PATH}
    headers:
      Host: ${SNI}
  reality-opts:
    public-key: ${PUBLIC_KEY}
    short-id: ${SHORT_ID}
EOF
    echo -e "${PLAIN}----------------------------------------"
    
    if [[ "$AUTO_SETUP" == "true" ]]; then
        echo "Tag: ${NODE_TAG} (ENC) | ${SHARE_LINK}" >> "/root/xray_nodes.txt"
    fi
else
    echo -e "${RED}启动失败！请检查日志 (journalctl -u xray -e) ${PLAIN}"
    [[ "$AUTO_SETUP" == "true" ]] && exit 1
fi
