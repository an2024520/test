#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> 开始部署 Xray (日本 VPS 优化版 - Amazon JP)...${PLAIN}"

# 1. 检查 Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# ==========================================
# 用户自定义配置区域
# ==========================================

# --- 1. 设置监听端口 ---
while true; do
    echo -e "${YELLOW}提示: 建议使用 2053, 2083, 8443 等端口。${PLAIN}"
    read -p "请输入 Xray 监听端口 (默认 2053): " CUSTOM_PORT
    
    if [[ -z "$CUSTOM_PORT" ]]; then
        PORT=2053
        echo -e "${GREEN}使用默认端口: 2053${PLAIN}"
        break
    fi

    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -ge 1 ] && [ "$CUSTOM_PORT" -le 65535 ]; then
        PORT="$CUSTOM_PORT"
        echo -e "${GREEN}端口已设置为: $PORT${PLAIN}"
        break
    else
        echo -e "${RED}无效端口，请输入 1-65535。${PLAIN}"
    fi
done

echo "------------------------------------------"

# --- 2. 设置伪装域名 (SNI) - 日本专供版 ---
echo -e "${YELLOW}提示: 针对日本 VPS，推荐使用以下域名 (已验证国内可访问性):${PLAIN}"
echo -e "  1. www.amazon.co.jp (日本亚马逊 - 首选，最稳)"
echo -e "  2. www.nintendo.co.jp (任天堂 - 适合 UDP 游戏流量)"
echo -e "  3. www.microsoft.com (微软 - 全球通用保底)"

read -p "请输入伪装域名 (默认 www.amazon.co.jp): " CUSTOM_SNI

if [[ -z "$CUSTOM_SNI" ]]; then
    SNI="www.amazon.co.jp"
else
    SNI="$CUSTOM_SNI"
fi

# --- 3. 连通性预检 (新增功能) ---
echo -e "${YELLOW}正在检查 VPS 访问 $SNI 的连通性...${PLAIN}"
if curl -s -I --max-time 5 "https://$SNI" >/dev/null; then
    echo -e "${GREEN}检测通过！你的 VPS 可以顺畅连接到 $SNI。${PLAIN}"
else
    echo -e "${RED}警告: 你的 VPS 似乎无法连接到 $SNI (超时或被拒)。${PLAIN}"
    echo -e "${YELLOW}这可能会导致 Reality 无法工作。是否继续？(y/n)${PLAIN}"
    read -p "请选择: " CONTINUE
    if [[ "$CONTINUE" != "y" ]]; then
        echo "已取消安装。"
        exit 1
    fi
fi

# ==========================================
# 安装流程
# ==========================================

# 4. 清理旧环境
echo -e "${YELLOW}正在清理旧版本...${PLAIN}"
systemctl stop xray >/dev/null 2>&1
systemctl disable xray >/dev/null 2>&1
rm -rf /usr/local/bin/xray /usr/local/bin/xray_core /usr/local/etc/xray /etc/systemd/system/xray.service
systemctl daemon-reload

# 5. 安装依赖
apt update -y
apt install -y curl wget jq openssl uuid-runtime unzip

# 6. 下载 Xray 最新版
ARCH=$(dpkg --print-architecture)
case $ARCH in
    amd64) XRAY_ARCH="64" ;;
    arm64) XRAY_ARCH="arm64-v8a" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac

echo -e "${YELLOW}正在获取最新版本...${PLAIN}"
LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
if [[ -z "$LATEST_VERSION" ]] || [[ "$LATEST_VERSION" == "null" ]]; then
    echo -e "${RED}获取版本失败，请检查网络。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}即将安装版本: ${LATEST_VERSION}${PLAIN}"
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${XRAY_ARCH}.zip"

mkdir -p /usr/local/bin/xray_core
wget -O /tmp/xray.zip "$DOWNLOAD_URL"
if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败！${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}正在解压...${PLAIN}"
unzip -o /tmp/xray.zip -d /usr/local/bin/xray_core
rm -f /tmp/xray.zip
chmod +x /usr/local/bin/xray_core/xray

XRAY_BIN="/usr/local/bin/xray_core/xray"

# 7. 生成密钥 (适配 v25.12.8+)
echo -e "${YELLOW}正在生成 Reality 密钥...${PLAIN}"

UUID=$(uuidgen)
SHORT_ID=$(openssl rand -hex 4)
XHTTP_PATH="/$(openssl rand -hex 4)"

RAW_KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$RAW_KEYS" | grep "PrivateKey:" | awk -F ":" '{print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$RAW_KEYS" | grep "Password:" | awk -F ":" '{print $2}' | tr -d ' \r\n')

# 调试输出
echo -e "Private Key: ${PRIVATE_KEY}"
echo -e "Public Key : ${PUBLIC_KEY}"

if [[ -z "$PRIVATE_KEY" ]] || [[ -z "$PUBLIC_KEY" ]]; then
    echo -e "${RED}密钥获取失败！${PLAIN}"
    exit 1
fi

# 8. 写入配置文件
mkdir -p /usr/local/etc/xray
CONFIG_FILE="/usr/local/etc/xray/config.json"

cat <<EOF > $CONFIG_FILE
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$XHTTP_PATH"
        },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF

# 9. Systemd 配置
cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/xray_core/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 10. 启动
echo -e "${YELLOW}正在启动服务...${PLAIN}"
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 11. 结果输出
PUBLIC_IP=$(curl -s4 ifconfig.me)
NODE_NAME="Xray-JP-${PUBLIC_IP}"

SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&type=xhttp&sni=${SNI}&sid=${SHORT_ID}&path=${XHTTP_PATH}&fp=chrome#${NODE_NAME}"

sleep 2
if systemctl is-active --quiet xray; then
    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}   Xray (日本 VPS 优化版) 部署成功     ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "IP 地址     : ${YELLOW}${PUBLIC_IP}${PLAIN}"
    echo -e "监听端口    : ${YELLOW}${PORT}${PLAIN}"
    echo -e "伪装域名    : ${YELLOW}${SNI}${PLAIN}"
    echo -e "Reality公钥 : ${YELLOW}${PUBLIC_KEY}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [链接]: ${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "⚠️ 防火墙提示: 请确保云服务商安全组已放行 UDP/TCP ${PORT} 端口"
else
    echo -e "${RED}启动失败！请检查日志: journalctl -u xray -e${PLAIN}"
fi
