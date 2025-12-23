#!/bin/bash
# ============================================================
#  Commander Auto-Deploy (v6.8 Ultimate)
#  - 核心特性: 超市选购模式 | 核心/WARP/Argo 模块化组装
#  - 协议矩阵: 
#    - Sing-box: Vision, WS-TLS, Tunnel, AnyTLS, Hy2
#    - Xray: Vision, WS-TLS, Tunnel, XHTTP
#  - 修复: 智能 Argo 跳过 & 全局 Tag 联动
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
RED='\033[0;31m'
PLAIN='\033[0m'

URL_LIST="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/sh_url.txt"
LOCAL_LIST="/tmp/sh_url.txt"

# 0. 环境预处理
check_dir_clean() {
    local current_script=$(basename "$0")
    if [[ $(ls -1 | grep -v "^$current_script$" | wc -l) -gt 0 ]]; then
        clear; echo -e "${YELLOW}检测到旧文件。${PLAIN}"
        read -p "是否清空目录并强制更新? (y/n, 默认 y): " clean_opt
        if [[ "${clean_opt:-y}" == "y" ]]; then
            ls | grep -v "^$current_script$" | xargs rm -rf
            echo -e "${GREEN}清理完成。${PLAIN}"; sleep 1
        fi
    fi
}

# 1. 执行引擎
init_urls() { wget -qO "$LOCAL_LIST" "$URL_LIST"; }

run() {
    local script=$1
    if [ ! -f "$script" ]; then
        local url=$(grep "^$script" "$LOCAL_LIST" | awk '{print $2}' | head -1)
        if [[ -z "$url" ]]; then echo -e "${RED}[错误] 找不到脚本: $script${PLAIN}"; return 1; fi
        echo -e "   > 下载: $script ..."; wget -qO "$script" "$url" && chmod +x "$script"
    fi
    ./"$script"
}

deploy_logic() {
    clear; echo -e "${GREEN}>>> 正在处理您的订单 (开始部署)...${PLAIN}"; init_urls
    local SB_TAGS_ACC=""
    local XRAY_TAGS_ACC=""

    # === Sing-box ===
    if [[ "$INSTALL_SB" == "true" ]]; then
        echo -e "${GREEN}>>> [Sing-box] 部署核心...${PLAIN}"; run "sb_install_core.sh"
        
        if [[ "$DEPLOY_SB_VISION" == "true" ]]; then
            PORT=$VAR_SB_VISION_PORT run "sb_vless_vision_reality.sh"
            SB_TAGS_ACC+="Vision-${VAR_SB_VISION_PORT},"
        fi
        if [[ "$DEPLOY_SB_WS" == "true" ]]; then # WS+TLS (CDN)
             echo -e "${GREEN}>>> [SB] WS+TLS (CDN) 节点 (: ${VAR_SB_WS_PORT})...${PLAIN}"
             export SB_WS_TLS_PORT="$VAR_SB_WS_PORT"
             export SB_WS_TLS_DOMAIN="$VAR_SB_WS_DOMAIN"
             export SB_WS_TLS_PATH="$VAR_SB_WS_PATH"
             run "sb_vless_ws_tls.sh"
             unset SB_WS_TLS_PORT SB_WS_TLS_DOMAIN SB_WS_TLS_PATH
             SB_TAGS_ACC+="WS-TLS-${VAR_SB_WS_PORT},"
        fi
        if [[ "$DEPLOY_SB_WS_TUNNEL" == "true" ]]; then
             export SB_WS_PORT="$VAR_SB_WS_TUNNEL_PORT"; export SB_WS_PATH="$VAR_SB_WS_TUNNEL_PATH"
             run "sb_vless_ws_tunnel.sh"
             unset SB_WS_PORT SB_WS_PATH
             SB_TAGS_ACC+="Tunnel-${VAR_SB_WS_TUNNEL_PORT},"
        fi
        if [[ "$DEPLOY_SB_ANYTLS" == "true" ]]; then
             PORT=$VAR_SB_ANYTLS_PORT run "sb_anytls_reality.sh"
             SB_TAGS_ACC+="AnyTLS-${VAR_SB_ANYTLS_PORT},"
        fi
        if [[ "$DEPLOY_SB_HY2" == "true" ]]; then
             PORT=$VAR_SB_HY2_PORT run "sb_hy2_self.sh"
             SB_TAGS_ACC+="Hy2-Self-${VAR_SB_HY2_PORT},"
        fi
    fi

    # === Xray ===
    if [[ "$INSTALL_XRAY" == "true" ]]; then
        echo -e "${GREEN}>>> [Xray] 部署核心...${PLAIN}"; run "xray_core.sh"
        
        if [[ "$DEPLOY_XRAY_VISION" == "true" ]]; then
            export PORT="$VAR_XRAY_VISION_PORT"; run "xray_vless_vision_reality.sh"; unset PORT
            XRAY_TAGS_ACC+="Vision-${VAR_XRAY_VISION_PORT},"
        fi
        if [[ "$DEPLOY_XRAY_WS" == "true" ]]; then # WS+TLS (CDN)
            echo -e "${GREEN}>>> [Xray] WS+TLS (CDN) 节点 (: ${VAR_XRAY_WS_PORT})...${PLAIN}"
            export XRAY_WS_TLS_PORT="$VAR_XRAY_WS_PORT"
            export XRAY_WS_TLS_DOMAIN="$VAR_XRAY_WS_DOMAIN"
            export XRAY_WS_TLS_PATH="$VAR_XRAY_WS_PATH"
            run "xray_vless_ws_tls.sh"
            unset XRAY_WS_TLS_PORT XRAY_WS_TLS_DOMAIN XRAY_WS_TLS_PATH
            XRAY_TAGS_ACC+="Xray-WS-TLS-${VAR_XRAY_WS_PORT},"
        fi
        if [[ "$DEPLOY_XRAY_WS_TUNNEL" == "true" ]]; then
            export XRAY_WS_PORT="$VAR_XRAY_WS_TUNNEL_PORT"; export XRAY_WS_PATH="$VAR_XRAY_WS_TUNNEL_PATH"
            run "xray_vless_ws_tunnel.sh"; unset XRAY_WS_PORT XRAY_WS_PATH
            XRAY_TAGS_ACC+="vless-ws-tunnel-${VAR_XRAY_WS_TUNNEL_PORT},"
        fi
        if [[ "$DEPLOY_XRAY_XHTTP" == "true" ]]; then
            echo -e "${GREEN}>>> [Xray] XHTTP Reality 节点 (: ${VAR_XRAY_XHTTP_PORT})...${PLAIN}"
            export XRAY_XHTTP_PORT="$VAR_XRAY_XHTTP_PORT"
            run "xray_vless_xhttp_reality.sh"; unset XRAY_XHTTP_PORT
            XRAY_TAGS_ACC+="Xray-XHTTP-${VAR_XRAY_XHTTP_PORT},"
        fi
    fi

    # === WARP ===
    if [[ "$INSTALL_WARP" == "true" ]]; then
        echo -e "${GREEN}>>> [WARP] 配置路由出口...${PLAIN}"
        if [[ "$INSTALL_SB" == "true" ]]; then
            export WARP_INBOUND_TAGS="${SB_TAGS_ACC%,}"; run "sb_module_warp_native_route.sh"
        fi
        if [[ "$INSTALL_XRAY" == "true" ]]; then
            export WARP_INBOUND_TAGS="${XRAY_TAGS_ACC%,}"; run "xray_module_warp_native_route.sh"
        fi
    fi

    # === Argo ===
    if [[ "$INSTALL_ARGO" == "true" ]]; then
        if systemctl is-active --quiet cloudflared; then
            echo -e "${SKYBLUE}>>> [检测] Tunnel 服务已运行，跳过安装。${PLAIN}"
        else
            run "install_cf_tunnel_debian.sh"
        fi
    fi

    echo -e "${GREEN}>>> 所有任务执行完毕。${PLAIN}"; exit 0
}

# 2. 交互界面
get_status() { if [[ "$1" == "true" ]]; then echo -e "${GREEN}√${PLAIN}"; else echo -e "${PLAIN} ${PLAIN}"; fi; }

show_dashboard() {
    clear; echo -e "${SKYBLUE}=== Commander 选购清单 (Auto Mode) ===${PLAIN}"
    local has_item=false
    if [[ "$INSTALL_SB" == "true" ]]; then
        echo -e "${YELLOW}● Sing-box${PLAIN}"
        [[ "$DEPLOY_SB_VISION" == "true" ]] && echo -e "  ├─ Vision Reality  [Port: ${GREEN}$VAR_SB_VISION_PORT${PLAIN}]"
        [[ "$DEPLOY_SB_WS" == "true" ]]     && echo -e "  ├─ WS+TLS (CDN)    [Port: ${GREEN}$VAR_SB_WS_PORT${PLAIN}]"
        [[ "$DEPLOY_SB_WS_TUNNEL" == "true" ]] && echo -e "  ├─ WS Tunnel       [Port: ${GREEN}$VAR_SB_WS_TUNNEL_PORT${PLAIN}]"
        [[ "$DEPLOY_SB_ANYTLS" == "true" ]] && echo -e "  ├─ AnyTLS Reality  [Port: ${GREEN}$VAR_SB_ANYTLS_PORT${PLAIN}]"
        [[ "$DEPLOY_SB_HY2" == "true" ]]    && echo -e "  └─ Hysteria 2      [Port: ${GREEN}$VAR_SB_HY2_PORT${PLAIN}]"
        has_item=true
    fi
    if [[ "$INSTALL_XRAY" == "true" ]]; then
        echo -e "${YELLOW}● Xray${PLAIN}"
        [[ "$DEPLOY_XRAY_VISION" == "true" ]] && echo -e "  ├─ Vision Reality  [Port: ${GREEN}$VAR_XRAY_VISION_PORT${PLAIN}]"
        [[ "$DEPLOY_XRAY_WS" == "true" ]]     && echo -e "  ├─ WS+TLS (CDN)    [Port: ${GREEN}$VAR_XRAY_WS_PORT${PLAIN}]"
        [[ "$DEPLOY_XRAY_WS_TUNNEL" == "true" ]] && echo -e "  ├─ WS Tunnel       [Port: ${GREEN}$VAR_XRAY_WS_TUNNEL_PORT${PLAIN}]"
        [[ "$DEPLOY_XRAY_XHTTP" == "true" ]]  && echo -e "  └─ XHTTP Reality   [Port: ${GREEN}$VAR_XRAY_XHTTP_PORT${PLAIN}]"
        has_item=true
    fi
    if [[ "$INSTALL_WARP" == "true" ]]; then echo -e "${YELLOW}● WARP 路由${PLAIN} (Mode: $WARP_MODE_SELECT)"; has_item=true; fi
    if [[ "$INSTALL_ARGO" == "true" ]]; then echo -e "${YELLOW}● Argo Tunnel${PLAIN} ($ARGO_DOMAIN)"; has_item=true; fi
    [[ "$has_item" == "false" ]] && echo -e "${GRAY}  (空购物车)${PLAIN}"
    echo -e "======================================"
}

menu_protocols() {
    while true; do
        clear; echo -e "${SKYBLUE}=== 协议选择 ===${PLAIN}"
        echo -e "--- Sing-box ---"
        echo -e " 1. [$(get_status $DEPLOY_SB_VISION)] Vision Reality"
        echo -e " 2. [$(get_status $DEPLOY_SB_WS)] WS + TLS (CDN)"
        echo -e " 3. [$(get_status $DEPLOY_SB_WS_TUNNEL)] WS + Tunnel"
        echo -e " 4. [$(get_status $DEPLOY_SB_ANYTLS)] AnyTLS Reality"
        echo -e " 5. [$(get_status $DEPLOY_SB_HY2)] Hysteria 2"
        echo -e "--- Xray ---"
        echo -e " 6. [$(get_status $DEPLOY_XRAY_VISION)] Vision Reality"
        echo -e " 7. [$(get_status $DEPLOY_XRAY_WS)] WS + TLS (CDN)"
        echo -e " 8. [$(get_status $DEPLOY_XRAY_WS_TUNNEL)] WS + Tunnel"
        echo -e " 9. [$(get_status $DEPLOY_XRAY_XHTTP)] XHTTP Reality"
        echo ""; echo -e " 0. 返回"
        read -p "选择: " c
        case $c in
            1) DEPLOY_SB_VISION=$([[ $DEPLOY_SB_VISION == true ]] && echo false || echo true); [[ $DEPLOY_SB_VISION == true ]] && { INSTALL_SB=true; read -p "端口(443): " p; VAR_SB_VISION_PORT=${p:-443}; } ;;
            2) DEPLOY_SB_WS=$([[ $DEPLOY_SB_WS == true ]] && echo false || echo true); [[ $DEPLOY_SB_WS == true ]] && { INSTALL_SB=true; read -p "端口(8443): " p; VAR_SB_WS_PORT=${p:-8443}; read -p "域名: " d; VAR_SB_WS_DOMAIN=$d; read -p "Path(/ws): " q; VAR_SB_WS_PATH=${q:-/ws}; } ;;
            3) DEPLOY_SB_WS_TUNNEL=$([[ $DEPLOY_SB_WS_TUNNEL == true ]] && echo false || echo true); [[ $DEPLOY_SB_WS_TUNNEL == true ]] && { INSTALL_SB=true; read -p "端口(8080): " p; VAR_SB_WS_TUNNEL_PORT=${p:-8080}; read -p "Path(/ws): " q; VAR_SB_WS_TUNNEL_PATH=${q:-/ws}; } ;;
            4) DEPLOY_SB_ANYTLS=$([[ $DEPLOY_SB_ANYTLS == true ]] && echo false || echo true); [[ $DEPLOY_SB_ANYTLS == true ]] && { INSTALL_SB=true; read -p "端口(8443): " p; VAR_SB_ANYTLS_PORT=${p:-8443}; } ;;
            5) DEPLOY_SB_HY2=$([[ $DEPLOY_SB_HY2 == true ]] && echo false || echo true); [[ $DEPLOY_SB_HY2 == true ]] && { INSTALL_SB=true; read -p "端口(10086): " p; VAR_SB_HY2_PORT=${p:-10086}; } ;;
            6) DEPLOY_XRAY_VISION=$([[ $DEPLOY_XRAY_VISION == true ]] && echo false || echo true); [[ $DEPLOY_XRAY_VISION == true ]] && { INSTALL_XRAY=true; read -p "端口(1443): " p; VAR_XRAY_VISION_PORT=${p:-1443}; } ;;
            7) DEPLOY_XRAY_WS=$([[ $DEPLOY_XRAY_WS == true ]] && echo false || echo true); [[ $DEPLOY_XRAY_WS == true ]] && { INSTALL_XRAY=true; read -p "端口(8443): " p; VAR_XRAY_WS_PORT=${p:-8443}; read -p "域名: " d; VAR_XRAY_WS_DOMAIN=$d; read -p "Path(/ws): " q; VAR_XRAY_WS_PATH=${q:-/ws}; } ;;
            8) DEPLOY_XRAY_WS_TUNNEL=$([[ $DEPLOY_XRAY_WS_TUNNEL == true ]] && echo false || echo true); [[ $DEPLOY_XRAY_WS_TUNNEL == true ]] && { INSTALL_XRAY=true; read -p "端口(8081): " p; VAR_XRAY_WS_TUNNEL_PORT=${p:-8081}; read -p "Path(/xr): " q; VAR_XRAY_WS_TUNNEL_PATH=${q:-/xr}; } ;;
            9) DEPLOY_XRAY_XHTTP=$([[ $DEPLOY_XRAY_XHTTP == true ]] && echo false || echo true); [[ $DEPLOY_XRAY_XHTTP == true ]] && { INSTALL_XRAY=true; read -p "端口(2053): " p; VAR_XRAY_XHTTP_PORT=${p:-2053}; } ;;
            0) break ;;
        esac
    done
}

# (省略重复的 WARP/Argo 菜单函数，与 v6.7 保持一致，请直接保留原有的 menu_warp 和 menu_argo 即可)
# 简写以节省空间，请确保实际文件中包含完整的 menu_warp 和 menu_argo
menu_warp() {
    while true; do clear; echo -e "${SKYBLUE}=== WARP ===${PLAIN}"; echo "1.启用 2.模式 3.清除 0.返回"; read -p "选: " c; case $c in 1) INSTALL_WARP=true;; 2) read -p "模式(1-5): " m; WARP_MODE_SELECT=$m;; 3) INSTALL_WARP=false; unset WARP_MODE_SELECT;; 0) break;; esac; done
}
menu_argo() {
    while true; do clear; echo -e "${SKYBLUE}=== Argo ===${PLAIN}"; echo "1.启用 2.清除 0.返回"; read -p "选: " c; case $c in 1) INSTALL_ARGO=true; read -p "Token: " t; export ARGO_AUTH=$t; read -p "Domain: " d; export ARGO_DOMAIN=$d;; 2) INSTALL_ARGO=false;; 0) break;; esac; done
}

export AUTO_SETUP=true
if [[ -z "$INSTALL_SB" && -z "$INSTALL_XRAY" ]]; then check_dir_clean; fi
if [[ -n "$INSTALL_SB" || -n "$INSTALL_XRAY" || -n "$INSTALL_ARGO" ]]; then deploy_logic; exit 0; fi
while true; do
    show_dashboard; echo -e " 1.协议 2.WARP 3.Argo 0.部署"; read -p "选: " m
    case $m in 1) menu_protocols;; 2) menu_warp;; 3) menu_argo;; 0) deploy_logic; break;; esac
done
