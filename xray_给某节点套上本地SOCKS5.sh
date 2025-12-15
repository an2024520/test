#!/bin/bash

# ============================================================
#  模块六：节点分流挂载器 (给现有节点套上 WARP/Socks5)
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 核心路径
CONFIG_FILE="/usr/local/etc/xray/config.json"

echo -e "${GREEN}>>> [模块六] 节点分流挂载器 (Router)...${PLAIN}"

# 1. 基础环境检查
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 配置文件不存在！请先运行前序模块建立节点。${PLAIN}"
    exit 1
fi
if ! command -v jq &> /dev/null; then
    apt update -y && apt install -y jq
fi

# 2. 配置 SOCKS5 出口通道
# -----------------------------------------------------------
echo -e "${YELLOW}--- 第一步：配置出口代理 (SOCKS5) ---${PLAIN}"
echo -e "请输入 SOCKS5 代理地址 (通常是 WARP 或其他代理)"

# 输入 IP
read -p "代理 IP (默认 127.0.0.1): " PROXY_IP
[[ -z "$PROXY_IP" ]] && PROXY_IP="127.0.0.1"

# 输入端口
while true; do
    read -p "代理 端口 (例如 40000): " PROXY_PORT
    if [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -le 65535 ]; then
        break
    else
        echo -e "${RED}请输入有效的端口号。${PLAIN}"
    fi
done

# 检测连通性
echo -e "${YELLOW}正在测试代理连通性 ($PROXY_IP:$PROXY_PORT)...${PLAIN}"
# 尝试通过代理访问 Google，超时设置为 5 秒
if curl -s --max-time 5 -x socks5://$PROXY_IP:$PROXY_PORT https://www.google.com >/dev/null; then
    echo -e "${GREEN}代理连接成功！${PLAIN}"
else
    echo -e "${RED}连接失败！该代理似乎无法访问外网。${PLAIN}"
    echo -e "请检查 WARP 是否启动，或 IP/端口是否正确。"
    read -p "是否强制继续配置? (y/n): " FORCE
    [[ "$FORCE" != "y" ]] && exit 1
fi

# 3. 将 SOCKS5 写入出站 (Outbounds)
# -----------------------------------------------------------
# 定义这个出口的唯一标识 Tag
PROXY_TAG="custom-socks-out-$PROXY_PORT"

# 检查该配置是否已存在
IS_EXIST=$(jq --arg tag "$PROXY_TAG" '.outbounds[] | select(.tag == $tag)' "$CONFIG_FILE")

if [[ -z "$IS_EXIST" ]]; then
    echo -e "${YELLOW}正在添加出站规则...${PLAIN}"
    OUTBOUND_JSON=$(jq -n --arg tag "$PROXY_TAG" --arg ip "$PROXY_IP" --argjson port "$PROXY_PORT" '{
        tag: $tag,
        protocol: "socks",
        settings: {
            servers: [{
                address: $ip,
                port: $port
            }]
        }
    }')
    tmp=$(mktemp)
    jq --argjson new_out "$OUTBOUND_JSON" '.outbounds += [$new_out]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
else
    echo -e "该出口规则已存在，复用现有配置。"
fi

# 4. 选择要挂载 WARP 的现有节点
# -----------------------------------------------------------
echo -e ""
echo -e "${YELLOW}--- 第二步：选择要“变身”的节点 ---${PLAIN}"
echo -e "请从下方列表中选择一个节点，它的流量将被强制转发到刚才配置的代理。"
echo -e "----------------------------------------------------"
printf "%-25s %-10s %-15s\n" "节点标识 (Tag)" "端口" "协议"
echo -e "----------------------------------------------------"

# 列出节点 (复用模块四逻辑)
jq -r '.inbounds[] | "\(.tag) \(.port) \(.protocol)"' "$CONFIG_FILE" | while read -r tag port proto; do
    printf "${SKYBLUE}%-25s${PLAIN} ${GREEN}%-10s${PLAIN} %-15s\n" "$tag" "$port" "$proto"
done
echo -e "----------------------------------------------------"

read -p "请输入目标节点的 [端口号]: " TARGET_PORT

if [[ -z "$TARGET_PORT" ]]; then
    echo -e "操作取消。"
    exit 0
fi

# 获取该端口对应的 Tag
TARGET_NODE_TAG=$(jq -r --argjson p "$TARGET_PORT" '.inbounds[] | select(.port == $p) | .tag' "$CONFIG_FILE")

if [[ -z "$TARGET_NODE_TAG" ]] || [[ "$TARGET_NODE_TAG" == "null" ]]; then
    echo -e "${RED}错误: 找不到端口为 $TARGET_PORT 的节点。${PLAIN}"
    exit 1
fi

echo -e "已选中节点: ${GREEN}$TARGET_NODE_TAG${PLAIN}"

# 5. 写入路由规则 (Routing Rules)
# -----------------------------------------------------------
echo -e "${YELLOW}正在应用路由规则 (Traffic Hijack)...${PLAIN}"

# 逻辑：InboundTag(选中节点) -> OutboundTag(Socks代理)
# 注意：我们将这条规则插入到 rules 数组的 [0] 位置（最前面），确保优先级最高，覆盖旧规则
RULE_JSON=$(jq -n \
    --arg inTag "$TARGET_NODE_TAG" \
    --arg outTag "$PROXY_TAG" \
    '{
        type: "field",
        inboundTag: [$inTag],
        outboundTag: $outTag
    }')

tmp_rule=$(mktemp)
# 使用 + 运算符将新规则加在数组头部
jq --argjson new_rule "$RULE_JSON" '.routing.rules = [$new_rule] + .routing.rules' "$CONFIG_FILE" > "$tmp_rule" && mv "$tmp_rule" "$CONFIG_FILE"

# 6. 重启与验证
# -----------------------------------------------------------
systemctl restart xray
sleep 1

if systemctl is-active --quiet xray; then
    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    [模块六] 挂载成功！                ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "目标节点端口 : ${YELLOW}${TARGET_PORT}${PLAIN}"
    echo -e "流量出口     : ${SKYBLUE}${PROXY_IP}:${PROXY_PORT}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "现在，当你连接端口 ${TARGET_PORT} 时，"
    echo -e "你的 IP 将变更为代理的 IP (Cloudflare WARP)。"
    echo -e "你可以访问 ip111.cn 进行验证。"
else
    echo -e "${RED}Xray 重启失败，请检查日志。${PLAIN}"
    journalctl -u xray -e | tail -n 20
fi
