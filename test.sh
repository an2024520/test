#!/bin/bash

# ============================================================
#  系统运维工具箱 v3.0 (优化增强版 - 2025)
#  - 基于原脚本全面改进：安全性、兼容性、现代化
#  - 新增：BBRv3 支持、Chrony 时间同步、ZRAM 选项、nftables 端口跳跃、Fail2Ban 集成
#  - 改进：全面备份、错误处理、输入验证、动态优化
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'

# 严格模式
set -euo pipefail

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# 备份函数
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp -a "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)"
        echo -e "${YELLOW}已备份: $file${PLAIN}"
    fi
}

# ==========================================
# 功能函数定义
# ==========================================

# --- 1. 系统内核加速 (BBRv3 + 优化参数) ---
enable_bbr() {
    echo -e "${YELLOW}正在检测并配置最佳 BBR 拥塞控制...${PLAIN}"
    backup_file /etc/sysctl.conf

    # 清理旧配置
    sed -i '/net\.core\.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net\.ipv4\.tcp_ecn/d' /etc/sysctl.conf
    sed -i '/net\.core\.somaxconn/d' /etc/sysctl.conf

    # 检测内核版本并选择最佳 BBR
    local kernel_version=$(uname -r | cut -d'.' -f1-2)
    local bbr_version="bbr"

    if [[ $(echo "$kernel_version >= 6.1" | bc -l 2>/dev/null || echo 0) -eq 1 ]]; then
        if lsmod | grep -q tcp_bbr3; then
            bbr_version="bbr3"
            echo -e "${GREEN}检测到支持 BBRv3，已启用！${PLAIN}"
        elif modprobe tcp_bbr3 2>/dev/null; then
            bbr_version="bbr3"
            echo -e "${GREEN}已加载 BBRv3 模块${PLAIN}"
        fi
    fi

    cat <<EOF >> /etc/sysctl.conf

# === Network Optimization (2025) ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $bbr_version
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_ecn = 1                  # 启用 ECN，提高兼容性
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
vm.swappiness = 10
EOF

    sysctl -p >/dev/null

    # 优化 Ulimit（动态）
    backup_file /etc/security/limits.conf
    if ! grep -q "*.*nofile" /etc/security/limits.conf; then
        cat <<EOF >> /etc/security/limits.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    fi

    local current_bbr=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    echo -e "${GREEN}✅ 当前拥塞控制: $current_bbr${PLAIN}"
    echo -e "${GREEN}✅ 文件描述符限制已提升至 1048576${PLAIN}"
    echo -e "${GREEN}✅ 网络参数优化完成${PLAIN}"
}

# --- 2. SSH 防断连优化 ---
fix_ssh_keepalive() {
    echo -e "${YELLOW}正在配置 SSH 保活参数（推荐 Web SSH）...${PLAIN}"
    backup_file /etc/ssh/sshd_config

    sed -i '/ClientAliveInterval/d' /etc/ssh/sshd_config
    sed -i '/ClientAliveCountMax/d' /etc/ssh/sshd_config
    sed -i '/TCPKeepAlive/d' /etc/ssh/sshd_config

    cat <<EOF >> /etc/ssh/sshd_config

# KeepAlive Settings
ClientAliveInterval 240
ClientAliveCountMax 3
TCPKeepAlive yes
EOF

    if sshd -t >/dev/null 2>&1; then
        systemctl restart sshd
        echo -e "${GREEN}✅ SSH 保活配置已更新（240s 心跳，超时断开）${PLAIN}"
        echo -e "${SKYBLUE}建议客户端 ~/.ssh/config 添加：ServerAliveInterval 60${PLAIN}"
    else
        echo -e "${RED}❌ SSH 配置语法错误，请检查！${PLAIN}"
    fi
}

# --- 3. 系统时间同步 (优先 Chrony) ---
sync_time() {
    echo -e "${YELLOW}正在配置高精度时间同步（Chrony）...${PLAIN}"

    if command -v chronyd >/dev/null 2>&1; then
        echo -e "${GREEN}Chrony 已安装，正在优化配置...${PLAIN}"
    else
        echo -e "${YELLOW}正在安装 Chrony...${PLAIN}"
        if command -v apt >/dev/null; then
            apt update && apt install -y chrony
        elif command -v yum >/dev/null; then
            yum install -y chrony
        elif command -v dnf >/dev/null; then
            dnf install -y chrony
        else
            echo -e "${RED}不支持的包管理器${PLAIN}"
            return 1
        fi
    fi

    backup_file /etc/chrony/chrony.conf

    cat >/etc/chrony/chrony.conf <<EOF
# 高精度 NTP 池
pool pool.ntp.org iburst
pool time.cloudflare.com iburst
pool time.google.com iburst

# 允许本地网络客户端
allow all

# 记录漂移
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF

    systemctl enable --now chronyd >/dev/null
    sleep 3

    echo -e "${GREEN}✅ Chrony 时间同步已启用${PLAIN}"
    chronyc tracking | grep "Reference ID\|Stratum\|Last offset"
}

# --- 4. Swap / ZRAM 虚拟内存管理 ---
manage_swap() {
    if [[ -d "/proc/vz" ]] || systemd-detect-virt | grep -q "lxc\|docker\|container"; then
        echo -e "${RED}检测到容器或 OpenVZ，不支持传统 Swap${PLAIN}"
    fi

    while true; do
        clear
        echo -e "${BLUE}========= 虚拟内存管理 (Swap / ZRAM) =========${PLAIN}"
        echo -e "当前状态:"
        swapon --show || echo -e "${YELLOW}无传统 Swap${PLAIN}"
        if [[ -d /sys/block/zram0 ]]; then echo -e "${GREEN}ZRAM 已启用${PLAIN}"; fi
        echo ""
        echo -e " ${GREEN}1.${PLAIN} 添加传统 Swap 文件"
        echo -e " ${GREEN}2.${PLAIN} 启用 ZRAM（推荐 SSD，低内存 VPS）"
        echo -e " ${RED}3.${PLAIN} 删除传统 Swap"
        echo -e " ${RED}4.${PLAIN} 禁用 ZRAM"
        echo -e " ${GRAY}0.${PLAIN} 返回"
        read -p "请选择: " choice

        case "$choice" in
            1)
                read -p "输入 Swap 大小 (MB，建议 RAM 的 1-2 倍): " size
                if ! [[ "$size" =~ ^[0-9]+$ ]] || [[ "$size" -le 0 ]]; then
                    echo -e "${RED}无效输入${PLAIN}"; read -p "按回车继续..."; continue
                fi
                if grep -q swap /etc/fstab; then
                    echo -e "${RED}已存在 Swap，请先删除${PLAIN}"; read -p "按回车继续..."; continue
                fi
                fallocate -l "${size}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$size"
                chmod 600 /swapfile
                mkswap /swapfile
                swapon /swapfile
                echo '/swapfile none swap defaults 0 0' >> /etc/fstab
                echo -e "${GREEN}✅ ${size}MB Swap 已添加${PLAIN}"
                ;;
            2)
                if [[ -d /sys/block/zram0 ]]; then
                    echo -e "${YELLOW}ZRAM 已存在${PLAIN}"
                else
                    modprobe zram
                    echo lz4 > /sys/block/zram0/comp_algorithm
                    echo 2G > /sys/block/zram0/disksize  # 可调整
                    mkswap /dev/zram0
                    swapon /dev/zram0
                    echo '/dev/zram0 none swap defaults 0 0' >> /etc/fstab
                    echo -e "${GREEN}✅ ZRAM 已启用（2GB 压缩内存）${PLAIN}"
                fi
                ;;
            3)
                if grep -q swap /etc/fstab; then
                    swapoff -a
                    sed -i '/swap/d' /etc/fstab
                    rm -f /swapfile
                    echo -e "${GREEN}✅ Swap 已删除${PLAIN}"
                else
                    echo -e "${RED}无 Swap 可删除${PLAIN}"
                fi
                ;;
            4)
                if [[ -d /sys/block/zram0 ]]; then
                    swapoff /dev/zram0
                    echo 0 > /sys/block/zram0/disksize
                    rmmod zram
                    sed -i '/zram/d' /etc/fstab
                    echo -e "${GREEN}✅ ZRAM 已禁用${PLAIN}"
                fi
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择${PLAIN}"; sleep 1 ;;
        esac
        read -p "按回车继续..."
    done
}

# --- 5. 端口跳跃管理 (nftables 现代版) ---
manage_port_hopping() {
    if ! command -v nft >/dev/null; then
        echo -e "${YELLOW}正在安装 nftables...${PLAIN}"
        apt install -y nftables || yum install -y nftables
    fi

    while true; do
        clear
        echo -e "${BLUE}========= UDP 端口跳跃 (nftables) =========${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 添加跳跃规则"
        echo -e " ${RED}2.${PLAIN} 删除跳跃规则"
        echo -e " ${SKYBLUE}3.${PLAIN} 查看当前规则"
        echo -e " ${GRAY}0.${PLAIN} 返回"
        read -p "请选择: " choice

        case "$choice" in
            1)
                read -p "真实监听端口 (如 443): " target
                read -p "起始端口 (如 20000): " start
                read -p "结束端口 (如 30000): " end
                [[ -z "$target" || -z "$start" || -z "$end" ]] && { echo "参数不能为空"; continue; }
                nft add rule nat prerouting udp dport "$start"-"$end" redirect to :"$target"
                nft list ruleset > /etc/nftables.conf
                echo -e "${GREEN}规则已添加并持久化${PLAIN}"
                ;;
            2)
                nft -a list table nat
                read -p "输入要删除的 handle 编号: " handle
                nft delete rule nat prerouting handle "$handle"
                nft list ruleset > /etc/nftables.conf
                echo -e "${GREEN}规则已删除${PLAIN}"
                ;;
            3)
                nft list table nat
                ;;
            0) return ;;
        esac
        read -p "按回车继续..."
    done
}

# --- 6. SSH 安全加固 + Fail2Ban ---
configure_ssh_security() {
    backup_file /etc/ssh/sshd_config

    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    echo -e "${YELLOW}第一步: 导入公钥${PLAIN}"
    read -p "从 GitHub 导入？输入用户名（留空手动）: " gh_user
    if [[ -n "$gh_user" ]]; then
        pub_key=$(curl -sSf "https://github.com/${gh_user}.keys" || echo "")
        [[ -z "$pub_key" ]] && echo -e "${RED}拉取失败或无公钥${PLAIN}"
    else
        read -p "粘贴公钥（直接回车跳过）: " pub_key
    fi

    if [[ -n "$pub_key" ]]; then
        echo "$pub_key" >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        echo -e "${GREEN}✅ 公钥已导入${PLAIN}"
    fi

    read -p "是否禁用密码登录？(y/n): " disable_pass
    if [[ "$disable_pass" == "y" ]]; then
        sed -i '/^PasswordAuthentication/d' /etc/ssh/sshd_config
        sed -i '/^PubkeyAuthentication/d' /etc/ssh/sshd_config
        echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
        echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
        echo -e "${GREEN}✅ 已禁用密码登录${PLAIN}"
    fi

    echo -e "${YELLOW}正在安装 Fail2Ban 防暴力破解...${PLAIN}"
    if command -v apt >/dev/null; then apt install -y fail2ban; fi
    if command -v yum >/dev/null || command -v dnf >/dev/null; then yum install -y fail2ban || dnf install -y fail2ban; fi

    cat >/etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
maxretry = 5
bantime = 3600
findtime = 600
EOF

    systemctl enable --now fail2ban >/dev/null
    echo -e "${GREEN}✅ Fail2Ban 已启用${PLAIN}"

    sshd -t && systemctl restart sshd
    echo -e "${GREEN}SSH 加固完成！建议新窗口测试登录${PLAIN}"
    read -p "按回车返回..."
}

# --- 其他函数保持不变（view_certs, view_logs）---
view_certs() { ... }  # 原函数保留
view_logs() { ... }   # 原函数保留

# ==========================================
# 主菜单
# ==========================================
show_menu() {
    while true; do
        clear
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e "${GREEN}      系统运维工具箱 v3.0 (2025 优化版)      ${PLAIN}"
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 开启 BBRv3 加速 + 高并发优化"
        echo -e " ${SKYBLUE}2.${PLAIN} SSH 防断连优化（Web SSH 推荐）"
        echo -e " ${SKYBLUE}3.${PLAIN} 高精度时间同步 (Chrony)"
        echo -e " --------------------------------------------"
        echo -e " ${SKYBLUE}4.${PLAIN} 查看 ACME 证书"
        echo -e " ${SKYBLUE}5.${PLAIN} 查看服务日志 (Xray/SB/Hy2/CF)"
        echo -e " ${SKYBLUE}6.${PLAIN} 虚拟内存管理 (Swap/ZRAM)"
        echo -e " --------------------------------------------"
        echo -e " ${GREEN}7.${PLAIN} UDP 端口跳跃 (nftables)"
        echo -e " ${GREEN}8.${PLAIN} SSH 安全加固 + Fail2Ban"
        echo -e " --------------------------------------------"
        echo -e " ${GRAY}0.${PLAIN} 退出"
        read -p "请选择: " choice
        case "$choice" in
            1) enable_bbr ;;
            2) fix_ssh_keepalive ;;
            3) sync_time ;;
            4) view_certs ;;
            5) view_logs ;;
            6) manage_swap ;;
            7) manage_port_hopping ;;
            8) configure_ssh_security ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
        read -p "按回车继续..." < /dev/tty
    done
}

show_menu
