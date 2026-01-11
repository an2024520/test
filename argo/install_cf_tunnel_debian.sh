#!/bin/bash

# ============================================================
#  Cloudflare Tunnel 安装助手 (v5.8 Logic Fix - 2025.01.07)
#  - 修复: 增加 GPG 依赖补全 (gnupg/curl)
#  - 优化: 增加 APT 源清理与智能回退机制
#  - 保持: 原有环境自检与 DNS 修复逻辑不变
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
    
    local apt_success="false"

    # 优先 APT（Debian/Ubuntu）
    if command -v apt-get &> /dev/null; then
        echo -e "${YELLOW}检测到 Debian 系统，准备配置环境...${PLAIN}"
        
        # [Step 1] 清理潜在的坏源，防止 apt update 报错 (解开死锁)
        rm -f /etc/apt/sources.list.d/cloudflared.list
        
        # [Step 2] 补全系统依赖 (GPG 工具)
        echo -e "正在补全 GPG 依赖..."
        apt-get update -y
        apt-get install -y gnupg curl ca-certificates

        # [Step 3] 尝试导入 Key 并智能判断
        mkdir -p --mode=0755 /usr/share/keyrings
        # 使用 && 逻辑确保只有 Key 下载成功才继续
        if curl -fsSL --retry 3 https://pkg.cloudflare.com/cloudflare-public-v2.gpg | gpg --dearmor --yes -o /usr/share/keyrings/cloudflare-public-v2.gpg; then
            echo -e "${GREEN}GPG Key 导入成功，添加官方源...${PLAIN}"
            echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list > /dev/null
            
            if apt-get update && apt-get install -y cloudflared; then
                # 移动到统一路径
                mv /usr/bin/cloudflared /usr/local/bin/cloudflared 2>/dev/null || true
                apt_success="true"
            else
                echo -e "${RED}APT 安装过程失败，清理源文件...${PLAIN}"
                rm -f /etc/apt/sources.list.d/cloudflared.list
            fi
        else
            echo -e "${RED}无法连接 Cloudflare GPG 地址，跳过 APT 模式...${PLAIN}"
            # 确保不残留坏文件
            rm -f /etc/apt/sources.list.d/cloudflared.list
        fi
    fi

    # 二进制兜底安装 (APT 失败或非 Debian 系统时执行)
    if [[ "$apt_success" != "true" ]] || ! command -v /usr/local/bin/cloudflared &> /dev/null; then
        echo -e "${YELLOW}正在使用官方二进制直接安装...${PLAIN}"
        ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
        case $ARCH in
            amd64|x86_64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
            arm64|aarch64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
            *) echo -e "${RED}不支持的架构: $ARCH (仅支持 amd64/arm64)${PLAIN}"; exit 1 ;;
        esac
        
        if wget -O /usr/local/bin/cloudflared "$CF_URL"; then
            chmod +x /usr/local/bin/cloudflared
        else
            echo -e "${RED}二进制文件下载失败！请检查网络。${PLAIN}"
            exit 1
        fi
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
    
    # [新增] 彻底清理 APT 源文件
    rm -f /etc/apt/sources.list.d/cloudflared.list
    
    apt-get remove --purge cloudflared -y 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    systemctl daemon-reload
    
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
    # 手动模式
    echo -e "${GREEN}=== Cloudflare Tunnel 管理助手 (Fixed) ===${PLAIN}"
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

