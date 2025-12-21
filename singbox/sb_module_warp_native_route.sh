#!/bin/bash

# ============================================================
#  Sing-box Native WARP 管理模块 (SB-Commander v4.0)
#  - 核心: WireGuard 原生出站 / 动态路由管理
#  - 特性: 智能路径 / 延迟加载Python / 纯Shell解码 / 纯净分流
#  - 更新: 支持“指定节点接管” (模式三)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
GRAY='\033[0;37m'

# ==========================================
# 1. 环境初始化与依赖检查
# ==========================================

# 智能查找 Sing-box 配置文件路径
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then
        CONFIG_FILE="$p"
        break
    fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 未检测到 config.json 配置文件！${PLAIN}"
    echo -e "请确认 Sing-box 是否已安装，或手动指定路径。"
    exit 1
fi

# 检查基础依赖
check_dependencies() {
    local missing=0
    if ! command -v jq &> /dev/null; then echo -e "${RED}缺失工具: jq${PLAIN}"; missing=1; fi
    if ! command -v curl &> /dev/null; then echo -e "${RED}缺失工具: curl${PLAIN}"; missing=1; fi
    if ! command -v od &> /dev/null; then echo -e "${GRAY}提示: 建议安装 od 工具 (用于免 Python 解码)${PLAIN}"; fi
    
    if [[ $missing -eq 1 ]]; then
        echo -e "${YELLOW}正在安装基础依赖...${PLAIN}"
        if [ -x "$(command -v apt)" ]; then
            apt update && apt install -y jq curl
        elif [ -x "$(command -v yum)" ]; then
            yum install -y jq curl
        fi
    fi
}

# 按需安装 Python
ensure_python() {
    if ! command -v python3 &> /dev/null; then
        echo -e "${YELLOW}该功能需要 Python3 支持，正在安装...${PLAIN}"
        if [ -x "$(command -v apt)" ]; then apt update && apt install -y python3; fi
        if [ -x "$(command -v yum)" ]; then yum install -y python3; fi
        
        if ! command -v python3 &> /dev/null; then
            echo -e "${RED}Python3 安装失败，无法继续。${PLAIN}"
            return 1
        fi
    fi
    return 0
}

# 重启 Sing-box
restart_sb() {
    echo -e "${YELLOW}重启 Sing-box 服务...${PLAIN}"
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
        echo -e "${RED}服务重启失败，请检查配置文件格式！${PLAIN}"
        echo -e "配置文件路径: $CONFIG_FILE"
    fi
}

# ==========================================
# 2. 核心功能：WARP 账号逻辑
# ==========================================

# Shell Base64 解码
base64_to_reserved_shell() {
    local input="$1"
    local bytes=$(echo "$input" | base64 -d 2>/dev/null | od -An -t u1 | tr -s ' ' ',')
    bytes=$(echo "$bytes" | sed 's/^,//;s/,$//;s/ //g')
    if [ -n "$bytes" ]; then echo "[$bytes]"; else echo ""; fi
}

# 注册 WARP
register_warp() {
    ensure_python || return 1
    echo -e "${YELLOW}正在连接 Cloudflare API 注册免费账号...${PLAIN}"
    
    if ! command -v wg &> /dev/null; then
        echo -e "${YELLOW}安装 wireguard-tools 用于生成密钥...${PLAIN}"
        if [ -x "$(command -v apt)" ]; then apt install -y wireguard-tools; fi
        if [ -x "$(command -v yum)" ]; then yum install -y wireguard-tools; fi
    fi

    local priv_key=$(wg genkey)
    local pub_key=$(echo "$priv_key" | wg pubkey)
    local install_id=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 22)
    
    local result=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "User-Agent: okhttp/3.12.1" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -d "{\"key\":\"${pub_key}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${install_id}:APA91bHuwEuLNj_${install_id}\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Android\",\"serial_number\":\"${install_id}\",\"locale\":\"zh_CN\"}")
    
    local v4=$(echo "$result" | jq -r '.config.interface.addresses.v4')
    local v6=$(echo "$result" | jq -r '.config.interface.addresses.v6')
    local peer_pub=$(echo "$result" | jq -r '.config.peers[0].public_key')
    local client_id=$(echo "$result" | jq -r '.config.client_id')
    
    if [[ "$v4" == "null" || -z "$v4" ]]; then echo -e "${RED}注册失败。${PLAIN}"; return 1; fi
    
    local reserved_json=$(python3 -c "import base64, json; decoded = base64.b64decode('$client_id'); print(json.dumps([x for x in decoded[0:3]]))" 2>/dev/null)
    
    write_warp_config "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
}

# 手动录入
manual_warp() {
    echo -e "${GREEN}手动录入 WARP 信息${PLAIN}"
    read -p "私钥 (Private Key): " priv_key
    read -p "公钥 (Peer Public Key, 留空默认): " peer_pub
    [[ -z "$peer_pub" ]] && peer_pub="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    
    read -p "本机 IPv4 (如 172.16.0.2/32): " v4
    read -p "本机 IPv6 (如 2606:4700:...): " v6
    read -p "Reserved (Base64 或 [1,2,3]): " res_input
    
    local reserved_json="[]"
    if [[ "$res_input" == *","* && "$res_input" != *"["* ]]; then
        reserved_json="[$res_input]"
    elif [[ "$res_input" == *"["* ]]; then
        reserved_json="$res_input"
    else
        reserved_json=$(base64_to_reserved_shell "$res_input")
        if [[ -z "$reserved_json" ]]; then
             ensure_python
             reserved_json=$(python3 -c "import base64, json; decoded = base64.b64decode('$res_input'); print(json.dumps([x for x in decoded]))" 2>/dev/null)
        fi
    fi
    
    write_warp_config "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
}

# 写入配置
write_warp_config() {
    local priv="$1"
    local pub="$2"
    local v4="$3"
    local v6="$4"
    local res="$5"
    
    local addr_json="[]"
    if [[ -n "$v4" && "$v4" != "null" ]]; then addr_json=$(echo "$addr_json" | jq --arg ip "$v4" '. + [$ip]'); fi
    if [[ -n "$v6" && "$v6" != "null" ]]; then addr_json=$(echo "$addr_json" | jq --arg ip "$v6" '. + [$ip]'); fi
    
    local warp_json=$(jq -n \
        --arg priv "$priv" --arg pub "$pub" --argjson addr "$addr_json" --argjson res "$res" \
        '{ "type": "wireguard", "tag": "WARP", "server": "engage.cloudflareclient.com", "server_port": 2408, "local_address": $addr, "private_key": $priv, "peers": [{ "server": "engage.cloudflareclient.com", "server_port": 2408, "public_key": $pub, "reserved": $res }] }')

    echo -e "${YELLOW}正在写入配置...${PLAIN}"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    # 删除旧的
    tmp=$(jq 'del(.outbounds[] | select(.tag == "WARP"))' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    # 添加新的
    tmp=$(jq --argjson new "$warp_json" '.outbounds += [$new]' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    
    echo -e "${GREEN}WARP 节点配置完成。${PLAIN}"
    restart_sb
}

# ==========================================
# 3. 路由规则管理 (Modes)
# ==========================================

# 模式一 & 二通用函数
apply_routing_rule() {
    local rule_json="$1"
    echo -e "${YELLOW}正在应用路由规则...${PLAIN}"
    local tmp=$(jq --argjson r "$rule_json" '.route.rules = [$r] + .route.rules' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    restart_sb
}

# 模式一：流媒体分流
mode_stream() {
    echo -e "请选择规则匹配模式:"
    echo -e "  1. ${GREEN}域名列表 (Domain List)${PLAIN} - [推荐] 稳定，不依赖 Geosite"
    echo -e "  2. ${YELLOW}Geosite 规则集${PLAIN}       - 需确保本地有 geosite.db"
    read -p "请选择 (1/2): " mode
    
    local rule=""
    if [[ "$mode" == "2" ]]; then
        rule=$(jq -n '{ "geosite": ["netflix","openai","disney","google","youtube"], "outbound": "WARP" }')
    else
        rule=$(jq -n '{ "domain_suffix": ["netflix.com","nflxvideo.net","openai.com","ai.com","disney.com","disneyplus.com","google.com","youtube.com"], "outbound": "WARP" }')
    fi
    apply_routing_rule "$rule"
}

# 模式二：全局/IP接管
mode_global() {
    echo -e " a. 仅接管 IPv4"
    echo -e " b. 仅接管 IPv6"
    echo -e " c. 双栈全接管"
    read -p "选择: " sub
    local rule=""
    case "$sub" in
        a) rule=$(jq -n '{ "ip_version": 4, "outbound": "WARP" }') ;;
        b) rule=$(jq -n '{ "ip_version": 6, "outbound": "WARP" }') ;;
        c) rule=$(jq -n '{ "network": ["tcp","udp"], "outbound": "WARP" }') ;;
    esac
    apply_routing_rule "$rule"
}

# 模式三：指定节点接管 (修复的核心部分)
mode_specific_node() {
    if [[ ! -f "$CONFIG_FILE" ]]; then echo -e "${RED}无配置文件${PLAIN}"; return; fi
    
    echo -e "${SKYBLUE}正在读取 Sing-box 入站节点...${PLAIN}"
    # 提取 tag, type, listen_port (如果有)
    # Sing-box 的 inbounds 结构多样，这里尝试通用的提取
    local node_list=$(jq -r '.inbounds[] | "\(.tag) | \(.type) | \(.listen_port // .listen // "N/A")"' "$CONFIG_FILE" | nl -w 2 -s " ")
    
    if [[ -z "$node_list" ]]; then
        echo -e "${RED}未找到任何入站节点。${PLAIN}"; return
    fi

    echo -e "------------------------------------------------"
    echo -e "序号 | Tag (标签)   | 类型      | 端口/监听"
    echo -e "------------------------------------------------"
    # 简单的格式化输出
    echo "$node_list"
    echo -e "------------------------------------------------"
    echo -e "${YELLOW}请输入要走 WARP 的节点序号 (支持多选，空格分隔，如: 1 3)${PLAIN}"
    read -p "选择: " selection

    local selected_tags_json="[]"
    
    for num in $selection; do
        local raw_line=$(echo "$node_list" | sed -n "${num}p")
        # 提取第一列的 Tag (awk 默认空格分隔，这里由于上面的格式，tag 是第3列，序号是1，|是2)
        # jq output format: "tag | type | port" -> nl: " 1 tag | type | port"
        local tag=$(echo "$raw_line" | awk -F'|' '{print $1}' | awk '{print $2}')
        
        if [[ -n "$tag" ]]; then
            selected_tags_json=$(echo "$selected_tags_json" | jq --arg t "$tag" '. + [$t]')
            echo -e "已选择: ${GREEN}$tag${PLAIN}"
        fi
    done

    # 生成规则: { "inbound": ["tag1", "tag2"], "outbound": "WARP" }
    local rule=$(jq -n --argjson ib "$selected_tags_json" '{ "inbound": $ib, "outbound": "WARP" }')
    
    apply_routing_rule "$rule"
}

# 卸载 WARP
uninstall_warp() {
    echo -e "${YELLOW}正在清理...${PLAIN}"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_uninstall"
    
    local tmp=$(jq 'del(.outbounds[] | select(.tag == "WARP"))' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    
    tmp=$(jq 'del(.route.rules[] | select(.outbound == "WARP"))' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    
    restart_sb
}

# ==========================================
# 4. 菜单逻辑
# ==========================================

show_menu() {
    check_dependencies
    while true; do
        clear
        local status_text="${RED}未配置${PLAIN}"
        if jq -e '.outbounds[] | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null; then
            status_text="${GREEN}已配置${PLAIN}"
        fi
        
        echo -e "================ Native WARP 配置向导 (Sing-box) ================"
        echo -e " 配置文件: ${SKYBLUE}$CONFIG_FILE${PLAIN}"
        echo -e " 凭证状态: [$status_text]"
        echo -e "----------------------------------------------------"
        echo -e " [基础账号]"
        echo -e " 1. 注册/配置 WARP 凭证 (自动获取 或 手动输入)"
        echo -e " 2. 查看当前凭证信息 (配置文件中可见)"
        echo -e ""
        echo -e " [策略模式 - 单选]"
        echo -e " 3. ${SKYBLUE}模式一：智能流媒体分流 (推荐)${PLAIN}"
        echo -e "    ${GRAY}(Netflix/Disney+/OpenAI/Google -> WARP)${PLAIN}"
        echo -e ""
        echo -e " 4. ${SKYBLUE}模式二：全局接管 (隐藏 IP)${PLAIN}"
        echo -e "    ${GRAY}---> 拯救 Google 验证码 / 单栈变双栈${PLAIN}"
        echo -e ""
        echo -e " 5. ${SKYBLUE}模式三：指定节点接管 (多节点共存)${PLAIN}"
        echo -e "    ${GRAY}---> 选择特定端口强制走 WARP 出口${PLAIN}"
        echo -e ""
        echo -e " [维护]"
        echo -e " 7. ${RED}禁用/卸载 Native WARP (恢复直连)${PLAIN}"
        echo -e " 0. 返回上级菜单"
        echo -e "===================================================="
        read -p "请输入选项: " choice
        
        case "$choice" in
            1)
                echo -e "  1. 自动注册 (需 Python)"
                echo -e "  2. 手动录入 (Base64/CSV)"
                read -p "  请选择: " reg_type
                if [[ "$reg_type" == "1" ]]; then register_warp; else manual_warp; fi
                read -p "按回车继续..."
                ;;
            2)
                echo -e "请查看配置文件中的 WARP outbound 字段。"
                read -p "按回车继续..."
                ;;
            3) mode_stream; read -p "按回车继续..." ;;
            4) mode_global; read -p "按回车继续..." ;;
            5) mode_specific_node; read -p "按回车继续..." ;;
            7) uninstall_warp; read -p "按回车继续..." ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

show_menu
