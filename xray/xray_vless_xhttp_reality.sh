#!/bin/bash

# ============================================================
#  模块二 (升级版)：VLESS + XHTTP + Reality + 智能端口检测
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 核心路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray_core/xray"

echo -e "${GREEN}>>> [模块二] 智能添加节点: VLESS + Reality + XHTTP ...${PLAIN}"

# 1. 环境检查
if [[ ! -f "$XRAY_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Xray 核心！请先运行 [模块一]。${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}检测到缺少必要工具，正在安装 (jq, openssl)...${PLAIN}"
    apt update -y && apt install -y jq openssl
fi

# 2. 初始化配置文件骨架
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}配置文件不存在，正在初始化标准骨架...${PLAIN}"
    mkdir -p /usr/local/etc/xray
    cat <<EOF > $CONFIG_FILE
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {
        "type": "field",
        "outboundTag": "blocked",
        "ip": ["geoip:private"]
      }
    ]
  }
}
EOF
    echo -e "${GREEN}标准骨架初始化完成。${PLAIN}"
fi

# 3. 用户配置参数
echo -e "${YELLOW}--- 配置 VLESS (XHTTP) 节点参数 ---${PLAIN}"

# A. 端口设置
while true; do
    read -p "请输入监听端口 (推荐 2053, 2083, 8443, 默认 2053): " CUSTOM_PORT
    [[ -z "$CUSTOM_PORT" ]] && PORT=2053 && break
    
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
        if grep -q "\"port\": $CUSTOM_PORT" "$CONFIG_FILE"; then
             echo -e "${RED}警告: 端口 $CUSTOM_PORT 似乎已被之前的模块占用了，请换一个！${PLAIN}"
        else
             PORT="$CUSTOM_PORT"
             break
        fi
    else
        echo -e "${RED}无效端口。${PLAIN}"
    fi
done

# B. 伪装域名选择
echo -e "${YELLOW}请选择伪装域名 (SNI) - 日本 VPS 推荐:${PLAIN}"
echo -e "  1. www.sony.jp (索尼日本 - 逻辑完美)"
echo -e "  2. www.nintendo.co.jp (任天堂 - 模拟待机流量)"
echo -e "  3. updates.cdn-apple.com (苹果CDN - 跨国更新流量)"
echo -e "  4. www.microsoft.com (微软 - 兼容性保底)"
echo -e "  5. ${GREEN}手动输入 (自定义域名)${PLAIN}"
read -p "请选择 [1-5] (默认 1): " SNI_CHOICE

case $SNI_CHOICE in
    2) SNI="www.nintendo.co.jp" ;;
    3) SNI="updates.cdn-apple.com" ;;
    4) SNI="www.microsoft.com" ;;
    5) 
        read -p "请输入域名 (不带https://): " MANUAL_SNI
        [[ -z "$MANUAL_SNI" ]] && SNI="www.sony.jp" || SNI="$MANUAL_SNI"
        ;;
    *) SNI="www.sony.jp" ;;
esac

# C. 连通性校验
echo -e "${YELLOW}正在检查连通性: $SNI ...${PLAIN}"
if ! curl -s -I --max-time 5 "https://$SNI" >/dev/null; then
    echo -e "${RED}警告: 无法连接到 $SNI。建议更换。${PLAIN}"
    read -p "是否强制继续? (y/n): " FORCE
    [[ "$FORCE" != "y" ]] && exit 1
fi

# 4. 生成密钥 (使用 Xray 生成 UUID)
echo -e "${YELLOW}正在生成密钥...${PLAIN}"

UUID=$($XRAY_BIN uuid)
SHORT_ID=$(openssl rand -hex 4)
XHTTP_PATH="/$(openssl rand -hex 4)"
RAW_KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$RAW_KEYS" | grep "Private" | awk -F ":" '{print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$RAW_KEYS" | grep -E "Password|Public" | awk -F ":" '{print $2}' | tr -d ' \r\n')

# 5. 构建节点 JSON
echo -e "${YELLOW}正在将节点注入配置文件...${PLAIN}"

NODE_TAG="vless-xhttp-${PORT}"

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
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls", "quic"],
        routeOnly: true
      }
    }')

tmp=$(mktemp)
jq --argjson new_node "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 6. 重启验证
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    PUBLIC_IP=$(curl -s4 ifconfig.me)
    NODE_NAME="Xray-VLESS-${PORT}"
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&type=xhttp&sni=${SNI}&sid=${SHORT_ID}&path=${XHTTP_PATH}&fp=chrome#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [模块二] 节点已追加成功！          ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "端口        : ${YELLOW}${PORT}${PLAIN}"
    echo -e "SNI (伪装)  : ${YELLOW}${SNI}${PLAIN}"
    echo -e "传输协议    : xhttp"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    # === 新增：OpenClash 输出 ===
    echo -e "🐱 [OpenClash / Meta 配置块]:"
    echo -e "${YELLOW}"
    cat <<EOF
- name: "${NODE_NAME}"
  type: vless
  server: ${PUBLIC_IP}
  port: ${PORT}
  uuid: ${UUID}
  network: xhttp
  tls: true
  udp: true
  servername: ${SNI}
  client-fingerprint: chrome
  reality-opts:
    public-key: ${PUBLIC_KEY}
    short-id: ${SHORT_ID}
  xhttp-opts:
    mode: auto
    path: ${XHTTP_PATH}
EOF
    echo -e "${PLAIN}----------------------------------------"
else
    echo -e "${RED}启动失败！配置可能存在冲突。${PLAIN}"
    echo -e "请检查日志: journalctl -u xray -e"
fi
