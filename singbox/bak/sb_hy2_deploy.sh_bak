#!/bin/bash

# ============================================================
#  Sing-box 节点部署: Hysteria 2 (智能全能版 v2.2)
#  - 架构: Sing-box Inbound 模式
#  - 证书: 智能识别 (留空->自签 / 输入域名->ACME)
#  - 升级: 适配 Auto Deploy 参数自动传递
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [Sing-box] Hysteria 2 智能部署启动...${PLAIN}"

# --- 1. 环境准备 ---
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")
for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done
[[ -z "$CONFIG_FILE" ]] && CONFIG_FILE="/usr/local/etc/sing-box/config.json"

CONFIG_DIR=$(dirname "$CONFIG_FILE")
META_FILE="${CONFIG_FILE}.meta"
CERT_DIR="${CONFIG_DIR}/cert"
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")

if [[ ! -f "$SB_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Sing-box 核心！请先安装核心。${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null || ! command -v socat &> /dev/null; then
    echo -e "${YELLOW}正在安装必要依赖 (jq, openssl, socat)...${PLAIN}"
    apt update -y && apt install -y jq openssl socat
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$CONFIG_DIR"
    echo '{"log":{"level":"info","timestamp":false},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],"route":{"rules":[]}}' > "$CONFIG_FILE"
fi
mkdir -p "$CERT_DIR"

# --- 2. 配置处理 (适配自动模式) ---

# --- [修改处 Start] ---
if [[ "$AUTO_SETUP" == "true" ]]; then
    # 自动模式：直接从环境变量读取，不进行交互
    if [[ -z "$DOMAIN_INPUT" ]]; then
        MODE="self"
        DOMAIN="bing.com"
        echo -e "${GREEN}>>> [自动模式] 域名为空，使用自签模式 (Self-Signed)${PLAIN}"
    else
        MODE="acme"
        DOMAIN="$DOMAIN_INPUT"
        echo -e "${GREEN}>>> [自动模式] 使用域名证书模式 (ACME): $DOMAIN${PLAIN}"
    fi

    # 端口处理
    if [[ -n "$PORT" ]]; then
        echo -e "${GREEN}>>> [自动模式] 使用端口: $PORT${PLAIN}"
    else
        PORT=$([[ "$MODE" == "acme" ]] && echo 443 || echo 10086)
        echo -e "${YELLOW}>>> [自动模式] 未指定端口，使用默认: $PORT${PLAIN}"
    fi

else
    # 手动模式：保持原有交互逻辑
    echo -e "${YELLOW}------------------------------------------------${PLAIN}"
    echo -e "请选择安装模式:"
    echo -e "1. ${GREEN}留空回车${PLAIN} -> 使用**自签证书** (无需域名，IP 直连)"
    echo -e "2. ${SKYBLUE}输入域名${PLAIN} -> 使用**真实证书** (ACME 自动申请，需提前解析)"
    echo -e "${YELLOW}------------------------------------------------${PLAIN}"
    read -p "请输入域名 (留空则自签): " DOMAIN_INPUT

    if [[ -z "$DOMAIN_INPUT" ]]; then
        MODE="self"
        DOMAIN="bing.com"
        echo -e "${GREEN}>>> 已选择: 自签证书模式 (Self-Signed)${PLAIN}"
    else
        MODE="acme"
        DOMAIN="$DOMAIN_INPUT"
        echo -e "${GREEN}>>> 已选择: 域名证书模式 (ACME)${PLAIN}"
    fi

    if [[ "$MODE" == "acme" ]]; then
        DEFAULT_PORT=443
    else
        DEFAULT_PORT=10086
    fi

    while true; do
        read -p "请输入 UDP 监听端口 (默认 $DEFAULT_PORT): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=$DEFAULT_PORT && break
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            PORT="$CUSTOM_PORT"
            break
        else
            echo -e "${RED}无效端口。${PLAIN}"
        fi
    done
fi
# --- [修改处 End] ---

# 2.3 密码生成
PASSWORD=$(openssl rand -hex 16)
OBFS_PASS=$(openssl rand -hex 8)
echo -e "${YELLOW}已自动生成高强度认证信息。${PLAIN}"

# --- 3. 证书处理 ---

if [[ "$MODE" == "self" ]]; then
    # === 自签模式 ===
    echo -e "${YELLOW}正在生成自签证书...${PLAIN}"
    CERT_PATH="$CERT_DIR/self_${PORT}.crt"
    KEY_PATH="$CERT_DIR/self_${PORT}.key"
    
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
        -keyout "$KEY_PATH" -out "$CERT_PATH" \
        -days 36500 -subj "/CN=$DOMAIN" 2>/dev/null
        
    INSECURE_BOOL="true" # 客户端需要跳过验证
    SNI_VAL="bing.com"

elif [[ "$MODE" == "acme" ]]; then
    # === ACME 模式 ===
    echo -e "${YELLOW}正在使用 acme.sh 申请证书...${PLAIN}"
    
    WEB_STOPPED=""
    if lsof -i :80 | grep -q "LISTEN"; then
        echo -e "${YELLOW}检测到 80 端口占用，尝试临时停止 Web 服务...${PLAIN}"
        if systemctl is-active --quiet nginx; then systemctl stop nginx; WEB_STOPPED="nginx"; fi
        if systemctl is-active --quiet apache2; then systemctl stop apache2; WEB_STOPPED="apache2"; fi
    fi

    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        curl https://get.acme.sh | sh -s email="hy2@${DOMAIN}"
    fi
    ACME_BIN=~/.acme.sh/acme.sh

    $ACME_BIN --issue -d "$DOMAIN" --standalone --force
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}证书申请失败！请检查域名解析或防火墙。${PLAIN}"
        [[ -n "$WEB_STOPPED" ]] && systemctl start "$WEB_STOPPED"
        exit 1
    fi

    CERT_PATH="$CERT_DIR/${DOMAIN}.cer"
    KEY_PATH="$CERT_DIR/${DOMAIN}.key"

    $ACME_BIN --install-cert -d "$DOMAIN" \
        --key-file       "$KEY_PATH"  \
        --fullchain-file "$CERT_PATH" \
        --reloadcmd     "systemctl restart sing-box"
    
    [[ -n "$WEB_STOPPED" ]] && systemctl start "$WEB_STOPPED"
        
    INSECURE_BOOL="false"
    SNI_VAL="$DOMAIN"
fi

# --- 4. 写入 Sing-box 配置 ---

NODE_TAG="Hy2-${PORT}"
[[ "$MODE" == "acme" ]] && NODE_TAG="Hy2-${DOMAIN}"

tmp0=$(mktemp)
jq --argjson port "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[]? | select(.listen_port == $port or .tag == $tag))' \
   "$CONFIG_FILE" > "$tmp0" && mv "$tmp0" "$CONFIG_FILE"

NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg pass "$PASSWORD" \
    --arg obfs "$OBFS_PASS" \
    --arg cert "$CERT_PATH" \
    --arg key "$KEY_PATH" \
    '{
        "type": "hysteria2",
        "tag": $tag,
        "listen": "::",
        "listen_port": ($port | tonumber),
        "users": [{ "password": $pass }],
        "obfs": {
            "type": "salamander",
            "password": $obfs
        },
        "tls": {
            "enabled": true,
            "certificate_path": $cert,
            "key_path": $key
        }
    }')

tmp=$(mktemp)
jq --argjson new_node "$NODE_JSON" 'if .inbounds == null then .inbounds = [] else . end | .inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

if [[ ! -f "$META_FILE" ]]; then echo "{}" > "$META_FILE"; fi
tmp_meta=$(mktemp)
jq --arg tag "$NODE_TAG" --arg type "hy2-$MODE" \
   '. + {($tag): {"type": $type}}' "$META_FILE" > "$tmp_meta" && mv "$tmp_meta" "$META_FILE"

# --- 5. 重启与输出 ---
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    PUBLIC_IP=$(curl -s4m5 https://api.ip.sb/ip || curl -s4 ifconfig.me)
    if [[ "$MODE" == "acme" ]]; then
        SERVER_HOST="$DOMAIN"
        INSECURE_NUM=0
    else
        SERVER_HOST="$PUBLIC_IP"
        INSECURE_NUM=1
    fi
    
    SHARE_LINK="hysteria2://${PASSWORD}@${SERVER_HOST}:${PORT}?insecure=${INSECURE_NUM}&obfs=salamander&obfs-password=${OBFS_PASS}&sni=${SNI_VAL}#${NODE_TAG}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}   [Sing-box] Hy2 部署成功 ($MODE)      ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "Tag         : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "地址        : ${YELLOW}${SERVER_HOST}${PLAIN}"
    echo -e "端口        : ${YELLOW}${PORT}${PLAIN}"
    echo -e "SNI         : ${YELLOW}${SNI_VAL}${PLAIN}"
    echo -e "允许不安全  : ${YELLOW}${INSECURE_BOOL}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "${SKYBLUE}提示: 您可以使用 WARP 脚本将其分流接管。${PLAIN}"
else
    echo -e "${RED}启动失败！请检查日志: journalctl -u sing-box -e${PLAIN}"
fi
