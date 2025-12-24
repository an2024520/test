#!/bin/bash

# ============================================================
#  ICMP9 中转扩展模块 (v3.0 Final Perfect Edition)
#  - 架构: 端口锚定 -> 协议自适应 -> 增量注入
#  - 兼容: VLESS / VMess + WS (Argo Tunnel)
#  - 修复: 彻底解决 clients/users 字段错位问题
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
# 1. 端口锚定与环境检测
# ============================================================
check_env() {
    echo -e "${YELLOW}>>> [自检] 正在扫描本地节点...${PLAIN}"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 未找到 Xray 配置文件 ($CONFIG_FILE)${PLAIN}"; exit 1
    fi

    # --- A. 获取目标端口 ---
    if [[ "$AUTO_SETUP" == "true" ]] && [[ -n "$ICMP9_PORT" ]]; then
        # 自动模式: 接收外部传参
        LOCAL_PORT="$ICMP9_PORT"
        echo -e "${GREEN}>>> [自动模式] 锁定端口: ${SKYBLUE}$LOCAL_PORT${PLAIN}"
    else
        # 手动模式: 交互输入
        echo -e "${SKYBLUE}请指定需要衔接 ICMP9 的本地节点端口 (Tunnel Port):${PLAIN}"
        echo -e "${GRAY}* 该节点通常监听 127.0.0.1，用于 Argo 隧道回源${PLAIN}"
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
    # 使用 jq 根据端口查找节点的索引 (Index)
    TARGET_INDEX=$(jq -r --argjson p "$LOCAL_PORT" '
        .inbounds | to_entries | 
        map(select(.value.port == $p)) | 
        .[0].key
    ' "$CONFIG_FILE")

    if [[ "$TARGET_INDEX" == "null" || -z "$TARGET_INDEX" ]]; then
        echo -e "${RED}错误: 在配置文件中未找到监听端口为 $LOCAL_PORT 的节点！${PLAIN}"
        echo -e "${GRAY}请检查端口是否正确，或先运行部署脚本生成节点。${PLAIN}"
        exit 1
    fi

    # --- C. 提取关键信息用于验证 ---
    LOCAL_PROTO=$(jq -r ".inbounds[$TARGET_INDEX].protocol" "$CONFIG_FILE")
    LOCAL_PATH=$(jq -r ".inbounds[$TARGET_INDEX].streamSettings.wsSettings.path // \"/\"" "$CONFIG_FILE")
    LOCAL_LISTEN=$(jq -r ".inbounds[$TARGET_INDEX].listen" "$CONFIG_FILE")

    echo -e "${GREEN}>>> 节点锁定成功:${PLAIN}"
    echo -e "    索引: [${TARGET_INDEX}]"
    echo -e "    协议: ${SKYBLUE}${LOCAL_PROTO}${PLAIN}"
    echo -e "    路径: ${SKYBLUE}${LOCAL_PATH}${PLAIN}"
    echo -e "    监听: ${YELLOW}${LOCAL_LISTEN}${PLAIN}"

    # 安全警告
    if [[ "$LOCAL_LISTEN" != "127.0.0.1" ]]; then
        echo -e "${RED}警告: 该节点未监听在 127.0.0.1，可能会暴露在公网！${PLAIN}"
        if [[ "$AUTO_SETUP" != "true" ]]; then
            read -p "是否继续? (y/n): " confirm
            [[ "$confirm" != "y" ]] && exit 1
        fi
    fi
    
    # 验证协议支持
    if [[ "$LOCAL_PROTO" != "vless" ]] && [[ "$LOCAL_PROTO" != "vmess" ]]; then
        echo -e "${RED}错误: 不支持协议 $LOCAL_PROTO (仅支持 vless 或 vmess)${PLAIN}"; exit 1
    fi
    
    # IPv6 DNS 优化
    if ! curl -4 -s -m 5 http://ip.sb >/dev/null; then
        if ! grep -q "2001:4860:4860::8888" /etc/resolv.conf; then
            chattr -i /etc/resolv.conf
            echo -e "nameserver 2001:4860:4860::8888\nnameserver 2606:4700:4700::1111" > /etc/resolv.conf
            chattr +i /etc/resolv.conf
        fi
    fi
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
    
    DEFAULT_DOMAIN=${ARGO_DOMAIN}
    if [[ -z "$ARGO_DOMAIN" ]]; then
         read -p "请输入 Argo 隧道域名 (用于生成链接): " ARGO_DOMAIN
    fi
    [[ -z "$ARGO_DOMAIN" ]] && echo -e "${RED}域名不能为空！${PLAIN}" && exit 1
}

# ============================================================
# 2. 核心注入逻辑 (动态适配 VLESS/VMess)
# ============================================================
inject_config() {
    echo -e "${YELLOW}>>> [配置] 获取节点数据与重构路由...${PLAIN}"
    
    # --- 1. 确定协议对应的字段名 ---
    # VLESS 用 clients, VMess 用 users
    if [[ "$LOCAL_PROTO" == "vmess" ]]; then
        USER_FIELD="users"
        echo -e "${YELLOW}>>> 识别为 VMess 协议，操作字段: settings.users${PLAIN}"
    else
        USER_FIELD="clients"
        echo -e "${YELLOW}>>> 识别为 VLESS 协议，操作字段: settings.clients${PLAIN}"
    fi

    NODES_JSON=$(curl -s "$API_NODES")
    if ! echo "$NODES_JSON" | jq -e . >/dev/null 2>&1; then
         echo -e "${RED}错误: API 请求失败，请检查 KEY 或网络。${PLAIN}"; exit 1
    fi
    
    RAW_CFG=$(curl -s "$API_CONFIG")
    R_HOST=$(echo "$RAW_CFG" | grep "^host|" | cut -d'|' -f2 | tr -d '\r\n')
    R_PORT=$(echo "$RAW_CFG" | grep "^port|" | cut -d'|' -f2 | tr -d '\r\n')
    R_WSHOST=$(echo "$RAW_CFG" | grep "^wshost|" | cut -d'|' -f2 | tr -d '\r\n')
    R_TLS="none"; [[ $(echo "$RAW_CFG" | grep "^tls|" | cut -d'|' -f2) == "1" ]] && R_TLS="tls"

    cp "$CONFIG_FILE" "$BACKUP_FILE"

    # --- 2. 清理旧 ICMP9 出站和规则 ---
    jq '
      .outbounds |= map(select(.tag | startswith("icmp9-") | not)) |
      .routing.rules |= map(select(.outboundTag | startswith("icmp9-") | not))
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # --- 3. 准备新的客户列表 ---
    # 使用动态变量 $USER_FIELD 读取原有用户，只取第一个作为备份/直连用户
    EXISTING_USERS=$(jq -c ".inbounds[$TARGET_INDEX].settings.${USER_FIELD}[0:1]" "$CONFIG_FILE")
    
    echo "[]" > /tmp/new_outbounds.json
    echo "[]" > /tmp/new_rules.json
    echo "$EXISTING_USERS" > /tmp/new_users.json

    # --- 4. 循环生成配置 ---
    echo "$NODES_JSON" | jq -c '.countries[]?' | while read -r node; do
        CODE=$(echo "$node" | jq -r '.code')
        
        NEW_UUID=$(/usr/local/bin/xray_core/xray uuid)
        USER_EMAIL="icmp9-${CODE}"
        TAG_OUT="icmp9-out-${CODE}"
        PATH_OUT="/${CODE}"

        # 4.1 追加用户到列表
        # VMess 和 VLESS 都支持 id 和 email 字段，可以直接追加
        jq --arg uuid "$NEW_UUID" --arg email "$USER_EMAIL" \
           '. + [{"id": $uuid, "email": $email}]' \
           /tmp/new_users.json > /tmp/new_users.json.tmp && mv /tmp/new_users.json.tmp /tmp/new_users.json

        # 4.2 生成出站 (Outbound) - 始终连接 ICMP9 远端 (VMess)
        jq -n \
           --arg tag "$TAG_OUT" --arg host "$R_WSHOST" --arg port "$R_PORT" \
           --arg uuid "$REMOTE_UUID" --arg wshost "$R_WSHOST" --arg tls "$R_TLS" --arg path "$PATH_OUT" \
           '{
              "tag": $tag, "protocol": "vmess",
              "settings": { "vnext": [{"address": $host, "port": ($port | tonumber), "users": [{"id": $uuid}]}] },
              "streamSettings": { "network": "ws", "security": $tls, 
                "tlsSettings": (if $tls == "tls" then {"serverName": $wshost} else null end),
                "wsSettings": { "path": $path, "headers": {"Host": $wshost} } }
           }' >> /tmp/outbound_block.json

        # 4.3 生成路由规则 (基于 User Email 分流)
        jq -n \
           --arg email "$USER_EMAIL" \
           --arg outTag "$TAG_OUT" \
           '{ "type": "field", "user": [$email], "outboundTag": $outTag }' >> /tmp/rule_block.json
           
        echo "${CODE}|${NEW_UUID}" >> /tmp/uuid_map.txt
    done

    # --- 5. 合并并注入 ---
    jq -s '.' /tmp/outbound_block.json > /tmp/final_outbounds.json
    jq -s '.' /tmp/rule_block.json > /tmp/final_rules.json
    
    # [核心修复] 注入用户到动态字段 (users 或 clients)
    jq --slurpfile new_list /tmp/new_users.json \
       --argjson idx "$TARGET_INDEX" \
       --arg field "$USER_FIELD" \
       '.inbounds[$idx].settings[$field] = $new_list[0]' \
       "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 注入 Outbounds
    jq --slurpfile new_outs /tmp/final_outbounds.json '.outbounds += $new_outs[0]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    # 注入 Routing (置顶)
    jq --slurpfile new_rules /tmp/final_rules.json '.routing.rules = ($new_rules[0] + .routing.rules)' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    rm -f /tmp/new_users.json /tmp/outbound_block.json /tmp/rule_block.json /tmp/final_*.json /tmp/new_users.json.tmp
}

# ============================================================
# 3. 验证与输出
# ============================================================
finish_setup() {
    # 1. 每次运行脚本前先清空旧的中转节点文件
    > /root/xray_nodes2.txt
    ARGO_DOMAIN=$(echo "$ARGO_DOMAIN" | tr -d '\r\n ')
    echo -e "${YELLOW}>>> [重启] 应用配置...${PLAIN}"
    systemctl restart xray
    sleep 2
    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}失败: Xray 崩溃，正在回滚...${PLAIN}"; cp "$BACKUP_FILE" "$CONFIG_FILE"; systemctl restart xray; exit 1
    fi

    echo -e "\n${GREEN}======================================================${PLAIN}"
    echo -e "${GREEN}   ICMP9 中转部署成功 (Port-Binding Mode)             ${PLAIN}"
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "绑定端口 : ${YELLOW}${LOCAL_PORT}${PLAIN}"
    echo -e "绑定协议 : ${SKYBLUE}${LOCAL_PROTO^^}${PLAIN}"
    echo -e "WS 路径  : ${SKYBLUE}${LOCAL_PATH}${PLAIN}"
    echo -e "------------------------------------------------------"

    echo "$NODES_JSON" | jq -c '.countries[]?' | while read -r node; do
        CODE=$(echo "$node" | jq -r '.code')
        NAME=$(echo "$node" | jq -r '.name')
        EMOJI=$(echo "$node" | jq -r '.emoji')
        
        UUID=$(grep "^${CODE}|" /tmp/uuid_map.txt | cut -d'|' -f2)
        NODE_ALIAS="${EMOJI} ${NAME} [中转]"
        
        # 根据原协议类型生成对应链接
        if [[ "$LOCAL_PROTO" == "vmess" ]]; then
            # 构建 VMess JSON 用于分享
            VMESS_JSON=$(jq -n \
                --arg v "2" --arg ps "$NODE_ALIAS" --arg add "$ARGO_DOMAIN" --arg port "443" --arg id "$UUID" \
                --arg scy "auto" --arg net "ws" --arg type "none" --arg host "$ARGO_DOMAIN" --arg path "$LOCAL_PATH" --arg tls "tls" --arg sni "$ARGO_DOMAIN" \
                '{v:$v, ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:$scy, net:$net, type:$type, host:$host, path:$path, tls:$tls, sni:$sni}')
            LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
        else
            LINK="vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=${LOCAL_PATH}#${NODE_ALIAS}"
          # 这里删除了那个LINK=${LINK// /%20}的代码
        fi

        # === 新增：保存到文件 ===
        # 1. 打印到屏幕
        #echo -e "${SKYBLUE}${LINK}${PLAIN}"
        # 2. 追加到 TXT 文件 (自动去除颜色代码和不可见字符)
        CLEAN_LINK=$(echo "$LINK" | tr -d '\r\n ')
        #要标识就是echo "Tag: icmp9-${CODE} | Link: ${CLEAN_LINK}" >> /root/xray_nodes2.txt
        echo "$CLEAN_LINK" >> /root/xray_nodes2.txt
        # =======================
    done
    echo "请查看cat /root/xray_nodes2.txt"
    rm -f /tmp/uuid_map.txt
    echo -e "------------------------------------------------------"
}

check_env
get_user_input
inject_config
finish_setup
