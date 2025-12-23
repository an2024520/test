#!/bin/bash

# ============================================================
#  Sing-box 节点新增: AnyTLS + Reality (v3.1 Final-Audit)
#  - 协议: AnyTLS (Sing-box 专属拟态协议)
#  - 升级: 支持 auto_deploy.sh 自动化调用
#  - 审计: 已验证 Tag + Port 双重清理逻辑 (Configuration is Final)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: AnyTLS + Reality ...${PLAIN}"

# --- 1. 环境准备 ---
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")
for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done
[[ -z "$CONFIG_FILE" ]] && CONFIG_FILE="/usr/local/etc/sing-box/config.json"

CONFIG_DIR=$(dirname "$CONFIG_FILE")
META_FILE="${CONFIG_FILE}.meta"
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")

echo -e "${GREEN}>>> 锁定配置文件: ${CONFIG_FILE}${PLAIN}"

if [[ ! -f "$SB_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Sing-box 核心！${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}安装必要依赖 (jq, openssl)...${PLAIN}"
    apt update -y && apt install -y jq openssl
fi

# 初始化骨架
if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$CONFIG_DIR"
    echo '{"log":{"level":"info","timestamp":false},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],"route":{"rules":[]}}' > "$CONFIG_FILE"
fi

# --- 2. 参数获取 (自动/手动分流) ---
if [[ "$AUTO_SETUP" == "true" ]]; then
    # >>> 自动模式 >>>
    echo -e "${GREEN}>>> [自动模式] 读取参数...${PLAIN}"
    PORT=${PORT:-8443}
    SNI=${REALITY_DOMAIN:-"updates.cdn-apple.com"}
    echo -e "端口: ${GREEN}$PORT${PLAIN}"
    echo -e "SNI : ${GREEN}$SNI${PLAIN}"
else
    # >>> 手动模式 >>>
    echo -e "${YELLOW}--- 配置 AnyTLS 参数 ---${PLAIN}"
    while true; do
        read -p "请输入监听端口 (默认 8443): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=8443 && break
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            PORT="$CUSTOM_PORT"
            break
        else
            echo -e "${RED}无效端口。${PLAIN}"
        fi
    done

    echo -e "${YELLOW}请选择伪装域名 (SNI):${PLAIN}"
    echo -e "  1. www.sony.jp (默认)"
    echo -e "  2. updates.cdn-apple.com"
    echo -e "  3. www.microsoft.com"
    echo -e "  4. 手动输入"
    read -p "选择 [1-4]: " SNI_CHOICE
    case $SNI_CHOICE in
        2) SNI="updates.cdn-apple.com" ;;
        3) SNI="www.microsoft.com" ;;
        4) read -p "输入域名: " SNI; [[ -z "$SNI" ]] && SNI="www.sony.jp" ;;
        *) SNI="www.sony.jp" ;;
    esac
fi

# --- 3. 资源生成 ---
echo -e "${YELLOW}正在生成密钥...${PLAIN}"
USER_PASS=$($SB_BIN generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
KEY_PAIR=$($SB_BIN generate reality-keypair 2>/dev/null)
if [[ -z "$KEY_PAIR" ]]; then
    PRIVATE_KEY=$(openssl rand -base64 32 | tr -d /=+ | head -c 43)
    PUBLIC_KEY="GenerateFailed"
else
    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "PrivateKey" | awk '{print $2}' | tr -d ' "')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "PublicKey" | awk '{print $2}' | tr -d ' "')
fi
SHORT_ID=$(openssl rand -hex 8)

# --- 4. 核心执行 ---
NODE_TAG="AnyTLS-${PORT}"

# [PRO 专家模式] 双重清理：删除占用同端口(.listen_port) 或 同Tag(.tag) 的旧配置
# 确保“配置即最终态”，防止残留
tmp0=$(mktemp)
jq --argjson port "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[]? | select(.listen_port == $port or .tag == $tag))' \
   "$CONFIG_FILE" > "$tmp0" && mv "$tmp0" "$CONFIG_FILE"

# 构建 JSON (AnyTLS)
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg pass "$USER_PASS" \
    --arg dest "$SNI" \
    --arg pk "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" \
    '{
        "type": "anytls",
        "tag": $tag,
        "listen": "::",
        "listen_port": ($port | tonumber),
        "users": [{ "password": $pass }],
        "padding_scheme": [],
        "tls": {
            "enabled": true,
            "server_name": $dest,
            "reality": {
                "enabled": true,
                "handshake": { "server": $dest, "server_port": 443 },
                "private_key": $pk,
                "short_id": [$sid]
            }
        }
    }')

tmp=$(mktemp)
jq --argjson new_node "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 存根 Meta
if [[ ! -f "$META_FILE" ]]; then echo "{}" > "$META_FILE"; fi
tmp_meta=$(mktemp)
jq --arg tag "$NODE_TAG" --arg pbk "$PUBLIC_KEY" --arg sid "$SHORT_ID" --arg sni "$SNI" \
   '. + {($tag): {"pbk": $pbk, "sid": $sid, "sni": $sni}}' "$META_FILE" > "$tmp_meta" && mv "$tmp_meta" "$META_FILE"

# --- 5. 重启与输出 ---
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    PUBLIC_IP=$(curl -s4m5 https://api.ip.sb/ip || curl -s4 ifconfig.me)
    NODE_NAME="$NODE_TAG"
    SHARE_LINK="anytls://${USER_PASS}@${PUBLIC_IP}:${PORT}?security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [Sing-box] AnyTLS 节点部署成功！    ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "监听端口    : ${YELLOW}${PORT}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    # 自动模式日志记录
    if [[ "$AUTO_SETUP" == "true" ]]; then
        LOG_FILE="/root/sb_nodes.txt"
        echo "Tag: ${NODE_TAG} | ${SHARE_LINK}" >> "$LOG_FILE"
        echo -e "${SKYBLUE}>>> [自动记录] 节点信息已追加至: ${LOG_FILE}${PLAIN}"
    fi
else
    echo -e "${RED}启动失败！请检查日志: journalctl -u sing-box -e${PLAIN}"
    [[ "$AUTO_SETUP" == "true" ]] && exit 1
fi
