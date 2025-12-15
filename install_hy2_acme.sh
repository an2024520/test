#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}正在开始安装 Hysteria 2 (官方内置 ACME 版)...${PLAIN}"

# 1. 检查是否为 Root 用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# ==========================================
# 2. 用户输入配置 (域名、邮箱、端口、密码)
# ==========================================

# 2.1 获取域名
echo -e "${YELLOW}请务必确保您的域名 A 记录已解析到本机 IP！${PLAIN}"
echo -e "${YELLOW}注意：Hysteria 2 内置 ACME 需要占用 80 端口进行验证，请确保 80 端口未被其他程序占用。${PLAIN}"
read -p "请输入您的域名 (例如: www.example.com): " CUSTOM_DOMAIN
if [[ -z "$CUSTOM_DOMAIN" ]]; then
    echo -e "${RED}域名不能为空，脚本退出。${PLAIN}"
    exit 1
fi

# 2.2 获取邮箱 (ACME 需要)
read -p "请输入您的邮箱 (用于申请证书，例如: admin@example.com): " CUSTOM_EMAIL
if [[ -z "$CUSTOM_EMAIL" ]]; then
    echo -e "${YELLOW}未输入邮箱，使用默认伪装邮箱。${PLAIN}"
    CUSTOM_EMAIL="user@${CUSTOM_DOMAIN}"
fi

# 2.3 提示输入端口 (UDP 监听端口)
while true; do
    read -p "请输入 Hysteria 2 监听端口 (推荐 10000 - 65535 之间的数字): " CUSTOM_PORT
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -ge 10000 ] && [ "$CUSTOM_PORT" -le 65535 ]; then
        break
    else
        echo -e "${RED}端口输入无效，请输入一个 10000 到 65535 之间的数字。${PLAIN}"
    fi
done

# 2.4 提示输入密码
read -p "请输入 Hysteria 2 连接密码 (留空则自动生成): " CUSTOM_PASSWORD
if [[ -z "$CUSTOM_PASSWORD" ]]; then
    PASSWORD=$(openssl rand -hex 8)
    echo -e "${YELLOW}未输入密码，已自动生成随机密码：${PASSWORD}${PLAIN}"
else
    PASSWORD="$CUSTOM_PASSWORD"
fi

# 3. 安装基础依赖 (移除 socat, cron, acme.sh)
echo -e "${YELLOW}正在更新系统并安装基础工具...${PLAIN}"
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

# 5. 环境清理与目录创建
mkdir -p /etc/hysteria

# 临时停止可能占用 80 端口的服务 (Hysteria 需要用 80 端口申请证书)
echo -e "${YELLOW}正在尝试释放 80 端口以供证书申请...${PLAIN}"
systemctl stop nginx 2>/dev/null
systemctl stop apache2 2>/dev/null

# 6. 写入配置文件 config.yaml (使用 acme 字段)
# 参考文档: https://v2.hysteria.network/docs/advanced/Full-Server-Config/#acme
cat <<EOF > /etc/hysteria/config.yaml
server:
  listen: :$CUSTOM_PORT

# 开启内置 ACME (自动证书管理)
acme:
  domains:
    - $CUSTOM_DOMAIN
  email: $CUSTOM_EMAIL

auth:
  type: password
  password: $PASSWORD

# 伪装配置 (推荐开启)
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true

ignoreClientBandwidth: false
EOF

# 7. 配置 Systemd 服务
# 注意：为了能让 Hysteria 绑定 80 端口(ACME HTTP Challenge)，Root 用户无须额外配置。
# CAP_NET_BIND_SERVICE 已包含在 Root 权限中。
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
# 确保 ACME 数据能被正确保存
Environment=HYSTERIA_ACME_DIR=/etc/hysteria/acme

[Install]
WantedBy=multi-user.target
EOF

# 8. 启动服务
echo -e "${YELLOW}正在启动服务并申请证书 (首次启动可能需要几秒钟)...${PLAIN}"
systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

# 等待几秒检查状态
sleep 3
STATUS=$(systemctl is-active hysteria-server)
if [[ "$STATUS" != "active" ]]; then
    echo -e "${RED}服务启动失败！请使用 'journalctl -u hysteria-server -e' 查看日志。${PLAIN}"
    echo -e "${RED}常见原因：80 端口被占用，导致 ACME 申请失败。${PLAIN}"
    exit 1
fi

# 9. 获取公网 IP
PUBLIC_IP=$(curl -s4 ifconfig.me)

# 10. 生成 v2rayN 兼容链接
SHARE_LINK="hysteria2://${PASSWORD}@${CUSTOM_DOMAIN}:${CUSTOM_PORT}/?sni=${CUSTOM_DOMAIN}&alpn=h3&name=Hy2-${CUSTOM_DOMAIN}"

echo -e ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}   Hysteria 2 (内置ACME版) 部署完成！   ${PLAIN}"
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
echo -e "1. **端口占用**：Hysteria 2 运行时会自动监听 TCP 80 端口用于证书申请/续期，请勿在服务器上运行其他占用 80 端口的 Web 服务(如 Nginx)。"
echo -e "2. **证书验证**：客户端请正常开启证书验证，不要跳过。"
echo -e "3. **证书位置**：证书数据自动存储在 /etc/hysteria/acme 目录下，无需手动干预。"
echo -e ""
