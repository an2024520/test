#!/bin/bash

# ============================================================
#  Sing-box 节点新增: VLESS + Vision + Reality (v3.3 Final)
#  - 架构: 参数分流 (自动/手动) -> 统一执行 -> 统一输出
#  - 特性: 完整保留手动模式体验，自动模式增加文件存根
# ============================================================

# --- 1. 基础定义与环境检查 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: VLESS + Vision + Reality ...${PLAIN}"

# 智能路径查找
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")
for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then
        CONFIG_FILE="$p"
        break
    fi
done
# 默认回退
if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FILE="/usr/local/etc/sing-box/config.json"
fi

CONFIG_DIR=$(dirname "$CONFIG_FILE")
META_FILE="${CONFIG_FILE}.meta" 
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")

echo -e "${GREEN}>>> 锁定配置文件: ${CONFIG_FILE}${PLAIN}"

# 核心存在性检查
if [[ ! -f "$SB_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Sing-box 核心！请先运行 [核心环境管理] 安装。${PLAIN}"
    exit 1
fi

# 依赖工具检查
if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}检测到缺少必要工具，正在安装 (jq, openssl)...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y jq openssl
    elif [ -f /etc/redhat-release ]; then
        yum install -y jq openssl
    fi
fi

# 初始化骨架配置 (如果文件不存在)
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}配置文件不存在，正在初始化标准骨架...${PLAIN}"
    mkdir -p "$CONFIG_DIR"
    cat <<EOF > "$CONFIG_FILE"
{
  "log": {
    "level": "info",
    "output": "",
    "timestamp": false
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": []
  }
}
EOF
    echo -e "${GREEN}标准骨架初始化完成。${PLAIN}"
fi


# --- 2. 参数获取阶段 (Parameter Acquisition) ---
# 此阶段根据 AUTO_SETUP 变量进行逻辑分叉

echo -e "${YELLOW}--- 配置 VLESS (Vision) 节点参数 ---${PLAIN}"

if [[ "$AUTO_SETUP" == "true" ]]; then
    # >>> 自动模式通道 >>>
    echo -e "${GREEN}>>> [自动模式] 正在读取参数...${PLAIN}"
    
    # 端口: 优先读取注入变量，否则默认为 443
    PORT=${PORT:-443}
    echo -e "端口: ${GREEN}$PORT${PLAIN}"
    
    # SNI: 读取全局变量，否则使用默认
    SNI=${REALITY_DOMAIN:-"updates.cdn-apple.com"}
    echo -e "SNI : ${GREEN}$SNI${PLAIN}"
    
    # UUID: 如果全局变量有，则继承；否则留空(后面会生成)
    if [[ -n "$UUID" ]]; then
        echo -e "UUID: ${GREEN}$UUID (继承全局)${PLAIN}"
    fi
    
    # 自动模式下跳过 Curl 检查，强制继续

else
    # >>> 手动模式通道 (完整保留原版交互) >>>
    
    # [A. 端口设置]
    while true; do
        read -p "请输入监听端口 (推荐 443, 2053, 默认 443): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=443 && break
        
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            if grep -q "\"listen_port\": $CUSTOM_PORT" "$CONFIG_FILE"; then
                 echo -e "${YELLOW}提示: 端口 $CUSTOM_PORT 已被占用，脚本将强制覆盖该端口的旧配置。${PLAIN}"
            fi
            PORT="$CUSTOM_PORT"
            break
        else
            echo -e "${RED}无效端口。${PLAIN}"
        fi
    done

    # [B. SNI 选择]
    echo -e "${YELLOW}请选择伪装域名 (SNI) - 推荐:${PLAIN}"
    echo -e "  1. www.sony.jp (索尼日本)"
    echo -e "  2. www.nintendo.co.jp (任天堂)"
    echo -e "  3. updates.cdn-apple.com (苹果CDN)"
    echo -e "  4. www.microsoft.com (微软)"
    echo -e "  5. ${GREEN}手动输入${PLAIN}"
    read -p "请选择 [1-5] (默认 3): " SNI_CHOICE

    case $SNI_CHOICE in
        1) SNI="www.sony.jp" ;;
        2) SNI="www.nintendo.co.jp" ;;
        4) SNI="www.microsoft.com" ;;
        5) 
            read -p "请输入域名 (不带https://): " MANUAL_SNI
            [[ -z "$MANUAL_SNI" ]] && SNI="updates.cdn-apple.com" || SNI="$MANUAL_SNI"
            ;;
        *) SNI="updates.cdn-apple.com" ;;
    esac
    
    # [C. 连通性校验]
    echo -e "${YELLOW}正在检查连通性: $SNI ...${PLAIN}"
    if ! curl -s -I --max-time 5 "https://$SNI" >/dev/null; then
        echo -e "${RED}警告: 无法连接到 $SNI。建议更换。${PLAIN}"
        read -p "是否强制继续? (y/n): " FORCE
        [[ "$FORCE" != "y" ]] && exit 1
    fi
fi


# --- 3. 资源生成阶段 (Common Generation) ---
# 无论手动还是自动，都在这里准备 UUID 和 密钥

echo -e "${YELLOW}正在生成密钥与 UUID...${PLAIN}"

# 如果 UUID 还是空的 (自动模式未指定，或手动模式)，则生成
if [[ -z "$UUID" ]]; then
    UUID=$($SB_BIN generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    echo -e "UUID 已生成: ${SKYBLUE}$UUID${PLAIN}"
fi

# 生成 Reality 密钥对
KEY_PAIR=$($SB_BIN generate reality-keypair 2>/dev/null)
if [[ -z "$KEY_PAIR" ]]; then
    PRIVATE_KEY=$(openssl rand -base64 32 | tr -d /=+ | head -c 43)
    PUBLIC_KEY="GenerateFailed"
    echo -e "${RED}警告: 核心生成密钥失败，尝试使用 OpenSSL 回退。${PLAIN}"
else
    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "PrivateKey" | awk '{print $2}' | tr -d ' "')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "PublicKey" | awk '{print $2}' | tr -d ' "')
fi
SHORT_ID=$(openssl rand -hex 8)


# --- 4. 核心执行阶段 (Unified Execution) ---
# 写入配置、重启服务

echo -e "${YELLOW}正在更新配置文件...${PLAIN}"
NODE_TAG="Vision-${PORT}"

# 步骤 1: 强制日志托管 (防止 Permission Denied)
tmp_log=$(mktemp)
jq '.log.output = "" | .log.timestamp = false' "$CONFIG_FILE" > "$tmp_log" && mv "$tmp_log" "$CONFIG_FILE"

# 步骤 2: 端口霸占清理 (删除同端口旧节点)
tmp0=$(mktemp)
jq --argjson port "$PORT" 'del(.inbounds[]? | select(.listen_port == $port))' "$CONFIG_FILE" > "$tmp0" && mv "$tmp0" "$CONFIG_FILE"

# 步骤 3: 构建 Sing-box 标准 VLESS Vision JSON
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
        "users": [
            {
                "uuid": $uuid,
                "flow": "xtls-rprx-vision"
            }
        ],
        "tls": {
            "enabled": true,
            "server_name": $dest,
            "reality": {
                "enabled": true,
                "handshake": {
                    "server": $dest,
                    "server_port": 443
                },
                "private_key": $pk,
                "short_id": [$sid]
            }
        }
    }')

# 插入新节点
tmp=$(mktemp)
jq --argjson new_node "$NODE_JSON" 'if .inbounds == null then .inbounds = [] else . end | .inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 步骤 4: 写入伴生元数据 (.meta)
if [[ ! -f "$META_FILE" ]]; then echo "{}" > "$META_FILE"; fi
tmp_meta=$(mktemp)
jq --arg tag "$NODE_TAG" --arg pbk "$PUBLIC_KEY" --arg sid "$SHORT_ID" --arg sni "$SNI" \
   '. + {($tag): {"pbk": $pbk, "sid": $sid, "sni": $sni}}' "$META_FILE" > "$tmp_meta" && mv "$tmp_meta" "$META_FILE"

# 重启服务
echo -e "${YELLOW}正在重启服务...${PLAIN}"
systemctl restart sing-box
sleep 2


# --- 5. 输出反馈阶段 (Unified Output + Logging) ---
# 屏幕完整输出，自动模式额外存根

if systemctl is-active --quiet sing-box; then
    PUBLIC_IP=$(curl -s4m5 https://api.ip.sb/ip || curl -s4 ifconfig.me)
    NODE_NAME="$NODE_TAG"
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [Sing-box] 节点已追加/更新成功！    ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "端口        : ${YELLOW}${PORT}${PLAIN}"
    echo -e "SNI (伪装)  : ${YELLOW}${SNI}${PLAIN}"
    echo -e "流控 (Flow) : xtls-rprx-vision"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    echo -e "🐱 [Clash Meta / OpenClash 配置块]:"
    echo -e "${YELLOW}"
    cat <<EOF
- name: "${NODE_NAME}"
  type: vless
  server: ${PUBLIC_IP}
  port: ${PORT}
  uuid: ${UUID}
  network: tcp
  tls: true
  udp: true
  flow: xtls-rprx-vision
  servername: ${SNI}
  reality-opts:
    public-key: ${PUBLIC_KEY}
    short-id: ${SHORT_ID}
  client-fingerprint: chrome
EOF
    echo -e "${PLAIN}----------------------------------------"

    echo -e "📱 [Sing-box 客户端配置块]:"
    echo -e "${YELLOW}"
    cat <<EOF
{
  "type": "vless",
  "tag": "proxy-out",
  "server": "${PUBLIC_IP}",
  "server_port": ${PORT},
  "uuid": "${UUID}",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "${PUBLIC_KEY}",
      "short_id": "${SHORT_ID}"
    }
  }
}
EOF
    echo -e "${PLAIN}----------------------------------------"
    echo -e "${GREEN}提示: 节点公钥已备份至 ${META_FILE}，可随时使用查看菜单获取。${PLAIN}"
    
    # === [自动模式特有逻辑] 存根到文件 ===
    if [[ "$AUTO_SETUP" == "true" ]]; then
        LOG_FILE="/root/sb_nodes.txt"
        {
            echo "========================================"
            echo "Tag: ${NODE_TAG} | Time: $(date)"
            echo "--- v2rayN ---"
            echo "${SHARE_LINK}"
            echo "--- OpenClash ---"
            cat <<EOF_LOG
- name: "${NODE_NAME}"
  type: vless
  server: ${PUBLIC_IP}
  port: ${PORT}
  uuid: ${UUID}
  network: tcp
  tls: true
  udp: true
  flow: xtls-rprx-vision
  servername: ${SNI}
  reality-opts:
    public-key: ${PUBLIC_KEY}
    short-id: ${SHORT_ID}
  client-fingerprint: chrome
EOF_LOG
            echo "========================================"
            echo ""
        } >> "$LOG_FILE"
        echo -e "${SKYBLUE}>>> [自动记录] 节点信息已追加至: ${LOG_FILE}${PLAIN}"
    fi

else
    echo -e "${RED}启动失败！请检查日志: journalctl -u sing-box -e${PLAIN}"
fi
