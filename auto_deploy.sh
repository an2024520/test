#!/bin/bash
# ============================================================
#  Commander Auto-Deploy (v7.6 Hy2 & XHTTP Final)
#  - 特性: 严格 IP 检测 | 纯净 URL (适配 Worker)
#  - 升级: 修复 Xray XHTTP 协议参数传递 (SNI/Path/Port)
#  - 修正: 统一 XHTTP 默认 SNI 为 www.microsoft.com
# ============================================================

# --- 基础定义 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
RED='\033[0;31m'
PLAIN='\033[0m'
GRAY='\033[0;37m'

# ============================================================
#  GitHub Proxy Injector (Interactive Mode)
# ============================================================

# 1. 询问用户
echo -e "${YELLOW}======================================================${PLAIN}"
echo -e "${YELLOW} 是否使用 Cloudflare Worker 代理加速 GitHub 请求?${PLAIN}"
echo -e "${GRAY} (示例: https://my-worker.dev/ ) -- 务必以 https 开头${PLAIN}"
read -p "请输入代理链接 (默认为空/不使用，直接回车): " input_proxy

# 2. 判断逻辑
if [[ -n "$input_proxy" ]]; then
    if [[ "$input_proxy" != */ ]]; then
        input_proxy="${input_proxy}/"
    fi
    
    export GH_PROXY_URL="$input_proxy"
    echo -e "${GREEN}>>> 已启用代理模式，目标: ${GH_PROXY_URL}${PLAIN}"

    function curl() {
        local args=()
        for arg in "$@"; do
            if [[ "$arg" =~ ^https?://([a-zA-Z0-9-]+\.)?github(usercontent)?\.com ]]; then
                if [[ "$arg" != *"$GH_PROXY_URL"* ]]; then
                    arg="${GH_PROXY_URL}${arg}"
                fi
            fi
            args+=("$arg")
        done
        command curl "${args[@]}"
    }

    function wget() {
        local args=()
        for arg in "$@"; do
            if [[ "$arg" =~ ^https?://([a-zA-Z0-9-]+\.)?github(usercontent)?\.com ]]; then
                if [[ "$arg" != *"$GH_PROXY_URL"* ]]; then
                    arg="${GH_PROXY_URL}${arg}"
                fi
            fi
            args+=("$arg")
        done
        command wget "${args[@]}"
    }

    export -f curl
    export -f wget
else
    echo -e "${GRAY}>>> 未输入代理，将使用直连模式 (Direct Mode)。${PLAIN}"
fi
echo -e "${YELLOW}======================================================${PLAIN}"
echo ""

URL_LIST="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/sh_url.txt"
LOCAL_LIST="/tmp/sh_url.txt"

# ============================================================
#  0. 环境预处理
# ============================================================

check_ipv6_environment() {
    echo -e "${YELLOW}>>> [环境自检] 检测网络连通性 (Strict Mode)...${PLAIN}"
    local ipv4_check=$(curl -4 -s -m 5 http://ip.sb 2>/dev/null)
    if [[ "$ipv4_check" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return
    fi

    echo -e "${YELLOW}>>> 检测到纯 IPv6 环境 (无法获取 IPv4)，正在优化 DNS...${PLAIN}"
    if [[ ! -f /etc/resolv.conf.bak ]]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak
    fi
    chattr -i /etc/resolv.conf >/dev/null 2>&1
    cat > /etc/resolv.conf << EOF
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8844
nameserver 2606:4700:4700::1001
EOF
    chattr +i /etc/resolv.conf >/dev/null 2>&1
    echo -e "${GREEN}>>> DNS 优化完成。${PLAIN}"
}

check_dir_clean() {
    local current_script=$(basename "$0")
    local count=$(ls -1 | grep -v "^$current_script$" | wc -l)
    if [[ "$count" -gt 0 ]]; then
        clear
        echo -e "${YELLOW}======================================================${PLAIN}"
        echo -e "${YELLOW} 检测到目录下存在 $count 个旧文件/脚本。${PLAIN}"
        echo -e "${GRAY} 为了确保安装环境纯净，建议执行清理。${PLAIN}"
        echo -e "${YELLOW}======================================================${PLAIN}"
        echo -e ""
        read -p "是否清空目录并强制更新? (y/n, 默认 y): " clean_opt
        clean_opt=${clean_opt:-y}

        if [[ "$clean_opt" == "y" ]]; then
            echo -e "${YELLOW}正在清理旧文件...${PLAIN}"
            ls | grep -v "^$current_script$" | xargs rm -rf
            echo -e "${GREEN}清理完成。${PLAIN}"; sleep 1
        fi
    fi
}

# ============================================================
#  1. 执行引擎
# ============================================================

init_urls() {
    check_ipv6_environment
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

# ============================================================
#  [核心逻辑] 部署与 Tag 累加
# ============================================================
deploy_logic() {
    clear
    echo -e "${GREEN}>>> 正在处理您的订单 (开始部署)...${PLAIN}"
    init_urls
    
    local SB_TAGS_ACC=""
    local XRAY_TAGS_ACC=""

    # === 1. Sing-box 体系 ===
    if [[ "$INSTALL_SB" == "true" ]]; then
        echo -e "${GREEN}>>> [Sing-box] 部署核心...${PLAIN}"
        run "sb_install_core.sh"
        
        # A. Vision Reality
        if [[ "$DEPLOY_SB_VISION" == "true" ]]; then
            echo -e "${GREEN}>>> [SB] Vision 节点 (: ${VAR_SB_VISION_PORT})...${PLAIN}"
            PORT=$VAR_SB_VISION_PORT run "sb_vless_vision_reality.sh"
            SB_TAGS_ACC+="Vision-${VAR_SB_VISION_PORT},"
        fi
        
        # B. WS TLS (CDN)
        if [[ "$DEPLOY_SB_WS" == "true" ]]; then
             echo -e "${GREEN}>>> [SB] WS+TLS (CDN) 节点 (: ${VAR_SB_WS_PORT})...${PLAIN}"
             export SB_WS_TLS_PORT="$VAR_SB_WS_PORT"
             export SB_WS_TLS_DOMAIN="$VAR_SB_WS_DOMAIN"
             export SB_WS_TLS_PATH="$VAR_SB_WS_PATH"
             run "sb_vless_ws_tls.sh"
             unset SB_WS_TLS_PORT SB_WS_TLS_DOMAIN SB_WS_TLS_PATH
             SB_TAGS_ACC+="WS-TLS-${VAR_SB_WS_PORT},"
        fi

        # C. WS Tunnel
        if [[ "$DEPLOY_SB_WS_TUNNEL" == "true" ]]; then
             echo -e "${GREEN}>>> [SB] WS Tunnel 节点 (: ${VAR_SB_WS_TUNNEL_PORT})...${PLAIN}"
             export SB_WS_PORT="$VAR_SB_WS_TUNNEL_PORT"
             export SB_WS_PATH="$VAR_SB_WS_TUNNEL_PATH"
             run "sb_vless_ws_tunnel.sh"
             unset SB_WS_PORT SB_WS_PATH
             SB_TAGS_ACC+="Tunnel-${VAR_SB_WS_TUNNEL_PORT},"
        fi

        # D. AnyTLS Reality
        if [[ "$DEPLOY_SB_ANYTLS" == "true" ]]; then
             echo -e "${GREEN}>>> [SB] AnyTLS 节点 (: ${VAR_SB_ANYTLS_PORT})...${PLAIN}"
             PORT=$VAR_SB_ANYTLS_PORT run "sb_anytls_reality.sh"
             SB_TAGS_ACC+="AnyTLS-${VAR_SB_ANYTLS_PORT},"
        fi

        # E. Hysteria 2 (智能部署)
        if [[ "$DEPLOY_SB_HY2" == "true" ]]; then
             echo -e "${GREEN}>>> [SB] Hysteria 2 节点 (Smart Mode)...${PLAIN}"
             export PORT="$VAR_SB_HY2_PORT"
             export DOMAIN_INPUT="$VAR_SB_HY2_DOMAIN"
             export AUTO_SETUP=true
             run "sb_hy2_deploy.sh"
             if [[ -n "$VAR_SB_HY2_DOMAIN" ]]; then
                 SB_TAGS_ACC+="Hy2-${VAR_SB_HY2_DOMAIN},"
             else
                 SB_TAGS_ACC+="Hy2-${VAR_SB_HY2_PORT},"
             fi
             unset PORT DOMAIN_INPUT AUTO_SETUP
        fi
    fi

    # === 2. Xray 体系 ===
    if [[ "$INSTALL_XRAY" == "true" ]]; then
        echo -e "${GREEN}>>> [Xray] 部署核心...${PLAIN}"
        run "xray_core.sh"
        
        # A. Vision Reality
        if [[ "$DEPLOY_XRAY_VISION" == "true" ]]; then
            echo -e "${GREEN}>>> [Xray] Vision 节点 (: ${VAR_XRAY_VISION_PORT})...${PLAIN}"
            export PORT="$VAR_XRAY_VISION_PORT"
            run "xray_vless_vision_reality.sh"
            unset PORT
            XRAY_TAGS_ACC+="vless-vision-${VAR_XRAY_VISION_PORT},"
        fi

        # B. WS TLS (CDN)
        if [[ "$DEPLOY_XRAY_WS" == "true" ]]; then
            echo -e "${GREEN}>>> [Xray] WS+TLS (CDN) 节点 (: ${VAR_XRAY_WS_PORT})...${PLAIN}"
            export XRAY_WS_TLS_PORT="$VAR_XRAY_WS_PORT"
            export XRAY_WS_TLS_DOMAIN="$VAR_XRAY_WS_DOMAIN"
            export XRAY_WS_TLS_PATH="$VAR_XRAY_WS_PATH"
            run "xray_vless_ws_tls.sh"
            unset XRAY_WS_TLS_PORT XRAY_WS_TLS_DOMAIN XRAY_WS_TLS_PATH
            XRAY_TAGS_ACC+="Xray-WS-TLS-${VAR_XRAY_WS_PORT},"
        fi

        # C. WS Tunnel
        if [[ "$DEPLOY_XRAY_WS_TUNNEL" == "true" ]]; then
            echo -e "${GREEN}>>> [Xray] WS Tunnel 节点 (: ${VAR_XRAY_WS_TUNNEL_PORT})...${PLAIN}"
            export XRAY_WS_PORT="$VAR_XRAY_WS_TUNNEL_PORT"
            export XRAY_WS_PATH="$VAR_XRAY_WS_TUNNEL_PATH"
            run "xray_vless_ws_tunnel.sh"
            unset XRAY_WS_PORT XRAY_WS_PATH
            XRAY_TAGS_ACC+="vless-ws-tunnel-${VAR_XRAY_WS_TUNNEL_PORT},"
        fi

        # D. XHTTP Reality
        if [[ "$DEPLOY_XRAY_XHTTP" == "true" ]]; then
            echo -e "${GREEN}>>> [Xray] XHTTP Reality 节点 (: ${VAR_XRAY_XHTTP_PORT})...${PLAIN}"
            export PORT="$VAR_XRAY_XHTTP_PORT"
            export XRAY_XHTTP_SNI="$VAR_XRAY_XHTTP_SNI"
            export XRAY_XHTTP_PATH="$VAR_XRAY_XHTTP_PATH"
            
            run "xray_vless_xhttp_reality.sh"
            
            unset PORT XRAY_XHTTP_SNI XRAY_XHTTP_PATH
            XRAY_TAGS_ACC+="Xray-XHTTP-${VAR_XRAY_XHTTP_PORT},"
        fi

        # E. ML-KEM ENC
        if [[ "$DEPLOY_XRAY_MLKEM" == "true" ]]; then
            echo -e "${GREEN}>>> [Xray] ML-KEM-768 节点 (: ${VAR_XRAY_MLKEM_PORT})...${PLAIN}"
            export PORT="$VAR_XRAY_MLKEM_PORT"
            run "xray_vless_xhttp_reality_mlkem.sh"
            unset PORT
            XRAY_TAGS_ACC+="Xray-MLKEM-${VAR_XRAY_MLKEM_PORT},"
        fi
    fi

    # === 3. WARP 模块 ===
    if [[ "$INSTALL_WARP" == "true" ]]; then
        echo -e "${GREEN}>>> [WARP] 配置路由出口...${PLAIN}"
        if [[ "$INSTALL_SB" == "true" ]]; then
            export WARP_INBOUND_TAGS="${SB_TAGS_ACC%,}"
            run "sb_module_warp_native_route.sh"
        fi
        if [[ "$INSTALL_XRAY" == "true" ]]; then
            export WARP_INBOUND_TAGS="${XRAY_TAGS_ACC%,}"
            run "xray_module_warp_native_route.sh"
        fi
    fi

    # === 4. Argo 模块 ===
    if [[ "$INSTALL_ARGO" == "true" ]]; then
        if systemctl is-active --quiet cloudflared; then
            echo -e "${SKYBLUE}>>> [检测] Cloudflare Tunnel 服务已在运行，跳过安装程序。${PLAIN}"
        else
            echo -e "${GREEN}>>> [Argo] 环境未就绪，开始配置 Tunnel...${PLAIN}"
            run "install_cf_tunnel_debian.sh"
        fi
    fi

    echo -e "${GREEN}>>> 所有任务执行完毕。${PLAIN}"
    exit 0
}

# ============================================================
#  2. 交互界面 (Frontend UI)
# ============================================================

get_status() {
    if [[ "$1" == "true" ]]; then echo -e "${GREEN}√${PLAIN}"; else echo -e "${PLAIN} ${PLAIN}"; fi
}

show_dashboard() {
    clear
    echo -e "${SKYBLUE}==============================================${PLAIN}"
    echo -e "${SKYBLUE}       Commander 选购清单 (Auto Mode)      ${PLAIN}"
    echo -e "${SKYBLUE}==============================================${PLAIN}"
    local has_item=false

    if [[ "$INSTALL_SB" == "true" ]]; then
        echo -e "${YELLOW}● Sing-box Core${PLAIN}"
        [[ "$DEPLOY_SB_VISION" == "true" ]]     && echo -e "  ├─ Vision Reality  [Port: ${GREEN}$VAR_SB_VISION_PORT${PLAIN}]"
        [[ "$DEPLOY_SB_WS" == "true" ]]         && echo -e "  ├─ WS+TLS (CDN)    [Port: ${GREEN}$VAR_SB_WS_PORT${PLAIN}]"
        [[ "$DEPLOY_SB_WS_TUNNEL" == "true" ]]  && echo -e "  ├─ WS Tunnel       [Port: ${GREEN}$VAR_SB_WS_TUNNEL_PORT${PLAIN}]"
        [[ "$DEPLOY_SB_ANYTLS" == "true" ]]     && echo -e "  ├─ AnyTLS Reality  [Port: ${GREEN}$VAR_SB_ANYTLS_PORT${PLAIN}]"
        if [[ "$DEPLOY_SB_HY2" == "true" ]]; then
            if [[ -n "$VAR_SB_HY2_DOMAIN" ]]; then
                echo -e "  └─ Hysteria 2      [ACME: ${GREEN}${VAR_SB_HY2_DOMAIN}${PLAIN}]"
            else
                echo -e "  └─ Hysteria 2      [Self: ${GREEN}${VAR_SB_HY2_PORT}${PLAIN}]"
            fi
        fi
        has_item=true
    fi
    
    if [[ "$INSTALL_XRAY" == "true" ]]; then
        echo -e "${YELLOW}● Xray Core${PLAIN}"
        [[ "$DEPLOY_XRAY_VISION" == "true" ]]    && echo -e "  ├─ Vision Reality  [Port: ${GREEN}$VAR_XRAY_VISION_PORT${PLAIN}]"
        [[ "$DEPLOY_XRAY_WS" == "true" ]]        && echo -e "  ├─ WS+TLS (CDN)    [Port: ${GREEN}$VAR_XRAY_WS_PORT${PLAIN}]"
        [[ "$DEPLOY_XRAY_WS_TUNNEL" == "true" ]] && echo -e "  ├─ WS Tunnel       [Port: ${GREEN}$VAR_XRAY_WS_TUNNEL_PORT${PLAIN}]"
        [[ "$DEPLOY_XRAY_XHTTP" == "true" ]]     && echo -e "  ├─ XHTTP Reality   [Port: ${GREEN}$VAR_XRAY_XHTTP_PORT${PLAIN}]"
        [[ "$DEPLOY_XRAY_MLKEM" == "true" ]]     && echo -e "  └─ ML-KEM (ENC)    [Port: ${GREEN}$VAR_XRAY_MLKEM_PORT${PLAIN}]"
        has_item=true
    fi

    if [[ "$INSTALL_WARP" == "true" ]]; then
        local mode_str="流媒体分流"
        case "$WARP_MODE_SELECT" in
            1) mode_str="IPv4 优先" ;;
            2) mode_str="IPv6 优先" ;;
            3) mode_str="指定节点接管" ;;
            4) mode_str="双栈全局接管" ;;
            5) mode_str="仅流媒体分流" ;;
        esac
        echo -e "${YELLOW}● WARP 路由优化${PLAIN}"
        echo -e "  └─ 模式: ${SKYBLUE}${mode_str}${PLAIN}"
        has_item=true
    fi

    if [[ "$INSTALL_ARGO" == "true" ]]; then
        echo -e "${YELLOW}● Argo Tunnel${PLAIN}"
        echo -e "  └─ 域名: ${GREEN}${ARGO_DOMAIN}${PLAIN}"
        has_item=true
    fi

    if [[ "$has_item" == "false" ]]; then
        echo -e "${GRAY}  (购物车是空的, 请选择商品...)${PLAIN}"
    fi
    echo -e "=============================================="
}

menu_protocols() {
    while true; do
        clear; echo -e "${SKYBLUE}=== 协议选择 ===${PLAIN}"
        echo -e "${YELLOW}--- Sing-box 体系 ---${PLAIN}"
        echo -e " 1. [$(get_status $DEPLOY_SB_VISION)] Vless_Vision_Reality"
        echo -e " 2. [$(get_status $DEPLOY_SB_WS)] Vless_WS_TLS (CDN_回源)"
        echo -e " 3. [$(get_status $DEPLOY_SB_WS_TUNNEL)] Vless_WS_Tunnel"
        echo -e " 4. [$(get_status $DEPLOY_SB_ANYTLS)] AnyTLS_Reality"
        echo -e " 5. [$(get_status $DEPLOY_SB_HY2)] Hysteria_2 (智能部署)"
        echo -e "${YELLOW}--- Xray 体系 ---${PLAIN}"
        echo -e " 6. [$(get_status $DEPLOY_XRAY_VISION)] Vless_Vision_Reality"
        echo -e " 7. [$(get_status $DEPLOY_XRAY_WS)] Vless_WS_TLS (CDN_回源)"
        echo -e " 8. [$(get_status $DEPLOY_XRAY_WS_TUNNEL)] Vless_WS_Tunnel"
        echo -e " 9. [$(get_status $DEPLOY_XRAY_XHTTP)] Vless_XHTTP_Reality"
        echo -e "10. [$(get_status $DEPLOY_XRAY_MLKEM)] Vless_ENC_MLKEM (抗量子)"
        echo ""
        echo -e " 0. 返回"
        read -p "选择: " c
        case $c in
            1) if [[ "$DEPLOY_SB_VISION" == "true" ]]; then DEPLOY_SB_VISION=false; else DEPLOY_SB_VISION=true; INSTALL_SB=true; read -p "端口(443): " p; VAR_SB_VISION_PORT=${p:-443}; fi ;;
            2) if [[ "$DEPLOY_SB_WS" == "true" ]]; then DEPLOY_SB_WS=false; else DEPLOY_SB_WS=true; INSTALL_SB=true; read -p "端口(8443): " p; VAR_SB_WS_PORT=${p:-8443}; read -p "域名: " d; VAR_SB_WS_DOMAIN=$d; read -p "Path(/ws): " q; VAR_SB_WS_PATH=${q:-/ws}; fi ;;
            3) if [[ "$DEPLOY_SB_WS_TUNNEL" == "true" ]]; then DEPLOY_SB_WS_TUNNEL=false; else DEPLOY_SB_WS_TUNNEL=true; INSTALL_SB=true; read -p "端口(8080): " p; VAR_SB_WS_TUNNEL_PORT=${p:-8080}; read -p "Path(/ws): " q; VAR_SB_WS_TUNNEL_PATH=${q:-/ws}; if [[ "$INSTALL_ARGO" != "true" ]]; then echo -e "${YELLOW}提示: 建议开启 Argo${PLAIN}"; INSTALL_ARGO=true; read -p "Token: " t; export ARGO_AUTH="$t"; read -p "Domain: " d; export ARGO_DOMAIN="$d"; fi; fi ;;
            4) if [[ "$DEPLOY_SB_ANYTLS" == "true" ]]; then DEPLOY_SB_ANYTLS=false; else DEPLOY_SB_ANYTLS=true; INSTALL_SB=true; read -p "端口(8443): " p; VAR_SB_ANYTLS_PORT=${p:-8443}; fi ;;
            5) if [[ "$DEPLOY_SB_HY2" == "true" ]]; then DEPLOY_SB_HY2=false; unset VAR_SB_HY2_PORT VAR_SB_HY2_DOMAIN; else DEPLOY_SB_HY2=true; INSTALL_SB=true; echo -e "${YELLOW}[Hysteria 2 设置]${PLAIN}"; read -p "  域名 (留空自签): " d; VAR_SB_HY2_DOMAIN=$d; if [[ -n "$VAR_SB_HY2_DOMAIN" ]]; then read -p "  端口 (443): " p; VAR_SB_HY2_PORT=${p:-443}; else read -p "  UDP端口 (10086): " p; VAR_SB_HY2_PORT=${p:-10086}; fi; fi ;;
            6) if [[ "$DEPLOY_XRAY_VISION" == "true" ]]; then DEPLOY_XRAY_VISION=false; else DEPLOY_XRAY_VISION=true; INSTALL_XRAY=true; read -p "端口(1443): " p; VAR_XRAY_VISION_PORT=${p:-1443}; fi ;;
            7) if [[ "$DEPLOY_XRAY_WS" == "true" ]]; then DEPLOY_XRAY_WS=false; else DEPLOY_XRAY_WS=true; INSTALL_XRAY=true; read -p "端口(8443): " p; VAR_XRAY_WS_PORT=${p:-8443}; read -p "域名: " d; VAR_XRAY_WS_DOMAIN=$d; read -p "Path(/ws): " q; VAR_XRAY_WS_PATH=${q:-/ws}; fi ;;
            8) if [[ "$DEPLOY_XRAY_WS_TUNNEL" == "true" ]]; then DEPLOY_XRAY_WS_TUNNEL=false; else DEPLOY_XRAY_WS_TUNNEL=true; INSTALL_XRAY=true; read -p "端口(8081): " p; VAR_XRAY_WS_TUNNEL_PORT=${p:-8081}; read -p "Path(/xr): " q; VAR_XRAY_WS_TUNNEL_PATH=${q:-/xr}; if [[ "$INSTALL_ARGO" != "true" ]]; then echo -e "${YELLOW}提示: 建议开启 Argo${PLAIN}"; INSTALL_ARGO=true; read -p "Token: " t; export ARGO_AUTH="$t"; read -p "Domain: " d; export ARGO_DOMAIN="$d"; fi; fi ;;
            # [修改] 增加 SNI 和 Path 录入，统一默认值为 Microsoft
            9) if [[ "$DEPLOY_XRAY_XHTTP" == "true" ]]; then 
                   DEPLOY_XRAY_XHTTP=false; 
               else 
                   DEPLOY_XRAY_XHTTP=true; 
                   INSTALL_XRAY=true; 
                   read -p "端口(2053): " p; VAR_XRAY_XHTTP_PORT=${p:-2053}; 
                   read -p "SNI(www.microsoft.com): " s; VAR_XRAY_XHTTP_SNI=${s:-"www.microsoft.com"}; 
                   read -p "Path(随机): " q; VAR_XRAY_XHTTP_PATH=${q}; 
               fi ;;
            10) if [[ "$DEPLOY_XRAY_MLKEM" == "true" ]]; then DEPLOY_XRAY_MLKEM=false; else DEPLOY_XRAY_MLKEM=true; INSTALL_XRAY=true; read -p "端口(2088): " p; VAR_XRAY_MLKEM_PORT=${p:-2088}; fi ;;
            0) break ;;
        esac
    done
}

menu_warp() {
    while true; do
        clear
        echo -e "${SKYBLUE}=== WARP 路由配置 ===${PLAIN}"
        echo -e "当前状态: [$(get_status $INSTALL_WARP)]"
        echo ""
        echo -e " 1. 启用/配置 WARP 账号"
        echo -e " 2. 选择分流模式"
        echo -e " 3. ${RED}清空 WARP 购物车${PLAIN}"
        echo ""
        echo -e " 0. 返回"
        read -p "选择: " w
        case $w in
            1) INSTALL_WARP=true; [[ -z "$WARP_MODE_SELECT" ]] && WARP_MODE_SELECT=5; echo -e "   1. 自动注册"; echo -e "   2. 手动录入"; read -p "   选择: " acc; if [[ "$acc" == "2" ]]; then read -p "   Private Key: " k; export WARP_PRIV_KEY="$k"; read -p "   IPv6: " i; export WARP_IPV6="$i"; read -p "   Reserved: " r; export WARP_RESERVED="$r"; else unset WARP_PRIV_KEY WARP_IPV6 WARP_RESERVED; fi ;;
            2) INSTALL_WARP=true; echo -e "   1. IPv4 优先"; echo -e "   2. IPv6 优先"; echo -e "   3. 指定节点接管"; echo -e "   4. 双栈全局接管"; echo -e "   5. 仅流媒体分流"; read -p "   选择模式 (1-5): " m; if [[ "$m" =~ ^[1-5]$ ]]; then export WARP_MODE_SELECT="$m"; fi ;;
            3) INSTALL_WARP=false; unset WARP_MODE_SELECT WARP_PRIV_KEY WARP_IPV6 WARP_RESERVED; echo -e "${YELLOW}已移除 WARP。${PLAIN}"; sleep 1 ;;
            0) break ;;
        esac
    done
}

menu_argo() {
    while true; do
        clear; echo -e "${SKYBLUE}=== Argo 配置 ===${PLAIN}"
        echo -e " 1. 启用 Argo"
        echo -e " 2. 清空 Argo"
        echo " 0. 返回"
        read -p "选择: " c
        case $c in
            1) INSTALL_ARGO=true; read -p "Token: " t; export ARGO_AUTH="$t"; read -p "Domain: " d; export ARGO_DOMAIN="$d" ;;
            2) INSTALL_ARGO=false; unset ARGO_AUTH; unset ARGO_DOMAIN ;;
            0) break ;;
        esac
    done
}

export AUTO_SETUP=true
if [[ -z "$INSTALL_SB" ]] && [[ -z "$INSTALL_XRAY" ]]; then check_dir_clean; fi
if [[ -n "$INSTALL_SB" ]] || [[ -n "$INSTALL_XRAY" ]] || [[ -n "$INSTALL_ARGO" ]]; then deploy_logic; exit 0; fi

while true; do
    show_dashboard
    echo -e " ${GREEN}1.${PLAIN} 协议选择"
    echo -e " ${GREEN}2.${PLAIN} WARP 路由"
    echo -e " ${GREEN}3.${PLAIN} Argo 隧道"
    echo -e " -------------------------"
    echo -e " ${GREEN}0. 确认清单并开始部署${PLAIN}"
    echo ""
    read -p "选项: " m
    case $m in
        1) menu_protocols ;;
        2) menu_warp ;;
        3) menu_argo ;;
        0) if [[ "$INSTALL_SB" != "true" ]] && [[ "$INSTALL_XRAY" != "true" ]] && [[ "$INSTALL_ARGO" != "true" ]]; then echo -e "${RED}购物车是空的！${PLAIN}"; sleep 2; else deploy_logic; break; fi ;;
    esac
done