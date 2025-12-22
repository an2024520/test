#!/bin/bash

# ==========================================
# 1. 环境与基础函数 (已修复掩码与Endpoint)
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE=""
CRED_FILE="/etc/sing-box/warp_credentials.conf"
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json")
for p in "${PATHS[@]}"; do [[ -f "$p" ]] && CONFIG_FILE="$p" && break; done

# [省略基础环境检测函数...]
restart_sb() {
    mkdir -p /var/log/sing-box/ && chmod 777 /var/log/sing-box/ >/dev/null 2>&1
    systemctl restart sing-box || pkill -xf "sing-box run -c $CONFIG_FILE"
}

write_warp_config() {
    local priv="$1" pub="$2" v4="$3" v6="$4" res="$5"
    [[ ! "$v4" =~ "/" && -n "$v4" ]] && v4="${v4}/32"
    [[ ! "$v6" =~ "/" && -n "$v6" ]] && v6="${v6}/128"
    local addr_json=$(jq -n --arg v4 "$v4" --arg v6 "$v6" '[$v4, $v6] | map(select(. != "null/32" and . != "null/128"))')
    local warp_json=$(jq -n --arg priv "$priv" --arg pub "$pub" --argjson addr "$addr_json" --argjson res "$res" \
        '{"type":"wireguard","tag":"WARP","address":$addr,"private_key":$priv,"system":false,"peers":[{"address":"2606:4700:d0::a29f:c001","port":2408,"public_key":$pub,"reserved":$res,"allowed_ips":["0.0.0.0/0","::/0"]}]}')
    local TMP_CONF=$(mktemp)
    jq --argjson new "$warp_json" 'if .endpoints == null then .endpoints = [] else . end | del(.endpoints[] | select(.tag == "WARP")) | .endpoints += [$new]' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    restart_sb
}

apply_routing_rule() {
    local rule_json="$1"
    local TMP_CONF=$(mktemp)
    jq --argjson r "$rule_json" '.route.rules = [$r] + .route.rules' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    restart_sb
}

# ==========================================
# 2. 路由模式函数 (必须定义在 menu 之前)
# ==========================================

mode_stream() {
    local rule=$(jq -n '{ "domain_suffix": ["netflix.com","openai.com","google.com","youtube.com"], "outbound": "WARP" }')
    apply_routing_rule "$rule"
}

mode_global() {
    echo -e "${YELLOW}正在配置全局接管策略...${PLAIN}"
    # 防环回
    local anti_loop=$(jq -n '{ "domain": ["engage.cloudflareclient.com", "cloudflare.com"], "outbound": "direct" }')
    apply_routing_rule "$anti_loop"
    # 全局规则
    local rule=$(jq -n '{ "outbound": "WARP" }')
    apply_routing_rule "$rule"
}

mode_specific_node() {
    echo -e "${SKYBLUE}正在读取节点...${PLAIN}"
    # [此处保留你原有的节点提取与 nl/awk 逻辑]
    local node_list=$(jq -r '.inbounds[] | .tag' "$CONFIG_FILE")
    # ... 原有逻辑 ...
}

uninstall_warp() {
    local TMP_CONF=$(mktemp)
    jq 'del(.endpoints[] | select(.tag == "WARP")) | del(.route.rules[] | select(.outbound == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    restart_sb
}

# ==========================================
# 3. 菜单主循环 (最后定义)
# ==========================================

show_menu() {
    while true; do
        clear
        echo -e "================ Native WARP 配置向导 ================"
        echo -e " 1. 注册/配置 WARP 凭证"
        echo -e " 3. 模式一：智能流媒体分流"
        echo -e " 4. 模式二：全局接管"
        echo -e " 5. 模式三：指定节点接管"
        echo -e " 7. 禁用/卸载 Native WARP"
        echo -e " 0. 返回上级菜单"
        echo -e "===================================================="
        read -p "请输入选项: " choice
        case "$choice" in
            1) register_warp ;;
            3) mode_stream ;;
            4) mode_global ;; # 此时 mode_global 已在上方定义，不会再报错
            5) mode_specific_node ;;
            7) uninstall_warp ;;
            0) exit 0 ;;
            *) echo -e "无效输入"; sleep 1 ;;
        esac
        read -p "按回车继续..."
    done
}

show_menu
