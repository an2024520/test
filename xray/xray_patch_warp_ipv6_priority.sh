#!/bin/bash
#警告：下面两行只能修改版本号，其他不要动
echo "v5.3 IPV6绝对优先（两种模式：原生IPV6优先和WARP IP6优先）+ ICMP9修复"
sleep 2

# ===== 兼容 bash <(curl ...) 或 source 方式运行 =====
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    _pipeline_compat_main() {
        # 为了 source 模式下的变量隔离，将逻辑包裹
        # 下方是完整的脚本逻辑，请直接复制使用
        :
    }
    echo -e "\033[31m[提示] 建议直接运行脚本文件，Source 模式仅供调试。\033[0m"
    # 如果必须支持 source，请手动取消下方包裹或直接保存文件运行
fi


# ============================================================
#  Xray IPv6 优先 + WARP 兜底补丁 (v5.3 Final Logic)
#  - 修复: 去除 Python 依赖，使用 od/base64 原生解析 Reserved
#  - 修复: 凭证文件读取/写入双向兼容 (WARP_XXX & XXX)
#  - 修复: ICMP9 路由优先级算法重构 (Split & Merge)
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

# ==================== [核心] 智能 Reserved 解析 (无Python版) ====================
smart_parse_reserved() {
    local input="$1"
    # 1. 如果已经是标准的 "123,45,67" 格式，直接返回
    if [[ "$input" =~ ^[0-9]+,[0-9]+,[0-9]+$ ]]; then
        echo "$input"
        return
    fi
    
    # 2. 尝试 Base64 解码 (针对 Client ID)
    # 逻辑: echo -> base64 decode -> od 转十进制(1字节无符号) -> 取前3个 -> tr换行符转逗号 -> sed修剪
    local decoded=""
    if command -v od &>/dev/null; then
        decoded=$(echo -n "$input" | base64 -d 2>/dev/null | od -t u1 -An -N 3 | tr -s ' ' ',' | sed 's/^,//;s/,$//')
    fi
    
    # 3. 验证解码结果
    if [[ "$decoded" =~ ^[0-9]+,[0-9]+,[0-9]+$ ]]; then
        echo "$decoded"
    else
        # 4. 失败回退 (防止报错导致 WARP 启动失败)
        echo "0,0,0"
    fi
}

# ==================== WARP 凭证 (兼容版) ====================
manual_warp_input() {
    local def_key="" def_v4="" def_v6="" def_res=""
    
    # [Fix] 兼容读取：尝试读取两种格式的变量
    if [[ -f "$CRED_FILE" ]]; then
        source "$CRED_FILE" 2>/dev/null
        # 优先取 WARP_ 前缀，没有则取旧版
        def_key="${WARP_PRIV_KEY:-$PRIV_KEY}"
        def_v4="${WARP_IPV4:-$V4_ADDR}"
        def_v6="${WARP_IPV6:-$V6_ADDR}"
        def_res="${WARP_RESERVED:-$RESERVED}"
    fi

    echo -e "${SKYBLUE}=== WARP 配置 (兼容模式) ===${PLAIN}"
    echo -e "${YELLOW}提示：Reserved 支持输入 Base64 ClientID 或 数字格式${PLAIN}"
    
    read -p "私钥 [默认: ${def_key:0:10}...]: " priv_key
    priv_key=${priv_key:-$def_key}
    [[ -z "$priv_key" ]] && return 1

    read -p "IPv4 [默认: ${def_v4:-172.16.0.2/32}]: " v4
    v4=${v4:-"${def_v4:-172.16.0.2/32}"}

    read -p "IPv6 [默认: ${def_v6}]: " v6
    v6=${v6:-$def_v6}
    [[ -z "$v6" ]] && return 1

    local default_res_show="${def_res:-0,0,0}"
    read -p "Reserved [默认: $default_res_show]: " res_input
    res_input=${res_input:-"$default_res_show"}

    # [Fix] 调用无 Python 的智能解析器
    local clean_res=$(smart_parse_reserved "$res_input")
    echo -e "✅ Reserved 解析结果: [${clean_res}]"

    mkdir -p "$(dirname "$CRED_FILE")"
    
    # [Fix] 兼容保存：同时写入两种格式，防止其他脚本读不到
    cat > "$CRED_FILE" <<EOF
# Xray/Sing-box WARP Credentials
WARP_PRIV_KEY="$priv_key"
WARP_IPV4="$v4"
WARP_IPV6="$v6"
WARP_RESERVED="$clean_res"
# Legacy Compatibility
PRIV_KEY="$priv_key"
V4_ADDR="$v4"
V6_ADDR="$v6"
RESERVED="$clean_res"
EOF
    echo -e "${GREEN}WARP 凭证已保存。${PLAIN}"
}

# ==================== 注入 warp-out + anti-loop ====================
inject_warp_outbound() {
    source "$CRED_FILE" 2>/dev/null
    # [Fix] 读取变量时再次做兼容检查
    local key="${WARP_PRIV_KEY:-$PRIV_KEY}"
    local v4="${WARP_IPV4:-$V4_ADDR}"
    local v6="${WARP_IPV6:-$V6_ADDR}"
    local res_str="${WARP_RESERVED:-$RESERVED}"

    [[ -z "$key" ]] && echo -e "${RED}错误: 凭证无效 (Key为空)，请重新配置。${PLAIN}" && return 1

    # 标准化 CIDR
    [[ ! "$v4" =~ "/" && -n "$v4" ]] && v4="${v4}/32"
    [[ ! "$v6" =~ "/" ]] && v6="${v6}/128"

    local addr="[\"$v6\""
    [[ -n "$v4" ]] && addr="$addr,\"$v4\""
    addr="$addr]"
    
    # Reserved 数组化
    local res="[${res_str}]"

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

    # 幂等注入：先删旧的，再加新的
    jq 'del(.outbounds[] | select(.tag == "warp-out"))' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    jq --argjson w "$warp_json" '.outbounds += [$w]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    # Anti-loop 清理与注入
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
    # 检查 warp-out 是否存在，不存在则引导配置
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

    # 1. 强制 IPIfNonMatch
    jq 'if .routing.domainStrategy? == null or .routing.domainStrategy == "AsIs" then .routing.domainStrategy = "IPIfNonMatch" else . end' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    # 2. 靶向清洗 (避免重复规则)
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

    # 3. 注入双层 IP 规则
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

# ==================== ICMP9 修复补丁 (Split-Merge) ====================
repair_icmp9_priority() {
    echo -e "${YELLOW}正在修复 ICMP9 优先级冲突 (Split-Merge Algorithm)...${PLAIN}"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
         echo -e "${RED}未找到配置文件。${PLAIN}"; return 1
    fi

    cp "$CONFIG_FILE" "${CONFIG_FILE}.icmp9_fix.bak"
    local tmp=$(mktemp)
    
    # [Fix] 使用分离-合并算法：
    # 提取含 user 的规则 + 提取不含 user 的规则 -> 重新拼接
    if jq '
        .routing.rules = (
            (.routing.rules | map(select(has("user")))) + 
            (.routing.rules | map(select(has("user") | not)))
        )
    ' "$CONFIG_FILE" > "$tmp"; then
        mv "$tmp" "$CONFIG_FILE"
        systemctl restart xray
        echo -e "${GREEN}修复完成！ICMP9 规则已强制置顶。${PLAIN}"
    else
        echo -e "${RED}JSON 处理失败，已回滚。${PLAIN}"
        cp "${CONFIG_FILE}.icmp9_fix.bak" "$CONFIG_FILE"
    fi
}

# ==================== 菜单 ====================
while true; do
    clear
    st="${RED}未配置${PLAIN}"
    has_cred=false
    # [Fix] 菜单状态检查也支持兼容模式
    if [[ -f "$CRED_FILE" ]]; then
        if grep -q "WARP_PRIV_KEY" "$CRED_FILE" 2>/dev/null || grep -q "PRIV_KEY" "$CRED_FILE" 2>/dev/null; then
            has_cred=true
        fi
    fi

    if jq -e '.outbounds[] | select(.tag == "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
        st="${GREEN}WARP 运行中${PLAIN}"
    elif $has_cred; then
        st="${YELLOW}凭证已存${PLAIN}"
    fi

    mode_hint=""
    if jq -e '.outbounds[] | select(.tag == "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
        if jq -e '.routing.rules[] | select(.ip == ["::/0"] and .outboundTag != "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
            mode_hint="当前模式: 原生IPv6直连 + IPv4 WARP兜底"
        else
            mode_hint="当前模式: 双栈走WARP (强制IPv6优先解析)"
        fi
    fi

    echo -e "============================================"
    echo -e " Xray IPv6 优先 + WARP 兜底补丁 (v5.3 Final)"
    echo -e " 当前状态: [$st]"
    [[ -n "$mode_hint" ]] && echo -e " $mode_hint"
    echo -e "--------------------------------------------"
    echo -e " 1. 应用分流策略 (Fix: 凭证兼容)"
    echo -e " 2. 卸载分流策略"
    echo -e " 3. 手动配置 WARP (Fix: 智能解析)"
    echo -e " 4. 修复 ICMP9 优先级 (Fix: 强力置顶)"
    echo -e " 0. 退出"
    echo -e "============================================"
    read -p "选: " c
    case "$c" in
        1) inject_rule; read -p "..." ;;
        2) uninstall_policy; read -p "..." ;;
        3) manual_warp_input; read -p "..." ;;
        4) repair_icmp9_priority; read -p "..." ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效${PLAIN}"; sleep 1 ;;
    esac
done