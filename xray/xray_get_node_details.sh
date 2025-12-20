#!/bin/bash

# ============================================================
#  模块四：节点信息读取 (v3.1 暴力适配版)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray_core/xray"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}[错误] 找不到配置文件: $CONFIG_FILE${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}>>> 正在获取节点信息...${PLAIN}"
PUBLIC_IP=$(curl -s4 ifconfig.me)
[[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="[你的服务器IP]"

for row in $(jq -r '.inbounds[] | @base64' "$CONFIG_FILE"); do
    _jq() { echo ${row} | base64 --decode | jq -r ${1}; }

    PROTOCOL=$(_jq '.protocol')
    
    if [[ "$PROTOCOL" == "vless" ]]; then
        TAG=$(_jq '.tag')
        PORT=$(_jq '.port')
        UUID=$(_jq '.settings.clients[0].id')
        NETWORK=$(_jq '.streamSettings.network')
        SECURITY=$(_jq '.streamSettings.security')
        
        if [[ "$SECURITY" == "reality" ]]; then
            PRIVATE_KEY=$(_jq '.streamSettings.realitySettings.privateKey')
            
            # --- 核心修改：暴力抓取 ---
            # 运行命令获取所有输出
            RAW_OUTPUT=$($XRAY_BIN x25519 -i "$PRIVATE_KEY" 2>&1)
            
            # 逻辑：
            # 1. awk '/Public|Password/' : 只要行里包含 Public 或 Password
            # 2. {print $NF} : 直接打印这一行的"最后一个字段" (也就是密钥本体)
            # 3. head -n 1 : 万一匹配到多行，只取第一行
            PUBLIC_KEY=$(echo "$RAW_OUTPUT" | awk '/Public|Password/{print $NF}' | head -n 1)

            # 兜底：如果还是空的，强制标记错误
            if [[ -z "$PUBLIC_KEY" ]]; then
                 PUBLIC_KEY="[获取失败-请检查Xray版本]"
            fi
            
            SNI=$(_jq '.streamSettings.realitySettings.serverNames[0]')
            SHORT_ID=$(_jq '.streamSettings.realitySettings.shortIds[0]')
            [[ "$SHORT_ID" == "null" ]] && SHORT_ID=""

            echo -e "${CYAN}--------------------------------------------------${PLAIN}"
            echo -e "节点名称: ${YELLOW}${TAG}${PLAIN} | 协议: ${GREEN}${NETWORK}${PLAIN}"
            
            # 生成 OpenClash (Vision / TCP)
            if [[ "$NETWORK" == "tcp" ]]; then
                echo -e "${YELLOW}➤ OpenClash 配置 (Vision):${PLAIN}"
                echo -e "  - name: \"${TAG}\""
                echo -e "    type: vless"
                echo -e "    server: ${PUBLIC_IP}"
                echo -e "    port: ${PORT}"
                echo -e "    uuid: ${UUID}"
                echo -e "    network: tcp"
                echo -e "    tls: true"
                echo -e "    udp: true"
                echo -e "    flow: xtls-rprx-vision"
                echo -e "    servername: ${SNI}"
                echo -e "    client-fingerprint: chrome"
                echo -e "    reality-opts:"
                echo -e "      public-key: ${PUBLIC_KEY}"
                echo -e "      short-id: ${SHORT_ID}"
                
                echo -e "\n${YELLOW}➤ v2rayN 分享链接:${PLAIN}"
                echo -e "vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#${TAG}"

            # 生成 OpenClash (XHTTP)
            elif [[ "$NETWORK" == "xhttp" ]]; then
                PATH_VAL=$(_jq '.streamSettings.xhttpSettings.path')
                echo -e "${YELLOW}➤ OpenClash 配置 (XHTTP):${PLAIN}"
                echo -e "  - name: \"${TAG}\""
                echo -e "    type: vless"
                echo -e "    server: ${PUBLIC_IP}"
                echo -e "    port: ${PORT}"
                echo -e "    uuid: ${UUID}"
                echo -e "    network: xhttp"
                echo -e "    tls: true"
                echo -e "    udp: true"
                echo -e "    # flow: (XHTTP不支持vision)"
                echo -e "    servername: ${SNI}"
                echo -e "    client-fingerprint: chrome"
                echo -e "    reality-opts:"
                echo -e "      public-key: ${PUBLIC_KEY}"
                echo -e "      short-id: ${SHORT_ID}"
                echo -e "    xhttp-opts:"
                echo -e "      mode: auto"
                echo -e "      path: ${PATH_VAL}"
                
                echo -e "\n${YELLOW}➤ v2rayN 分享链接:${PLAIN}"
                echo -e "vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&type=xhttp&path=${PATH_VAL}&mode=auto&sni=${SNI}&sid=${SHORT_ID}#${TAG}"
            fi
        fi
    fi
done
echo -e "${CYAN}--------------------------------------------------${PLAIN}"
