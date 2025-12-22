#!/bin/bash

# ============================================================
#  Sing-box Native WARP 管理模块 (SB-Commander v6.5 IPv6-Fix)
#  - 核心修复: 强制 IP 掩码 (/32 /128) 解决 Sing-box 解析崩溃
#  - 物理链路: 强制 IPv6 Endpoint 绕过 NAT64 解析故障
#  - 菜单修复: 补全 show_menu 交互逻辑，修复选项无效问题
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# ==========================================
# 1. 环境初始化
# ==========================================

CONFIG_FILE=""
CRED_FILE="/etc/sing-box/warp_credentials.conf"
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 未检测到 config.json 配置文件！${PLAIN}"
    exit 1
fi

mkdir -p "$(dirname "$CRED_FILE")"

check_dependencies() {
    if ! command -v jq &> /dev/null; then apt-get install -y jq || yum install -y jq; fi
    if ! command -v curl &> /dev/null; then apt-get install -y curl || yum install -y curl; fi
}

ensure_python() {
    if ! command -v python3 &> /dev/null; then
        echo -e "${YELLOW}安装 Python3 支持...${PLAIN}"
        apt-get install -y python3 || yum install -y python3
    fi
}

restart_sb() {
    mkdir -p /var/log/sing-box/ && chmod 777 /var/log/sing-box/ >/dev/null 2>&1
    echo -e "${YELLOW}重启 Sing-box 服务...${PLAIN}"
    if command -v sing-box &> /dev/null; then
        if ! sing-box check -c "$CONFIG_FILE" > /dev/null 2>&1; then
             echo -e "${RED}配置语法校验失败！${PLAIN}"
             sing-box check -c "$CONFIG_FILE"
             return
        fi
    fi
    if systemctl list-unit-files | grep -q sing-box; then
        systemctl restart sing-box
    else
        pkill -xf "sing-box run -c $CONFIG_FILE"
        nohup sing-box run -c "$CONFIG_FILE" > /dev/null 2>&1 &
    fi
}

# ==========================================
# 2. 账号与配置核心逻辑
# ==========================================

save_credentials() {
    cat > "$CRED_FILE" <<EOF
PRIV_KEY="$1"
PUB_KEY="$2"
V4_ADDR="$3"
V6_ADDR="$4"
RESERVED="$5"
EOF
    echo -e "${GREEN}凭证已备份至: $CRED_FILE${PLAIN}"
}

register_warp() {
    ensure_python || return 1
    echo -e "${YELLOW}正在注册免费账号...${PLAIN}"
    if ! command -v wg &> /dev/null; then apt install -y wireguard-tools || yum install -y wireguard-tools; fi
    
    local priv_key=$(wg genkey)
    local pub_key=$(echo "$priv_key" | wg pubkey)
    local install_id=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 22)
    local result=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "User-Agent: okhttp/3.12.1" -H "Content-Type: application/json; charset=UTF-8" \
        -d "{\"key\":\"${pub_key}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${install_id}:APA91bHuwEuLNj_${install_id}\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Android\",\"serial_number\":\"${install_id}\",\"locale\":\"zh_CN\"}")
    
    local v4=$(echo "$result" | jq -r '.config.interface.addresses.v4')
    local v6=$(echo "$result" | jq -r '.config.interface.addresses.v6')
    local peer_pub=$(echo "$result" | jq -r '.config.peers[0].public_key')
    local client_id=$(echo "$result" | jq -r '.config.client_id')
    
    if [[ "$v4" == "null" || -z "$v4" ]]; then echo -e "${RED}注册失败。${PLAIN}"; return 1; fi
    
    # 修复掩码缺失
    [[ ! "$v4" =~ "/" ]] && v4="${v4}/32"
    [[ ! "$v6" =~ "/" ]] && v6="${v6}/128"
    
    local reserved_json=$(python3 -c "import base64, json; decoded = base64.b64decode('$client_id'); print(json.dumps([x for x in decoded[0:3]]))" 2>/dev/null)
    save_credentials "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
    write_warp_config "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
}

write_warp_config() {
    local priv="$1" pub="$2" v4="$3" v6="$4" res="$5"
    
    # 二次确认掩码格式
    [[ ! "$v4" =~ "/" && -n "$v4" ]] && v4="${v4}/32"
    [[ ! "$v6" =~ "/" && -n "$v6" ]] && v6="${v6}/128"
    
    local addr_json="[]"
    [[ -n "$v4" && "$v4" != "null" ]] && addr_json=$(echo "$addr_json" | jq --arg ip "$v4" '. + [$ip]')
    [[ -n "$v6" && "$v6" != "null" ]] && addr_json=$(echo "$addr_json" | jq --arg ip "$v6" '. + [$ip]')
    
    # 强制物理 IPv6 Endpoint
    local warp_json=$(jq -n \
        --arg priv "$priv" --arg pub "$pub" --argjson addr "$addr_json" --argjson res "$res" \
        '{ 
            "type": "wireguard", 
            "tag": "WARP", 
            "address": $addr, 
            "private_key": $priv,
            "system": false,
            "peers": [
                { 
                    "address": "2606:4700:d0::a29f:c001", 
                    "port": 2408, 
                    "public_key": $pub, 
                    "reserved": $res,
                    "allowed_ips": ["0.0.0.0/0", "::/0"]
                }
            ] 
        }')

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    local TMP_CONF=$(mktemp)
    # 使用 endpoints 数组模式写入
    jq 'if .endpoints == null then .endpoints = [] else . end | del(.endpoints[] | select(.tag == "WARP")) | .endpoints += [$new]' --argjson new "$warp_json" "$CONFIG_FILE" > "$TMP_CONF"
    
    if [[ $? -eq 0 && -s "$TMP_CONF" ]]; then
        mv "$TMP_CONF" "$CONFIG_FILE"
        echo -e "${GREEN}WARP 配置已写入并应用物理 IPv6 直连。${PLAIN}"
        restart_sb
    else
        echo -e "${RED}配置写入失败。${PLAIN}"; rm "$TMP_CONF" 2>/dev/null
    fi
}

# ==========================================
# 3. 交互菜单逻辑 (关键修复点)
# ==========================================

show_menu() {
    check_dependencies
    while true; do
        clear
        echo -e "${BLUE}============= Sing-box 核心路由管理 =============${PLAIN}"
        echo -e " ${SKYBLUE}1.${PLAIN} Native WARP (原生 WireGuard 模式 - 推荐)"
        echo -e "    ${GRAY}- 自动注册账号，支持 ChatGPT/Netflix 分流${PLAIN}"
        echo -e " ${SKYBLUE}2.${PLAIN} Wireproxy WARP (Socks5 模式 - 待开发)"
        echo -e " ----------------------------------------------"
        echo -e " ${GRAY}0. 返回上一级${PLAIN}"
        echo -e " ${GRAY}99. 返回总菜单${PLAIN}"
        echo -e ""
        read -p "请选择: " choice
        case "$choice" in
            1)
                echo -e "\n${YELLOW}正在启动 WARP 注册程序...${PLAIN}"
                register_warp
                read -p "按回车继续..."
                ;;
            2)
                echo -e "${YELLOW}功能开发中...${PLAIN}"
                sleep 2
                ;;
            0)
                exit 0
                ;;
            99)
                # 尝试调用父级脚本
                if [[ -f "./menu.sh" ]]; then bash ./menu.sh; else exit 0; fi
                ;;
            *)
                echo -e "${RED}无效输入${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

# 运行主菜单
show_menu
