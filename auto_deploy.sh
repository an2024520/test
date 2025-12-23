#!/bin/bash
# ============================================================
#  Commander Auto-Deploy (v3.0 Menu Style)
#  - 核心理念: 超市选购模式 (Dashboard + Sub-menus)
#  - 架构: 交互界面 (UI) 与 执行引擎 (Executor) 完全分离
# ============================================================

# --- 基础定义 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
RED='\033[0;31m'
PLAIN='\033[0m'

URL_LIST="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/sh_url.txt"
LOCAL_LIST="/tmp/sh_url.txt"

# ============================================================
#  1. 执行引擎 (Backend Executor)
#  负责根据全局变量下载并运行脚本
# ============================================================

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
    
    # --- 1. Argo Tunnel ---
    if [[ "$INSTALL_ARGO" == "true" ]]; then
        echo -e "${GREEN}>>> [Argo] 配置 Tunnel...${PLAIN}"
        run "install_cf_tunnel_debian.sh"
    fi

    # --- 2. Sing-box 体系 ---
    if [[ "$INSTALL_SB" == "true" ]]; then
        echo -e "${GREEN}>>> [Sing-box] 部署核心...${PLAIN}"
        run "sb_install_core.sh"
        
        # 端口变量行内注入 (Isolation)
        if [[ "$DEPLOY_SB_VISION" == "true" ]]; then
            echo -e "${GREEN}>>> [SB] Vision 节点 (端口: ${VAR_SB_VISION_PORT})...${PLAIN}"
            PORT=$VAR_SB_VISION_PORT run "sb_vless_vision_reality.sh"
        fi
        
        # 预留给 WS 或 Hy2
        if [[ "$DEPLOY_SB_WS" == "true" ]]; then
             echo -e "${GREEN}>>> [SB] WS 节点 (端口: ${VAR_SB_WS_PORT})...${PLAIN}"
             PORT=$VAR_SB_WS_PORT run "sb_vless_ws_tls.sh"
        fi
    fi

    # --- 3. Xray 体系 ---
    if [[ "$INSTALL_XRAY" == "true" ]]; then
        echo -e "${GREEN}>>> [Xray] 部署核心...${PLAIN}"
        run "xray_core.sh"
        
        if [[ "$DEPLOY_XRAY_VISION" == "true" ]]; then
            echo -e "${GREEN}>>> [Xray] Vision 节点 (端口: ${VAR_XRAY_VISION_PORT})...${PLAIN}"
            PORT=$VAR_XRAY_VISION_PORT run "xray_vless_vision_reality.sh"
        fi
    fi

    echo -e "${GREEN}>>> 所有任务执行完毕。${PLAIN}"
    exit 0
}

# ============================================================
#  2. 交互界面 (Frontend UI)
#  超市货架逻辑
# ============================================================

# --- 辅助显示函数 ---
get_status() {
    if [[ "$1" == "true" ]]; then
        echo -e "${GREEN}[已选]${PLAIN}"
    else
        echo -e "${PLAIN}[    ]${PLAIN}"
    fi
}

show_dashboard() {
    clear
    echo -e "${SKYBLUE}==============================================${PLAIN}"
    echo -e "${SKYBLUE}       Commander 自动部署 - 选购清单       ${PLAIN}"
    echo -e "${SKYBLUE}==============================================${PLAIN}"
    
    # 购物车预览区
    echo -e "${YELLOW}--- 全局配置 ---${PLAIN}"
    echo -e "  UUID        : ${GREEN}${UUID:-"随机生成"}${PLAIN}"
    echo -e "  Reality域名 : ${GREEN}${REALITY_DOMAIN:-"默认"}${PLAIN}"
    
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
    if [[ "$INSTALL_SB" != "true" ]] && [[ "$INSTALL_XRAY" != "true" ]]; then
        echo -e "  (暂未选择任何核心)"
    fi

    echo -e "${YELLOW}--- 附加组件 ---${PLAIN}"
    if [[ "$INSTALL_ARGO" == "true" ]]; then
        echo -e "  Argo Tunnel : ${GREEN}启用${PLAIN} (Domain: ${ARGO_DOMAIN})"
    else
        echo -e "  Argo Tunnel : 未启用"
    fi
    echo -e "=============================================="
}

# --- 子菜单 1: 协议选择 ---
menu_protocols() {
    while true; do
        clear
        echo -e "${SKYBLUE}=== 协议选择货架 ===${PLAIN}"
        echo -e "说明: 选择对应数字开启/关闭协议，开启时会询问端口。"
        echo ""
        echo -e "${YELLOW}[Sing-box 系列]${PLAIN}"
        echo -e " 1. $(get_status $DEPLOY_SB_VISION) VLESS-Vision-Reality"
        echo -e " 2. $(get_status $DEPLOY_SB_WS) VLESS-WS-TLS (CDN)"
        echo ""
        echo -e "${YELLOW}[Xray 系列]${PLAIN}"
        echo -e " 3. $(get_status $DEPLOY_XRAY_VISION) VLESS-Vision-Reality"
        echo ""
        echo -e " 0. 返回主菜单"
        echo ""
        read -p "请选择 (Toggle): " p_choice

        case $p_choice in
            1)
                if [[ "$DEPLOY_SB_VISION" == "true" ]]; then
                    DEPLOY_SB_VISION=false
                    INSTALL_SB=false # 简易逻辑：如果关了唯一的节点，核心标记也可能需要处理，这里暂且简化
                    # 更严谨的逻辑是检查是否有任意 SB 节点开启
                else
                    DEPLOY_SB_VISION=true
                    INSTALL_SB=true
                    read -p "   请输入 Sing-box Vision 端口 (默认443): " p
                    VAR_SB_VISION_PORT="${p:-443}"
                fi
                ;;
            2)
                if [[ "$DEPLOY_SB_WS" == "true" ]]; then
                    DEPLOY_SB_WS=false
                else
                    DEPLOY_SB_WS=true
                    INSTALL_SB=true
                    read -p "   请输入 Sing-box WS 端口 (默认8443): " p
                    VAR_SB_WS_PORT="${p:-8443}"
                fi
                ;;
            3)
                if [[ "$DEPLOY_XRAY_VISION" == "true" ]]; then
                    DEPLOY_XRAY_VISION=false
                    # INSTALL_XRAY check logic...
                else
                    DEPLOY_XRAY_VISION=true
                    INSTALL_XRAY=true
                    read -p "   请输入 Xray Vision 端口 (默认1443): " p
                    VAR_XRAY_VISION_PORT="${p:-1443}"
                fi
                ;;
            0) break ;;
            *) ;;
        esac
    done
}

# --- 子菜单 2: 全局配置 ---
menu_global() {
    while true; do
        clear
        echo -e "${SKYBLUE}=== 全局参数设置 ===${PLAIN}"
        echo ""
        echo -e " 1. 设置统一 UUID [当前: ${GREEN}${UUID:-随机}${PLAIN}]"
        echo -e " 2. 设置 Reality 目标域名 [当前: ${GREEN}${REALITY_DOMAIN:-默认}${PLAIN}]"
        echo ""
        echo -e " 0. 返回主菜单"
        echo ""
        read -p "请选择: " g_choice
        case $g_choice in
            1)
                read -p "请输入 UUID (留空则恢复随机): " u
                export UUID="$u"
                ;;
            2)
                read -p "请输入目标域名 (例如 www.sony.jp): " d
                export REALITY_DOMAIN="$d"
                ;;
            0) break ;;
        esac
    done
}

# --- 子菜单 3: Argo ---
menu_argo() {
    while true; do
        clear
        echo -e "${SKYBLUE}=== Argo Tunnel 配置 ===${PLAIN}"
        echo ""
        echo -e "当前状态: $(get_status $INSTALL_ARGO)"
        echo ""
        echo -e " 1. 启用/配置 Argo"
        echo -e " 2. 禁用 Argo"
        echo ""
        echo -e " 0. 返回主菜单"
        echo ""
        read -p "请选择: " a_choice
        case $a_choice in
            1)
                export INSTALL_ARGO=true
                echo -e "${YELLOW}请输入 Cloudflare Tunnel Token:${PLAIN}"
                read -p "> " tk
                export ARGO_AUTH="$tk"
                
                echo -e "${YELLOW}请输入固定域名 (Tunnel Domain):${PLAIN}"
                read -p "> " dom
                export ARGO_DOMAIN="$dom"
                ;;
            2)
                export INSTALL_ARGO=false
                unset ARGO_AUTH
                unset ARGO_DOMAIN
                ;;
            0) break ;;
        esac
    done
}

# --- 主循环 (Main Loop) ---

# 开启自动模式全局开关
export AUTO_SETUP=true

# 如果有外部变量传入(高级模式)，直接跳过菜单
if [[ -n "$INSTALL_SB" ]] || [[ -n "$INSTALL_XRAY" ]] || [[ -n "$INSTALL_ARGO" ]]; then
    deploy_logic
    exit 0
fi

while true; do
    show_dashboard
    echo -e " ${GREEN}1.${PLAIN} 协议选择 (Sing-box / Xray)"
    echo -e " ${GREEN}2.${PLAIN} 全局配置 (UUID / 域名)"
    echo -e " ${GREEN}3.${PLAIN} Argo 隧道配置"
    echo -e " -------------------------"
    echo -e " ${GREEN}0. 确认清单并开始部署${PLAIN}"
    echo ""
    read -p "请输入选项 [0-3]: " main_choice
    
    case $main_choice in
        1) menu_protocols ;;
        2) menu_global ;;
        3) menu_argo ;;
        0) 
            # 简单检查是否至少选了一个
            if [[ "$INSTALL_SB" != "true" ]] && [[ "$INSTALL_XRAY" != "true" ]] && [[ "$INSTALL_ARGO" != "true" ]]; then
                echo -e "${RED}您购物车是空的！请至少选择一个组件。${PLAIN}"
                sleep 2
            else
                deploy_logic 
                break
            fi
            ;;
        *) echo -e "${RED}无效选项${PLAIN}" ; sleep 1 ;;
    esac
done
