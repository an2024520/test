#!/bin/bash

# ============================================================
#  模块八：VLESS + WS + TLS (经典 CDN / Nginx 前置版)
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 核心路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray_core/xray"

echo -e "${GREEN}>>> [模块八] 智能添加节点: VLESS + WebSocket + TLS ...${PLAIN}"

# 1. 环境检查
if [[ ! -f "$XRAY_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Xray 核心！请先运行 [模块一]。${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}检测到缺少必要工具，正在安装 (jq, openssl)...${PLAIN}"
    apt update -y && apt install -y jq openssl
fi

# 2. 配置文件初始化
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
echo -e "${YELLOW}--- 配置 VLESS-WS-TLS 节点 ---${PLAIN}"
echo -e "${YELLOW}注意: 此模式需要您拥有【真实域名】和【SSL证书文件】(.crt/.key)${PLAIN}"

# A. 端口设置
while true; do
    read -p "请输入监听端口 (推荐 443, 或 2053/2083 等 CDN 端口): " CUSTOM_PORT
    [[ -z "$CUSTOM_PORT" ]] && echo -e "${RED}端口不能为空${PLAIN}" && continue
    
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
        if grep -q "\"port\": $CUSTOM_PORT" "$CONFIG_FILE"; then
             echo -e "${RED}警告: 端口 $CUSTOM_PORT 似乎已被占用了，请换一个！${PLAIN}"
        else
             PORT="$CUSTOM_PORT"
             break
        fi
    else
        echo -e "${RED}无效端口。${PLAIN}"
    fi
done

# B. 域名与证书配置 (核心区别)
read -p "请输入您的真实域名 (SNI, 例如 www.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && echo -e "${RED}域名不能为空！${PLAIN}" && exit 1

# 证书文件路径
echo -e "${YELLOW}请输入证书文件路径 (公钥 .crt/.pem):${PLAIN}"
read -p "路径: " CERT_FILE
if [[ ! -f "$CERT_FILE" ]]; then
    echo -e "${RED}错误: 找不到文件 $CERT_FILE${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}请输入密钥文件路径 (私钥 .key):${PLAIN}"
read -p "路径: " KEY_FILE
if [[ ! -f "$KEY_FILE" ]]; then
    echo -e "${RED}错误: 找不到文件 $KEY_FILE${PLAIN}"
    exit 1
fi

# C. WS 路径配置
DEFAULT_PATH="/$(openssl rand -hex 4)"
read -p "请输入 WebSocket 路径 (默认 ${DEFAULT_PATH}): " WS_PATH
[[ -z "$WS_PATH" ]] && WS_PATH="$DEFAULT_PATH"

# 4. 生成密钥 (UUID)
echo -e "${YELLOW}正在生成 UUID...${PLAIN}"
UUID=$($XRAY_BIN uuid)

# 5. 构建节点 JSON (Standard TLS + WS)
echo -e "${YELLOW}正在注入节点配置...${PLAIN}"

NODE_TAG="vless-ws-tls-${PORT}"

# 注意：这里使用的是 standard TLS，不是 Reality
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
          certificates: [
            {
              certificateFile: $cert,
              keyFile: $key
            }
          ]
        },
        wsSettings: {
          path: $path
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

# 6. 重启与输出
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    PUBLIC_IP=$(curl -s4 ifconfig.me)
    NODE_NAME="Xray-WS-TLS-${PORT}"
    
    # 链接生成
    # 格式: vless://uuid@ip:port?security=tls&type=ws&path=/ws&sni=domain#name
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=tls&encryption=none&type=ws&path=${WS_PATH}&sni=${DOMAIN}&fp=chrome#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [模块八] WS+TLS 节点部署成功！      ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "监听端口    : ${YELLOW}${PORT}${PLAIN}"
    echo -e "绑定域名    : ${YELLOW}${DOMAIN}${PLAIN}"
    echo -e "WS 路径     : ${YELLOW}${WS_PATH}${PLAIN}"
    echo -e "证书路径    : ${YELLOW}${CERT_FILE}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    # === OpenClash 输出 ===
    echo -e "🐱 [OpenClash / Meta 配置块]:"
    echo -e "${YELLOW}"
    cat <<EOF
- name: "${NODE_NAME}"
  type: vless
  server: ${PUBLIC_IP}
  port: ${PORT}
  uuid: ${UUID}
  network: ws
  tls: true
  udp: true
  servername: ${DOMAIN}
  client-fingerprint: chrome
  ws-opts:
    path: "${WS_PATH}"
    headers:
      Host: ${DOMAIN}
EOF
    echo -e "${PLAIN}----------------------------------------"
    echo -e "${GRAY}提示: 如果开启了 CDN (如 Cloudflare)，请确保上面的 Server 地址填写的是您的域名，而不是 IP。${PLAIN}"
else
    echo -e "${RED}启动失败！${PLAIN}"
    echo -e "请检查证书权限是否正确 (Xray 可能无法读取 root 目录下的证书)。"
    echo -e "建议将证书复制到 /usr/local/etc/xray/ 目录下。"
    echo -e "日志: journalctl -u xray -e"
fi
