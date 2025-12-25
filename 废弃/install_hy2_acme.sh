#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}正在开始安装 Hysteria 2 (ACME 443 标准版)...${PLAIN}"

# 1. 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# ==========================================
# 2. 用户输入配置
# ==========================================

# 2.1 获取域名
echo -e "${YELLOW}请务必确保您的域名 A 记录已解析到本机 IP！${PLAIN}"
echo -e "${YELLOW}注意：本脚本将强制使用 443 端口以配合 HTTPS/3 标准伪装。${PLAIN}"
read -p "请输入您的域名 (例如: www.example.com): " CUSTOM_DOMAIN
if [[ -z "$CUSTOM_DOMAIN" ]]; then
    echo -e "${RED}域名不能为空，脚本退出。${PLAIN}"
    exit 1
fi

# 2.2 获取邮箱
read -p "请输入您的邮箱 (用于核销证书，例如: admin@example.com): " CUSTOM_EMAIL
if [[ -z "$CUSTOM_EMAIL" ]]; then
    CUSTOM_EMAIL="user@${CUSTOM_DOMAIN}"
    echo -e "${YELLOW}使用默认邮箱: ${CUSTOM_EMAIL}${PLAIN}"
fi

# 2.3 自动设置端口为 443
CUSTOM_PORT=443
echo -e "${GREEN}端口已自动设置为: ${CUSTOM_PORT} (最佳伪装)${PLAIN}"

# 2.4 获取密码
read -p "请输入连接密码 (留空自动生成): " CUSTOM_PASSWORD
if [[ -z "$CUSTOM_PASSWORD" ]]; then
    PASSWORD=$(openssl rand -hex 8)
    echo -e "${YELLOW}已生成随机密码：${PASSWORD}${PLAIN}"
else
    PASSWORD="$CUSTOM_PASSWORD"
fi

# 3. 安装依赖
echo -e "${YELLOW}正在安装必要工具...${PLAIN}"
apt update -y
apt install -y curl openssl jq wget

# 4. 下载 Hysteria 2
ARCH=$(dpkg --print-architecture)
case $ARCH in
    amd64) HY_ARCH="amd64" ;;
    arm64) HY_ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac

LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
if [[ -z "$LATEST_VERSION" ]]; then
    echo -e "${RED}获取版本失败，请检查网络。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}下载版本: ${LATEST_VERSION}${PLAIN}"
wget -O /usr/local/bin/hysteria "https://github.com/apernet/hysteria/releases/download/${LATEST_VERSION}/hysteria-linux-${HY_ARCH}"
chmod +x /usr/local/bin/hysteria

# 5. 清理环境与端口
mkdir -p /etc/hysteria
echo -e "${YELLOW}正在释放 80/443 端口...${PLAIN}"
systemctl stop nginx 2>/dev/null
systemctl stop apache2 2>/dev/null

# 6. 写入配置 (标准 ACME 配置)
cat <<EOF > /etc/hysteria/config.yaml
server:
  listen: :$CUSTOM_PORT

acme:
  domains:
    - $CUSTOM_DOMAIN
  email: $CUSTOM_EMAIL

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

# 7. 配置 Systemd
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
Environment=HYSTERIA_ACME_DIR=/etc/hysteria/acme

[Install]
WantedBy=multi-user.target
EOF

# 8. 启动服务
echo -e "${YELLOW}正在启动服务并申请证书...${PLAIN}"
systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

sleep 3

# 9. 检查状态
if systemctl is-active --quiet hysteria-server; then
    PUBLIC_IP=$(curl -s4 ifconfig.me)
    # 生成链接 (已包含 alpn=h3 和端口 443)
    SHARE_LINK="hysteria2://${PASSWORD}@${CUSTOM_DOMAIN}:${CUSTOM_PORT}/?sni=${CUSTOM_DOMAIN}&alpn=h3&name=Hy2-${CUSTOM_DOMAIN}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}      Hysteria 2 部署成功 (端口 443)    ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "域名       : ${YELLOW}${CUSTOM_DOMAIN}${PLAIN}"
    echo -e "端口       : ${YELLOW}${CUSTOM_PORT}${PLAIN}"
    echo -e "密码       : ${YELLOW}${PASSWORD}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN / Nekoray 导入链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "⚠️  重要检查:"
    echo -e "1. 请确保云服务器防火墙已放行 **UDP 443** (不仅仅是 TCP)。"
    echo -e "2. 客户端允许不安全连接 (Insecure) 必须设为 **False**。"
else
    echo -e "${RED}服务启动失败！${PLAIN}"
    echo -e "请运行: journalctl -u hysteria-server -e --no-pager 查看日志"
fi
