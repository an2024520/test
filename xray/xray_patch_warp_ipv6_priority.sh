#!/bin/bash
echo "v5.0 核心原则：IPV6绝对优先（两种模式：原生IPV6优先和WARP IP6优先）"
sleep 2
# ============================================================
#  Xray IPv6 优先 + WARP 兜底补丁 (v5.0 Ultimate Final)
#  - 核心原则: 无论何种模式，强制触发 DNS 解析以优先匹配 IPv6
#  - 模式1: Native IPv6 -> Direct | IPv4 -> WARP
#  - 模式2: WARP IPv6   -> WARP   | WARP IPv4 -> WARP (强制 V6 优先)
#  - 修复: 强制注入 domainStrategy: IPIfNonMatch
#  - 修复: 靶向清洗逻辑 (Zero-Loss Policy)
#  - 安全: 补全了卸载逻辑，闭环管理
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# ==================== 环境自检 ====================
check_environment() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}安装 jq...${PLAIN}"
        if [[ -f /etc/debian_version ]]; then apt-get update -q && apt-get install -y jq
        elif [[ -f /etc/redhat-release ]]; then yum install -y jq
        else echo -e "${RED}请手动安装 jq${PLAIN}" && exit 1; fi
    fi

    local possible_paths=("/usr/local/etc/xray/config.json" "/etc/xray/config.json" "/usr/local/xray/config.json")
    for path in "${possible_paths[@]}"; do
        if [[ -f "$path" ]]; then CONFIG_FILE="$path"; break; fi
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        echo -e "${RED}未找到 Xray 配置文件。${PLAIN}"; exit 1
    fi
    BACKUP_FILE="${CONFIG_FILE}.ipv6_patch.bak"
}

check_environment
XRAY_BIN=$(command -v xray || echo "/usr/local/bin/xray")
CRED_FILE="/etc/xray/warp_credentials.conf"
[[ $EUID -ne 0 ]] && echo -e "${RED}Root required${PLAIN}" && exit 1

# ==================== WARP 凭证 ====================
manual_warp_input() {
    local def_key="" def_v4="" def_v6="" def_res=""
    if [[ -f "$CRED_FILE" ]]; then
        source "$CRED_FILE" 2>/dev/null
        def_key="$PRIV_KEY"
        def_v4="$V4_ADDR"
        def_v6="$V6_ADDR"
        def_res="$RESERVED"
    fi

    echo -e "${SKYBLUE}=== WARP 配置 ===${PLAIN}"
    read -p "私钥 [默认: ${def_key:0:10}...]: " priv_key
    priv_key=${priv_key:-$def_key}
    [[ -z "$priv_key" ]] && return 1

    read -p "IPv4 [默认: 172.16.0.2/32]: " v4
    v4=${v4:-"172.16.0.2/32"}

    read -p "IPv6 [默认: ${def_v6}]: " v6
    v6=${v6:-$def_v6}
    [[ -z "$v6" ]] && return 1

    read -p "Reserved [默认: ${def_res:-0,0,0}]: " res_input
    res_input=${res_input:-"${def_res:-0,0,0}"}

    local clean_res="${res_input// /}"
    local res_json="[0,0,0]"
    if [[ "$clean_res" =~ ^\[([0-9]+,){2}[0-9]+\]$ ]]; then res_json="$clean_res"
    elif [[ "$clean_res" =~ ^([0-9]+,){2}[0-9]+$ ]]; then res_json="[$clean_res]"
    elif [[ "$clean_res" =~ ^\[.*\]$ ]]; then res_json="$clean_res"; fi

    mkdir -p "$(dirname "$CRED_FILE")"
    cat > "$CRED_FILE" <<EOF
PRIV_KEY="$priv_key"
V4_ADDR="$v4"
V6_ADDR="$v6"
RESERVED="$res_json"
EOF
    echo -e "${GREEN}WARP 凭证已保存。${PLAIN}"
}

# ==================== 注入 warp-out + anti-loop ====================
inject_warp_outbound() {
    source "$CRED_FILE" 2>/dev/null
    [[ -z "$PRIV_KEY" ]] && return 1

    local v4="${V4_ADDR:-""}"
    local v6="$V6_ADDR"
    local key="$PRIV_KEY"
    local res="$RESERVED"
    
    [[ ! "$v4" =~ "/" && -n "$v4" ]] && v4="${v4}/32"
    [[ ! "$v6" =~ "/" ]] && v6="${v6}/128"

    local addr="[\"$v6\""
    [[ -n "$v4" ]] && addr="$addr,\"$v4\""
    addr="$addr]"

    local endpoint="engage.cloudflareclient.com:2408"
    local ipv4_check=$(curl -4 -s -m 3 http://ip.sb 2>/dev/null)
    [[ ! "$ipv4_check" =~ ^[0-9.]+$ ]] && endpoint="2606:4700:d0::a29f:c001:2408"

    # 智能获取直连 Tag
    local direct_tag=$(jq -r '.outbounds[] | select(.tag == "direct" or .tag == "freedom" or .protocol == "freedom") | .tag' "$CONFIG_FILE" | head -n 1)
    [[ -z "$direct_tag" ]] && direct_tag="direct"

    local warp_json=$(jq -n \
        --arg key "$key" \
        --argjson addr "$addr" \
        --argjson res "$res" \
        --arg ep "$endpoint" \
        '{
            "tag": "warp-out",
            "protocol": "wireguard",
            "settings": {
                "secretKey": $key,
                "address": $addr,
                "peers": [{
                    "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                    "endpoint": $ep,
                    "reserved": $res,
                    "mtu": 1280
                }]
            }
        }')

    local tmp=$(mktemp)
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_warp"

    jq 'del(.outbounds[] | select(.tag == "warp-out"))' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    jq --argjson w "$warp_json" '.outbounds += [$w]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    # Anti-loop (幂等)
    jq '
        .routing.rules |= map(
            select(
                (.domain // empty) as $d | 
                $d | inside(["engage.cloudflareclient.com","cloudflare.com","www.cloudflare.com","cdn.cloudflare.net","workers.dev"]) | not
            )
        )
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    local anti_loop_json=$(jq -n --arg dt "$direct_tag" '{
        "type": "field",
        "domain": ["engage.cloudflareclient.com","cloudflare.com","www.cloudflare.com","cdn.cloudflare.net","workers.dev"],
        "outboundTag": $dt
    }')
    jq --argjson al "$anti_loop_json" '.routing.rules = [$al] + .routing.rules' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    echo -e "${GREEN}warp-out 已注入。${PLAIN}"
}

# ==================== 应用分流策略 ====================
inject_rule() {
    if ! jq -e '.outbounds[] | select(.tag == "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
        if [[ -f "$CRED_FILE" ]]; then inject_warp_outbound
        else manual_warp_input && inject_warp_outbound; fi
    fi

    echo -e "${SKYBLUE}请选择模式:${PLAIN}"
    echo -e " 1. 原生IPv6直连 + IPv4 WARP兜底"
    echo -e " 2. 双栈走WARP (强制IPv6优先解析)"
    read -p "选 (默认1): " mode_select
    mode_select=${mode_select:-1}

    local direct_tag=$(jq -r '.outbounds[] | select(.tag == "direct" or .tag == "freedom" or .protocol == "freedom") | .tag' "$CONFIG_FILE" | head -n 1)
    [[ -z "$direct_tag" ]] && direct_tag="direct"

    # 确定 IPv6 的去向
    local v6_target="$direct_tag"
    [[ "$mode_select" == "2" ]] && v6_target="warp-out"

    echo -e "${YELLOW}读取节点...${PLAIN}"
    local node_list=$(jq -r '.inbounds[] | select(.protocol != "dokodemo-door" and .tag != "api") | "\(.tag) | \(.protocol)"' "$CONFIG_FILE" | nl)
    echo "$node_list"
    read -p "选择节点序号 (空格分隔): " selection
    
    local tags_list=()
    for num in $selection; do
        local tag=$(echo "$node_list" | sed -n "${num}p" | awk -F'|' '{print $1}' | awk '{print $2}')
        [[ -n "$tag" ]] && tags_list+=("$tag")
    done
    [[ ${#tags_list[@]} -eq 0 ]] && return

    local tags_json=$(printf '%s\n' "${tags_list[@]}" | jq -R . | jq -s .)
    local tmp=$(mktemp)
    cp "$CONFIG_FILE" "$BACKUP_FILE"

    # 1. 强制 IPIfNonMatch (核心)
    jq 'if .routing.domainStrategy? == null or .routing.domainStrategy == "AsIs" then .routing.domainStrategy = "IPIfNonMatch" else . end' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    # 2. 靶向清洗 (保护用户原有 GeoIP/广告规则)
    jq --argjson targets "$tags_json" '
        .routing.rules |= map(
            select(
                (has("inboundTag") | not) or
                (.inboundTag | inside($targets) | not) or 
                (
                    .outboundTag != "warp-out" and 
                    (.ip? | index("::/0") // false | not) and 
                    (.ip? | index("0.0.0.0/0") // false | not)
                )
            )
        )
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    # 3. 注入双层 IP 规则 (v5.0 核心逻辑)
    # 无论是模式1还是模式2，都使用 ::/0 和 0.0.0.0/0 显式分层
    local rule_v6=$(jq -n --argjson t "$tags_json" --arg dt "$v6_target" '{ 
        "type": "field", "inboundTag": $t, "network": "tcp,udp", "ip": ["::/0"], "outboundTag": $dt 
    }')
    local rule_v4=$(jq -n --argjson t "$tags_json" '{ 
        "type": "field", "inboundTag": $t, "network": "tcp,udp", "ip": ["0.0.0.0/0"], "outboundTag": "warp-out" 
    }')
    
    jq --argjson r1 "$rule_v6" --argjson r2 "$rule_v4" \
       '.routing.rules = [$r1, $r2] + .routing.rules' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    if [[ -f "$XRAY_BIN" ]] && ! "$XRAY_BIN" run -test -conf "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}预检失败，已回滚${PLAIN}"; cp "$BACKUP_FILE" "$CONFIG_FILE"; return 1
    fi

    systemctl restart xray && echo -e "${GREEN}应用成功！${PLAIN}" || { cp "$BACKUP_FILE" "$CONFIG_FILE"; echo -e "${RED}失败回滚${PLAIN}"; }
}

# ==================== 卸载策略 ====================
uninstall_policy() {
    echo -e "${YELLOW}正在移除...${PLAIN}"
    local node_list=$(jq -r '.inbounds[] | select(.protocol != "dokodemo-door" and .tag != "api") | "\(.tag) | \(.protocol)"' "$CONFIG_FILE" | nl)
    echo "$node_list"
    read -p "选择节点: " selection
    
    local tags_list=()
    for num in $selection; do
        local tag=$(echo "$node_list" | sed -n "${num}p" | awk -F'|' '{print $1}' | awk '{print $2}')
        [[ -n "$tag" ]] && tags_list+=("$tag")
    done
    [[ ${#tags_list[@]} -eq 0 ]] && return

    local tags_json=$(printf '%s\n' "${tags_list[@]}" | jq -R . | jq -s .)
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    local tmp=$(mktemp)

    # 靶向移除规则
    jq --argjson targets "$tags_json" '
        .routing.rules |= map(
            select(
                (has("inboundTag") | not) or
                (.inboundTag | inside($targets) | not)
            )
        )
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    echo
    read -p "同时删除 warp-out? (y/N): " del_warp
    if [[ "$del_warp" == "y" || "$del_warp" == "Y" ]]; then
        jq 'del(.outbounds[] | select(.tag == "warp-out"))' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
        echo -e "${GREEN}warp-out 已删除。${PLAIN}"
        
        read -p "删除凭证? (y/N): " del_cred
        if [[ "$del_cred" == "y" || "$del_cred" == "Y" ]]; then
            rm -f "$CRED_FILE"
            echo -e "${GREEN}凭证已删。${PLAIN}"
        fi
    fi

    systemctl restart xray && echo -e "${GREEN}卸载完成。${PLAIN}" || { cp "$BACKUP_FILE" "$CONFIG_FILE"; echo -e "${RED}失败回滚${PLAIN}"; }
}

# ==================== 菜单 ====================
while true; do
    clear
    local st="${RED}未配置${PLAIN}"
    local has_cred=false
    [[ -f "$CRED_FILE" ]] && grep -q "PRIV_KEY" "$CRED_FILE" && has_cred=true

    if jq -e '.outbounds[] | select(.tag == "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
        st="${GREEN}WARP 运行中${PLAIN}"
    elif $has_cred; then
        st="${YELLOW}凭证已存${PLAIN}"
    fi

    # 动态提示状态
    local mode_hint=""
    if jq -e '.outbounds[] | select(.tag == "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
        if jq -e '.routing.rules[] | select(.ip == ["::/0"] and .outboundTag != "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
            mode_hint="当前模式: 原生IPv6直连 + IPv4 WARP兜底"
        else
            mode_hint="当前模式: 双栈走WARP (强制IPv6优先解析)"
        fi
    fi

    echo -e "============================================"
    echo -e " Xray IPv6 优先 + WARP 兜底补丁 (v5.0 Ultimate Final)"
    echo -e " 当前状态: [$st]"
    [[ -n "$mode_hint" ]] && echo -e " $mode_hint"
    echo -e "--------------------------------------------"
    echo -e " 1. 应用分流策略 (Fix: 强制解析)"
    echo -e " 2. 卸载分流策略"
    echo -e " 3. 手动配置 WARP"
    echo -e " 0. 退出"
    echo -e "============================================"
    read -p "选: " c
    case "$c" in
        1) inject_rule; read -p "..." ;;
        2) uninstall_policy; read -p "..." ;;
        3) manual_warp_input; read -p "..." ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效${PLAIN}"; sleep 1 ;;
    esac
done