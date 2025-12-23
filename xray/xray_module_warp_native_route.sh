#!/bin/bash

# ============================================================
#  Native WARP 增强模块 (Xray Auto-Enhanced v1.2)
#  - 无需 Wireproxy，由 Xray 内核直接连接 Cloudflare
#  - 自动化: 支持 auto_deploy.sh 的三要素传入与 Tag 分流
#  - 新增: 模式4(双栈) 和 模式5(Stream)
# ============================================================

# --- 1. 全局配置 (与 xray_core.sh 严格配套) ---
XRAY_CONFIG="/usr/local/etc/xray/config.json"
WARP_CONF_FILE="/etc/my_script/warp_native.conf"
mkdir -p "$(dirname "$WARP_CONF_FILE")"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
GRAY='\033[0;37m'

# --- 2. 依赖检查 ---
check_dependencies() {
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${YELLOW}正在安装 jq (JSON处理工具)...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y jq
        elif [ -f /etc/redhat-release ]; then
            yum install -y jq
        fi
    fi
    if ! command -v od >/dev/null 2>&1; then
        echo -e "${GRAY}提示: 系统未安装 od 工具，手动解码可能需要依赖 Python。${PLAIN}"
    fi
}

ensure_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${YELLOW}该功能需要 Python3 支持 (计算/解码 Reserved)，正在安装...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y python3
        elif [ -f /etc/redhat-release ]; then
            yum install -y python3
        fi
        
        if ! command -v python3 >/dev/null 2>&1; then
             echo -e "${RED}Python3 安装失败！${PLAIN}"
             return 1
        fi
    fi
    return 0
}

base64_to_reserved_shell() {
    local input="$1"
    local bytes=$(echo "$input" | base64 -d 2>/dev/null | od -An -t u1 | tr -s ' ' ',')
    bytes=$(echo "$bytes" | sed 's/^,//;s/,$//;s/ //g')
    if [ -n "$bytes" ]; then echo "[$bytes]"; else echo ""; fi
}

# --- 3. 核心功能：获取 WARP 凭证 (交互版) ---
get_warp_credentials() {
    check_dependencies
    clear
    echo -e "${GREEN}================ Native WARP 凭证配置 ================${PLAIN}"
    echo -e "Native 模式需要 WARP 账户的三要素：Private Key, IPv6 Address, Reserved"
    echo -e "----------------------------------------------------"
    echo -e " 1. 自动注册 (推荐: 使用 wgcf 生成独享账号)"
    echo -e " 2. 手动输入 (已有账号，支持 Base64 / 数组格式)"
    echo -e "----------------------------------------------------"
    read -p "请选择: " choice

    local wp_key=""
    local wp_ip=""
    local wp_res=""

    if [ "$choice" == "1" ]; then
        ensure_python || return 1
        echo -e "${YELLOW}正在准备 wgcf 环境...${PLAIN}"
        local arch=$(uname -m)
        local wgcf_arch="amd64"
        case "$arch" in
            aarch64) wgcf_arch="arm64" ;;
            x86_64) wgcf_arch="amd64" ;;
            *) echo "不支持的架构: $arch"; return 1 ;;
        esac

        local tmp_dir=$(mktemp -d)
        pushd "$tmp_dir" >/dev/null || return

        wget -qO wgcf "https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${wgcf_arch}"
        chmod +x wgcf
        
        echo "正在向 Cloudflare 注册新账户..."
        ./wgcf register --accept-tos >/dev/null 2>&1
        ./wgcf generate >/dev/null 2>&1

        if [ ! -f wgcf-profile.conf ]; then
            echo -e "${RED}错误：注册失败。Cloudflare 可能限制了本机 IP 注册。${PLAIN}"
            popd >/dev/null; rm -rf "$tmp_dir"; read -p "按回车退出..."; return 1
        fi

        wp_key=$(grep 'PrivateKey' wgcf-profile.conf | cut -d ' ' -f 3 | tr -d '\n\r ')
        local raw_addr=$(grep 'Address' wgcf-profile.conf | cut -d '=' -f 2 | tr -d ' ')
        if [[ "$raw_addr" == *","* ]]; then
            wp_ip=$(echo "$raw_addr" | awk -F',' '{print $2}' | cut -d'/' -f1 | tr -d '\n\r ')
        else
            wp_ip=$(echo "$raw_addr" | cut -d'/' -f1 | tr -d '\n\r ')
        fi

        local client_id=$(grep "client_id" wgcf-account.toml | cut -d '"' -f 2)
        if [ -n "$client_id" ]; then
            wp_res=$(python3 -c "import base64; d=base64.b64decode('${client_id}'); print(f'[{d[0]}, {d[1]}, {d[2]}]')")
        else
            wp_res="[0, 0, 0]"
        fi

        echo -e "${GREEN}注册成功！已获取独享账号。${PLAIN}"
        echo "Private Key: $wp_key"
        echo "IPv6 Addr:   $wp_ip"
        echo "Reserved:    $wp_res"
        
        popd >/dev/null
        rm -rf "$tmp_dir"

    elif [ "$choice" == "2" ]; then
        echo -e "${YELLOW}请输入 Private Key (私钥):${PLAIN}"
        read -r wp_key
        echo -e "${YELLOW}请输入 WARP IPv6 地址 (不带 /128):${PLAIN}"
        read -r wp_ip
        echo -e "${YELLOW}请输入 Reserved 值:${PLAIN}"
        read -r res_input
        
        if [[ -z "$res_input" ]]; then
            wp_res="[0, 0, 0]"
        elif [[ "$res_input" == *"["* ]]; then
            wp_res="$res_input"
        else
            wp_res=$(base64_to_reserved_shell "$res_input")
            if [[ -z "$wp_res" ]]; then
                echo -e "${YELLOW}Shell 解码失败，尝试使用 Python 解码...${PLAIN}"
                ensure_python
                if command -v python3 >/dev/null 2>&1; then
                    wp_res=$(python3 -c "import base64; d=base64.b64decode('${res_input}'); print(f'[{d[0]}, {d[1]}, {d[2]}]')" 2>/dev/null)
                else
                    wp_res="[0, 0, 0]"
                fi
            fi
        fi
        
        if [ -z "$wp_key" ] || [ -z "$wp_ip" ]; then
            echo -e "${RED}错误：私钥和 IP 不能为空！${PLAIN}"
            return 1
        fi
    else
        return 1
    fi

    cat > "$WARP_CONF_FILE" <<EOF
WP_KEY="$wp_key"
WP_IP="$wp_ip"
WP_RES="$wp_res"
EOF
    echo -e "${GREEN}凭证已保存至 $WARP_CONF_FILE${PLAIN}"
    read -p "按回车键继续..."
}

# --- 3.5 [新增] 无头注册模式 (用于自动化) ---
register_warp_headless() {
    ensure_python || return 1
    echo -e "${YELLOW}[自动模式] 正在准备 wgcf 环境...${PLAIN}"
    
    local arch=$(uname -m)
    local wgcf_arch="amd64"
    case "$arch" in
        aarch64) wgcf_arch="arm64" ;;
        x86_64) wgcf_arch="amd64" ;;
    esac

    local tmp_dir=$(mktemp -d)
    pushd "$tmp_dir" >/dev/null || return

    wget -qO wgcf "https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${wgcf_arch}"
    chmod +x wgcf
    
    echo "正在向 Cloudflare 注册新账户..."
    ./wgcf register --accept-tos >/dev/null 2>&1
    ./wgcf generate >/dev/null 2>&1

    if [ ! -f wgcf-profile.conf ]; then
        echo -e "${RED}错误：自动注册失败 (Cloudflare 限制)。${PLAIN}"
        popd >/dev/null; rm -rf "$tmp_dir"; return 1
    fi

    local wp_key=$(grep 'PrivateKey' wgcf-profile.conf | cut -d ' ' -f 3 | tr -d '\n\r ')
    local raw_addr=$(grep 'Address' wgcf-profile.conf | cut -d '=' -f 2 | tr -d ' ')
    local wp_ip=""
    if [[ "$raw_addr" == *","* ]]; then
        wp_ip=$(echo "$raw_addr" | awk -F',' '{print $2}' | cut -d'/' -f1 | tr -d '\n\r ')
    else
        wp_ip=$(echo "$raw_addr" | cut -d'/' -f1 | tr -d '\n\r ')
    fi

    local client_id=$(grep "client_id" wgcf-account.toml | cut -d '"' -f 2)
    local wp_res=""
    if [ -n "$client_id" ]; then
        wp_res=$(python3 -c "import base64; d=base64.b64decode('${client_id}'); print(f'[{d[0]}, {d[1]}, {d[2]}]')")
    else
        wp_res="[0, 0, 0]"
    fi

    cat > "$WARP_CONF_FILE" <<EOF
WP_KEY="$wp_key"
WP_IP="$wp_ip"
WP_RES="$wp_res"
EOF
    echo -e "${GREEN}[自动模式] 注册成功，凭证已保存。${PLAIN}"
    popd >/dev/null; rm -rf "$tmp_dir"
}

# --- 4. 核心功能：生成 Outbound JSON ---
generate_warp_outbound() {
    if [ ! -f "$WARP_CONF_FILE" ]; then return 1; fi
    source "$WARP_CONF_FILE"
    local addr_json="\"172.16.0.2/32\", \"${WP_IP}/128\""
    cat <<EOF
{
  "tag": "warp-out",
  "protocol": "wireguard",
  "settings": {
    "secretKey": "${WP_KEY}",
    "address": [ ${addr_json} ],
    "peers": [
      {
        "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
        "endpoint": "engage.cloudflareclient.com:2408",
        "reserved": ${WP_RES},
        "keepAlive": 30
      }
    ]
  }
}
EOF
}

# --- 5. 核心功能：应用配置到 Xray ---
apply_warp_config() {
    local mode="$1"
    local extra_arg="$2"

    if [ ! -f "$XRAY_CONFIG" ]; then echo -e "${RED}未找到 Xray 配置文件！${PLAIN}"; return; fi
    if [ ! -f "$WARP_CONF_FILE" ]; then echo -e "${RED}请先配置 WARP 账号！${PLAIN}"; return; fi

    echo -e "${YELLOW}正在修改 Xray 配置...${PLAIN}"

    # 1. 清理旧配置
    jq 'del(.outbounds[] | select(.tag=="warp-out"))' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    jq 'del(.routing.rules[] | select(.outboundTag=="warp-out"))' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"

    # 2. 注入 Outbound
    local outbound_json=$(generate_warp_outbound)
    jq --argjson new_out "$outbound_json" '.outbounds += [$new_out]' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"

    # 3. 生成路由规则
    local rule_json=""
    case "$mode" in
        "stream")
            rule_json='{ "type": "field", "outboundTag": "warp-out", "domain": ["geosite:netflix", "geosite:openai", "geosite:disney", "geosite:google", "geosite:youtube"] }' ;;
        "ipv4")
            rule_json='{ "type": "field", "outboundTag": "warp-out", "network": "tcp,udp", "ip": ["0.0.0.0/0"] }' ;;
        "ipv6")
            rule_json='{ "type": "field", "outboundTag": "warp-out", "network": "tcp,udp", "ip": ["::/0"] }' ;;
        "dual")
            rule_json='{ "type": "field", "outboundTag": "warp-out", "network": "tcp,udp" }' ;;
        "manual_node")
            rule_json="{ \"type\": \"field\", \"outboundTag\": \"warp-out\", \"inboundTag\": $extra_arg }" ;;
    esac

    # 4. 注入路由规则
    if [ -n "$rule_json" ]; then
        jq --argjson new_rule "$rule_json" '.routing.rules = [$new_rule] + .routing.rules' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    fi

    # 5. 重启
    echo -e "${GREEN}配置注入完成，正在重启 Xray...${PLAIN}"
    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}Native WARP 模式已生效！${PLAIN}"
    else
        echo -e "${RED}Xray 重启失败。${PLAIN}"
    fi
}

# --- 6. 辅助功能：卸载 WARP 配置 ---
disable_warp() {
    if [ ! -f "$XRAY_CONFIG" ]; then return; fi
    echo -e "${YELLOW}正在移除 Native WARP 配置...${PLAIN}"
    jq 'del(.outbounds[] | select(.tag=="warp-out"))' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    jq 'del(.routing.rules[] | select(.outboundTag=="warp-out"))' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    systemctl restart xray
    echo -e "${GREEN}已恢复直连模式。${PLAIN}"
}

# --- 7. 交互逻辑：模式三节点选择器 ---
select_nodes_interactive() {
    if [ ! -f "$XRAY_CONFIG" ]; then echo "无配置文件"; return; fi
    echo -e "${SKYBLUE}正在读取当前节点列表...${PLAIN}"
    local node_list=$(jq -r '.inbounds[] | "\(.tag)|\(.port)|\(.protocol)"' "$XRAY_CONFIG" | nl -w 2 -s " ")
    
    if [ -z "$node_list" ]; then echo -e "${RED}未找到任何入站节点。${PLAIN}"; return; fi
    echo "$node_list" | awk -F'|' '{printf "%s | %-12s | %-5s | %s\n", $1, $2, $3, $4}'
    read -p "选择序号 (空格分隔): " selection

    local selected_tags_json="["
    local first=true
    for num in $selection; do
        local raw_line=$(echo "$node_list" | sed -n "${num}p")
        local tag=$(echo "$raw_line" | awk -F'|' '{print $1}' | awk '{print $2}')
        if [ -n "$tag" ] && [ "$tag" != "null" ]; then
            if [ "$first" = true ]; then first=false; else selected_tags_json+=","; fi
            selected_tags_json+="\"$tag\""
        fi
    done
    selected_tags_json+="]"

    if [ "$selected_tags_json" == "[]" ]; then echo -e "${RED}无效选择。${PLAIN}"; else apply_warp_config "manual_node" "$selected_tags_json"; fi
}

# --- 8. 主菜单入口 ---
show_warp_menu() {
    check_dependencies
    while true; do
        clear
        local status_text="${RED}未配置${PLAIN}"
        if [ -f "$WARP_CONF_FILE" ]; then status_text="${GREEN}已获取凭证${PLAIN}"; fi
        
        echo -e "${GREEN}================ Native WARP 配置向导 ================${PLAIN}"
        echo -e " 凭证状态: [$status_text]"
        echo -e "----------------------------------------------------"
        echo -e " 1. 注册/配置 WARP 凭证 (自动获取 或 手动输入)" 
        echo -e " 2. 查看当前凭证信息"
        echo -e "----------------------------------------------------"
        echo -e " 3. ${SKYBLUE}模式一：智能流媒体分流 (推荐)${PLAIN}"
        echo -e " 4. ${SKYBLUE}模式二：全局接管 (IPv4/IPv6/双栈)${PLAIN}"
        echo -e " 5. ${SKYBLUE}模式三：指定节点接管 (多节点共存)${PLAIN}"
        echo -e "----------------------------------------------------"
        echo -e " 7. ${RED}禁用/卸载 Native WARP (恢复直连)${PLAIN}"
        echo -e " 0. 返回上级菜单"
        echo -e "===================================================="
        read -p "请输入选项: " choice

        case "$choice" in
            1) get_warp_credentials ;; 
            2) cat "$WARP_CONF_FILE" 2>/dev/null; read -p "按回车继续..." ;;
            3) apply_warp_config "stream" ;;
            4) 
                echo -e " a. 仅接管 IPv4  b. 仅接管 IPv6  c. 双栈全接管"
                read -p "选择: " sub
                case "$sub" in
                    a) apply_warp_config "ipv4" ;;
                    b) apply_warp_config "ipv6" ;;
                    c) apply_warp_config "dual" ;;
                esac
                read -p "按回车继续..." ;;
            5) select_nodes_interactive; read -p "按回车继续..." ;;
            7) disable_warp; read -p "按回车继续..." ;;
            0) break ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 9. 自动化入口 (Auto Main)
# ==========================================

auto_main() {
    echo -e "${GREEN}>>> [WARP-Xray] 启动自动化部署流程...${PLAIN}"
    check_dependencies
    
    # 1. 凭证处理
    if [[ -n "$WARP_PRIV_KEY" ]] && [[ -n "$WARP_IPV6" ]]; then
        echo -e "${YELLOW}[自动模式] 应用三要素凭证...${PLAIN}"
        cat > "$WARP_CONF_FILE" <<EOF
WP_KEY="$WARP_PRIV_KEY"
WP_IP="$WARP_IPV6"
WP_RES="${WARP_RESERVED:-[0,0,0]}"
EOF
    else
        echo -e "${YELLOW}[自动模式] 执行无头自动注册...${PLAIN}"
        register_warp_headless
        if [ ! -f "$WARP_CONF_FILE" ]; then
            echo -e "${RED}[错误] 自动注册失败，跳过 WARP 配置。${PLAIN}"
            return
        fi
    fi
    
    # 2. 路由模式应用 (新增 4 和 5)
    case "$WARP_MODE_SELECT" in
        1) apply_warp_config "ipv4" ;;
        2) apply_warp_config "ipv6" ;;
        3) 
            # 解析逗号分隔字符串为 JSON 数组: "tag1,tag2" -> ["tag1","tag2"]
            if [[ -n "$WARP_INBOUND_TAGS" ]]; then
                local tags_json=$(echo "$WARP_INBOUND_TAGS" | jq -R 'split(",")')
                echo -e "   > 目标节点: $WARP_INBOUND_TAGS"
                apply_warp_config "manual_node" "$tags_json"
            fi
            ;;
        4) 
            echo -e "${SKYBLUE}[自动模式] 策略: 双栈全局接管${PLAIN}"
            apply_warp_config "dual" 
            ;;
        5) 
            echo -e "${SKYBLUE}[自动模式] 策略: 仅流媒体分流${PLAIN}"
            apply_warp_config "stream" 
            ;;
        *) 
            # 默认：流媒体
            apply_warp_config "stream" 
            ;;
    esac
    
    echo -e "${GREEN}>>> [WARP-Xray] 自动化配置完成。${PLAIN}"
}

# 自动/手动 分流入口
if [[ "$AUTO_SETUP" == "true" ]]; then
    auto_main
else
    show_warp_menu
fi
