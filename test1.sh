#!/bin/bash

# ============================================================
#  系统运维工具箱 v3.1 (2025 自用增强版)
#  - 恢复内置专属公钥便利功能（仅自用安全）
#  - Fail2Ban 安装/卸载改为用户选择
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp -a "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)"
        echo -e "${YELLOW}已备份: $file${PLAIN}"
    fi
}

# --- 1. BBR 加速 + 高并发优化 ---
enable_bbr() {
    echo -e "${YELLOW}正在配置 BBR 与网络优化参数...${PLAIN}"
    backup_file /etc/sysctl.conf

    sed -i '/net\.core\.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net\.ipv4\.tcp_ecn/d' /etc/sysctl.conf
    sed -i '/net\.core\.somaxconn/d' /etc/sysctl.conf

    local bbr_version="bbr"
    if command -v bc >/dev/null && [[ $(echo "$(uname -r | cut -d. -f1-2) >= 6.1" | bc) -eq 1 ]]; then
        if lsmod | grep -q bbr3 || modprobe tcp_bbr3 2>/dev/null; then
            bbr_version="bbr3"
        fi
    fi

    cat <<EOF >> /etc/sysctl.conf

# Network Optimization 2025
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $bbr_version
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_ecn = 1
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
vm.swappiness = 10
EOF

    sysctl -p >/dev/null

    backup_file /etc/security/limits.conf
    if ! grep -q "nofile 1048576" /etc/security/limits.conf; then
        cat <<EOF >> /etc/security/limits.conf

* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    fi

    echo -e "${GREEN}✅ BBR ($bbr_version) 与高并发优化完成${PLAIN}"
}

# --- 2. SSH 防断连优化 ---
fix_ssh_keepalive() {
    echo -e "${YELLOW}配置 SSH 保活参数...${PLAIN}"
    backup_file /etc/ssh/sshd_config

    sed -i '/ClientAliveInterval/d' /etc/ssh/sshd_config
    sed -i '/ClientAliveCountMax/d' /etc/ssh/sshd_config
    sed -i '/TCPKeepAlive/d' /etc/ssh/sshd_config

    cat <<EOF >> /etc/ssh/sshd_config

ClientAliveInterval 240
ClientAliveCountMax 3
TCPKeepAlive yes
EOF

    if sshd -t >/dev/null 2>&1; then
        systemctl restart sshd
        echo -e "${GREEN}✅ SSH 保活已更新${PLAIN}"
    else
        echo -e "${RED}❌ 配置错误${PLAIN}"
    fi
}

# --- 3. 高精度时间同步 (Chrony) ---
sync_time() {
    echo -e "${YELLOW}安装并配置 Chrony...${PLAIN}"
    if ! command -v chronyd >/dev/null 2>&1; then
        apt update && apt install -y chrony || yum install -y chrony || dnf install -y chrony
    fi

    backup_file /etc/chrony/chrony.conf
    cat >/etc/chrony/chrony.conf <<EOF
pool pool.ntp.org iburst
pool time.cloudflare.com iburst
pool time.google.com iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF

    systemctl enable --now chronyd >/dev/null
    echo -e "${GREEN}✅ Chrony 已启用${PLAIN}"
}

# --- 4 & 5. view_certs / view_logs (保持不变) ---
view_certs() {
    echo -e "${BLUE}============= 已申请的 SSL 证书 =============${PLAIN}"
    local cert_root="/root/.acme.sh"
    if [ -d "$cert_root" ]; then
        ls -d $cert_root/*/ | grep -v "_ecc" | while read dir; do
            domain=$(basename "$dir")
            if [[ "$domain" != "http.header" && "$domain" != "acme.sh" ]]; then
                echo -e "域名: ${SKYBLUE}$domain${PLAIN}"
                echo -e "路径: ${YELLOW}$dir${PLAIN}"
                echo "-----------------------------------------------"
            fi
        done
    else
        echo -e "${RED}未检测到 acme.sh 目录。${PLAIN}"
    fi
}

view_logs() {
    echo -e "${BLUE}============= 服务运行日志 (最近 20 行) =============${PLAIN}"
    systemctl is-active --quiet xray && { echo -e "${YELLOW}>>> Xray${PLAIN}"; journalctl -u xray --no-pager -n 20; echo; }
    systemctl is-active --quiet sing-box && { echo -e "${YELLOW}>>> Sing-box${PLAIN}"; journalctl -u sing-box --no-pager -n 20; echo; }
    systemctl is-active --quiet hysteria-server && { echo -e "${YELLOW}>>> Hysteria 2${PLAIN}"; journalctl -u hysteria-server --no-pager -n 20; echo; }
    systemctl is-active --quiet cloudflared && { echo -e "${YELLOW}>>> Cloudflare Tunnel${PLAIN}"; journalctl -u cloudflared --no-pager -n 20; echo; }
    if ! systemctl is-active --quiet xray && ! systemctl is-active --quiet sing-box && ! systemctl is-active --quiet hysteria-server && ! systemctl is-active --quiet cloudflared; then
        echo -e "${RED}未检测到常见服务运行${PLAIN}"
    fi
}

# --- 6 & 7. manage_swap / manage_port_hopping (保持不变，略) ---
# （内容同之前完整版，这里省略以节省篇幅，实际脚本请保留）

# --- 8. SSH 安全加固（恢复便利功能 + Fail2Ban 询问）---
configure_ssh_security() {
    backup_file /etc/ssh/sshd_config
    mkdir -p ~/.ssh && chmod 700 ~/.ssh

    echo -e "${YELLOW}=== SSH 公钥导入（自用专属保险通道）===${PLAIN}"
    read -p "GitHub 用户名（留空则手动）: " gh_user
    local pub_key=""

    if [[ -n "$gh_user" ]]; then
        pub_key=$(curl -sSf "https://github.com/${gh_user}.keys" || echo "")
        [[ -z "$pub_key" ]] && echo -e "${RED}拉取失败${PLAIN}"
    else
        read -p "粘贴公钥（直接回车使用你的内置专属公钥）: " input_key
        if [[ -n "$input_key" ]]; then
            pub_key="$input_key"
        else
            echo -e "${SKYBLUE}>>> 使用内置专属公钥（一键恢复访问）${PLAIN}"
            pub_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILdsaJ9MTQU28cyRJZ3s32V1u9YDNUYRJvCSkztBDGsW eddsa-key-20251218"
        fi
    fi

    if [[ -n "$pub_key" ]]; then
        echo "$pub_key" >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        echo -e "${GREEN}✅ 公钥已写入${PLAIN}"
    fi

    read -p "是否禁用密码登录？(y/n): " disable_pass
    if [[ "$disable_pass" == "y" ]]; then
        sed -i '/^PasswordAuthentication/d' /etc/ssh/sshd_config
        sed -i '/^PubkeyAuthentication/d' /etc/ssh/sshd_config
        echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
        echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
        echo -e "${GREEN}✅ 已禁用密码登录${PLAIN}"
    fi

    # === Fail2Ban 用户选择 ===
    echo -e "\n${YELLOW}=== Fail2Ban 防暴力破解 ===${PLAIN}"
    if command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "当前状态: ${GREEN}已安装${PLAIN}"
        read -p "是否卸载 Fail2Ban？(y/n，默认n): " uninstall_f2b
        if [[ "$uninstall_f2b" == "y" ]]; then
            apt purge -y fail2ban || yum remove -y fail2ban || dnf remove -y fail2ban
            rm -rf /etc/fail2ban
            echo -e "${GREEN}✅ Fail2Ban 已卸载${PLAIN}"
            sshd -t && systemctl restart sshd
            echo -e "${GREEN}SSH 配置完成${PLAIN}"
            return
        fi
    else
        echo -e "当前状态: ${RED}未安装${PLAIN}"
    fi

    read -p "是否安装 Fail2Ban？(y/n，默认n): " install_f2b
    if [[ "$install_f2b" == "y" ]]; then
        apt install -y fail2ban || yum install -y fail2ban || dnf install -y fail2ban
        cat >/etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
maxretry = 5
bantime = 3600
findtime = 600
EOF
        systemctl enable --now fail2ban
        echo -e "${GREEN}✅ Fail2Ban 已安装并启用${PLAIN}"
    else
        echo -e "${GRAY}跳过 Fail2Ban 安装${PLAIN}"
    fi

    sshd -t && systemctl restart sshd
    echo -e "${GREEN}SSH 安全加固完成！请在新窗口测试公钥登录${PLAIN}"
}

# 主菜单及其他函数保持不变（略，完整脚本请保留之前所有函数）

show_menu() {
    while true; do
        clear
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e "${GREEN}      系统运维工具箱 v3.1 (2025 自用版)      ${PLAIN}"
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} BBR 加速 + 高并发优化"
        echo -e " ${SKYBLUE}2.${PLAIN} SSH 防断连优化"
        echo -e " ${SKYBLUE}3.${PLAIN} 高精度时间同步 (Chrony)"
        echo -e " --------------------------------------------"
        echo -e " ${SKYBLUE}4.${PLAIN} 查看 ACME 证书"
        echo -e " ${SKYBLUE}5.${PLAIN} 查看服务日志"
        echo -e " ${SKYBLUE}6.${PLAIN} 虚拟内存管理 (Swap/ZRAM)"
        echo -e " --------------------------------------------"
        echo -e " ${GREEN}7.${PLAIN} UDP 端口跳跃 (nftables)"
        echo -e " ${GREEN}8.${PLAIN} SSH 安全加固（含专属公钥恢复）"
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
        read -p "按回车继续..." </dev/tty
    done
}

# （manage_swap 和 manage_port_hopping 函数请从之前完整版复制进来）

show_menu
