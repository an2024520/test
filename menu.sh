#!/bin/bash

# ============================================================
#  全能协议管理中心 (Commander v3.9.9 - 稳定修复版)
#  - 修复说明: 
#    1. 修复 menu_routing_sb 变量捕获失效问题
#    2. 彻底隔离 check_ipv6_environment 作用域，防止函数嵌套
#    3. 严格对齐原始排版、颜色与文字描述
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
    
    # 1. 针对高延迟环境探测 (10s 超时)
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
            echo -e "${GREEN}已备份原 DNS${PLAIN}"
        fi
        rm -f /etc/resolv.conf
        echo -e "nameserver 2a09:c500::1\nnameserver 2001:67c:2b0::4" > /etc/resolv.conf
        chattr +i /etc/resolv.conf
        echo -e "${GREEN}已完成 NAT64 配置并锁定。${PLAIN}"
    else
        echo -e "${GRAY}已跳过。${PLAIN}"
    fi
}

check_dir_clean() {
    local current_script=$(basename "$0")
    local file_count=$(ls -1 | grep -v "^$current_script$" | wc -l)
    if [[ "$file_count" -gt 0 ]]; then
        echo -e "${YELLOW}======================================================${PLAIN}"
        echo -e "${YELLOW} 检测到当前目录存在 $file_count 个历史文件。${PLAIN}"
        echo -e "为了确保脚本运行在最新状态，建议在【空文件夹】下运行。"
        echo -e ""
        read -p "是否清空当前目录并强制更新所有组件? (y/n, 默认 n): " clean_opt
        if [[ "$clean_opt" == "y" ]]; then
            ls | grep -v "^$current_script$" | xargs rm -rf
            echo -e "${GREEN}清理完成，即将下载最新组件。${PLAIN}"; sleep 1
        fi
    fi
}

init_urls() {
    echo -e "${YELLOW}正在同步最新脚本列表...${PLAIN}"
    wget -T 20 -t 3 -qO "$LOCAL_LIST_FILE" "${URL_LIST_FILE}?t=$(date +%s)"
    if [[ $? -ne 0 ]]; then
        [[ -f "$LOCAL_LIST_FILE" ]] && echo -e "${YELLOW}网络异常，使用本地缓存列表。${PLAIN}" || { echo -e "${RED}致命错误: 无法获取脚本列表。${PLAIN}"; exit 1; }
    else
        echo -e "${GREEN}同步完成。${PLAIN}"
    fi
}

get_url_by_name() {
    grep "^$1" "$LOCAL_LIST_FILE" | awk '{print $2}' | head -n 1
}

check_run() {
    local script_name="$1"
    local no_pause="$2"
    if [[ ! -f "$script_name" ]]; then
        echo -e "${YELLOW}正在获取组件 [$script_name] ...${PLAIN}"
        local script_url=$(get_url_by_name "$script_name")
        [[ -z "$script_url" ]] && { echo -e "${RED}错误: sh_url.txt 中未找到该文件记录。${PLAIN}"; read -p "按回车继续..."; return; }
        mkdir -p "$(dirname "$script_name")"
        wget -qO "$script_name" "${script_url}?t=$(date +%s)"
        [[ $? -ne 0 ]] && { echo -e "${RED}下载失败。${PLAIN}"; read -p "按回车继续..."; return; }
        chmod +x "$script_name"
    fi
    ./"$script_name"
    [[ "$no_pause" != "true" ]] && { echo -e ""; read -p "操作结束，按回车键继续..."; }
}

# ==========================================
# 3. 子菜单逻辑 (排版还原)
# ==========================================

menu_singbox_env() {
    while true; do
        clear
        echo -e "${BLUE}============= Sing-box 核心环境管理 =============${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 安装/重置 Sing-box 核心 (最新正式版)"
        echo -e " ${SKYBLUE}2.${PLAIN} ${RED}彻底卸载 Sing-box 服务${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e " ${GRAY}99. 返回总菜单${PLAIN}"
        echo ""
        read -p "请选择: " sb_choice
        case "$sb_choice" in
            1) check_run "$FILE_SB_CORE" ;;
            2) check_run "$FILE_SB_UNINSTALL" ;;
            0) return ;;
            99) show_main_menu ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu_nodes_sb() {
    while true; do
        clear
        echo -e "${BLUE}============= Sing-box 节点配置管理 =============${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 新增: AnyTLS-Reality (Sing-box 专属 / 极度拟态)"
        echo -e " ${SKYBLUE}2.${PLAIN} 新增: VLESS-Vision-Reality (极稳定 - 推荐)"
        echo -e " ${SKYBLUE}3.${PLAIN} 新增: VLESS-WS-TLS (CDN / Nginx前置)"
        echo -e " ${SKYBLUE}4.${PLAIN} 新增: VLESS-WS-Tunnel (Tunnel穿透专用)"
        echo -e " ${SKYBLUE}5.${PLAIN} 新增: Hysteria2 (自签证书 - 极速/跳过验证)"
        echo -e " ${SKYBLUE}6.${PLAIN} 新增: Hysteria2 (ACME证书 - 推荐/标准HTTPS)"
        echo -e " ----------------------------------------------"
        echo -e " ${SKYBLUE}7.${PLAIN} 查看: 当前节点链接 / 分享信息"
        echo -e " ${SKYBLUE}8.${PLAIN} ${RED}删除: 删除指定节点 / 清空配置${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e " ${GRAY}99. 返回总菜单${PLAIN}"
        echo ""
        read -p "请选择: " choice
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
            99) show_main_menu ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu_routing_sb() {
    while true; do
        clear
        echo -e "${BLUE}============= Sing-box 核心路由管理 =============${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} Native WARP (原生 WireGuard 模式 - 推荐)"
        echo -e "    ${GRAY}- 自动注册账号，支持 ChatGPT/Netflix 分流${PLAIN}"
        echo -e " ${GREEN}2.${PLAIN} Wireproxy WARP (Socks5 模式 - 待开发)"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e " ${GRAY}99. 返回总菜单${PLAIN}"
        echo ""
        read -p "请选择: " choice_sb_route
        case "$choice_sb_route" in
            1) check_run "$FILE_SB_NATIVE_WARP" "true" ;;
            2) echo -e "${RED}功能开发中...${PLAIN}"; sleep 2 ;;
            0) return ;;
            99) show_main_menu ;;
            *) echo -e "${RED}无效选择${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu_routing() {
    while true; do
        clear
        echo -e "${BLUE}============= 路由与分流规则 (Routing) =============${PLAIN}"
        echo -e " [Xray 核心路由]"
        echo -e " ${GREEN}1. Native WARP (原生模式 - 推荐)${PLAIN}"
        echo -e "    ${GRAY}- 内核直连，支持 全局/分流/指定节点接管${PLAIN}"
        echo ""
        echo -e " ${YELLOW}2. Wireproxy WARP (传统挂载模式)${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " [Sing-box 核心路由]"
        echo -e " ${GREEN}3. Sing-box 路由管理 (WARP & 分流)${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e " ${GRAY}99. 返回总菜单${PLAIN}"
        echo ""
        read -p "请选择: " choice
        case "$choice" in
            1) check_run "$FILE_NATIVE_WARP" "true" ;; 
            2) 
                while true; do
                    clear
                    echo -e "${YELLOW}>>> [传统模式] Wireproxy 挂载管理${PLAIN}"
                    echo -e " 1. 挂载 WARP/Socks5"
                    echo -e " 2. 解除 挂载"
                    echo -e " 0. 返回"
                    read -p "选择: " sub_c
                    case "$sub_c" in
                        1) check_run "$FILE_ATTACH" ;;
                        2) check_run "$FILE_DETACH" ;;
                        0) break ;;
                    esac
                done
                ;;
            3) menu_routing_sb ;;
            0) break ;;
            99) show_main_menu ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# --- 其他菜单 (省略详细内容以对齐排版) ---
menu_core() {
    while true; do
        clear
        echo -e "${BLUE}============= 前置/核心管理 (Core) =============${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 安装/重置 Xray 核心"
        echo -e " ${SKYBLUE}2.${PLAIN} ${RED}彻底卸载 Xray 服务${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " ${SKYBLUE}3.${PLAIN} Sing-box 核心管理"
        echo -e " ${SKYBLUE}4.${PLAIN} WireProxy (Socks5)"
        echo -e " ${SKYBLUE}5.${PLAIN} Cloudflare Tunnel"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e ""
        read -p "选择: " choice
        case "$choice" in
            1) check_run "$FILE_XRAY_CORE" ;; 2) check_run "$FILE_XRAY_UNINSTALL" ;;
            3) menu_singbox_env ;; 4) check_run "$FILE_WIREPROXY" ;;
            5) check_run "$FILE_CF_TUNNEL" ;; 0) break ;;
        esac
    done
}

menu_nodes() {
    while true; do
        clear
        echo -e "${BLUE}============= 节点配置管理 (Nodes) =============${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} Xray 核心节点管理"
        echo -e " ${SKYBLUE}2.${PLAIN} Sing-box 节点管理"
        echo -e " ----------------------------------------------"
        echo -e " ${SKYBLUE}3.${PLAIN} 独立 Hysteria 2"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo ""
        read -p "选择: " choice
        case "$choice" in
            1) check_run "$FILE_ADD_XHTTP" ;; 2) menu_nodes_sb ;;
            3) check_run "$FILE_HY2" ;; 0) break ;;
        esac
    done
}

# ==========================================
# 4. 主程序入口
# ==========================================

show_main_menu() {
    while true; do
        clear
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e "${GREEN}      全能协议管理中心 (Commander v3.9.9)      ${PLAIN}"
        echo -e "${GREEN}============================================${PLAIN}"
        
        STATUS_TEXT=""
        pgrep -x "xray" >/dev/null && STATUS_TEXT+="Xray:${GREEN}运行 ${PLAIN}" || STATUS_TEXT+="Xray:${RED}停止 ${PLAIN}"
        pgrep -x "sing-box" >/dev/null && STATUS_TEXT+="| SB:${GREEN}运行 ${PLAIN}" || STATUS_TEXT+="| SB:${RED}停止 ${PLAIN}"
        
        echo -e " 系统状态: [$STATUS_TEXT]"
        echo -e "--------------------------------------------"
        echo -e " ${SKYBLUE}1.${PLAIN} 前置/核心管理 (Core & Infrastructure)"
        echo -e " ${SKYBLUE}2.${PLAIN} 节点配置管理 (Nodes)"
        echo -e " ${SKYBLUE}3.${PLAIN} 路由规则管理 (Routing & WARP) ${YELLOW}★${PLAIN}"
        echo -e " ${SKYBLUE}4.${PLAIN} 系统优化工具 (BBR/Cert/Logs)"
        echo -e "--------------------------------------------"
        echo -e " ${GRAY}0. 退出脚本${PLAIN}"
        echo ""
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
