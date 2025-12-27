#!/bin/bash
echo "v5.7"
sleep 5
# ==============================================================================
# Script Name: singbox_patch_warp_ipv6_priority.sh
# Version: v5.7 (Absolute Pure-v6 Edition)
# 
# Critical Changes:
#   1. Endpoint: REMOVED auto-detection. FORCED to use IPv6 Endpoint IP.
#      (Reason: Dirty IPv4 might pass curl check but fail WARP handshake).
#   2. DNS: Enforces Google/CF IPv6 DNS (No IPv4 fallback).
#   3. Route: IPv6 -> Direct | All Others -> WARP.
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE=""
CRED_FILE="/etc/sing-box/warp_credentials.conf"
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done

if [[ "$AUTO_SETUP" == "true" ]]; then
    if [[ -z "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: [自动模式] 未检测到 config.json 配置文件！流程终止。${PLAIN}"
        exit 1
    fi
else
    if [[ -z "$CONFIG_FILE" ]]; then
        CONFIG_FILE="/etc/sing-box/config.json"
        echo -e "${YELLOW}提示: 未找到现有 config.json，操作时将尝试创建。${PLAIN}"
    fi
fi

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

# [v5.7] 强制环境设定：忽略脏 IPv4，直接锁定 IPv6
check_env() {
    echo -e "${YELLOW}正在配置网络环境 (强制 Pure IPv6 模式)...${PLAIN}"
    # 不再检测 curl -4，直接视为 IPv4 不可用/不可信
    # 强制使用 Cloudflare 官方 IPv6 Endpoint IP
    FINAL_EP_ADDR="2606:4700:d0::a29f:c001"
    FINAL_EP_PORT=2408
    
    echo -e "${SKYBLUE}>>> Endpoint 已锁定: ${FINAL_EP_ADDR} (规避脏 IPv4)${PLAIN}"
    
    export FINAL_EP_ADDR
    export FINAL_EP_PORT
}

get_direct_tag() {
    local tag=$(jq -r '.outbounds[] | select(.type=="direct" or .tag=="direct" or .tag=="freedom") | .tag' "$CONFIG_FILE" | head -n1)
    echo "${tag:-direct}"
}

restart_sb() {
    mkdir -p /var/log/sing-box/
    chown -R root:root /var/log/sing-box/ >/dev/null 2>&1
    echo -e "${YELLOW}重启 Sing-box 服务...${PLAIN}"
    if command -v sing-box &> /dev/null; then
        local check_out=$(sing-box check -c "$CONFIG_FILE" 2>&1)
        if [[ $? -ne 0 ]]; then
             echo -e "${RED}配置语法校验失败！${PLAIN}"
             echo -e "${SKYBLUE}$check_out${PLAIN}"
             echo -e "${RED}正在回滚...${PLAIN}"
             [[ -f "${CONFIG_FILE}.bak" ]] && cp "${CONFIG_FILE}.bak" "$CONFIG_FILE"
             return 1
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
        echo -e "${RED}服务重启失败！请检查日志 (journalctl -u sing-box -n 20)。${PLAIN}"
    fi
}

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

save_credentials() {
    cat > "$CRED_FILE" <<EOF
PRIV_KEY="$1"
PUB_KEY="$2"
V4_ADDR="$3"
V6_ADDR="$4"
RESERVED="$5"
EOF
    echo -e "${GREEN}凭证已备份。${PLAIN}"
}

write_warp_config() {
    local priv="$1" pub="$2" v4="$3" v6="$4" res="$5"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$(dirname "$CONFIG_FILE")"
        echo "{}" > "$CONFIG_FILE"
    fi
    [[ ! "$v4" =~ "/" && -n "$v4" && "$v4" != "null" ]] && v4="${v4}/32"
    [[ ! "$v6" =~ "/" && -n "$v6" && "$v6" != "null" ]] && v6="${v6}/128"
    local addr_json="[]"
    [[ -n "$v4" && "$v4" != "null" ]] && addr_json=$(echo "$addr_json" | jq --arg ip "$v4" '. + [$ip]')
    [[ -n "$v6" && "$v6" != "null" ]] && addr_json=$(echo "$addr_json" | jq --arg ip "$v6" '. + [$ip]')
    check_env
    
    # Endpoint 结构 (Sing-box v1.12+ Standard)
    local endpoint_json=$(jq -n \
        --arg priv "$priv" \
        --arg pub "$pub" \
        --argjson addr "$addr_json" \
        --argjson res "$res" \
        --arg ep_addr "$FINAL_EP_ADDR" \
        --argjson ep_port "${FINAL_EP_PORT:-2408}" \
        '{ 
            "type": "wireguard", 
            "tag": "WARP", 
            "system": false,
            "address": $addr, 
            "private_key": $priv,
            "peers": [
                { 
                    "address": $ep_addr, 
                    "port": $ep_port, 
                    "public_key": $pub, 
                    "reserved": $res,
                    "allowed_ips": ["0.0.0.0/0", "::/0"]
                }
            ] 
        }')
    echo -e "${YELLOW}正在应用 Endpoint 架构配置...${PLAIN}"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    local TMP_CONF=$(mktemp)
    jq '.endpoints = (.endpoints // []) | .outbounds = (.outbounds // [])' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq 'del(.outbounds[] | select(.tag == "WARP" or .tag == "warp" or .type == "wireguard"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq 'del(.endpoints[] | select(.tag == "warp-endpoint" or .tag == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq --argjson ep "$endpoint_json" '.endpoints += [$ep]' "$CONFIG_FILE" > "$TMP_CONF"
    if [[ $? -eq 0 && -s "$TMP_CONF" ]]; then
        mv "$TMP_CONF" "$CONFIG_FILE"
        echo -e "${GREEN}WARP Endpoint 已写入。${PLAIN}"
        restart_sb
    else
        echo -e "${RED}写入失败，恢复备份...${PLAIN}"
        cp "${CONFIG_FILE}.bak" "$CONFIG_FILE"
        rm "$TMP_CONF"
    fi
}

register_warp() {
    ensure_python || return 1
    echo -e "${YELLOW}正在向 Cloudflare 注册账号...${PLAIN}"
    if ! command -v wg &> /dev/null; then apt install -y wireguard-tools || yum install -y wireguard-tools; fi
    local priv_key=$(wg genkey)
    local pub_key=$(echo "$priv_key" | wg pubkey)
    local install_id=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 22)
    local result=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "User-Agent: okhttp/3.12.1" -H "Content-Type: application/json; charset=UTF-8" \
        -d "{\"key\":\"${pub_key}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${install_id}:APA91bHuwEuLNj_${install_id}\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Android\",\"serial_number\":\"${install_id}\",\"locale\":\"zh_CN\"}")
    local v4=$(echo "$result" | jq -r '.config.interface.addresses.v4')
    local v6=$(echo "$result" | jq -r '.config.interface.addresses.v6')
    local client_id=$(echo "$result" | jq -r '.config.client_id')
    [[ "$v4" == "null" || -z "$v4" ]] && { echo -e "${RED}注册失败${PLAIN}"; return 1; }
    local res_json=$(python3 -c "import base64, json; d=base64.b64decode('$client_id'); print(json.dumps([x for x in d[0:3]]))" 2>/dev/null)
    save_credentials "$priv_key" "$pub_key" "$v4" "$v6" "$res_json"
    write_warp_config "$priv_key" "$pub_key" "$v4" "$v6" "$res_json"
}

manual_warp() {
    local def_priv="" def_pub="" def_v4="" def_v6="" def_res=""
    [[ -f "$CRED_FILE" ]] && { source "$CRED_FILE"; def_priv="$PRIV_KEY"; def_pub="$PUB_KEY"; def_v4="$V4_ADDR"; def_v6="$V6_ADDR"; def_res="$RESERVED"; }
    read -p "私钥 [默认: ${def_priv:0:10}...]: " priv_key
    priv_key=${priv_key:-$def_priv}
    [[ -z "$priv_key" ]] && { echo "私钥必填"; return; }
    read -p "对端公钥 [默认: 官方]: " peer_pub
    peer_pub=${peer_pub:-"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="}
    read -p "内网 IPv4 [默认: 172.16.0.2/32]: " v4
    v4=${v4:-"172.16.0.2/32"}
    read -p "内网 IPv6 [默认: $def_v6]: " v6
    v6=${v6:-$def_v6}
    read -p "Reserved [默认: $def_res]: " res_input
    res_input=${res_input:-$def_res}
    local res_json="[0,0,0]"
    if [[ "$res_input" =~ [0-9] ]]; then
        res_json=$(clean_reserved "$res_input")
    else
        res_json=$(base64_to_reserved_shell "$res_input")
        [[ -z "$res_json" ]] && { ensure_python; res_json=$(python3 -c "import base64, json; d=base64.b64decode('$res_input'); print(json.dumps([x for x in d]))" 2>/dev/null); }
    fi
    save_credentials "$priv_key" "$peer_pub" "$v4" "$v6" "$res_json"
    write_warp_config "$priv_key" "$peer_pub" "$v4" "$v6" "$res_json"
}

ensure_warp_exists() {
    if jq -e '.endpoints[]? | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null 2>&1; then return 0; fi
    if [[ -f "$CRED_FILE" ]]; then
        read -p "未发现配置但存在凭证，是否恢复？[y/n]: " r
        [[ "$r" == "y" ]] && { source "$CRED_FILE"; write_warp_config "$PRIV_KEY" "$PUB_KEY" "$V4_ADDR" "$V6_ADDR" "$RESERVED"; return 0; }
    fi
    return 1
}

apply_routing_rule() {
    local rule_json="$1"
    echo -e "${YELLOW}正在应用路由规则...${PLAIN}"
    local TMP_CONF=$(mktemp)
    jq 'del(.route.rules[] | select(.outbound == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq --argjson r "$rule_json" '.route.rules = [$r] + .route.rules' "$CONFIG_FILE" > "$TMP_CONF"
    if [[ $? -eq 0 && -s "$TMP_CONF" ]]; then
        mv "$TMP_CONF" "$CONFIG_FILE"
        restart_sb
    else
        echo -e "${RED}规则应用失败。${PLAIN}"; rm "$TMP_CONF"
    fi
}

get_anti_loop_rule() {
    if [[ -z "$FINAL_EP_ADDR" ]]; then check_env >/dev/null; fi
    local ip_cidr="[]"
    local direct_tag=$(get_direct_tag)
    if [[ "$FINAL_EP_ADDR" == *":"* ]]; then ip_cidr="[\"${FINAL_EP_ADDR}/128\"]"; fi
    jq -n --argjson ip "$ip_cidr" --arg dt "$direct_tag" '{ "domain": ["engage.cloudflareclient.com", "cloudflare.com"], "ip_cidr": $ip, "outbound": $dt }'
}

fix_dns_strict_v6() {
    local TMP_CONF=$(mktemp)
    # [关键] 仅使用 Google/CF IPv6 DNS，彻底放弃 IPv4 DNS
    local clean_dns='{
        "servers": [
            {"tag": "google_v6", "type": "udp", "server": "2001:4860:4860::8888"},
            {"tag": "cf_v6", "type": "udp", "server": "2606:4700:4700::1111"},
            {"tag": "local", "type": "local"}
        ],
        "rules": [],
        "final": "google_v6",
        "strategy": "prefer_ipv6"
    }'
    
    echo -e "${YELLOW}>>> 正在配置纯净 IPv6 DNS (规避脏 IPv4)...${PLAIN}"
    jq --argjson dns "$clean_dns" '.dns = $dns' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq '.route.default_domain_resolver = "google_v6"' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
}

mode_stream() {
    ensure_warp_exists || return
    apply_routing_rule "$(jq -n '{ "domain_suffix": ["netflix.com","nflxvideo.net","openai.com","ai.com","google.com","youtube.com"], "outbound": "WARP" }')"
}

mode_global() {
    ensure_warp_exists || return
    echo -e " a. 仅 IPv4  b. 仅 IPv6  c. 双栈全接管"
    read -p "选择模式: " sub
    local warp_rule=""
    case "$sub" in
        a) warp_rule=$(jq -n '{ "ip_version": 4, "outbound": "WARP" }') ;;
        b) warp_rule=$(jq -n '{ "ip_version": 6, "outbound": "WARP" }') ;;
        *) warp_rule=$(jq -n '{ "outbound": "WARP" }') ;;
    esac
    apply_routing_rule "$warp_rule"
    apply_routing_rule "$(get_anti_loop_rule)"
    echo -e "${GREEN}全局接管策略已应用。${PLAIN}"
}

# [v5.7] 强制使用 Pure IPv6 逻辑
mode_flexible_node() {
    ensure_warp_exists || return
    
    echo -e "${YELLOW}正在读取节点列表...${PLAIN}"
    local tags_raw
    mapfile -t tags_raw < <(jq -r '.inbounds[] | "\(.tag) | \(.type)"' "$CONFIG_FILE")
    
    if [[ ${#tags_raw[@]} -eq 0 ]]; then echo -e "${RED}无有效入站节点。${PLAIN}"; return; fi
    
    echo -e "------------------------------------------------"
    local i=1
    for t in "${tags_raw[@]}"; do
        echo "     $i  $t"
        ((i++))
    done
    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}步骤 1/2: 选择节点序号 (空格分隔，如: 1 3)${PLAIN}"
    read -p "输入序号: " selection
    
    local tags_list=()
    for num in $selection; do
        local idx=$((num-1))
        local raw_entry="${tags_raw[$idx]}"
        if [[ -n "$raw_entry" ]]; then
            local tag=$(echo "$raw_entry" | sed 's/ | .*//')
            tags_list+=("$tag")
            echo -e "已选中: ${GREEN}${tag}${PLAIN}"
        fi
    done
    
    if [[ ${#tags_list[@]} -eq 0 ]]; then echo -e "${RED}无效选择。${PLAIN}"; return; fi
    local tags_json=$(printf '%s\n' "${tags_list[@]}" | jq -R . | jq -s .)

    echo -e "\n${SKYBLUE}步骤 2/2: 选择接管策略${PLAIN}"
    echo -e " a. IPv6 优先 (直连) + 仅 IPv4 走 WARP ${GREEN}[推荐]${PLAIN}"
    echo -e " b. IPv4 优先 (直连) + 仅 IPv6 走 WARP"
    echo -e " c. 双栈全部走 WARP (完全隐身)"
    read -p "请选择: " sub
    
    # 强制修正 DNS 为 Pure IPv6 模式
    fix_dns_strict_v6
    
    local direct_tag=$(get_direct_tag)
    local anti_loop=$(get_anti_loop_rule)
    local rules="[]"
    
    case "$sub" in
        a)
            # [Xray V1 逻辑复刻 - 漏斗模式]
            # 1. 选中节点 -> OpenAI -> WARP
            # 2. 选中节点 -> IPv6 -> Direct (优先放行)
            # 3. 选中节点 -> 剩余(IPv4/Domain) -> WARP (强制捕获)
            # 4. 全局 IPv4 -> WARP (本地流量兜底)
            rules=$(jq -n --argjson tags "$tags_json" --arg dt "$direct_tag" '[
                { "inbound": $tags, "domain_suffix": ["openai.com","ai.com","chatgpt.com"], "outbound": "WARP" },
                { "inbound": $tags, "ip_version": 6, "outbound": $dt },
                { "inbound": $tags, "outbound": "WARP" },
                { "ip_version": 4, "outbound": "WARP" }
            ]')
            ;;
        b)
            rules=$(jq -n --argjson tags "$tags_json" --arg dt "$direct_tag" '[
                { "inbound": $tags, "ip_version": 6, "outbound": "WARP" },
                { "inbound": $tags, "outbound": $dt }
            ]')
            ;;
        *)
            rules=$(jq -n --argjson tags "$tags_json" '[
                { "inbound": $tags, "outbound": "WARP" }
            ]')
            ;;
    esac

    echo -e "${YELLOW}正在应用策略...${PLAIN}"
    local TMP_CONF=$(mktemp)
    
    jq 'del(.route.rules[] | select(.outbound == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq --argjson r "$rules" --argjson al "$anti_loop" '.route.rules = [$al] + $r + .route.rules' "$CONFIG_FILE" > "$TMP_CONF"
    
    if [[ $? -eq 0 && -s "$TMP_CONF" ]]; then
        mv "$TMP_CONF" "$CONFIG_FILE"
        restart_sb
        echo -e "${GREEN}多节点策略应用成功！${PLAIN}"
    else
        echo -e "${RED}策略应用失败。${PLAIN}"; rm "$TMP_CONF"
    fi
}

mode_ipv6_priority_global() {
    ensure_warp_exists || return
    echo -e "${YELLOW}正在应用 IPv6 优先策略 (全局生效)...${PLAIN}"
    fix_dns_strict_v6
    local rules='[
        { "domain_suffix": ["openai.com", "ai.com", "chatgpt.com"], "outbound": "WARP" },
        { "ip_version": 4, "outbound": "WARP" }
    ]'
    local anti_loop=$(get_anti_loop_rule)
    local TMP_CONF=$(mktemp)
    jq 'del(.route.rules[] | select(.outbound == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq --argjson r "$rules" --argjson al "$anti_loop" '.route.rules = [$al] + $r + .route.rules' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    restart_sb
    echo -e "${GREEN}全局策略已应用：IPv6直连 / IPv4 WARP。${PLAIN}"
}

uninstall_warp() {
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_un"
    local TMP_CONF=$(mktemp)
    jq 'del(.outbounds[] | select(.tag == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq 'del(.endpoints[] | select(.tag == "warp-endpoint" or .tag == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq 'del(.route.rules[] | select(.outbound == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    echo -e "${GREEN}WARP 卸载完成。${PLAIN}"; restart_sb
}

show_menu() {
    check_dependencies
    while true; do
        clear
        local st="${RED}未配置${PLAIN}"
        if [[ -f "$CONFIG_FILE" ]]; then
            if jq -e '.endpoints[]? | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null 2>&1; then
                st="${GREEN}已配置 (v5.7 Pure-v6)${PLAIN}"
            fi
        fi
        echo -e "================ Native WARP 管理中心 (Sing-box 1.12+) ================"
        echo -e " 当前配置状态: [$st]"
        echo -e "----------------------------------------------------"
        echo -e " 1. 配置 WARP 凭证 (自动/手动)"
        echo -e " 2. 查看当前凭证信息"
        echo -e " 3. 模式一：流媒体分流 (仅 Netflix/OpenAI 等)"
        echo -e " 4. 模式二：全局接管 (含 a/b/c 策略)"
        echo -e " 5. 模式三：指定节点接管 (支持 v4优先/v6优先/双栈) [强力推荐]"
        echo -e " 6. 模式四：全局 IPv6 优先 (适合单节点环境)"
        echo -e " 7. 卸载 Native WARP"
        echo -e " 0. 返回上级菜单"
        read -p "请选择: " choice
        case "$choice" in
            1) echo -e "1. 自动; 2. 手动"; read -p "选: " t; [[ "$t" == "1" ]] && register_warp || manual_warp; read -p "回车继续..." ;;
            2) cat "$CRED_FILE" 2>/dev/null; read -p "回车继续..." ;;
            3) mode_stream; read -p "回车继续..." ;;
            4) mode_global; read -p "回车继续..." ;;
            5) mode_flexible_node; read -p "回车继续..." ;;
            6) mode_ipv6_priority_global; read -p "回车继续..." ;;
            7) uninstall_warp; read -p "回车继续..." ;;
            0) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

auto_main() {
    echo -e "${GREEN}>>> [WARP-SB] 启动自动化部署 (v5.7)...${PLAIN}"
    check_dependencies
    if [[ -n "$WARP_PRIV_KEY" ]] && [[ -n "$WARP_IPV6" ]]; then
        save_credentials "$WARP_PRIV_KEY" "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=" "172.16.0.2/32" "$WARP_IPV6" "${WARP_RESERVED:-[0,0,0]}"
        write_warp_config "$WARP_PRIV_KEY" "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=" "172.16.0.2/32" "$WARP_IPV6" "${WARP_RESERVED:-[0,0,0]}"
    else
        register_warp
    fi

    if [[ -n "$WARP_INBOUND_TAGS" ]]; then
        fix_dns_strict_v6
        local tags_json=$(echo "$WARP_INBOUND_TAGS" | jq -R 'split(",")')
        local direct_tag=$(get_direct_tag)
        local anti_loop=$(get_anti_loop_rule)
        local rules=$(jq -n --argjson tags "$tags_json" --arg dt "$direct_tag" '[
            { "inbound": $tags, "domain_suffix": ["openai.com"], "outbound": "WARP" },
            { "inbound": $tags, "ip_version": 6, "outbound": $dt },
            { "inbound": $tags, "outbound": "WARP" },
            { "ip_version": 4, "outbound": "WARP" }
        ]')
        local TMP_CONF=$(mktemp)
        jq 'del(.route.rules[] | select(.outbound == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
        jq --argjson r "$rules" --argjson al "$anti_loop" '.route.rules = [$al] + $r + .route.rules' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
        restart_sb
        echo -e "${GREEN}>>> [WARP-SB] 自动化多节点策略(v4优先)已应用。${PLAIN}"
        return
    fi
    
    local rule=""
    case "$WARP_MODE_SELECT" in
        1) rule=$(jq -n '{ "ip_version": 4, "outbound": "WARP" }') ;;
        2) rule=$(jq -n '{ "ip_version": 6, "outbound": "WARP" }') ;;
        4) rule=$(jq -n '{ "outbound": "WARP" }') ;;
        6) mode_ipv6_priority_global; return ;; 
        *) rule=$(jq -n '{ "domain_suffix": ["netflix.com","openai.com","google.com","youtube.com"], "outbound": "WARP" }') ;;
    esac
    if [[ -n "$rule" ]]; then apply_routing_rule "$rule"; fi
    apply_routing_rule "$(get_anti_loop_rule)"
    echo -e "${GREEN}>>> [WARP-SB] 自动化配置完成。${PLAIN}"
}

if [[ "$AUTO_SETUP" == "true" ]]; then auto_main; else show_menu; fi
