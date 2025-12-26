#!/bin/bash

# ============================================================
#  Xray WARP IPv4 分流补丁 (v2.0 双栈优化版)
#  - 功能: 为指定节点配置 "IPv6优先直连，IPv4兜底WARP" 策略
#  - 逻辑: 利用规则顺序，防止双栈网站(如Google)被误判走WARP
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
BACKUP_FILE="${CONFIG_FILE}.patch.bak"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

check_env() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 未找到配置文件 $CONFIG_FILE${PLAIN}"
        exit 1
    fi
    # 检查是否存在 warp-out
    if ! jq -e '.outbounds[] | select(.tag == "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}错误: 未找到 'warp-out' 出站。请先运行主脚本配置 WARP。${PLAIN}"
        exit 1
    fi
}

inject_rule() {
    echo -e "${YELLOW}正在读取节点列表...${PLAIN}"
    # 获取直连的出站 Tag (通常是 direct 或 freedom)
    local direct_tag="direct"
    if ! jq -e '.outbounds[] | select(.tag == "direct")' "$CONFIG_FILE" >/dev/null 2>&1; then
        if jq -e '.outbounds[] | select(.tag == "freedom")' "$CONFIG_FILE" >/dev/null 2>&1; then
            direct_tag="freedom"
        fi
    fi
    echo -e "${GREEN}检测到直连出站 Tag: ${direct_tag}${PLAIN}"

    local node_list=$(jq -r '.inbounds[] | "\(.tag) | \(.protocol)"' "$CONFIG_FILE" | grep -v "api" | nl)
    if [[ -z "$node_list" ]]; then echo -e "${RED}无有效入站节点。${PLAIN}"; return 1; fi
    
    echo -e "------------------------------------------------"
    echo "$node_list"
    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}请选择要进行 [智能分流] 的节点序号${PLAIN}"
    read -p "输入序号: " selection
    
    local target_tag=$(echo "$node_list" | sed -n "${selection}p" | awk -F'|' '{print $1}' | awk '{print $2}')
    if [[ -z "$target_tag" ]]; then echo -e "${RED}选择无效。${PLAIN}"; return 1; fi
    
    echo -e "${GREEN}选中节点: ${target_tag}${PLAIN}"
    echo -e "${YELLOW}正在注入 IPv6优先+IPv4兜底 规则...${PLAIN}"
    
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    
    # === 关键逻辑 ===
    # 规则1: 有 IPv6 (::/0) -> 直连 (Direct)
    local rule_v6=$(jq -n --arg t "$target_tag" --arg dt "$direct_tag" '{ 
        "type": "field", "inboundTag": [$t], "ip": ["::/0"], "outboundTag": $dt 
    }')
    
    # 规则2: 仅 IPv4 (0.0.0.0/0) -> WARP
    local rule_v4=$(jq -n --arg t "$target_tag" '{ 
        "type": "field", "inboundTag": [$t], "ip": ["0.0.0.0/0"], "outboundTag": "warp-out" 
    }')
    
    # 将这两条规则按顺序 (v6在前, v4在后) 插入到路由表最顶端
    jq --argjson r1 "$rule_v6" --argjson r2 "$rule_v4" \
       '.routing.rules = [$r1, $r2] + .routing.rules' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
       && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}规则注入成功！${PLAIN}"
        echo -e "优先级 1: 节点[$target_tag] -> 包含IPv6 -> 直连 ($direct_tag)"
        echo -e "优先级 2: 节点[$target_tag] -> 仅有IPv4 -> WARP (warp-out)"
        systemctl restart xray
        echo -e "${GREEN}Xray 服务已重启，策略已生效。${PLAIN}"
    else
        echo -e "${RED}配置失败，已还原。${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
    fi
}

check_env
inject_rule
