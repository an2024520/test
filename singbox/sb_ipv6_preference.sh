#!/bin/bash
# ============================================================
#  Sing-box IPv6 优先策略管理器 (v1.1 Strict DNS)
#  - 核心功能: 修改 DNS 解析策略 (Strategy)
#  - 适配版本: Sing-box v1.12+ (DNS Module Refactor)
#  - 作用域: Global (全局) / Specific Inbound (指定入站)
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

# 获取所有入站 Tag 的函数 (独立实现，不依赖外部脚本)
get_inbound_tags() {
    jq -r '.inbounds[].tag' "$CONFIG_FILE"
}

show_status() {
    echo -e "${YELLOW}正在读取当前 DNS 策略...${PLAIN}"
    local global_st=$(jq -r '.dns.strategy // "默认(Default)"' "$CONFIG_FILE")
    # 提取所有设置了 prefer_ipv6 的规则涉及的 inbound
    local rules_st=$(jq -r '.dns.rules[]? | select(.strategy == "prefer_ipv6") | .inbound[]?' "$CONFIG_FILE" 2>/dev/null | sort | uniq | tr '\n' ',' | sed 's/,$//')
    
    echo -e "----------------------------------------"
    echo -e " 全局策略: ${SKYBLUE}${global_st}${PLAIN}"
    if [[ -n "$rules_st" ]]; then
        echo -e " 节点优先规则: ${GREEN}[$rules_st]${PLAIN}"
    else
        echo -e " 节点优先规则: ${PLAIN}无${PLAIN}"
    fi
    echo -e "----------------------------------------"
}

clean_ipv6_policy() {
    local quiet=$1
    [[ -z "$quiet" ]] && echo -e "${YELLOW}正在清理旧的 IPv6 优先策略...${PLAIN}"
    
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    local tmp=$(mktemp)
    
    # 1. 删除全局 strategy (如果是 prefer_ipv6)
    # 2. 删除 dns.rules 中所有 strategy 为 prefer_ipv6 的规则
    jq '
        (if .dns.strategy == "prefer_ipv6" then del(.dns.strategy) else . end) | 
        (.dns.rules |= map(select(.strategy != "prefer_ipv6")))
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

set_global_ipv6() {
    echo -e "${GREEN}正在设置全局 IPv6 优先...${PLAIN}"
    clean_ipv6_policy "quiet" # 先清理，避免规则冲突
    
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
    
    # 将 tags 转为数组
    mapfile -t tag_array <<< "$tags_raw"
    
    echo -e "请选择要应用 IPv6 优先的入站节点 (支持多选，用逗号分隔，如 1,3):"
    local i=1
    for t in "${tag_array[@]}"; do
        echo -e " ${GREEN}$i.${PLAIN} $t"
        let i++
    done
    
    read -p "请输入序号: " selection
    if [[ -z "$selection" ]]; then echo -e "${RED}未选择。${PLAIN}"; return; fi
    
    # 解析选择的序号
    local selected_tags_json="[]"
    IFS=',' read -ra ADDR <<< "$selection"
    local target_tags=()
    
    for idx in "${ADDR[@]}"; do
        if [[ "$idx" =~ ^[0-9]+$ ]]; then
            local real_idx=$((idx-1))
            local t="${tag_array[$real_idx]}"
            if [[ -n "$t" ]]; then
                target_tags+=("$t")
            fi
        fi
    done
    
    if [[ ${#target_tags[@]} -eq 0 ]]; then
        echo -e "${RED}无效的选择。${PLAIN}"; return
    fi
    
    echo -e "${YELLOW}即将为以下节点启用 IPv6 优先: ${GREEN}${target_tags[*]}${PLAIN}"
    
    # 构造 JSON 数组字符串
    local json_array=$(printf '%s\n' "${target_tags[@]}" | jq -R . | jq -s .)
    
    # 清理旧策略 (避免规则重复堆叠)
    clean_ipv6_policy "quiet"
    
    local tmp=$(mktemp)
    # 注入新规则到 dns.rules 顶部
    jq --argjson tags "$json_array" '
        if .dns.rules == null then .dns.rules = [] else . end |
        .dns.rules = ([{"inbound": $tags, "strategy": "prefer_ipv6"}] + .dns.rules)
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    
    echo -e "${GREEN}规则已注入。重启服务生效...${PLAIN}"
    systemctl restart sing-box
    show_status
}

uninstall_policy() {
    echo -e "${RED}警告: 这将移除所有强制 IPv6 优先的 DNS 设定。${PLAIN}"
    read -p "确认执行? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    
    clean_ipv6_policy
    
    echo -e "${GREEN}所有 IPv6 优先策略已彻底清除。重启服务生效...${PLAIN}"
    systemctl restart sing-box
    show_status
}

check_jq
clear
echo -e "${GREEN}Sing-box IPv6 优先策略管理 (DNS Strategy)${PLAIN}"
show_status
echo -e "1. 设置 ${SKYBLUE}全局${PLAIN} IPv6 优先 (强制所有流量)"
echo -e "2. 设置 ${SKYBLUE}指定节点${PLAIN} IPv6 优先 (仅针对特定入站)"
echo -e "3. ${RED}一键卸载/清洗策略${PLAIN} (恢复默认)"
echo -e "0. 退出"
read -p "请选择: " choice

case "$choice" in
    1) set_global_ipv6 ;;
    2) set_node_ipv6 ;;
    3) uninstall_policy ;;
    0) exit 0 ;;
    *) echo "无效输入" ;;
esac