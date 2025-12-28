#!/bin/bash

# ============================================================
#  Sing-box 节点新增: VLESS + Vision + Reality (v3.4 Final-Fix)
#  - 架构: 参数分流 (自动/手动) -> 统一执行 -> 统一输出
#  - 修复: 写入配置前强制清理同端口/同Tag节点
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: VLESS + Vision + Reality ...${PLAIN}"

# 智能路径查找
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")
for p in "${PATHS[@]}"; do if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi; done
if [[ -z "$CONFIG_FILE" ]]; then CONFIG_FILE="/usr/local/etc/sing-box/config.json"; fi

CONFIG_DIR=$(dirname "$CONFIG_FILE")
META_FILE="${CONFIG_FILE}.meta" 
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")

echo -e "${GREEN}>>> 锁定配置文件: ${CONFIG_FILE}${PLAIN}"

if [[ ! -f "$SB_BIN" ]]; then echo -e "${RED}错误: 未找到 Sing-box 核心！${PLAIN}"; exit 1; fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}安装必要工具...${PLAIN}"
    if [ -f /etc/debian_version ]; then apt update -y && apt install -y jq openssl; 
    elif [ -f /etc/redhat-release ]; then yum install -y jq openssl; fi
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$CONFIG_DIR"
    echo '{"log":{"level":"info","timestamp":false},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],"route":{"rules":[]}}' > "$CONFIG_FILE"
fi

# --- 参数获取 ---
if [[ "$AUTO_SETUP" == "true" ]]; then
    echo -e "${GREEN}>>> [自动模式] 正在读取参数...${PLAIN}"
    PORT=${PORT:-443}
    echo -e "端口: ${GREEN}$PORT${PLAIN}"
    SNI=${REALITY_DOMAIN:-"updates.cdn-apple.com"}
    echo -e "SNI : ${GREEN}$SNI${PLAIN}"
else
    while true; do
        read -p "请输入监听端口 (推荐 443, 2053, 默认 443): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=443 && break
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            PORT="$CUSTOM_PORT"; break
        else
            echo -e "${RED}无效端口。${PLAIN}"
        fi
    done

    echo -e "${YELLOW}请选择伪装域名 (SNI):${PLAIN}"
    echo -e "  1. www.sony.jp"
    echo -e "  2. www.nintendo.co.jp"
    echo -e "  3. updates.cdn-apple.com (默认)"
    echo -e "  4. www.microsoft.com"
    echo -e "  5. 手动输入"
    read -p "请选择 [1-5]: " SNI_CHOICE
    case $SNI_CHOICE in
        1) SNI="www.sony.jp" ;; 2) SNI="www.nintendo.co.jp" ;; 4) SNI="www.microsoft.com" ;;
        5) read -p "输入域名: " MANUAL_SNI; [[ -z "$MANUAL_SNI" ]] && SNI="updates.cdn-apple.com" || SNI="$MANUAL_SNI" ;;
        *) SNI="updates.cdn-apple.com" ;;
    esac
fi

# --- 资源生成 ---
if [[ -z "$UUID" ]]; then UUID=$($SB_BIN generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid); fi
KEY_PAIR=$($SB_BIN generate reality-keypair 2>/dev/null)
if [[ -z "$KEY_PAIR" ]]; then
    PRIVATE_KEY=$(openssl rand -base64 32 | tr -d /=+ | head -c 43)
    PUBLIC_KEY="GenerateFailed"
else
    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "PrivateKey" | awk '{print $2}' | tr -d ' "')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "PublicKey" | awk '{print $2}' | tr -d ' "')
fi
SHORT_ID=$(openssl rand -hex 8)

# --- 核心执行 ---
NODE_TAG="Vision-${PORT}"

# [修复] 端口与Tag双重清理，防止重复冲突
tmp0=$(mktemp)
jq --argjson port "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[]? | select(.listen_port == $port or .tag == $tag))' \
   "$CONFIG_FILE" > "$tmp0" && mv "$tmp0" "$CONFIG_FILE"

NODE_JSON=$(jq -n --arg port "$PORT" --arg tag "$NODE_TAG" --arg uuid "$UUID" \
    --arg dest "$SNI" --arg pk "$PRIVATE_KEY" --arg sid "$SHORT_ID" \
    '{
        "type": "vless", "tag": $tag, "listen": "::", "listen_port": ($port | tonumber),
        "users": [{ "uuid": $uuid, "flow": "xtls-rprx-vision" }],
        "tls": { "enabled": true, "server_name": $dest, "reality": { "enabled": true, "handshake": { "server": $dest, "server_port": 443 }, "private_key": $pk, "short_id": [$sid] } }
    }')

tmp=$(mktemp)
jq --argjson new_node "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 存根 Meta
if [[ ! -f "$META_FILE" ]]; then echo "{}" > "$META_FILE"; fi
tmp_meta=$(mktemp)
jq --arg tag "$NODE_TAG" --arg pbk "$PUBLIC_KEY" --arg sid "$SHORT_ID" --arg sni "$SNI" \
   '. + {($tag): {"pbk": $pbk, "sid": $sid, "sni": $sni}}' "$META_FILE" > "$tmp_meta" && mv "$tmp_meta" "$META_FILE"

systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    PUBLIC_IP=$(curl -s4m5 https://api.ip.sb/ip || curl -s4 ifconfig.me)
    NODE_NAME="$NODE_TAG"
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#${NODE_NAME}"

    echo -e "${GREEN}节点部署成功: ${NODE_TAG}${PLAIN}"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    
    if [[ "$AUTO_SETUP" == "true" ]]; then
        LOG_FILE="/root/sb_nodes.txt"
        echo "Tag: ${NODE_TAG} | ${SHARE_LINK}" >> "$LOG_FILE"
        echo -e "${SKYBLUE}>>> 已记录至: ${LOG_FILE}${PLAIN}"
    fi
else
    echo -e "${RED}启动失败！journalctl -u sing-box -e${PLAIN}"
    exit 1
fi
