#!/bin/bash

# ============================================================
#  模块四 (v4.3 修复版)：批量智能拆除工具
#  - 修复了误删 Native WARP 多节点共用规则的问题
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

echo -e "${RED}>>> [模块四] 智能节点拆除工具 (v4.3 修复版)...${PLAIN}"

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

# 检查节点数量
NODE_COUNT=$(jq '.inbounds | length' "$CONFIG_FILE")
if [[ "$NODE_COUNT" == "0" ]]; then
    echo -e "${RED}当前没有配置任何节点！无需删除。${PLAIN}"
    exit 0
fi

# 定义数组存储所有存在的端口
declare -a ALL_EXISTING_PORTS

# === 修复点：使用临时文件替代进程替换，解决语法错误 ===
TMP_NODE_LIST=$(mktemp)
jq -r '.inbounds[] | "\(.tag) \(.port) \(.protocol)"' "$CONFIG_FILE" > "$TMP_NODE_LIST"

while read -r tag port proto; do
    printf "${SKYBLUE}%-25s${PLAIN} ${GREEN}%-10s${PLAIN} %-15s\n" "$tag" "$port" "$proto"
    ALL_EXISTING_PORTS+=("$port")
done < "$TMP_NODE_LIST"

# 删除临时文件
rm -f "$TMP_NODE_LIST"
# =======================================================

echo -e "----------------------------------------------------"

# 3. 操作模式选择
# -----------------------------------------------------------
echo -e "${YELLOW}请选择删除模式:${PLAIN}"
echo -e "  1. ${GREEN}手动输入${PLAIN} (删除特定端口，支持批量)"
echo -e "  2. ${RED}全部删除${PLAIN} (清空列表中的 ${NODE_COUNT} 个节点)"
read -p "请选择 [1-2] (默认 1): " MODE_CHOICE

declare -a TARGET_PORTS_ARRAY

case $MODE_CHOICE in
    2)
        # === 模式 2: 全选 (核弹模式) ===
        echo -e "${RED}警告: 你选择了删除所有节点！${PLAIN}"
        read -p "确认要清空所有节点吗？(y/n): " CONFIRM_ALL
        if [[ "$CONFIRM_ALL" != "y" ]]; then
            echo -e "操作已取消。"
            exit 0
        fi
        echo -e "${RED}正在准备清空所有节点...${PLAIN}"
        TARGET_PORTS_ARRAY=("${ALL_EXISTING_PORTS[@]}")
        ;;
    *)
        # === 模式 1: 手动 (默认) ===
        echo -e "${YELLOW}请输入要删除的端口号 (支持批量)${PLAIN}"
        echo -e "说明: 用空格分隔多个端口，例如: ${GREEN}2053 8443${PLAIN}"
        read -p "目标端口: " INPUT_PORTS
        
        if [[ -z "$INPUT_PORTS" ]]; then
            echo -e "操作取消。"
            exit 0
        fi
        read -a TARGET_PORTS_ARRAY <<< "$INPUT_PORTS"
        ;;
esac

# 4. 执行批量/全量删除
# -----------------------------------------------------------
echo -e "${YELLOW}正在执行清理操作...${PLAIN}"
# 备份
cp "$CONFIG_FILE" "$BACKUP_FILE"
CHANGE_COUNT=0

for TARGET_PORT in "${TARGET_PORTS_ARRAY[@]}"; do
    # 4.1 验证端口数字
    if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}跳过: '$TARGET_PORT' 不是有效的端口号。${PLAIN}"
        continue
    fi

    # 4.2 查找 Tag
    TARGET_TAG=$(jq -r --argjson p "$TARGET_PORT" '.inbounds[] | select(.port == $p) | .tag' "$CONFIG_FILE")

    if [[ -z "$TARGET_TAG" ]] || [[ "$TARGET_TAG" == "null" ]]; then
        echo -e "${RED}跳过: 找不到端口为 $TARGET_PORT 的节点。${PLAIN}"
        continue
    fi

    echo -e "----------------------------------------"
    echo -e "正在处理: ${SKYBLUE}$TARGET_TAG${PLAIN} (${GREEN}$TARGET_PORT${PLAIN})"

    # 4.3 删除 inbound 节点
    tmp1=$(mktemp)
    jq --argjson p "$TARGET_PORT" '.inbounds |= map(select(.port != $p))' "$CONFIG_FILE" > "$tmp1" && mv "$tmp1" "$CONFIG_FILE"
    echo -e "  -> 节点配置已移除。"

    # 4.4 删除相关的 routing 规则 (逻辑已修复)
    # -------------------------------------------------------------
    # 原逻辑：只要 inboundTag 含此 Tag 就删整条规则 (会导致误删共享规则)
    # 新逻辑：只从 inboundTag 数组中剔除此 Tag；若数组变空，才删整条规则
    # -------------------------------------------------------------
    tmp2=$(mktemp)
    jq --arg tag "$TARGET_TAG" '
      .routing.rules |= map(
        (if .inboundTag then .inboundTag -= [$tag] else . end) 
        | select(.inboundTag == null or (.inboundTag | length > 0))
      )
    ' "$CONFIG_FILE" > "$tmp2" && mv "$tmp2" "$CONFIG_FILE"
    
    echo -e "  -> 关联路由规则已智能更新。"
    
    ((CHANGE_COUNT++))
done

echo -e "----------------------------------------"

# 5. 重启服务
# -----------------------------------------------------------
if [[ "$CHANGE_COUNT" -gt 0 ]]; then
    echo -e "${YELLOW}正在重启 Xray 服务以应用 ${CHANGE_COUNT} 个更改...${PLAIN}"
    systemctl restart xray
    sleep 1

    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${GREEN}    拆除成功！${PLAIN}"
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "已成功移除 ${CHANGE_COUNT} 个节点及其附属路由规则。"
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
