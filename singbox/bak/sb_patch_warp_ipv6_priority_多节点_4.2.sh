#!/bin/bash
echo "v4.2"
sleep 2
# ============================================================
#  Sing-box 分流策略管理器 (v4.2 Ultimate Fix)
#  - 核心功能: 实现 "原生IPv6优先直连，IPv4兜底WARP" 或 "双栈WARP接管"
#  - 支持多节点输入
#  - 核心修复: 彻底解决 Anti-loop 规则重复插入问题
#  - 核心修复: 解决多次应用策略导致的规则堆积问题 (先清洗后注入)
#  - 增强: 优化 Reserved 字段的 JSON 容错解析
#  - 新增: 扩展 Anti-loop 规则域名 (cdn.cloudflare.net, workers.dev)
#  - 新增: 卸载时可选删除 WARP Endpoint
#  - 新增: 菜单状态旁显示当前分流模式提示
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

    # === 修复: 更强的 Reserved 容错处理 ===
    # 移除所有空格，确保纯净
    local clean_res="${res_input// /}"
    local res_json="[0,0,0]"
    
    if [[ "$clean_res" =~ ^\[([0-9]+,){2}[0-9]+\]$ ]]; then
        # 已经是标准格式 [1,2,3]
        res_json="$clean_res"
    elif [[ "$clean_res" =~ ^([0-9]+,){2}[0-9]+$ ]]; then
        # 是 CSV 格式 1,2,3 -> 转为 [1,2,3]
        res_json="[$clean_res]"
    elif [[ "$clean_res" =~ ^\[.*\]$ ]]; then
        # 其他带括号的尝试直接保留
        res_json="$clean_res"
    fi

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

# 3. 自动注入 WARP Endpoint (含幂等性修复)
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
    
    # 删除旧 WARP Endpoint 并注入新的
    jq 'del(.endpoints[]? | select(.tag == "WARP"))' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    jq --argjson ep "$endpoint_json" '.endpoints += [$ep]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    # === 修复: Anti-loop 规则幂等性 (先删后加) ===
    # 1. 删除所有包含 engage.cloudflareclient.com 的规则，防止无限堆积
    jq '
        .route.rules |= map(
            select(
                (.domain // empty) as $d | 
                $d | inside(["engage.cloudflareclient.com","cloudflare.com","www.cloudflare.com","cdn.cloudflare.net","workers.dev"]) | not
            )
        )
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    
    # 2. 重新注入扩展后的 Anti-loop 规则
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

    echo -e "${GREEN}WARP Endpoint 已注入（含 anti-loop 规则）。${PLAIN}"
}

# ...（中间所有函数保持完全原样，未做任何改动）...

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
    
    # === 新增：询问是否同时删除 WARP Endpoint ===
    echo
    read -p "是否同时删除 WARP Endpoint？(y/N): " del_warp
    if [[ "$del_warp" == "y" || "$del_warp" == "Y" ]]; then
        local tmp2=$(mktemp)
        jq 'del(.endpoints[]? | select(.tag == "WARP"))' "$CONFIG_FILE" > "$tmp2" && mv "$tmp2" "$CONFIG_FILE"
        echo -e "${GREEN}WARP Endpoint 已删除。${PLAIN}"
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

    # === 新增：检测当前分流模式并显示提示 ===
    local mode_hint=""
    if jq -e '.endpoints[]? | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null 2>&1; then
        # 检查是否有仅 IPv4 走 WARP 的规则（即存在 ::/0 → direct）
        if jq -e '.route.rules[] | select(.ip_cidr == ["::/0"] and .outbound != "WARP")' "$CONFIG_FILE" >/dev/null 2>&1; then
            mode_hint="当前模式: IPv6优先直连 + IPv4兜底WARP"
        else
            mode_hint="当前模式: 双栈全部走WARP"
        fi
    fi

    echo -e "============================================"
    echo -e " Sing-box 分流策略管理器 (v4.2 Ultimate Fix)"
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