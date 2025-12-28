#!/bin/bash

# ============================================================
#  Cloudflare Tunnel 安装助手 (v5.6 终极优化版 - 2025.12.28)
#  - 自适应模式：ARGO_AUTH 存在 → 自动安装；否则 → 手动菜单
#  - 环境自检仅在安装时执行
#  - 统一安装路径 /usr/local/bin
#  - DNS 修复智能适配 IPv4/IPv6
#  - 只支持官方最新架构 (amd64/arm64)
#  - 卸载彻底 + 可选 DNS 恢复
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 检查 Root
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# ==========================================
# 0. 环境自检与修复 (仅安装时调用)
# ==========================================
check_and_fix_env() {
    echo -e "${YELLOW}>>> [自检] 正在检查网络环境与 DNS...${PLAIN}"
    
    local sites=("https://api.ipify.org" "https://ip.sb" "https://ifconfig.me")
    local ipv4_count=0
    for site in "${sites[@]}"; do
        if curl -4 -s --max-time 5 "$site" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            ((ipv4_count++))
        fi
    done
    
    if [[ $ipv4_count -ge 2 ]]; then
        IS_IPV6_ONLY=false
        echo -e "${GREEN}>>> 检测到有效 IPv4 环境。${PLAIN}"
    else
        IS_IPV6_ONLY=true
        echo -e "${YELLOW}>>> 检测到纯 IPv6 环境。${PLAIN}"
    fi

    if ! curl -s --connect-timeout 5 https://www.google.com >/dev/null 2>&1; then
        echo -e "${RED}>>> DNS 解析异常，正在应用临时修复...${PLAIN}"
        [[ ! -f /etc/resolv.conf.bak ]] && cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
        
        if [[ "$IS_IPV6_ONLY" == "true" ]]; then
            cat > /etc/resolv.conf << EOF
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1001
nameserver 2001:4860:4860::8844
EOF
        else
            cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF
        fi
        echo -e "${GREEN}>>> 临时 DNS 已设置（卸载时可自动恢复）${PLAIN}"
    fi
}

# ==========================================
# 1. 软件安装 (统一路径 /usr/local/bin)
# ==========================================
install_software() {
    check_and_fix_env

    echo -e "${GREEN}>>> 开始安装 Cloudflared (统一安装到 /usr/local/bin)...${PLAIN}"
    
    # 优先 APT（Debian/Ubuntu）
    if command -v apt-get &> /dev/null; then
        echo -e "${YELLOW}检测到 Debian 系统，使用 APT 官方源...${PLAIN}"
        mkdir -p --mode=0755 /usr/share/keyrings
        curl -fsSL --retry 3 https://pkg.cloudflare.com/cloudflare-public-v2.gpg | gpg --dearmor --yes -o /usr/share/keyrings/cloudflare-public-v2.gpg
        echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
        apt-get update
        apt-get install -y cloudflared
        # 移动到统一路径
        mv /usr/bin/cloudflared /usr/local/bin/cloudflared 2>/dev/null || true
    fi

    # 如果仍未安装成功，使用二进制
    if ! command -v /usr/local/bin/cloudflared &> /dev/null; then
        echo -e "${YELLOW}使用官方最新二进制安装...${PLAIN}"
        ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
        case $ARCH in
            amd64|x86_64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
            arm64|aarch64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
            *) echo -e "${RED}不支持的架构: $ARCH (仅支持 amd64/arm64)${PLAIN}"; exit 1 ;;
        esac
        wget -O /usr/local/bin/cloudflared "$CF_URL"
        chmod +x /usr/local/bin/cloudflared
    fi

    echo -e "${GREEN}cloudflared 版本: $($(readlink -f /usr/local/bin/cloudflared) --version)${PLAIN}"
}

# ==========================================
# 2. 卸载功能
# ==========================================
uninstall_tunnel() {
    echo -e "${YELLOW}>>> 开始卸载 Cloudflare Tunnel...${PLAIN}"
    
    systemctl stop cloudflared 2>/dev/null
    systemctl disable cloudflared 2>/dev/null
    cloudflared service uninstall >/dev/null 2>&1
    rm -f /etc/systemd/system/cloudflared.service
    rm -rf /etc/cloudflared
    rm -f /usr/local/bin/cloudflared
    rm -f /etc/apt/sources.list.d/cloudflared.list
    apt-get remove --purge cloudflared -y 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    systemctl daemon-reload
    
    # 可选恢复 DNS
    if [[ -f /etc/resolv.conf.bak ]]; then
        mv /etc/resolv.conf.bak /etc/resolv.conf
        echo -e "${GREEN}已恢复原 DNS 配置${PLAIN}"
    fi
    
    echo -e "${GREEN}Cloudflare Tunnel 已完全卸载。${PLAIN}"
    exit 0
}

# ==========================================
# 3. 配置与服务注入
# ==========================================
configure_tunnel() {
    local TOKEN="${ARGO_AUTH:-$TOKEN}"
    if [[ -z "$TOKEN" ]]; then
        echo -e "\n${YELLOW}--- 配置 Tunnel ---${PLAIN}"
        read -p "请输入您的 Tunnel Token: " TOKEN
    fi
    [[ -z "$TOKEN" ]] && echo -e "${RED}未输入 Token，退出。${PLAIN}" && exit 0

    rm -rf /etc/cloudflared
    cloudflared service uninstall >/dev/null 2>&1
    systemctl stop cloudflared 2>/dev/null
    rm -f /etc/systemd/system/cloudflared.service

    local EXEC_ARGS="tunnel --no-autoupdate run --token $TOKEN"
    local DESC_SUFFIX=""

    if [[ "$IS_IPV6_ONLY" == "true" ]]; then
        echo -e "${YELLOW}纯 IPv6 环境，强制使用 IPv6 + HTTP2 协议${PLAIN}"
        EXEC_ARGS="tunnel --no-autoupdate --edge-ip-version 6 --protocol http2 run --token $TOKEN"
        DESC_SUFFIX=" (IPv6 Optimized)"
    fi

    cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=cloudflared${DESC_SUFFIX}
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart=/usr/local/bin/cloudflared $EXEC_ARGS
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cloudflared >/dev/null 2>&1
    systemctl restart cloudflared
    
    sleep 5
    if systemctl is-active --quiet cloudflared; then
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${GREEN}    Cloudflare Tunnel 启动成功！        ${PLAIN}"
        [[ "$IS_IPV6_ONLY" == "true" ]] && echo -e "${SKYBLUE}    [IPv6 + HTTP2 优化已启用]           ${PLAIN}"
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${YELLOW}验证命令：${PLAIN}"
        echo "  journalctl -u cloudflared -f"
        echo "  cloudflared tunnel list"
    else
        echo -e "${RED}启动失败，请查看日志：journalctl -u cloudflared -e${PLAIN}"
        exit 1
    fi
}

# ==========================================
# 执行入口：自适应模式
# ==========================================
if [[ -n "$ARGO_AUTH" ]]; then
    # 自动模式（auto_deploy.sh 调用）
    install_software
    configure_tunnel
else
    # 手动模式（menu.sh 或直接运行）
    echo -e "${GREEN}=== Cloudflare Tunnel 管理助手 ===${PLAIN}"
    echo "1. 安装/更新 Tunnel"
    echo "2. 卸载 Tunnel"
    echo "0. 退出"
    read -p "请选择 [0-2]: " choice
    case "$choice" in
        1) install_software && configure_tunnel ;;
        2) uninstall_tunnel ;;
        *) exit 0 ;;
    esac
fi
