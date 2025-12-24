#!/bin/bash

# ============================================================
#  ICMP9 中转扩展模块 [VLESS 进阶版] (Relay Extension Pro)
#  架构: VLESS(In) -> Routing -> VMess(Out)
#  优化: 针对低配 VPS (1核256M) 优化，降低解密开销
#  场景: 专为 Cloudflare Tunnel (Argo) 设计
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 核心路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
BACKUP_FILE="/usr/local/etc/xray/config.json.bak"

# API 接口
API_CONFIG="https://api.icmp9.com/config/config.txt"
API_NODES="https://api.icmp9.com/online.php"

# 权限检查
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

# 依赖检查
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YELLOW}正在安装依赖 (jq)...${PLAIN}"
    apt-get update -qq && apt-get install -y jq -qq
fi

echo -e "${GREEN}>>> [VLESS 中转进阶版] 模块初始化...${PLAIN}"
echo -e "${SKYBLUE}提示: 本模式采用 VLESS 入站，性能优于 VMess，专为低配机器优化。${PLAIN}"

# ============================================================
# 1. 远程配置获取
# ============================================================
echo -e "${YELLOW}正在同步 ICMP9 远端配置...${PLAIN}"

RAW_CONFIG=$(curl -s --connect-timeout 10 "$API_CONFIG")
if [[ -z "$RAW_CONFIG" ]]; then
    echo -e "${RED}错误: API 连接失败，请检查网络连接。${PLAIN}"
    exit 1
fi

# 提取关键连接参数
REMOTE_HOST=$(echo "$RAW_CONFIG" | grep "^host|" | cut -d'|' -f2 | tr -d '\r\n')
REMOTE_PORT=$(echo "$RAW_CONFIG" | grep "^port|" | cut -d'|' -f2 | tr -d '\r\n')
REMOTE_WSHOST=$(echo "$RAW_CONFIG" | grep "^wshost|" | cut -d'|' -f2 | tr -d '\r\n')
REMOTE_TLS_FLAG=$(echo "$RAW_CONFIG" | grep "^tls|" | cut -d'|' -f2 | tr -d '\r\n')

# 确定后端安全策略
REMOTE_SECURITY="none"
[[ "$REMOTE_TLS_FLAG" == "1" ]] && REMOTE_SECURITY="tls"

if [[ -z "$REMOTE_HOST" || -z "$REMOTE_PORT" ]]; then
    echo -e "${RED}错误: 远端配置解析异常。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}API 同步成功: ${REMOTE_WSHOST}:${REMOTE_PORT} [${REMOTE_SECURITY}]${PLAIN}"

# ============================================================
# 2. 交互式配置 (ARGO 适配)
# ============================================================
echo -e "----------------------------------------------------"
echo -e "${SKYBLUE}步骤 1/2: 配置中转参数${PLAIN}"

# 2.1 鉴权 KEY
while true; do
    read -p "请输入 ICMP9 授权 KEY (UUID): " REMOTE_UUID
    if [[ -n "$REMOTE_UUID" ]]; then break; fi
    echo -e "${RED}不能为空${PLAIN}"
done

# 2.2 本地监听端口
echo -e ""
echo -e "${YELLOW}说明: 这是 Xray 在 VPS 内部监听的端口，Argo 隧道应转发到此端口。${PLAIN}"
read -p "请输入 VPS 本地监听端口 (默认 10086): " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-10086}

# 2.3 链路信息配置 (用于生成链接)
echo -e "----------------------------------------------------"
echo -e "${SKYBLUE}步骤 2/2: 配置 V2RayN 链接信息 (配合 Argo 隧道)${PLAIN}"

# 优选 IP / 域名
echo -e ""
echo -e "${YELLOW}1. 优选 IP 或 访问域名${PLAIN}"
echo -e "   (填入您在 V2RayN [地址/Address] 栏想显示的内容，如: www.visa.com 或 cf-ip.xyz)"
read -p "   请输入: " PUBLIC_ADDR
# 默认回退到自动获取 IP
[[ -z "$PUBLIC_ADDR" ]] && PUBLIC_ADDR=$(curl -s4 http://ip.sb)

# 公网端口
echo -e ""
echo -e "${YELLOW}2. 公网访问端口${PLAIN}"
echo -e "   (填入您在 V2RayN [端口/Port] 栏想显示的内容，Argo 通常为 443, 80, 2053 等)"
read -p "   请输入 (默认 443): " PUBLIC_PORT
PUBLIC_PORT=${PUBLIC_PORT:-443}

# Argo 域名
echo -e ""
echo -e "${YELLOW}3. Argo 隧道域名${PLAIN}"
echo -e "   (这是您在 Cloudflare Tunnel 绑定的域名，将用于 TLS SNI 和 WS Host)"
echo -e "   (例如: tunnel.mysite.com)"
while true; do
    read -p "   请输入: " ARGO_DOMAIN
    if [[ -n "$ARGO_DOMAIN" ]]; then break; fi
    echo -e "${RED}域名不能为空，否则 VLESS 无法连接${PLAIN}"
done

# 生成本地 UUID
LOCAL_UUID=$(/usr/local/bin/xray_core/xray uuid)

# ============================================================
# 3. 配置文件生成 (核心逻辑)
# ============================================================
echo -e "----------------------------------------------------"
echo -e "${YELLOW}正在拉取节点列表并构建路由规则...${PLAIN}"

# 获取国家列表
NODES_JSON=$(curl -s "$API_NODES")
COUNTRY_CODES=$(echo "$NODES_JSON" | jq -r '.countries[]? | .code')

if [[ -z "$COUNTRY_CODES" ]]; then
    echo -e "${RED}错误: 无法获取节点列表。${PLAIN}"
    exit 1
fi

# 备份配置
cp "$CONFIG_FILE" "$BACKUP_FILE"

# --- 3.1 清理旧配置 ---
echo -e "${YELLOW}清理旧模块数据...${PLAIN}"
# 删除所有 tag 以 "icmp9-" 开头的配置
jq '
  .inbounds |= map(select(.tag | startswith("icmp9-") | not)) |
  .outbounds |= map(select(.tag | startswith("icmp9-") | not)) |
  .routing.rules |= map(select(.outboundTag | startswith("icmp9-") | not))
' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"


# --- 3.2 构造 VLESS Inbound (入站) ---
# 协议: VLESS
# 传输: WS (路径 /)
# 解密: none (交给传输层处理，降低 CPU)
jq --arg port "$LOCAL_PORT" --arg uuid "$LOCAL_UUID" '.inbounds += [{
  "tag": "icmp9-relay-in",
  "port": ($port | tonumber),
  "protocol": "vless",
  "settings": {
    "clients": [{"id": $uuid}],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "ws",
    "security": "none",
    "wsSettings": { "path": "/" }
  }
}]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"


# --- 3.3 批量构造 Outbounds 和 Rules ---
TEMP_OUTS="/tmp/icmp9_outs.json"
TEMP_RULES="/tmp/icmp9_rules.json"
echo "[]" > "$TEMP_OUTS"
echo "[]" > "$TEMP_RULES"

# 循环处理每个国家节点
for code in $COUNTRY_CODES; do
    # Outbound: VMess + WS + TLS
    # 注意: 这是 VPS -> ICMP9 的连接，必须加密
    jq --arg code "$code" \
       --arg host "$REMOTE_HOST" \
       --arg port "$REMOTE_PORT" \
       --arg uuid "$REMOTE_UUID" \
       --arg wshost "$REMOTE_WSHOST" \
       --arg security "$REMOTE_SECURITY" \
       '. + [{
          "tag": ("icmp9-out-" + $code),
          "protocol": "vmess",
          "settings": {
            "vnext": [{
              "address": $host,
              "port": ($port | tonumber),
              "users": [{"id": $uuid, "security": "auto"}]
            }]
          },
          "streamSettings": {
            "network": "ws",
            "security": $security,
            "tlsSettings": (if $security == "tls" then {"serverName": $wshost} else null end),
            "wsSettings": {
              "path": ("/" + $code),
              "headers": {"Host": $wshost}
            }
          }
       }]' "$TEMP_OUTS" > "${TEMP_OUTS}.tmp" && mv "${TEMP_OUTS}.tmp" "$TEMP_OUTS"

    # Routing Rule: 路径分流
    # 匹配 VLESS 入站路径 /relay/hk -> 转发到 icmp9-out-hk
    jq --arg code "$code" \
       '. + [{
          "type": "field",
          "inboundTag": ["icmp9-relay-in"],
          "outboundTag": ("icmp9-out-" + $code),
          "path": [("/relay/" + $code)]
       }]' "$TEMP_RULES" > "${TEMP_RULES}.tmp" && mv "${TEMP_RULES}.tmp" "$TEMP_RULES"
done

# --- 3.4 注入配置 ---
# 注入 Outbounds
jq --slurpfile new_outs "$TEMP_OUTS" '.outbounds += $new_outs[0]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

# 注入 Rules (添加到数组头部，确保优先级)
jq --slurpfile new_rules "$TEMP_RULES" '.routing.rules = ($new_rules[0] + .routing.rules)' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

rm -f "$TEMP_OUTS" "$TEMP_RULES" "${CONFIG_FILE}.tmp"

# ============================================================
# 4. 服务重启与结果输出
# ============================================================
echo -e "${YELLOW}重启 Xray 服务以应用更改...${PLAIN}"
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    echo -e "${GREEN}>>> 部署成功！VLESS 中转服务已就绪。${PLAIN}"
    echo -e ""
    echo -e "----------------------------------------------------"
    echo -e " [本地配置信息] (用于 Cloudflare Tunnel)"
    echo -e " 协议: http (或 ws)"
    echo -e " 地址: localhost:${LOCAL_PORT}"
    echo -e "----------------------------------------------------"
    echo -e " [V2RayN 订阅/节点信息] (已生成完整链接)"
    echo -e " 优选地址: ${SKYBLUE}${PUBLIC_ADDR}:${PUBLIC_PORT}${PLAIN}"
    echo -e " 伪装域名: ${SKYBLUE}${ARGO_DOMAIN}${PLAIN}"
    echo -e " 协议类型: ${GREEN}VLESS + WS + TLS${PLAIN}"
    echo -e ""

    # 生成 V2RayN 链接
    echo "$NODES_JSON" | jq -c '.countries[]?' | while read -r item; do
        CODE=$(echo "$item" | jq -r '.code')
        NAME=$(echo "$item" | jq -r '.name')
        EMOJI=$(echo "$item" | jq -r '.emoji')
        
        # 别名
        PS_NAME="${EMOJI} ${NAME} [中转]"
        
        # 路径: 这里的路径对应 Routing Rule 的匹配规则
        PATH_VAL="/relay/${CODE}"
        
        # VLESS URL 格式:
        # vless://uuid@host:port?encryption=none&security=tls&sni=sni_domain&type=ws&host=ws_host&path=ws_path#Name
        
        # 构造 URL 参数
        LINK="vless://${LOCAL_UUID}@${PUBLIC_ADDR}:${PUBLIC_PORT}?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=${PATH_VAL}#${PS_NAME}"
        
        # URL 编码处理 (简单的处理空格)
        LINK=${LINK// /%20}
        
        echo -e "${PLAIN}${LINK}${PLAIN}"
    done
    
    echo -e ""
    echo -e "${SKYBLUE}提示: 请复制以上以 vless:// 开头的链接到 V2RayN。${PLAIN}"
    echo -e "${SKYBLUE}注意: 请确保您的 Cloudflare Tunnel 已正确配置，将流量转发到 localhost:${LOCAL_PORT}。${PLAIN}"
else
    echo -e "${RED}错误: Xray 重启失败！正在回滚配置...${PLAIN}"
    cp "$BACKUP_FILE" "$CONFIG_FILE"
    systemctl restart xray
    echo -e "${RED}回滚完成。请检查 config.json 格式或端口冲突。${PLAIN}"
fi
