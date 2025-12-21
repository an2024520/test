#!/bin/bash

# ============================================================
#  Sing-box Native WARP 管理模块 (SB-Commander v6.2 LogicFix)
#  - 逻辑修复: 杜绝“有规则无节点”的断链问题
#  - 新增特性: 凭证持久化保存 (warp_credentials.conf)
#  - 智能拦截: 未配置节点时禁止添加路由规则
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# ==========================================
# 1. 环境初始化
# ==========================================

CONFIG_FILE=""
CRED_FILE="/etc/sing-box/warp_credentials.conf"
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 未检测到 config.json 配置文件！${PLAIN}"
    exit 1
fi

# 确保配置目录存在以便保存凭证
mkdir -p "$(dirname "$CRED_FILE")"

check_dependencies() {
    if ! command -v jq &> /dev/null; then apt-get install -y jq || yum install -y jq; fi
    if ! command -v curl &> /dev/null; then apt-get install -y curl || yum install -y curl; fi
}

ensure_python() {
    if ! command -v python3 &> /dev/null; then
        echo -e "${YELLOW}安装 Python3 支持...${PLAIN}"
        apt-get install -y python3 || yum install -y python3
    fi
}

restart_sb() {
    echo -e "${YELLOW}重启 Sing-box 服务...${PLAIN}"
    if command -v sing-box &> /dev/null; then
        if ! sing-box check -c "$CONFIG_FILE" > /dev/null 2>&1; then
             echo -e "${RED}配置语法校验失败！请检查以下错误：${PLAIN}"
             sing-box check -c "$CONFIG_FILE"
             if [[ -f "${CONFIG_FILE}.bak" ]]; then
                 echo -e "${YELLOW}正在尝试回滚到备份配置...${PLAIN}"
                 cp "${CONFIG_FILE}.bak" "$CONFIG_FILE"
                 restart_sb
             fi
             return
        fi
    fi

    if systemctl list-unit-files | grep -q sing-box; then
        systemctl restart sing-box
    else
        pkill -xf "sing-box run -c $CONFIG_FILE"
        nohup sing-box run -c "$CONFIG_FILE" > /dev/null 2>&1 &
    fi
    sleep 2
    if systemctl is-active --quiet sing-box || pgrep -x "sing-box" >/dev/null; then
        echo -e "${GREEN}服务重启成功。${PLAIN}"
    else
        echo -e "${RED}服务重启失败！${PLAIN}"
    fi
}

# ==========================================
# 2. 核心：账号与配置
# ==========================================

clean_reserved() {
    local input="$1"
    local nums=$(echo "$input" | grep -oE '[0-9]+' | tr '\n' ',' | sed 's/,$//')
    [[ -n "$nums" ]] && echo "[$nums]" || echo ""
}

base64_to_reserved_shell() {
    local input="$1"
    local bytes=$(echo "$input" | base64 -d 2>/dev/null | od -An -t u1 | tr -s ' ' ',')
    bytes=$(echo "$bytes" | sed 's/^,//;s/,$//;s/ //g')
    [[ -n "$bytes" ]] && echo "[$bytes]" || echo ""
}

# 保存凭证到本地
save_credentials() {
    cat > "$CRED_FILE" <<EOF
PRIV_KEY="$1"
PUB_KEY="$2"
V4_ADDR="$3"
V6_ADDR="$4"
RESERVED="$5"
EOF
    echo -e "${GREEN}凭证已备份至: $CRED_FILE${PLAIN}"
}

register_warp() {
    ensure_python || return 1
    echo -e "${YELLOW}正在注册免费账号...${PLAIN}"
    if ! command -v wg &> /dev/null; then apt install -y wireguard-tools || yum install -y wireguard-tools; fi
    
    local priv_key=$(wg genkey)
    local pub_key=$(echo "$priv_key" | wg pubkey)
    local install_id=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 22)
    local result=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "User-Agent: okhttp/3.12.1" -H "Content-Type: application/json; charset=UTF-8" \
        -d "{\"key\":\"${pub_key}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${install_id}:APA91bHuwEuLNj_${install_id}\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Android\",\"serial_number\":\"${install_id}\",\"locale\":\"zh_CN\"}")
    
    local v4=$(echo "$result" | jq -r '.config.interface.addresses.v4')
    local v6=$(echo "$result" | jq -r '.config.interface.addresses.v6')
    local peer_pub=$(echo "$result" | jq -r '.config.peers[0].public_key')
    local client_id=$(echo "$result" | jq -r '.config.client_id')
    
    if [[ "$v4" == "null" || -z "$v4" ]]; then echo -e "${RED}注册失败。${PLAIN}"; return 1; fi
    local reserved_json=$(python3 -c "import base64, json; decoded = base64.b64decode('$client_id'); print(json.dumps([x for x in decoded[0:3]]))" 2>/dev/null)
    
    save_credentials "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
    write_warp_config "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
}

manual_warp() {
    # 尝试读取上次保存的凭证
    local def_priv=""
    local def_pub=""
    local def_v4=""
    local def_v6=""
    local def_res=""
    
    if [[ -f "$CRED_FILE" ]]; then
        source "$CRED_FILE"
        def_priv="$PRIV_KEY"
        def_pub="$PUB_KEY"
        def_v4="$V4_ADDR"
        def_v6="$V6_ADDR"
        def_res="$RESERVED"
        echo -e "${SKYBLUE}检测到历史凭证，回车可直接使用默认值。${PLAIN}"
    fi

    echo -e "${GREEN}手动录入 WARP 信息${PLAIN}"
    
    read -p "私钥 (Private Key) [默认: ${def_priv:0:10}...]: " priv_key
    [[ -z "$priv_key" ]] && priv_key="$def_priv"
    if [[ -z "$priv_key" ]]; then echo -e "${RED}私钥不能为空${PLAIN}"; return; fi
    
    read -p "公钥 (Peer Public Key) [默认: 官方Key]: " peer_pub
    [[ -z "$peer_pub" ]] && peer_pub="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    
    read -p "本机 IPv4 [默认: 172.16.0.2/32]: " v4
    [[ -z "$v4" ]] && v4="172.16.0.2/32"
    
    echo -e "${YELLOW}提示: IPv6 地址必须以 /128 结尾${PLAIN}"
    local show_v6=""
    [[ -n "$def_v6" ]] && show_v6=" [默认: ${def_v6}]"
    read -p "本机 IPv6${show_v6}: " v6
    [[ -z "$v6" ]] && v6="$def_v6"
    
    local show_res=""
    [[ -n "$def_res" ]] && show_res=" [默认: ${def_res}]"
    echo -e "Reserved (示例: [0, 0, 0] 或 c+kIBA==)${show_res}"
    read -p "请输入: " res_input
    
    local reserved_json=""
    if [[ -z "$res_input" && -n "$def_res" ]]; then
        reserved_json="$def_res"
    else
        if [[ "$res_input" =~ [0-9] ]]; then
            local clean_res=$(clean_reserved "$res_input")
            [[ -n "$clean_res" ]] && reserved_json="$clean_res"
        fi
        if [[ -z "$reserved_json" ]]; then
            reserved_json=$(base64_to_reserved_shell "$res_input")
            if [[ -z "$reserved_json" ]]; then
                 ensure_python
                 reserved_json=$(python3 -c "import base64, json; decoded = base64.b64decode('$res_input'); print(json.dumps([x for x in decoded]))" 2>/dev/null)
            fi
        fi
        [[ -z "$reserved_json" || "$reserved_json" == "[]" ]] && reserved_json="[0,0,0]"
    fi
    
    save_credentials "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
    write_warp_config "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
}

write_warp_config() {
    local priv="$1"
    local pub="$2"
    local v4="$3"
    local v6="$4"
    local res="$5"
    
    local addr_json="[]"
    if [[ -n "$v4" && "$v4" != "null" ]]; then addr_json=$(echo "$addr_json" | jq --arg ip "$v4" '. + [$ip]'); fi
    if [[ -n "$v6" && "$v6" != "null" ]]; then addr_json=$(echo "$addr_json" | jq --arg ip "$v6" '. + [$ip]'); fi
    
    # Endpoints 结构 (v6.1+)
    local warp_json=$(jq -n \
        --arg priv "$priv" \
        --arg pub "$pub" \
        --argjson addr "$addr_json" \
        --argjson res "$res" \
        '{ 
            "type": "wireguard", 
            "tag": "WARP", 
            "address": $addr, 
            "private_key": $priv,
            "system": false,
            "peers": [
                { 
                    "address": "engage.cloudflareclient.com", 
                    "port": 2408, 
                    "public_key": $pub, 
                    "reserved": $res,
                    "allowed_ips": ["0.0.0.0/0", "::/0"]
                }
            ] 
        }')

    if [[ $? -ne 0 || -z "$warp_json" ]]; then echo -e "${RED}JSON 生成失败。${PLAIN}"; return; fi

    echo -e "${YELLOW}正在验证并写入配置...${PLAIN}"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    local TMP_CONF=$(mktemp)
    
    jq 'if .endpoints == null then .endpoints = [] else . end' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq 'del(.outbounds[] | select(.tag == "WARP" or .tag == "warp" or .tag == "warp-out"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq 'del(.endpoints[] | select(.tag == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq --argjson new "$warp_json" '.endpoints += [$new]' "$CONFIG_FILE" > "$TMP_CONF"
    
    if [[ $? -eq 0 && -s "$TMP_CONF" ]]; then
        mv "$TMP_CONF" "$CONFIG_FILE"
        echo -e "${GREEN}WARP Endpoint 配置完成。${PLAIN}"
        restart_sb
    else
        echo -e "${RED}写入失败，已保留原配置。${PLAIN}"
        rm "$TMP_CONF" 2>/dev/null
    fi
}

# ==========================================
# 3. 路由管理 (带前置检查)
# ==========================================

# 关键修复：检查是否存在 WARP 节点
ensure_warp_exists() {
    # 检查 endpoints 中是否有 WARP
    if jq -e '.endpoints[]? | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null 2>&1; then 
        return 0
    fi
    # 兼容性检查 outbounds
    if jq -e '.outbounds[]? | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null 2>&1; then 
        return 0 
    fi
    
    echo -e "${RED}错误：未检测到 WARP 节点配置！${PLAIN}"
    echo -e "${YELLOW}请先执行 [1. 注册/配置 WARP 凭证] 添加节点，再设置分流规则。${PLAIN}"
    
    # 尝试自动恢复
    if [[ -f "$CRED_FILE" ]]; then
        echo -e "检测到历史凭证备份，是否自动恢复？[y/n]"
        read -p "选择: " recover
        if [[ "$recover" == "y" ]]; then
            source "$CRED_FILE"
            write_warp_config "$PRIV_KEY" "$PUB_KEY" "$V4_ADDR" "$V6_ADDR" "$RESERVED"
            return 0
        fi
    fi
    return 1
}

apply_routing_rule() {
    local rule_json="$1"
    echo -e "${YELLOW}正在应用路由规则...${PLAIN}"
    local TMP_CONF=$(mktemp)
    jq --argjson r "$rule_json" '.route.rules = [$r] + .route.rules' "$CONFIG_FILE" > "$TMP_CONF"
    if [[ $? -eq 0 && -s "$TMP_CONF" ]]; then
        mv "$TMP_CONF" "$CONFIG_FILE"
        restart_sb
    else
        echo -e "${RED}规则应用失败。${PLAIN}"
        rm "$TMP_CONF"
    fi
}

mode_stream() {
    ensure_warp_exists || return
    echo -e "请选择: 1. ${GREEN}域名列表${PLAIN} (推荐)  2. ${YELLOW}Geosite${PLAIN}"
    read -p "选择: " mode
    local rule=""
    if [[ "$mode" == "2" ]]; then
        rule=$(jq -n '{ "geosite": ["netflix","openai","disney","google","youtube"], "outbound": "WARP" }')
    else
        rule=$(jq -n '{ "domain_suffix": ["netflix.com","nflxvideo.net","openai.com","ai.com","disney.com","disneyplus.com","google.com","youtube.com"], "outbound": "WARP" }')
    fi
    apply_routing_rule "$rule"
}

mode_global() {
    ensure_warp_exists || return
    echo -e " a. 仅 IPv4  b. 仅 IPv6  c. 双栈全局"
    read -p "选择: " sub
    local rule=""
    case "$sub" in
        a) rule=$(jq -n '{ "ip_version": 4, "outbound": "WARP" }') ;;
        b) rule=$(jq -n '{ "ip_version": 6, "outbound": "WARP" }') ;;
        c) rule=$(jq -n '{ "network": ["tcp","udp"], "outbound": "WARP" }') ;;
    esac
    apply_routing_rule "$rule"
}

mode_specific_node() {
    ensure_warp_exists || return
    if [[ ! -f "$CONFIG_FILE" ]]; then echo -e "${RED}无配置文件${PLAIN}"; return; fi
    echo -e "${SKYBLUE}正在读取 Sing-box 入站节点...${PLAIN}"
    local node_list=$(jq -r '.inbounds[] | "\(.tag) | \(.type) | \(.listen_port // .listen // "N/A")"' "$CONFIG_FILE" | nl -w 2 -s " ")
    [[ -z "$node_list" ]] && { echo -e "${RED}未找到节点。${PLAIN}"; return; }
    echo -e "------------------------------------------------"
    echo -e "序号 | Tag (标签)   | 类型      | 端口/监听"
    echo -e "------------------------------------------------"
    echo "$node_list"
    echo -e "------------------------------------------------"
    read -p "请输入要走 WARP 的节点序号 (空格分隔): " selection
    local selected_tags_json="[]"
    for num in $selection; do
        local raw_line=$(echo "$node_list" | sed -n "${num}p")
        local tag=$(echo "$raw_line" | awk -F'|' '{print $1}' | awk '{print $2}')
        [[ -n "$tag" ]] && selected_tags_json=$(echo "$selected_tags_json" | jq --arg t "$tag" '. + [$t]')
    done
    local rule=$(jq -n --argjson ib "$selected_tags_json" '{ "inbound": $ib, "outbound": "WARP" }')
    apply_routing_rule "$rule"
}

uninstall_warp() {
    echo -e "${YELLOW}正在卸载 WARP (节点配置 + 路由规则)...${PLAIN}"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_uninstall"
    local TMP_CONF=$(mktemp)
    jq 'del(.outbounds[] | select(.tag == "WARP" or .tag == "warp" or .tag == "warp-out"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq 'if .endpoints then del(.endpoints[] | select(.tag == "WARP")) else . end' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq 'del(.route.rules[] | select(.outbound == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    echo -e "${GREEN}卸载完成。凭证已保留在 $CRED_FILE (下次可自动恢复)${PLAIN}"
    restart_sb
}

show_menu() {
    check_dependencies
    while true; do
        clear
        local status_text="${RED}未配置${PLAIN}"
        if jq -e '.endpoints[]? | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null 2>&1; then 
            status_text="${GREEN}已配置 (Endpoint)${PLAIN}"
        elif jq -e '.outbounds[]? | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null 2>&1; then
            status_text="${YELLOW}已配置 (Legacy)${PLAIN}"
        fi
        
        local ver=$(sing-box version 2>/dev/null | head -n1 | awk '{print $3}')
        
        echo -e "================ Native WARP 配置向导 (Sing-box) ================"
        echo -e " 内核版本: ${SKYBLUE}${ver:-未知}${PLAIN} ${YELLOW}(v6.2 逻辑修复)${PLAIN}"
        echo -e " 配置文件: ${SKYBLUE}$CONFIG_FILE${PLAIN}"
        echo -e " 凭证状态: [$status_text]"
        echo -e "----------------------------------------------------"
        echo -e " 1. 注册/配置 WARP 凭证 ${YELLOW}(卸载后需先点此恢复)${PLAIN}"
        echo -e " 2. 查看当前凭证信息"
        echo -e "----------------------------------------------------"
        echo -e " 3. ${SKYBLUE}模式一：智能流媒体分流 (推荐)${PLAIN}"
        echo -e " 4. ${SKYBLUE}模式二：全局接管 (隐藏 IP)${PLAIN}"
        echo -e " 5. ${SKYBLUE}模式三：指定节点接管 (多节点共存)${PLAIN}"
        echo -e "----------------------------------------------------"
        echo -e " 7. ${RED}禁用/卸载 Native WARP (恢复直连)${PLAIN}"
        echo -e " 0. 返回上级菜单"
        echo -e "===================================================="
        read -p "请输入选项: " choice
        case "$choice" in
            1)
                echo -e "  1. 自动注册 (需 Python)"; echo -e "  2. 手动录入 (Base64/CSV)"
                read -p "  请选择: " reg_type
                if [[ "$reg_type" == "1" ]]; then register_warp; else manual_warp; fi; read -p "按回车继续..." ;;
            2) echo -e "凭证文件: $CRED_FILE"; cat "$CRED_FILE" 2>/dev/null; read -p "按回车继续..." ;;
            3) mode_stream; read -p "按回车继续..." ;;
            4) mode_global; read -p "按回车继续..." ;;
            5) mode_specific_node; read -p "按回车继续..." ;;
            7) uninstall_warp; read -p "按回车继续..." ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

show_menu
