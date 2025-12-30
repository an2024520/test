#!/bin/bash

# ============================================================
#  模块五：系统运维工具箱 (System Tools)
#  - 状态: v2.5 (集成 Swap 管理)
#  - 适用: Xray / Sing-box / Hysteria2 / Cloudflare Tunnel
#  - 更新: 自动清除 sshd_config.d 中的覆盖配置
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
BLUE='\033[0;34m'

# 1. 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# ==========================================
# 功能函数定义
# ==========================================

# --- 1. 系统内核加速 (BBR + Ulimit) ---
enable_bbr() {
    echo -e "${YELLOW}正在配置 BBR 拥塞控制与系统参数...${PLAIN}"
    [ ! -f /etc/sysctl.conf.bak ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak

    # 清理旧配置
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_window_scaling/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_ecn/d' /etc/sysctl.conf

    # 写入新配置 (默认关闭 ECN 以防断流)
    cat <<EOF >> /etc/sysctl.conf
# === Network Optimization ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_ecn = 0
# ============================
EOF
    sysctl -p > /dev/null 2>&1

    # 优化 Ulimit
    if ! grep -q "soft nofile 65535" /etc/security/limits.conf; then
        echo "* soft nofile 65535" >> /etc/security/limits.conf
        echo "* hard nofile 65535" >> /etc/security/limits.conf
        echo "root soft nofile 65535" >> /etc/security/limits.conf
        echo "root hard nofile 65535" >> /etc/security/limits.conf
    fi

    local bbr_status=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [[ "$bbr_status" == "bbr" ]]; then
        echo -e "${GREEN}✅ BBR 加速: [已开启]${PLAIN}"
        echo -e "${GREEN}✅ 连接数限制: [已解除]${PLAIN}"
    else
        echo -e "${RED}❌ BBR 开启失败，请检查内核版本。${PLAIN}"
    fi
}

# --- 2. SSH 防断连修复 (Web SSH 优化) ---
fix_ssh_keepalive() {
    echo -e "${YELLOW}正在配置 SSH 心跳保活 (Web SSH 防断连)...${PLAIN}"
    sed -i '/ClientAliveInterval/d' /etc/ssh/sshd_config
    sed -i '/ClientAliveCountMax/d' /etc/ssh/sshd_config
    echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config
    echo "ClientAliveCountMax 10" >> /etc/ssh/sshd_config
    systemctl restart sshd
    echo -e "${GREEN}✅ SSH 配置已更新。请重新连接以生效。${PLAIN}"
}

# --- 3. 系统时间同步 ---
sync_time() {
    echo -e "${YELLOW}正在同步系统时间...${PLAIN}"
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true
        echo -e "${GREEN}✅ 已开启 NTP 自动同步。${PLAIN}"
        timedatectl status | grep "Local time"
    else
        apt-get install -y ntpdate >/dev/null 2>&1 || yum install -y ntpdate >/dev/null 2>&1
        ntpdate pool.ntp.org
        echo -e "${GREEN}✅ 时间同步完成。${PLAIN}"
    fi
}

# --- 4. 查看 ACME 证书 ---
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

# --- 5. 全能日志查看器 ---
view_logs() {
    echo -e "${BLUE}============= 服务运行日志 (实时最近 20 行) =============${PLAIN}"
    
    # Xray Log
    if systemctl is-active --quiet xray; then
        echo -e "${YELLOW}>>> Xray Core:${PLAIN}"
        journalctl -u xray --no-pager -n 20
        echo ""
    fi
    
    # Sing-box Log
    if systemctl is-active --quiet sing-box; then
        echo -e "${YELLOW}>>> Sing-box Core:${PLAIN}"
        journalctl -u sing-box --no-pager -n 20
        echo ""
    fi

    # Hysteria 2 Official Log
    if systemctl is-active --quiet hysteria-server; then
        echo -e "${YELLOW}>>> Hysteria 2 Official:${PLAIN}"
        journalctl -u hysteria-server --no-pager -n 20
        echo ""
    fi
    
    # Cloudflare Tunnel Log
    if systemctl is-active --quiet cloudflared; then
        echo -e "${YELLOW}>>> Cloudflare Tunnel:${PLAIN}"
        journalctl -u cloudflared --no-pager -n 20
        echo ""
    fi
    
    # 检测是否全空
    if ! systemctl is-active --quiet xray && ! systemctl is-active --quiet sing-box \
       && ! systemctl is-active --quiet hysteria-server && ! systemctl is-active --quiet cloudflared; then
         echo -e "${RED}未检测到常见代理服务 (Xray/SB/Hy2/Argo) 运行。${PLAIN}"
    fi
}

# --- 6. 端口跳跃管理 ---
manage_port_hopping() {
    if ! command -v iptables &> /dev/null || ! dpkg -s iptables-persistent &> /dev/null; then
        echo -e "${YELLOW}检测到缺少 iptables 持久化组件，正在安装...${PLAIN}"
        apt update -y && apt install -y iptables iptables-persistent netfilter-persistent
    fi
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    while true; do
        clear
        echo -e "${BLUE}========= UDP 端口跳跃管理 (Port Hopping) =========${PLAIN}"
        echo -e "功能: 利用 Iptables 将大范围 UDP 流量转发至 Hy2/Xray 监听端口"
        echo -e "----------------------------------------------------"
        echo -e " ${GREEN}1.${PLAIN} 添加跳跃规则"
        echo -e " ${RED}2.${PLAIN} 删除跳跃规则"
        echo -e " ${SKYBLUE}3.${PLAIN} 查看当前规则"
        echo -e " ----------------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo ""
        read -p "请选择: " hop_choice
        case "$hop_choice" in
            1)
                echo -e "\n${YELLOW}>>> 添加规则向导${PLAIN}"
                read -p "请输入真实监听端口 (Target Port, 例 443): " target_port
                read -p "请输入跳跃起始端口 (Start Port, 例 20000): " start_port
                read -p "请输入跳跃结束端口 (End Port,   例 30000): " end_port
                if [[ -z "$target_port" || -z "$start_port" || -z "$end_port" ]]; then
                    echo -e "${RED}错误: 参数不能为空。${PLAIN}"; sleep 1; continue
                fi
                echo -e "${YELLOW}正在添加: UDP $start_port:$end_port -> $target_port ...${PLAIN}"
                iptables -t nat -A PREROUTING -p udp --dport "$start_port":"$end_port" -j REDIRECT --to-ports "$target_port"
                netfilter-persistent save >/dev/null 2>&1
                echo -e "${GREEN}规则已保存。${PLAIN}"; read -p "按回车继续..." ;;
            2)
                echo -e "\n${YELLOW}>>> 删除规则向导${PLAIN}"
                iptables -t nat -nL PREROUTING --line-numbers | grep "REDIRECT"
                echo -e "----------------------------------------------------"
                echo -e "请输入要删除的规则对应的 ${GREEN}源端口范围${PLAIN}。"
                read -p "起始端口: " d_start
                read -p "结束端口: " d_end
                if [[ -z "$d_start" || -z "$d_end" ]]; then echo -e "${RED}参数无效。${PLAIN}"; sleep 1; continue; fi
                iptables -t nat -D PREROUTING -p udp --dport "$d_start":"$d_end" -j REDIRECT 2>/dev/null
                if [[ $? -eq 0 ]]; then netfilter-persistent save >/dev/null 2>&1; echo -e "${GREEN}删除成功。${PLAIN}"; else echo -e "${RED}删除失败。${PLAIN}"; fi
                read -p "按回车继续..." ;;
            3)
                echo -e "\n${YELLOW}>>> 当前 NAT 转发规则${PLAIN}"
                iptables -t nat -nL PREROUTING --line-numbers | grep -E "num|REDIRECT|dpts"
                read -p "按回车继续..." ;;
            0) break ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# --- 7. SSH 安全配置 (修复 Cloud-init 冲突) ---
configure_ssh_security() {
    local DEFAULT_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILdsaJ9MTQU28cyRJZ3s32V1u9YDNUYRJvCSkztBDGsW eddsa-key-20251218"

    clear
    echo -e "${BLUE}========= SSH 安全加固 (公钥/禁用密码) =========${PLAIN}"
    echo -e "1. 导入公钥: 解决 VPS 重装后需要反复输入密码的烦恼。"
    echo -e "2. 禁用密码: 彻底杜绝 SSH 暴力破解，提升安全等级。"
    echo -e "------------------------------------------------"
    
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    
    echo -e "${YELLOW}第一步: 导入公钥 (Authorized Keys)${PLAIN}"
    echo -e "  1. 从 GitHub 导入"
    echo -e "  2. 手动粘贴公钥 (留空则自动使用内置默认 Key)"
    echo -e "  3. 跳过此步"
    read -p "请选择 [1-3]: " key_opt
    
    local pub_key=""
    if [[ "$key_opt" == "1" ]]; then
        read -p "请输入 GitHub 用户名: " gh_user
        if [[ -n "$gh_user" ]]; then
            echo -e "正在拉取 https://github.com/${gh_user}.keys ..."
            pub_key=$(curl -s "https://github.com/${gh_user}.keys")
            if [[ -z "$pub_key" ]] || [[ "$pub_key" == *"Not Found"* ]]; then
                echo -e "${RED}错误: 未找到用户或 Keys 为空。${PLAIN}"
                pub_key=""
            fi
        fi
    elif [[ "$key_opt" == "2" ]]; then
        read -p "请粘贴公钥串 (直接回车使用内置): " input_key
        if [[ -n "$input_key" ]]; then
            pub_key="$input_key"
        else
            echo -e "${SKYBLUE}>>> 检测到空输入，已加载内置默认公钥。${PLAIN}"
            pub_key="$DEFAULT_KEY"
        fi
    fi
    
    if [[ -n "$pub_key" ]]; then
        if grep -q "${pub_key:0:20}" ~/.ssh/authorized_keys 2>/dev/null; then
            echo -e "${YELLOW}提示: 该公钥似乎已存在，跳过写入。${PLAIN}"
        else
            echo "$pub_key" >> ~/.ssh/authorized_keys
            chmod 600 ~/.ssh/authorized_keys
            echo -e "${GREEN}✅ 公钥已成功写入 ~/.ssh/authorized_keys${PLAIN}"
        fi
    fi
    
    echo -e "\n${YELLOW}第二步: 安全策略设置${PLAIN}"
    echo -e "当前 SSH 密码登录状态: $(grep "^PasswordAuthentication" /etc/ssh/sshd_config || echo "默认(Yes)")"
    
    # 检测是否存在冲突的子配置文件
    if grep -r "PasswordAuthentication yes" /etc/ssh/sshd_config.d/ &> /dev/null; then
        echo -e "${RED}警告: 检测到 sshd_config.d/ 目录下存在强制开启密码登录的配置！${PLAIN}"
        echo -e "${RED}这通常由 Cloud-init 生成，会导致禁用密码失败。${PLAIN}"
    fi

    read -p "是否禁用 SSH 密码登录? (y/n): " dis_pass
    
    if [[ "$dis_pass" == "y" ]]; then
        # 备份配置
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
        
        # 1. 强力清理冲突的子配置 (Cloud-init 修复)
        if [ -d /etc/ssh/sshd_config.d/ ]; then
            echo -e "${YELLOW}正在扫描并清理冲突的子配置...${PLAIN}"
            # 查找所有包含 PasswordAuthentication yes 的文件并重命名备份
            grep -l "PasswordAuthentication yes" /etc/ssh/sshd_config.d/* 2>/dev/null | while read file; do
                echo -e "  - 禁用冲突文件: $file"
                mv "$file" "${file}.bak_disabled"
            done
        fi
        
        # 2. 修改主配置
        sed -i '/^PubkeyAuthentication/d' /etc/ssh/sshd_config
        sed -i '/^PasswordAuthentication/d' /etc/ssh/sshd_config
        sed -i '/^ChallengeResponseAuthentication/d' /etc/ssh/sshd_config
        
        echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
        echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
        echo "ChallengeResponseAuthentication no" >> /etc/ssh/sshd_config
        
        systemctl restart sshd
        echo -e "${GREEN}✅ 已禁用密码登录 (并清理了冲突配置)，重启 SSH 服务。${PLAIN}"
    else
        echo -e "${GRAY}已保留密码登录。${PLAIN}"
    fi
    
    echo -e "\n${GREEN}SSH 配置完成。${PLAIN}"
    read -p "按回车返回..."
}

# --- 8. 虚拟内存管理 (Swap) ---
# --- 8. 虚拟内存管理 (Swap) ---
manage_swap() {
    # 1. OpenVZ 检测
    if [[ -d "/proc/vz" ]]; then
        echo -e "${RED}错误: 您的 VPS 基于 OpenVZ 架构，不支持修改 Swap！${PLAIN}"
        read -p "按回车返回..."
        return
    fi

    # 2. 容器环境检测 (Podman/Docker/LXC)
    # 检测 systemd-detect-virt 的输出是否包含 docker, podman, lxc 等关键字
    local virt_type=$(systemd-detect-virt 2>/dev/null)
    if [[ "$virt_type" == "docker" || "$virt_type" == "podman" || "$virt_type" == "lxc" || "$virt_type" == "wsl" ]]; then
        echo -e "${RED}警告: 检测到您正在容器环境 ($virt_type) 中运行。${PLAIN}"
        echo -e "${YELLOW}在此环境下，Swap 由宿主机严格管控，容器内无法添加或删除。${PLAIN}"
        echo -e "${YELLOW}您当前的 Swap 是虚拟配额，无法修改。${PLAIN}"
        read -p "按回车返回..."
        return
    fi

    while true; do
        clear
        echo -e "${BLUE}========= 虚拟内存管理 (Swap) =========${PLAIN}"
        echo -e "当前 Swap 状态:"
        free -h | grep -i swap
        echo -e "------------------------------------------------"
        echo -e " ${GREEN}1.${PLAIN} 添加/设置 Swap (建议 512MB/1024MB)"
        echo -e " ${RED}2.${PLAIN} 删除 Swap"
        echo -e " ------------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo ""
        read -p "请选择: " swap_choice
        case "$swap_choice" in
            1)
                echo -e "\n${YELLOW}>>> 添加 Swap 向导${PLAIN}"
                read -p "请输入 Swap 数值 (MB) [建议 512]: " swapsize
                [[ -z "$swapsize" ]] && swapsize=512
                
                # 检查是否已存在 (防止双重挂载)
                if grep -q "swap" /etc/fstab; then
                    echo -e "${RED}错误: 检测到 fstab 中已存在 Swap 配置。${PLAIN}"
                    echo -e "${YELLOW}建议先执行 [2. 删除 Swap] 清理环境。${PLAIN}"
                else
                    echo -e "${YELLOW}正在创建 ${swapsize}MB Swap 文件...${PLAIN}"
                    
                    # [核心优化] 优先使用 fallocate (秒级创建，防止 128M 机器断连)
                    if command -v fallocate &> /dev/null; then
                        echo -e "${SKYBLUE}正在使用 fallocate 高速分配...${PLAIN}"
                        fallocate -l ${swapsize}M /swapfile 2>/dev/null
                    fi

                    # [兼容保底] 如果 fallocate 失败(文件系统不支持)，回退到 dd (使用小块读写)
                    if [ ! -f /swapfile ] || [ $(stat -c%s /swapfile) -eq 0 ]; then
                        echo -e "${SKYBLUE}fallocate 不可用，回退到 dd (平滑模式)...${PLAIN}"
                        # bs=64k 降低内存抖动，count 计算总块数
                        dd if=/dev/zero of=/swapfile bs=64k count=$((swapsize * 16))
                    fi

                    # 设置权限并挂载
                    chmod 600 /swapfile
                    mkswap /swapfile
                    swapon /swapfile
                    echo '/swapfile none swap defaults 0 0' >> /etc/fstab
                    
                    echo -e "${GREEN}✅ Swap 创建成功！${PLAIN}"
                    echo -e "--------------------------------------"
                    cat /proc/swaps
                    cat /proc/meminfo | grep Swap
                fi
                read -p "按回车继续..." ;;
            2)
                echo -e "\n${YELLOW}>>> 删除 Swap 向导${PLAIN}"
                # [逻辑增强] 只要 free 里有显示，或者有文件，就强制执行清理
                if [ $(free | grep -i swap | awk '{print $2}') -gt 0 ] || [ -f /swapfile ]; then
                    echo -e "${YELLOW}正在强制停止并删除所有 Swap 空间...${PLAIN}"
                    # 从 fstab 中彻底移除相关行
                    sed -i '/swap/d' /etc/fstab
                    # 释放缓存
                    echo "3" > /proc/sys/vm/drop_caches
                    # 关闭所有交换分区 (stderr 丢弃，防止无 swap 时报错)
                    swapoff -a 2>/dev/null
                    # 删除物理文件
                    rm -f /swapfile
                    echo -e "${GREEN}✅ Swap 已强制删除。${PLAIN}"
                else
                    echo -e "${RED}系统当前未激活任何 Swap 空间，无需清理。${PLAIN}"
                fi
                read -p "按回车继续..." ;;
            0) break ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 主菜单
# ==========================================
show_menu() {
    while true; do
        clear
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e "${GREEN}        系统运维工具箱 (System Tools)        ${PLAIN}"
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 开启 BBR 加速 + 解除连接数限制"
        echo -e " ${SKYBLUE}2.${PLAIN} 修复 SSH 自动断开 ${YELLOW}(Web SSH 推荐)${PLAIN}"
        echo -e " ${SKYBLUE}3.${PLAIN} 强制同步系统时间 ${YELLOW}(修复节点连不上)${PLAIN}"
        echo -e " --------------------------------------------"
        echo -e " ${SKYBLUE}4.${PLAIN} 查看 ACME 证书路径"
        echo -e " ${SKYBLUE}5.${PLAIN} 查看运行日志 ${YELLOW}(Xray/SB/Hy2/CF)${PLAIN}"
        echo -e " ${GREEN}6.${PLAIN} UDP 端口跳跃管理 ${YELLOW}(适配 Sing-box Hy2)${PLAIN}"
        echo -e " ${GREEN}7.${PLAIN} SSH 安全配置 ${YELLOW}(导入公钥/禁用密码)${PLAIN}"
        echo -e " ${GREEN}8.${PLAIN} 虚拟内存管理 (Swap) ${YELLOW}(小鸡必备)${PLAIN}"
        echo -e " --------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo ""
        read -p "请选择操作: " choice
        case "$choice" in
            1) enable_bbr; read -p "按回车继续..." ;;
            2) fix_ssh_keepalive; read -p "按回车继续..." ;;
            3) sync_time; read -p "按回车继续..." ;;
            4) view_certs; read -p "按回车继续..." ;;
            5) view_logs; read -p "按回车继续..." ;;
            6) manage_port_hopping ;;
            7) configure_ssh_security ;;
            8) manage_swap ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

show_menu