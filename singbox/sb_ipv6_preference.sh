#!/bin/bash
# ============================================================
#  Sing-box IPv6 优先策略管理器 (v1.2 Inbound Injection Fix)
#  - 修复: 解决 v1.12+ DNS Rule 必须包含 server 字段导致的启动失败
#  - 变更: 指定节点模式改为直接修改 Inbound 对象的 domain_strategy
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
    echo -e "${RED}错误: 未找到 Sing-box 配置文件。${PLAIN}"
    exit 1
fi

check_jq() {
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}错误: 需要安装 jq (apt install jq)${PLAIN}"
        exit 1
    fi
}

get_inbound_tags() {
    jq -r '.inbounds[].tag' "$CONFIG_FILE"
}

show_status() {
    echo -e "${YELLOW}正在读取当前 IPv6 策略...${PLAIN}"
    # 1. 检查全局 DNS 策略
    local global_st=$(jq -r '.dns.strategy // "默认(Default)"' "$CONFIG_FILE")
    
    # 2. 检查 Inbound 级别的策略 (修复后逻辑)
    local inbound_st=$(jq -r '.inbounds[] | select(.domain_strategy == "prefer_ipv6") | .tag' "$CONFIG_FILE" 2>/dev/null | sort | uniq | tr '\n' ',' | sed 's/,$//')
    
    # 3. 检查残留的坏规则 (DNS Rules)
    local broken_rules=$(jq -r '.dns.rules[]? | select(.strategy == "prefer_ipv6" and .server == null) | "存在"' "$CONFIG_FILE" 2>/dev/null | head -n 1)

    echo -e "----------------------------------------"
    echo -e " 全局策略: ${SKYBLUE}${global_st}${PLAIN}"
    if [[ -n "$inbound_st" ]]; then
        echo -e " 节点强制(Inbound): ${GREEN}[$inbound_st]${PLAIN}"
    else
        echo -e " 节点强制(Inbound): ${PLAIN}无${PLAIN}"
    fi
    
    if [[ -n "$broken_rules" ]]; then
         echo -e " ${RED}⚠️ 检测到错误的 DNS 规则，建议立即执行卸载清理！${PLAIN}"
    fi
    echo -e "----------------------------------------"
}

# 核心清理函数：同时移除 全局策略、Inbound策略 和 错误的DNS规则
clean_ipv6_policy() {
    local quiet=$1
    [[ -z "$quiet" ]] && echo -e "${YELLOW}正在清理旧策略与修复错误...${PLAIN}"
    
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    local tmp=$(mktemp)
    
    jq '
        # 1. 清除全局策略
        (if .dns.strategy == "prefer_ipv6" then del(.dns.strategy) else . end) | 
        
        # 2. 清除 Inbound 中的 domain_strategy
        (.inbounds |= map(if .domain_strategy == "prefer_ipv6" then del(.domain_strategy) else . end)) |
        
        # 3. [关键修复] 移除导致报错的 DNS 规则 (即没有 server 字段但有 strategy 的规则)
        (.dns.rules |= map(select( .strategy != "prefer_ipv6" )))
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

set_global_ipv6() {
    echo -e "${GREEN}正在设置全局 IPv6 优先...${PLAIN}"
    clean_ipv6_policy "quiet" # 清理旧配置
    
    local tmp=$(mktemp)
    jq '.dns.strategy = "prefer_ipv6"' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    
    echo -e "${GREEN}设置完成！重启服务生效...${PLAIN}"
    systemctl restart sing-box
    show_status
}

set_node_ipv6() {
    echo -e "${GREEN}正在获取入站节点列表...${PLAIN}"
    local tags_raw=$(get_inbound_tags)
    
    if [[ -z "$tags_raw" ]]; then
        echo -e "${RED}未找到任何入站节点。${PLAIN}"; return
    fi
    
    mapfile -t tag_array <<< "$tags_raw"
    
    echo -e "请选择要应用 IPv6 优先的入站节点 (支持多选，用逗号分隔，如 1,3):"
    local i=1
    for t in "${tag_array[@]}"; do
        echo -e " ${GREEN}$i.${PLAIN} $t"
        let i++
    done
    
    read -p "请输入序号: " selection
    if [[ -z "$selection" ]]; then echo -e "${RED}未选择。${PLAIN}"; return; fi
    
    # 解析选择
    local target_tags=()
    IFS=',' read -ra ADDR <<< "$selection"
    for idx in "${ADDR[@]}"; do
        if [[ "$idx" =~ ^[0-9]+$ ]]; then
            local real_idx=$((idx-1))
            local t="${tag_array[$real_idx]}"
            [[ -n "$t" ]] && target_tags+=("$t")
        fi
    done
    
    if [[ ${#target_tags[@]} -eq 0 ]]; then
        echo -e "${RED}无效的选择。${PLAIN}"; return
    fi
    
    echo -e "${YELLOW}即将为以下节点启用 IPv6 优先: ${GREEN}${target_tags[*]}${PLAIN}"
    
    # 清理旧策略
    clean_ipv6_policy "quiet"
    
    local tmp=$(mktemp)
    
    # 将 target_tags 数组传递给 jq
    local json_array=$(printf '%s\n' "${target_tags[@]}" | jq -R . | jq -s .)
    
    # 使用 reduce 遍历选中的 tag，并修改对应的 inbound
    jq --argjson tags "$json_array" '
        .inbounds |= map(
            if (.tag as $t | $tags | index($t)) then
                .domain_strategy = "prefer_ipv6"
            else
                .
            end
        )
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    
    echo -e "${GREEN}Inbound 策略已注入。重启服务生效...${PLAIN}"
    systemctl restart sing-box
    show_status
}

uninstall_policy() {
    echo -e "${RED}警告: 这将移除所有强制 IPv6 优先的设定 (包括全局和节点)。${PLAIN}"
    read -p "确认执行? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    
    clean_ipv6_policy
    
    echo -e "${GREEN}策略已清洗并修复。重启服务生效...${PLAIN}"
    systemctl restart sing-box
    show_status
}

check_jq
clear
echo -e "${GREEN}Sing-box IPv6 优先策略管理 (v1.2 Fix)${PLAIN}"
show_status
echo -e "1. 设置 ${SKYBLUE}全局${PLAIN} IPv6 优先 (DNS Strategy)"
echo -e "2. 设置 ${SKYBLUE}指定节点${PLAIN} IPv6 优先 (Inbound Strategy)"
echo -e "3. ${RED}一键修复/卸载${PLAIN} (解决 missing server field 报错)"
echo -e "0. 退出"
read -p "请选择: " choice

case "$choice" in
    1) set_global_ipv6 ;;
    2) set_node_ipv6 ;;
    3) uninstall_policy ;;
    0) exit 0 ;;
    *) echo "无效输入" ;;
esac