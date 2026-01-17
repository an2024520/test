#!/bin/bash

# ============================================================
# ICMP9 Nginx 透明转发脚本 (v5.0 用户主导版)
# 逻辑回归: 用户输入 > 历史配置 > API 实时获取 > 硬保底
# 优势: 如果用户手动指定，完全跳过 API 请求，速度最快
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

WORK_DIR="/etc/icmp9_relay"
CONFIG_ENV="$WORK_DIR/config.env"
NGINX_CONF="/etc/nginx/sites-available/icmp9_relay"
OUTPUT_FILE="/root/icmp9_vmess.txt"

# API 地址
API_NODES="https://api.icmp9.com/online.php"
API_CONFIG="https://api.icmp9.com/config/config.txt"

# 最后的倔强：如果连 API 都挂了，至少有个值能让脚本跑下去
HARD_FALLBACK="tunnel-na.8443.buzz"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1
mkdir -p "$WORK_DIR"

init_system() {
    echo -e "${GREEN}>>> [1/4] 初始化环境...${PLAIN}"
    if ! command -v nginx &> /dev/null || ! command -v jq &> /dev/null; then
        apt-get update -y && apt-get install -y nginx jq curl coreutils
    fi
    rm -f /etc/nginx/sites-enabled/default
}

# ============================================================
# 核心逻辑修正: 严格遵循降级策略
# ============================================================
configure_upstream() {
    echo -e "${GREEN}>>> [2/4] 配置上游入口域名...${PLAIN}"
    
    # 0. 准备历史记录用于提示 (仅提示，不自动决定)
    if [ -f "$CONFIG_ENV" ]; then source "$CONFIG_ENV"; fi
    HINT_MSG=""
    if [[ -n "$Saved_Host" ]]; then
        HINT_MSG="[回车复用: $Saved_Host]"
    else
        HINT_MSG="[回车尝试自动获取]"
    fi

    # 1. 第一优先级: 用户手动输入
    # 这里的逻辑是: 给我一个域名。如果你给不出，我再自己去想办法。
    read -p "请输入入口域名 $HINT_MSG: " USER_INPUT

    if [[ -n "$USER_INPUT" ]]; then
        # === 分支 A: 用户给了明确指令 ===
        FINAL_HOST="$USER_INPUT"
        echo -e "${GREEN}>>> 使用用户输入: $FINAL_HOST${PLAIN}"
    
    elif [[ -n "$Saved_Host" ]]; then
        # === 分支 B: 用户留空，且有历史记录 ===
        FINAL_HOST="$Saved_Host"
        echo -e "${GREEN}>>> 使用历史配置: $FINAL_HOST${PLAIN}"
        
    else
        # === 分支 C: 用户留空，且无历史 -> 只有这时候才去请求 API ===
        echo -e "${YELLOW}>>> 正在从 API 获取最新入口...${PLAIN}"
        
        # 抓取逻辑: 复刻原脚本 cut 方案
        RAW_CFG=$(curl -s -m 5 "$API_CONFIG")
        API_FETCHED_HOST=$(echo "$RAW_CFG" | grep "^wshost|" | cut -d'|' -f2 | tr -d '\r\n')
        
        if [[ -n "$API_FETCHED_HOST" ]]; then
            FINAL_HOST="$API_FETCHED_HOST"
            echo -e "${GREEN}>>> API 获取成功: $FINAL_HOST${PLAIN}"
        else
            # === 分支 D: API 也挂了 -> 使用硬保底 ===
            FINAL_HOST="$HARD_FALLBACK"
            echo -e "${RED}>>> API 获取失败，使用内置保底: $FINAL_HOST${PLAIN}"
        fi
    fi

    # 无论来源如何，保存本次使用的值
    echo "Saved_Host=\"$FINAL_HOST\"" > "$CONFIG_ENV"
}

setup_nginx() {
    echo -e "${GREEN}>>> [3/4] 生成 Nginx 反代配置...${PLAIN}"
    read -p "Nginx 本地监听端口 [默认 8080]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-8080}
    
    NODES_JSON=$(curl -s "$API_NODES")
    # 容错: 即使节点列表 API 挂了，也不要直接退出，至少 Nginx 配置文件结构要是对的
    if [[ -z "$NODES_JSON" ]]; then 
        echo -e "${RED}警告: 节点列表获取失败。Nginx 将只生成空壳配置。${PLAIN}" 
    fi

    cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$LISTEN_PORT;
    server_name localhost;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
    location / { return 404; }
EOF

    # 过滤杂项数据的 jq 逻辑
    if [[ -n "$NODES_JSON" ]]; then
        for node in $(echo "$NODES_JSON" | jq -r '(.data // .nodes // .) | if type=="array" then .[] else empty end | select(.["ws-opts"] != null) | @base64'); do
            _node=$(echo "$node" | base64 -d)
            path=$(echo "$_node" | jq -r '.["ws-opts"].path')
            name=$(echo "$_node" | jq -r '.name')

            cat >> "$NGINX_CONF" <<EOF
    # $name
    location $path {
        proxy_pass https://$FINAL_HOST;
        proxy_ssl_server_name on;
        proxy_ssl_name $FINAL_HOST;
        proxy_set_header Host $FINAL_HOST;
    }
EOF
        done
    fi

    echo "}" >> "$NGINX_CONF"
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    
    nginx -t > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        systemctl restart nginx
        echo -e "${GREEN}Nginx 已启动 (Port: $LISTEN_PORT)${PLAIN}"
    else
        echo -e "${RED}Nginx 验证失败！${PLAIN}"
        exit 1
    fi
}

generate_links() {
    echo -e "${GREEN}>>> [4/4] 生成分享链接...${PLAIN}"
    read -p "请输入你的公网 Argo 域名: " USER_ARGO_DOMAIN
    if [[ -z "$USER_ARGO_DOMAIN" ]]; then echo -e "${RED}域名为空，无法生成链接。${PLAIN}" && return; fi

    > "$OUTPUT_FILE"
    echo -e "\n${SKYBLUE}------ 节点列表 ------${PLAIN}"
    
    if [[ -n "$NODES_JSON" ]]; then
        for node in $(echo "$NODES_JSON" | jq -r '(.data // .nodes // .) | if type=="array" then .[] else empty end | select(.["ws-opts"] != null) | @base64'); do
            _node=$(echo "$node" | base64 -d)
            
            ORIGIN_NAME=$(echo "$_node" | jq -r '.name')
            NODE_ALIAS="[Argo] $ORIGIN_NAME"
            REAL_UUID=$(echo "$_node" | jq -r '.uuid')
            REAL_PATH=$(echo "$_node" | jq -r '.["ws-opts"].path')

            VMESS_JSON=$(jq -n \
                --arg v "2" \
                --arg ps "$NODE_ALIAS" \
                --arg add "$USER_ARGO_DOMAIN" \
                --arg port "443" \
                --arg id "$REAL_UUID" \
                --arg net "ws" \
                --arg type "none" \
                --arg host "$USER_ARGO_DOMAIN" \
                --arg path "$REAL_PATH" \
                --arg tls "tls" \
                --arg sni "$USER_ARGO_DOMAIN" \
                --arg fp "chrome" \
                '{v:$v, ps:$ps, add:$add, port:$port, id:$id, net:$net, type:$type, host:$host, path:$path, tls:$tls, sni:$sni, fp:$fp}')

            LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
            echo "$LINK" >> "$OUTPUT_FILE"
            echo -e "${GREEN}${NODE_ALIAS}${PLAIN}\n$LINK\n"
        done
        echo -e "已保存至: ${YELLOW}$OUTPUT_FILE${PLAIN}"
    else
        echo -e "${RED}因 API 故障，无法生成节点列表。${PLAIN}"
    fi
}

init_system
configure_upstream
setup_nginx
generate_links
