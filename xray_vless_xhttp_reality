#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> 开始部署 Xray (日本 VPS 逻辑闭环版)...${PLAIN}"

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

# --- 2. 设置伪装域名 (SNI) - 逻辑严密版 ---
echo -e "${YELLOW}提示: 为避免 IP 归属地逻辑矛盾，已精选以下适合 [中国->日本] 的伪装域名:${PLAIN}"
echo -e "  1. www.sony.jp (索尼日本 - 逻辑完美，访问日本官网天经地义)"
echo -e "  2. www.nintendo.co.jp (任天堂 - 模拟游戏机待机流量，非常安全)"
echo -e "  3. updates.cdn-apple.com (苹果CDN - 更新服务器经常会有跨国流量)"
echo -e "  4. www.microsoft.com (微软 - 技术最稳，虽然逻辑稍逊但大厂光环重)"

read -p "请输入选项 [1-4] (默认 1. 索尼): " SNI_CHOICE

case $SNI_CHOICE in
    2) SNI="www.nintendo.co.jp" ;;
    3) SNI="updates.cdn-apple.com" ;;
    4) SNI="www.microsoft.com" ;;
    *) SNI="www.sony.jp" ;;
esac

echo -e "${GREEN}已选择伪装域名: ${SNI}${PLAIN}"

# --- 3. 连通性预检 ---
echo -e "${YELLOW}正在检查 VPS 访问 $SNI 的连通性...${PLAIN}"
if curl -s -I --max-time 5 "https://$SNI" >/dev/null; then
    echo -e "${GREEN}检测通过！VPS 可以连接到 $SNI。${PLAIN}"
else
    echo -e "${RED}警告: VPS 无法连接到 $SNI (可能是被阻断或超时)。${PLAIN}"
    echo -e "${YELLOW}建议更换其他域名。输入 y 更换，输入 n 强制继续。${PLAIN}"
    read -p "是否更换? (y/n): " RETRY
    if [[ "$RETRY" == "y" ]]; then
        echo "请重新运行脚本选择其他域名。"
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

echo -e "${GREEN}即将安装版本: ${LATEST_VERSION}${PLAIN}"
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${XRAY_ARCH}.zip"

mkdir -p /usr/local/bin/xray_core
wget -O /tmp/xray.zip "$DOWNLOAD_URL"
if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败！${PLAIN}"
    exit 1
fi

unzip -o /tmp/xray.zip -d /usr/local/bin/xray_core
rm -f /tmp/xray.zip
chmod +x /usr/local/bin/xray_core/xray
XRAY_BIN="/usr/local/bin/xray_core/xray"

# 7. 生成密钥 (v25+ 适配)
echo -e "${YELLOW}正在生成 Reality 密钥...${PLAIN}"
UUID=$(uuidgen)
SHORT_ID=$(openssl rand -hex 4)
XHTTP_PATH="/$(openssl rand -hex 4)"

RAW_KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$RAW_KEYS" | grep "PrivateKey:" | awk -F ":" '{print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$RAW_KEYS" | grep "Password:" | awk -F ":" '{print $2}' | tr -d ' \r\n')

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
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 11. 结果
PUBLIC_IP=$(curl -s4 ifconfig.me)
NODE_NAME="Xray-JP-${PUBLIC_IP}"
SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&type=xhttp&sni=${SNI}&sid=${SHORT_ID}&path=${XHTTP_PATH}&fp=chrome#${NODE_NAME}"

sleep 2
if systemctl is-active --quiet xray; then
    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}   Xray (日本-索尼/任天堂) 部署成功     ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "IP 地址     : ${YELLOW}${PUBLIC_IP}${PLAIN}"
    echo -e "监听端口    : ${YELLOW}${PORT}${PLAIN}"
    echo -e "伪装域名    : ${YELLOW}${SNI}${PLAIN}"
    echo -e "Reality公钥 : ${YELLOW}${PUBLIC_KEY}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [链接]: ${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
else
    echo -e "${RED}启动失败！请检查日志: journalctl -u xray -e${PLAIN}"
fi
