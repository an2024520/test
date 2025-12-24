#!/bin/bash

# ============================================================
#  ICMP9 中转扩展模块 (Commander v4.1 Adaptive)
#  - 架构: VLESS (入站) -> Routing -> VMess (出站)
#  - 适配: 自动识别 IPv4/IPv6 双栈或单栈环境
#  - 依赖: 需配合 Argo 隧道使用
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 核心路径与 API
CONFIG_FILE="/usr/local/etc/xray/config.json"
BACKUP_FILE="/usr/local/etc/xray/config.json.bak"
API_CONFIG="https://api.icmp9.com/config/config.txt"
API_NODES="https://api.icmp9.com/online.php"

# ============================================================
# 1. 环境自适应检测
# ============================================================
check_env_and_dns() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 运行${PLAIN}" && exit 1
    
    echo -e "${YELLOW}正在检测网络环境...${PLAIN}"
    local is_ipv6_only=false
    
    # 简单的连通性测试
    if ! curl -4 -s --connect-timeout 2 https://1.1.1.1 >/dev/null 2>&1; then
        is_ipv6_only=true
        echo -e "${SKYBLUE}>>> 检测到 IPv6-Only 环境${PLAIN}"
    else
        echo -e "${GREEN}>>> 检测到 IPv4/双栈环境${PLAIN}"
    fi

    # 验证 DNS 是否正常 (尝试解析 Google)
    if ! curl -s --connect-timeout 3 https://www.google.com >/dev/null 2>&1; then
        echo -e "${YELLOW}>>> 网络连接异常，正在尝试修复系统 DNS...${PLAIN}"
        # 既然 menu.sh 已经切为 Google DNS，这里做兜底修复
        chattr -i /etc/resolv.conf >/dev/null 2>&1
        echo -e "nameserver 2001:4860:4860::8888\nnameserver 2606:4700:4700::1111" > /etc/resolv.conf
        chattr +i /etc/resolv.conf >/dev/null 2>&1
        echo -e "${GREEN}>>> DNS 修复完成。${PLAIN}"
    fi
    
    # 导出环境变量供后续使用
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
    
    # 智能默认值：如果用户不填显示地址，默认用 Argo 域名
    read -p "客户端显示地址 (优选IP/域名, 默认同上): " SHOW_ADDR
    SHOW_ADDR=${SHOW_ADDR:-$ARGO_DOMAIN}
    
    LOCAL_UUID=$(/usr/local/bin/xray_core/xray uuid)
}

# ============================================================
# 3. 核心配置注入
# ============================================================
inject_config() {
    echo -e "${YELLOW}正在获取远端配置与节点列表...${PLAIN}"
    
    # 获取节点列表
    NODES_JSON=$(curl -s "$API_NODES")
    COUNTRY_CODES=$(echo "$NODES_JSON" | jq -r '.countries[]? | .code')
    
    if [[ -z "$COUNTRY_CODES" ]]; then
        echo -e "${RED}错误: 无法获取节点列表，请检查网络或 KEY。${PLAIN}"
        exit 1
    fi

    # 获取连接元数据
    RAW_CFG=$(curl -s "$API_CONFIG")
    R_HOST=$(echo "$RAW_CFG" | grep "^host|" | cut -d'|' -f2 | tr -d '\r\n')
    R_PORT=$(echo "$RAW_CFG" | grep "^port|" | cut -d'|' -f2 | tr -d '\r\n')
    R_WSHOST=$(echo "$RAW_CFG" | grep "^wshost|" | cut -d'|' -f2 | tr -d '\r\n')
    R_TLS="none"; [[ $(echo "$RAW_CFG" | grep "^tls|" | cut -d'|' -f2) == "1" ]] && R_TLS="tls"

    # 备份
    cp "$CONFIG_FILE" "$BACKUP_FILE"

    # --- A. 清理旧数据 ---
    jq '
      .inbounds |= map(select(.tag | startswith("icmp9-") | not)) |
      .outbounds |= map(select(.tag | startswith("icmp9-") | not)) |
      .routing.rules |= map(select(.outboundTag | startswith("icmp9-") | not))
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # --- B. 注入 DNS (双重保险) ---
    # 如果是 IPv6-Only 环境，强制 Xray 内部使用 IPv6 DNS 策略
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

    # --- C. 注入 VLESS Inbound ---
    # decryption="none" 是给 256MB 小鸡的性能优化关键
    jq --arg port "$LOCAL_PORT" --arg uuid "$LOCAL_UUID" '.inbounds += [{
      "tag": "icmp9-vless-in",
      "port": ($port | tonumber),
      "protocol": "vless",
      "settings": { "clients": [{"id": $uuid}], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/" } }
    }]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # --- D. 批量注入 Outbounds & Rules ---
    echo -e "${YELLOW}正在生成路由规则...${PLAIN}"
    
    # 预创建临时文件以提高 jq 写入效率
    echo "[]" > /tmp/icmp9_outs.json
    echo "[]" > /tmp/icmp9_rules.json

    for code in $COUNTRY_CODES; do
        # Outbound: VMess + WS + TLS
        jq --arg tag "icmp9-out-$code" --arg host "$R_HOST" --arg port "$R_PORT" \
           --arg uuid "$REMOTE_UUID" --arg wshost "$R_WSHOST" --arg tls "$R_TLS" --arg path "/$code" \
           '. + [{
              "tag": $tag, "protocol": "vmess",
              "settings": { "vnext": [{"address": $host, "port": ($port | tonumber), "users": [{"id": $uuid}]}] },
              "streamSettings": { "network": "ws", "security": $tls, 
                "tlsSettings": (if $tls == "tls" then {"serverName": $wshost} else null end),
                "wsSettings": { "path": $path, "headers": {"Host": $wshost} } }
           }]' /tmp/icmp9_outs.json > /tmp/icmp9_outs.json.tmp && mv /tmp/icmp9_outs.json.tmp /tmp/icmp9_outs.json

        # Rule: 路径分流
        jq --arg tag "icmp9-out-$code" --arg path "/relay/$code" \
           '. + [{ "type": "field", "inboundTag": ["icmp9-vless-in"], "outboundTag": $tag, "path": [$path] }]' \
           /tmp/icmp9_rules.json > /tmp/icmp9_rules.json.tmp && mv /tmp/icmp9_rules.json.tmp /tmp/icmp9_rules.json
    done

    # 合并 JSON
    jq --slurpfile new_outs /tmp/icmp9_outs.json '.outbounds += $new_outs[0]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    jq --slurpfile new_rules /tmp/icmp9_rules.json '.routing.rules = ($new_rules[0] + .routing.rules)' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    rm -f /tmp/icmp9_outs.json /tmp/icmp9_rules.json
}

# ============================================================
# 4. 重启与链接输出
# ============================================================
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
        
        # 标准 VLESS 链接生成
        LINK="vless://${LOCAL_UUID}@${SHOW_ADDR}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=/relay/${CODE}#${EMOJI}${NAME}_中转"
        # 简单处理空格
        LINK=${LINK// /%20}
        
        echo -e "${SKYBLUE}${LINK}${PLAIN}"
    done
}

# 执行流程
check_env_and_dns
get_user_input
inject_config
finish_setup
