#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}正在开始安装 Hysteria 2...${PLAIN}"

# 1. 检查是否为 Root 用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# 2. 用户输入端口和密码

# 提示输入端口
while true; do
    read -p "请输入 Hysteria 2 监听端口 (推荐 10000 - 65535 之间的数字): " CUSTOM_PORT
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -ge 10000 ] && [ "$CUSTOM_PORT" -le 65535 ]; then
        break
    else
        echo -e "${RED}端口输入无效，请输入一个 10000 到 65535 之间的数字。${PLAIN}"
    fi
done

# 提示输入密码 (如果留空则生成随机密码)
read -p "请输入 Hysteria 2 连接密码 (留空则自动生成): " CUSTOM_PASSWORD
if [[ -z "$CUSTOM_PASSWORD" ]]; then
    PASSWORD=$(openssl rand -hex 8)
    echo -e "${YELLOW}未输入密码，已自动生成随机密码：${PASSWORD}${PLAIN}"
else
    PASSWORD="$CUSTOM_PASSWORD"
fi

# 3. 安装必要依赖
echo -e "${YELLOW}正在更新系统并安装依赖...${PLAIN}"
apt update -y
apt install -y curl openssl jq wget

# 4. 获取架构并下载最新版内核
ARCH=$(dpkg --print-architecture)
case $ARCH in
    amd64) HY_ARCH="amd64" ;;
    arm64) HY_ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac

echo -e "${YELLOW}正在获取 Hysteria 2 最新版本...${PLAIN}"
LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
if [[ -z "$LATEST_VERSION" ]]; then
    echo -e "${RED}获取版本失败，请检查网络连接。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}检测到最新版本: ${LATEST_VERSION}${PLAIN}"
DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/${LATEST_VERSION}/hysteria-linux-${HY_ARCH}"

# 下载并安装
wget -O /usr/local/bin/hysteria "$DOWNLOAD_URL"
chmod +x /usr/local/bin/hysteria

# 5. 创建配置目录和自签名证书
mkdir -p /etc/hysteria

echo -e "${YELLOW}正在生成自签名证书 (有效期 10 年)...${PLAIN}"
openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=bing.com"

# 6. 写入配置文件 config.yaml (使用用户指定的端口和密码)
cat <<EOF > /etc/hysteria/config.yaml
listen: :$CUSTOM_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true

ignoreClientBandwidth: false
EOF

# 7. 配置 Systemd 服务
cat <<EOF > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/hysteria
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 8. 启动服务
systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

# 9. 获取公网 IP
PUBLIC_IP=$(curl -s4 ifconfig.me)

# 10. 生成 v2rayN 兼容链接
SHARE_LINK="hysteria2://${PASSWORD}@${PUBLIC_IP}:${CUSTOM_PORT}/?insecure=1&sni=bing.com&name=Hysteria2-${PUBLIC_IP}"

echo -e ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}      Hysteria 2 安装部署完成！        ${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "服务器 IP  : ${YELLOW}${PUBLIC_IP}${PLAIN}"
echo -e "监听端口   : ${YELLOW}${CUSTOM_PORT}${PLAIN}"
echo -e "连接密码   : ${YELLOW}${PASSWORD}${PLAIN}"
echo -e "----------------------------------------"
echo -e "🚀 [v2rayN / Nekoray 导入链接]:"
echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
echo -e "----------------------------------------"
echo -e "⚠️ 重要提醒:"
echo -e "1. **防火墙**：请确保你的 Debian 系统防火墙 (iptables/ufw) 或云服务商的安全组放行了 UDP 协议的 ${CUSTOM_PORT} 端口。"
echo -e "2. **客户端**：由于使用自签名证书，客户端必须开启【允许不安全连接/跳过证书验证】(Insecure Mode)。"
echo -e ""
