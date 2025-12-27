#!/bin/sh

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}=== Alpine Sing-box (Tunnel 后端) 安装脚本 ===${NC}"

# 1. 检查 Root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行！${NC}"
    exit 1
fi

# 2. 安装依赖
echo -e "${YELLOW}安装依赖 (curl, tar, jq, uuidgen)...${NC}"
apk update
apk add --no-cache curl tar jq util-linux ca-certificates

# 3. 架构检测
ARCH=$(uname -m)
case $ARCH in
    x86_64)  SB_ARCH="amd64" ;;
    aarch64) SB_ARCH="arm64" ;;
    armv7*)  SB_ARCH="armv7" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

# 4. 获取 Sing-box 最新版本
echo -e "${YELLOW}正在检查 Sing-box 最新版本...${NC}"
LATEST_URL=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r ".assets[] | select(.name | contains(\"linux-$SB_ARCH.tar.gz\")) | .browser_download_url")

if [ -z "$LATEST_URL" ]; then
    echo -e "${RED}获取下载链接失败，可能是 Github API 限制或网络问题。${NC}"
    exit 1
fi

# 5. 下载并安装
echo -e "${YELLOW}正在下载 Sing-box...${NC}"
rm -rf /tmp/sing-box*
curl -L -o /tmp/sing-box.tar.gz "$LATEST_URL"

echo -e "${YELLOW}正在解压安装...${NC}"
tar -xzf /tmp/sing-box.tar.gz -C /tmp
# 移动二进制文件
mv /tmp/sing-box-*/sing-box /usr/local/bin/sing-box
chmod +x /usr/local/bin/sing-box
rm -rf /tmp/sing-box*

# 6. 配置参数
echo ""
echo -e "${CYAN}--- 配置节点信息 ---${NC}"
read -p "请输入本地监听端口 [默认: 10010]: " PORT
PORT=${PORT:-10010}

read -p "请输入 WebSocket 路径 [默认: /sing]: " WSPATH
WSPATH=${WSPATH:-/sing}
# 确保路径以 / 开头
case "$WSPATH" in
    /*) ;;
    *) WSPATH="/$WSPATH" ;;
esac

# 生成 UUID
UUID=$(uuidgen)

# 7. 写入配置文件
CONF_DIR="/etc/sing-box"
mkdir -p "$CONF_DIR"

cat > "$CONF_DIR/config.json" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "name": "tunnel-user"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$WSPATH"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

# 8. 创建 OpenRC 服务 (Alpine 专用)
cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Platform"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"

depend() {
    need net
    after firewall
}
EOF

chmod +x /etc/init.d/sing-box

# 9. 启动服务
echo -e "${YELLOW}启动 Sing-box 服务...${NC}"
rc-update add sing-box default
rc-service sing-box restart

# 10. 生成客户端配置信息
DOMAIN_PLACEHOLDER="你的CF域名"

echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}      Sing-box 安装成功 (Tunnel 后端)         ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo ""
echo -e "${YELLOW}👉 1. Cloudflare Tunnel 设置 (在 CF 后台填写):${NC}"
echo -e "   - Service Type : HTTP"
echo -e "   - URL          : localhost:${PORT}"
echo ""
echo -e "${YELLOW}👉 2. 客户端 (v2rayN/Clash) 填写的配置:${NC}"
echo -e "   - 地址 (Address) : ${CYAN}www.visa.com.sg${NC} (优选IP域名)"
echo -e "   - 端口 (Port)    : ${CYAN}443${NC}"
echo -e "   - 用户ID (UUID)  : ${CYAN}${UUID}${NC}"
echo -e "   - 传输协议       : ${CYAN}ws${NC}"
echo -e "   - 伪装域名/Host  : ${CYAN}${DOMAIN_PLACEHOLDER}${NC}"
echo -e "   - 路径 (Path)    : ${CYAN}${WSPATH}${NC}"
echo -e "   - TLS            : ${CYAN}开启 (tls)${NC}"
echo -e "   - 跳过证书验证   : ${CYAN}true/开启${NC}"
echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "提示：此配置完全独立，删除 icmp9 脚本不会影响此服务。"
