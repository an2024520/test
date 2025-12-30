#!/bin/bash
echo "手动修复了SHARE_LIN无ws的host域名-暂未实测"
sleep 3

# ============================================================
#  模块九：VLESS + WS (Tunnel 专用版 / 无需证书)
#  - 版本: v1.3 (Force-Save Edition)
#  - 修复: 无论手动还是自动模式，强制保存节点信息到文件
#  - 适配: 完美支持 auto_deploy.sh 自动化部署
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

echo -e "${GREEN}>>> [模块九] 智能添加节点: VLESS + WebSocket (Tunnel专用)...${PLAIN}"

# --- 1. 环境检查 ---
if [[ ! -f "$XRAY_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Xray 核心！请先运行 [模块一]。${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}检测到缺少必要工具，正在安装 (jq, openssl)...${PLAIN}"
    apt update -y && apt install -y jq openssl
fi

# --- 2. 配置文件初始化 ---
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}配置文件不存在，正在初始化标准骨架...${PLAIN}"
    mkdir -p /usr/local/etc/xray
    cat <<EOF > $CONFIG_FILE
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "blocked", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      { "type": "field", "outboundTag": "blocked", "ip": ["geoip:private"] }
    ]
  }
}
EOF
fi

# --- 3. 参数获取 (自动/手动分流) ---
if [[ "$AUTO_SETUP" == "true" ]]; then
    # >>> 自动模式 >>>
    echo -e "${GREEN}>>> [自动模式] 正在读取参数...${PLAIN}"
    PORT=${XRAY_WS_PORT:-${PORT:-8080}}
    WS_PATH=${XRAY_WS_PATH:-${SB_WS_PATH:-"/ws"}}
    DOMAIN=${ARGO_DOMAIN}
    
    echo -e "监听端口: ${GREEN}$PORT${PLAIN}"
    echo -e "WS 路径 : ${GREEN}$WS_PATH${PLAIN}"
    echo -e "隧道域名: ${GREEN}$DOMAIN${PLAIN}"
else
    # >>> 手动模式 >>>
    echo -e "${YELLOW}--- 配置 Tunnel 对接节点 ---${PLAIN}"
    while true; do
        read -p "请输入 Xray 监听端口 (默认 8080): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && CUSTOM_PORT=8080
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            PORT="$CUSTOM_PORT"
            break
        else
            echo -e "${RED}无效端口。${PLAIN}"
        fi
    done

    read -p "请输入您在 Cloudflare Tunnel 绑定的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && echo -e "${RED}域名不能为空！${PLAIN}" && exit 1

    DEFAULT_PATH="/$(openssl rand -hex 4)"
    read -p "请输入 WebSocket 路径 (默认 ${DEFAULT_PATH}): " CUSTOM_WS_PATH
    WS_PATH=${CUSTOM_WS_PATH:-$DEFAULT_PATH}
fi

# --- 4. 资源生成 (UUID) ---
UUID=$($XRAY_BIN uuid)

# --- 5. 核心执行 (注入配置) ---
NODE_TAG="vless-ws-tunnel-${PORT}"

echo -e "${YELLOW}正在更新 Xray 配置...${PLAIN}"

# 双重清理：删除占用同端口(.port) 或 同Tag(.tag) 的旧配置
tmp_clean=$(mktemp)
jq --argjson p "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[]? | select(.port == $p or .tag == $tag))' \
   "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"

# 构建节点 JSON
# 强制监听 :: 以兼容 IPv4/IPv6 双栈
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg path "$WS_PATH" \
    '{
      tag: $tag,
      listen: "::",
      port: ($port | tonumber),
      protocol: "vless",
      settings: {
        clients: [{id: $uuid, flow: ""}],
        decryption: "none"
      },
      streamSettings: {
        network: "ws",
        security: "none",
        wsSettings: { path: $path }
      },
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls", "quic"],
        routeOnly: true
      }
    }')

# 注入新节点
tmp_add=$(mktemp)
jq --argjson new_node "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp_add" && mv "$tmp_add" "$CONFIG_FILE"

# 重启服务
systemctl restart xray
sleep 2

# --- 6. 输出反馈与保存 ---
if systemctl is-active --quiet xray; then
    NODE_NAME="Xray-Tunnel-${PORT}"
    # 链接生成：前端 443 TLS -> Tunnel -> 本地 8080
    SHARE_LINK="vless://${UUID}@${DOMAIN}:443?security=tls&encryption=none&type=ws&host=${DOMAIN}&path=${WS_PATH}&sni=${DOMAIN}&fp=chrome#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [Xray-Tunnel] 节点部署成功！        ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "本地监听    : ${YELLOW}:: (IPv4/IPv6 Dual Stack) :${PORT}${PLAIN}"
    echo -e "WS 路径     : ${YELLOW}${WS_PATH}${PLAIN}"
    echo -e "绑定域名    : ${YELLOW}${DOMAIN}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    # [核心修复] 无论何种模式，强制保存到文件
    echo "Tag: ${NODE_TAG} | Time: $(date)" >> "$LOG_FILE"
    echo "Link: ${SHARE_LINK}" >> "$LOG_FILE"
    echo "--------------------------------------------------" >> "$LOG_FILE"
    
    echo -e "${SKYBLUE}>>> 节点信息已保存至: ${LOG_FILE}${PLAIN}"
    echo -e "${SKYBLUE}>>> 您随时可以使用 'cat ${LOG_FILE}' 查看链接${PLAIN}"
else
    echo -e "${RED}启动失败！请检查日志: journalctl -u xray -e${PLAIN}"
    [[ "$AUTO_SETUP" == "true" ]] && exit 1
fi
