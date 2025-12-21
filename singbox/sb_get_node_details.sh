#!/bin/bash

# =================================================
# 脚本名称：sb_get_node_details.sh (v2.2 混合读取版)
# 作用：支持 Inbounds(Server)/Outbounds(Client) 读取
#       支持从 .meta 伴生文件自动提取 Reality 公钥
# =================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE="$1"
NODE_TAG="$2"

# 1. 自动寻路
# ------------------------------------------------
if [[ -z "$CONFIG_FILE" ]]; then
    PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")
    for p in "${PATHS[@]}"; do
        if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
    done
    if [[ -z "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 未找到 Sing-box 配置文件。${PLAIN}"; exit 1
    fi
    echo -e "${GREEN}读取配置: $CONFIG_FILE${PLAIN}"
fi
META_FILE="${CONFIG_FILE}.meta"

if ! command -v jq &> /dev/null; then echo -e "${RED}错误: 需要安装 jq${PLAIN}"; exit 1; fi

# 2. 交互式选择 (Inbounds + Outbounds)
# ------------------------------------------------
if [[ -z "$NODE_TAG" ]]; then
    # 扫描 Inbounds (排除空)
    LIST_IN=$(jq -r '.inbounds[]? | select(.type=="vless" or .type=="vmess" or .type=="hysteria2") | .tag + " [Server-In]"' "$CONFIG_FILE")
    # 扫描 Outbounds (排除 Direct/Block 等)
    LIST_OUT=$(jq -r '.outbounds[]? | select(.type!="direct" and .type!="block" and .type!="dns" and .type!="selector" and .type!="urltest") | .tag + " [Client-Out]"' "$CONFIG_FILE")
    
    # 合并列表
    IFS=$'\n' read -d '' -r -a ALL_NODES <<< "$LIST_IN"$'\n'"$LIST_OUT"

    # 清理空行
    CLEAN_NODES=()
    for item in "${ALL_NODES[@]}"; do
        [[ -n "$item" ]] && CLEAN_NODES+=("$item")
    done

    if [[ ${#CLEAN_NODES[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未发现任何有效节点。请先添加节点。${PLAIN}"
        exit 0
    fi

    echo -e "-------------------------------------------"
    echo -e "发现以下节点:"
    i=1
    for item in "${CLEAN_NODES[@]}"; do
        echo -e " ${GREEN}$i.${PLAIN} $item"
        let i++
    done
    echo -e "-------------------------------------------"
    
    read -p "请选择序号 (回车退出): " CHOICE
    if [[ -z "$CHOICE" ]]; then exit 0; fi
    INDEX=$((CHOICE-1))
    
    RAW_SELECTION="${CLEAN_NODES[$INDEX]}"
    if [[ -z "$RAW_SELECTION" ]]; then echo "无效选择"; exit 1; fi
    
    # 提取纯 Tag (去掉后面的 [Server-In] 等)
    NODE_TAG=$(echo "$RAW_SELECTION" | awk '{print $1}')
fi

echo -e "正在解析: ${SKYBLUE}$NODE_TAG${PLAIN} ..."

# 3. 数据提取
# ------------------------------------------------
# 尝试在 Inbounds (服务端) 查找
NODE_JSON=$(jq -r --arg tag "$NODE_TAG" '.inbounds[]? | select(.tag==$tag)' "$CONFIG_FILE")
IS_SERVER="false"

if [[ -n "$NODE_JSON" ]]; then
    IS_SERVER="true"
else
    # 尝试在 Outbounds (客户端) 查找
    NODE_JSON=$(jq -r --arg tag "$NODE_TAG" '.outbounds[]? | select(.tag==$tag)' "$CONFIG_FILE")
fi

if [[ -z "$NODE_JSON" ]]; then echo "错误: JSON 中找不到 Tag 为 '$NODE_TAG' 的配置。"; exit 1; fi

# 提取通用字段
TYPE=$(echo "$NODE_JSON" | jq -r '.type')

if [[ "$IS_SERVER" == "true" ]]; then
    # === 服务端模式 ===
    # IP: 获取本机公网IP
    SERVER_ADDR=$(curl -s4m5 https://api.ip.sb/ip || curl -s4m5 ifconfig.me)
    PORT=$(echo "$NODE_JSON" | jq -r '.listen_port')
    UUID=$(echo "$NODE_JSON" | jq -r '.users[0].uuid // empty')
    
    # 尝试从伴生文件读取元数据
    if [[ -f "$META_FILE" ]]; then
        PBK=$(jq -r --arg tag "$NODE_TAG" '.[$tag].pbk // empty' "$META_FILE")
        SID=$(jq -r --arg tag "$NODE_TAG" '.[$tag].sid // empty' "$META_FILE")
        SNI=$(jq -r --arg tag "$NODE_TAG" '.[$tag].sni // empty' "$META_FILE")
    fi
    
    # 如果伴生文件里没有(旧节点)，尝试从配置读取(虽然通常没有)
    if [[ -z "$SNI" ]]; then SNI=$(echo "$NODE_JSON" | jq -r '.tls.server_name // empty'); fi
    # PBK 在 inbound通常读不到，如果为空，稍后会提示
else
    # === 客户端模式 ===
    SERVER_ADDR=$(echo "$NODE_JSON" | jq -r '.server')
    PORT=$(echo "$NODE_JSON" | jq -r '.server_port')
    UUID=$(echo "$NODE_JSON" | jq -r '.uuid // empty')
    SNI=$(echo "$NODE_JSON" | jq -r '.tls.server_name // empty')
    PBK=$(echo "$NODE_JSON" | jq -r '.tls.reality.public_key // empty')
    SID=$(echo "$NODE_JSON" | jq -r '.tls.reality.short_id // empty')
fi

urlencode() {
    local string="${1}"; local strlen=${#string}; local encoded=""; local pos c o
    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}; case "$c" in [-_.~a-zA-Z0-9] ) o="${c}" ;; * ) printf -v o '%%%02x' "'$c" ;; esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# 4. 生成链接
# ------------------------------------------------
LINK=""
case "$TYPE" in
    "vless")
        FLOW=""
        if [[ "$IS_SERVER" == "true" ]]; then
            FLOW=$(echo "$NODE_JSON" | jq -r '.users[0].flow // empty')
            TLS_ENABLED=$(echo "$NODE_JSON" | jq -r '.tls.enabled // "false"')
            REALITY=$(echo "$NODE_JSON" | jq -r '.tls.reality.enabled // "false"')
        else
            FLOW=$(echo "$NODE_JSON" | jq -r '.flow // empty')
            TLS_ENABLED=$(echo "$NODE_JSON" | jq -r '.tls.enabled // "false"')
            REALITY=$(echo "$NODE_JSON" | jq -r '.tls.reality.enabled // "false"')
        fi

        PARAMS="security=none"
        if [[ "$TLS_ENABLED" == "true" ]]; then
            if [[ "$REALITY" == "true" ]]; then
                PARAMS="security=reality&sni=$SNI&fp=chrome&pbk=$PBK"
                [[ -n "$SID" ]] && PARAMS+="&sid=$SID"
            else
                PARAMS="security=tls&sni=$SNI"
            fi
        fi
        PARAMS+="&type=tcp"
        [[ -n "$FLOW" ]] && PARAMS+="&flow=$FLOW"
        
        LINK="vless://${UUID}@${SERVER_ADDR}:${PORT}?${PARAMS}#$(urlencode "$NODE_TAG")"
        ;;
    *)
        echo "暂不支持自动生成该协议链接: $TYPE"
        exit 0
        ;;
esac

echo ""
echo -e "${SKYBLUE}$LINK${PLAIN}"
if [[ "$IS_SERVER" == "true" && "$REALITY" == "true" && -z "$PBK" ]]; then
    echo -e "${RED}警告: 未找到 Public Key。${PLAIN}"
    echo -e "这可能是因为该节点是旧版本脚本创建的。建议删除并重建该节点以启用自动链接生成。"
fi
echo ""
