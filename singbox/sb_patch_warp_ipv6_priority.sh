#!/bin/bash
echo "v4.6  核心原则：IPV6绝对优先（两种模式：原生IPV6优先和WARP IP6优先）"
sleep 2
# ============================================================
#  Sing-box 分流策略管理器 (v4.6 Native Pure)
#  - 核心原则：IPV6绝对优先（两种模式：原生IPV6优先和WARP IP6优先）
#  - 核心哲学: 遵循 v1.12+ 原生隐式路由 (Route -> Endpoint)
#  - 架构: 无 Bridge，无冗余，直接点对点接管
#  - 兼容性: 完美适配 Sing-box v1.12+ (2025标准)
#  - 保护: 保留 JSON 语法级校验 (非 TUN 接口才注入 domain_strategy)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 未找到 config.json 配置文件！${PLAIN}"
    exit 1
fi

BACKUP_FILE="${CONFIG_FILE}.strategy.bak"
CRED_FILE="/etc/sing-box/warp_credentials.conf"

# 1. 基础环境检查
check_env() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}正在安装 jq...${PLAIN}"
        if command -v apt-get &> /dev/null; then apt-get update && apt-get install -y jq
        elif command -v yum &> /dev/null; then yum install -y jq
        elif command -v apk &> /dev/null; then apk add jq
        else echo -e "${RED}错误: 无法自动安装 jq，请手动安装。${PLAIN}"; exit 1; fi
    fi
}

# 2. WARP 凭证手动输入
manual_warp_input() {
    local def_priv="" def_pub="" def_v4="" def_v6="" def_res=""
    if [[ -f "$CRED_FILE" ]]; then
        source "$CRED_FILE" 2>/dev/null
        def_priv="$PRIV_KEY"
        def_pub="$PUB_KEY"
        def_v4="$V4_ADDR"
        def_v6="$V6_ADDR"
        def_res="$RESERVED"
    fi

    echo -e "${SKYBLUE}=== WARP 手动配置（首次必填，后续可直接回车）===${PLAIN}"
    read -p "私钥 [默认: ${def_priv:0:10}...]: " priv_key
    priv_key=${priv_key:-$def_priv}
    [[ -z "$priv_key" ]] && { echo -e "${RED}私钥必填！${PLAIN}"; return 1; }

    read -p "对端公钥 [默认: 官方]: " peer_pub
    peer_pub=${peer_pub:-"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="}

    read -p "内网 IPv4 [默认: 172.16.0.2/32]: " v4
    v4=${v4:-"172.16.0.2/32"}

    read -p "内网 IPv6 [默认: ${def_v6}]: " v6
    v6=${v6:-$def_v6}
    [[ -z "$v6" ]] && { echo -e "${RED}IPv6 地址必填！${PLAIN}"; return 1; }

    read -p "Reserved [默认: ${def_res:-[0,0,0]}]: " res_input
    res_input=${res_input:-"${def_res:-[0,0,0]}"}

    local clean_res="${res_input// /}"
    local res_json="[0,0,0]"
    if [[ "$clean_res" =~ ^\[([0-9]+,){2}[0-9]+\]$ ]]; then res_json="$clean_res";
    elif [[ "$clean_res" =~ ^([0-9]+,){2}[0-9]+$ ]]; then res_json="[$clean_res]";
    elif [[ "$clean_res" =~ ^\[.*\]$ ]]; then res_json="$clean_res"; fi

    mkdir -p "$(dirname "$CRED_FILE")"
    cat > "$CRED_FILE" <<EOF
PRIV_KEY="$priv_key"
PUB_KEY="$peer_pub"
V4_ADDR="$v4"
V6_ADDR="$v6"
RESERVED="$res_json"
EOF

    echo -e "${GREEN}WARP 凭证已保存。${PLAIN}"
    return 0
}

# 3. 自动注入 WARP Endpoint (Native Direct)
write_warp_endpoint() {
    source "$CRED_FILE" 2>/dev/null
    [[ -z "$PRIV_KEY" || -z "$V6_ADDR" ]] && { echo -e "${RED}凭证加载失败！${PLAIN}"; return 1; }

    local v4="${V4_ADDR:-""}"
    local v6="$V6_ADDR"
    local priv="$PRIV_KEY"
    local pub="$PUB_KEY"
    local res="$RESERVED"

    [[ ! "$v4" =~ "/" && -n "$v4" ]] && v4="${v4}/32"
    [[ ! "$v6" =~ "/" ]] && v6="${v6}/128"

    local addr_json="[]"
    [[ -n "$v4" ]] && addr_json=$(echo "$addr_json" | jq --arg ip "$v4" '. + [$ip]')
    [[ -n "$v6" ]] && addr_json=$(echo "$addr_json" | jq --arg ip "$v6" '. + [$ip]')

    local ep_addr="engage.cloudflareclient.com"
    local ipv4_check=$(curl -4 -s -m 3 http://ip.sb 2>/dev/null)
    [[ ! "$ipv4_check" =~ ^[0-9.]+$ ]] && ep_addr="2606:4700:d0::a29f:c001"

    local endpoint_json=$(jq -n \
        --arg priv "$priv" \
        --arg pub "$pub" \
        --argjson addr "$addr_json" \
        --argjson res "$res" \
        --arg ep_addr "$ep_addr" \
        '{ 
            "type": "wireguard", 
            "tag": "WARP", 
            "system": false,
            "address": $addr, 
            "private_key": $priv,
            "peers": [
                { 
                    "address": $ep_addr, 
                    "port": 2408, 
                    "public_key": $pub, 
                    "reserved": $res,
                    "allowed_ips": ["0.0.0.0/0", "::/0"]
                }
            ] 
        }')

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_endpoint"
    local tmp=$(mktemp)

    # === 清洗逻辑: 确保没有同名 Tag 阻碍隐式路由 ===
    jq 'del(.endpoints[]? | select(.tag == "WARP" or .tag == "WARP-EP"))' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    jq 'del(.outbounds[]? | select(.tag == "WARP"))' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    # 仅注入 Endpoint
    jq --argjson ep "$endpoint_json" '.endpoints += [$ep]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    # 注入 Anti-loop
    jq '
        .route.rules |= map(
            select(
                (.domain // empty) as $d | 
                $d | inside(["engage.cloudflareclient.com","cloudflare.com","www.cloudflare.com","cdn.cloudflare.net","workers.dev"]) | not
            )
        )
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    
    local direct_tag=$(jq -r '.outbounds[] | select(.type == "direct") | .tag // "direct"' "$CONFIG_FILE" | head -n 1)
    [[ -z "$direct_tag" ]] && direct_tag="direct"
    local anti_loop_json=$(jq -n --arg dt "$direct_tag" '{
        "domain": [
            "engage.cloudflareclient.com",
            "cloudflare.com",
            "www.cloudflare.com",
            "cdn.cloudflare.net",
            "workers.dev"
        ],
        "outbound": $dt
    }')
    jq --argjson al "$anti_loop_json" '.route.rules = [$al] + .route.rules' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    echo -e "${GREEN}WARP Endpoint (Native) 已配置。${PLAIN}"
}

# 4. 获取目标节点
get_target_nodes() {
    echo -e "${SKYBLUE}正在读取入站节点列表...${PLAIN}"
    local nodes=$(jq -r '.inbounds[] | "\(.tag) | \(.type)"' "$CONFIG_FILE" | nl)
    
    if [[ -z "$nodes" ]]; then
        echo -e "${RED}未检测到有效的 Inbound 节点。${PLAIN}"
        exit 1
    fi

    echo -e "============================================"
    echo "$nodes"
    echo -e "============================================"
    echo -e "${YELLOW}提示: 输入序号选择节点，支持多选 (例如: 1 3)${PLAIN}"
    read -p "请选择: " selection
    
    if [[ -z "$selection" || "$selection" == "0" ]]; then exit 0; fi

    target_tags=()
    for num in $selection; do
        local tag=$(echo "$nodes" | sed -n "${num}p" | awk -F'|' '{print $1}' | awk '{print $2}')
        if [[ -n "$tag" ]]; then target_tags+=("$tag"); fi
    done

    if [[ ${#target_tags[@]} -eq 0 ]]; then
        echo -e "${RED}无效的选择。${PLAIN}"; exit 1
    fi
    echo -e "${GREEN}已选择节点: ${target_tags[*]}${PLAIN}"
}

# 5. 应用策略
apply_strategy() {
    if ! jq -e '.endpoints[]? | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null 2>&1; then
        if [[ -f "$CRED_FILE" ]]; then
            echo -e "${YELLOW}检测到凭证，正在配置 WARP...${PLAIN}"
            write_warp_endpoint || return 1
        else
            echo -e "${YELLOW}需先配置 WARP...${PLAIN}"
            manual_warp_input || return 1
            write_warp_endpoint || return 1
        fi
    fi

    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}请选择流量转发策略:${PLAIN}"
    echo -e " 1. IPv6走直连 + IPv4走WARP (默认 - 推荐)"
    echo -e " 2. 双栈全部走WARP (隐藏 IP / 全解锁)"
    read -p "输入选项 (1 或 2，默认1): " strategy_select
    strategy_select=${strategy_select:-1}

    cp "$CONFIG_FILE" "$BACKUP_FILE"
    local tmp_json=$(mktemp)
    
    local v6_target="direct"
    if [[ "$strategy_select" == "2" ]]; then
        v6_target="WARP"
        echo -e "${GREEN}模式: 双栈 WARP${PLAIN}"
    else
        local found_direct=$(jq -r '.outbounds[] | select(.type == "direct") | .tag' "$CONFIG_FILE" | head -n 1)
        [[ -n "$found_direct" ]] && v6_target="$found_direct"
        echo -e "${GREEN}模式: IPv6 直连 + IPv4 WARP${PLAIN}"
    fi
    
    local tags_arg=$(printf '%s\n' "${target_tags[@]}" | jq -R . | jq -s .)

    # 原生路由: 直接指向 WARP Endpoint
    local rule_v6=$(jq -n --argjson tags "$tags_arg" --arg dt "$v6_target" '{
        "inbound": $tags, "ip_cidr": ["::/0"], "outbound": $dt
    }')
    local rule_v4=$(jq -n --argjson tags "$tags_arg" '{
        "inbound": $tags, "ip_cidr": ["0.0.0.0/0"], "outbound": "WARP"
    }')

    jq --argjson r1 "$rule_v6" --argjson r2 "$rule_v4" --argjson tags "$tags_arg" '
        # 语法合规性修正: TUN 接口不支持 domain_strategy，必须过滤
        (.inbounds[] | select(.tag as $t | $tags | index($t)) | select(.type != "tun")).domain_strategy = "prefer_ipv6" |

        .route.rules |= map(
            select(type == "object") |
            select(
                (has("inbound") | not) or
                (.inbound | type == "array" and (inside($tags) | not)) or
                (.inbound | type == "string" and ([.inbound] | inside($tags) | not))
            )
        ) |

        .route.rules = [$r1, $r2] + .route.rules
    ' "$CONFIG_FILE" > "$tmp_json" && mv "$tmp_json" "$CONFIG_FILE"

    restart_service
}

# 6. 卸载策略
uninstall_policy() {
    echo -e "${YELLOW}正在移除相关分流规则...${PLAIN}"
    get_target_nodes
    
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    local tmp_json=$(mktemp)
    local tags_json=$(printf '%s\n' "${target_tags[@]}" | jq -R . | jq -s .)
    
    jq --argjson targets "$tags_json" '
        (.inbounds[] | select(.tag as $t | $targets | index($t))).domain_strategy = null |
        .route.rules |= map(
            select(type == "object") |
            select(
                (has("inbound") | not) or
                (.inbound | type == "array" and (inside($targets) | not)) or
                (.inbound | type == "string" and ([.inbound] | inside($targets) | not))
            )
        )
    ' "$CONFIG_FILE" > "$tmp_json" && mv "$tmp_json" "$CONFIG_FILE"
    
    echo
    read -p "是否同时删除 WARP Endpoint？(y/N): " del_warp
    if [[ "$del_warp" == "y" || "$del_warp" == "Y" ]]; then
        local tmp2=$(mktemp)
        jq 'del(.endpoints[]? | select(.tag == "WARP"))' "$CONFIG_FILE" > "$tmp2" && mv "$tmp2" "$CONFIG_FILE"
        jq 'del(.outbounds[]? | select(.tag == "WARP"))' "$CONFIG_FILE" > "$tmp2" && mv "$tmp2" "$CONFIG_FILE"
        echo -e "${GREEN}WARP Endpoint 已删除。${PLAIN}"
        
        read -p "是否同时删除 WARP 凭证文件？(y/N): " del_cred
        if [[ "$del_cred" == "y" || "$del_cred" == "Y" ]]; then
            rm -f "$CRED_FILE"
            echo -e "${GREEN}WARP 凭证文件已删除。${PLAIN}"
        fi
    fi

    restart_service
}

# 7. 重启服务
restart_service() {
    echo -e "${YELLOW}正在验证配置并重启服务...${PLAIN}"
    if command -v sing-box &> /dev/null; then
        if ! sing-box check -c "$CONFIG_FILE"; then
             echo -e "${RED}配置语法校验失败！正在回滚...${PLAIN}"
             [[ -f "$BACKUP_FILE" ]] && cp "$BACKUP_FILE" "$CONFIG_FILE"
             return 1
        fi
    fi

    if systemctl list-unit-files | grep -q sing-box; then
        systemctl restart sing-box
    else
        pkill -xf "sing-box run -c $CONFIG_FILE"
        sleep 1
        nohup sing-box run -c "$CONFIG_FILE" > /dev/null 2>&1 &
    fi

    sleep 1.5
    if systemctl is-active --quiet sing-box || pgrep -x "sing-box" >/dev/null; then
        echo -e "${GREEN}策略应用成功！${PLAIN}"
    else
        echo -e "${RED}重启失败，请检查日志。${PLAIN}"
    fi
}

# --- 主菜单 ---
# --- 主菜单 ---
show_menu() {
    check_env
    while true; do
        clear
        local st="${RED}未配置${PLAIN}"
        local has_cred=false
        
        [[ -f "$CRED_FILE" ]] && grep -q "PRIV_KEY" "$CRED_FILE" && has_cred=true
        
        if jq -e '.endpoints[]? | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null 2>&1; then
            st="${GREEN}已配置（WARP 运行中）${PLAIN}"
        elif $has_cred; then
            st="${YELLOW}凭证已保存（未启用 WARP）${PLAIN}"
        fi

        local mode_hint=""
        if jq -e '.endpoints[]? | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null 2>&1; then
            if jq -e '.route.rules[] | select(.ip_cidr == ["::/0"] and .outbound != "WARP")' "$CONFIG_FILE" >/dev/null 2>&1; then
                mode_hint="当前模式: IPv6优先直连 + IPv4兜底WARP"
            else
                mode_hint="当前模式: 双栈全部走WARP"
            fi
        fi

        echo -e "============================================"
        echo -e " Sing-box 分流策略管理器 (v4.6 Native Pure)"
        echo -e "--------------------------------------------"
        echo -e " 当前状态: [$st]"
        [[ -n "$mode_hint" ]] && echo -e " $mode_hint"
        echo -e " 1. 添加分流策略 (自动注入/清洗规则)"
        echo -e " 2. 卸载分流策略"
        echo -e " 3. 手动配置/更新 WARP 凭证"
        echo -e " 0. 退出"
        echo -e "============================================"
        read -p "请选择: " choice

        case "$choice" in
            1) get_target_nodes; apply_strategy; read -p "回车继续..." ;;
            2) uninstall_policy; read -p "回车继续..." ;;
            3) manual_warp_input; echo -e "${GREEN}凭证已更新。${PLAIN}"; read -p "回车继续..." ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

show_menu