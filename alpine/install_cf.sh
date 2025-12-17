#!/bin/sh

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Cloudflare Tunnel Alpine 安装脚本 ===${NC}"

# 1. 检查是否为 Root 用户
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 用户运行此脚本。${NC}"
    exit 1
fi

# 2. 获取用户 Token
echo ""
echo -e "${YELLOW}请粘贴您的 Cloudflare Tunnel Token (以 eyJh 开头的长字符串):${NC}"
printf "Token: "
read -r CF_TOKEN

if [ -z "$CF_TOKEN" ]; then
    echo -e "${RED}错误：Token 不能为空！${NC}"
    exit 1
fi

# 3. 检测系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        DOWNLOAD_ARCH="amd64"
        ;;
    aarch64|armv8*)
        DOWNLOAD_ARCH="arm64"
        ;;
    armv7*)
        DOWNLOAD_ARCH="arm"
        ;;
    x86)
        DOWNLOAD_ARCH="386"
        ;;
    *)
        echo -e "${RED}不支持的架构: $ARCH${NC}"
        exit 1
        ;;
esac

echo -e "${GREEN}检测到系统架构: $ARCH (下载版本: $DOWNLOAD_ARCH)${NC}"

# 4. 安装依赖 (libc6-compat 是必须的)
echo -e "${YELLOW}正在安装必要的依赖 (curl, libc6-compat)...${NC}"
apk add --no-cache curl libc6-compat

# 5. 下载 Cloudflared
echo -e "${YELLOW}正在下载 cloudflared 二进制文件...${NC}"
if curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$DOWNLOAD_ARCH" -o /usr/bin/cloudflared; then
    chmod +x /usr/bin/cloudflared
    echo -e "${GREEN}下载成功！${NC}"
else
    echo -e "${RED}下载失败，请检查网络连接。${NC}"
    exit 1
fi

# 6. 创建 OpenRC 服务文件
echo -e "${YELLOW}正在配置 OpenRC 服务...${NC}"

cat > /etc/init.d/cloudflared <<EOF
#!/sbin/openrc-run

name="cloudflared"
description="Cloudflare Tunnel Agent"
command="/usr/bin/cloudflared"
command_args="tunnel run --token $CF_TOKEN"
command_background=true
pidfile="/run/cloudflared.pid"
output_log="/var/log/cloudflared.log"
error_log="/var/log/cloudflared.err"

depend() {
    need net
    after firewall
}
EOF

# 赋予服务脚本执行权限
chmod +x /etc/init.d/cloudflared

# 7. 启动服务并设置开机自启
echo -e "${YELLOW}正在启动服务...${NC}"
rc-update add cloudflared default
rc-service cloudflared restart

# 8. 检查状态
echo ""
if rc-service cloudflared status | grep -q "started"; then
    echo -e "${GREEN}✅ 安装成功！Cloudflared 正在运行。${NC}"
    echo -e "日志文件位置: /var/log/cloudflared.log"
    echo -e "请回到 Cloudflare 面板查看连接状态。"
else
    echo -e "${RED}❌ 服务启动似乎遇到了问题，请检查日志：${NC}"
    echo "tail -n 20 /var/log/cloudflared.err"
fi
