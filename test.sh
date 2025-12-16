#!/bin/bash

# ============================================================
#  全能协议管理中心 (Commander v3.0)
#  - 基础设施: Warp/WireProxy
#  - 核心协议: Xray / Hysteria 2
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
GRAY='\033[0;37m'

# ==========================================
# 1. 脚本文件与下载源定义
# ==========================================

# --- A. 基础设施 (Warp) ---
# 独立出来，作为第一大类
FILE_WARP="warp_wireproxy_socks5.sh"
URL_WARP="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/warp/warp_wireproxy_socks5.sh"

# --- B. Xray 核心套件 (第二大类) ---
FILE_XRAY_CORE="xray_core.sh"
URL_XRAY_CORE="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_core.sh"

FILE_ADD_XHTTP="xray_vless_xhttp_reality.sh"
URL_ADD_XHTTP="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_vless_xhttp_reality.sh"

FILE_ADD_VISION="xray_vless_vision_reality.sh"
URL_ADD_VISION="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_vless_vision_reality.sh"

FILE_NODE_DEL="xray_module_node_del.sh"
URL_NODE_DEL="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_module_node_del.sh"

FILE_NODE_INFO="xray_get_node_details.sh"
URL_NODE_INFO="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray_get_node_details.sh"

FILE_ATTACH="xray_module_attach_warp.sh"
URL_ATTACH="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_module_attach_warp.sh"

FILE_DETACH="xray_module_detach_warp.sh"
URL_DETACH="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_module_detach_warp.sh"

FILE_BOOST="xray_module_boost.sh"
URL_BOOST="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_module_boost.sh"

FILE_XRAY_UNINSTALL="xray_uninstall_all.sh"
URL_XRAY_UNINSTALL="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_uninstall_all.sh"

# --- C. Hysteria 2 (第三大类) ---
FILE_HY2="hy2.sh"
URL_HY2="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/hy2/hy2.sh"


# ==========================================
# 2. 核心函数: 检查并下载运行
# ==========================================
check_run() {
    local script_name="$1"
    local script_url="$2"

    # 如果文件不存在，则下载
    if [[ ! -f "$script_name" ]]; then
        echo -e "${YELLOW}脚本 [$script_name] 不存在，正在下载...${PLAIN}"
        if [[ -z "$script_url" ]]; then
            echo -e "${RED}错误: 未定义下载地址。${PLAIN}"
            read -p "按回车键返回..."
            return
        fi
        
        wget -O "$script_name" "$script_url"
        
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}下载失败！请检查网络或 URL。${PLAIN}"
            read -p "按回车键返回..."
            return
        fi
        echo -e "${GREEN}下载成功！${PLAIN}"
    fi

    chmod +x "$script_name"
    ./"$script_name"
    
    echo -e ""
    read -p "操作结束，按回车键继续..."
}

# ==========================================
# 3. 子菜单逻辑
# ==========================================

# --- Xray 子菜单 ---
# 注意：移除了 "前置安装Warp" (因为已提级)，保留了 "挂载Warp出口" (因为这是Xray的路由功能)
menu_xray() {
    while true; do
        clear
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${GREEN}       Xray 宇宙 (The Xray Universe)     ${PLAIN}"
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${YELLOW}--- 基础建设 ---${PLAIN}"
        echo -e "  1. 安装/重置 Xray 核心 (Core)"
        echo -e "  2. 系统内核加速 (BBR + ECN)"
        echo -e ""
        echo -e "${YELLOW}--- 节点管理 ---${PLAIN}"
        echo -e "  3. 新增节点: VLESS-XHTTP (Reality - 穿透)"
        echo -e "  4. 新增节点: VLESS-Vision (Reality - 稳定)"
        echo -e "  5. 查看节点信息 / 分享链接"
        echo -e "  6. ${RED}删除/清空 节点${PLAIN}"
        echo -e ""
        echo -e "${YELLOW}--- 路由分流 (Warp出口) ---${PLAIN}"
        echo -e "  7. 节点挂载 Warp/Socks5 出口 (解锁流媒体)"
        echo -e "  8. 节点恢复 直连模式"
        echo -e ""
        echo -e "${GRAY}----------------------------------------${PLAIN}"
        echo -e "  9. ${RED}彻底卸载 Xray 服务${PLAIN}"
        echo -e "  0. 返回主菜单"
        echo -e ""
        read -p "请选择: " xray_choice

        case "$xray_choice" in
            1) check_run "$FILE_XRAY_CORE" "$URL_XRAY_CORE" ;;
            2) check_run "$FILE_BOOST" "$URL_BOOST" ;;
            3) check_run "$FILE_ADD_XHTTP" "$URL_ADD_XHTTP" ;;
            4) check_run "$FILE_ADD_VISION" "$URL_ADD_VISION" ;;
            5) check_run "$FILE_NODE_INFO" "$URL_NODE_INFO" ;;
            6) check_run "$FILE_NODE_DEL" "$URL_NODE_DEL" ;;
            7) check_run "$FILE_ATTACH" "$URL_ATTACH" ;;
            8) check_run "$FILE_DETACH" "$URL_DETACH" ;;
            9) check_run "$FILE_XRAY_UNINSTALL" "$URL_XRAY_UNINSTALL" ;;
            0) break ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 4. 主菜单逻辑
# ==========================================
while true; do
    clear
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    全能协议管理中心 (Total Commander)   ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${SKYBLUE}1.${PLAIN} 前置基础设施: WARP / WireProxy (Socks5)"
    echo -e "    ${GRAY}- 独立服务，为 Xray 或 Hy2 提供分流出口${PLAIN}"
    echo -e ""
    echo -e "${SKYBLUE}2.${PLAIN} Xray 协议簇"
    echo -e "    ${GRAY}- VLESS / Vision / XHTTP / Reality / 内核加速 / 卸载${PLAIN}"
    echo -e ""
    echo -e "${SKYBLUE}3.${PLAIN} Hysteria 2 协议"
    echo -e "    ${GRAY}- UDP / 端口跳跃 / 极速抗封锁${PLAIN}"
    echo -e ""
    echo -e "----------------------------------------"
    echo -e "${GRAY}0. 退出系统${PLAIN}"
    echo -e ""
    read -p "请选择操作 [0-3]: " main_choice

    case "$main_choice" in
        1) check_run "$FILE_WARP" "$URL_WARP" ;;
        2) menu_xray ;;
        3) check_run "$FILE_HY2" "$URL_HY2" ;;
        0) echo -e "Bye~"; exit 0 ;;
        *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
    esac
done
