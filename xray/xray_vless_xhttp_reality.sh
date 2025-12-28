#!/bin/bash

# ============================================================
#  模块二：VLESS + XHTTP + Reality (v1.3.2 Final)
#  - 默认 SNI: www.microsoft.com (2025 社区主流)
#  - ShortID: 仅生成一个随机 8 位 (更安全，重换即重部署)
#  - Tag: 基于端口 (Xray-XHTTP-${PORT})，简洁唯一
#  - 新增: 客户端兼容性提示
#  - 新增: 结构化 JSON 日志 (/root/xray_nodes.json)
#  - 新增: jq 全 --argjson 安全注入
#  - 新增: xray -test 配置验证
#  - 新增: 自动模式默认值日志提示
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
LOG_FILE="/root/xray_nodes.json"

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

# --- 2. 配置文件初始化 ---
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

# --- 3. 参数获取 ---
PORT=${PORT:-${XRAY_XHTTP_PORT:-2053}}
SNI=${XRAY_XHTTP_SNI:-"www.microsoft.com"}
XHTTP_PATH=${XRAY_XHTTP_PATH:-"/$(openssl rand -hex 4)"}

if [[ "$AUTO_SETUP" == "true" ]]; then
    echo -e "${GREEN}>>> [自动模式] 使用参数: Port=${PORT}, SNI=${SNI}, Path=${XHTTP_PATH}${PLAIN}"
    [[ -z "$XRAY_XHTTP_SNI" ]] && echo -e "${YELLOW}>>> [日志] 使用默认 SNI: www.microsoft.com${PLAIN}"
    [[ -z "$XRAY_XHTTP_PATH" ]] && echo -e "${YELLOW}>>> [日志] 使用随机 Path: ${XHTTP_PATH}${PLAIN}"
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
    echo -e "  1. www.microsoft.com (推荐/默认)"
    echo -e "  2. updates.cdn-apple.com"
    echo -e "  3. www.cloudflare.com"
    echo -e "  4. 手动输入"
    read -p "选择: " s
    case $s in
        2) SNI="updates.cdn-apple.com" ;;
        3) SNI="www.cloudflare.com" ;;
        4) read -p "输入域名: " SNI; [[ -z "$SNI" ]] && SNI="www.microsoft.com" ;;
        *) SNI="www.microsoft.com" ;;
    esac

    read -p "Path (默认随机): " input_path
    [[ -n "$input_path" ]] && XHTTP_PATH="$input_path"
fi

# 端口强制校验
if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}致命错误: 端口参数无效，重置为 2053。${PLAIN}"
    PORT=2053
fi

# --- 4. 密钥生成 ---
echo -e "${YELLOW}正在生成独立密钥...${PLAIN}"
UUID=$($XRAY_BIN uuid)
RAW_KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$RAW_KEYS" | grep "Private" | awk -F ":" '{print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$RAW_KEYS" | grep -E "Public" | awk -F ":" '{print $2}' | tr -d ' \r\n')
SHORT_ID=$(openssl rand -hex 4)  # 仅一个随机 ShortID

# 节点 Tag (基于端口，简洁唯一)
NODE_TAG="Xray-XHTTP-${PORT}"

# --- 5. 清理旧节点 ---
tmp_clean=$(mktemp)
jq --argjson p "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[]? | select(.port == $p or .tag == $tag))' \
   "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"

# --- 6. 构建节点 JSON ---
NODE_JSON=$(jq -n \
    --argjson port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg path "$XHTTP_PATH" \
    --arg sni "$SNI" \
    --arg pk "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" \
    '{
      tag: $tag,
      listen: "0.0.0.0",
      port: $port,
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

# 注入配置
tmp_add=$(mktemp)
jq --argjson new "$NODE_JSON" '.inbounds += [$new]' "$CONFIG_FILE" > "$tmp_add" && mv "$tmp_add" "$CONFIG_FILE"

# --- 7. 配置验证 ---
echo -e "${YELLOW}正在验证配置语法...${PLAIN}"
if ! $XRAY_BIN -test -config="$CONFIG_FILE" > /dev/null 2>&1; then
    echo -e "${RED}配置验证失败！请检查错误。${PLAIN}"
    exit 1
fi

# --- 8. 重启服务 ---
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
    echo -e "SNI         : ${YELLOW}${SNI}${PLAIN}"
    echo -e "路径 (Path) : ${YELLOW}${XHTTP_PATH}${PLAIN}"
    echo -e "ShortID     : ${YELLOW}${SHORT_ID}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🐱 [OpenClash / Meta 配置块]:"
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
    echo -e "${SKYBLUE}注意：XHTTP + Reality 推荐使用最新版 v2rayN / Nekobox / HiddifyNext。${PLAIN}"
    echo -e "${SKYBLUE}Clash Meta 需开启 experimental 并正确填写 xhttp-opts 与 reality-opts。${PLAIN}"

    # --- 9. 结构化日志记录 ---
    if [[ "$AUTO_SETUP" == "true" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        jq -n --arg tag "$NODE_TAG" \
              --arg link "$SHARE_LINK" \
              --argjson port "$PORT" \
              --arg sni "$SNI" \
              --arg path "$XHTTP_PATH" \
              --arg pk "$PUBLIC_KEY" \
              --arg sid "$SHORT_ID" \
              '{tag: $tag, link: $link, port: $port, sni: $sni, path: $path, publicKey: $pk, shortId: $sid, time: now | strftime("%Y-%m-%d %H:%M:%S")}' \
              >> "$LOG_FILE"
        echo -e "${SKYBLUE}>>> [自动记录] 已追加至: ${LOG_FILE}${PLAIN}"
    fi
else
    echo -e "${RED}启动失败！请检查日志: journalctl -u xray -e${PLAIN}"
    [[ "$AUTO_SETUP" == "true" ]] && exit 1
fi