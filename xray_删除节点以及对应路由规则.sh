#!/bin/bash

# ============================================================
#  模块四 (v3.0)：批量智能级联拆除工具 (支持一次删多个)
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

echo -e "${RED}>>> [模块四] 批量智能节点拆除工具 (Multi-Delete)...${PLAIN}"

# 1. 检查配置文件
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 找不到配置文件！${PLAIN}"
    exit 1
fi
if ! command -v jq &> /dev/null; then
    apt update -y && apt install -y jq
fi

# 2. 列出当前节点
echo -e "${YELLOW}正在读取当前运行的节点列表...${PLAIN}"
echo -e "----------------------------------------------------"
printf "%-25s %-10s %-15s\n" "节点标识 (Tag)" "端口" "协议"
echo -e "----------------------------------------------------"

NODE_COUNT=$(jq '.inbounds | length' "$CONFIG_FILE")
if [[ "$NODE_COUNT" == "0" ]]; then
    echo -e "${RED}当前没有配置任何节点！${PLAIN}"
    exit 0
fi

jq -r '.inbounds[] | "\(.tag) \(.port) \(.protocol)"' "$CONFIG_FILE" | while read -r tag port proto; do
    printf "${SKYBLUE}%-25s${PLAIN} ${GREEN}%-10s${PLAIN} %-15s\n" "$tag" "$port" "$proto"
done
echo -e "----------------------------------------------------"

# 3. 用户输入 (支持多个端口)
# -----------------------------------------------------------
echo -e "${YELLOW}请输入要删除的端口号 (支持批量删除)${PLAIN}"
echo -e "说明: 如果要删除多个，请用空格分隔，例如: ${GREEN}2053 8443 32111${PLAIN}"
read -p "目标端口: " INPUT_PORTS

if [[ -z "$INPUT_PORTS" ]]; then
    echo -e "操作已取消。"
    exit 0
fi

# 4. 执行批量删除逻辑
# -----------------------------------------------------------
echo -e "${YELLOW}正在备份配置文件...${PLAIN}"
cp "$CONFIG_FILE" "$BACKUP_FILE"

# 将输入的字符串转换为数组
read -a PORT_ARRAY <<< "$INPUT_PORTS"

CHANGE_COUNT=0

# 开始循环处理每个端口
for TARGET_PORT in "${PORT_ARRAY[@]}"; do
    echo -e "----------------------------------------"
    echo -e "正在处理端口: ${GREEN}$TARGET_PORT${PLAIN} ..."

    # 4.1 验证端口是否为数字
    if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}跳过: '$TARGET_PORT' 不是有效的端口号。${PLAIN}"
        continue
    fi

    # 4.2 查找 Tag (为了清理路由)
    TARGET_TAG=$(jq -r --argjson p "$TARGET_PORT" '.inbounds[] | select(.port == $p) | .tag' "$CONFIG_FILE")

    if [[ -z "$TARGET_TAG" ]] || [[ "$TARGET_TAG" == "null" ]]; then
        echo -e "${RED}跳过: 找不到端口为 $TARGET_PORT 的节点。${PLAIN}"
        continue
    fi

    echo -e "  -> 识别到节点 Tag: ${SKYBLUE}$TARGET_TAG${PLAIN}"

    # 4.3 删除 inbound 节点
    tmp1=$(mktemp)
    jq --argjson p "$TARGET_PORT" '.inbounds |= map(select(.port != $p))' "$CONFIG_FILE" > "$tmp1" && mv "$tmp1" "$CONFIG_FILE"
    echo -e "  -> 节点配置已移除。"

    # 4.4 删除相关的 routing 规则 (级联清理)
    tmp2=$(mktemp)
    jq --arg tag "$TARGET_TAG" '.routing.rules |= map(select(.inboundTag | index($tag) | not))' "$CONFIG_FILE" > "$tmp2" && mv "$tmp2" "$CONFIG_FILE"
    echo -e "  -> 关联路由规则已清理。"
    
    ((CHANGE_COUNT++))
done

echo -e "----------------------------------------"

# 5. 重启服务 (只在有变动时重启)
if [[ "$CHANGE_COUNT" -gt 0 ]]; then
    echo -e "${YELLOW}正在重启 Xray 服务以应用 ${CHANGE_COUNT} 个更改...${PLAIN}"
    systemctl restart xray
    sleep 1

    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${GREEN}    批量拆除成功！${PLAIN}"
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "当前剩余节点数: $(jq '.inbounds | length' "$CONFIG_FILE")"
    else
        echo -e "${RED}重启失败！正在回滚配置...${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        systemctl restart xray
        echo -e "已恢复备份。"
    fi
else
    echo -e "${YELLOW}没有进行任何有效更改，无需重启。${PLAIN}"
fi
