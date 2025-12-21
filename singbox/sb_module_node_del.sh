#!/bin/bash

# ============================================================
# 脚本名称：sb_module_node_del.sh (v3.4 SmartClean)
# 作用：深度清理 Sing-box 节点
# 升级：智能剔除路由规则中的无效引用 (防止多节点共用路由时误删或残留)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# ==========================================
# 1. 环境与配置检测
# ==========================================

CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 未找到 Sing-box 配置文件 config.json。${PLAIN}"
    exit 1
fi

META_FILE="${CONFIG_FILE}.meta"
BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%H%M%S)"

if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误: 系统未安装 jq。${PLAIN}"
    exit 1
fi

# ==========================================
# 2. 交互式选择节点
# ==========================================

echo -e "${GREEN}正在读取当前节点列表...${PLAIN}"

# 读取常规节点 + Endpoints
NODES_OUT=$(jq -r '.outbounds[]? | select(.tag != "direct" and .tag != "block" and .tag != "dns-out") | .tag' "$CONFIG_FILE")
NODES_EP=$(jq -r '.endpoints[]? | .tag' "$CONFIG_FILE")
ALL_NODES=$(echo -e "$NODES_OUT\n$NODES_EP" | sed '/^$/d')

if [[ -z "$ALL_NODES" ]]; then
    echo -e "${YELLOW}未检测到可删除的自定义节点。${PLAIN}"
    exit 0
fi

declare -a NODE_ARRAY
i=1
echo -e "------------------------------------------------"
echo -e " 序号 | 节点标签 (Tag)"
echo -e "------------------------------------------------"

while IFS= read -r tag; do
    NODE_ARRAY[$i]="$tag"
    echo -e "  $i   | ${SKYBLUE}$tag${PLAIN}"
    ((i++))
done <<< "$ALL_NODES"

echo -e "------------------------------------------------"
echo -e "${YELLOW}请输入要删除的节点序号 (空格分隔)${PLAIN}"
echo -e "${RED}注意：将自动清理关联的路由规则，确保 Sing-box 正常重启。${PLAIN}"
read -p "请选择: " selection

if [[ -z "$selection" ]]; then echo -e "${YELLOW}取消操作。${PLAIN}"; exit 0; fi

# ==========================================
# 3. 执行删除 (高级 JQ 逻辑)
# ==========================================

declare -a DELETE_TAGS
for num in $selection; do
    if [[ -n "${NODE_ARRAY[$num]}" ]]; then
        tag="${NODE_ARRAY[$num]}"
        DELETE_TAGS+=("$tag")
        echo -e "准备删除: ${RED}$tag${PLAIN}"
    fi
done

[[ ${#DELETE_TAGS[@]} -eq 0 ]] && exit 1

echo -e "${YELLOW}正在备份配置文件...${PLAIN}"
cp "$CONFIG_FILE" "$BACKUP_FILE"

JSON_TAGS=$(printf '%s\n' "${DELETE_TAGS[@]}" | jq -R . | jq -s .)
TMP_FILE=$(mktemp)

echo -e "${YELLOW}正在智能清洗 Config & Routes...${PLAIN}"

# v3.4 核心逻辑解释：
# 1. 删除 inbounds/outbounds/endpoints 中匹配的节点
# 2. 删除 route.rules 中，目标(outbound)是被删节点的规则
# 3. [新] 清洗 route.rules 中，源头(inbound)包含被删节点的引用：
#    - 从 inbound 数组中减去被删的 tags
#    - 如果减完后数组为空，则删除整条规则
#    - 如果减完后还有剩余(如 hy2)，则更新规则保留剩余部分

jq --argjson tags "$JSON_TAGS" '
    # 1. 删除节点定义
    del(.inbounds[]? | select(.tag as $t | $tags | index($t))) | 
    del(.outbounds[]? | select(.tag as $t | $tags | index($t))) |
    del(.endpoints[]? | select(.tag as $t | $tags | index($t))) |
    
    # 2. 删除以被删节点为目标的规则
    del(.route.rules[]? | select(.outbound as $o | $tags | index($o))) |

    # 3. 清洗引用了被删节点的规则 (Smart Clean)
    .route.rules |= map(
        # 逻辑：如果规则有 inbound 字段
        if .inbound then
            # 将 inbound 转为数组(以防它是字符串)，然后减去我们要删除的 tags
            (.inbound | if type=="array" then . else [.] end) - $tags |
            # 如果减完后数组长度为0 (说明全被删了)，则通过 empty 丢弃该规则
            if length == 0 then empty 
            # 否则(还有其他节点)，将清洗后的数组赋值回 inbound
            else . as $new_ib | ($$ | .inbound = $new_ib) end
        else
            . # 没有 inbound 字段的规则(如 geoip)，保持原样
        end
    )
' "$CONFIG_FILE" > "$TMP_FILE"

if [[ $? -eq 0 && -s "$TMP_FILE" ]]; then
    mv "$TMP_FILE" "$CONFIG_FILE"
    echo -e "${GREEN}配置清理完成。${PLAIN}"
else
    echo -e "${RED}错误: JSON 处理失败，已恢复备份。${PLAIN}"
    cp "$BACKUP_FILE" "$CONFIG_FILE"
    rm "$TMP_FILE"
    exit 1
fi

# 处理 Meta 文件
if [[ -f "$META_FILE" ]]; then
    TMP_META=$(mktemp)
    jq --argjson tags "$JSON_TAGS" 'del(.[$tags[]])' "$META_FILE" > "$TMP_META" && mv "$TMP_META" "$META_FILE"
fi

# ==========================================
# 5. 重启服务
# ==========================================
echo -e "${YELLOW}正在重启 Sing-box 服务...${PLAIN}"
if systemctl list-unit-files | grep -q sing-box; then
    systemctl restart sing-box
else
    pkill -xf "sing-box run -c $CONFIG_FILE"
    nohup sing-box run -c "$CONFIG_FILE" > /dev/null 2>&1 &
fi

sleep 2
if systemctl is-active --quiet sing-box || pgrep -x "sing-box" >/dev/null; then
    echo -e "${GREEN}操作成功！${PLAIN}"
    # 清理证书
    for tag in "${DELETE_TAGS[@]}"; do
        rm -f "/usr/local/etc/sing-box/cert/${tag}.crt" 2>/dev/null
        rm -f "/usr/local/etc/sing-box/cert/${tag}.key" 2>/dev/null
    done
else
    echo -e "${RED}重启失败！可能因残留配置导致，已回滚。${PLAIN}"
    cp "$BACKUP_FILE" "$CONFIG_FILE"
    systemctl restart sing-box
fi
