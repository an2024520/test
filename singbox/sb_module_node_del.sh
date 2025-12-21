#!/bin/bash

# ============================================================
# 脚本名称：sb_module_node_del.sh
# 作用：深度清理 Sing-box 节点 (支持批量/全删/路由规则联动清理)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'
BLUE='\033[0;34m'

# ==========================================
# 1. 环境与配置检测
# ==========================================

# 自动寻路配置文件
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then
        CONFIG_FILE="$p"
        break
    fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 未找到 Sing-box 配置文件 config.json。${PLAIN}"
    exit 1
fi

META_FILE="${CONFIG_FILE}.meta"
# 备份路径
BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%H%M%S)"

# 检查依赖
if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误: 系统未安装 jq，无法处理 JSON。${PLAIN}"
    echo -e "请尝试运行: apt-get update && apt-get install -y jq"
    exit 1
fi

# ==========================================
# 2. 智能节点扫描 (排除法)
# ==========================================
# 逻辑：不设白名单，而是排除系统核心类型，剩下的都视为“用户节点”
# 排除列表：direct, block, dns, dns-out, selector (节点组), urltest (自动测速), loopback
# ------------------------------------------

echo -e "${GREEN}正在读取配置文件...${PLAIN}"

# 提取 Inbounds (通常是服务端入口)
# 排除: 无 (Inbounds通常都是用户配置的，除非有 tun/mixed，这里简单处理全部列出供选，或者你可以加 select 过滤)
RAW_IN=$(jq -r '.inbounds[]? | .tag + " [Server-In]"' "$CONFIG_FILE")

# 提取 Outbounds (通常是客户端节点)
# 排除系统保留类型
RAW_OUT=$(jq -r '.outbounds[]? | select(.type!="direct" and .type!="block" and .type!="dns" and .type!="selector" and .type!="urltest" and .type!="loopback") | .tag + " [Client-Out]"' "$CONFIG_FILE")

# 合并列表
IFS=$'\n' read -d '' -r -a ALL_NODES <<< "$RAW_IN"$'\n'"$RAW_OUT"

# 清洗空行
NODES=()
for item in "${ALL_NODES[@]}"; do
    [[ -n "$item" ]] && NODES+=("$item")
done

if [[ ${#NODES[@]} -eq 0 ]]; then
    echo -e "${YELLOW}当前配置文件中没有检测到可删除的用户节点。${PLAIN}"
    echo -e "(已自动隐藏 direct, block, dns, selector 等系统保留对象)"
    read -p "按回车键返回..."
    exit 0
fi

# ==========================================
# 3. 交互菜单 (多选支持)
# ==========================================

clear
echo -e "${BLUE}============= 删除 Sing-box 节点 =============${PLAIN}"
echo -e " 检测到配置文件: ${YELLOW}$CONFIG_FILE${PLAIN}"
echo -e " -------------------------------------------"
echo -e " ${RED}注意：删除节点将同步删除关联的路由规则 (Route Rules)${PLAIN}"
echo -e " -------------------------------------------"

i=1
for node in "${NODES[@]}"; do
    echo -e " ${GREEN}$i.${PLAIN} $node"
    let i++
done

echo -e " -------------------------------------------"
echo -e " ${YELLOW}a.${PLAIN} ${RED}清空所有节点 (Delete All)${PLAIN}"
echo -e " ${YELLOW}0.${PLAIN} 取消返回"
echo -e ""
echo -e "提示: 支持多选，用空格分隔 (例如: 1 3 5)"
read -p "请输入序号: " SELECTION

if [[ -z "$SELECTION" || "$SELECTION" == "0" ]]; then
    echo "操作取消"; exit 0
fi

# 待删除的 Tags 数组
DELETE_TAGS=()

# 处理 "All" 逻辑
if [[ "$SELECTION" == "a" || "$SELECTION" == "all" ]]; then
    echo -e "${RED}警告: 即将删除列表中展示的所有 ${#NODES[@]} 个节点！${PLAIN}"
    read -p "请再次确认 (输入 yes 确认): " CONFIRM_ALL
    if [[ "$CONFIRM_ALL" != "yes" ]]; then echo "操作取消"; exit 0; fi
    
    for item in "${NODES[@]}"; do
        TAG=$(echo "$item" | awk '{print $1}')
        DELETE_TAGS+=("$TAG")
    done
else
    # 处理 数字选择
    for idx in $SELECTION; do
        # 检查是否为数字
        if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
            echo -e "${YELLOW}忽略无效输入: $idx${PLAIN}"
            continue
        fi
        
        REAL_IDX=$((idx-1))
        if [[ $REAL_IDX -ge 0 && $REAL_IDX -lt ${#NODES[@]} ]]; then
            RAW_ITEM="${NODES[$REAL_IDX]}"
            TAG=$(echo "$RAW_ITEM" | awk '{print $1}')
            
            # 查重防止重复添加
            if [[ ! " ${DELETE_TAGS[@]} " =~ " ${TAG} " ]]; then
                DELETE_TAGS+=("$TAG")
            fi
        else
            echo -e "${YELLOW}序号 $idx 超出范围，已跳过。${PLAIN}"
        fi
    done
fi

if [[ ${#DELETE_TAGS[@]} -eq 0 ]]; then
    echo -e "${RED}未选择有效节点，退出。${PLAIN}"
    exit 1
fi

echo -e ""
echo -e "${YELLOW}即将删除以下节点及其关联配置 (路由/Meta):${PLAIN}"
for t in "${DELETE_TAGS[@]}"; do
    echo -e " - ${RED}$t${PLAIN}"
done
echo -e ""
read -p "确认执行删除? (y/n): " CONFIRM_FINAL
if [[ "$CONFIRM_FINAL" != "y" ]]; then echo "操作取消"; exit 0; fi

# ==========================================
# 4. 执行深度清理 (Core Logic)
# ==========================================

# 备份
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo -e "${GREEN}已创建备份: $BACKUP_FILE${PLAIN}"

# 构建 jq 参数 (将 bash 数组传递给 jq)
# 使用 --argjson 传递 tags 列表，安全高效
JSON_TAGS=$(printf '%s\n' "${DELETE_TAGS[@]}" | jq -R . | jq -s .)

echo -e "${YELLOW}正在处理配置文件 (Config & Routing)...${PLAIN}"

TMP_FILE=$(mktemp)

# jq 魔法：
# 1. del(.inbounds): 删除匹配 tag 的入站
# 2. del(.outbounds): 删除匹配 tag 的出站
# 3. del(.route.rules): 删除 'outbound' 字段等于被删 tag 的路由规则 (清理残留!)
jq --argjson tags "$JSON_TAGS" '
    del(.inbounds[]? | select(.tag as $t | $tags | index($t))) | 
    del(.outbounds[]? | select(.tag as $t | $tags | index($t))) |
    del(.route.rules[]? | select(.outbound as $o | $tags | index($o)))
' "$CONFIG_FILE" > "$TMP_FILE"

if [ $? -eq 0 ]; then
    # 检查文件是否为空 (jq 崩溃保护)
    if [[ -s "$TMP_FILE" ]]; then
        mv "$TMP_FILE" "$CONFIG_FILE"
        echo -e "${GREEN}主配置清理完成。${PLAIN}"
    else
        echo -e "${RED}错误: 生成的新配置为空，已恢复备份。${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        rm "$TMP_FILE"
        exit 1
    fi
else
    echo -e "${RED}JSON 处理失败，已恢复备份。${PLAIN}"
    cp "$BACKUP_FILE" "$CONFIG_FILE"
    rm "$TMP_FILE"
    exit 1
fi

# 处理 Meta 文件
if [[ -f "$META_FILE" ]]; then
    echo -e "${YELLOW}正在清理 Meta 缓存...${PLAIN}"
    TMP_META=$(mktemp)
    jq --argjson tags "$JSON_TAGS" '
        del(.[$tags[]])
    ' "$META_FILE" > "$TMP_META" && mv "$TMP_META" "$META_FILE"
fi

# ==========================================
# 5. 重启服务
# ==========================================
echo -e "${YELLOW}正在重启 Sing-box 服务...${PLAIN}"
systemctl restart sing-box

sleep 1
if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}删除成功！服务运行正常。${PLAIN}"
else
    echo -e "${RED}警告: 服务重启失败。${PLAIN}"
    echo -e "尝试还原备份? (y/n)"
    read -p "选择: " RESTORE_OPT
    if [[ "$RESTORE_OPT" == "y" ]]; then
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        systemctl restart sing-box
        echo -e "${GREEN}已还原配置。${PLAIN}"
    else
        echo -e "你可以手动检查日志: journalctl -u sing-box -e"
    fi
fi
