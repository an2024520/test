#!/bin/bash

# ============================================================
#  Sing-box 节点新增: VLESS + WS (Tunnel专用)
#  - 核心: 自动识别路径 + 写入 Inbounds
#  - 特性: 无 TLS，专用于 CF Tunnel 后端或 Nginx 反代
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: VLESS + WS (Tunnel) ...${PLAIN}"

# 1. 智能路径查找
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")
for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done
if [[ -z "$CONFIG_FILE" ]]; then CONFIG_FILE="/usr/local/etc/sing-box/config.json"; fi

CONFIG_DIR=$(dirname "$CONFIG_FILE")
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")

echo -e "${GREEN}>>> 锁定配置文件: ${CONFIG_FILE}${PLAIN}"

# 2. 依赖检查
if ! command -v jq &> /dev/null; then if [ -f /etc/debian_version ]; then apt update -y && apt install -y jq; fi; fi

# 3. 参数配置
while true; do
    read -p "请输入监听端口 (推荐 8080): " CUSTOM_PORT
    [[ -z "$CUSTOM_PORT" ]] && PORT=8080 && break
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
        PORT="$CUSTOM_PORT"
        break
    else
        echo -e "${RED}无效端口。${PLAIN}"
    fi
done

read -p "请输入 WebSocket 路径 (默认 /ws): " WS_PATH
[[ -z "$WS_PATH" ]] && WS_PATH="/ws"
if [[ "${WS_PATH:0:1}" != "/" ]]; then WS_PATH="/$WS_PATH"; fi

# 4. 生成 UUID
UUID=$($SB_BIN generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)

# 5. 写入配置
NODE_TAG="Tunnel-${PORT}"

# A. 初始化/清理
if [[ ! -f "$CONFIG_FILE" ]]; then mkdir -p "$CONFIG_DIR"; echo '{"inbounds":[],"outbounds":[]}' > "$CONFIG_FILE"; fi
tmp_clean=$(mktemp)
jq --argjson port "$PORT" 'del(.inbounds[]? | select(.listen_port == $port))' "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"

# B. 构造 Inbound JSON (显式增加字段)
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg path "$WS_PATH" \
    '{
        "type": "vless",
        "tag": $tag,
        "listen": "::",
        "listen_port": ($port | tonumber),
        "users": [{ 
            "uuid": $uuid 
        }],
        "transport": { 
            "type": "ws", 
            "path": $path,
            "max_early_data": 0,
            "early_data_header_name": "Sec-WebSocket-Protocol"
        }
    }')

# C. 写入
tmp_add=$(mktemp)
jq --argjson new "$NODE_JSON" 'if .inbounds == null then .inbounds = [] else . end | .inbounds += [$new]' "$CONFIG_FILE" > "$tmp_add" && mv "$tmp_add" "$CONFIG_FILE"

# 6. 重启服务
systemctl restart sing-box
sleep 1

if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}配置写入成功！${PLAIN} Tag: ${NODE_TAG}"
    echo -e "------------------------------------------------------"

    # --- 隧道域名探测与补全逻辑 ---
    
    # A. 尝试从日志中自动抓取 TryCloudflare 临时隧道域名
    ARGO_DOMAIN=$(journalctl -u cloudflared --no-pager 2>/dev/null | grep -o 'https://.*\.trycloudflare\.com' | tail -n 1 | sed 's/https:\/\///')

    # B. 如果抓取不到，提示用户手动输入（兼容固定域名隧道）
    if [[ -z "$ARGO_DOMAIN" ]]; then
        echo -e "${YELLOW}提示：未探测到正在运行的临时隧道域名。${PLAIN}"
        read -p "请输入您的 Cloudflare Tunnel 域名 (直接回车跳过链接生成): " MANUAL_DOMAIN
        ARGO_DOMAIN=$MANUAL_DOMAIN
    fi

    # C. 生成并输出节点信息
    if [[ -n "$ARGO_DOMAIN" ]]; then
        echo -e "${GREEN}检测到隧道域名: ${ARGO_DOMAIN}${PLAIN}"
        
        # 构造 VLESS 分享链接 (针对 Tunnel 场景优化：443端口 + TLS开启 + 加密none)
        # 备注：Sing-box 做后端时，CF 隧道前端是 TLS 443，所以这里直接补全
        SHARE_LINK="vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${ARGO_DOMAIN}&path=${WS_PATH}&sni=${ARGO_DOMAIN}#SB-Tunnel-${PORT}"
        
        echo -e ""
        echo -e "${BLUE}========= Cloudflare Tunnel 专用配置 =========${PLAIN}"
        echo -e "${SKYBLUE}地址 (Address):${PLAIN} ${ARGO_DOMAIN}"
        echo -e "${SKYBLUE}端口 (Port):${PLAIN} 443"
        echo -e "${SKYBLUE}用户 ID (UUID):${PLAIN} ${UUID}"
        echo -e "${SKYBLUE}传输协议 (Network):${PLAIN} ws"
        echo -e "${SKYBLUE}伪装域名 (Host):${PLAIN} ${ARGO_DOMAIN}"
        echo -e "${SKYBLUE}路径 (Path):${PLAIN} ${WS_PATH}"
        echo -e "${SKYBLUE}TLS (Security):${PLAIN} tls"
        echo -e "${SKYBLUE}VLESS 加密:${PLAIN} none"
        echo -e "------------------------------------------------------"
        echo -e "${GREEN}分享链接 (直接导入客户端):${PLAIN}"
        echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
        echo -e "------------------------------------------------------"
    else
        echo -e "${YELLOW}未配置域名，请手动在客户端补全 Tunnel 域名信息。${PLAIN}"
        echo -e "本地监听端口: ${PORT}"
        echo -e "UUID: ${UUID}"
        echo -e "WS 路径: ${WS_PATH}"
    fi

else
    echo -e "${RED}Sing-box 启动失败，请检查配置文件格式。${PLAIN}"
fi
