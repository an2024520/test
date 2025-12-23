#!/bin/bash
# ============================================================
#  Commander Auto-Deploy (v5.1 Logic Fix)
#  - 核心修复: 修复 Tag 聚合污染问题，实现 Tag 核心级隔离
#  - 逻辑确认: 节点部署完成后 -> 统一执行 WARP 路由
# ============================================================

# --- 基础定义 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
RED='\033[0;31m'
PLAIN='\033[0m'

URL_LIST="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/sh_url.txt"
LOCAL_LIST="/tmp/sh_url.txt"

# --- 1. 执行引擎 (Backend Executor) ---

init_urls() {
    wget -qO "$LOCAL_LIST" "$URL_LIST"
}

run() {
    local script=$1
    if [ ! -f "$script" ]; then
        local url
        url=$(grep "^$script" "$LOCAL_LIST" | awk '{print $2}' | head -1)
        if [[ -z "$url" ]]; then
            echo -e "${RED}[错误] 无法找到脚本: $script${PLAIN}"
            return 1
        fi
        echo -e "   > 下载: $script ..."
        wget -qO "$script" "$url" && chmod +x "$script"
    fi
    ./"$script"
}

deploy_logic() {
    clear
    echo -e "${GREEN}>>> 正在处理您的订单 (开始部署)...${PLAIN}"
    init_urls
    
    # 定义两个独立的 Tag 蓄水池
    local SB_TAGS_ACC=""
    local XRAY_TAGS_ACC=""

    # === 1. 部署 Sing-box 体系 ===
    if [[ "$INSTALL_SB" == "true" ]]; then
        echo -e "${GREEN}>>> [Sing-box] 部署核心...${PLAIN}"
        run "sb_install_core.sh"
        
        if [[ "$DEPLOY_SB_VISION" == "true" ]]; then
            echo -e "${GREEN}>>> [SB] Vision 节点 (端口: ${VAR_SB_VISION_PORT})...${PLAIN}"
            PORT=$VAR_SB_VISION_PORT run "sb_vless_vision_reality.sh"
            # 记录 Tag 到 SB 蓄水池
            SB_TAGS_ACC+="Vision-${VAR_SB_VISION_PORT},"
        fi
        
        if [[ "$DEPLOY_SB_WS" == "true" ]]; then
             echo -e "${GREEN}>>> [SB] WS 节点 (端口: ${VAR_SB_WS_PORT})...${PLAIN}"
             PORT=$VAR_SB_WS_PORT run "sb_vless_ws_tls.sh"
             SB_TAGS_ACC+="WS-${VAR_SB_WS_PORT},"
        fi
    fi

    # === 2. 部署 Xray 体系 ===
    if [[ "$INSTALL_XRAY" == "true" ]]; then
        echo -e "${GREEN}>>> [Xray] 部署核心...${PLAIN}"
        run "xray_core.sh"
        
        if [[ "$DEPLOY_XRAY_VISION" == "true" ]]; then
            echo -e "${GREEN}>>> [Xray] Vision 节点 (端口: ${VAR_XRAY_VISION_PORT})...${PLAIN}"
            PORT=$VAR_XRAY_VISION_PORT run "xray_vless_vision_reality.sh"
            # 记录 Tag 到 Xray 蓄水池
            XRAY_TAGS_ACC+="Vision-${VAR_XRAY_VISION_PORT},"
        fi
    fi

    # === 3. 部署 WARP (智能分发 + 隔离) ===
    if [[ "$INSTALL_WARP" == "true" ]]; then
        echo -e "${GREEN}>>> [WARP] 正在配置出站与路由...${PLAIN}"
        
        # [逻辑分支 A] 应用于 Sing-box
        if [[ "$INSTALL_SB" == "true" ]]; then
            echo -e "${GREEN}   > 正在配置 Sing-box 核心...${PLAIN}"
            
            # 仅分发 Sing-box 的 Tags
            export WARP_INBOUND_TAGS="${SB_TAGS_ACC%,}"
            
            if [[ "$WARP_MODE_SELECT" == "3" ]] && [[ -n "$WARP_INBOUND_TAGS" ]]; then
                 echo -e "     [分流目标] ${SKYBLUE}${WARP_INBOUND_TAGS}${PLAIN}"
            fi
            
            run "sb_module_warp_native_route.sh"
        fi
        
        # [逻辑分支 B] 应用于 Xray
        if [[ "$INSTALL_XRAY" == "true" ]]; then
            echo -e "${GREEN}   > 正在配置 Xray 核心...${PLAIN}"
            
            # 仅分发 Xray 的 Tags
            export WARP_INBOUND_TAGS="${XRAY_TAGS_ACC%,}"
            
            if [[ "$WARP_MODE_SELECT" == "3" ]] && [[ -n "$WARP_INBOUND_TAGS" ]]; then
                 echo -e "     [分流目标] ${SKYBLUE}${WARP_INBOUND_TAGS}${PLAIN}"
            fi
            
            run "xray_module_warp_native_route.sh"
        fi
    fi

    # === 4. Argo Tunnel ===
    if [[ "$INSTALL_ARGO" == "true" ]]; then
        echo -e "${GREEN}>>> [Argo] 配置 Tunnel...${PLAIN}"
        run "install_cf_tunnel_debian.sh"
    fi

    echo -e "${GREEN}>>> 所有任务执行完毕。${PLAIN}"
    exit 0
}

# ============================================================
#  2. 交互界面 (Frontend UI)
# ============================================================

get_status() {
    if [[ "$1" == "true" ]]; then echo -e "${GREEN}[已选]${PLAIN}"; else echo -e "${PLAIN}[    ]${PLAIN}"; fi
}

show_dashboard() {
    clear
    echo -e "${SKYBLUE}==============================================${PLAIN}"
    echo -e "${SKYBLUE}    Commander 自动部署 - 选购清单 v5.1     ${PLAIN}"
    echo -e "${SKYBLUE}==============================================${PLAIN}"
    
    echo -e "${YELLOW}--- 核心与协议 ---${PLAIN}"
    if [[ "$INSTALL_SB" == "true" ]]; then
        echo -n "  Sing-box    : ${GREEN}安装${PLAIN}"
        [[ "$DEPLOY_SB_VISION" == "true" ]] && echo -n " | Vision(:$VAR_SB_VISION_PORT)"
        [[ "$DEPLOY_SB_WS" == "true" ]] && echo -n " | WS(:$VAR_SB_WS_PORT)"
        echo ""
    fi
    if [[ "$INSTALL_XRAY" == "true" ]]; then
        echo -n "  Xray        : ${GREEN}安装${PLAIN}"
        [[ "$DEPLOY_XRAY_VISION" == "true" ]] && echo -n " | Vision(:$VAR_XRAY_VISION_PORT)"
        echo ""
    fi
    
    echo -e "${YELLOW}--- WARP 出口优化 ---${PLAIN}"
    if [[ "$INSTALL_WARP" == "true" ]]; then
        echo -n "  WARP 路由   : ${GREEN}启用${PLAIN}"
        case "$WARP_MODE_SELECT" in
            1) echo -n " (分流: IPv4优先)";;
            2) echo -n " (分流: IPv6优先)";;
            3) echo -n " (分流: 指定节点接管)";;
            *) echo -n " (默认)";;
        esac
        if [[ -n "$WARP_PRIV_KEY" ]]; then echo -n " [自备账号]"; else echo -n " [自动注册]"; fi
        echo ""
    else
        echo -e "  WARP 路由   : 未启用"
    fi

    echo -e "${YELLOW}--- 附加组件 ---${PLAIN}"
    if [[ "$INSTALL_ARGO" == "true" ]]; then
        echo -e "  Argo Tunnel : ${GREEN}启用${PLAIN} (Domain: ${ARGO_DOMAIN})"
    else
        echo -e "  Argo Tunnel : 未启用"
    fi
    echo -e "=============================================="
}

# --- 菜单: 协议选择 ---
menu_protocols() {
    while true; do
        clear; echo -e "${SKYBLUE}=== 协议选择 ===${PLAIN}"
        echo -e " 1. $(get_status $DEPLOY_SB_VISION) SB-Vision"; 
        echo -e " 2. $(get_status $DEPLOY_XRAY_VISION) Xray-Vision"; 
        echo " 0. 返回"
        read -p "选择: " c
        case $c in
            1) if [[ "$DEPLOY_SB_VISION" == "true" ]]; then DEPLOY_SB_VISION=false; else DEPLOY_SB_VISION=true; INSTALL_SB=true; read -p "端口(443): " p; VAR_SB_VISION_PORT="${p:-443}"; fi ;;
            2) if [[ "$DEPLOY_XRAY_VISION" == "true" ]]; then DEPLOY_XRAY_VISION=false; else DEPLOY_XRAY_VISION=true; INSTALL_XRAY=true; read -p "端口(1443): " p; VAR_XRAY_VISION_PORT="${p:-1443}"; fi ;;
            0) break ;;
        esac
    done
}

# --- 菜单: WARP 配置 ---
menu_warp() {
    while true; do
        clear
        echo -e "${SKYBLUE}=== WARP 路由出口配置 ===${PLAIN}"
        echo ""
        echo -e "当前状态: $(get_status $INSTALL_WARP)"
        echo ""
        echo -e " 1. 启用 WARP"
        echo -e " 2. 配置 WARP 账号 (自动注册 / 手动录入)"
        echo -e " 3. 选择分流模式 [当前: ${WARP_MODE_SELECT:-未选}]"
        echo -e " 4. 禁用 WARP"
        echo ""
        echo -e " 0. 返回"
        echo ""
        read -p "请选择: " w_choice
        case $w_choice in
            1) INSTALL_WARP=true; [[ -z "$WARP_MODE_SELECT" ]] && WARP_MODE_SELECT=1 ;;
            2) 
                echo -e "   1. 自动注册免费账号 (默认)"
                echo -e "   2. 手动录入 (Private Key / IPv6 / Reserved)"
                read -p "   选择: " acc_type
                if [[ "$acc_type" == "2" ]]; then
                    read -p "   Private Key: " k; export WARP_PRIV_KEY="$k"
                    read -p "   IPv6 Address (xxxx:xxxx:...): " i; export WARP_IPV6="$i"
                    read -p "   Reserved ([x,x,x] 或 base64): " r; export WARP_RESERVED="$r"
                else
                    unset WARP_PRIV_KEY WARP_IPV6 WARP_RESERVED
                    echo -e "   -> 已设为自动注册模式"
                fi
                ;;
            3) 
                echo -e "   1. IPv4 优先 (全局 IPv4 流量走 WARP)"
                echo -e "   2. IPv6 优先 (全局 IPv6 流量走 WARP)"
                echo -e "   3. 指定节点接管 (仅选中的节点出口走 WARP)"
                read -p "   选择模式 (1-3): " m
                if [[ "$m" =~ ^[1-3]$ ]]; then export WARP_MODE_SELECT="$m"; fi
                ;;
            4) INSTALL_WARP=false; unset WARP_MODE_SELECT WARP_PRIV_KEY WARP_IPV6 WARP_RESERVED ;;
            0) break ;;
        esac
    done
}

# --- 菜单: Argo ---
menu_argo() {
    while true; do
        clear; echo -e "${SKYBLUE}=== Argo 配置 ===${PLAIN}"
        echo -e " 1. 启用/配置"; echo " 0. 返回"
        read -p "选择: " c
        case $c in
            1) INSTALL_ARGO=true; read -p "Token: " t; export ARGO_AUTH="$t"; read -p "Domain: " d; export ARGO_DOMAIN="$d" ;;
            0) break ;;
        esac
    done
}

# --- 主循环 ---
export AUTO_SETUP=true
if [[ -n "$INSTALL_SB" ]] || [[ -n "$INSTALL_XRAY" ]] || [[ -n "$INSTALL_ARGO" ]]; then
    deploy_logic; exit 0
fi

while true; do
    show_dashboard
    echo -e " ${GREEN}1.${PLAIN} 协议选择"; echo -e " ${GREEN}2.${PLAIN} WARP 路由配置"; echo -e " ${GREEN}3.${PLAIN} Argo 隧道"
    echo -e " -------------------------"; echo -e " ${GREEN}0. 开始部署${PLAIN}"
    read -p "选项: " m
    case $m in
        1) menu_protocols ;;
        2) menu_warp ;;
        3) menu_argo ;;
        0) deploy_logic; break ;;
    esac
done
