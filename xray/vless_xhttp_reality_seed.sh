#!/bin/bash

# ============================================================
#  模块四：VLESS + XHTTP + Reality + Vision Seed (修正版)
#  - 协议: XHTTP (基于 QUIC 的抗探测协议)
#  - 兼容: 仅限 v2rayN / Nekoray / PassWall (Mihomo 不支持)
#  - 修正: 强制遵循 SNI 白名单原则，修复被墙域名导致的阻断
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 核心路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray_core/xray"
LOG_FILE="/root/xray_nodes.txt"

echo -e "${GREEN}>>> [模块四] 部署 VLESS + XHTTP + Reality (白名单伪装版) ...${PLAIN}"

# 1. 环境检查
if [[ ! -f "$XRAY_BIN" ]]; then
    echo -e "${RED}错误: Xray 核心未安装！请先运行模块一。${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}正在安装依赖 (jq, openssl)...${PLAIN}"
    apt update -y && apt install -y jq openssl
fi

# 2. 配置文件初始化
if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat <<EOF > "$CONFIG_FILE"
{
  "log": { "loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log" },
  "inbounds": [],
  "outbounds": [ { "tag": "direct", "protocol": "freedom" }, { "tag": "blocked", "protocol": "blackhole" } ],
  "routing": { "domainStrategy": "IPOnDemand", "rules": [ { "type": "field", "outboundTag": "blocked", "ip": ["geoip:private"] } ] }
}
EOF
fi

# 3. 参数获取 (严格遵守白名单)
if [[ "$AUTO_SETUP" == "true" ]]; then
    echo -e "${GREEN}>>> [自动模式] 读取环境变量...${PLAIN}"
    PORT="${PORT:-443}"
    # [修正] 自动模式强制使用微软，确保国内连通性
    SNI="www.microsoft.com"
else
    # === 手动模式 ===
    echo -e "${YELLOW}--- 配置 XHTTP 端口与伪装 ---${PLAIN}"
    
    # A. 端口
    while true; do
        read -p "请输入监听端口 (推荐 443): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=443 && break
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            PORT="$CUSTOM_PORT"
            break
        else
            echo -e "${RED}无效端口。${PLAIN}"
        fi
    done

    # B. 伪装域名 (白名单引导)
    echo -e "${YELLOW}请选择伪装域名 (SNI) - [警告] 必须是中国大陆可访问的网站:${PLAIN}"
    echo -e "  1. www.microsoft.com (推荐 - 支持HTTP/3)"
    echo -e "  2. www.apple.com (支持 H3)"
    echo -e "  3. www.amazon.com"
    echo -e "  4. 手动输入"
    read -p "选择 [1-4] (默认 1): " SNI_CHOICE
    case $SNI_CHOICE in
        2) SNI="www.apple.com" ;;
        3) SNI="www.amazon.com" ;;
        4) 
            while true; do
                read -p "请输入域名 (严禁输入 google/youtube 等被墙域名): " SNI
                # 简单阻断常见的错误输入
                if [[ "$SNI" == *"google"* || "$SNI" == *"youtube"* || "$SNI" == *"twitter"* ]]; then
                    echo -e "${RED}错误: 检测到被墙关键词！Reality 必须伪装国内可访问的域名，否则无法握手。${PLAIN}"
                elif [[ -n "$SNI" ]]; then
                    break
                else
                    SNI="www.microsoft.com"
                    break
                fi
            done
            ;;
        *) SNI="www.microsoft.com" ;;
    esac
fi

# 4. 密钥与 Seed 生成
echo -e "${YELLOW}正在生成密钥与随机特征...${PLAIN}"
UUID=$($XRAY_BIN uuid)
SHORT_ID=$(openssl rand -hex 4)
XHTTP_PATH="/$(openssl rand -hex 6)"
VISION_SEED=$(openssl rand -hex 16) # XHTTP 混淆种子

RAW_KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$RAW_KEYS" | grep "Private" | awk -F ":" '{print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$RAW_KEYS" | grep -E "Password|Public" | awk -F ":" '{print $2}' | tr -d ' \r\n')

# 5. 注入配置 (JQ 清洗)
NODE_TAG="vless-xhttp-${PORT}"
tmp_clean=$(mktemp)
jq --argjson port "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[] | select(.tag == $tag or .port == $port))' \
   "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"

# 构建 XHTTP 节点 JSON
NODE_JSON=$(jq -n \
    --argjson port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg sni "$SNI" \
    --arg pk "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" \
    --arg path "$XHTTP_PATH" \
    --arg seed "$VISION_SEED" \
    '{
      tag: $tag,
      listen: "0.0.0.0",
      port: $port,
      protocol: "vless",
      settings: {
        clients: [{ id: $uuid, flow: "", seed: $seed }],
        decryption: "none"
      },
      streamSettings: {
        network: "xhttp",
        xhttpSettings: { path: $path },
        security: "reality",
        realitySettings: {
          show: false,
          dest: ($sni + ":443"),
          serverNames: [$sni],
          privateKey: $pk,
          shortIds: [$sid]
        }
      },
      sniffing: { enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true }
    }')

tmp_add=$(mktemp)
jq --argjson new "$NODE_JSON" '.inbounds += [$new]' "$CONFIG_FILE" > "$tmp_add" && mv "$tmp_add" "$CONFIG_FILE"

# 6. 重启与输出
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    PUBLIC_IP=$(curl -s4 ifconfig.me)
    # 构造分享链接
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&type=xhttp&sni=${SNI}&sid=${SHORT_ID}&path=${XHTTP_PATH}&seed=${VISION_SEED}&fp=chrome#${NODE_TAG}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [模块四] XHTTP 部署成功 (已修正)     ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "核心协议    : ${YELLOW}VLESS + XHTTP + Reality${PLAIN}"
    echo -e "Vision Seed : ${SKYBLUE}${VISION_SEED}${PLAIN} (抗识别填充)"
    echo -e "伪装域名    : ${YELLOW}${SNI}${PLAIN} (白名单合规)"
    echo -e "适用客户端  : ${SKYBLUE}v2rayN 6.33+ / Nekoray / PassWall${PLAIN}"
    echo -e "${RED}不支持      : Clash Meta / Mihomo (暂无计划支持 XHTTP)${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [通用分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "提示: 若 v2rayN 导入后无法连接，请右键检查配置 JSON 中是否包含 seed 字段。"
    
    # 自动记录
    if [[ "$AUTO_SETUP" == "true" ]]; then
        echo "Tag: ${NODE_TAG} | ${SHARE_LINK}" >> "$LOG_FILE"
    fi
else
    echo -e "${RED}启动失败！请运行: journalctl -u xray -e${PLAIN}"
    [[ "$AUTO_SETUP" == "true" ]] && exit 1
fi
