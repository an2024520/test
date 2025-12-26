#!/bin/bash

# ============================================================
#  Sing-box Native WARP 管理模块 (v3.6 Ultimate-Fix)
#  - 架构: Endpoint + Detour (v1.10+ 标准)
#  - 修复: 修正路由插入顺序导致的“全局模式死循环”BUG
#  - 增强: 防环回规则增加 IPv6 Endpoint IP 白名单
#  - 补丁: 修复手动模式下因缺少 config.json 导致无法启动的问题
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# ==========================================
# 1. 环境初始化 (修复版)
# ==========================================

CONFIG_FILE=""
CRED_FILE="/etc/sing-box/warp_credentials.conf"
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done

# --- [修复逻辑 Start] ---
# 自动模式下保持严格检查，防止流程错乱；手动模式下允许空配置启动
if [[ "$AUTO_SETUP" == "true" ]]; then
    if [[ -z "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: [自动模式] 未检测到 config.json 配置文件！流程终止。${PLAIN}"
        exit 1
    fi
else
    if [[ -z "$CONFIG_FILE" ]]; then
        CONFIG_FILE="/etc/sing-box/config.json"
        echo -e "${YELLOW}提示: 未找到现有 config.json，将在操作时尝试创建或写入默认路径。${PLAIN}"
    fi
fi
# --- [修复逻辑 End] ---

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

# --- 环境检测与 Endpoint 适配 ---
check_env() {
    echo -e "${YELLOW}正在执行严格的网络环境检测...${PLAIN}"
    
    # 默认值
    FINAL_EP_ADDR="engage.cloudflareclient.com"
    FINAL_EP_PORT=2408

    # 严格检测 IPv4 (使用 ip.sb)
    local ipv4_check=$(curl -4 -s -m 5 http://ip.sb 2>/dev/null)
    
    if [[ "$ipv4_check" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${GREEN}>>> 检测到有效 IPv4 环境 (IP: $ipv4_check)。${PLAIN}"
    else
        # IPv6-Only: 切换为官方 IPv6 Anycast IP
        FINAL_EP_ADDR="2606:4700:d0::a29f:c001"
        echo -e "${SKYBLUE}>>> 检测到纯 IPv6 环境，切换为专用 Endpoint: ${FINAL_EP_ADDR}${PLAIN}"
    fi
    
    export FINAL_EP_ADDR
    export FINAL_EP_PORT
}

restart_sb() {
    mkdir -p /var/log/sing-box/ && chmod 777 /var/log/sing-box/ >/dev/null 2>&1
    echo -e "${YELLOW}重启 Sing-box 服务...${PLAIN}"
    
  if command -v sing-box &> /dev/null; then
        echo -e "${YELLOW}正在执行语法校验...${PLAIN}"
        # 1. 去掉 > /dev/null 2>&1，让错误显示在屏幕上
        if ! sing-box check -c "$CONFIG_FILE"; then
             echo -e "${RED}配置语法校验严重失败！${PLAIN}"
             echo -e "${RED}请截图上方报错信息！${PLAIN}"
             
             # 2. 暂时注释掉回滚，这样你可以用 cat 查看 config.json 到底哪里错了
             # [[ -f "${CONFIG_FILE}.bak" ]] && cp "${CONFIG_FILE}.bak" "$CONFIG_FILE"
             return
        fi
    fi

    if systemctl list-unit-files | grep -q sing-box; then
        systemctl restart sing-box
    else
        pkill -xf "sing-box run -c $CONFIG_FILE"
        nohup sing-box run -c "$CONFIG_FILE" > /dev/null 2>&1 &
    fi
    sleep 2
    if systemctl is-active --quiet sing-box || pgrep -x "sing-box" >/dev/null; then
        echo -e "${GREEN}服务重启成功。${PLAIN}"
    else
        echo -e "${RED}服务重启失败！${PLAIN}"
    fi
}

# ==========================================
# 2. 核心功能函数
# ==========================================

clean_reserved() {
    local input="$1"
    local nums=$(echo "$input" | grep -oE '[0-9]+' | tr '\n' ',' | sed 's/,$//')
    [[ -n "$nums" ]] && echo "[$nums]" || echo ""
}

base64_to_reserved_shell() {
    local input="$1"
    local bytes=$(echo "$input" | base64 -d 2>/dev/null | od -An -t u1 | tr -s ' ' ',')
    bytes=$(echo "$bytes" | sed 's/^,//;s/,$//;s/ //g')
    [[ -n "$bytes" ]] && echo "[$bytes]" || echo ""
}

save_credentials() {
    cat > "$CRED_FILE" <<EOF
PRIV_KEY="$1"
PUB_KEY="$2"
V4_ADDR="$3"
V6_ADDR="$4"
RESERVED="$5"
EOF
    echo -e "${GREEN}凭证已备份。${PLAIN}"
}

write_warp_config() {
    local priv="$1" pub="$2" v4="$3" v6="$4" res="$5"
    
    # [新增] 确保目录和基础文件存在，防止 jq 报错
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$(dirname "$CONFIG_FILE")"
        echo "{}" > "$CONFIG_FILE"
        echo -e "${YELLOW}已生成空配置文件: $CONFIG_FILE${PLAIN}"
    fi

    [[ ! "$v4" =~ "/" && -n "$v4" && "$v4" != "null" ]] && v4="${v4}/32"
    [[ ! "$v6" =~ "/" && -n "$v6" && "$v6" != "null" ]] && v6="${v6}/128"
    
    local addr_json="[]"
    [[ -n "$v4" && "$v4" != "null" ]] && addr_json=$(echo "$addr_json" | jq --arg ip "$v4" '. + [$ip]')
    [[ -n "$v6" && "$v6" != "null" ]] && addr_json=$(echo "$addr_json" | jq --arg ip "$v6" '. + [$ip]')
    
    check_env

    # 1. 生成 Endpoint
    local endpoint_json=$(jq -n \
        --arg priv "$priv" \
        --arg pub "$pub" \
        --argjson addr "$addr_json" \
        --argjson res "$res" \
        --arg ep_addr "$FINAL_EP_ADDR" \
        --argjson ep_port "$FINAL_EP_PORT" \
        '{ 
            "type": "wireguard", 
            "tag": "warp-endpoint", 
            "system": false,
            "address": $addr, 
            "private_key": $priv,
            "peers": [
                { 
                    "address": $ep_addr, 
                    "port": $ep_port, 
                    "public_key": $pub, 
                    "reserved": $res,
                    "allowed_ips": ["0.0.0.0/0", "::/0"]
                }
            ] 
        }')

    # 2. 生成 Bridge Outbound
    local outbound_json=$(jq -n '{ 
        "type": "direct", 
        "tag": "WARP", 
        "detour": "warp-endpoint" 
    }')

    echo -e "${YELLOW}正在应用 v3.6 Ultimate 架构配置...${PLAIN}"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    local TMP_CONF=$(mktemp)
    
    # 初始化
    jq 'if .endpoints == null then .endpoints = [] else . end | if .outbounds == null then .outbounds = [] else . end' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"

    # 清理旧配置
    jq 'del(.outbounds[] | select(.tag == "WARP" or .tag == "warp" or .type == "wireguard"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq 'del(.endpoints[] | select(.tag == "warp-endpoint" or .tag == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"

    # 注入
    jq --argjson ep "$endpoint_json" '.endpoints += [$ep]' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq --argjson out "$outbound_json" '.outbounds += [$out]' "$CONFIG_FILE" > "$TMP_CONF"
    
    if [[ $? -eq 0 && -s "$TMP_CONF" ]]; then
        mv "$TMP_CONF" "$CONFIG_FILE"
        echo -e "${GREEN}WARP 架构迁移与配置写入成功。${PLAIN}"
        restart_sb
    else
        echo -e "${RED}写入失败。${PLAIN}"; rm "$TMP_CONF"
    fi
}

register_warp() {
    ensure_python || return 1
    echo -e "${YELLOW}正在向 Cloudflare 注册账号...${PLAIN}"
    if ! command -v wg &> /dev/null; then apt install -y wireguard-tools || yum install -y wireguard-tools; fi
    local priv_key=$(wg genkey)
    local pub_key=$(echo "$priv_key" | wg pubkey)
    local install_id=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 22)
    local result=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "User-Agent: okhttp/3.12.1" -H "Content-Type: application/json; charset=UTF-8" \
        -d "{\"key\":\"${pub_key}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${install_id}:APA91bHuwEuLNj_${install_id}\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Android\",\"serial_number\":\"${install_id}\",\"locale\":\"zh_CN\"}")
    
    local v4=$(echo "$result" | jq -r '.config.interface.addresses.v4')
    local v6=$(echo "$result" | jq -r '.config.interface.addresses.v6')
    local client_id=$(echo "$result" | jq -r '.config.client_id')
    [[ "$v4" == "null" || -z "$v4" ]] && { echo -e "${RED}注册失败${PLAIN}"; return 1; }
    
    local res_json=$(python3 -c "import base64, json; d=base64.b64decode('$client_id'); print(json.dumps([x for x in d[0:3]]))" 2>/dev/null)
    save_credentials "$priv_key" "$pub_key" "$v4" "$v6" "$res_json"
    write_warp_config "$priv_key" "$pub_key" "$v4" "$v6" "$res_json"
}

manual_warp() {
    local def_priv="" def_pub="" def_v4="" def_v6="" def_res=""
    [[ -f "$CRED_FILE" ]] && { source "$CRED_FILE"; def_priv="$PRIV_KEY"; def_pub="$PUB_KEY"; def_v4="$V4_ADDR"; def_v6="$V6_ADDR"; def_res="$RESERVED"; }

    read -p "私钥 [默认: ${def_priv:0:10}...]: " priv_key
    priv_key=${priv_key:-$def_priv}
    [[ -z "$priv_key" ]] && { echo "私钥必填"; return; }
    
    read -p "对端公钥 [默认: 官方]: " peer_pub
    peer_pub=${peer_pub:-"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="}
    
    read -p "内网 IPv4 [默认: 172.16.0.2/32]: " v4
    v4=${v4:-"172.16.0.2/32"}
    
    read -p "内网 IPv6 [默认: $def_v6]: " v6
    v6=${v6:-$def_v6}
    
    read -p "Reserved [默认: $def_res]: " res_input
    res_input=${res_input:-$def_res}
    
    local res_json="[0,0,0]"
    if [[ "$res_input" =~ [0-9] ]]; then
        res_json=$(clean_reserved "$res_input")
    else
        res_json=$(base64_to_reserved_shell "$res_input")
        [[ -z "$res_json" ]] && { ensure_python; res_json=$(python3 -c "import base64, json; d=base64.b64decode('$res_input'); print(json.dumps([x for x in d]))" 2>/dev/null); }
    fi

    save_credentials "$priv_key" "$peer_pub" "$v4" "$v6" "$res_json"
    write_warp_config "$priv_key" "$peer_pub" "$v4" "$v6" "$res_json"
}

# ==========================================
# 3. 路由策略 (修正顺序BUG)
# ==========================================

ensure_warp_exists() {
    jq -e '.outbounds[]? | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null 2>&1 && return 0
    if [[ -f "$CRED_FILE" ]]; then
        read -p "未发现配置但存在凭证，是否恢复？[y/n]: " r
        [[ "$r" == "y" ]] && { source "$CRED_FILE"; write_warp_config "$PRIV_KEY" "$PUB_KEY" "$V4_ADDR" "$V6_ADDR" "$RESERVED"; return 0; }
    fi
    return 1
}

apply_routing_rule() {
    local rule_json="$1"
    echo -e "${YELLOW}正在应用路由规则...${PLAIN}"
    local TMP_CONF=$(mktemp)
    
    # 清空旧规则 (配置即最终态)
    jq 'del(.route.rules[] | select(.outbound == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    
    # 前置插入 (Prepend)
    jq --argjson r "$rule_json" '.route.rules = [$r] + .route.rules' "$CONFIG_FILE" > "$TMP_CONF"
    if [[ $? -eq 0 && -s "$TMP_CONF" ]]; then
        mv "$TMP_CONF" "$CONFIG_FILE"
        restart_sb
    else
        echo -e "${RED}规则应用失败。${PLAIN}"; rm "$TMP_CONF"
    fi
}

# [核心] 生成全能防环回规则 (Domain + IPv6 IP)
get_anti_loop_rule() {
    # 动态获取当前环境的 Endpoint IP (如果没跑 write_warp_config，则尝试重新检测)
    if [[ -z "$FINAL_EP_ADDR" ]]; then check_env >/dev/null; fi
    
    # 构造排除 IP 列表 (默认空)
    local ip_cidr="[]"
    # 如果检测到是 IPv6 Endpoint (包含冒号)，则加入 IP 排除列表
    if [[ "$FINAL_EP_ADDR" == *":"* ]]; then
        ip_cidr="[\"${FINAL_EP_ADDR}/128\"]"
    fi
    
    jq -n --argjson ip "$ip_cidr" '{ "domain": ["engage.cloudflareclient.com", "cloudflare.com"], "ip_cidr": $ip, "outbound": "direct" }'
}

mode_stream() {
    ensure_warp_exists || return
    apply_routing_rule "$(jq -n '{ "domain_suffix": ["netflix.com","nflxvideo.net","openai.com","ai.com","google.com","youtube.com"], "outbound": "WARP" }')"
}

mode_global() {
    ensure_warp_exists || return
    echo -e " a. 仅 IPv4  b. 仅 IPv6  c. 双栈全接管"
    read -p "选择模式: " sub
    
    # [关键修正] 倒序应用：先应用 WARP 规则 (被压到底部)，再应用 Anti-loop (置顶)
    
    local warp_rule=""
    case "$sub" in
        a) warp_rule=$(jq -n '{ "ip_version": 4, "outbound": "WARP" }') ;;
        b) warp_rule=$(jq -n '{ "ip_version": 6, "outbound": "WARP" }') ;;
        *) warp_rule=$(jq -n '{ "outbound": "WARP" }') ;;
    esac
    
    # 1. 应用 WARP 全局规则 (此时在 Index 0)
    apply_routing_rule "$warp_rule"
    
    # 2. 应用防环回规则 (此时 Anti-Loop 插入 Index 0，WARP 被挤到 Index 1)
    # 这样防环回优先级更高，防止握手流量死循环
    apply_routing_rule "$(get_anti_loop_rule)"
    
    echo -e "${GREEN}全局接管策略已应用 (防环回已置顶)。${PLAIN}"
}

mode_specific_node() {
    ensure_warp_exists || return
    local node_list=$(jq -r '.inbounds[] | "\(.tag) | \(.type)"' "$CONFIG_FILE" | nl)
    echo "$node_list"
    read -p "输入节点序号 (空格分隔): " selection
    local tags_json="[]"
    for num in $selection; do
        local tag=$(echo "$node_list" | sed -n "${num}p" | awk -F'|' '{print $1}' | awk '{print $2}')
        [[ -n "$tag" ]] && tags_json=$(echo "$tags_json" | jq --arg t "$tag" '. + [$t]')
    done
    apply_routing_rule "$(jq -n --argjson ib "$tags_json" '{ "inbound": $ib, "outbound": "WARP" }')"
}

uninstall_warp() {
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_un"
    local TMP_CONF=$(mktemp)
    jq 'del(.outbounds[] | select(.tag == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq 'del(.endpoints[] | select(.tag == "warp-endpoint"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    jq 'del(.route.rules[] | select(.outbound == "WARP"))' "$CONFIG_FILE" > "$TMP_CONF" && mv "$TMP_CONF" "$CONFIG_FILE"
    echo -e "${GREEN}WARP 卸载完成。${PLAIN}"; restart_sb
}

# ==========================================
# 4. 自动化与入口
# ==========================================

show_menu() {
    check_dependencies
    while true; do
        clear
        local st="${RED}未配置${PLAIN}"
        if [[ -f "$CONFIG_FILE" ]]; then
            jq -e '.outbounds[]? | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null 2>&1 && st="${GREEN}已配置 (v3.6 Ultimate)${PLAIN}"
        fi
        echo -e "================ Native WARP 管理中心 (Sing-box 1.10+) ================"
        echo -e " 当前配置状态: [$st]"
        echo -e "----------------------------------------------------"
        echo -e " 1. 配置 WARP 凭证 (自动/手动)"
        echo -e " 2. 查看当前凭证信息"
        echo -e " 3. 模式一：智能流媒体分流"
        echo -e " 4. 模式二：全局接管"
        echo -e " 5. 模式三：指定节点接管 (推荐)"
        echo -e " 7. 卸载 Native WARP"
        echo -e " 0. 返回上级菜单"
        read -p "请选择: " choice
        case "$choice" in
            1) echo -e "1. 自动; 2. 手动"; read -p "选: " t; [[ "$t" == "1" ]] && register_warp || manual_warp; read -p "回车继续..." ;;
            2) cat "$CRED_FILE" 2>/dev/null; read -p "回车继续..." ;;
            3) mode_stream; read -p "回车继续..." ;;
            4) mode_global; read -p "回车继续..." ;;
            5) mode_specific_node; read -p "回车继续..." ;;
            7) uninstall_warp; read -p "回车继续..." ;;
            0) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

auto_main() {
    echo -e "${GREEN}>>> [WARP-SB] 启动自动化部署 (v3.6)...${PLAIN}"
    check_dependencies
    if [[ -n "$WARP_PRIV_KEY" ]] && [[ -n "$WARP_IPV6" ]]; then
        save_credentials "$WARP_PRIV_KEY" "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=" "172.16.0.2/32" "$WARP_IPV6" "${WARP_RESERVED:-[0,0,0]}"
        write_warp_config "$WARP_PRIV_KEY" "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=" "172.16.0.2/32" "$WARP_IPV6" "${WARP_RESERVED:-[0,0,0]}"
    else
        register_warp
    fi

    local rule=""
    case "$WARP_MODE_SELECT" in
        1) rule=$(jq -n '{ "ip_version": 4, "outbound": "WARP" }') ;;
        2) rule=$(jq -n '{ "ip_version": 6, "outbound": "WARP" }') ;;
        3) [[ -n "$WARP_INBOUND_TAGS" ]] && rule=$(jq -n --argjson ib "$(echo "$WARP_INBOUND_TAGS" | jq -R 'split(",")')" '{ "inbound": $ib, "outbound": "WARP" }') ;;
        4) rule=$(jq -n '{ "outbound": "WARP" }') ;;
        *) rule=$(jq -n '{ "domain_suffix": ["netflix.com","openai.com","google.com","youtube.com"], "outbound": "WARP" }') ;;
    esac
    
    # [关键修复] 倒序应用：先应用策略规则，再应用防环回规则
    if [[ -n "$rule" ]]; then
        apply_routing_rule "$rule"
    fi
    
    # 防环回最后应用 (Prepend 后会在最顶端)
    apply_routing_rule "$(get_anti_loop_rule)"
    
    echo -e "${GREEN}>>> [WARP-SB] 自动化配置完成。${PLAIN}"
}

if [[ "$AUTO_SETUP" == "true" ]]; then auto_main; else show_menu; fi
