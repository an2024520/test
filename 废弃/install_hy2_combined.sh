#!/bin/bash

# ============================================================
#  Hysteria 2 官方内核部署 (全能合并版)
#  - 整合: 自签证书 (openssl) + 内置 ACME
#  - 逻辑: 自动生成 Systemd, Config, 自动检测架构
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [官方内核] Hysteria 2 部署脚本启动...${PLAIN}"

# 1. 权限与依赖
if [[ $EUID -ne 0 ]]; then echo -e "${RED}必须使用 root 运行！${PLAIN}"; exit 1; fi

apt update -y && apt install -y curl openssl jq wget

# 2. 模式选择 (核心逻辑)
echo -e "${YELLOW}------------------------------------------------${PLAIN}"
echo -e "请选择模式:"
echo -e "1. ${GREEN}留空回车${PLAIN} -> 自签证书 (IP直连，无需域名)"
echo -e "2. ${SKYBLUE}输入域名${PLAIN} -> 真实证书 (官方内置 ACME 申请)"
echo -e "${YELLOW}------------------------------------------------${PLAIN}"
read -p "请输入域名 (留空则自签): " DOMAIN_INPUT

if [[ -z "$DOMAIN_INPUT" ]]; then
    MODE="self"
    DOMAIN="bing.com"
    # 自签模式：允许自定义端口
    read -p "请输入监听端口 (默认 10086): " CUSTOM_PORT
    [[ -z "$CUSTOM_PORT" ]] && PORT=10086 || PORT=$CUSTOM_PORT
else
    MODE="acme"
    DOMAIN="$DOMAIN_INPUT"
    # ACME模式：为了符合 HTTP/3 标准，强制或推荐 443
    echo -e "${GREEN}ACME 模式推荐使用 443 端口以获得最佳伪装效果。${PLAIN}"
    read -p "请输入端口 (回车默认 443): " CUSTOM_PORT
    [[ -z "$CUSTOM_PORT" ]] && PORT=443 || PORT=$CUSTOM_PORT
    
    # 清理 80/443 用于申请
    systemctl stop nginx 2>/dev/null
    systemctl stop apache2 2>/dev/null
fi

# 3. 密码处理
read -p "请输入连接密码 (留空随机): " INPUT_PASS
if [[ -z "$INPUT_PASS" ]]; then
    PASSWORD=$(openssl rand -hex 16)
else
    PASSWORD="$INPUT_PASS"
fi

# 4. 下载核心
ARCH=$(dpkg --print-architecture)
case $ARCH in
    amd64) HY_ARCH="amd64" ;;
    arm64) HY_ARCH="arm64" ;;
    *) echo -e "${RED}不支持架构: $ARCH${PLAIN}"; exit 1 ;;
esac

echo -e "${YELLOW}正在获取最新版本...${PLAIN}"
LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
wget -O /usr/local/bin/hysteria "https://github.com/apernet/hysteria/releases/download/${LATEST_VERSION}/hysteria-linux-${HY_ARCH}"
chmod +x /usr/local/bin/hysteria

# 5. 配置生成
mkdir -p /etc/hysteria

if [[ "$MODE" == "self" ]]; then
    # === 自签配置 ===
    echo -e "${YELLOW}生成自签证书...${PLAIN}"
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=bing.com"
    
    cat <<EOF > /etc/hysteria/config.yaml
listen: :$PORT
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

else
    # === ACME 配置 ===
    echo -e "${YELLOW}配置内置 ACME...${PLAIN}"
    cat <<EOF > /etc/hysteria/config.yaml
server:
  listen: :$PORT
acme:
  domains:
    - $DOMAIN
  email: admin@$DOMAIN
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
fi

# 6. 服务管理
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

systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

# 7. 结果输出
PUBLIC_IP=$(curl -s4 ifconfig.me)
if [[ "$MODE" == "acme" ]]; then
    SERVER_HOST="$DOMAIN"
    INSECURE_NUM=0
    SNI_VAL="$DOMAIN"
else
    SERVER_HOST="$PUBLIC_IP"
    INSECURE_NUM=1
    SNI_VAL="bing.com"
fi

SHARE_LINK="hysteria2://${PASSWORD}@${SERVER_HOST}:${PORT}/?sni=${SNI_VAL}&insecure=${INSECURE_NUM}&name=Hy2-${MODE}"

echo -e ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}   Hysteria 2 (官方核) 部署成功!        ${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "模式       : ${YELLOW}${MODE}${PLAIN}"
echo -e "地址       : ${YELLOW}${SERVER_HOST}${PLAIN}"
echo -e "端口       : ${YELLOW}${PORT}${PLAIN}"
echo -e "密码       : ${YELLOW}${PASSWORD}${PLAIN}"
echo -e "----------------------------------------"
echo -e "🚀 [链接]: ${YELLOW}${SHARE_LINK}${PLAIN}"
echo -e "----------------------------------------"
