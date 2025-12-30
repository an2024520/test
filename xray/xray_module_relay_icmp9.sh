#!/bin/bash

# ============================================================
#  ICMP9 中转扩展模块 (v3.92 Syntax-Fix Edition)
#  - 架构: 端口锚定 -> 协议自适应 -> 增量注入
#  - 修复: 修复 v3.9 中 VMess 链接生成时的引号闭合错误
#  - 核心: 依赖 IP 白名单直连 Cloudflare
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

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# ============================================================
# 1. 环境检测
# ============================================================
check_env() {
    if ! command -v jq &> /dev/null; then apt-get install -y jq; fi
    
    echo -e "${YELLOW}>>> [自检] 正在扫描本地节点...${PLAIN}"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 未找到 Xray 配置文件${PLAIN}"; exit 1
    fi

    if [[ "$AUTO_SETUP" == "true" ]] && [[ -n "$ICMP9_PORT" ]]; then
        LOCAL_PORT="$ICMP9_PORT"
    else
        read -p "请输入端口 (默认 8080): " input_port
        LOCAL_PORT=${input_port:-8080}
    fi

    # 1. 锚定节点索引
    TARGET_INDEX=$(jq -r --argjson p "$LOCAL_PORT" '.inbounds | to_entries | map(select(.value.port == $p)) | .[0].key' "$CONFIG_FILE")
    if [[ -z "$TARGET_INDEX" || "$TARGET_INDEX" == "null" ]]; then
        echo -e "${RED}错误: 未找到端口 $LOCAL_PORT${PLAIN}"; exit 1
    fi

    # 2. 获取协议和路径 (使用更安全的引号写法)
    LOCAL_PROTO=$(jq -r ".inbounds[$TARGET_INDEX].protocol" "$CONFIG_FILE")
    # 注意：这里使用单引号包裹 jq 过滤器，避免 bash 转义问题
    LOCAL_PATH=$(jq -r ".inbounds[$TARGET_INDEX].streamSettings.wsSettings.path // \"/\"" "$CONFIG_FILE")
    
    echo -e "${GREEN}>>> 锁定端口: $LOCAL_PORT ($LOCAL_PROTO)${PLAIN}"
    echo -e "${GREEN}>>> 锁定路径: $LOCAL_PATH${PLAIN}"
    
    # 检测纯 IPv6 提示
    if ! curl -4 -s -m 2 http://ip.sb >/dev/null; then
        echo -e "${SKYBLUE}>>> 检测到纯 IPv6 环境 (将使用 CF IPv6 通道)${PLAIN}"
    fi
}

get_user_input() {
    if [[ "$AUTO_SETUP" != "true" ]]; then
        read -p "请输入 ICMP9 KEY: " REMOTE_UUID
        read -p "请输入 Argo 域名: " ARGO_DOMAIN
    else
        REMOTE_UUID="$ICMP9_KEY"
    fi
    [[ -z "$REMOTE_UUID" || -z "$ARGO_DOMAIN" ]] && exit 1
}

# ============================================================
# 2. 注入配置 (标准逻辑)
# ============================================================
inject_config() {
    echo -e "${YELLOW}>>> [配置] 生成配置...${PLAIN}"
    
    NODES_JSON=$(curl -s "$API_NODES")
    RAW_CFG=$(curl -s "$API_CONFIG")
    
    R_WSHOST=$(echo "$RAW_CFG" | grep "^wshost|" | cut -d'|' -f2 | tr -d '\r\n')
    R_PORT=$(echo "$RAW_CFG" | grep "^port|" | cut -d'|' -f2 | tr -d '\r\n')
    R_TLS="none"; [[ $(echo "$RAW_CFG" | grep "^tls|" | cut -d'|' -f2) == "1" ]] && R_TLS="tls"

    # 直连 wshost (CF IPv6)
    FINAL_ADDR="$R_WSHOST"

    cp "$CONFIG_FILE" "$BACKUP_FILE"

    # 清理旧配置
    jq '
      .outbounds |= map(select(.tag | startswith("icmp9-") | not)) |
      .routing.rules |= map(select(.outboundTag | startswith("icmp9-") | not))
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    if [[ "$LOCAL_PROTO" == "vmess" ]]; then USER_FIELD="users"; else USER_FIELD="clients"; fi
    EXISTING_USERS=$(jq -c ".inbounds[$TARGET_INDEX].settings.${USER_FIELD}[0:1]" "$CONFIG_FILE")
    
    echo "[]" > /tmp/new_outbounds.json
    echo "[]" > /tmp/new_rules.json
    echo "$EXISTING_USERS" > /tmp/new_users.json

    echo "$NODES_JSON" | jq -c '.countries[]?' | while read -r node; do
        CODE=$(echo "$node" | jq -r '.code')
        NEW_UUID=$(/usr/local/bin/xray_core/xray uuid)
        
        # 用户
        jq --arg uuid "$NEW_UUID" --arg email "icmp9-${CODE}" '. + [{"id": $uuid, "email": $email}]' \
           /tmp/new_users.json > /tmp/new_users.json.tmp && mv /tmp/new_users.json.tmp /tmp/new_users.json

        # 出站配置
        jq -n \
           --arg tag "icmp9-out-${CODE}" \
           --arg addr "$FINAL_ADDR" \
           --arg sni "$R_WSHOST" \
           --arg port "$R_PORT" \
           --arg uuid "$REMOTE_UUID" \
           --arg tls "$R_TLS" \
           --arg path "/${CODE}" \
           '{
              "tag": $tag, "protocol": "vmess",
              "settings": { "vnext": [{"address": $addr, "port": ($port | tonumber), "users": [{"id": $uuid, "alterId": 0, "security": "auto"}]}] },
              "streamSettings": { 
                  "network": "ws", 
                  "security": $tls, 
                  "tlsSettings": (if $tls == "tls" then {
                      "serverName": $sni, 
                      "allowInsecure": false
                  } else null end),
                  "wsSettings": { 
                      "path": $path, 
                      "headers": {
                          "Host": $sni
                      } 
                  }
              }
           }' >> /tmp/outbound_block.json

        # 路由
        jq -n --arg email "icmp9-${CODE}" --arg outTag "icmp9-out-${CODE}" \
           '{ "type": "field", "user": [$email], "outboundTag": $outTag }' >> /tmp/rule_block.json
           
        echo "${CODE}|${NEW_UUID}" >> /tmp/uuid_map.txt
    done

    # 合并
    jq -s '.' /tmp/outbound_block.json > /tmp/final_outbounds.json
    jq -s '.' /tmp/rule_block.json > /tmp/final_rules.json
    
    jq --slurpfile new_list /tmp/new_users.json --argjson idx "$TARGET_INDEX" --arg field "$USER_FIELD" \
       '.inbounds[$idx].settings[$field] = $new_list[0]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    jq --slurpfile new_outs /tmp/final_outbounds.json '.outbounds += $new_outs[0]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    jq --slurpfile new_rules /tmp/final_rules.json '.routing.rules = ($new_rules[0] + .routing.rules)' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

# ============================================================
# 3. 收尾
# ============================================================
finish_setup() {
    > /root/xray_nodes2.txt
    systemctl restart xray
    sleep 2
    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}配置失败，正在回滚...${PLAIN}"; cp "$BACKUP_FILE" "$CONFIG_FILE"; systemctl restart xray; exit 1
    fi

    echo -e "\n${GREEN}=== 部署成功 (v3.92 Syntax Fix) ===${PLAIN}"
    echo -e "连接地址: ${SKYBLUE}${R_WSHOST}${PLAIN}"
    
    echo "$NODES_JSON" | jq -c '.countries[]?' | while read -r node; do
        CODE=$(echo "$node" | jq -r '.code')
        NAME=$(echo "$node" | jq -r '.name')
        EMOJI=$(echo "$node" | jq -r '.emoji')
        UUID=$(grep "^${CODE}|" /tmp/uuid_map.txt | cut -d'|' -f2)
        NODE_ALIAS="${EMOJI} ${NAME} [中转]"
        
        # 使用修复后的 $LOCAL_PATH 生成正确链接
        if [[ "$LOCAL_PROTO" == "vmess" ]]; then
            # 拆分长命令以确保语法安全
            VMESS_JSON=$(jq -n \
                --arg v "2" \
                --arg ps "$NODE_ALIAS" \
                --arg add "$ARGO_DOMAIN" \
                --arg port "443" \
                --arg id "$UUID" \
                --arg net "ws" \
                --arg type "none" \
                --arg host "$ARGO_DOMAIN" \
                --arg path "$LOCAL_PATH" \
                --arg tls "tls" \
                --arg sni "$ARGO_DOMAIN" \
	--arg fp "chrome" \
            	'{v:$v, ps:$ps, add:$add, port:$port, id:$id, net:$net, type:$type, host:$host, path:$path, tls:$tls, sni:$sni, fp:$fp}')
	
            LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
        else
            LINK="vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=${LOCAL_PATH}&fp=chrome#${NODE_ALIAS}"
        fi
        echo "$LINK" >> /root/xray_nodes2.txt
    done
    rm -f /tmp/new_* /tmp/final_* /tmp/outbound_* /tmp/rule_* /tmp/uuid_map.txt
    echo "请查看: cat /root/xray_nodes2.txt"
}

check_env
get_user_input
inject_config
finish_setup
