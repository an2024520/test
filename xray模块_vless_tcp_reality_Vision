#!/bin/bash

# ============================================================
#  模块三：VLESS + TCP + Reality + Vision (极致稳定版)
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 核心路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray_core/xray"

echo -e "${GREEN}>>> [模块三] 智能添加节点: VLESS + TCP + Reality + Vision ...${PLAIN}"

# 1. 环境检查 (依赖模块一)
if [[ ! -f "$XRAY_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Xray 核心！请先运行 [模块一] 打地基。${PLAIN}"
    exit 1
fi

# 检查并安装 jq (为了处理 JSON)
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}检测到缺少 jq 工具，正在安装...${PLAIN}"
    apt update -y && apt install -y jq
fi

# 2. 核心逻辑：配置文件初始化
# (这一步保证了模块运行不分先后：谁先运行谁就负责创建骨架)
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}配置文件不存在，由本模块初始化标准骨架...${PLAIN}"
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
# -----------------------------------------------------------
echo -e "${YELLOW}--- 配置 Vision 节点参数 ---${PLAIN}"
echo -e "${YELLOW}注意: Vision 协议通常占用 443 端口效果最好，但为了模块共存，你可以自定义。${PLAIN}"

# A. 端口设置 (自动避让逻辑)
while true; do
    read -p "请输入监听端口 (推荐 443 或 8443, 默认 8443): " CUSTOM_PORT
    [[ -z "$CUSTOM_PORT" ]] && PORT=8443 && break
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
        # 简单检查端口是否已被配置文件中的其他模块占用
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

# B. 伪装域名选择 (Reality 必须)
echo -e "${YELLOW}请选择伪装域名 (SNI) - 既然是Vision，推荐大厂域名:${PLAIN}"
echo -e "  1. www.microsoft.com (微软 - 稳如老狗)"
echo -e "  2. www.apple.com (苹果 - 经典)"
echo -e "  3. www.amazon.com (亚马逊 - 电商流量)"
echo -e "  4. ${GREEN}手动输入${PLAIN}"
read -p "请选择 [1-4] (默认 1): " SNI_CHOICE

case $SNI_CHOICE in
    2) SNI="www.apple.com" ;;
    3) SNI="www.amazon.com" ;;
    4) 
        read -p "请输入域名 (不带https://): " MANUAL_SNI
        [[ -z "$MANUAL_SNI" ]] && SNI="www.microsoft.com" || SNI="$MANUAL_SNI"
        ;;
    *) SNI="www.microsoft.com" ;;
esac

# 4. 生成密钥
echo -e "${YELLOW}正在生成独立密钥...${PLAIN}"
UUID=$(uuidgen)
# Vision 建议生成多个 shortId 以增强抗探测能力，这里我们生成一个标准的
SHORT_ID=$(openssl rand -hex 8) 
RAW_KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$RAW_KEYS" | grep "Private" | awk -F ":" '{print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$RAW_KEYS" | grep -E "Password|Public" | awk -F ":" '{print $2}' | tr -d ' \r\n')

# 5. 构建节点 JSON (Vision 特供版)
# -----------------------------------------------------------
echo -e "${YELLOW}正在注入 Vision 节点...${PLAIN}"

NODE_TAG="vless-vision-${PORT}"

# 关键区别：
# 1. flow: "xtls-rprx-vision" (开启流控)
# 2. network: "tcp" (强制 TCP)
# 3. 不再需要 xhttpSettings
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg sni "$SNI" \
    --arg pk "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" \
    '{
      tag: $tag,
      listen: "0.0.0.0",
      port: ($port | tonumber),
      protocol: "vless",
      settings: {
        clients: [{
            id: $uuid, 
            flow: "xtls-rprx-vision"
        }],
        decryption: "none"
      },
      streamSettings: {
        network: "tcp",
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

# 追加到 inbounds
tmp=$(mktemp)
jq --argjson new_node "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 6. 重启与输出
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    PUBLIC_IP=$(curl -s4 ifconfig.me)
    NODE_NAME="Xray-Vision-${PORT}"
    # 分享链接中 flow=xtls-rprx-vision 非常重要
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}&fp=chrome#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [模块三] Vision 节点部署成功！      ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "协议特性    : VLESS + Reality + ${YELLOW}Vision (TCP)${PLAIN}"
    echo -e "监听端口    : ${YELLOW}${PORT}${PLAIN}"
    echo -e "伪装域名    : ${YELLOW}${SNI}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "💡 小贴士: 在客户端中，请确保 '流控(flow)' 选项已识别为 xtls-rprx-vision"
else
    echo -e "${RED}启动失败！${PLAIN}"
    echo -e "可能是端口冲突或配置错误，请检查日志: journalctl -u xray -e"
fi
