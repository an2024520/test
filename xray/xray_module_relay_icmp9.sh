#!/bin/bash

# ============================================================
#  ICMP9 中转扩展模块 (v3.2 IPv6-Split-Fix)
#  - 架构: 端口锚定 -> 协议自适应 -> 增量注入
#  - 修复: 纯 IPv6 环境下远程域名无 AAAA 记录导致的无法连接
#  - 核心: 实现“连接地址(IPv6)”与“伪装域名(SNI)”分离配置
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
GRAY='\033[0;37m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
BACKUP_FILE="/usr/local/etc/xray/config.json.bak"
API_CONFIG="https://api.icmp9.com/config/config.txt"
API_NODES="https://api.icmp9.com/online.php"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# ============================================================
# 0. 基础依赖检查
# ============================================================
check_dependencies() {
    if ! command -v jq &> /dev/null; then apt-get install -y jq || yum install -y jq; fi
    # 需要 dnsutils 来使用 dig 命令进行解析检测
    if ! command -v dig &> /dev/null; then apt-get install -y dnsutils || yum install -y bind-utils; fi
}

# ============================================================
# 1. 端口锚定与环境检测
# ============================================================
check_env() {
    check_dependencies
    echo -e "${YELLOW}>>> [自检] 正在扫描本地节点...${PLAIN}"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 未找到 Xray 配置文件 ($CONFIG_FILE)${PLAIN}"; exit 1
    fi

    # --- IPv6 环境检测 ---
    IS_IPV6_ONLY=false
    if ! curl -4 -s -m 2 http://ip.sb >/dev/null; then
        IS_IPV6_ONLY=true
        echo -e "${SKYBLUE}>>> 检测到纯 IPv6 环境 (无 IPv4)${PLAIN}"
    else
        echo -e "${GREEN}>>> 检测到 IPv4/双栈环境${PLAIN}"
    fi

    # --- A. 获取目标端口 ---
    if [[ "$AUTO_SETUP" == "true" ]] && [[ -n "$ICMP9_PORT" ]]; then
        LOCAL_PORT="$ICMP9_PORT"
        echo -e "${GREEN}>>> [自动模式] 锁定端口: ${SKYBLUE}$LOCAL_PORT${PLAIN}"
    else
        echo -e "${SKYBLUE}请指定需要衔接 ICMP9 的本地节点端口 (Tunnel Port):${PLAIN}"
        while true; do
            read -p "请输入端口 (默认 8080): " input_port
            LOCAL_PORT=${input_port:-8080}
            if [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] && [ "$LOCAL_PORT" -le 65535 ]; then
                break
            else
                echo -e "${RED}无效端口，请重新输入。${PLAIN}"
            fi
        done
    fi

    # --- B. 精准锚定节点 ---
    TARGET_INDEX=$(jq -r --argjson p "$LOCAL_PORT" '
        .inbounds | to_entries | 
        map(select(.value.port == $p)) | 
        .[0].key
    ' "$CONFIG_FILE")

    if [[ "$TARGET_INDEX" == "null" || -z "$TARGET_INDEX" ]]; then
        echo -e "${RED}错误: 未找到监听端口为 $LOCAL_PORT 的节点！${PLAIN}"
        exit 1
    fi

    LOCAL_PROTO=$(jq -r ".inbounds[$TARGET_INDEX].protocol" "$CONFIG_FILE")
    LOCAL_PATH=$(jq -r ".inbounds[$TARGET_INDEX].streamSettings.wsSettings.path // \"/\"" "$CONFIG_FILE")
    echo -e "${GREEN}>>> 节点锁定成功: [${LOCAL_PROTO^^}] Path: ${LOCAL_PATH}${PLAIN}"
}

get_user_input() {
    if [[ "$AUTO_SETUP" == "true" ]] && [[ -n "$ICMP9_KEY" ]]; then
        REMOTE_UUID="$ICMP9_KEY"
    else
        echo -e "----------------------------------------------------"
        while true; do
            read -p "请输入 ICMP9 授权 KEY (UUID): " REMOTE_UUID
            if [[ -n "$REMOTE_UUID" ]]; then break; fi
        done
    fi
    
    if [[ -z "$ARGO_DOMAIN" ]]; then
         read -p "请输入 Argo 隧道域名 (用于生成链接): " ARGO_DOMAIN
    fi
}

# ============================================================
# 2. 核心注入逻辑 (地址分离修复版)
# ============================================================
inject_config() {
    echo -e "${YELLOW}>>> [配置] 获取节点数据...${PLAIN}"
    
    if [[ "$LOCAL_PROTO" == "vmess" ]]; then USER_FIELD="users"; else USER_FIELD="clients"; fi

    NODES_JSON=$(curl -s "$API_NODES")
    if ! echo "$NODES_JSON" | jq -e . >/dev/null 2>&1; then
         echo -e "${RED}错误: API 请求失败。${PLAIN}"; exit 1
    fi
    
    RAW_CFG=$(curl -s "$API_CONFIG")
    R_WSHOST=$(echo "$RAW_CFG" | grep "^wshost|" | cut -d'|' -f2 | tr -d '\r\n')
    R_PORT=$(echo "$RAW_CFG" | grep "^port|" | cut -d'|' -f2 | tr -d '\r\n')
    R_TLS="none"; [[ $(echo "$RAW_CFG" | grep "^tls|" | cut -d'|' -f2) == "1" ]] && R_TLS="tls"

    # ========================================================
    # [核心修复] 远程地址 IPv6 适配检查
    # ========================================================
    FINAL_CONNECT_ADDR="$R_WSHOST"
    
    if [[ "$IS_IPV6_ONLY" == "true" ]]; then
        echo -e "${YELLOW}>>> 正在检测远程域名 ($R_WSHOST) 的 IPv6 连通性...${PLAIN}"
        
        # 尝试解析 AAAA 记录
        AAAA_RECORD=$(dig AAAA +short "$R_WSHOST" | head -n 1)
        
        if [[ -n "$AAAA_RECORD" ]]; then
            echo -e "${GREEN}>>> 成功解析到 IPv6 地址: $AAAA_RECORD${PLAIN}"
            # 即使解析到了，为了保险，也可以选择是否强制使用 IP，这里默认信赖解析
        else
            echo -e "${RED}警告: 纯 IPv6 环境下，远程域名 $R_WSHOST 未解析到 IPv6 地址！${PLAIN}"
            echo -e "${RED}      直接连接会导致 'Network is unreachable'。${PLAIN}"
            echo -e "${SKYBLUE}>>> 解决方案: 请手动输入远程节点的 IPv6 地址。${PLAIN}"
            echo -e "${GRAY}    (此地址将用于建立连接，原域名仍用于 TLS 握手验证)${PLAIN}"
            
            while true; do
                read -p "请输入远程 IPv6 地址 (留空则尝试直接使用域名): " MANUAL_IPV6
                if [[ -n "$MANUAL_IPV6" ]]; then
                    # 简单验证 IPv6 格式
                    if [[ "$MANUAL_IPV6" =~ : ]]; then
                        FINAL_CONNECT_ADDR="$MANUAL_IPV6"
                        echo -e "${GREEN}>>> 已采用手动 IPv6 地址: $FINAL_CONNECT_ADDR${PLAIN}"
                        break
                    else
                        echo -e "${RED}格式错误，请输入有效的 IPv6 地址 (包含冒号)。${PLAIN}"
                    fi
                else
                    echo -e "${YELLOW}>>> 未输入，将保持使用域名 (可能会连接失败)。${PLAIN}"
                    break
                fi
            done
        fi
    fi
    # ========================================================

    cp "$CONFIG_FILE" "$BACKUP_FILE"

    # 清理旧配置
    jq '
      .outbounds |= map(select(.tag | startswith("icmp9-") | not)) |
      .routing.rules |= map(select(.outboundTag | startswith("icmp9-") | not))
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    EXISTING_USERS=$(jq -c ".inbounds[$TARGET_INDEX].settings.${USER_FIELD}[0:1]" "$CONFIG_FILE")
    
    echo "[]" > /tmp/new_outbounds.json
    echo "[]" > /tmp/new_rules.json
    echo "$EXISTING_USERS" > /tmp/new_users.json

    echo "$NODES_JSON" | jq -c '.countries[]?' | while read -r node; do
        CODE=$(echo "$node" | jq -r '.code')
        NEW_UUID=$(/usr/local/bin/xray_core/xray uuid)
        USER_EMAIL="icmp9-${CODE}"
        TAG_OUT="icmp9-out-${CODE}"
        PATH_OUT="/${CODE}"

        jq --arg uuid "$NEW_UUID" --arg email "$USER_EMAIL" \
           '. + [{"id": $uuid, "email": $email}]' \
           /tmp/new_users.json > /tmp/new_users.json.tmp && mv /tmp/new_users.json.tmp /tmp/new_users.json

        # [生成出站]
        # 关键点：address 使用 $conn_addr (可能是 IP)，Host/SNI 使用 $sni_host (域名)
        jq -n \
           --arg tag "$TAG_OUT" \
           --arg conn_addr "$FINAL_CONNECT_ADDR" \
           --arg sni_host "$R_WSHOST" \
           --arg port "$R_PORT" \
           --arg uuid "$REMOTE_UUID" \
           --arg tls "$R_TLS" \
           --arg path "$PATH_OUT" \
           '{
              "tag": $tag, "protocol": "vmess",
              "settings": { "vnext": [{"address": $conn_addr, "port": ($port | tonumber), "users": [{"id": $uuid}]}] },
              "streamSettings": { 
                  "network": "ws", 
                  "security": $tls, 
                  "tlsSettings": (if $tls == "tls" then {"serverName": $sni_host} else null end),
                  "wsSettings": { "path": $path, "headers": {"Host": $sni_host} },
                  "sockopt": { "domainStrategy": "UseIPv6" } 
              }
           }' >> /tmp/outbound_block.json

        jq -n \
           --arg email "$USER_EMAIL" \
           --arg outTag "$TAG_OUT" \
           '{ "type": "field", "user": [$email], "outboundTag": $outTag }' >> /tmp/rule_block.json
           
        echo "${CODE}|${NEW_UUID}" >> /tmp/uuid_map.txt
    done

    jq -s '.' /tmp/outbound_block.json > /tmp/final_outbounds.json
    jq -s '.' /tmp/rule_block.json > /tmp/final_rules.json
    
    jq --slurpfile new_list /tmp/new_users.json \
       --argjson idx "$TARGET_INDEX" \
       --arg field "$USER_FIELD" \
       '.inbounds[$idx].settings[$field] = $new_list[0]' \
       "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    jq --slurpfile new_outs /tmp/final_outbounds.json '.outbounds += $new_outs[0]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    jq --slurpfile new_rules /tmp/final_rules.json '.routing.rules = ($new_rules[0] + .routing.rules)' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    rm -f /tmp/new_users.json /tmp/outbound_block.json /tmp/rule_block.json /tmp/final_*.json /tmp/new_users.json.tmp
}

# ============================================================
# 3. 验证与输出
# ============================================================
finish_setup() {
    > /root/xray_nodes2.txt
    ARGO_DOMAIN=$(echo "$ARGO_DOMAIN" | tr -d '\r\n ')
    echo -e "${YELLOW}>>> [重启] 应用配置...${PLAIN}"
    systemctl restart xray
    sleep 2
    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}失败: Xray 崩溃，正在回滚...${PLAIN}"; cp "$BACKUP_FILE" "$CONFIG_FILE"; systemctl restart xray; exit 1
    fi

    echo -e "\n${GREEN}======================================================${PLAIN}"
    echo -e "${GREEN}   ICMP9 中转部署成功 (v3.2 IPv6 增强版)              ${PLAIN}"
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "远程连接地址: ${SKYBLUE}${FINAL_CONNECT_ADDR}${PLAIN}"
    echo -e "SNI 伪装域名: ${YELLOW}${R_WSHOST}${PLAIN}"
    echo -e "------------------------------------------------------"

    echo "$NODES_JSON" | jq -c '.countries[]?' | while read -r node; do
        CODE=$(echo "$node" | jq -r '.code')
        NAME=$(echo "$node" | jq -r '.name')
        EMOJI=$(echo "$node" | jq -r '.emoji')
        
        UUID=$(grep "^${CODE}|" /tmp/uuid_map.txt | cut -d'|' -f2)
        NODE_ALIAS="${EMOJI} ${NAME} [中转]"
        
        if [[ "$LOCAL_PROTO" == "vmess" ]]; then
            VMESS_JSON=$(jq -n \
                --arg v "2" --arg ps "$NODE_ALIAS" --arg add "$ARGO_DOMAIN" --arg port "443" --arg id "$UUID" \
                --arg scy "auto" --arg net "ws" --arg type "none" --arg host "$ARGO_DOMAIN" --arg path "$LOCAL_PATH" --arg tls "tls" --arg sni "$ARGO_DOMAIN" \
                '{v:$v, ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:$scy, net:$net, type:$type, host:$host, path:$path, tls:$tls, sni:$sni}')
            LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
        else
            LINK="vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=${LOCAL_PATH}#${NODE_ALIAS}"
        fi
        echo "$LINK" >> /root/xray_nodes2.txt
    done
    echo "请查看: cat /root/xray_nodes2.txt"
    rm -f /tmp/uuid_map.txt
    echo -e "------------------------------------------------------"
}

check_env
get_user_input
inject_config
finish_setup
