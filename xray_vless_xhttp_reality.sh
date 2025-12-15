#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> 开始部署 Xray 最新版 (自定义端口 + 适配 v25.12.8+)...${PLAIN}"

# 1. 检查 Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# 2. 用户输入监听端口
# ----------------------------------------------------
while true; do
    echo -e "${YELLOW}提示: 如果你同时运行 Hysteria 2 (ACME)，请不要使用 443 端口。${PLAIN}"
    read -p "请输入 Xray 监听端口 (留空默认 443，推荐 2053, 8443 等): " CUSTOM_PORT
    
    # 如果用户留空，默认 443
    if [[ -z "$CUSTOM_PORT" ]]; then
        PORT=443
        echo -e "${YELLOW}已选择默认端口: 443${PLAIN}"
        break
    fi

    # 检查是否为有效数字
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -ge 1 ] && [ "$CUSTOM_PORT" -le 65535 ]; then
        PORT="$CUSTOM_PORT"
        echo -e "${GREEN}端口已设置为: $PORT${PLAIN}"
        break
    else
        echo -e "${RED}输入无效，请输入 1-65535 之间的数字。${PLAIN}"
    fi
done
# ----------------------------------------------------

# 3. 清理旧环境
echo -e "${YELLOW}正在清理旧版本...${PLAIN}"
systemctl stop xray >/dev/null 2>&1
systemctl disable xray >/dev/null 2>&1
rm -rf /usr/local/bin/xray /usr/local/bin/xray_core /usr/local/etc/xray /etc/systemd/system/xray.service
systemctl daemon-reload

# 4. 安装依赖
apt update -y
apt install -y curl wget jq openssl uuid-runtime unzip

# 5. 下载 Xray 最新版
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

# 6. 生成密钥 (直接抓取逻辑)
echo -e "${YELLOW}正在生成 Reality 密钥...${PLAIN}"

UUID=$(uuidgen)
SHORT_ID=$(openssl rand -hex 4)

# 生成原始数据
RAW_KEYS=$($XRAY_BIN x25519)

# 提取 PrivateKey
PRIVATE_KEY=$(echo "$RAW_KEYS" | grep "PrivateKey:" | awk -F ":" '{print $2}' | tr -d ' \r\n')

# 提取 Public Key (在新版中显示为 Password:)
PUBLIC_KEY=$(echo "$RAW_KEYS" | grep "Password:" | awk -F ":" '{print $2}' | tr -d ' \r\n')

# 调试输出
echo -e "Private Key: ${PRIVATE_KEY}"
echo -e "Public Key : ${PUBLIC_KEY}"

if [[ -z "$PRIVATE_KEY" ]] || [[ -z "$PUBLIC_KEY" ]]; then
    echo -e "${RED}密钥获取失败！${PLAIN}"
    exit 1
fi

# 7. 配置参数
# SNI 依然指向 443，这是伪装目标，和我们监听的端口无关
SNI="www.microsoft.com"
XHTTP_PATH="/$(openssl rand -hex 4)"

# 8. 写入配置文件 config.json
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

# 9. 配置 Systemd
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

# 11. 输出结果
PUBLIC_IP=$(curl -s4 ifconfig.me)
NODE_NAME="Xray-Reality-${PUBLIC_IP}"

# VLESS 链接
SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&type=xhttp&sni=${SNI}&sid=${SHORT_ID}&path=${XHTTP_PATH}&fp=chrome#${NODE_NAME}"

sleep 2
if systemctl is-active --quiet xray; then
    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}      Xray 最新版 部署成功！           ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "IP 地址     : ${YELLOW}${PUBLIC_IP}${PLAIN}"
    echo -e "监听端口    : ${YELLOW}${PORT}${PLAIN} (请确保防火墙已放行 UDP/TCP)"
    echo -e "UUID        : ${YELLOW}${UUID}${PLAIN}"
    echo -e "Reality公钥 : ${YELLOW}${PUBLIC_KEY}${PLAIN}"
    echo -e "伪装域名    : ${YELLOW}${SNI}${PLAIN}"
    echo -e "XHTTP 路径  : ${YELLOW}${XHTTP_PATH}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN / Nekoray 导入链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "⚠️  重要提示:"
    echo -e "1. 务必在防火墙(安全组)放行端口: **${PORT}** (协议: TCP 和 UDP)。"
    echo -e "2. 如果你使用 443 以外的端口，Reality 依然会伪装成 www.microsoft.com 的 443 流量。"
else
    echo -e "${RED}启动失败！请运行以下命令查看日志：${PLAIN}"
    echo -e "journalctl -u xray -e"
fi
