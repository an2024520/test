#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}正在开始安装 Hysteria 2 (自有域名版)...${PLAIN}"

# 1. 检查是否为 Root 用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# ==========================================
# 2. 用户输入配置 (端口、域名、密码)
# ==========================================

# 2.1 获取域名 (新增)
echo -e "${YELLOW}请务必确保您的域名 A 记录已解析到本机 IP，并且 80 端口未被占用！${PLAIN}"
read -p "请输入您的域名 (例如: www.example.com): " CUSTOM_DOMAIN
if [[ -z "$CUSTOM_DOMAIN" ]]; then
    echo -e "${RED}域名不能为空，脚本退出。${PLAIN}"
    exit 1
fi

# 2.2 提示输入端口
while true; do
    read -p "请输入 Hysteria 2 监听端口 (推荐 10000 - 65535 之间的数字): " CUSTOM_PORT
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -ge 10000 ] && [ "$CUSTOM_PORT" -le 65535 ]; then
        break
    else
        echo -e "${RED}端口输入无效，请输入一个 10000 到 65535 之间的数字。${PLAIN}"
    fi
done

# 2.3 提示输入密码
read -p "请输入 Hysteria 2 连接密码 (留空则自动生成): " CUSTOM_PASSWORD
if [[ -z "$CUSTOM_PASSWORD" ]]; then
    PASSWORD=$(openssl rand -hex 8)
    echo -e "${YELLOW}未输入密码，已自动生成随机密码：${PASSWORD}${PLAIN}"
else
    PASSWORD="$CUSTOM_PASSWORD"
fi

# 3. 安装必要依赖 (新增 socat 和 cron)
echo -e "${YELLOW}正在更新系统并安装依赖...${PLAIN}"
apt update -y
# 修复点：这里增加了 cron，解决了 acme.sh 安装失败的问题
apt install -y curl openssl jq wget socat cron

# 确保 cron 服务启动
systemctl start cron
systemctl enable cron

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

# 5. 创建配置目录和申请证书 (大幅修改部分)
mkdir -p /etc/hysteria

echo -e "${YELLOW}正在安装 acme.sh 并申请证书 (请确保 80 端口开放)...${PLAIN}"

# 安装 acme.sh
curl https://get.acme.sh | sh
if [ $? -ne 0 ]; then
    echo -e "${RED}acme.sh 安装失败！${PLAIN}"
    exit 1
fi

# 临时停止可能占用 80 端口的服务
systemctl stop nginx 2>/dev/null
systemctl stop apache2 2>/dev/null

# 申请证书
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d "$CUSTOM_DOMAIN" --standalone --force

if [ $? -ne 0 ]; then
    echo -e "${RED}证书申请失败！请检查：1.域名解析是否正确 2.防火墙是否放行 80 端口${PLAIN}"
    exit 1
fi

# 安装证书到 /etc/hysteria
~/.acme.sh/acme.sh --install-cert -d "$CUSTOM_DOMAIN" \
    --key-file       /etc/hysteria/server.key  \
    --fullchain-file /etc/hysteria/server.crt

if [ ! -f /etc/hysteria/server.crt ]; then
	echo -e "${RED}证书安装失败，文件不存在。${PLAIN}"
	exit 1
fi

echo -e "${GREEN}证书申请成功！${PLAIN}"

# 6. 写入配置文件 config.yaml
cat <<EOF > /etc/hysteria/config.yaml
server:
  listen: :$CUSTOM_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $PASSWORD

# 可选：如果需要伪装成网页服务器，可以开启以下部分，否则默认即可
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
SHARE_LINK="hysteria2://${PASSWORD}@${CUSTOM_DOMAIN}:${CUSTOM_PORT}/?sni=${CUSTOM_DOMAIN}&name=Hy2-${CUSTOM_DOMAIN}"

echo -e ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}      Hysteria 2 安装部署完成！        ${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "服务器 IP  : ${YELLOW}${PUBLIC_IP}${PLAIN}"
echo -e "你的域名   : ${YELLOW}${CUSTOM_DOMAIN}${PLAIN}"
echo -e "监听端口   : ${YELLOW}${CUSTOM_PORT}${PLAIN}"
echo -e "连接密码   : ${YELLOW}${PASSWORD}${PLAIN}"
echo -e "----------------------------------------"
echo -e "🚀 [v2rayN / Nekoray 导入链接]:"
echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
echo -e "----------------------------------------"
echo -e "⚠️ 重要提醒:"
echo -e "1. **客户端设置**：现在使用的是真实证书，客户端【切勿】开启“跳过证书验证”或“允许不安全连接”。"
echo -e "2. **防火墙**：请确保 UDP ${CUSTOM_PORT} 端口已放行。"
echo -e "3. **证书续期**：acme.sh 会自动配置 crontab 任务进行续期，请勿删除相关 cron 任务。"
echo -e ""
