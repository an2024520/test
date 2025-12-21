#!/bin/bash

# =================================================
# 脚本名称：sb_get_node_details.sh (交互增强版 v2.0)
# 作用：自动寻找配置 -> 列出节点 -> 交互选择 -> 生成链接
# =================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE="$1"
NODE_TAG="$2"

# -------------------------------------------------
# 1. 自动寻找配置文件 (如果未通过参数传入)
# -------------------------------------------------
if [[ -z "$CONFIG_FILE" ]]; then
    # 定义搜索顺序：优先 /usr/local/etc (手动安装), 其次 /etc (包管理安装)
    PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")
    
    for p in "${PATHS[@]}"; do
        if [[ -f "$p" ]]; then
            CONFIG_FILE="$p"
            break
        fi
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 未找到 Sing-box 配置文件。${PLAIN}"
        echo -e "请尝试手动指定路径: $0 <path> <tag>"
        exit 1
    fi
    echo -e "${GREEN}读取配置: $CONFIG_FILE${PLAIN}"
fi

# 检查 jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误: 需要安装 jq (apt install jq / yum install jq)${PLAIN}"
    exit 1
fi

# -------------------------------------------------
# 2. 如果没有传入 TAG，则进入“交互式选择模式”
# -------------------------------------------------
if [[ -z "$NODE_TAG" ]]; then
    # 获取所有非系统保留的节点
    # 过滤掉 direct, block, dns, selector, urltest
    RAW_TAGS=$(jq -r '.outbounds[] | select(.type != "direct" and .type != "block" and .type != "dns" and .type != "selector" and .type != "urltest") | .tag' "$CONFIG_FILE")
    
    # 将结果转为数组
    readarray -t TAG_LIST <<< "$RAW_TAGS"

    # 处理空列表的情况 (即你之前遇到的情况)
    # readarray 在空输入时可能产生含有一个空元素的数组，需判空
    # 只要第一个元素为空，就视为没找到
    if [[ -z "${TAG_LIST[0]}" ]]; then
        echo -e "${YELLOW}警告: 在配置文件中未找到有效的代理节点 (VLESS/VMess/Hysteria2)。${PLAIN}"
        echo -e "当前配置文件中的所有 Outbounds (供参考):"
        echo "-------------------------------------------"
        jq -r '.outbounds[] | " - " + .tag + " [" + .type + "]"' "$CONFIG_FILE"
        echo "-------------------------------------------"
        echo -e "${SKYBLUE}建议: 请先在主菜单选择 1-4 添加一个节点。${PLAIN}"
        exit 0
    fi

    echo -e "-------------------------------------------"
    echo -e "发现以下代理节点:"
    i=1
    for tag in "${TAG_LIST[@]}"; do
        if [[ -n "$tag" ]]; then
            echo -e " ${GREEN}$i.${PLAIN} $tag"
            let i++
        fi
    done
    echo -e "-------------------------------------------"
    
    read -p "请输入序号选择节点 (直接回车退出): " CHOICE
    if [[ -z "$CHOICE" ]]; then exit 0; fi
    
    # 获取数组下标 (序号-1)
    INDEX=$((CHOICE-1))
    NODE_TAG="${TAG_LIST[$INDEX]}"
    
    if [[ -z "$NODE_TAG" ]]; then
        echo -e "${RED}无效的选择。${PLAIN}"
        exit 1
    fi
    echo -e "正在解析节点: ${GREEN}$NODE_TAG${PLAIN} ..."
fi

# =================================================
# 下面是解析逻辑 (核心部分)
# =================================================

urlencode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * )               printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# 提取节点对象
NODE_JSON=$(jq -r --arg tag "$NODE_TAG" '.outbounds[] | select(.tag==$tag)' "$CONFIG_FILE")

if [[ -z "$NODE_JSON" ]]; then
    echo "Error: Node '$NODE_TAG' not found."
    exit 1
fi

TYPE=$(echo "$NODE_JSON" | jq -r '.type')
SERVER=$(echo "$NODE_JSON" | jq -r '.server // empty')
PORT=$(echo "$NODE_JSON" | jq -r '.server_port // empty')
UUID=$(echo "$NODE_JSON" | jq -r '.uuid // empty')
PASSWORD=$(echo "$NODE_JSON" | jq -r '.password // empty')

if [[ -z "$SERVER" || -z "$PORT" ]]; then
    echo "Info: Not a standard proxy node. JSON Dump:"
    echo "$NODE_JSON"
    exit 0
fi

LINK=""

case "$TYPE" in
    "vless")
        FLOW=$(echo "$NODE_JSON" | jq -r '.flow // empty')
        TLS_TYPE=$(echo "$NODE_JSON" | jq -r '.tls.enabled // "false"')
        TRANSPORT=$(echo "$NODE_JSON" | jq -r '.transport.type // "tcp"')
        PARAMS="security=none"
        if [[ "$TLS_TYPE" == "true" ]]; then
            REALITY=$(echo "$NODE_JSON" | jq -r '.tls.reality.enabled // "false"')
            if [[ "$REALITY" == "true" ]]; then
                PARAMS="security=reality"
                PBK=$(echo "$NODE_JSON" | jq -r '.tls.reality.public_key // empty')
                SNI=$(echo "$NODE_JSON" | jq -r '.tls.server_name // empty')
                SID=$(echo "$NODE_JSON" | jq -r '.tls.reality.short_id // empty')
                FP=$(echo "$NODE_JSON" | jq -r '.tls.utls.fingerprint // "chrome"')
                [[ -n "$PBK" ]] && PARAMS+="&pbk=$PBK"
                [[ -n "$SNI" ]] && PARAMS+="&sni=$SNI"
                [[ -n "$SID" ]] && PARAMS+="&sid=$SID"
                [[ -n "$FP" ]] && PARAMS+="&fp=$FP"
            else
                PARAMS="security=tls"
                SNI=$(echo "$NODE_JSON" | jq -r '.tls.server_name // empty')
                [[ -n "$SNI" ]] && PARAMS+="&sni=$SNI"
            fi
        fi
        PARAMS+="&type=$TRANSPORT"
        if [[ "$TRANSPORT" == "ws" ]]; then
            WS_PATH=$(echo "$NODE_JSON" | jq -r '.transport.path // "/"')
            WS_HOST=$(echo "$NODE_JSON" | jq -r '.transport.headers.Host // empty')
            PARAMS+="&path=$(urlencode "$WS_PATH")"
            [[ -n "$WS_HOST" ]] && PARAMS+="&host=$(urlencode "$WS_HOST")"
        elif [[ "$TRANSPORT" == "grpc" ]]; then
            SERVICE_NAME=$(echo "$NODE_JSON" | jq -r '.transport.service_name // empty')
            [[ -n "$SERVICE_NAME" ]] && PARAMS+="&serviceName=$(urlencode "$SERVICE_NAME")"
        fi
        [[ -n "$FLOW" ]] && PARAMS+="&flow=$FLOW"
        LINK="vless://${UUID}@${SERVER}:${PORT}?${PARAMS}#$(urlencode "$NODE_TAG")"
        ;;

    "vmess")
        ALTER_ID=$(echo "$NODE_JSON" | jq -r '.alter_id // 0')
        NET=$(echo "$NODE_JSON" | jq -r '.transport.type // "tcp"')
        TLS_ENABLED=$(echo "$NODE_JSON" | jq -r '.tls.enabled // "false"')
        VMESS_TLS=""
        if [[ "$TLS_ENABLED" == "true" ]]; then VMESS_TLS="tls"; fi
        VMESS_OBJ=$(jq -n --arg v "2" --arg ps "$NODE_TAG" --arg add "$SERVER" --arg port "$PORT" --arg id "$UUID" --arg aid "$ALTER_ID" --arg net "$NET" --arg type "none" --arg tls "$VMESS_TLS" '{v:$v, ps:$ps, add:$add, port:$port, id:$id, aid:$aid, net:$net, type:$type, host:"", path:"", tls:$tls}')
        if [[ "$NET" == "ws" ]]; then
            WS_PATH=$(echo "$NODE_JSON" | jq -r '.transport.path // "/"')
            WS_HOST=$(echo "$NODE_JSON" | jq -r '.transport.headers.Host // ""')
            VMESS_OBJ=$(echo "$VMESS_OBJ" | jq --arg path "$WS_PATH" --arg host "$WS_HOST" '.path=$path | .host=$host')
        fi
        B64_VMESS=$(echo -n "$VMESS_OBJ" | base64 -w 0)
        LINK="vmess://${B64_VMESS}"
        ;;
    
    "hysteria2")
        PARAMS="insecure=0"
        SNI=$(echo "$NODE_JSON" | jq -r '.tls.server_name // empty')
        INSECURE=$(echo "$NODE_JSON" | jq -r '.tls.insecure // "false"')
        OBFS_PASS=$(echo "$NODE_JSON" | jq -r '.obfs.password // empty')
        [[ -n "$SNI" ]] && PARAMS+="&sni=$SNI"
        if [[ "$INSECURE" == "true" ]]; then PARAMS+="&insecure=1"; fi
        [[ -n "$OBFS_PASS" ]] && PARAMS+="&obfs=salamander&obfs-password=$OBFS_PASS"
        LINK="hysteria2://${PASSWORD}@${SERVER}:${PORT}?${PARAMS}#$(urlencode "$NODE_TAG")"
        ;;

    *)
        echo "Unknown protocol. Raw JSON:"
        echo "$NODE_JSON"
        exit 0
        ;;
esac

echo ""
echo -e "分享链接："
echo -e "${SKYBLUE}$LINK${PLAIN}"
echo ""
