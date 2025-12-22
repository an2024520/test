#!/bin/bash

# ============================================================
#  全能协议管理中心 (Commander v3.9.8)
#  - 修复说明: 
#    1. 彻底隔离函数作用域，修复菜单点击失效问题
#    2. 修正 check_ipv6_environment 的括号闭合逻辑
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
GRAY='\033[0;37m'
BLUE='\033[0;34m'

# ==========================================
# 1. 核心配置与文件映射
# ==========================================
URL_LIST_FILE="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/sh_url.txt"
LOCAL_LIST_FILE="/tmp/sh_url.txt"

FILE_XRAY_CORE="xray_core.sh"
FILE_XRAY_UNINSTALL="xray_uninstall_all.sh"
FILE_SB_CORE="sb_install_core.sh"
FILE_SB_UNINSTALL="sb_uninstall.sh"
FILE_WIREPROXY="warp_wireproxy_socks5.sh"
FILE_CF_TUNNEL="install_cf_tunnel_debian.sh"
FILE_ADD_XHTTP="xray_vless_xhttp_reality.sh"
FILE_ADD_VISION="xray_vless_vision_reality.sh"
FILE_ADD_WS="xray_vless_ws_tls.sh"
FILE_ADD_TUNNEL="xray_vless_ws_tunnel.sh"
FILE_NODE_INFO="xray_get_node_details.sh"
FILE_NODE_DEL="xray_module_node_del.sh"
FILE_SB_ADD_ANYTLS="sb_anytls_reality.sh"
FILE_SB_ADD_VISION="sb_vless_vision_reality.sh"
FILE_SB_ADD_WS="sb_vless_ws_tls.sh"
FILE_SB_ADD_TUNNEL="sb_vless_ws_tunnel.sh"
FILE_SB_ADD_HY2_SELF="sb_hy2_self.sh"
FILE_SB_ADD_HY2_ACME="sb_hy2_acme.sh"
FILE_SB_INFO="sb_get_node_details.sh"
FILE_SB_DEL="sb_module_node_del.sh"
FILE_HY2="hy2.sh"
FILE_NATIVE_WARP="xray_module_warp_native_route.sh"
FILE_SB_NATIVE_WARP="sb_module_warp_native_route.sh"
FILE_ATTACH="xray_module_attach_warp.sh"
FILE_DETACH="xray_module_detach_warp.sh"
FILE_BOOST="xray_module_boost.sh"

# ==========================================
# 2. 引擎函数
# ==========================================

check_ipv6_environment() {
    echo -e "${YELLOW}正在检测 IPv4 网络连通性 (针对高延迟环境)...${PLAIN}"
    
    if curl -4 -s --connect-timeout 10 https://1.1.1.1 >/dev/null 2>&1; then
        echo -e "${GREEN}检测到 IPv4 连接正常。${PLAIN}"
        return
    fi
    
    if curl -s -m 10 https://www.google.com/generate_204 >/dev/null 2>&1; then
         echo -e "${GREEN}检测到通过 DNS64/NAT64 的网络连接。${PLAIN}"
         return
    fi

    echo -e "${YELLOW}======================================================${PLAIN}"
    echo -e "${RED}⚠️  检测到当前环境为纯 IPv6 (IPv6-Only)！${PLAIN}"
    echo -e "${GRAY}即将配置 NAT64/DNS64 并锁定文件以防止重启失效。${PLAIN}"
    echo -e ""
    read -p "是否立即配置 NAT64? (y/n, 默认 y): " fix_choice
    fix_choice=${fix_choice:-y}

    if [[ "$fix_choice" == "y" ]]; then
        echo -e "${YELLOW}正在配置 NAT64/DNS64...${PLAIN}"
        mkdir -p /var/log/sing-box/ && chmod 777 /var/log/sing-box/ >/dev/null 2>&1
        chattr -i /etc/resolv.conf >/dev/null 2>&1
        if [ ! -f "/etc/resolv.conf.bak.nat64" ]; then
            cp /etc/resolv.conf /etc/resolv.conf.bak.nat64
        fi
        rm -f /etc/resolv.conf
        echo -e "nameserver 2a09:c500::1\nnameserver 2001:67c:2b0::4" > /etc/resolv.conf
        chattr +i /etc/resolv.conf
        echo -e "${GREEN}已完成 NAT64 配置并锁定。${PLAIN}"
    else
        echo -e "${GRAY}已跳过。${PLAIN}"
    fi
} # 此处正确闭合 check_ipv6_environment

check_dir_clean() {
    local current_script=$(basename "$0")
    local file_count=$(ls -1 | grep -v "^$current_script$" | wc -l)
    if [[ "$file_count" -gt 0 ]]; then
        echo -e "${YELLOW}======================================================${PLAIN}"
        echo -e "${YELLOW} 检测到当前目录存在 $file_count 个历史文件。${PLAIN}"
        read -p "是否清空当前目录? (y/n, 默认 n): " clean_opt
        if [[ "$clean_opt" == "y" ]]; then
            ls | grep -v "^$current_script$" | xargs rm -rf
        fi
    fi
}

init_urls() {
    echo -e "${YELLOW}正在同步最新脚本列表...${PLAIN}"
    wget -T 20 -t 3 -qO "$LOCAL_LIST_FILE" "${URL_LIST_FILE}?t=$(date +%s)"
    [[ $? -ne 0 ]] && [[ ! -f "$LOCAL_LIST_FILE" ]] && echo -e "${RED}无法获取脚本列表${PLAIN}" && exit 1
    echo -e "${GREEN}同步完成。${PLAIN}"
}

get_url_by_name() {
    grep "^$1" "$LOCAL_LIST_FILE" | awk '{print $2}' | head -n 1
}

check_run() {
    local script_name="$1"
    local no_pause="$2"
    if [[ ! -f "$script_name" ]]; then
        local script_url=$(get_url_by_name "$script_name")
        [[ -z "$script_url" ]] && echo -e "${RED}未找到记录: $script_name${PLAIN}" && return
        mkdir -p "$(dirname "$script_name")"
        wget -qO "$script_name" "${script_url}?t=$(date +%s)"
        chmod +x "$script_name"
    fi
    ./"$script_name"
    [[ "$no_pause" != "true" ]] && read -p "操作结束，按回车键继续..."
}

# ==========================================
# 3. 菜单逻辑
# ==========================================

menu_singbox_env() {
    while true; do
        clear
        echo -e "${BLUE}============= Sing-box 核心环境管理 =============${PLAIN}"
        echo -e " 1. 安装/重置 Sing-box"
        echo -e " 2. 卸载 Sing-box"
        echo -e " 0. 返回"
        read -p "选择: " choice
        case "$choice" in
            1) check_run "$FILE_SB_CORE" ;;
            2) check_run "$FILE_SB_UNINSTALL" ;;
            0) return ;;
        esac
    done
}

menu_nodes_xray() {
    while true; do
        clear
        echo -e "${BLUE}============= Xray 节点配置管理 =============${PLAIN}"
        echo -e " 1. VLESS-XHTTP | 2. VLESS-Vision | 3. VLESS-WS | 4. Tunnel"
        echo -e " 5. 查看信息 | 6. 删除节点 | 0. 返回"
        read -p "选择: " choice
        case "$choice" in
            1) check_run "$FILE_ADD_XHTTP" ;;
            2) check_run "$FILE_ADD_VISION" ;;
            3) check_run "$FILE_ADD_WS" ;;
            4) check_run "$FILE_ADD_TUNNEL" ;;
            5) check_run "$FILE_NODE_INFO" ;;
            6) check_run "$FILE_NODE_DEL" ;;
            0) return ;;
        esac
    done
}

menu_nodes_sb() {
    while true; do
        clear
        echo -e "${BLUE}============= Sing-box 节点配置管理 =============${PLAIN}"
        echo -e " 1. AnyTLS | 2. Vision | 3. WS | 4. Tunnel | 5. Hy2(Self) | 6. Hy2(ACME)"
        echo -e " 7. 查看信息 | 8. 删除节点 | 0. 返回"
        read -p "选择: " choice
        case "$choice" in
            1) check_run "$FILE_SB_ADD_ANYTLS" ;;
            2) check_run "$FILE_SB_ADD_VISION" ;;
            3) check_run "$FILE_SB_ADD_WS" ;;
            4) check_run "$FILE_SB_ADD_TUNNEL" ;;
            5) check_run "$FILE_SB_ADD_HY2_SELF" ;;
            6) check_run "$FILE_SB_ADD_HY2_ACME" ;;
            7) check_run "$FILE_SB_INFO" ;;
            8) check_run "$FILE_SB_DEL" ;;
            0) return ;;
        esac
    done
}

menu_routing() {
    while true; do
        clear
        echo -e "${BLUE}============= 路由管理 =============${PLAIN}"
        echo -e " 1. Xray Native WARP"
        echo -e " 2. Sing-box Native WARP"
        echo -e " 0. 返回"
        read -p "选择: " choice
        case "$choice" in
            1) check_run "$FILE_NATIVE_WARP" "true" ;;
            2) check_run "$FILE_SB_NATIVE_WARP" "true" ;;
            0) return ;;
        esac
    done
}

menu_core() {
    while true; do
        clear
        echo -e " 1. Xray核心 | 2. 卸载Xray | 3. SB核心 | 4. WireProxy | 5. CF Tunnel | 0. 返回"
        read -p "选择: " choice
        case "$choice" in
            1) check_run "$FILE_XRAY_CORE" ;;
            2) check_run "$FILE_XRAY_UNINSTALL" ;;
            3) menu_singbox_env ;;
            4) check_run "$FILE_WIREPROXY" ;;
            5) check_run "$FILE_CF_TUNNEL" ;;
            0) return ;;
        esac
    done
}

menu_nodes() {
    while true; do
        clear
        echo -e " 1. Xray节点 | 2. Sing-box节点 | 3. 独立Hy2 | 0. 返回"
        read -p "选择: " choice
        case "$choice" in
            1) menu_nodes_xray ;;
            2) menu_nodes_sb ;;
            3) check_run "$FILE_HY2" ;;
            0) return ;;
        esac
    done
}

# ==========================================
# 4. 主菜单入口 (已移出 check_ipv6 范围)
# ==========================================
show_main_menu() {
    while true; do
        clear
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e "${GREEN}      全能协议管理中心 (Commander v3.9.8)      ${PLAIN}"
        echo -e "${GREEN}============================================${PLAIN}"
        
        STATUS_TEXT=""
        pgrep -x "xray" >/dev/null && STATUS_TEXT+="Xray:${GREEN}运行 ${PLAIN}" || STATUS_TEXT+="Xray:${RED}停止 ${PLAIN}"
        pgrep -x "sing-box" >/dev/null && STATUS_TEXT+="| SB:${GREEN}运行 ${PLAIN}" || STATUS_TEXT+="| SB:${RED}停止 ${PLAIN}"
        
        echo -e " 系统状态: [$STATUS_TEXT]"
        echo -e "--------------------------------------------"
        echo -e " 1. 前置/核心管理 (Core)"
        echo -e " 2. 节点配置管理 (Nodes)"
        echo -e " 3. 路由规则管理 (Routing)"
        echo -e " 4. 系统优化工具 (Boost)"
        echo -e " 0. 退出脚本"
        echo -e "--------------------------------------------"
        read -p "请选择操作 [0-4]: " main_choice

        case "$main_choice" in
            1) menu_core ;;
            2) menu_nodes ;;
            3) menu_routing ;;
            4) check_run "$FILE_BOOST" ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# 脚本启动
check_dir_clean
check_ipv6_environment
init_urls
show_main_menu
