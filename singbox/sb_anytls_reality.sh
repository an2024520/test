#!/bin/bash

# ============================================================
#  Sing-box 节点新增: VLESS + Vision + Reality (v2.1 Pro)
#  - 修复: 自动识别配置文件路径 (兼容 /usr/local/etc 和 /etc)
#  - 修复: 写入 Inbounds (服务端模式)
#  - 新增: 公钥持久化到 .meta 文件 (供查看脚本调用)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: VLESS + Vision + Reality ...${PLAIN}"

# 1. 智能路径查找
# ------------------------------------------------
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then
        CONFIG_FILE="$p"
        break
    fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 未找到 Sing-box 配置文件！${PLAIN}"
    exit 1
fi

CONFIG_DIR=$(dirname "$CONFIG_FILE")
META_FILE="${CONFIG_FILE}.meta" # 伴生文件，用于存储公钥等元数据
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")

echo -e "${GREEN}>>> 锁定配置文件: ${CONFIG_FILE}${PLAIN}"

# 2. 依赖检查
if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}安装必要工具 (jq, openssl)...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y jq openssl
    elif [ -f /etc/redhat-release ]; then
        yum install -y jq openssl
    fi
fi

# 3. 参数配置
# ------------------------------------------------
# A. 端口
while true; do
    read -p "请输入监听端口 (默认 443): " CUSTOM_PORT
    [[ -z "$CUSTOM_PORT" ]] && PORT=443 && break
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
        PORT="$CUSTOM_PORT"
        break
    else
        echo -e "${RED}无效端口。${PLAIN}"
    fi
done

# B. 伪装域名
echo -e "${YELLOW}请选择伪装域名 (SNI):${PLAIN}"
echo -e "  1. www.microsoft.com (默认)"
echo -e "  2. www.apple.com"
echo -e "  3. 手动输入"
read -p "选择 [1-3]: " SNI_CHOICE
case $SNI_CHOICE in
    2) SNI="www.apple.com" ;;
    3) read -p "输入域名: " SNI ;;
    *) SNI="www.microsoft.com" ;;
esac

# 4. 生成密钥
# ------------------------------------------------
echo -e "${YELLOW}正在生成密钥与 UUID...${PLAIN}"
UUID=$($SB_BIN generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
KEY_PAIR=$($SB_BIN generate reality-keypair 2>/dev/null)

if [[ -z "$KEY_PAIR" ]]; then
    # 回退模式
    PRIVATE_KEY=$(openssl rand -base64 32 | tr -d /=+ | head -c 43)
    PUBLIC_KEY="GenerateFailed_Please_Check_Logs" 
    echo -e "${RED}警告: 无法调用 sing-box 生成密钥，使用随机字符串(可能不可用)，请检查核心。${PLAIN}"
else
    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "PrivateKey" | awk '{print $2}' | tr -d ' "')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "PublicKey" | awk '{print $2}' | tr -d ' "')
fi
SHORT_ID=$(openssl rand -hex 8)

# 5. 写入配置
# ------------------------------------------------
NODE_TAG="Vision-${PORT}"

echo -e "${YELLOW}正在写入配置...${PLAIN}"

# A. 清理冲突端口 (无论在 inbounds 还是 outbounds)
tmp_clean=$(mktemp)
jq --argjson port "$PORT" '
    del(.inbounds[]? | select(.listen_port == $port)) 
' "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"

# B. 构造 Inbound JSON
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg dest "$SNI" \
    --arg pk "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" \
    '{
        "type": "vless",
        "tag": $tag,
        "listen": "::",
        "listen_port": ($port | tonumber),
        "users": [{ "uuid": $uuid, "flow": "xtls-rprx-vision" }],
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

# C. 写入 config.json (追加到 inbounds)
tmp_add=$(mktemp)
jq --argjson new "$NODE_JSON" '
    if .inbounds == null then .inbounds = [] else . end | .inbounds += [$new]
' "$CONFIG_FILE" > "$tmp_add" && mv "$tmp_add" "$CONFIG_FILE"

# D. 写入伴生元数据 (关键步骤: 保存公钥)
# 格式: { "Tag": { "pbk": "xxx", "sid": "xxx", "sni": "xxx" } }
if [[ ! -f "$META_FILE" ]]; then echo "{}" > "$META_FILE"; fi
tmp_meta=$(mktemp)
jq --arg tag "$NODE_TAG" --arg pbk "$PUBLIC_KEY" --arg sid "$SHORT_ID" --arg sni "$SNI" \
   '. + {($tag): {"pbk": $pbk, "sid": $sid, "sni": $sni}}' "$META_FILE" > "$tmp_meta" && mv "$tmp_meta" "$META_FILE"

# 6. 重启服务
# ------------------------------------------------
systemctl restart sing-box
sleep 1

if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}配置写入并重启成功！${PLAIN}"
    echo -e "节点 Tag: ${SKYBLUE}$NODE_TAG${PLAIN} (已存入 Inbounds)"
    echo -e "Public Key 已备份至: $META_FILE"
    echo -e "${YELLOW}现在可以使用菜单 [5. 查看节点] 获取完整链接了。${PLAIN}"
else
    echo -e "${RED}服务启动失败，请检查日志。${PLAIN}"
fi
