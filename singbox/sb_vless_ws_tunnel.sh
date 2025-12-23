#!/bin/bash

# ============================================================
#  Sing-box 节点模块: VLESS + WS (Tunnel专用)
#  - 模式: Manual (交互式) / Auto (变量传参)
#  - 特性: 无 TLS，专用于 CF Tunnel 后端
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# ==========================================
# 1. 核心功能函数 (Core Logic)
# ==========================================

get_config_path() {
    CONFIG_FILE=""
    PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")
    for p in "${PATHS[@]}"; do
        if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
    done
    if [[ -z "$CONFIG_FILE" ]]; then CONFIG_FILE="/usr/local/etc/sing-box/config.json"; fi
    CONFIG_DIR=$(dirname "$CONFIG_FILE")
    SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")
}

write_node_config() {
    local port="$1"
    local ws_path="$2"
    local uuid="$3"
    
    local node_tag="Tunnel-${port}"
    
    # 1. 初始化
    if [[ ! -f "$CONFIG_FILE" ]]; then mkdir -p "$CONFIG_DIR"; echo '{"inbounds":[],"outbounds":[]}' > "$CONFIG_FILE"; fi
    
    # 2. 清理旧同端口配置
    local tmp_clean=$(mktemp)
    jq --argjson p "$port" 'del(.inbounds[]? | select(.listen_port == $p))' "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"

    # 3. 构造 JSON
    local node_json=$(jq -n \
        --arg port "$port" \
        --arg tag "$node_tag" \
        --arg uuid "$uuid" \
        --arg path "$ws_path" \
        '{
            "type": "vless",
            "tag": $tag,
            "listen": "::",
            "listen_port": ($port | tonumber),
            "users": [{ "uuid": $uuid }],
            "transport": { 
                "type": "ws", 
                "path": $path,
                "max_early_data": 0,
                "early_data_header_name": "Sec-WebSocket-Protocol"
            }
        }')

    # 4. 写入
    local tmp_add=$(mktemp)
    jq --argjson new "$node_json" 'if .inbounds == null then .inbounds = [] else . end | .inbounds += [$new]' "$CONFIG_FILE" > "$tmp_add" && mv "$tmp_add" "$CONFIG_FILE"

    # 5. 重启
    systemctl restart sing-box
    sleep 1
    
    if systemctl is-active --quiet sing-box; then
        return 0
    else
        echo -e "${RED}Sing-box 重启失败，请检查日志。${PLAIN}"
        return 1
    fi
}

print_info() {
    local port="$1"
    local ws_path="$2"
    local uuid="$3"
    local domain="$4"
    
    echo -e "${GREEN}节点部署成功！${PLAIN}"
    
    if [[ -n "$domain" ]]; then
        # 构造分享链接: Tunnel 场景下前端是 TLS 443
        local share_link="vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=${ws_path}&sni=${domain}#SB-Tunnel-${port}"
        
        echo -e ""
        echo -e "${BLUE}========= Cloudflare Tunnel 节点信息 =========${PLAIN}"
        echo -e "${SKYBLUE}地址 (Address):${PLAIN} ${domain}"
        echo -e "${SKYBLUE}端口 (Port):${PLAIN} 443"
        echo -e "${SKYBLUE}UUID:${PLAIN} ${uuid}"
        echo -e "${SKYBLUE}传输 (Network):${PLAIN} ws"
        echo -e "${SKYBLUE}路径 (Path):${PLAIN} ${ws_path}"
        echo -e "${SKYBLUE}TLS:${PLAIN} on"
        echo -e "------------------------------------------------------"
        echo -e "${GREEN}分享链接:${PLAIN}"
        echo -e "${YELLOW}${share_link}${PLAIN}"
        echo -e "------------------------------------------------------"
    else
        echo -e "${YELLOW}未提供域名，无法生成完整链接。请在客户端手动填写 Tunnel 域名。${PLAIN}"
        echo -e "本地监听端口: $port | Path: $ws_path | UUID: $uuid"
    fi
}

# ==========================================
# 2. 手动模式 (Manual Menu)
# ==========================================

manual_menu() {
    echo -e "${GREEN}>>> [Sing-box] 智能添加节点: VLESS + WS (Tunnel) ...${PLAIN}"
    get_config_path
    
    # 依赖检查
    if ! command -v jq &> /dev/null; then if [ -f /etc/debian_version ]; then apt update -y && apt install -y jq; fi; fi

    # 交互输入
    while true; do
        read -p "请输入监听端口 (推荐 8080): " c_port
        [[ -z "$c_port" ]] && c_port=8080 && break
        if [[ "$c_port" =~ ^[0-9]+$ ]] && [ "$c_port" -le 65535 ]; then break; else echo -e "${RED}无效端口${PLAIN}"; fi
    done

    read -p "请输入 WebSocket 路径 (默认 /ws): " c_path
    [[ -z "$c_path" ]] && c_path="/ws"
    if [[ "${c_path:0:1}" != "/" ]]; then c_path="/$c_path"; fi

    local uuid=$($SB_BIN generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)

    # 执行写入
    if write_node_config "$c_port" "$c_path" "$uuid"; then
        # 尝试自动抓取域名 (TryCloudflare)
        local auto_domain=$(journalctl -u cloudflared --no-pager 2>/dev/null | grep -o 'https://.*\.trycloudflare\.com' | tail -n 1 | sed 's/https:\/\///')
        
        if [[ -z "$auto_domain" ]]; then
             echo -e "${YELLOW}提示：未自动抓取到临时域名。${PLAIN}"
             read -p "请输入您的 Cloudflare Tunnel 域名 (回车跳过): " m_domain
             auto_domain=$m_domain
        fi
        
        print_info "$c_port" "$c_path" "$uuid" "$auto_domain"
    fi
}

# ==========================================
# 3. 自动模式 (Auto Main)
# ==========================================

auto_main() {
    echo -e "${GREEN}>>> [SB-Tunnel] 启动自动化部署...${PLAIN}"
    get_config_path
    
    # 从环境变量读取
    local port="${SB_WS_PORT:-8080}"
    local path="${SB_WS_PATH:-/ws}"
    local domain="${ARGO_DOMAIN}" # 由 auto_deploy.sh 传入
    local uuid=$($SB_BIN generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)

    if write_node_config "$port" "$path" "$uuid"; then
        print_info "$port" "$path" "$uuid" "$domain"
    else
        echo -e "${RED}[错误] 节点配置写入失败。${PLAIN}"
        exit 1
    fi
}

# ==========================================
# 入口分流
# ==========================================

if [[ "$AUTO_SETUP" == "true" ]]; then
    auto_main
else
    manual_menu
fi
