#!/bin/bash

# ============================================================
#  Sing-box Native WARP 管理模块 (SB-Commander v3.9)
#  - 核心: WireGuard 原生出站 / 动态路由管理
#  - 特性: 智能路径 / 自动计算 Reserved / 双模式规则 / 纯净分流
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

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

# 检查必要工具
check_dependencies() {
    local missing=0
    if ! command -v jq &> /dev/null; then echo -e "${RED}缺失工具: jq${PLAIN}"; missing=1; fi
    if ! command -v curl &> /dev/null; then echo -e "${RED}缺失工具: curl${PLAIN}"; missing=1; fi
    if ! command -v python3 &> /dev/null; then echo -e "${RED}缺失工具: python3 (用于计算 Reserved)${PLAIN}"; missing=1; fi
    
    if [[ $missing -eq 1 ]]; then
        echo -e "${YELLOW}正在安装依赖...${PLAIN}"
        if [ -x "$(command -v apt)" ]; then
            apt update && apt install -y jq curl python3
        elif [ -x "$(command -v yum)" ]; then
            yum install -y jq curl python3
        fi
    fi
}

# 重启 Sing-box
restart_sb() {
    echo -e "${YELLOW}重启 Sing-box 服务...${PLAIN}"
    # 尝试多种重启方式
    if systemctl list-unit-files | grep -q sing-box; then
        systemctl restart sing-box
    else
        # 兼容非 systemd 或 docker 环境 (简单的 kill 重启)
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
# 2. 核心功能：WARP 账号获取与计算
# ==========================================

# 计算 Reserved 值 (Python 辅助)
# 输入: Client ID (Base64)
# 输出: JSON 数组 [x, y, z]
get_reserved_array() {
    local client_id="$1"
    python3 -c "import base64, json; decoded = base64.b64decode('$client_id'); print(json.dumps([x for x in decoded[0:3]]))" 2>/dev/null
}

# 注册/生成 WARP 账号
register_warp() {
    echo -e "${YELLOW}正在连接 Cloudflare API 注册免费账号...${PLAIN}"
    
    # 1. 生成 Key
    # 如果没有 wg 命令，尝试用 sing-box 生成，或者直接用 python/openssl (为了通用性这里简化，假设 API 会返回 Key 或者脚本自建)
    # Cloudflare API 注册实际上由客户端生成 Key，这里我们模拟 wg-tools 的行为
    # 为了不依赖 wireguard-tools，我们直接利用 API 注册一个新的 user，API 会返回 config
    # *注意*: 实际上标准流程是: 本地生成 Key -> 发送 PubKey 给 API -> API 返回分配的 IP 和 Reserved
    
    # 既然为了减少依赖，我们使用一段 python 代码生成 Curve25519 密钥对 (如果没有 wg 命令)
    if ! command -v wg &> /dev/null; then
        # 简单处理：如果没有 wg，我们尝试直接请求 API 让它分配 (某些旧接口支持) 或者提示安装
        echo -e "${YELLOW}提示: 未检测到 wireguard-tools，尝试安装以生成密钥...${PLAIN}"
        if [ -x "$(command -v apt)" ]; then apt install -y wireguard-tools; fi
        if [ -x "$(command -v yum)" ]; then yum install -y wireguard-tools; fi
    fi
    
    if ! command -v wg &> /dev/null; then
        echo -e "${RED}错误: 无法生成密钥，请手动安装 wireguard-tools (apt install wireguard-tools)${PLAIN}"
        return 1
    fi

    local priv_key=$(wg genkey)
    local pub_key=$(echo "$priv_key" | wg pubkey)
    local install_id=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 22)
    
    # 2. 发送注册请求
    local result=$(curl -sX POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "User-Agent: okhttp/3.12.1" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -d "{\"key\":\"${pub_key}\",\"install_id\":\"${install_id}\",\"fcm_token\":\"${install_id}:APA91bHuwEuLNj_${install_id}\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Android\",\"serial_number\":\"${install_id}\",\"locale\":\"zh_CN\"}")
    
    # 3. 提取信息
    local v4=$(echo "$result" | jq -r '.config.interface.addresses.v4')
    local v6=$(echo "$result" | jq -r '.config.interface.addresses.v6')
    local peer_pub=$(echo "$result" | jq -r '.config.peers[0].public_key')
    local client_id=$(echo "$result" | jq -r '.config.client_id')
    
    if [[ "$v4" == "null" || -z "$v4" ]]; then
        echo -e "${RED}注册失败，API 未返回有效 IP。请重试。${PLAIN}"
        return 1
    fi
    
    # 4. 计算 Reserved
    local reserved_json=$(get_reserved_array "$client_id")
    
    echo -e "${GREEN}注册成功!${PLAIN}"
    write_warp_config "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
}

# 手动录入账号
manual_warp() {
    echo -e "===================================================="
    echo -e "请准备好你的 WARP 账号信息 (WireGuard 格式)"
    echo -e "===================================================="
    
    read -p "私钥 (Private Key): " priv_key
    read -p "公钥 (Peer Public Key, 留空默认为官方Key): " peer_pub
    if [[ -z "$peer_pub" ]]; then
        peer_pub="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    fi
    
    read -p "本机 IPv4 (如 172.16.0.2/32, 留空不填): " v4
    read -p "本机 IPv6 (如 2606:4700:..., 留空不填): " v6
    
    # 关键：手动输入的 Reserved 可能是 Base64 (Xray常用) 或 CSV
    echo -e "Reserved 值 (非常重要!)"
    echo -e " - 格式 A (Base64): c+kIBA=="
    echo -e " - 格式 B (CSV): 115,233,8"
    read -p "请输入 Reserved: " res_input
    
    local reserved_json="[]"
    
    # 简单的判断逻辑：如果包含逗号，假设是 CSV；否则假设是 Base64
    if [[ "$res_input" == *","* ]]; then
        # CSV 转 JSON 数组
        reserved_json="[$res_input]"
    else
        # Base64 转 JSON 数组 (利用 Python)
        reserved_json=$(python3 -c "import base64, json; decoded = base64.b64decode('$res_input'); print(json.dumps([x for x in decoded]))" 2>/dev/null)
    fi
    
    if [[ "$reserved_json" == "[]" || -z "$reserved_json" ]]; then
         echo -e "${RED}Reserved 解析失败，使用默认空值 (可能导致连接失败)${PLAIN}"
    fi

    write_warp_config "$priv_key" "$peer_pub" "$v4" "$v6" "$reserved_json"
}

# 写入配置文件 (Config.json)
write_warp_config() {
    local priv="$1"
    local pub="$2"
    local v4="$3"
    local v6="$4"
    local res="$5"
    
    # 构建 local_address 数组
    local addr_json="[]"
    if [[ -n "$v4" && "$v4" != "null" ]]; then
        addr_json=$(echo "$addr_json" | jq --arg ip "$v4" '. + [$ip]')
    fi
    if [[ -n "$v6" && "$v6" != "null" ]]; then
        addr_json=$(echo "$addr_json" | jq --arg ip "$v6" '. + [$ip]')
    fi
    
    # 构建 Outbound JSON
    local warp_json=$(jq -n \
        --arg priv "$priv" \
        --arg pub "$pub" \
        --argjson addr "$addr_json" \
        --argjson res "$res" \
        '{
            "type": "wireguard",
            "tag": "WARP",
            "server": "engage.cloudflareclient.com",
            "server_port": 2408,
            "local_address": $addr,
            "private_key": $priv,
            "peers": [
                {
                    "server": "engage.cloudflareclient.com",
                    "server_port": 2408,
                    "public_key": $pub,
                    "reserved": $res
                }
            ]
        }')

    echo -e "${YELLOW}正在写入配置文件...${PLAIN}"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    
    # 1. 删除旧 WARP
    tmp=$(jq 'del(.outbounds[] | select(.tag == "WARP"))' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    
    # 2. 添加新 WARP
    tmp=$(jq --argjson new "$warp_json" '.outbounds += [$new]' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    
    echo -e "${GREEN}WARP 节点已写入配置。${PLAIN}"
    restart_sb
}

# ==========================================
# 3. 路由规则管理
# ==========================================

add_rule() {
    local name="$1"     # 显示名称
    local domains="$2"  # 域名列表字符串 "a.com b.com"
    local geosite="$3"  # Geosite Tag "netflix"
    
    echo -e "------------------------------------------------"
    echo -e "正在添加规则: ${SKYBLUE}$name${PLAIN} -> WARP"
    echo -e "------------------------------------------------"
    echo -e "请选择规则匹配模式:"
    echo -e "  1. ${GREEN}域名列表 (Domain List)${PLAIN} - [推荐] 稳定，不依赖 Geosite 文件"
    echo -e "  2. ${YELLOW}Geosite 规则集${PLAIN}       - 需确保本地有 geosite.db 或 rule_set"
    read -p "请选择 (1/2): " mode
    
    local new_rule=""
    
    if [[ "$mode" == "2" ]]; then
        # Geosite 模式
        # Sing-box 1.8+ 推荐使用 rule_set，这里简化兼容 tag 模式，
        # 如果用户没有配置 rule_set，这可能会无效。但为了脚本简洁，我们生成标准的 geosite 匹配。
        echo -e "${YELLOW}提示: 请确保你的 Sing-box 已配置 geosite 资源文件。${PLAIN}"
        new_rule=$(jq -n --arg g "$geosite" '{ "geosite": [$g], "outbound": "WARP" }')
    else
        # Domain List 模式 (将空格分隔的字符串转为 JSON 数组)
        # 使用 jq split 生成数组
        new_rule=$(jq -n --arg d "$domains" '{ "domain_suffix": ($d | split(" ")), "outbound": "WARP" }')
    fi
    
    # 插入规则到最前
    echo -e "${YELLOW}正在应用规则...${PLAIN}"
    local tmp=$(jq --argjson r "$new_rule" '.route.rules = [$r] + .route.rules' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    
    echo -e "${GREEN}规则添加成功。${PLAIN}"
    restart_sb
}

# 全局接管
set_global() {
    local type="$1" # v4, v6, dual
    
    local rule=""
    case "$type" in
        v4)
            echo -e "${YELLOW}设置: 优先 IPv4 流量走 WARP...${PLAIN}"
            rule=$(jq -n '{ "ip_version": 4, "outbound": "WARP" }')
            ;;
        v6)
            echo -e "${YELLOW}设置: 优先 IPv6 流量走 WARP...${PLAIN}"
            rule=$(jq -n '{ "ip_version": 6, "outbound": "WARP" }')
            ;;
        dual)
            echo -e "${YELLOW}设置: 全局流量 (0.0.0.0/0, ::/0) 走 WARP...${PLAIN}"
            rule=$(jq -n '{ "network": ["tcp","udp"], "outbound": "WARP" }')
            ;;
    esac
    
    local tmp=$(jq --argjson r "$rule" '.route.rules = [$r] + .route.rules' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    
    echo -e "${GREEN}全局规则已应用。${PLAIN}"
    restart_sb
}

# 移除 WARP 相关
uninstall_warp() {
    echo -e "${YELLOW}正在清理 WARP 配置与路由规则...${PLAIN}"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_uninstall"
    
    # 删除 outbound
    local tmp=$(jq 'del(.outbounds[] | select(.tag == "WARP"))' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    
    # 删除所有指向 WARP 的路由规则
    tmp=$(jq 'del(.route.rules[] | select(.outbound == "WARP"))' "$CONFIG_FILE")
    echo "$tmp" > "$CONFIG_FILE"
    
    echo -e "${GREEN}清理完成。已自动重启服务。${PLAIN}"
    restart_sb
}

# ==========================================
# 4. 菜单界面
# ==========================================

check_status() {
    if jq -e '.outbounds[] | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null; then
        echo -e "当前状态: ${GREEN}已配置 Native WARP${PLAIN}"
    else
        echo -e "当前状态: ${RED}未配置${PLAIN}"
    fi
}

menu() {
    check_dependencies
    clear
    echo -e "===================================================="
    echo -e "   Sing-box Native WARP 托管脚本 (v3.9)"
    echo -e "   配置文件: ${SKYBLUE}$CONFIG_FILE${PLAIN}"
    echo -e "===================================================="
    check_status
    echo -e "----------------------------------------------------"
    echo -e "  1. ${GREEN}配置/重置 WARP 账号${PLAIN} (自动注册 / 手动录入)"
    echo -e "  2. ${GREEN}添加分流规则${PLAIN} (Netflix/OpenAI/Disney+)"
    echo -e "  3. ${GREEN}全局流量接管${PLAIN} (IPv4 / IPv6 / 双栈)"
    echo -e "  4. ${RED}卸载/移除 WARP${PLAIN}"
    echo -e "  0. 退出脚本"
    echo -e "----------------------------------------------------"
    read -p " 请选择: " choice
    
    case $choice in
        1)
            echo -e "  1. 自动注册 (免费账号, 自动计算 Reserved)"
            echo -e "  2. 手动录入 (Teams/已有账号)"
            read -p "  请选择: " reg_type
            if [[ "$reg_type" == "1" ]]; then register_warp; 
            elif [[ "$reg_type" == "2" ]]; then manual_warp; 
            else echo -e "${RED}无效选择${PLAIN}"; fi
            ;;
        2)
            echo -e "  a. 解锁 ChatGPT/OpenAI"
            echo -e "  b. 解锁 Netflix"
            echo -e "  c. 解锁 Disney+"
            echo -e "  d. 解锁 Telegram"
            echo -e "  e. 解锁 Google"
            read -p "  请选择目标: " rule_target
            case "$rule_target" in
                a) add_rule "OpenAI" "openai.com ai.com chatgpt.com" "openai" ;;
                b) add_rule "Netflix" "netflix.com nflxvideo.net nflxext.com nflxso.net" "netflix" ;;
                c) add_rule "Disney+" "disney.com disneyplus.com bamgrid.com" "disney" ;;
                d) add_rule "Telegram" "telegram.org t.me" "telegram" ;;
                e) add_rule "Google" "google.com googleapis.com gvt1.com youtube.com" "google" ;;
                *) echo -e "${RED}无效选择${PLAIN}" ;;
            esac
            ;;
        3)
            echo -e "  a. 仅接管 IPv4 流量"
            echo -e "  b. 仅接管 IPv6 流量"
            echo -e "  c. 双栈全局接管 (所有流量)"
            read -p "  请选择: " glob_type
            case "$glob_type" in
                a) set_global "v4" ;;
                b) set_global "v6" ;;
                c) set_global "dual" ;;
            esac
            ;;
        4) uninstall_warp ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${PLAIN}" ;;
    esac
    
    echo -e ""
    read -p "按回车键返回菜单..." 
    menu
}

menu
