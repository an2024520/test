#!/bin/bash

# ============================================================
#  Sing-box 模块：ICMP9 中转扩展 (v1.0 Initial)
#  - 架构: 端口锚定 -> 协议适配 -> 增量注入
#  - 核心: 适配 Sing-box users.name 路由匹配机制
#  - 兼容: VLESS / VMess 入站 + VMess 出站 (Relay)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")
for p in "${PATHS[@]}"; do if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi; done

API_CONFIG="https://api.icmp9.com/config/config.txt"
API_NODES="https://api.icmp9.com/online.php"

# ============================================================
# 1. 环境检查与端口锚定
# ============================================================
check_env() {
    if [[ -z "$CONFIG_FILE" ]]; then echo -e "${RED}错误: 未找到 config.json${PLAIN}"; exit 1; fi
    
    echo -e "${YELLOW}>>> [自检] 正在扫描本地节点...${PLAIN}"

    # 获取端口
    if [[ "$AUTO_SETUP" == "true" ]] && [[ -n "$ICMP9_PORT" ]]; then
        LOCAL_PORT="$ICMP9_PORT"
        echo -e "${GREEN}>>> [自动模式] 锁定端口: $LOCAL_PORT${PLAIN}"
    else
        echo -e "${SKYBLUE}请指定 Sing-box 本地节点端口 (用于 Tunnel 回源):${PLAIN}"
        while true; do
            read -p "请输入端口 (默认 443): " input_port
            LOCAL_PORT=${input_port:-443}
            if [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]]; then break; else echo -e "${RED}无效端口${PLAIN}"; fi
        done
    fi

    # [关键] Sing-box 使用 listen_port 查找节点
    # 兼容: 查找 inbounds 中 listen_port 等于目标端口的节点索引
    TARGET_INDEX=$(jq -r --argjson p "$LOCAL_PORT" '
        .inbounds | to_entries | 
        map(select(.value.listen_port == $p)) | 
        .[0].key
    ' "$CONFIG_FILE")

    if [[ "$TARGET_INDEX" == "null" || -z "$TARGET_INDEX" ]]; then
        echo -e "${RED}错误: 未找到监听端口为 $LOCAL_PORT 的入站节点！${PLAIN}"; exit 1
    fi

    LOCAL_TYPE=$(jq -r ".inbounds[$TARGET_INDEX].type" "$CONFIG_FILE")
    LOCAL_TAG=$(jq -r ".inbounds[$TARGET_INDEX].tag" "$CONFIG_FILE")
    
    echo -e "${GREEN}>>> 节点锁定成功:${PLAIN}"
    echo -e "    索引: [${TARGET_INDEX}]"
    echo -e "    类型: ${SKYBLUE}${LOCAL_TYPE}${PLAIN}"
    echo -e "    Tag : ${SKYBLUE}${LOCAL_TAG}${PLAIN}"

    if [[ "$LOCAL_TYPE" != "vless" && "$LOCAL_TYPE" != "vmess" ]]; then
        echo -e "${RED}错误: 目前仅支持 vless 或 vmess 协议对接。${PLAIN}"; exit 1
    fi
}

get_user_input() {
    if [[ "$AUTO_SETUP" == "true" ]] && [[ -n "$ICMP9_KEY" ]]; then
        REMOTE_UUID="$ICMP9_KEY"
    else
        while true; do
            read -p "请输入 ICMP9 授权 KEY (UUID): " REMOTE_UUID
            if [[ -n "$REMOTE_UUID" ]]; then break; fi
        done
    fi
    
    DEFAULT_DOMAIN=${ARGO_DOMAIN}
    if [[ -z "$ARGO_DOMAIN" ]]; then
         read -p "请输入 Argo 隧道域名 (用于生成链接): " ARGO_DOMAIN
    fi
    [[ -z "$ARGO_DOMAIN" ]] && echo -e "${RED}域名不能为空！${PLAIN}" && exit 1
}

# ============================================================
# 2. 核心注入 (Sing-box 适配版)
# ============================================================
inject_config() {
    echo -e "${YELLOW}>>> [配置] 获取节点数据与重构路由...${PLAIN}"
    
    NODES_JSON=$(curl -s "$API_NODES")
    if ! echo "$NODES_JSON" | jq -e . >/dev/null 2>&1; then echo -e "${RED}API 请求失败${PLAIN}"; exit 1; fi

    # 解析远端配置
    RAW_CFG=$(curl -s "$API_CONFIG")
    R_HOST=$(echo "$RAW_CFG" | grep "^host|" | cut -d'|' -f2 | tr -d '\r\n')
    R_PORT=$(echo "$RAW_CFG" | grep "^port|" | cut -d'|' -f2 | tr -d '\r\n')
    R_WSHOST=$(echo "$RAW_CFG" | grep "^wshost|" | cut -d'|' -f2 | tr -d '\r\n')
    R_TLS=$(echo "$RAW_CFG" | grep "^tls|" | cut -d'|' -f2 | tr -d '\r\n') # 1 or 0
    
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

    # --- 1. 清理旧数据 ---
    # 删除 tag 以 icmp9- 开头的 outbound
    # 删除 outbound 为 icmp9- 开头的 route rules
    # 清理 inbound 中的 icmp9 用户 (通过 name 识别)
    tmp_clean=$(mktemp)
    jq '
        .outbounds |= map(select(.tag | startswith("icmp9-") | not)) |
        .route.rules |= map(select(.outbound | startswith("icmp9-") | not))
    ' "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"
    
    # 清理 Inbound Users (保留非 icmp9 用户)
    # 注意：Sing-box 的 users 是数组
    jq --argjson idx "$TARGET_INDEX" '
        .inbounds[$idx].users |= map(select(.name | startswith("icmp9-") | not))
    ' "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"

    # --- 2. 准备新数据 ---
    echo "[]" > /tmp/sb_new_users.json
    echo "[]" > /tmp/sb_new_outbounds.json
    echo "[]" > /tmp/sb_new_rules.json

    echo "$NODES_JSON" | jq -c '.countries[]?' | while read -r node; do
        CODE=$(echo "$node" | jq -r '.code')
        
        # Sing-box 使用 `sing-box generate uuid` 或系统 uuidgen
        NEW_UUID=$(cat /proc/sys/kernel/random/uuid)
        USER_NAME="icmp9-${CODE}"
        TAG_OUT="icmp9-out-${CODE}"
        PATH_OUT="/${CODE}"

        # 2.1 生成 Sing-box 用户对象 (注入 name 用于路由)
        # 这里的 flow 需要根据原节点是否开启 flow 来决定吗？
        # 通常 relay 不需要 flow，但如果是 reality vision 入站，user 必须带 flow 吗？
        # 为了兼容性，我们检查原节点第一个用户的 flow
        EXIST_FLOW=$(jq -r ".inbounds[$TARGET_INDEX].users[0].flow // empty" "$CONFIG_FILE")
        
        if [[ -n "$EXIST_FLOW" ]]; then
            jq -n --arg uuid "$NEW_UUID" --arg name "$USER_NAME" --arg flow "$EXIST_FLOW" \
               '{uuid: $uuid, name: $name, flow: $flow}' >> /tmp/user_obj.json
        else
            jq -n --arg uuid "$NEW_UUID" --arg name "$USER_NAME" \
               '{uuid: $uuid, name: $name}' >> /tmp/user_obj.json
        fi

        # 2.2 生成 Outbound (VMess)
        # Sing-box VMess 结构与 Xray 不同
        jq -n \
           --arg tag "$TAG_OUT" --arg server "$R_WSHOST" --argjson port "$R_PORT" \
           --arg uuid "$REMOTE_UUID" --arg path "$PATH_OUT" --arg host "$R_WSHOST" --arg tls_en "$R_TLS" \
           '{
             type: "vmess",
             tag: $tag,
             server: $server,
             server_port: $port,
             uuid: $uuid,
             security: "auto",
             transport: {
               type: "ws",
               path: $path,
               headers: {Host: $host}
             },
             tls: {
               enabled: (if $tls_en == "1" then true else false end),
               server_name: $host
             }
           }' >> /tmp/out_obj.json

        # 2.3 生成路由规则
        # Sing-box 路由匹配 users 列表中的 name
        jq -n --arg user "$USER_NAME" --arg out "$TAG_OUT" \
           '{user: [$user], outbound: $out}' >> /tmp/rule_obj.json

        echo "${CODE}|${NEW_UUID}" >> /tmp/sb_uuid_map.txt
    done

    # --- 3. 组装 ---
    jq -s '.' /tmp/user_obj.json > /tmp/sb_new_users.json
    jq -s '.' /tmp/out_obj.json > /tmp/sb_new_outbounds.json
    jq -s '.' /tmp/rule_obj.json > /tmp/sb_new_rules.json

    # --- 4. 注入 ---
    tmp_inject=$(mktemp)
    
    # 4.1 注入 Users 到 Inbound
    jq --slurpfile new_u /tmp/sb_new_users.json --argjson idx "$TARGET_INDEX" \
       '.inbounds[$idx].users += $new_u[0]' "$CONFIG_FILE" > "$tmp_inject" && mv "$tmp_inject" "$CONFIG_FILE"

    # 4.2 注入 Outbounds
    jq --slurpfile new_o /tmp/sb_new_outbounds.json \
       '.outbounds += $new_o[0]' "$CONFIG_FILE" > "$tmp_inject" && mv "$tmp_inject" "$CONFIG_FILE"

    # 4.3 注入 Rules (置顶)
    jq --slurpfile new_r /tmp/sb_new_rules.json \
       '.route.rules = ($new_r[0] + .route.rules)' "$CONFIG_FILE" > "$tmp_inject" && mv "$tmp_inject" "$CONFIG_FILE"

    rm -f /tmp/user_obj.json /tmp/out_obj.json /tmp/rule_obj.json /tmp/sb_new_*.json
}

# ============================================================
# 3. 输出与重启
# ============================================================
finish_setup() {
    > /root/sb_nodes_icmp9.txt
    ARGO_DOMAIN=$(echo "$ARGO_DOMAIN" | tr -d '\r\n ')
    
    echo -e "${YELLOW}>>> 重启 Sing-box...${PLAIN}"
    systemctl restart sing-box
    sleep 2
    
    if ! systemctl is-active --quiet sing-box; then
        echo -e "${RED}启动失败，正在回滚...${PLAIN}"
        cp "${CONFIG_FILE}.bak" "$CONFIG_FILE"
        systemctl restart sing-box
        exit 1
    fi

    echo -e "\n${GREEN}======================================================${PLAIN}"
    echo -e "${GREEN}   Sing-box ICMP9 中转部署成功 (v1.0)                 ${PLAIN}"
    echo -e "${GREEN}======================================================${PLAIN}"

    # 生成分享链接
    # 注意: 即使是 Sing-box 后端，分享链接通常还是用 vless:// 或 vmess:// 给客户端用
    # 这里我们生成通用的分享链接
    
    NODES_JSON=$(curl -s "$API_NODES")
    echo "$NODES_JSON" | jq -c '.countries[]?' | while read -r node; do
        CODE=$(echo "$node" | jq -r '.code')
        NAME=$(echo "$node" | jq -r '.name')
        EMOJI=$(echo "$node" | jq -r '.emoji')
        
        UUID=$(grep "^${CODE}|" /tmp/sb_uuid_map.txt | cut -d'|' -f2)
        NODE_ALIAS="${EMOJI} ${NAME} [SB-Relay]"
        
        # 假设本地是 VLESS + TLS (Tunnel/Vision)
        # 如果是 Tunnel (ws)，path 需要匹配原节点
        # 我们这里尝试读取原节点的 path
        # Sing-box path: .inbounds[].transport.path
        LOCAL_PATH=$(jq -r ".inbounds[$TARGET_INDEX].transport.path // \"/\"" "$CONFIG_FILE")
        
        # 构造标准 VLESS 链接
        # 注意: 这里简化处理，假设是 WS+TLS 或 Vision+Reality
        # 如果是 Vision，type=tcp, flow=xtls-rprx-vision
        # 如果是 WS，type=ws, path=$LOCAL_PATH
        
        LOCAL_NET=$(jq -r ".inbounds[$TARGET_INDEX].transport.type // \"tcp\"" "$CONFIG_FILE")
        if [[ "$LOCAL_NET" == "ws" ]]; then
             LINK="vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=${LOCAL_PATH}#${NODE_ALIAS}"
        else
             # 假设是 Vision (TCP)
             LINK="vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=reality&sni=${ARGO_DOMAIN}&type=tcp&flow=xtls-rprx-vision&fp=chrome&pbk=auto&sid=auto#${NODE_ALIAS}"
        fi
        
        CLEAN_LINK=$(echo "$LINK" | tr -d '\r\n ')
        echo "$CLEAN_LINK" >> /root/sb_nodes_icmp9.txt
    done
    
    echo -e "节点列表已保存至: /root/sb_nodes_icmp9.txt"
    rm -f /tmp/sb_uuid_map.txt
}

check_env
get_user_input
inject_config
finish_setup
