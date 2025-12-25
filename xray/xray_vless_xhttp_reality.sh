#!/bin/bash

# ============================================================
#  模块二：VLESS + XHTTP + Reality (v1.2 Refactor)
#  - 协议: XHTTP (Xray 新一代传输协议 / HTTP/3 内核)
#  - 升级: 增加 OpenClash/Meta YAML 输出
#  - 修复: 优化配置文件初始化与双重清理逻辑 (Fix-Crash)
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

echo -e "${GREEN}>>> [模块二] 智能添加节点: VLESS + XHTTP + Reality ...${PLAIN}"

# --- 1. 环境准备 ---
if [[ ! -f "$XRAY_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Xray 核心！请先运行 [模块一]。${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}检测到缺少必要工具，正在安装 (jq, openssl)...${PLAIN}"
    apt update -y && apt install -y jq openssl
fi

# --- 2. 配置文件初始化 (修复日志路径) ---
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}配置文件不存在，正在初始化标准骨架...${PLAIN}"
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
    echo -e "${GREEN}标准骨架初始化完成。${PLAIN}"
fi

# --- 3. 参数获取 (自动/手动) ---
if [[ "$AUTO_SETUP" == "true" ]]; then
    echo -e "${GREEN}>>> [自动模式] 读取参数...${PLAIN}"
    PORT=${XRAY_XHTTP_PORT:-2053}
    SNI=${XRAY_XHTTP_SNI:-"www.sony.jp"}
else
    echo -e "${YELLOW}--- 配置 XHTTP Reality ---${PLAIN}"
    while true; do
        read -p "请输入监听端口 (默认 2053): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=2053 && break
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            PORT="$CUSTOM_PORT"
            break
        else 
            echo -e "${RED}无效端口。${PLAIN}"
        fi
    done

    echo -e "${YELLOW}请选择伪装域名 (SNI):${PLAIN}"
    echo -e "  1. www.sony.jp (默认)"
    echo -e "  2. updates.cdn-apple.com"
    echo -e "  3. 手动输入"
    read -p "选择: " s
    case $s in
        2) SNI="updates.cdn-apple.com" ;;
        3) read -p "输入域名: " SNI; [[ -z "$SNI" ]] && SNI="www.sony.jp" ;;
        *) SNI="www.sony.jp" ;;
    esac
fi

# --- 4. 密钥生成 ---
echo -e "${YELLOW}正在生成独立密钥...${PLAIN}"
UUID=$($XRAY_BIN uuid)
SHORT_ID=$(openssl rand -hex 4)
XHTTP_PATH="/$(openssl rand -hex 4)"
RAW_KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$RAW_KEYS" | grep "Private" | awk -F ":" '{print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$RAW_KEYS" | grep -E "Password|Public" | awk -F ":" '{print $2}' | tr -d ' \r\n')

# --- 5. 核心执行 (注入配置) ---
NODE_TAG="Xray-XHTTP-${PORT}"

# [关键修复] Tag + Port 双重清理
# 使用 tonumber 确保端口比较准确，防止类型不匹配
tmp_clean=$(mktemp)
jq --argjson p "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[]? | select(.port == $p or .tag == $tag))' \
   "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"

# 构建节点 JSON
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg path "$XHTTP_PATH" \
    --arg sni "$SNI" \
    --arg pk "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" \
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
        network: "xhttp",
        xhttpSettings: {path: $path},
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

# 注入新节点
tmp_add=$(mktemp)
jq --argjson new "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp_add" && mv "$tmp_add" "$CONFIG_FILE"

# --- 6. 重启与输出 ---
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    PUBLIC_IP=$(curl -s4 ifconfig.me)
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&type=xhttp&sni=${SNI}&sid=${SHORT_ID}&path=${XHTTP_PATH}&fp=chrome#${NODE_TAG}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [Xray] XHTTP Reality 部署成功！     ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "端口        : ${YELLOW}${PORT}${PLAIN}"
    echo -e "协议        : ${YELLOW}XHTTP${PLAIN}"
    echo -e "路径 (Path) : ${YELLOW}${XHTTP_PATH}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"

    # === 新增：OpenClash / Meta 输出 ===
    echo -e "🐱 [OpenClash / Meta (Mihomo) 配置块]:"
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
  xhttp-opts:
    path: ${XHTTP_PATH}
  reality-opts:
    public-key: ${PUBLIC_KEY}
    short-id: ${SHORT_ID}
EOF
    echo -e "${PLAIN}----------------------------------------"

    if [[ "$AUTO_SETUP" == "true" ]]; then
        LOG_FILE="/root/xray_nodes.txt"
        echo "Tag: ${NODE_TAG} | ${SHARE_LINK}" >> "$LOG_FILE"
        echo -e "${SKYBLUE}>>> [自动记录] 已追加至: ${LOG_FILE}${PLAIN}"
    fi
else
    echo -e "${RED}启动失败！请检查日志: journalctl -u xray -e${PLAIN}"
    [[ "$AUTO_SETUP" == "true" ]] && exit 1
fi
