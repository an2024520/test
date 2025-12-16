#!/bin/bash

# ============================================================
#  模块六 (v3.0)：批量节点分流挂载器 (支持 手动批量 / 一键全选)
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
GRAY='\033[0;37m'

# 核心路径
CONFIG_FILE="/usr/local/etc/xray/config.json"
BACKUP_FILE="/usr/local/etc/xray/config.json.bak"

echo -e "${GREEN}>>> [模块六] 智能分流挂载器 (Smart Router v3.0)...${PLAIN}"

# 1. 基础环境检查
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 配置文件不存在！${PLAIN}"
    exit 1
fi
if ! command -v jq &> /dev/null; then
    apt update -y && apt install -y jq
fi

# 2. 配置 SOCKS5 出口通道
# -----------------------------------------------------------
echo -e "${YELLOW}--- 第一步：配置/确认出口代理 ---${PLAIN}"
echo -e "请输入 SOCKS5 代理地址 (通常是 WARP 或其他代理)"

read -p "代理 IP (默认 127.0.0.1): " PROXY_IP
[[ -z "$PROXY_IP" ]] && PROXY_IP="127.0.0.1"

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
if curl -s --max-time 4 -x socks5://$PROXY_IP:$PROXY_PORT https://www.google.com >/dev/null; then
    echo -e "${GREEN}代理连接成功！${PLAIN}"
else
    echo -e "${RED}连接失败！该代理似乎无法访问外网。${PLAIN}"
    read -p "是否强制继续配置? (y/n): " FORCE
    [[ "$FORCE" != "y" ]] && exit 1
fi

# 3. 写入出站规则 (Outbound)
# -----------------------------------------------------------
PROXY_TAG="custom-socks-out-$PROXY_PORT"
IS_EXIST=$(jq --arg tag "$PROXY_TAG" '.outbounds[] | select(.tag == $tag)' "$CONFIG_FILE")

if [[ -z "$IS_EXIST" ]]; then
    echo -e "${YELLOW}正在添加出站规则...${PLAIN}"
    OUTBOUND_JSON=$(jq -n --arg tag "$PROXY_TAG" --arg ip "$PROXY_IP" --argjson port "$PROXY_PORT" '{
        tag: $tag,
        protocol: "socks",
        settings: { servers: [{ address: $ip, port: $port }] }
    }')
    tmp=$(mktemp)
    jq --argjson new_out "$OUTBOUND_JSON" '.outbounds += [$new_out]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
fi

# 4. 扫描并展示可用节点
# -----------------------------------------------------------
echo -e ""
echo -e "${YELLOW}--- 第二步：选择要“变身”的节点 ---${PLAIN}"
echo -e "以下是目前 **尚未被挂载** 代理的“自由”节点："
echo -e "----------------------------------------------------"
printf "%-25s %-10s %-15s\n" "节点标识 (Tag)" "端口" "协议"
echo -e "----------------------------------------------------"

# 获取“忙碌”的 Tag 列表 (已经在路由规则里的)
BUSY_TAGS=$(jq -r '[.routing.rules[] | select(.inboundTag != null) | .inboundTag[]] | join(" ")' "$CONFIG_FILE")

# 定义一个数组，用来存储所有“可用”的端口
declare -a ALL_AVAILABLE_PORTS

# 使用 <(...) 进程替换，避免 while 循环在子 Shell 中运行导致变量无法保存
while read -r tag port proto; do
    # 检查当前 tag 是否出现在 BUSY_TAGS 字符串中
    if [[ " $BUSY_TAGS " =~ " $tag " ]]; then
        continue # 跳过忙碌节点
    else
        printf "${SKYBLUE}%-25s${PLAIN} ${GREEN}%-10s${PLAIN} %-15s\n" "$tag" "$port" "$proto"
        # 将端口加入数组
        ALL_AVAILABLE_PORTS+=("$port")
    fi
done < <(jq -r '.inbounds[] | "\(.tag) \(.port) \(.protocol)"' "$CONFIG_FILE")

echo -e "----------------------------------------------------"

AVAILABLE_COUNT=${#ALL_AVAILABLE_PORTS[@]}

if [[ "$AVAILABLE_COUNT" == "0" ]]; then
    echo -e "${GRAY}提示: 所有节点都已经挂载了代理，无需操作。${PLAIN}"
    exit 0
fi

# 5. 操作模式选择 (新增功能)
# -----------------------------------------------------------
echo -e "${YELLOW}请选择挂载模式:${PLAIN}"
echo -e "  1. ${GREEN}手动输入${PLAIN} (输入特定端口，支持批量)"
echo -e "  2. ${SKYBLUE}全部挂载${PLAIN} (将列表中的 ${AVAILABLE_COUNT} 个节点全部挂载)"
read -p "请选择 [1-2]: " MODE_CHOICE

declare -a TARGET_PORTS_ARRAY

case $MODE_CHOICE in
    2)
        # === 模式 2: 全选 ===
        echo -e "${SKYBLUE}已选择全部挂载。${PLAIN}"
        # 直接将之前存好的所有可用端口复制给目标数组
        TARGET_PORTS_ARRAY=("${ALL_AVAILABLE_PORTS[@]}")
        ;;
    *)
        # === 模式 1: 手动 (默认) ===
        echo -e "${YELLOW}请输入要挂载代理的端口号 (支持批量)${PLAIN}"
        echo -e "说明: 用空格分隔多个端口，例如: ${GREEN}2053 8443${PLAIN}"
        read -p "目标端口: " INPUT_PORTS
        
        if [[ -z "$INPUT_PORTS" ]]; then
            echo -e "操作取消。"
            exit 0
        fi
        read -a TARGET_PORTS_ARRAY <<< "$INPUT_PORTS"
        ;;
esac

# 6. 批量执行挂载
# -----------------------------------------------------------
echo -e "${YELLOW}正在配置路由规则...${PLAIN}"
cp "$CONFIG_FILE" "$BACKUP_FILE"
CHANGE_COUNT=0

for TARGET_PORT in "${TARGET_PORTS_ARRAY[@]}"; do
    # 验证数字
    if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}跳过: '$TARGET_PORT' 不是有效的端口号。${PLAIN}"
        continue
    fi

    # 查找 Tag
    TARGET_NODE_TAG=$(jq -r --argjson p "$TARGET_PORT" '.inbounds[] | select(.port == $p) | .tag' "$CONFIG_FILE")

    if [[ -z "$TARGET_NODE_TAG" ]] || [[ "$TARGET_NODE_TAG" == "null" ]]; then
        echo -e "${RED}跳过: 找不到端口为 $TARGET_PORT 的节点。${PLAIN}"
        continue
    fi

    # 二次检查
    if [[ " $BUSY_TAGS " =~ " $TARGET_NODE_TAG " ]]; then
        echo -e "${RED}跳过: 节点 $TARGET_NODE_TAG 已经挂载了代理。${PLAIN}"
        continue
    fi

    echo -e "  -> 处理中: ${SKYBLUE}$TARGET_NODE_TAG${PLAIN} (${GREEN}$TARGET_PORT${PLAIN})"

    # 写入路由规则
    RULE_JSON=$(jq -n \
        --arg inTag "$TARGET_NODE_TAG" \
        --arg outTag "$PROXY_TAG" \
        '{
            type: "field",
            inboundTag: [$inTag],
            outboundTag: $outTag
        }')

    tmp_rule=$(mktemp)
    jq --argjson new_rule "$RULE_JSON" '.routing.rules = [$new_rule] + .routing.rules' "$CONFIG_FILE" > "$tmp_rule" && mv "$tmp_rule" "$CONFIG_FILE"
    
    ((CHANGE_COUNT++))
done

# 7. 重启与验证
# -----------------------------------------------------------
if [[ "$CHANGE_COUNT" -gt 0 ]]; then
    echo -e "----------------------------------------"
    echo -e "${YELLOW}正在重启 Xray 以应用 ${CHANGE_COUNT} 个更改...${PLAIN}"
    systemctl restart xray
    sleep 1

    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${GREEN}    操作成功！${PLAIN}"
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "已为 ${CHANGE_COUNT} 个节点挂载了代理出口: ${PROXY_IP}:${PROXY_PORT}"
    else
        echo -e "${RED}重启失败！正在回滚...${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        systemctl restart xray
    fi
else
    echo -e "${YELLOW}未做任何有效更改。${PLAIN}"
fi
