#!/bin/bash

# ============================================================
#  Hysteria 2 全能管理脚本 (v4.2 修复版 - 2025.12.27)
#  修复要点：
#  1. listen 字段 YAML 语法错误（移除错误的 "-" 前缀）
#  2. IPv6-only 环境 IP 获取失败（智能获取公网 IP，支持 IPv4/IPv6）
#  3. Web 服务恢复逻辑优化（443 端口冲突时不再强行恢复）
#  4. masquerade 支持低内存模式（静态文件/404，避免 proxy OOM）
#  5. ACME 模式非 443 端口时自动添加 httpListen: :80
#  6. 其他细节完善与健壮性提升
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'
SKYBLUE='\033[0;36m'

# 核心路径
CONFIG_FILE="/etc/hysteria/config.yaml"
HOPPING_CONF="/etc/hysteria/hopping.conf"
HY_BIN="/usr/local/bin/hysteria"
WIREPROXY_CONF="/etc/wireproxy/wireproxy.conf"
NFT_CONF="/etc/nftables/hy2_port_hopping.nft"

# --- 开头检查：必须运行在 systemd 环境 ---
if [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
    echo -e "${RED}错误: 本脚本依赖 systemd 管理服务${PLAIN}"
    echo -e "${RED}当前环境 PID 1 进程为 $(ps -p 1 -o comm=)，非 systemd（可能是 Docker/OpenWrt/Alpine 等）${PLAIN}"
    echo -e "${YELLOW}建议使用官方 Docker 镜像或对应系统的专用脚本。${PLAIN}"
    exit 1
fi

# --- 辅助功能：检查 Root ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

# --- 辅助功能：智能获取公网 IP（支持 IPv4/IPv6）---
get_public_ip() {
    # 优先尝试 IPv4
    local IPV4=$(curl -s --max-time 8 https://api.ipify.org)
    if [[ -n "$IPV4" && "$IPV4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$IPV4"
        return
    fi

    # 再尝试 IPv6
    local IPV6=$(curl -s --max-time 8 https://api64.ipify.org)
    if [[ -n "$IPV6" && "$IPV6" =~ : ]]; then
        echo "$IPV6"
        return
    fi

    # 最后 fallback 到 ifconfig.me（自动适配）
    curl -s --max-time 10 https://ifconfig.me
}

# --- 辅助功能：端口占用检查 ---
check_port() {
    local port=$1
    if ss -tulnp | grep -q ":$port "; then
        echo -e "${RED}错误: 端口 $port 已被占用！${PLAIN}"
        return 1
    fi
    return 0
}

# --- 辅助功能：Web 服务管理 ---
stop_web_service() {
    WEB_SERVICE=""
    if systemctl is-active --quiet nginx; then
        WEB_SERVICE="nginx"
    elif systemctl is-active --quiet apache2; then
        WEB_SERVICE="apache2"
    elif systemctl is-active --quiet httpd; then
        WEB_SERVICE="httpd"
    fi

    if [[ -n "$WEB_SERVICE" ]]; then
        echo -e "${YELLOW}检测到 $WEB_SERVICE 正在运行，正在临时停止以释放端口...${PLAIN}"
        systemctl stop "$WEB_SERVICE"
        touch /tmp/hy2_web_restore_flag
        echo "$WEB_SERVICE" > /tmp/hy2_web_service_name
        echo "$LISTEN_PORT" > /tmp/hy2_conflict_port  # 记录冲突端口
    fi
}

restore_web_service() {
    if [[ -f /tmp/hy2_web_restore_flag ]]; then
        local SVC=$(cat /tmp/hy2_web_service_name)
        local CONFLICT_PORT=$(cat /tmp/hy2_conflict_port 2>/dev/null || echo "")

        echo -e "${YELLOW}正在尝试恢复 Web 服务 ($SVC)...${PLAIN}"
        systemctl start "$SVC" 2>/dev/null

        if systemctl is-active --quiet "$SVC"; then
            echo -e "${GREEN}Web 服务 ($SVC) 已成功恢复。${PLAIN}"
        else
            if [[ "$CONFLICT_PORT" == "443" ]]; then
                echo -e "${RED}恢复失败：Hysteria 2 正在占用 443 端口，无法同时运行 Web 服务。${PLAIN}"
                echo -e "${YELLOW}建议方案：${PLAIN}"
                echo "  1. 让 Hysteria 2 的 masquerade 伪装网站接管流量（推荐）"
                echo "  2. 修改 $SVC 的监听端口（如改为 80 或 8080）"
                echo "  3. 停止 Hysteria 2 后手动启动 Web 服务"
            else
                echo -e "${RED}Web 服务 ($SVC) 启动失败，请检查配置或日志。${PLAIN}"
            fi
        fi
        rm -f /tmp/hy2_web_restore_flag /tmp/hy2_web_service_name /tmp/hy2_conflict_port
    fi
}

# --- 辅助功能：节点信息生成 ---
print_node_info() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}配置文件不存在${PLAIN}"
        return
    fi

    echo -e "\n${YELLOW}正在读取当前配置生成分享链接...${PLAIN}"
    
    local LISTEN=$(grep "^listen:" $CONFIG_FILE | awk '{print $2}' | tr -d '"')
    local PASSWORD=$(grep "password:" $CONFIG_FILE | awk '{print $2}' | tr -d '"')
    
    local IS_SOCKS5="直连模式"
    if grep -q "# --- SOCKS5 START ---" $CONFIG_FILE; then
        IS_SOCKS5="${SKYBLUE}已挂载 Socks5 代理${PLAIN}"
    fi

    local SHOW_ADDR=""
    local SNI=""
    local INSECURE="0"
    local SKIP_CERT_VAL="false"

    if grep -q "acme:" $CONFIG_FILE; then
        SHOW_ADDR=$(grep -A 2 "domains:" $CONFIG_FILE | tail -n 1 | tr -d ' -')
        SNI="$SHOW_ADDR"
        INSECURE="0"
        SKIP_CERT_VAL="false"
    else
        SHOW_ADDR=$(get_public_ip)
        if [[ -z "$SHOW_ADDR" || "$SHOW_ADDR" == "获取失败" ]]; then
            SHOW_ADDR="IP获取失败，请手动替换"
        fi
        local CUSTOM_SNI=$(openssl x509 -in /etc/hysteria/server.crt -noout -subject 2>/dev/null | sed -n 's/.*CN=\([^/]*\).*/\1/p')
        SNI=${CUSTOM_SNI:-"bing.com"}
        INSECURE="1"
        SKIP_CERT_VAL="true"
    fi

    local LISTEN_PORT=$(echo "$LISTEN" | sed -e 's/^- //' -e 's/://' -e 's/\[::\]//')
    local SHOW_PORT="$LISTEN_PORT"
    local OC_PORT="$LISTEN_PORT"
    local OC_COMMENT=""
    
    if [[ -f "$HOPPING_CONF" ]]; then
        source "$HOPPING_CONF"
        if [[ -n "$HOP_RANGE" ]]; then
            SHOW_PORT="$HOP_RANGE"
            local START_PORT=$(echo $HOP_RANGE | cut -d '-' -f 1)
            OC_PORT="$START_PORT"
            OC_COMMENT="# 端口跳跃范围: ${HOP_RANGE}"
        fi
    fi

    local NODE_NAME="Hy2-${SHOW_ADDR}"
    local V2RAYN_LINK="hysteria2://${PASSWORD}@${SHOW_ADDR}:${SHOW_PORT}/?sni=${SNI}&insecure=${INSECURE}#${NODE_NAME}"

    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}      Hysteria 2 配置信息 (${IS_SOCKS5})      ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "地址(Address)  : ${YELLOW}${SHOW_ADDR}${PLAIN}"
    echo -e "端口(Port)     : ${YELLOW}${SHOW_PORT}${PLAIN}"
    echo -e "密码(Password) : ${YELLOW}${PASSWORD}${PLAIN}"
    echo -e "SNI            : ${YELLOW}${SNI}${PLAIN}"
    echo -e "跳过证书验证   : ${YELLOW}$( [[ "$INSECURE" == "1" ]] && echo "True" || echo "False" )${PLAIN}"
    
    echo -e "\n${YELLOW}➤ v2rayN / Nekoray / Clash Verge 分享链接:${PLAIN}"
    echo -e "${V2RAYN_LINK}"
    
    echo -e "\n${YELLOW}➤ OpenClash / Clash Meta (YAML):${PLAIN}"
    cat <<EOF
- name: "${NODE_NAME}"
  type: hysteria2
  server: "${SHOW_ADDR}"
  port: ${OC_PORT}  ${OC_COMMENT}
  password: "${PASSWORD}"
  sni: "${SNI}"
  skip-cert-verify: ${SKIP_CERT_VAL}
  alpn:
    - h3
EOF
    echo -e "----------------------------------------------"
}

# --- 系统检测与包管理 ---
detect_pkg_manager() {
    if command -v apt >/dev/null; then
        PKG_MANAGER="apt"
        PKG_UPDATE="apt update -y"
        PKG_INSTALL="apt install -y"
    elif command -v dnf >/dev/null; then
        PKG_MANAGER="dnf"
        PKG_UPDATE="dnf check-update -y || true"
        PKG_INSTALL="dnf install -y"
    elif command -v yum >/dev/null; then
        PKG_MANAGER="yum"
        PKG_UPDATE="yum check-update -y || true"
        PKG_INSTALL="yum install -y"
    else
        echo -e "${RED}不支持的包管理器${PLAIN}"
        exit 1
    fi
}

install_base() {
    detect_pkg_manager
    echo -e "${YELLOW}正在更新系统并安装基础组件...${PLAIN}"
    $PKG_UPDATE
    $PKG_INSTALL curl wget openssl jq socat ca-certificates
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        $PKG_INSTALL iptables-persistent netfilter-persistent || true
    fi
}

install_core() {
    ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case $ARCH in
        amd64|x86_64) HY_ARCH="amd64" ;;
        arm64|aarch64) HY_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    echo -e "${YELLOW}正在获取 Hysteria 2 最新版本...${PLAIN}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
    if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "null" ]]; then
        echo -e "${RED}获取版本失败，请检查网络${PLAIN}"
        exit 1
    fi
    
    wget -O "$HY_BIN" "https://github.com/apernet/hysteria/releases/download/${LATEST_VERSION}/hysteria-linux-${HY_ARCH}"
    chmod +x "$HY_BIN"
    mkdir -p /etc/hysteria
}

# --- 端口跳跃支持检查 ---
check_nat_support() {
    echo -e "${YELLOW}正在检测内核是否支持端口重定向...${PLAIN}"
    
    if command -v nft >/dev/null; then
        if nft -f /dev/stdin <<< "table inet hy2test { chain test { type nat hook prerouting priority 0; } }" 2>/dev/null; then
            nft delete table inet hy2test 2>/dev/null
            echo -e "${GREEN}nftables 支持 NAT${PLAIN}"
            return 0
        fi
    fi
    
    if command -v iptables >/dev/null; then
        if iptables -t nat -A PREROUTING -p udp --dport 9999 -j REDIRECT --to-ports 12345 2>/dev/null; then
            iptables -t nat -D PREROUTING -p udp --dport 9999 -j REDIRECT --to-ports 12345 2>/dev/null
            echo -e "${GREEN}iptables 支持 REDIRECT${PLAIN}"
            return 0
        fi
    fi
    
    echo -e "${RED}警告: 当前内核不支持端口重定向（常见于 OpenVZ、部分 LXC）${PLAIN}"
    echo -e "${RED}端口跳跃功能将不可用${PLAIN}"
    return 1
}

detect_firewall() {
    if command -v nft >/dev/null; then
        echo "nftables"
    elif command -v iptables >/dev/null; then
        echo "iptables"
    else
        echo "none"
    fi
}

setup_port_hopping() {
    local TARGET_PORT=$1
    local HOP_RANGE=$2
    if [[ -z "$HOP_RANGE" ]]; then return; fi

    if ! check_nat_support; then
        echo -e "${YELLOW}跳过端口跳跃配置${PLAIN}"
        return
    fi

    local FW=$(detect_firewall)
    local START_PORT=$(echo $HOP_RANGE | cut -d '-' -f 1)
    local END_PORT=$(echo $HOP_RANGE | cut -d '-' -f 2)

    echo -e "${YELLOW}正在配置端口跳跃: $HOP_RANGE -> $TARGET_PORT (使用 $FW)${PLAIN}"

    if [[ "$FW" == "nftables" ]]; then
        mkdir -p /etc/nftables
        cat > "$NFT_CONF" <<EOF
table inet hysteria {
    chain prerouting {
        type nat hook prerouting priority dstnat + 10; policy accept;
        udp dport $START_PORT-$END_PORT redirect to :$TARGET_PORT
    }
}
EOF
        nft flush table inet hysteria 2>/dev/null
        nft delete table inet hysteria 2>/dev/null
        nft -f "$NFT_CONF"
        systemctl enable nftables >/dev/null 2>&1
        systemctl restart nftables >/dev/null 2>&1
    elif [[ "$FW" == "iptables" ]]; then
        while iptables -t nat -D PREROUTING -p udp --dport "$START_PORT":"$END_PORT" -j REDIRECT --to-ports "$TARGET_PORT" 2>/dev/null; do :; done
        iptables -t nat -A PREROUTING -p udp --dport "$START_PORT":"$END_PORT" -j REDIRECT --to-ports "$TARGET_PORT"
        if command -v netfilter-persistent >/dev/null; then
            netfilter-persistent save >/dev/null 2>&1
        fi
    fi

    echo "HOP_RANGE=$HOP_RANGE" > "$HOPPING_CONF"
}

uninstall_port_hopping() {
    if [[ -f "$HOPPING_CONF" ]]; then
        source "$HOPPING_CONF"
        if [[ -n "$HOP_RANGE" ]]; then
            local START_PORT=$(echo $HOP_RANGE | cut -d '-' -f 1)
            local END_PORT=$(echo $HOP_RANGE | cut -d '-' -f 2)
            local FW=$(detect_firewall)

            if [[ "$FW" == "nftables" ]]; then
                nft flush table inet hysteria 2>/dev/null
                nft delete table inet hysteria 2>/dev/null
                rm -f "$NFT_CONF"
            elif [[ "$FW" == "iptables" ]]; then
                while iptables -t nat -D PREROUTING -p udp --dport "$START_PORT":"$END_PORT" -j REDIRECT 2>/dev/null; do :; done
                if command -v netfilter-persistent >/dev/null; then
                    netfilter-persistent save >/dev/null 2>&1
                fi
            fi
        fi
        rm -f "$HOPPING_CONF"
    fi
}

# --- 通用配置写入 ---
write_common_config() {
    local LISTEN=$1
    local PASSWORD=$2
    local MASQUERADE_TYPE=$3
    local MASQUERADE_CONTENT=$4

    cat > "$CONFIG_FILE" <<EOF
listen: "$LISTEN"
auth:
  type: password
  password: "$PASSWORD"
masquerade:
  type: $MASQUERADE_TYPE
EOF

    if [[ "$MASQUERADE_TYPE" == "proxy" ]]; then
        cat >> "$CONFIG_FILE" <<EOF
  proxy:
    url: $MASQUERADE_CONTENT
    rewriteHost: true
EOF
    elif [[ "$MASQUERADE_TYPE" == "file" ]]; then
        cat >> "$CONFIG_FILE" <<EOF
  file:
    dir: $MASQUERADE_CONTENT
EOF
    fi
}

# --- 自签名证书安装 ---
install_self_signed() {
    echo -e "${GREEN}>>> 安装模式: 自签名证书 (无域名)${PLAIN}"
    
    while true; do
        read -p "请输入监听端口 (推荐 8443): " LISTEN_PORT
        [[ -z "$LISTEN_PORT" ]] && LISTEN_PORT=8443
        if [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && [ "$LISTEN_PORT" -le 65535 ]; then
            if check_port "$LISTEN_PORT"; then break; fi
        fi
        echo -e "${RED}端口无效或已被占用，请重新输入${PLAIN}"
    done

    echo "IPv6 支持选择："
    echo "1. 双栈监听 (推荐)"
    echo "2. 仅 IPv4"
    echo "3. 仅 IPv6"
    read -p "请选择 [1-3，默认 1]: " IPV6_CHOICE
    [[ -z "$IPV6_CHOICE" ]] && IPV6_CHOICE=1
    case $IPV6_CHOICE in
        2) LISTEN=":$LISTEN_PORT" ;;
        3) LISTEN="[::]:$LISTEN_PORT" ;;
        *) LISTEN=":$LISTEN_PORT" ;;  # 双栈和仅 IPv4 都用 :port，内核自动处理
    esac

    read -p "端口跳跃范围 (如 20000-30000，留空跳过): " PORT_HOP
    read -p "连接密码 (留空随机生成): " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -hex 16)
    
    echo "伪装模式选择："
    echo "1. 反向代理网站 (高兼容，内存占用较高)"
    echo "2. 静态网页目录 (低内存，适合 128M 小鸡)"
    echo "3. 简单 404 页面 (最低内存)"
    read -p "请选择 [1-3，默认 1]: " MASQ_CHOICE
    [[ -z "$MASQ_CHOICE" ]] && MASQ_CHOICE=1

    case $MASQ_CHOICE in
        2)
            MASQ_TYPE="file"
            echo -e "${YELLOW}将使用内置静态网页作为伪装（低内存模式）${PLAIN}"
            mkdir -p /etc/hysteria/masquerade
            cat > /etc/hysteria/masquerade/index.html <<'EOF'
<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>It works!</h1></body></html>
EOF
            MASQ_CONTENT="/etc/hysteria/masquerade"
            ;;
        3)
            MASQ_TYPE="file"
            MASQ_CONTENT="404"
            echo -e "${YELLOW}使用简单 404 伪装（极低内存）${PLAIN}"
            ;;
        *)
            MASQ_TYPE="proxy"
            read -p "伪装网站 URL (默认 https://news.ycombinator.com/): " MASQ_URL
            [[ -z "$MASQ_URL" ]] && MASQ_URL="https://news.ycombinator.com/"
            MASQ_CONTENT="$MASQ_URL"
            ;;
    esac

    read -p "客户端 SNI (默认 bing.com): " SNI
    [[ -z "$SNI" ]] && SNI="bing.com"

    echo -e "${YELLOW}生成自签名证书 (CN=$SNI)...${PLAIN}"
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=$SNI" >/dev/null 2>&1

    write_common_config "$LISTEN" "$PASSWORD" "$MASQ_TYPE" "$MASQ_CONTENT"
    cat <<EOF >> "$CONFIG_FILE"
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
EOF

    setup_port_hopping "$LISTEN_PORT" "$PORT_HOP"
    start_service
    print_node_info
}

# --- ACME 证书安装 ---
install_acme() {
    echo -e "${GREEN}>>> 安装模式: ACME 自动证书 (有域名)${PLAIN}"
    
    read -p "请输入域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && echo "域名不能为空" && exit 1
    
    read -p "请输入邮箱 (留空自动生成): " EMAIL
    [[ -z "$EMAIL" ]] && EMAIL="admin@$DOMAIN"
    
    while true; do
        read -p "请输入监听端口 (推荐 443): " LISTEN_PORT
        [[ -z "$LISTEN_PORT" ]] && LISTEN_PORT=443
        if [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && [ "$LISTEN_PORT" -le 65535 ]; then
            if check_port "$LISTEN_PORT"; then break; fi
        fi
        echo -e "${RED}端口无效或已被占用，请重新输入${PLAIN}"
    done

    echo "IPv6 支持选择："
    echo "1. 双栈监听 (推荐)"
    echo "2. 仅 IPv4"
    echo "3. 仅 IPv6"
    read -p "请选择 [1-3，默认 1]: " IPV6_CHOICE
    [[ -z "$IPV6_CHOICE" ]] && IPV6_CHOICE=1
    case $IPV6_CHOICE in
        2) LISTEN=":$LISTEN_PORT" ;;
        3) LISTEN="[::]:$LISTEN_PORT" ;;
        *) LISTEN=":$LISTEN_PORT" ;;
    esac

    read -p "端口跳跃范围 (如 20000-30000，留空跳过): " PORT_HOP
    read -p "连接密码 (留空随机生成): " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -hex 16)
    
    echo "伪装模式选择："
    echo "1. 反向代理网站 (推荐)"
    echo "2. 静态网页目录 (低内存)"
    echo "3. 简单 404 页面 (最低内存)"
    read -p "请选择 [1-3，默认 1]: " MASQ_CHOICE
    [[ -z "$MASQ_CHOICE" ]] && MASQ_CHOICE=1

    case $MASQ_CHOICE in
        2)
            MASQ_TYPE="file"
            mkdir -p /etc/hysteria/masquerade
            cat > /etc/hysteria/masquerade/index.html <<'EOF'
<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>It works!</h1></body></html>
EOF
            MASQ_CONTENT="/etc/hysteria/masquerade"
            ;;
        3)
            MASQ_TYPE="file"
            MASQ_CONTENT="404"
            ;;
        *)
            MASQ_TYPE="proxy"
            read -p "伪装网站 URL (默认 https://news.ycombinator.com/): " MASQ_URL
            [[ -z "$MASQ_URL" ]] && MASQ_URL="https://news.ycombinator.com/"
            MASQ_CONTENT="$MASQ_URL"
            ;;
    esac

    stop_web_service

    write_common_config "$LISTEN" "$PASSWORD" "$MASQ_TYPE" "$MASQ_CONTENT"
    cat <<EOF >> "$CONFIG_FILE"
acme:
  domains:
    - $DOMAIN
  email: $EMAIL
EOF

    if [[ "$LISTEN_PORT" != "443" ]]; then
        echo "  httpListen: :80" >> "$CONFIG_FILE"
    fi

    setup_port_hopping "$LISTEN_PORT" "$PORT_HOP"
    start_service
    restore_web_service
    print_node_info
}

# --- Socks5 挂载/移除 ---
attach_socks5() {
    echo -e "${GREEN}>>> 正在配置 Socks5 出口分流...${PLAIN}"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 配置文件不存在${PLAIN}"
        return
    fi
    detach_socks5 "quiet"

    DEFAULT_SOCKS="127.0.0.1:40000"
    DETECTED_INFO=""
    if [[ -f "$WIREPROXY_CONF" ]]; then
        DETECTED_INFO=$(grep "BindAddress" "$WIREPROXY_CONF" | awk -F '=' '{print $2}' | tr -d ' ')
    fi

    if [[ -n "$DETECTED_INFO" ]]; then
        echo -e "${YELLOW}检测到 WireProxy: ${GREEN}${DETECTED_INFO}${PLAIN}"
        read -p "是否使用此地址？(y/n，默认 y): " USE_DETECTED
        [[ -z "$USE_DETECTED" ]] && USE_DETECTED="y"
        if [[ "$USE_DETECTED" == "y" ]]; then
            PROXY_ADDR="$DETECTED_INFO"
        else
            read -p "请输入 Socks5 地址: " PROXY_ADDR
        fi
    else
        read -p "请输入 Socks5 地址 (默认 $DEFAULT_SOCKS): " PROXY_ADDR
        [[ -z "$PROXY_ADDR" ]] && PROXY_ADDR="$DEFAULT_SOCKS"
    fi

    cat <<EOF >> "$CONFIG_FILE"

# --- SOCKS5 START ---
outbounds:
  - name: socks5_out
    type: socks5
    socks5:
      addr: $PROXY_ADDR

acl:
  inline:
    - socks5_out(all)
# --- SOCKS5 END ---
EOF

    systemctl restart hysteria-server
    sleep 3
    if systemctl is-active --quiet hysteria-server; then
        echo -e "${GREEN}Socks5 挂载成功！${PLAIN}"
        print_node_info
    else
        echo -e "${RED}服务启动失败，正在回滚...${PLAIN}"
        detach_socks5 "quiet"
    fi
}

detach_socks5() {
    local MODE=$1
    if [[ "$MODE" != "quiet" ]]; then
        echo -e "${YELLOW}正在移除 Socks5 配置...${PLAIN}"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        sed -i '/# --- SOCKS5 START ---/,/# --- SOCKS5 END ---/d' "$CONFIG_FILE"
        sed -i '/^$/N;/^\n$/D' "$CONFIG_FILE"
    fi

    if [[ "$MODE" != "quiet" ]]; then
        systemctl restart hysteria-server
        echo -e "${GREEN}已恢复直连模式${PLAIN}"
        print_node_info
    fi
}

# --- 服务管理 ---
start_service() {
    cat <<EOF > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/hysteria
ExecStart=$HY_BIN server -c $CONFIG_FILE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl restart hysteria-server

    sleep 3
    if systemctl is-active --quiet hysteria-server; then
        if ss -ulnp | grep -q "$HY_BIN"; then
            echo -e "${GREEN}Hysteria 2 服务启动成功并正在监听 UDP 端口！${PLAIN}"
        else
            echo -e "${YELLOW}服务启动但未检测到 UDP 监听，可能配置有误${PLAIN}"
        fi
    else
        echo -e "${RED}服务启动失败，请运行: journalctl -u hysteria-server -e 查看日志${PLAIN}"
    fi
}

uninstall_hy2() {
    echo -e "${RED}警告: 即将完全卸载 Hysteria 2 及其所有配置${PLAIN}"
    read -p "确认继续? (y/n): " CONFIRM
    [[ "$CONFIRM" != "y" ]] && return

    systemctl stop hysteria-server 2>/dev/null
    systemctl disable hysteria-server 2>/dev/null
    rm -f /etc/systemd/system/hysteria-server.service
    uninstall_port_hopping
    rm -f "$HY_BIN"
    rm -rf /etc/hysteria
    systemctl daemon-reload
    echo -e "${GREEN}Hysteria 2 已完全卸载${PLAIN}"
}

# --- 主菜单 ---
while true; do
    check_root
    clear
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    Hysteria 2 一键管理脚本 (v4.2)      ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "  1. 安装 - ${YELLOW}自签名证书${PLAIN} (无域名)"
    echo -e "  2. 安装 - ${GREEN}ACME 证书${PLAIN} (有域名)"
    echo -e "----------------------------------------"
    echo -e "  3. ${SKYBLUE}挂载 Socks5 代理出口${PLAIN}"
    echo -e "  4. ${YELLOW}移除 Socks5 代理出口${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "  5. 查看当前节点信息 / 分享链接"
    echo -e "  6. ${RED}完全卸载 Hysteria 2${PLAIN}"
    echo -e "  0. 退出脚本"
    echo -e ""
    read -p "请选择操作 [0-6]: " choice

    case "$choice" in
        1) install_base; install_core; install_self_signed; read -p "按回车返回菜单..." ;;
        2) install_base; install_core; install_acme; read -p "按回车返回菜单..." ;;
        3) attach_socks5; read -p "按回车返回菜单..." ;;
        4) detach_socks5; read -p "按回车返回菜单..." ;;
        5) print_node_info; read -p "按回车返回菜单..." ;;
        6) uninstall_hy2; read -p "按回车返回菜单..." ;;
        0) echo -e "${GREEN}再见！${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}无效选择${PLAIN}"; sleep 1 ;;
    esac
done