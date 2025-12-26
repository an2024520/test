#!/bin/bash

# ============================================================
#  Xray WARP IPv4 分流补丁 (Patch for Specific Node IPv4-Only)
#  - 功能: 为指定节点配置 "IPv4走WARP，IPv6走直连" 策略
#  - 前提: 请先运行主脚本配置好 WARP 凭证和出站 (warp-out)
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
        echo -e "${YELLOW}请先运行主 WARP 脚本完成初始化！${PLAIN}"
        exit 1
    fi
    
    # 检查是否存在 warp-out 出站
    if ! jq -e '.outbounds[] | select(.tag == "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}错误: 配置文件中未找到 'warp-out' 出站对象。${PLAIN}"
        echo -e "${YELLOW}请先运行主 WARP 脚本选择 '模式一' 或任意模式以生成基础配置。${PLAIN}"
        exit 1
    fi
}

inject_rule() {
    echo -e "${YELLOW}正在读取节点列表...${PLAIN}"
    # 提取所有入站节点 Tag (排除 api)
    local node_list=$(jq -r '.inbounds[] | "\(.tag) | \(.protocol)"' "$CONFIG_FILE" | grep -v "api" | nl)
    
    if [[ -z "$node_list" ]]; then 
        echo -e "${RED}没有找到有效的入站节点。${PLAIN}"; return 1
    fi
    
    echo -e "------------------------------------------------"
    echo "$node_list"
    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}请选择要进行 [IPv4分流] 的节点序号 (例如: 1)${PLAIN}"
    read -p "输入序号: " selection
    
    # 获取选中的 Tag
    local target_tag=$(echo "$node_list" | sed -n "${selection}p" | awk -F'|' '{print $1}' | awk '{print $2}')
    
    if [[ -z "$target_tag" ]]; then
        echo -e "${RED}选择无效。${PLAIN}"; return 1
    fi
    
    echo -e "${GREEN}选中节点 Tag: ${target_tag}${PLAIN}"
    echo -e "${YELLOW}正在注入 IPv4 分流规则...${PLAIN}"
    
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    
    # 1. 构造专用规则: 仅匹配 IPv4 (0.0.0.0/0) 且来源是该节点 -> warp-out
    local split_rule=$(jq -n --arg t "$target_tag" '{ 
        "type": "field", 
        "inboundTag": [$t], 
        "ip": ["0.0.0.0/0"], 
        "outboundTag": "warp-out" 
    }')
    
    # 2. 将规则插入到 routing.rules 的最前面 (优先级最高)
    jq --argjson r "$split_rule" '.routing.rules = [$r] + .routing.rules' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}规则注入成功！${PLAIN}"
        echo -e "${GRAY}逻辑: 节点[$target_tag] -> IPv4流量 -> WARP${PLAIN}"
        echo -e "${GRAY}逻辑: 节点[$target_tag] -> IPv6流量 -> 默认直连${PLAIN}"
        
        systemctl restart xray
        echo -e "${GREEN}Xray 服务已重启。${PLAIN}"
    else
        echo -e "${RED}写入配置失败，已还原。${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
    fi
}

# 执行
check_env
inject_rule
