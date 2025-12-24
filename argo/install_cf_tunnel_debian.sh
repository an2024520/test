#!/bin/bash

# ============================================================
#  Cloudflare Tunnel 安装助手 (v5.3 Strict Pure)
#  - 核心原则: 独立运行，不依赖 menu.sh，自动修复网络环境
#  - 增强功能: 严格 IPv4 检测 + 纯净 GitHub 链接 + Systemd 规范
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查 Root
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# ==========================================
# 0. 环境自检与修复 (独立性保障)
# ==========================================
check_and_fix_env() {
    echo -e "${YELLOW}>>> [自检] 正在检查网络环境与 DNS (Strict Mode)...${PLAIN}"
    
    # 1. 严格 IPv4 检测 (尝试获取公网 IPv4)
    # -m 5: 超时 5 秒
    local ipv4_check=$(curl -4 -s -m 5 http://ip.sb 2>/dev/null)
    
    if [[ "$ipv4_check" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        IS_IPV6_ONLY=false
        echo -e "${GREEN}>>> 检测到有效 IPv4 环境。${PLAIN}"
    else
        IS_IPV6_ONLY=true
        echo -e "${YELLOW}>>> 检测到纯 IPv6 环境 (无法获取 IPv4)${PLAIN}"
    fi

    # 2. DNS 连通性测试 (尝试解析 Google)
    if ! curl -s --connect-timeout 3 https://www.google.com >/dev/null 2>&1; then
        echo -e "${RED}>>> 检测到 DNS 解析异常 (可能未运行 menu.sh)${PLAIN}"
        echo -e "${YELLOW}>>> 正在应用临时 DNS 修复 (Google/CF IPv6)...${PLAIN}"
        
        # 备份原 DNS
        [[ ! -f /etc/resolv.conf.bak ]] && cp /etc/resolv.conf /etc/resolv.conf.bak
        
        # 写入稳健的 IPv6 DNS
        chattr -i /etc/resolv.conf >/dev/null 2>&1
        cat > /etc/resolv.conf << EOF
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8844
nameserver 2606:4700:4700::1001
EOF
        # 锁定以防止被 DHCP 覆盖，保证隧道重启后也能连网
        chattr +i /etc/resolv.conf >/dev/null 2>&1
        echo -e "${GREEN}>>> DNS 修复完成，网络已恢复。${PLAIN}"
    else
        echo -e "${GREEN}>>> 网络连接正常。${PLAIN}"
    fi
}

# ==========================================
# 1. 软件安装 (兼容性保障)
# ==========================================
install_software() {
    echo -e "${GREEN}>>> 开始安装 Cloudflared...${PLAIN}"
    
    # 优先尝试 APT/YUM 官方源 (更安全，方便更新)
    if command -v apt-get &> /dev/null; then
        echo -e "${YELLOW}使用 APT 官方源安装...${PLAIN}"
        mkdir -p --mode=0755 /usr/share/keyrings
        rm -f /usr/share/keyrings/cloudflare-public-v2.gpg
        curl -fsSL --retry 3 --connect-timeout 10 https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
        echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
        apt-get update
        apt-get install -y cloudflared
    else
        # 回退到二进制安装
        echo -e "${YELLOW}非 Debian 系统，使用二进制安装...${PLAIN}"
        ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
        case $ARCH in
            amd64|x86_64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
            arm64|aarch64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
            *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return 1 ;;
        esac
        # 纯净 GitHub 链接，不使用代理
        wget -O /usr/bin/cloudflared "$CF_URL"
        chmod +x /usr/bin/cloudflared
    fi

    if ! command -v cloudflared &> /dev/null; then
        echo -e "${RED}安装失败：无法获取 cloudflared。${PLAIN}"
        exit 1
    fi
}

# ==========================================
# 2. 配置与服务注入 (核心逻辑)
# ==========================================
configure_tunnel() {
    # 获取 Token
    local TOKEN="${ARGO_AUTH:-$TOKEN}"
    if [[ -z "$TOKEN" ]]; then
        echo -e "\n${YELLOW}--- 配置 Tunnel ---${PLAIN}"
        read -p "请输入您的 Tunnel Token: " TOKEN
    fi
    [[ -z "$TOKEN" ]] && echo -e "${RED}未输入 Token，退出。${PLAIN}" && exit 0

    # 清理旧服务
    echo -e "${YELLOW}正在注册系统服务...${PLAIN}"
    cloudflared service uninstall >/dev/null 2>&1
    systemctl stop cloudflared 2>/dev/null

    # --- 关键分支：生成 Service 文件 ---
    # 我们使用官方模板的强化版：保留 notify 和 network-online，注入 IPv6 优化参数
    
    # 基础参数
    local EXEC_ARGS="tunnel --no-autoupdate run --token $TOKEN"
    local DESC_SUFFIX=""

    if [[ "$IS_IPV6_ONLY" == "true" ]]; then
        echo -e "${YELLOW}检测到 IPv6-Only 环境，注入 HTTP2 + IPv6 强制参数...${PLAIN}"
        # 注入魔改参数
        EXEC_ARGS="tunnel --no-autoupdate --edge-ip-version 6 --protocol http2 run --token $TOKEN"
        DESC_SUFFIX=" (IPv6 Optimized)"
    else
        echo -e "${GREEN}检测到标准 IPv4 环境，使用标准参数...${PLAIN}"
    fi

    # 写入 Systemd 文件 (这是最完美的写法)
    cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=cloudflared${DESC_SUFFIX}
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart=/usr/bin/cloudflared $EXEC_ARGS
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cloudflared >/dev/null 2>&1
    systemctl restart cloudflared
    
    echo -e "${YELLOW}等待服务启动...${PLAIN}"
    sleep 3
    
    if systemctl is-active --quiet cloudflared; then
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${GREEN}    Cloudflare Tunnel 启动成功！        ${PLAIN}"
        if [[ "$IS_IPV6_ONLY" == "true" ]]; then
            echo -e "${SKYBLUE}    [已应用 IPv6/HTTP2 协议锁定]        ${PLAIN}"
        fi
        echo -e "${GREEN}========================================${PLAIN}"
    else
        echo -e "${RED}服务启动失败，请检查 Token 或日志。${PLAIN}"
        exit 1
    fi
}

# ==========================================
# 执行入口
# ==========================================
check_and_fix_env
install_software
configure_tunnel
