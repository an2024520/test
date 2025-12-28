#!/bin/bash
# ============================================================
#  Sing-box WARP IPv6 优先分流补丁 (v3.6 Final - Fixed)
#  - 核心修复: 增加 sing-box check 配置验证与回滚
#  - 核心修复: 增加 Systemd/Pkill 双模重启兼容 (Docker友好)
#  - 功能: 多节点选择、自动清理旧规则、IPv6直连/IPv4走WARP
#  - 修复: 卸载策略时 jq 处理 null inbound 的报错
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

# 2. 增强型重启逻辑 (验证+兼容)
restart_service() {
    echo -e "${YELLOW}正在验证配置并重启服务...${PLAIN}"
    
    # 语法检查
    if command -v sing-box &> /dev/null; then
        if ! sing-box check -c "$CONFIG_FILE"; then
             echo -e "${RED}配置语法校验失败！正在回滚...${PLAIN}"
             [[ -f "$BACKUP_FILE" ]] && cp "$BACKUP_FILE" "$CONFIG_FILE"
             return 1
        fi
    fi

    # 双模重启 (Systemd / Pkill)
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

# 3. 获取目标节点
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
    echo -e "${SKYBLUE}请输入节点序号 (支持多选，空格分隔):${PLAIN}"
    echo -e "${GRAY}输入 0 或直接回车退出${PLAIN}"
    read -p "请选择: " selection
    
    if [[ -z "$selection" || "$selection" == "0" ]]; then
        echo -e "${YELLOW}操作取消。${PLAIN}"
        exit 0
    fi

    target_tags=()
    for num in $selection; do
        local tag=$(echo "$nodes" | sed -n "${num}p" | awk -F'|' '{print $1}' | awk '{print $2}')
        if [[ -n "$tag" ]]; then
            target_tags+=("$tag")
            echo -e "${GREEN}已选择节点: $num $tag${PLAIN}"
        else
            echo -e "${YELLOW}序号 $num 无效，已忽略。${PLAIN}"
        fi
    done

    if [[ ${#target_tags[@]} -eq 0 ]]; then
        echo -e "${RED}未选择任何有效节点，操作取消。${PLAIN}"
        exit 0
    fi
}

# 4. 应用 IPv6 优先策略
apply_ipv6_priority() {
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    local tmp_json=$(mktemp)

    # 智能识别 direct 出站
    local v6_outbound_target="direct"
    if jq -e '.outbounds[] | select(.tag == "direct")' "$CONFIG_FILE" >/dev/null 2>&1; then
        local found_direct=$(jq -r '.outbounds[] | select(.tag == "direct") | .tag' "$CONFIG_FILE" | head -n 1)
        [[ -n "$found_direct" ]] && v6_outbound_target="$found_direct"
    fi
    
    # 构造 JSON 数组供 jq 使用
    local tags_arg=$(printf '%s\n' "${target_tags[@]}" | jq -R . | jq -s .)

    # 1. 规则: 选定节点的 IPv6 流量 -> Direct
    local rule_v6=$(jq -n --argjson tags "$tags_arg" --arg dt "$v6_outbound_target" '{
        "inbound": $tags,
        "ip_cidr": ["::/0"],
        "outbound": $dt
    }')
    
    # 2. 规则: 选定节点的 IPv4 流量 -> WARP
    local rule_v4=$(jq -n --argjson tags "$tags_arg" '{
        "inbound": $tags,
        "ip_cidr": ["0.0.0.0/0"],
        "outbound": "WARP"
    }')

    echo -e "${YELLOW}正在写入分流规则 (IPv6->${v6_outbound_target}, IPv4->WARP)...${PLAIN}"

    # 单次 jq 操作：设置 domain_strategy + 置顶两条规则
    jq --argjson r1 "$rule_v6" --argjson r2 "$rule_v4" --argjson tags "$tags_arg" '
        (.inbounds[]? | select(.tag as $t | $tags | index($t))).domain_strategy = "prefer_ipv6" |
        .route.rules = [$r1, $r2] + .route.rules
    ' "$CONFIG_FILE" > "$tmp_json" && mv "$tmp_json" "$CONFIG_FILE"

    restart_service
}

# 5. 卸载策略（修复 null inbound 报错）
uninstall_policy() {
    echo -e "${YELLOW}正在移除相关分流规则...${PLAIN}"
    get_target_nodes
    
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    local tmp_json=$(mktemp)
    
    local tags_json=$(printf '%s\n' "${target_tags[@]}" | jq -R . | jq -s .)
    
    # 修复版：安全处理 inbound 为 null/字符串/数组
    jq --argjson targets "$tags_json" '
        # 重置 domain_strategy
        (.inbounds[]? | select(.tag as $t | $targets | index($t))).domain_strategy = null |

        # 清理路由规则：安全处理 inbound 为 null/字符串/数组
        .route.rules |= map(select(
            if .inbound == null then true
            elif (.inbound | type) == "string" then ($targets | contains([.inbound]) | not)
            elif (.inbound | type) == "array" then ($targets | any(in .inbound) | not)
            else true
            end
        ))
    ' "$CONFIG_FILE" > "$tmp_json" && mv "$tmp_json" "$CONFIG_FILE"
    
    restart_service
}

# --- 菜单 ---
check_env
echo -e "============================================"
echo -e " Sing-box IPv6 优先 + WARP 分流助手 (v3.6 Final)"
echo -e "--------------------------------------------"
echo -e " 1. 为节点添加 [IPv6优先 + WARP分流] 策略"
echo -e " 2. 卸载节点的策略"
echo -e " 0. 退出"
echo -e "============================================"
read -p "请选择: " choice

case "$choice" in
    1)
        get_target_nodes
        apply_ipv6_priority
        ;;
    2)
        uninstall_policy
        ;;
    *)
        exit 0
        ;;
esac