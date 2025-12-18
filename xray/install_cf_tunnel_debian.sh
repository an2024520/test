#!/bin/bash

# ============================================================
#  Cloudflare Tunnel 安装助手 (Debian/Ubuntu 版)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 检查 Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

echo -e "${GREEN}正在安装 Cloudflare Tunnel (cloudflared)...${PLAIN}"

# 2. 架构检测与下载
ARCH=$(dpkg --print-architecture)
case $ARCH in
    amd64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    arm64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac

echo -e "${YELLOW}正在下载 cloudflared ($ARCH)...${PLAIN}"
wget -O /usr/local/bin/cloudflared "$CF_URL"
chmod +x /usr/local/bin/cloudflared

# 3. 验证安装
if ! command -v cloudflared &> /dev/null; then
    echo -e "${RED}下载失败，请检查网络连接。${PLAIN}"
    exit 1
fi

VERSION=$(cloudflared --version)
echo -e "${GREEN}安装成功: $VERSION${PLAIN}"

# 4. 配置向导
echo -e ""
echo -e "${YELLOW}--- 配置 Tunnel ---${PLAIN}"
echo -e "请在 Cloudflare Zero Trust 后台创建一个 Tunnel，并复制安装命令中的 Token。"
echo -e "命令格式通常为: cloudflared service install <token>"
echo -e ""
read -p "请输入您的 Tunnel Token (长字符串): " TOKEN

if [[ -z "$TOKEN" ]]; then
    echo -e "${RED}未输入 Token，仅安装了二进制文件。${PLAIN}"
    echo -e "您可以稍后运行: cloudflared service install <your-token>"
    exit 0
fi

# 5. 安装并启动服务
echo -e "${YELLOW}正在注册系统服务...${PLAIN}"
cloudflared service install "$TOKEN"

echo -e "${YELLOW}正在启动服务...${PLAIN}"
systemctl start cloudflared
systemctl enable cloudflared

if systemctl is-active --quiet cloudflared; then
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    Cloudflare Tunnel 启动成功！        ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "现在您可以使用 [模块九] 添加节点，并将端口映射到 Tunnel 中。"
else
    echo -e "${RED}服务启动失败！请检查 Token 是否正确。${PLAIN}"
fi
