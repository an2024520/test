#!/bin/bash

# ============================================================
#  Xray WARP Native Route 模块 (v2.7 Ultimate-Fix)
#  - 修复: 恢复手动模式下的接管模式选择菜单 (1-4)
#  - 适配: 自动识别 IPv6-Only 环境并切换 Endpoint
#  - 独立: 具备账号注册能力，不依赖 auto_deploy 预设
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
GRAY='\033[0;37m'

# 检查 Root
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# ============================================================
# 0. 环境初始化与依赖检查
# ============================================================
CONFIG_FILE=""
PATHS=("/usr/local/etc/xray/config.json" "/etc/xray/config.json" "$HOME/xray/config.json")
for p in "${PATHS[@]}"; do [[ -f "$p" ]] && CONFIG_FILE="$p" && break; done

BACKUP_FILE="${CONFIG_FILE}.bak"
CRED_FILE="/etc/xray/warp_credentials.conf"

check_dependencies() {
    if ! command -v jq &> /dev/null || ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}安装必要依赖...${PLAIN}"
        apt-get update >/dev/null 2>&1
        apt-get install -y jq curl python3 wireguard-tools >/dev/null 2>&1 || yum install -y jq curl python3 wireguard-tools >/dev/null 2>&1
    fi
}

# ============================================================
# 1. 环境与账号获取
# ============================================================
check_env() {
    echo -e "${YELLOW}检测网络环境...${PLAIN}"
    FINAL_ENDPOINT="engage.cloudflareclient.com:2408"
    FINAL_ENDPOINT_IP=""
    local ipv4_check=$(curl -4 -s -m 5 http://ip.sb 2>/dev/null)
    if [[ ! "$ipv4_check" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local ep_ip="2606:4700:d0::a29f:c001"
        FINAL_ENDPOINT="[${ep_ip}]:2408"
        FINAL_ENDPOINT_IP="${ep_ip}"
        echo -e "${SKYBLUE}>>> 检测到 IPv6-Only 环境${PLAIN}"
    fi
}

register_warp() {
    echo -e "${YELLOW}注册 WARP 免费账号...${PLAIN}"
    local priv_key=$(wg genkey)
    local pub_key=$(echo "$priv_key" | wg pubkey)
    local install_id=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 22)
    local result=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -d "{\"key\":\"${pub_key}\",\"install_id\":\"${install_id}\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Android\"}")
    local v6=$(echo "$result" | jq -r '.config.interface.addresses.v6')
    local client_id=$(echo "$result" | jq -r '.config.client_id')
    if [[ "$v6" == "null" ]]; then echo -e "${RED}注册失败${PLAIN}"; exit 1; fi
    local res_str=$(python3 -c "import base64; d=base64.b64decode('$client_id'); print(','.join([str(x) for x in d[0:3]]))")
    export WG_KEY="$priv_key" WG_ADDR="$v6/128" WG_RESERVED="$res_str"
}

get_warp_account() {
    if [[ -n "$WARP_PRIV_KEY" ]]; then
        export WG_KEY="$WARP_PRIV_KEY" WG_ADDR="$WARP_IPV6" WG_RESERVED=$(echo "$WARP_RESERVED" | tr -d '[] ')
    else
        echo -e " 1. 自动注册  2. 手动输入"
        read -p "请选择: " c
        if [[ "$c" == "2" ]]; then
            read -p "私钥: " WG_KEY; read -p "IPv6地址: " WG_ADDR; read -p "Reserved: " WG_RESERVED
        else register_warp; fi
    fi
}

# ============================================================
# 2. 模式选择 (核心恢复点)
# ============================================================
select_mode() {
    # 如果是自动化部署，直接跳过交互
    [[ "$AUTO_SETUP" == "true" ]] && return

    echo -e "----------------------------------------------------"
    echo -e "${SKYBLUE}请选择 WARP 接管模式:${PLAIN}"
    echo -e " 1. 仅流媒体分流 (Netflix/Disney+/OpenAI)"
    echo -e " 2. IPv4 优先 (所有 IPv4 流量走 WARP)"
    echo -e " 3. 指定节点接管 (按 Inbound Tag 选择)"
    echo -e " 4. 全局全双栈接管"
    read -p "选择 [1-4]: " m
    export WARP_MODE_SELECT="${m:-1}"

    if [[ "$WARP_MODE_SELECT" == "3" ]]; then
        echo -e "${YELLOW}检测到以下 Inbound Tags:${PLAIN}"
        jq -r '.inbounds[].tag' "$CONFIG_FILE" | nl
        read -p "请输入要接管的 Tag (多个用逗号分隔): " tags
        export WARP_INBOUND_TAGS="$tags"
    fi
}

# ============================================================
# 3. 配置注入
# ============================================================
inject_config() {
    echo -e "${YELLOW}正在注入配置...${PLAIN}"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    
    # 清理
    jq '.outbounds |= map(select(.tag != "warp-out")) | .routing.rules |= map(select(.outboundTag != "warp-out"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 注入 Outbound
    local res_json="[${WG_RESERVED}]"
    jq --arg key "$WG_KEY" --arg addr "$WG_ADDR" --argjson res "$res_json" --arg ep "$FINAL_ENDPOINT" \
       '.outbounds += [{ "tag": "warp-out", "protocol": "wireguard", "settings": { "secretKey": $key, "address": [$addr], "peers": [{ "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "endpoint": $ep }], "reserved": $res } }]' \
       "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 构造路由规则
    local anti_loop='{ "type": "field", "domain": ["engage.cloudflareclient.com"], "outboundTag": "direct" }'
    local rule=""
    case "$WARP_MODE_SELECT" in
        2) rule='{ "type": "field", "network": "tcp,udp", "ip": ["0.0.0.0/0"], "outboundTag": "warp-out" }' ;;
        3) 
            local tag_json=$(echo "$WARP_INBOUND_TAGS" | jq -R 'split(",")')
            rule=$(jq -n --argjson t "$tag_json" '{ "type": "field", "inboundTag": $t, "outboundTag": "warp-out" }') ;;
        4) rule='{ "type": "field", "network": "tcp,udp", "outboundTag": "warp-out" }' ;;
        *) rule='{ "type": "field", "domain": ["netflix.com","openai.com","google.com"], "outboundTag": "warp-out" }' ;;
    esac

    jq --argjson r1 "$anti_loop" --argjson r2 "$rule" '.routing.rules = [$r1, $r2] + .routing.rules' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

# ============================================================
# 主流程
# ============================================================
check_dependencies
check_env
get_warp_account
select_mode # 恢复模式选择环节
inject_config
systemctl restart xray
echo -e "${GREEN}配置结束，Xray 已重启。${PLAIN}"
