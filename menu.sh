#!/bin/bash

# ============================================================
#  全能协议管理中心 (Commander v3.5)
#  - 架构: Core / Nodes / Routing / Tools
#  - 特性: 动态链接 / 环境自洁 / 模块化路由
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

# [文件映射: 本地文件名 <-> sh_url.txt 中的 Key]
# 核心类
FILE_XRAY_CORE="xray_core.sh"
FILE_XRAY_UNINSTALL="xray_uninstall_all.sh"
FILE_WIREPROXY="warp_wireproxy_socks5.sh"
FILE_CF_TUNNEL="install_cf_tunnel_debian.sh"

# 节点类
FILE_ADD_XHTTP="xray_vless_xhttp_reality.sh"
FILE_ADD_VISION="xray_vless_vision_reality.sh"
FILE_ADD_WS="xray_vless_ws_tls.sh"
FILE_ADD_TUNNEL="xray_vless_ws_tunnel.sh"
FILE_NODE_INFO="xray_get_node_details.sh"
FILE_NODE_DEL="xray_module_node_del.sh"
FILE_HY2="hy2.sh"

# 路由与工具类
FILE_NATIVE_WARP="xray_module_warp_native_route.sh"         # ★ 新模块
FILE_ATTACH="xray_module_attach_warp.sh"  # 旧挂载
FILE_DETACH="xray_module_detach_warp.sh"  # 旧卸载
FILE_BOOST="xray_module_boost.sh"

# --- 引擎函数 (保持不变) ---

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
        echo -e ""
    fi
}

init_urls() {
    echo -e "${YELLOW}正在同步最新脚本列表...${PLAIN}"
    wget -T 5 -qO "$LOCAL_LIST_FILE" "$URL_LIST_FILE"
    if [[ $? -ne 0 ]]; then
        if [[ -f "$LOCAL_LIST_FILE" ]]; then echo -e "${YELLOW}网络异常，使用本地缓存列表。${PLAIN}"; else echo -e "${RED}致命错误: 无法获取脚本列表。${PLAIN}"; exit 1; fi
    else
        echo -e "${GREEN}同步完成。${PLAIN}"
    fi
}

get_url_by_name() {
    local fname="$1"
    grep "^$fname" "$LOCAL_LIST_FILE" | awk '{print $2}' | head -n 1
}

check_run() {
    local script_name="$1"
    if [[ ! -f "$script_name" ]]; then
        echo -e "${YELLOW}正在获取组件 [$script_name] ...${PLAIN}"
        local script_url=$(get_url_by_name "$script_name")
        if [[ -z "$script_url" ]]; then echo -e "${RED}错误: sh_url.txt 中未找到该文件记录。${PLAIN}"; read -p "按回车继续..."; return; fi
        wget -qO "$script_name" "$script_url"
        if [[ $? -ne 0 ]]; then echo -e "${RED}下载失败。${PLAIN}"; read -p "按回车继续..."; return; fi
        chmod +x "$script_name"
        echo -e "${GREEN}获取成功。${PLAIN}"
    fi
    ./"$script_name"
    echo -e ""; read -p "操作结束，按回车键继续..."
}

# ==========================================
# 2. 菜单逻辑 (新架构)
# ==========================================

# --- 1. 前置/核心管理 ---
menu_core() {
    while true; do
        clear
        echo -e "${BLUE}============= 前置/核心管理 (Core) =============${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} 安装/重置 Xray 核心环境"
        echo -e " ${SKYBLUE}2.${PLAIN} ${RED}彻底卸载 Xray 服务${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " ${SKYBLUE}3.${PLAIN} Sing-box 核心环境 (开发中...)"
        echo -e " ----------------------------------------------"
        echo -e " ${SKYBLUE}4.${PLAIN} WireProxy (Warp 出口代理服务)"
        echo -e "    ${GRAY}- 仅提供本地 Socks5 端口，需配合路由规则使用${PLAIN}"
        echo -e " ${SKYBLUE}5.${PLAIN} Cloudflare Tunnel (内网穿透)"
        echo -e "    ${GRAY}- 将本地节点映射到公网，自带 CDN${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e ""
        read -p "请选择: " choice
        case "$choice" in
            1) check_run "$FILE_XRAY_CORE" ;;
            2) check_run "$FILE_XRAY_UNINSTALL" ;;
            3) echo "敬请期待 Sing-box"; sleep 1 ;;
            4) check_run "$FILE_WIREPROXY" ;;
            5) check_run "$FILE_CF_TUNNEL" ;;
            0) break ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# --- 2. 节点管理 ---
menu_nodes() {
    while true; do
        clear
        echo -e "${BLUE}============= 节点配置管理 (Nodes) =============${PLAIN}"
        echo -e " [Xray 核心]"
        echo -e " ${SKYBLUE}1.${PLAIN} 新增: VLESS-XHTTP (Reality - 穿透强)"
        echo -e " ${SKYBLUE}2.${PLAIN} 新增: VLESS-Vision (Reality - 极稳定)"
        echo -e " ${SKYBLUE}3.${PLAIN} 新增: VLESS-WS-TLS (CDN / Nginx前置)"
        echo -e " ${SKYBLUE}4.${PLAIN} 新增: VLESS-WS-Tunnel (Tunnel穿透专用)"
        echo -e " ${SKYBLUE}5.${PLAIN} 查看: 当前节点链接 / 分享信息"
        echo -e " ${SKYBLUE}6.${PLAIN} ${RED}删除: 删除指定节点 / 清空配置${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " [其他核心]"
        echo -e " ${SKYBLUE}7.${PLAIN} 独立 Hysteria 2 节点管理"
        echo -e " ${SKYBLUE}8.${PLAIN} Sing-box 节点管理 (预留)"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e ""
        read -p "请选择: " choice
        case "$choice" in
            1) check_run "$FILE_ADD_XHTTP" ;;
            2) check_run "$FILE_ADD_VISION" ;;
            3) check_run "$FILE_ADD_WS" ;;
            4) check_run "$FILE_ADD_TUNNEL" ;;
            5) check_run "$FILE_NODE_INFO" ;;
            6) check_run "$FILE_NODE_DEL" ;;
            7) check_run "$FILE_HY2" ;;
            8) echo "敬请期待"; sleep 1 ;;
            0) break ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# --- 3. 路由规则管理 ---
menu_routing() {
    while true; do
        clear
        echo -e "${BLUE}============= 路由与分流规则 (Routing) =============${PLAIN}"
        echo -e " [Xray 核心路由]"
        echo -e " ${GREEN}1. Native WARP (原生模式 - 推荐)${PLAIN}"
        echo -e "    ${GRAY}- 内核直连，支持 全局/分流/指定节点接管${PLAIN}"
        echo -e ""
        echo -e " ${YELLOW}2. Wireproxy WARP (传统挂载模式)${PLAIN}"
        echo -e "    ${GRAY}- 需先在核心管理中安装 WireProxy 服务${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " [Sing-box 核心路由]"
        echo -e " ${GRAY}3. Sing-box 路由管理 (开发中...)${PLAIN}"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e ""
        read -p "请选择: " choice
        case "$choice" in
            1) check_run "$FILE_NATIVE_WARP" ;; # 直接调用新模块
            2) 
                while true; do
                    clear
                    echo -e "${YELLOW}>>> [传统模式] Wireproxy 挂载管理${PLAIN}"
                    echo -e " 1. 挂载 WARP/Socks5 (解锁流媒体)"
                    echo -e " 2. 解除 挂载 (恢复直连)"
                    echo -e " 0. 返回"
                    echo -e ""
                    read -p "请选择: " sub_c
                    case "$sub_c" in
                        1) check_run "$FILE_ATTACH" ;;
                        2) check_run "$FILE_DETACH" ;;
                        0) break ;;
                    esac
                done
                ;;
            3)
                # Sing-box 预留提示
                echo -e ""
                echo -e "${YELLOW}🚧 施工中...${PLAIN}"
                echo -e "Sing-box 的路由规则（Rule Set / 混合分流）功能即将上线。"
                echo -e "敬请期待双核路由系统的完整形态！"
                echo -e ""
                read -p "按回车键继续..."
                ;;
            0) break ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 3. 主程序入口
# ==========================================

check_dir_clean
init_urls

while true; do
    clear
    echo -e "${GREEN}============================================${PLAIN}"
    echo -e "${GREEN}      全能协议管理中心 (Commander v3.5)      ${PLAIN}"
    echo -e "${GREEN}============================================${PLAIN}"
    # 简单的状态检查 (可选)
    if pgrep -x "xray" >/dev/null; then STATUS="${GREEN}运行中${PLAIN}"; else STATUS="${RED}未运行${PLAIN}"; fi
    echo -e " 系统状态: [Xray: $STATUS]"
    echo -e "--------------------------------------------"
    echo -e " ${SKYBLUE}1.${PLAIN} 前置/核心管理 (Core & Infrastructure)"
    echo -e " ${SKYBLUE}2.${PLAIN} 节点配置管理 (Nodes)"
    echo -e " ${SKYBLUE}3.${PLAIN} 路由规则管理 (Routing & WARP) ${YELLOW}★${PLAIN}"
    echo -e " ${SKYBLUE}4.${PLAIN} 系统优化工具 (BBR/Cert/Logs)"
    echo -e "--------------------------------------------"
    echo -e " ${GRAY}0. 退出脚本${PLAIN}"
    echo -e ""
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
