#!/bin/bash

# ============================================================
#  模块三：VLESS + TCP + Reality + Vision (极致稳定版)
#  - 模式: Manual (交互式) / Auto (自动部署)
#  - 适配: 支持 auto_deploy.sh 传参 (PORT, AUTO_SETUP)
#  - 修复: 自动清理同端口/同Tag旧节点，防止 Xray 启动冲突
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 核心路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray_core/xray"

echo -e "${GREEN}>>> [模块三] 智能添加节点: VLESS + TCP + Reality + Vision ...${PLAIN}"

# 1. 环境检查
if [[ ! -f "$XRAY_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Xray 核心！请先运行 [模块一] 打地基。${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
    echo -e "${YELLOW}检测到缺少必要工具，正在安装 (jq, openssl)...${PLAIN}"
    apt update -y && apt install -y jq openssl
fi

# 2. 配置文件初始化
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}配置文件不存在，由本模块初始化标准骨架...${PLAIN}"
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
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {
        "type": "field",
        "outboundTag": "blocked",
        "ip": ["geoip:private"]
      }
    ]
  }
}
EOF
    echo -e "${GREEN}标准骨架初始化完成。${PLAIN}"
fi

# 3. 用户配置参数 (自动/手动分流核心)
if [[ "$AUTO_SETUP" == "true" ]]; then
    # === 自动模式 ===
    echo -e "${YELLOW}>>> [自动模式] 读取环境配置...${PLAIN}"
    # 端口: 优先读环境变量，否则默认 8443
    PORT="${PORT:-8443}"
    echo -e "    端口 (PORT): ${GREEN}${PORT}${PLAIN}"
    
    # 域名: 自动模式下默认使用微软 (稳健)
    SNI="www.microsoft.com"
    echo -e "    伪装 (SNI) : ${GREEN}${SNI}${PLAIN}"
    
else
    # === 手动模式 (原汁原味) ===
    echo -e "${YELLOW}--- 配置 Vision 节点参数 ---${PLAIN}"
    echo -e "${YELLOW}注意: Vision 协议通常占用 443 端口效果最好，但为了模块共存，你可以自定义。${PLAIN}"

    # A. 端口设置
    while true; do
        read -p "请输入监听端口 (推荐 443 或 8443, 默认 8443): " CUSTOM_PORT
        [[ -z "$CUSTOM_PORT" ]] && PORT=8443 && break
        if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
            # 这里的 grep 检查只是简单的文本匹配，主要逻辑依靠 jq 清理
            if grep -q "\"port\": $CUSTOM_PORT" "$CONFIG_FILE"; then
                 echo -e "${RED}警告: 端口 $CUSTOM_PORT 似乎已被之前的模块占用了 (建议清理后再试)${PLAIN}"
                 # 手动模式下允许用户头铁继续，反正后面会强制清理覆盖
                 PORT="$CUSTOM_PORT"
                 break
            else
                 PORT="$CUSTOM_PORT"
                 break
            fi
        else
            echo -e "${RED}无效端口。${PLAIN}"
        fi
    done

    # B. 伪装域名选择
    echo -e "${YELLOW}请选择伪装域名 (SNI) - 既然是Vision，推荐大厂域名:${PLAIN}"
    echo -e "  1. www.microsoft.com (微软 - 稳如老狗)"
    echo -e "  2. www.apple.com (苹果 - 经典)"
    echo -e "  3. www.amazon.com (亚马逊 - 电商流量)"
    echo -e "  4. ${GREEN}手动输入${PLAIN}"
    read -p "请选择 [1-4] (默认 1): " SNI_CHOICE

    case $SNI_CHOICE in
        2) SNI="www.apple.com" ;;
        3) SNI="www.amazon.com" ;;
        4) 
            read -p "请输入域名 (不带https://): " MANUAL_SNI
            [[ -z "$MANUAL_SNI" ]] && SNI="www.microsoft.com" || SNI="$MANUAL_SNI"
            ;;
        *) SNI="www.microsoft.com" ;;
    esac
fi

# 4. 生成密钥 (使用 Xray 生成 UUID)
echo -e "${YELLOW}正在生成独立密钥...${PLAIN}"

# 无论自动还是手动，这里的生成逻辑通用
UUID=$($XRAY_BIN uuid)
SHORT_ID=$(openssl rand -hex 8) 
RAW_KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$RAW_KEYS" | grep "Private" | awk -F ":" '{print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$RAW_KEYS" | grep -E "Password|Public" | awk -F ":" '{print $2}' | tr -d ' \r\n')

# 5. 构建节点 JSON
echo -e "${YELLOW}正在注入 Vision 节点...${PLAIN}"

NODE_TAG="vless-vision-${PORT}"

# ==========================================================
# [关键修复] 先清理旧的同 Tag 或同端口配置，防止启动冲突
# ==========================================================
tmp_clean=$(mktemp)
jq --arg port "$PORT" --arg tag "$NODE_TAG" \
   'del(.inbounds[] | select(.tag == $tag or .port == ($port | tonumber)))' \
   "$CONFIG_FILE" > "$tmp_clean" && mv "$tmp_clean" "$CONFIG_FILE"

NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg uuid "$UUID" \
    --arg sni "$SNI" \
    --arg pk "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" \
    '{
      tag: $tag,
      listen: "::",
      port: ($port | tonumber),
      protocol: "vless",
      settings: {
        clients: [{
            id: $uuid, 
            flow: "xtls-rprx-vision"
        }],
        decryption: "none"
      },
      streamSettings: {
        network: "tcp",
        security: "reality",
        realitySettings: {
          show: false,
          dest: ($sni + ":443"),
          serverNames: [$sni],
          privateKey: $pk,
          shortIds: [$sid]
        }
      },
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls", "quic"],
        routeOnly: true
      }
    }')

tmp=$(mktemp)
# 安全追加新节点
jq --argjson new_node "$NODE_JSON" '.inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# 6. 重启与输出
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    PUBLIC_IP=$(curl -s4 ifconfig.me)
    # 自动模式下，节点命名可能需要一点区分，这里保持统一即可
    NODE_NAME="Xray-Vision-${PORT}"
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}&fp=chrome#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [模块三] Vision 节点部署成功！      ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "协议特性    : VLESS + Reality + ${YELLOW}Vision (TCP)${PLAIN}"
    echo -e "监听端口    : ${YELLOW}${PORT}${PLAIN}"
    echo -e "伪装域名    : ${YELLOW}${SNI}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    
    # === 新增：OpenClash / Meta 输出 ===
    echo -e "🐱 [OpenClash / Meta 配置块]:"
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
  client-fingerprint: chrome
  reality-opts:
    public-key: ${PUBLIC_KEY}
    short-id: ${SHORT_ID}
EOF
    echo -e "${PLAIN}----------------------------------------"

else
    echo -e "${RED}启动失败！${PLAIN}"
    echo -e "请检查日志: journalctl -u xray -e"
    # 自动模式下失败也需要退出码，方便主脚本判断
    if [[ "$AUTO_SETUP" == "true" ]]; then exit 1; fi
fi
