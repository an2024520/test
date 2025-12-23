#!/bin/bash

# ============================================================
#  Cloudflare Tunnel 安装助手 (v3.1 完美复刻版)
#  - 模式 1: 官方 APT 源 (推荐，自动更新，校验完整)
#  - 模式 2: GitHub 二进制 (通用，无需添加源，适合纯净强迫症)
#  - 特性: 集成 IPv6 环境自动修复 (Auto-Fix IPv6)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

# 2. 收集 Token
echo -e "${GREEN}>>> Cloudflare Tunnel 部署向导${PLAIN}"
read -p "请输入 Cloudflare Tunnel Token (必填): " CF_TOKEN

if [[ -z "$CF_TOKEN" ]]; then
    echo -e "${RED}错误: Token 不能为空！${PLAIN}"
    exit 1
fi

# 3. 选择安装模式 (找回丢失的架构)
echo -e "${YELLOW}------------------------------------------------${PLAIN}"
echo -e "${YELLOW}请选择 Cloudflared 安装方式:${PLAIN}"
echo -e "  1. ${GREEN}官方 APT 仓库${PLAIN} (推荐，支持 apt upgrade 自动更新)"
echo -e "  2. ${GREEN}GitHub 二进制${PLAIN} (纯净模式，手动管理，不修改源)"
echo -e "${YELLOW}------------------------------------------------${PLAIN}"
read -p "请选择 [1-2] (默认 1): " INSTALL_MODE
[[ -z "$INSTALL_MODE" ]] && INSTALL_MODE=1

# 清理旧版本
if command -v cloudflared &> /dev/null; then
    echo -e "${YELLOW}检测到旧版本，正在停止服务并清理...${PLAIN}"
    systemctl stop cloudflared 2>/dev/null
    cloudflared service uninstall 2>/dev/null
    rm -f /usr/bin/cloudflared /usr/local/bin/cloudflared
fi

# 执行安装逻辑
if [[ "$INSTALL_MODE" == "1" ]]; then
    # === 模式 1: APT 安装 ===
    echo -e "${GREEN}>>> 正在添加 Cloudflare 官方 GPG 密钥与源...${PLAIN}"
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
    
    echo -e "${GREEN}>>> 更新源并安装...${PLAIN}"
    apt-get update && apt-get install -y cloudflared

elif [[ "$INSTALL_MODE" == "2" ]]; then
    # === 模式 2: 二进制安装 ===
    echo -e "${GREEN}>>> 正在从 GitHub 下载最新二进制文件...${PLAIN}"
    ARCH=$(dpkg --print-architecture)
    if [[ "$ARCH" == "amd64" ]]; then
        curl -L --output cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    elif [[ "$ARCH" == "arm64" ]]; then
        curl -L --output cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64
    else
        echo -e "${RED}不支持的架构: $ARCH${PLAIN}"
        exit 1
    fi
    
    chmod +x cloudflared
    mv cloudflared /usr/bin/cloudflared
fi

# 二次验证
if ! command -v cloudflared &> /dev/null; then
    echo -e "${RED}安装失败！未找到 cloudflared 命令。${PLAIN}"
    exit 1
fi

# 4. 智能环境检测 (这是你刚才要求新增的功能，完美融入)
# ------------------------------------------------
echo -e "${YELLOW}正在检测网络环境...${PLAIN}"

EXTRA_ARGS=""

# 检测 IPv4 连通性
if curl -4 -s --connect-timeout 3 https://1.1.1.1 >/dev/null; then
    echo -e "网络环境: ${GREEN}IPv4/Dual-Stack (标准模式)${PLAIN}"
else
    echo -e "网络环境: ${YELLOW}IPv6-Only (增强模式)${PLAIN}"
    echo -e "${GREEN}>>> 已自动启用 IPv6 专用参数 (--edge-ip-version 6 --protocol http2)${PLAIN}"
    EXTRA_ARGS="--edge-ip-version 6 --protocol http2"
fi
# ------------------------------------------------

# 5. 配置 Systemd 服务
echo -e "${YELLOW}正在配置系统服务...${PLAIN}"

# 手动写入 Service 文件 (确保参数生效)
cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=cloudflared
After=network.target

[Service]
TimeoutStartSec=0
Type=notify
User=root
# 动态注入 EXTRA_ARGS 参数
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate $EXTRA_ARGS run --token $CF_TOKEN
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# 6. 启动服务
systemctl daemon-reload
systemctl enable cloudflared
systemctl restart cloudflared

echo -e "------------------------------------------------"
sleep 2
if systemctl is-active --quiet cloudflared; then
    echo -e "${GREEN}Cloudflare Tunnel 部署成功！${PLAIN}"
    echo -e "安装模式: ${YELLOW}$([[ "$INSTALL_MODE" == "1" ]] && echo "APT源" || echo "二进制")${PLAIN}"
    echo -e "运行状态: ${GREEN}Active (Running)${PLAIN}"
    if [[ -n "$EXTRA_ARGS" ]]; then
        echo -e "IPv6补丁: ${YELLOW}已启用${PLAIN}"
    fi
else
    echo -e "${RED}服务启动失败！请检查日志: journalctl -u cloudflared -e${PLAIN}"
fi
echo -e "------------------------------------------------"
