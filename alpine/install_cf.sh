#!/bin/sh

# ============================================================
#  Cloudflare Tunnel Alpine 安装助手 (双核版)
#  - 模式 1: 官方 APK 源 (强烈推荐！走 CF 自家线路，适合 IPv6)
#  - 模式 2: GitHub 二进制 (备用，依赖 GitHub 网络)
# ============================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
SKYBLUE='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Cloudflare Tunnel Alpine 部署脚本 ===${NC}"

# 1. 检查 Root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 用户运行此脚本。${NC}"
    exit 1
fi

# 2. 安装基础依赖
# curl 用于下载，libc6-compat 用于让二进制兼容 Alpine 的 musl 库
echo -e "${YELLOW}正在检查并安装基础依赖 (curl, libc6-compat)...${NC}"
apk add --no-cache curl libc6-compat ca-certificates

# ==========================================
# 核心函数定义
# ==========================================

# --- 方式一：APK 官方源安装 (推荐) ---
install_via_apk() {
    echo -e "${GREEN}>>> 正在使用 [官方 APK 源] 模式安装...${PLAIN}"
    echo -e "${YELLOW}此模式使用 Cloudflare 自家 CDN，连接速度通常最快。${NC}"

    # 1. 下载 Cloudflare 的 RSA 签名公钥
    echo -e "${YELLOW}1. 添加 GPG 签名密钥...${NC}"
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.rsa.pub -o /etc/apk/keys/cloudflare-main.rsa.pub
    
    if [ ! -f "/etc/apk/keys/cloudflare-main.rsa.pub" ]; then
        echo -e "${RED}密钥下载失败，请检查网络连接。${NC}"
        return 1
    fi

    # 2. 添加软件源
    # 注意：这里使用 edge 分支以获取最新版，通常兼容性最好
    echo -e "${YELLOW}2. 添加 Cloudflare 仓库...${NC}"
    echo 'https://pkg.cloudflare.com/cloudflared/alpine/edge/main' > /etc/apk/repositories.d/cloudflared.repo
    
    # 3. 更新并安装
    echo -e "${YELLOW}3. 更新源并安装 cloudflared...${NC}"
    apk update && apk add cloudflared

    # 验证安装
    if command -v cloudflared >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# --- 方式二：GitHub 二进制安装 (备用) ---
install_via_github() {
    echo -e "${GREEN}>>> 正在使用 [GitHub 二进制] 模式安装...${NC}"
    
    # 架构检测
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  DOWNLOAD_ARCH="amd64" ;;
        aarch64|armv8*) DOWNLOAD_ARCH="arm64" ;;
        armv7*)  DOWNLOAD_ARCH="arm" ;;
        x86)     DOWNLOAD_ARCH="386" ;;
        *)
            echo -e "${RED}不支持的架构: $ARCH${NC}"
            return 1
            ;;
    esac

    echo -e "${YELLOW}检测到架构: $ARCH (下载版本: $DOWNLOAD_ARCH)${NC}"
    
    # 删除旧文件
    rm -f /usr/bin/cloudflared
    
    # 下载
    # 提示：如果 Github 慢，这里是最容易失败的地方
    if curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$DOWNLOAD_ARCH" -o /usr/bin/cloudflared; then
        chmod +x /usr/bin/cloudflared
        return 0
    else
        echo -e "${RED}GitHub 下载失败，请尝试使用模式 1。${NC}"
        return 1
    fi
}

# --- 配置服务 (OpenRC) ---
configure_service() {
    echo ""
    echo -e "${YELLOW}--- 配置 Tunnel ---${NC}"
    
    # 获取 Token (如果之前没输入)
    if [ -z "$CF_TOKEN" ]; then
        echo -e "${YELLOW}请粘贴您的 Cloudflare Tunnel Token (以 eyJh 开头的长字符串):${NC}"
        printf "Token: "
        read -r CF_TOKEN
    fi

    if [ -z "$CF_TOKEN" ]; then
        echo -e "${RED}错误：Token 不能为空！${NC}"
        exit 1
    fi

    echo -e "${YELLOW}正在配置 OpenRC 服务脚本...${NC}"

    # 无论用哪种方式安装，我们都重写 init 脚本以确保参数正确
    # 注意：APK 安装可能会自动创建一个默认的 init 脚本，我们这里覆盖它以适配 Token 模式
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

    chmod +x /etc/init.d/cloudflared

    # 启动服务
    echo -e "${YELLOW}正在启动服务...${NC}"
    if rc-service cloudflared restart; then
        rc-update add cloudflared default >/dev/null 2>&1
        echo -e "${GREEN}✅ 安装并启动成功！${NC}"
        echo -e "日志位置: /var/log/cloudflared.log"
    else
        echo -e "${RED}❌ 服务启动失败，请检查日志。${NC}"
        echo "查看命令: tail -n 20 /var/log/cloudflared.err"
    fi
}

# ==========================================
# 主逻辑
# ==========================================

clear
echo -e "${GREEN}Cloudflare Tunnel 安装向导 (Alpine版)${NC}"
echo -e "----------------------------------------"
echo -e "检测到您的系统为 Alpine Linux。"
echo -e "鉴于您的网络环境 (IPv6 Only)，强烈建议选择选项 1。"
echo -e ""
echo -e "${SKYBLUE}1.${NC} 官方 APK 源安装 ${YELLOW}(强烈推荐)${NC}"
echo -e "   - 优势: 走 Cloudflare 自家线路，无需访问 GitHub，更新方便"
echo -e ""
echo -e "${SKYBLUE}2.${NC} GitHub 二进制安装"
echo -e "   - 劣势: 需要连接 GitHub，可能因网络问题下载失败"
echo -e "----------------------------------------"
printf "请输入选项 [1-2] (默认1): "
read -r install_choice
install_choice=${install_choice:-1}

# 提前询问 Token，避免安装一半卡住
echo ""
echo -e "${YELLOW}为了配置服务，请现在粘贴您的 Tunnel Token:${NC}"
printf "Token: "
read -r CF_TOKEN

case "$install_choice" in
    1)
        if install_via_apk; then
            configure_service
        else
            echo -e "${RED}APK 安装失败，请检查网络或尝试模式 2。${NC}"
        fi
        ;;
    2)
        if install_via_github; then
            configure_service
        else
            echo -e "${RED}二进制安装失败。${NC}"
        fi
        ;;
    *)
        echo -e "${RED}无效输入，退出。${NC}"
        exit 1
        ;;
esac
