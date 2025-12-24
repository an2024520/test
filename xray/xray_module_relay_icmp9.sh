#!/bin/bash

# ============================================================
#  ICMP9 中转扩展模块 (Commander v4.3 Strict Pure)
#  - 架构: VLESS (入站) -> Routing -> VMess (出站)
#  - 适配: 严格 IP 检测 + DNS 自愈
#  - 纯净: 无代理干扰
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
BACKUP_FILE="/usr/local/etc/xray/config.json.bak"
API_CONFIG="https://api.icmp9.com/config/config.txt"
API_NODES="https://api.icmp9.com/online.php"

# ============================================================
# 1. 环境自适应检测 (严格模式)
# ============================================================
check_env_and_dns() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 运行${PLAIN}" && exit 1
    
    echo -e "${YELLOW}正在检测网络环境...${PLAIN}"
    local is_ipv6_only=false
    
    # 严格模式检测 IPv4
    local ipv4_check=$(curl -4 -s -m 5 http://ip.sb 2>/dev/null)
    
    if [[ "$ipv4_check" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${GREEN}>>> 检测到有效 IPv4 环境。${PLAIN}"
    else
        is_ipv6_only=true
        echo -e "${SKYBLUE}>>> 检测到 IPv6-Only 环境 (StrictMode)${PLAIN}"
    fi

    # 验证 DNS 是否正常 (尝试解析 Google)
    if ! curl -s --connect-timeout 3 https://www.google.com >/dev/null 2>&1; then
        echo -e "${YELLOW}>>> 网络连接异常，正在尝试修复系统 DNS...${PLAIN}"
        chattr -i /etc/resolv.conf >/dev/null 2>&1
        echo -e "nameserver 2001:4860:4860::8888\nnameserver 2606:4700:4700::1111" > /etc/resolv.conf
        chattr +i /etc/resolv.conf >/dev/null 2>&1
        echo -e "${GREEN}>>> DNS 修复完成。${PLAIN}"
    fi
    
    export IS_IPV6_ONLY=$is_ipv6_only
}

# ============================================================
# 2. 交互配置 (Argo 适配)
# ============================================================
get_user_input() {
    echo -e "----------------------------------------------------"
    echo -e "${SKYBLUE}配置 ICMP9 中转参数${PLAIN}"
    while true; do
        read -p "请输入 ICMP9 授权 KEY (UUID): " REMOTE_UUID
        if [[ -n "$REMOTE_UUID" ]]; then break; fi
    done
    read -p "请输入 VPS 内部监听端口 (默认 10086): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-10086}

    echo -e "\n${SKYBLUE}配置 Argo 隧道信息 (用于生成链接)${PLAIN}"
    read -p "请输入 Argo 隧道域名 (如 tunnel.abc.com): " ARGO_DOMAIN
    read -p "客户端显示地址 (优选IP/域名, 默认同上): " SHOW_ADDR
    SHOW_ADDR=${SHOW_ADDR:-$ARGO_DOMAIN}
    LOCAL_UUID=$(/usr/local/bin/xray_core/xray uuid)
}

# ============================================================
# 3. 核心配置注入
# ============================================================
inject_config() {
    echo -e "${YELLOW}正在获取远端配置与节点列表...${PLAIN}"
    NODES_JSON=$(curl -s "$API_NODES")
    COUNTRY_CODES=$(echo "$NODES_JSON" | jq -r '.countries[]? | .code')
    if [[ -z "$COUNTRY_CODES" ]]; then
        echo -e "${RED}错误: 无法获取节点列表，请检查网络或 KEY。${PLAIN}"
        exit 1
    fi

    RAW_CFG=$(curl -s "$API_CONFIG")
    R_HOST=$(echo "$RAW_CFG" | grep "^host|" | cut -d'|' -f2 | tr -d '\r\n')
    R_PORT=$(echo "$RAW_CFG" | grep "^port|" | cut -d'|' -f2 | tr -d '\r\n')
    R_WSHOST=$(echo "$RAW_CFG" | grep "^wshost|" | cut -d'|' -f2 | tr -d '\r\n')
    R_TLS="none"; [[ $(echo "$RAW_CFG" | grep "^tls|" | cut -d'|' -f2) == "1" ]] && R_TLS="tls"

    cp "$CONFIG_FILE" "$BACKUP_FILE"

    jq '
      .inbounds |= map(select(.tag | startswith("icmp9-") | not)) |
      .outbounds |= map(select(.tag | startswith("icmp9-") | not)) |
      .routing.rules |= map(select(.outboundTag | startswith("icmp9-") | not))
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    if [[ "$IS_IPV6_ONLY" == "true" ]]; then
        echo -e "${YELLOW}>>> 为 Xray 注入 IPv6 优先 DNS 策略...${PLAIN}"
        jq '.dns = {
            "servers": [
                "2001:4860:4860::8888",
                "2606:4700:4700::1111",
                "localhost"
            ],
            "queryStrategy": "UseIPv6"
        }' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi

    jq --arg port "$LOCAL_PORT" --arg uuid "$LOCAL_UUID" '.inbounds += [{
      "tag": "icmp9-vless-in",
      "port": ($port | tonumber),
      "protocol": "vless",
      "settings": { "clients": [{"id": $uuid}], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/" } }
    }]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    echo -e "${YELLOW}正在生成路由规则...${PLAIN}"
    echo "[]" > /tmp/icmp9_outs.json
    echo "[]" > /tmp/icmp9_rules.json

    for code in $COUNTRY_CODES; do
        jq --arg tag "icmp9-out-$code" --arg host "$R_HOST" --arg port "$R_PORT" \
           --arg uuid "$REMOTE_UUID" --arg wshost "$R_WSHOST" --arg tls "$R_TLS" --arg path "/$code" \
           '. + [{
              "tag": $tag, "protocol": "vmess",
              "settings": { "vnext": [{"address": $host, "port": ($port | tonumber), "users": [{"id": $uuid}]}] },
              "streamSettings": { "network": "ws", "security": $tls, 
                "tlsSettings": (if $tls == "tls" then {"serverName": $wshost} else null end),
                "wsSettings": { "path": $path, "headers": {"Host": $wshost} } }
           }]' /tmp/icmp9_outs.json > /tmp/icmp9_outs.json.tmp && mv /tmp/icmp9_outs.json.tmp /tmp/icmp9_outs.json

        jq --arg tag "icmp9-out-$code" --arg path "/relay/$code" \
           '. + [{ "type": "field", "inboundTag": ["icmp9-vless-in"], "outboundTag": $tag, "path": [$path] }]' \
           /tmp/icmp9_rules.json > /tmp/icmp9_rules.json.tmp && mv /tmp/icmp9_rules.json.tmp /tmp/icmp9_rules.json
    done

    jq --slurpfile new_outs /tmp/icmp9_outs.json '.outbounds += $new_outs[0]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    jq --slurpfile new_rules /tmp/icmp9_rules.json '.routing.rules = ($new_rules[0] + .routing.rules)' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    rm -f /tmp/icmp9_outs.json /tmp/icmp9_rules.json
}

finish_setup() {
    echo -e "${YELLOW}重启 Xray 服务...${PLAIN}"
    systemctl restart xray
    sleep 2
    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}错误: Xray 启动失败，正在回滚配置...${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        systemctl restart xray
        exit 1
    fi
    echo -e "\n${GREEN}>>> 部署成功！以下是您的 VLESS 中转链接:${PLAIN}"
    echo -e "${GRAY}(已适配 Cloudflare Tunnel, 请确保 Argo 指向本地端口: $LOCAL_PORT)${PLAIN}\n"
    echo "$NODES_JSON" | jq -c '.countries[]?' | while read -r node; do
        CODE=$(echo "$node" | jq -r '.code')
        NAME=$(echo "$node" | jq -r '.name')
        EMOJI=$(echo "$node" | jq -r '.emoji')
        LINK="vless://${LOCAL_UUID}@${SHOW_ADDR}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=/relay/${CODE}#${EMOJI}${NAME}_中转"
        LINK=${LINK// /%20}
        echo -e "${SKYBLUE}${LINK}${PLAIN}"
    done
}

check_env_and_dns
get_user_input
inject_config
finish_setup
