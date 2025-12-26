#!/bin/bash
echo "支持多节点版本-暂未实测"
# ============================================================
#  Xray IPv6 优先 + WARP 兜底补丁 (v2.1 Multi-Select)
#  - 适用场景: IPv6 VPS 需要访问 IPv4 网站，但又不想牺牲 IPv6 直连速度
#  - 升级: 支持输入多个序号 (空格分隔)，一次性为多个节点打补丁
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
BACKUP_FILE="${CONFIG_FILE}.ipv6_patch.bak"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

check_env() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 未找到 Xray 配置文件。${PLAIN}"; exit 1
    fi
    if ! jq -e '.outbounds[] | select(.tag == "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}错误: 未找到 'warp-out' 出站。${PLAIN}"
        echo -e "${YELLOW}提示: 请先运行主 WARP 脚本完成基础配置。${PLAIN}"
        exit 1
    fi
}

inject_rule() {
    echo -e "${YELLOW}读取节点列表...${PLAIN}"
    # 智能识别直连 Tag
    local direct_tag="direct"
    if ! jq -e '.outbounds[] | select(.tag == "direct")' "$CONFIG_FILE" >/dev/null 2>&1; then
        if jq -e '.outbounds[] | select(.tag == "freedom")' "$CONFIG_FILE" >/dev/null 2>&1; then direct_tag="freedom"; fi
    fi

    # 列出入站节点
    local node_list=$(jq -r '.inbounds[] | "\(.tag) | \(.protocol)"' "$CONFIG_FILE" | grep -v "api" | nl)
    if [[ -z "$node_list" ]]; then echo -e "${RED}无有效入站节点。${PLAIN}"; return 1; fi
    
    echo -e "------------------------------------------------"
    echo "$node_list"
    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}请选择要开启 [IPv6优先+IPv4兜底] 的节点序号${PLAIN}"
    echo -e "${GRAY}(支持多选，用空格分隔，例如: 1 3)${PLAIN}"
    read -p "输入序号: " selection
    
    # === 核心升级: 循环处理多选 ===
    local tags_list=()
    for num in $selection; do
        # 提取对应序号的 Tag
        local tag=$(echo "$node_list" | sed -n "${num}p" | awk -F'|' '{print $1}' | awk '{print $2}')
        if [[ -n "$tag" ]]; then
            tags_list+=("$tag")
            echo -e "已选中: ${GREEN}${tag}${PLAIN}"
        fi
    done
    
    if [[ ${#tags_list[@]} -eq 0 ]]; then
        echo -e "${RED}未选中任何有效节点。${PLAIN}"; return 1
    fi
    
    # 将 bash 数组转换为 json 数组格式 ["tag1", "tag2"]
    local tags_json=$(printf '%s\n' "${tags_list[@]}" | jq -R . | jq -s .)

    echo -e "${YELLOW}正在注入聚合规则...${PLAIN}"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    
    # 构造聚合规则 (inboundTag 是一个列表)
    # 1. 选中节点的 IPv6 -> Direct
    local rule_v6=$(jq -n --argjson t "$tags_json" --arg dt "$direct_tag" '{ 
        "type": "field", "inboundTag": $t, "ip": ["::/0"], "outboundTag": $dt 
    }')
    # 2. 选中节点的 IPv4 -> WARP
    local rule_v4=$(jq -n --argjson t "$tags_json" '{ 
        "type": "field", "inboundTag": $t, "ip": ["0.0.0.0/0"], "outboundTag": "warp-out" 
    }')
    
    # 插入到路由表顶部
    jq --argjson r1 "$rule_v6" --argjson r2 "$rule_v4" \
       '.routing.rules = [$r1, $r2] + .routing.rules' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
       && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    if systemctl restart xray; then
        echo -e "${GREEN}补丁应用成功！${PLAIN}"
        echo -e "策略已生效: 选中的 ${#tags_list[@]} 个节点已启用双栈分流策略。"
    else
        echo -e "${RED}重启失败，配置已回滚。${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        systemctl restart xray
    fi
}

check_env
inject_rule
