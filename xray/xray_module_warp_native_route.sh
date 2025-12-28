#!/bin/bash
#echo "v3.96"
#sleep 3
# ============================================================
#  Xray WARP Native Route 管理面板 (v3.96 Strict-Fix)
#  - 核心逻辑: 移植 Sing-box 的正则清洗算法，完美处理 Reserved 格式
#  - 关键修复: 仅修复 auto_main 映射逻辑，保留所有原版注释和结构
#  - 体验升级: 自动回填凭证 + IPv4 强制补全 + 智能格式化
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
# 0. 全局初始化
# ============================================================
CONFIG_FILE=""
PATHS=("/usr/local/etc/xray/config.json" "/etc/xray/config.json" "$HOME/xray/config.json")
for p in "${PATHS[@]}"; do [[ -f "$p" ]] && CONFIG_FILE="$p" && break; done

if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FILE="/usr/local/etc/xray/config.json"
fi

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
# 1. 基础功能函数
# ============================================================

check_env() {
    FINAL_ENDPOINT="engage.cloudflareclient.com:2408"
    FINAL_ENDPOINT_IP=""
    local ipv4_check=$(curl -4 -s -m 5 http://ip.sb 2>/dev/null)
    if [[ ! "$ipv4_check" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local ep_ip="2606:4700:d0::a29f:c001"
        FINAL_ENDPOINT="[${ep_ip}]:2408"
        FINAL_ENDPOINT_IP="${ep_ip}"
    fi
    export FINAL_ENDPOINT FINAL_ENDPOINT_IP
}

# [核心] 移植 Sing-box 的正则清洗逻辑
clean_reserved_str() {
    local input="$1"
    # 仅提取数字，过滤掉 [] , 空格 等所有杂质，并用逗号连接
    # 结果示例: 123,45,67
    local nums=$(echo "$input" | grep -oE '[0-9]+' | tr '\n' ',' | sed 's/,$//')
    echo "$nums"
}

register_warp() {
    echo -e "${YELLOW}正在连接 Cloudflare API 注册...${PLAIN}"
    if ! command -v wg &> /dev/null; then apt-get install -y wireguard-tools >/dev/null 2>&1; fi
    local priv_key=$(wg genkey)
    local pub_key=$(echo "$priv_key" | wg pubkey)
    local install_id=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 22)
    local result=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "User-Agent: okhttp/3.12.1" -H "Content-Type: application/json; charset=UTF-8" \
        -d "{\"key\":\"${pub_key}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${install_id}:APA91bHuwEuLNj_${install_id}\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Android\",\"serial_number\":\"${install_id}\",\"locale\":\"zh_CN\"}")
    
    local v4=$(echo "$result" | jq -r '.config.interface.addresses.v4')
    local v6=$(echo "$result" | jq -r '.config.interface.addresses.v6')
    local client_id=$(echo "$result" | jq -r '.config.client_id')
    
    if [[ "$v6" == "null" || -z "$v6" ]]; then echo -e "${RED}注册失败。${PLAIN}"; return 1; fi
    
    local res_str=$(python3 -c "import base64, json; d=base64.b64decode('$client_id'); print(','.join([str(x) for x in d[0:3]]))" 2>/dev/null)
    
    mkdir -p "$(dirname "$CRED_FILE")"
    echo "WARP_PRIV_KEY=\"$priv_key\"" > "$CRED_FILE"
    echo "WARP_IPV4=\"$v4/32\"" >> "$CRED_FILE"   
    echo "WARP_IPV6=\"$v6/128\"" >> "$CRED_FILE"  
    echo "WARP_RESERVED=\"$res_str\"" >> "$CRED_FILE"
    echo -e "${GREEN}注册成功！凭证已保存。${PLAIN}"
    
    export WG_KEY="$priv_key" WG_IPV4="$v4/32" WG_IPV6="$v6/128" WG_RESERVED="$res_str"
}

manual_warp() {
    local def_priv="" def_v4="" def_v6="" def_res=""
    if [[ -f "$CRED_FILE" ]]; then
        source "$CRED_FILE"
        def_priv="$WARP_PRIV_KEY"
        def_v4="$WARP_IPV4"
        def_v6="$WARP_IPV6"
        def_res="$WARP_RESERVED"
    fi

    # 默认值补全
    if [[ -z "$def_v4" ]]; then def_v4="172.16.0.2/32"; fi
    if [[ -z "$def_res" ]]; then def_res="0,0,0"; fi

    echo -e "${GRAY}------------------------------------------------${PLAIN}"
    echo -e "${GRAY}提示: 直接按回车将使用 [ ] 内的默认值${PLAIN}"
    
    local show_priv=""
    if [[ -n "$def_priv" ]]; then show_priv="${def_priv:0:6}......${def_priv: -4}"; fi
    read -p "私钥 ${GRAY}[默认: $show_priv]${PLAIN}: " k
    k=${k:-$def_priv}
    
    read -p "IPv4地址 ${GRAY}[默认: $def_v4]${PLAIN}: " v4
    v4=${v4:-$def_v4}
    
    read -p "IPv6地址 ${GRAY}[默认: $def_v6]${PLAIN}: " v6
    v6=${v6:-$def_v6}
    
    # 允许用户偷懒输入 [0,0,0]
    read -p "Reserved ${GRAY}[默认: $def_res]${PLAIN}: " r
    r=${r:-$def_res}
    
    # [核心] 使用正则逻辑清洗
    r=$(clean_reserved_str "$r")
    
    if [[ -z "$k" || -z "$v6" ]]; then
        echo -e "${RED}错误: 私钥和 IPv6 地址不能为空！${PLAIN}"
        return 1
    fi
    
    mkdir -p "$(dirname "$CRED_FILE")"
    echo "WARP_PRIV_KEY=\"$k\"" > "$CRED_FILE"
    echo "WARP_IPV4=\"$v4\"" >> "$CRED_FILE"
    echo "WARP_IPV6=\"$v6\"" >> "$CRED_FILE"
    echo "WARP_RESERVED=\"$r\"" >> "$CRED_FILE"
    
    export WG_KEY="$k" WG_IPV4="$v4" WG_IPV6="$v6" WG_RESERVED="$r"
    echo -e "${GREEN}凭证已更新并保存。${PLAIN}"
}

load_credentials() {
    if [[ -f "$CRED_FILE" ]]; then
        source "$CRED_FILE"
        if [[ -z "$WARP_IPV4" ]]; then
            echo -e "${RED}检测到旧凭证缺失关键参数 (IPv4)！${PLAIN}"
            echo -e "${YELLOW}请选择 '1. 配置 WARP 凭证' -> '手动录入' 进行补全。${PLAIN}"
            return 1
        fi
        export WG_KEY="$WARP_PRIV_KEY" WG_IPV4="$WARP_IPV4" WG_IPV6="$WARP_IPV6" WG_RESERVED="$WARP_RESERVED"
        return 0
    elif [[ -n "$WARP_PRIV_KEY" ]]; then
        export WG_KEY="$WARP_PRIV_KEY" WG_IPV4="$WARP_IPV4" WG_IPV6="$WARP_IPV6" WG_RESERVED=$(clean_reserved_str "$WARP_RESERVED")
        return 0
    else
        return 1
    fi
}

ensure_warp_exists() {
    if [[ ! -f "$CONFIG_FILE" ]]; then echo -e "${RED}错误: 找不到 config.json${PLAIN}"; return 1; fi
    if ! load_credentials; then 
        echo -e "${RED}错误: 凭证未就绪。${PLAIN}"
        return 1
    fi
    check_env
    return 0
}

# ============================================================
# 2. 核心注入逻辑
# ============================================================

apply_routing_rule() {
    local rule_json="$1"
    echo -e "${YELLOW}正在应用路由规则...${PLAIN}"
    cp "$CONFIG_FILE" "$BACKUP_FILE"

    jq '.outbounds |= map(select(.tag != "warp-out")) | .routing.rules |= map(select(.outboundTag != "warp-out"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # [Xray 原生格式] 手动加上 []，要求变量 WG_RESERVED 必须是纯数字逗号分隔
    local res_json="[${WG_RESERVED}]"
    local addr_json="[\"$WG_IPV6\"]"
    if [[ -n "$WG_IPV4" && "$WG_IPV4" != "null" ]]; then
        addr_json="[\"$WG_IPV6\",\"$WG_IPV4\"]"
    fi
    
    jq --arg key "$WG_KEY" --argjson addr "$addr_json" --argjson res "$res_json" --arg ep "$FINAL_ENDPOINT" \
       '.outbounds += [{ 
            "tag": "warp-out", 
            "protocol": "wireguard", 
            "settings": { "secretKey": $key, "address": $addr, "peers": [{ "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "endpoint": $ep, "keepAlive": 15 }], "reserved": $res, "mtu": 1280 } 
       }]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    local direct_tag="direct"
    if ! jq -e '.outbounds[] | select(.tag == "direct")' "$CONFIG_FILE" >/dev/null 2>&1; then
        if jq -e '.outbounds[] | select(.tag == "freedom")' "$CONFIG_FILE" >/dev/null 2>&1; then direct_tag="freedom"; fi
    fi
    local anti_loop_ips="[]"
    [[ -n "$FINAL_ENDPOINT_IP" ]] && anti_loop_ips="[\"${FINAL_ENDPOINT_IP}\"]"
    local anti_loop=$(jq -n --argjson i "$anti_loop_ips" --arg tag "$direct_tag" '{ "type": "field", "domain": ["engage.cloudflareclient.com", "cloudflare.com"], "ip": $i, "outboundTag": $tag }')

    if [[ -n "$rule_json" ]]; then
         jq --argjson r1 "$anti_loop" --argjson r2 "$rule_json" '.routing.rules = [$r1, $r2] + .routing.rules' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    else
         jq --argjson r1 "$anti_loop" '.routing.rules = [$r1] + .routing.rules' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi

    if systemctl restart xray; then
        echo -e "${GREEN}策略已更新，Xray 重启成功。${PLAIN}"
    else
        echo -e "${RED}Xray 重启失败！正在还原配置...${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        systemctl restart xray
    fi
}

# ============================================================
# 3. 模式逻辑
# ============================================================

mode_stream() {
    ensure_warp_exists || return
    apply_routing_rule "$(jq -n '{ "type": "field", "domain": ["geosite:netflix","geosite:disney","geosite:openai","geosite:google","geosite:youtube"], "outboundTag": "warp-out" }')"
}

mode_global() {
    ensure_warp_exists || return
    echo -e " a. 仅 IPv4  b. 仅 IPv6  c. 双栈全接管"
    read -p "选择模式: " sub
    local warp_rule=""
    case "$sub" in
        a) warp_rule=$(jq -n '{ "type": "field", "network": "tcp,udp", "ip": ["0.0.0.0/0"], "outboundTag": "warp-out" }') ;;
        b) warp_rule=$(jq -n '{ "type": "field", "network": "tcp,udp", "ip": ["::/0"], "outboundTag": "warp-out" }') ;;
        *) warp_rule=$(jq -n '{ "type": "field", "network": "tcp,udp", "outboundTag": "warp-out" }') ;;
    esac
    apply_routing_rule "$warp_rule"
    echo -e "${GREEN}全局接管策略已应用。${PLAIN}"
}

mode_specific_node() {
    ensure_warp_exists || return
    echo -e "${YELLOW}正在读取节点列表...${PLAIN}"
    local node_list=$(jq -r '.inbounds[] | "\(.tag) | \(.protocol)"' "$CONFIG_FILE" | grep -v "api" | nl)
    if [[ -z "$node_list" ]]; then echo -e "${RED}无有效入站节点。${PLAIN}"; return; fi
    echo "$node_list"
    read -p "输入节点序号 (空格分隔): " selection
    local tags_json="[]"
    for num in $selection; do
        # [v3.6 修复保留] 提取第2列 (Tag) 而非第1列 (序号)
        local tag=$(echo "$node_list" | sed -n "${num}p" | awk -F'|' '{print $1}' | awk '{print $2}')
        [[ -n "$tag" ]] && tags_json=$(echo "$tags_json" | jq --arg t "$tag" '. + [$t]')
    done
    [[ "$tags_json" == "[]" ]] && return
    echo -e "${GREEN}选中节点: $tags_json${PLAIN}"
    apply_routing_rule "$(jq -n --argjson ib "$tags_json" '{ "type": "field", "inboundTag": $ib, "outboundTag": "warp-out" }')"
}

uninstall_warp() {
    echo -e "${YELLOW}正在卸载 WARP 配置...${PLAIN}"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    jq '.outbounds |= map(select(.tag != "warp-out")) | .routing.rules |= map(select(.outboundTag != "warp-out"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    systemctl restart xray
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

# ============================================================
# 4. 菜单界面
# ============================================================

show_menu() {
    check_dependencies
    while true; do
        clear
        local st="${RED}未配置${PLAIN}"
        local has_cred=false
        
        # 检查是否有有效凭证文件（用于额外提示）
        if [[ -f "$CRED_FILE" ]] && grep -q "WARP_PRIV_KEY" "$CRED_FILE" && grep -q "WARP_IPV6" "$CRED_FILE"; then
            has_cred=true
        fi
        
        # 核心判断：以 warp-out 是否存在为准
        if [[ -f "$CONFIG_FILE" ]] && jq -e '.outbounds[]? | select(.tag == "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
            st="${GREEN}已配置（WARP 运行中）${PLAIN}"
        elif $has_cred; then
            # 特殊情况：有凭证但没注入规则 → 提示用户可以快速部署
            st="${YELLOW}凭证已保存（未启用 WARP）${PLAIN}"
        fi

        echo -e "================ Xray Native WARP 管理面板 ================"
        echo -e " 当前状态: [$st]"
        echo -e "----------------------------------------------------"
        echo -e " 1. 配置 WARP 凭证 (自动/手动)"
        echo -e " 2. 查看当前凭证信息"
        echo -e " 3. 模式一：流媒体分流 (推荐)"
        echo -e " 4. 模式二：全局接管"
        echo -e " 5. 模式三：指定节点接管"
        echo -e " 7. 卸载/清除 WARP 配置"
        echo -e " 0. 返回上级菜单"
        echo ""
        read -p "请选择: " choice
        
        case "$choice" in
            1) 
                echo -e "1. 自动注册  2. 手动录入 (支持旧凭证回填)"
                read -p "选: " t
                [[ "$t" == "1" ]] && register_warp || manual_warp
                read -p "按回车继续..." 
                ;;
            2) 
                if load_credentials; then
                    echo -e "PrivKey: $WG_KEY"
                    echo -e "IPv4: $WG_IPV4"
                    echo -e "IPv6: $WG_ADDR"
                    echo -e "Reserved: $WG_RESERVED"
                else
                    echo -e "${RED}未找到凭证。${PLAIN}"
                fi
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

# ============================================================
# 5. 入口逻辑
# ============================================================

auto_main() {
    echo -e "${GREEN}>>> [Auto] 正在应用 WARP 配置...${PLAIN}"
    if [[ -z "$WARP_PRIV_KEY" ]]; then register_warp; fi
    ensure_warp_exists || exit 1
    
    local rule=""
    # [核心修复] 对齐 auto_deploy.sh 的参数逻辑 (v3.96 Fix)
    case "$WARP_MODE_SELECT" in
        1) rule=$(jq -n '{ "type": "field", "network": "tcp,udp", "ip": ["0.0.0.0/0"], "outboundTag": "warp-out" }') ;;
        2) rule=$(jq -n '{ "type": "field", "network": "tcp,udp", "ip": ["::/0"], "outboundTag": "warp-out" }') ;;
        3) [[ -n "$WARP_INBOUND_TAGS" ]] && rule=$(jq -n --argjson t "$(echo "$WARP_INBOUND_TAGS" | jq -R 'split(",")')" '{ "type": "field", "inboundTag": $t, "outboundTag": "warp-out" }') ;;
        4) rule=$(jq -n '{ "type": "field", "network": "tcp,udp", "outboundTag": "warp-out" }') ;;
        *) rule=$(jq -n '{ "type": "field", "domain": ["geosite:netflix","geosite:disney","geosite:openai","geosite:google","geosite:youtube"], "outboundTag": "warp-out" }') ;;
    esac
    apply_routing_rule "$rule"
}

if [[ "$AUTO_SETUP" == "true" ]]; then
    check_dependencies
    auto_main
else
    show_menu
fi
