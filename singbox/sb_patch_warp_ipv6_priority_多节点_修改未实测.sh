#!/bin/bash
echo "v1"
sleep 5
# ============================================================
#  Sing-box 分流策略管理器 (v3.8 BugFix)
#  - 核心功能: 实现 "IPv6优先直连，IPv4兜底WARP" 或 "双栈WARP接管"
#  - 自动化: 自动将选中节点的 domain_strategy 修改为 prefer_ipv6
#  - 修复: 节点选择时包含序号的 Bug
#  - 修复: 遇到损坏的规则时 jq 报错退出的问题
#  - 核心: Systemd/Pkill 双模兼容 + 自动回滚
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

# 1. 基础检查
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

# 2. 增强型重启逻辑
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
        echo -e "${GREEN}Sing-box 服务重启成功，策略已生效。${PLAIN}"
    else
        echo -e "${RED}服务重启失败或未运行，请检查日志。${PLAIN}"
    fi
}

# 3. 获取目标节点 (修复 Awk 提取逻辑)
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
        # [Fix] 使用 $2 准确获取 Tag，避免包含序号 $1
        local tag=$(echo "$nodes" | sed -n "${num}p" | awk -F'|' '{print $1}' | awk '{print $2}')
        if [[ -n "$tag" ]]; then target_tags+=("$tag"); fi
    done

    if [[ ${#target_tags[@]} -eq 0 ]]; then
        echo -e "${RED}无效的选择。${PLAIN}"; exit 1
    fi
    echo -e "${GREEN}已选择节点: ${target_tags[*]}${PLAIN}"
}

# 4. 应用策略
apply_strategy() {
    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}请选择流量转发策略:${PLAIN}"
    echo -e " 1. IPv6走直连 + IPv4走WARP (默认 - 保留原生IPv6性能)"
    echo -e " 2. 双栈全部走WARP (IPV6优先/隐藏真实IP / 全解锁)"
    read -p "输入选项 (1 或 2，默认1): " strategy_select
    strategy_select=${strategy_select:-1}

    cp "$CONFIG_FILE" "$BACKUP_FILE"
    local tmp_json=$(mktemp)
    
    local v6_target="direct"
    if [[ "$strategy_select" == "2" ]]; then
        v6_target="WARP"
        echo -e "${GREEN}模式: 双栈 WARP 接管${PLAIN}"
    else
        if ! jq -e '.outbounds[] | select(.tag == "direct")' "$CONFIG_FILE" >/dev/null 2>&1; then
            local found_direct=$(jq -r '.outbounds[] | select(.type == "direct") | .tag' "$CONFIG_FILE" | head -n 1)
            [[ -n "$found_direct" ]] && v6_target="$found_direct"
        fi
        echo -e "${GREEN}模式: IPv6 直连 + IPv4 WARP${PLAIN}"
    fi
    
    local tags_arg=$(printf '%s\n' "${target_tags[@]}" | jq -R . | jq -s .)

    # 构造规则
    local rule_v6=$(jq -n --argjson tags "$tags_arg" --arg dt "$v6_target" '{
        "inbound": $tags, "ip_cidr": ["::/0"], "outbound": $dt
    }')
    local rule_v4=$(jq -n --argjson tags "$tags_arg" '{
        "inbound": $tags, "ip_cidr": ["0.0.0.0/0"], "outbound": "WARP"
    }')

    echo -e "${YELLOW}正在注入规则并修改 domain_strategy...${PLAIN}"

    # [Fix] 增加 map(select(type=="object")) 过滤坏数据
    jq --argjson r1 "$rule_v6" --argjson r2 "$rule_v4" --argjson tags "$tags_arg" '
        (.inbounds[] | select(.tag as $t | $tags | index($t))).domain_strategy = "prefer_ipv6" |
        .route.rules |= map(select(type == "object")) | 
        .route.rules = [$r1, $r2] + .route.rules
    ' "$CONFIG_FILE" > "$tmp_json" && mv "$tmp_json" "$CONFIG_FILE"

    restart_service
}

# 5. 卸载策略 (修复 JQ 报错)
uninstall_policy() {
    echo -e "${YELLOW}正在移除相关分流规则...${PLAIN}"
    get_target_nodes
    
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    local tmp_json=$(mktemp)
    local tags_json=$(printf '%s\n' "${target_tags[@]}" | jq -R . | jq -s .)
    
    # [Fix] 增加 select(type == "object") 防止 "Cannot index array" 错误
    jq --argjson targets "$tags_json" '
        (.inbounds[] | select(.tag as $t | $targets | index($t))).domain_strategy = null |
        .route.rules |= map(
            select(type == "object") |
            select(
                (.inbound | type == "array" and (.inbound | inside($targets) | not)) or
                (.inbound | type == "string" and ([.inbound] | inside($targets) | not)) or
                (.inbound == null)
            )
        )
    ' "$CONFIG_FILE" > "$tmp_json" && mv "$tmp_json" "$CONFIG_FILE"
    
    restart_service
}

# --- 菜单 ---
check_env
echo -e "============================================"
echo -e " Sing-box 分流策略管理器 (v3.8 BugFix)"
echo -e "--------------------------------------------"
echo -e " 1. 添加分流策略 (支持多模式)"
echo -e " 2. 卸载分流策略"
echo -e " 0. 退出"
echo -e "============================================"
read -p "请选择: " choice

case "$choice" in
    1) get_target_nodes; apply_strategy ;;
    2) uninstall_policy ;;
    *) exit 0 ;;
esac
