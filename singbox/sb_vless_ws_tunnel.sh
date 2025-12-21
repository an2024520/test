#!/bin/bash

# ============================================================
#  Sing-box 节点新增: VLESS + WS (Tunnel 专用)
#  - 协议: VLESS + WebSocket (无 TLS)
#  - 场景: 专用于 Cloudflare Tunnel 后端，或 Nginx 前置反代
#  - 特性: 极简配置 / Systemd 日志托管 / 端口霸占清理
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 核心路径
CONFIG_FILE="/usr/local/etc/sing-box/config.json"
SB_BIN="/usr/local/bin/sing-box"

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: VLESS + WS (无TLS / Tunnel专用) ...${PLAIN}"

# 1. 环境检查
if [[ ! -f "$SB_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Sing-box 核心！请先运行 [核心环境管理] 安装。${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}检测到缺少必要工具，正在安装 (jq, openssl)...${PLAIN}"
    apt update -y && apt install -y jq openssl
fi

# 2. 初始化配置文件 (Systemd 日志托管模式)
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}配置文件不存在，正在初始化标准骨架...${PLAIN}"
    mkdir -p /usr/local/etc/sing-box
    cat <<EOF > $CONFIG_FILE
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

# 3. 用户配置参数
echo -e "${YELLOW}--- 配置 VLESS-WS (Tunnel) 参数 ---${PLAIN}"

# A. 端口设置
# Tunnel 常用端口通常是 8080, 80, 或者是任意高位端口
while true; do
    read -p "请输入监听端口 (推荐 8080, 80, 或任意端口): " CUSTOM_PORT
    [[ -z "$CUSTOM_PORT" ]] && PORT=8080 && break
    
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

# B. WS 路径
read -p "请输入 WebSocket 路径 (默认 /ws): " WS_PATH
[[ -z "$WS_PATH" ]] && WS_PATH="/ws"
if [[ "${WS_PATH:0:1}" != "/" ]]; then WS_PATH="/$WS_PATH"; fi

# 4. 生成 UUID
UUID=$($SB_BIN generate uuid)

# 5. 构建与注入节点
echo -e "${YELLOW}正在更新配置文件...${PLAIN}"

NODE_TAG="vless-tunnel-${PORT}"

# === 步骤 1: 强制日志托管 (防止 Permission Denied) ===
tmp_log=$(mktemp)
jq '.log.output = "" | .log.timestamp = false' "$CONFIG_FILE" > "$tmp_log" && mv "$tmp_log" "$CONFIG_FILE"

# === 步骤 2: 端口霸占清理 (防止 bind error) ===
tmp0=$(mktemp)
jq --argjson port "$PORT" 'del(.inbounds[] | select(.listen_port == $port))' "$CONFIG_FILE" > "$tmp0" && mv "$tmp0" "$CONFIG_FILE"

# === 步骤 3: 构建 Sing-box VLESS WS (No TLS) JSON ===
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
        "users": [
            {
                "uuid": $uuid
            }
        ],
        "transport": {
            "type": "ws",
            "path": $path
        }
    }')

# 插入新节点
tmp=$(mktemp)
jq --argjson new_node "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 6. 重启与输出
echo -e "${YELLOW}正在重启服务...${PLAIN}"
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    PUBLIC_IP="127.0.0.1" # Tunnel 节点通常配合本机 Tunnel 使用，显示 127.0.0.1 更准确
    REAL_IP=$(curl -s4m5 https://api.ip.sb/ip || curl -s4 ifconfig.me)
    NODE_NAME="SB-Tunnel-${PORT}"
    
    # 构造 v2rayN 链接
    # 格式: vless://uuid@ip:port?encryption=none&security=none&type=ws&path=/path#name
    # 注意: security=none 表示无 TLS
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&security=none&type=ws&path=${WS_PATH}#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [Sing-box] Tunnel 节点添加成功！    ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "端口 (Port) : ${YELLOW}${PORT}${PLAIN}"
    echo -e "路径 (Path) : ${YELLOW}${WS_PATH}${PLAIN}"
    echo -e "UUID        : ${SKYBLUE}${UUID}${PLAIN}"
    echo -e "TLS 状态    : ${RED}关闭 (Off)${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "⚠️ [使用说明]:"
    echo -e "此节点没有 TLS 加密，${RED}不建议直接暴露在公网${PLAIN}。"
    echo -e "请在 Cloudflare Tunnel 配置中，将 Service 指向: ${GREEN}http://localhost:${PORT}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [本地测试链接] (v2rayN):"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    # === OpenClash / Meta 配置块 ===
    echo -e "🐱 [Clash Meta / OpenClash 配置块] (配合 Tunnel 使用):"
    echo -e "${YELLOW}"
    cat <<EOF
- name: "${NODE_NAME}"
  type: vless
  server: <Tunnel域名>
  port: 443
  uuid: ${UUID}
  network: ws
  tls: true
  udp: true
  servername: <Tunnel域名>
  ws-opts:
    path: "${WS_PATH}"
    headers:
      Host: <Tunnel域名>
  client-fingerprint: chrome
EOF
    echo -e "${PLAIN}----------------------------------------"
    echo -e "${GRAY}* 注意: 在 Clash 填入时，Server 和 Host 需填入你在 CF Tunnel 绑定的公网域名。${PLAIN}"

    # === Sing-box 客户端配置块 ===
    echo -e "📱 [Sing-box 客户端配置块]:"
    echo -e "${YELLOW}"
    cat <<EOF
{
  "type": "vless",
  "tag": "proxy-out",
  "server": "<Tunnel域名>",
  "server_port": 443,
  "uuid": "${UUID}",
  "tls": {
    "enabled": true,
    "server_name": "<Tunnel域名>",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    }
  },
  "transport": {
    "type": "ws",
    "path": "${WS_PATH}"
  }
}
EOF
    echo -e "${PLAIN}----------------------------------------"

else
    echo -e "${RED}启动失败！请检查日志: journalctl -u sing-box -e${PLAIN}"
fi
