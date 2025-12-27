#!/bin/bash
# ============================================================
#  模块四：VLESS + XHTTP + Reality + ENC (抗量子加密版)
#  - 协议: VLESS (vlessEncryption = ML-KEM-768)
#  - 传输: XHTTP (HTTP/3)
#  - 伪装: Reality
#  - 核心要求: Xray-core v25.12.8+
#  - 特性: 移植 Vision 脚本的"强制覆盖"逻辑
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

echo -e "${GREEN}>>> [模块四] 部署 VLESS-ENC (ML-KEM-768) + XHTTP + Reality ...${PLAIN}"

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
if ! "$XRAY_BIN" help | grep -q "vlessenc"; then
    echo -e "${RED}致命错误: 当前 Xray 核心版本过低，不支持抗量子加密 (vlessenc)。${PLAIN}"
    echo -e "${RED}请先更新 Xray-core 至 v25.12.8+。${PLAIN}"
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
    # === 自动模式 ===
    PORT="${PORT:-2088}"
    echo -e "    端口 (PORT): ${GREEN}${PORT}${PLAIN}"
    # 自动模式默认使用微软
    SNI="www.microsoft.com"
else
    # === 手动模式 (移植 Vision 覆盖逻辑) ===
    echo -e "${YELLOW}--- 配置 VLESS-ENC 参数 ---${PLAIN}"
    while true; do
        read -p "请输入监听端口 (默认 2088): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=2088 && break
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            # 检查端口占用，但允许覆盖
            if grep -q "\"port\": $CUSTOM_PORT" "$CONFIG_FILE"; then
                 echo -e "${RED}警告: 端口 $CUSTOM_PORT 似乎已被旧配置占用。${PLAIN}"
                 echo -e "${GREEN}>>> 将执行覆盖安装模式 (Overwrite Mode)。${PLAIN}"
                 PORT="$CUSTOM_PORT"
                 break
            else
                 PORT="$CUSTOM_PORT"
                 break
            fi
        else
            echo -e "${RED}无效端口。${PLAIN}"
        fi
    done

    echo -e "${YELLOW}请选择伪装域名 (SNI):${PLAIN}"
    echo -e "  1. www.microsoft.com (推荐 - Azure CDN)"
    echo -e "  2. www.apple.com"
    echo -e "  3. 手动输入"
    read -p "选择 [1-3]: " s
    case $s in
        2) SNI="www.apple.com" ;;
        3) read -p "请输入域名: " SNI ;;
        *) SNI="www.microsoft.com" ;;
    esac
fi

# 4. 生成密钥 (严谨模式)
echo -e "${YELLOW}正在生成密钥...${PLAIN}"

UUID=$($XRAY_BIN uuid)
SHORT_ID=$(openssl rand -hex 4)
XHTTP_PATH="/$(openssl rand -hex 6)"

# [Reality] 标准 X25519
RAW_REALITY=$($XRAY_BIN x25519)
# 修正: 使用 tr -d ' \r\n' 强制清洗换行和空格，防止空变量
PRIVATE_KEY=$(echo "$RAW_REALITY" | grep "Private" | awk -F ":" '{print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$RAW_REALITY" | grep -E "Password|Public" | awk -F ":" '{print $2}' | tr -d ' \r\n')

# [VLESS ENC] ML-KEM-768 提取逻辑
RAW_ENC=$($XRAY_BIN vlessenc)
# 修正: 使用 awk -F '"' 提取 JSON 字段值，更精准
SERVER_DECRYPTION=$(echo "$RAW_ENC" | grep '"decryption":' | head -n1 | awk -F '"' '{print $4}')
CLIENT_ENCRYPTION=$(echo "$RAW_ENC" | grep '"encryption":' | head -n1 | awk -F '"' '{print $4}')

# [关键熔断检查]
if [[ -z "$PRIVATE_KEY" ]]; then
    echo -e "${RED}错误: Reality 私钥提取失败！${PLAIN}"
    echo -e "调试信息: $RAW_REALITY"
    exit 1
fi

if [[ -z "$SERVER_DECRYPTION" ]]; then
    echo -e "${RED}错误: ENC (ML-KEM) 密钥提取失败！${PLAIN}"
    echo -e "调试信息: $RAW_ENC"
    exit 1
fi

echo -e "Reality Key   : ${SKYBLUE}OK${PLAIN}"
echo -e "VLESS Enc Key : ${SKYBLUE}ML-KEM-768 (OK)${PLAIN}"

# 5. 注入节点配置
NODE_TAG="Xray-MLKEM-${PORT}"

# ==========================================================
# [自动清洗] 无论端口是否冲突，先删除旧的同 Tag 或同端口配置
# ==========================================================
tmp_clean=$(mktemp)
jq --argjson p "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[]? | select(.port == $p or .tag == $tag))' \
   "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"

# 构建 JSON (settings.decryption)
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
      listen: "::",
      port: ($port | tonumber),
      protocol: "vless",
      settings: {
        clients: [{id: $uuid, flow: ""}],
        decryption: $deckey
      },
      streamSettings: {
        network: "xhttp",
        security: "reality",
        xhttpSettings: {
            mode: "auto",
            path: $path,
            host: $sni
        },
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
    # 分享链接: encryption=CLIENT_KEY
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=${CLIENT_ENCRYPTION}&pbk=${PUBLIC_KEY}&headerType=none&type=xhttp&sni=${SNI}&sid=${SHORT_ID}&path=${XHTTP_PATH}&mode=auto&fp=chrome#${NODE_TAG}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [ENC] VLESS 抗量子节点部署成功！     ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "加密模式    : ${SKYBLUE}ML-KEM-768 (Post-Quantum)${PLAIN}"
    echo -e "传输协议    : ${SKYBLUE}XHTTP + Reality${PLAIN}"
    echo -e "监听端口    : ${YELLOW}${PORT}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [分享链接] (需 Xray v25+ / v2rayNG v1.9.12+):"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    # Meta 格式
    echo -e "🐱 [Mihomo / Meta 配置块]:"
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
  # client-fingerprint: chrome
  # 注意: 目前 Meta 内核对 VLESS ENC 支持尚在实验阶段
  xhttp-opts:
    mode: auto
    path: ${XHTTP_PATH}
    headers:
      Host: ${SNI}
  reality-opts:
    public-key: ${PUBLIC_KEY}
    short-id: ${SHORT_ID}
EOF
    echo -e "${PLAIN}----------------------------------------"
else
    echo -e "${RED}启动失败！请检查日志: journalctl -u xray -e${PLAIN}"
    [[ "$AUTO_SETUP" == "true" ]] && exit 1
fi
