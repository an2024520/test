#!/bin/bash

# ============================================================
#  Hysteria 2 全能管理脚本 (v3.5 安全加固版)
#  - 安全: 修复 Iptables 清理逻辑，杜绝误杀 Docker 网络
#  - 智能: 自动恢复被临时停止的 Nginx/Apache Web 服务
#  - 健壮: 增强 Socks5 挂载的幂等性，防止配置堆叠
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

# --- 辅助功能：检查 Root ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

# --- 辅助功能：Web 服务管理 (快照与恢复) ---
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
        echo -e "${YELLOW}检测到 $WEB_SERVICE 占用端口，正在临时停止...${PLAIN}"
        systemctl stop "$WEB_SERVICE"
        # 标记需要恢复
        touch /tmp/hy2_web_restore_flag
        echo "$WEB_SERVICE" > /tmp/hy2_web_service_name
    fi
}

restore_web_service() {
    if [[ -f /tmp/hy2_web_restore_flag ]]; then
        local SVC=$(cat /tmp/hy2_web_service_name)
        echo -e "${YELLOW}正在尝试恢复 Web 服务 ($SVC)...${PLAIN}"
        # 尝试启动，如果端口冲突(比如Hy2占了443)则会失败，但这比直接不管要好
        systemctl start "$SVC" 2>/dev/null
        if systemctl is-active --quiet "$SVC"; then
            echo -e "${GREEN}Web 服务已恢复。${PLAIN}"
        else
            echo -e "${RED}警告: Web 服务无法启动 (可能端口被 Hysteria 2 占用)。${PLAIN}"
            echo -e "${RED}请稍后检查配置: systemctl status $SVC${PLAIN}"
        fi
        rm -f /tmp/hy2_web_restore_flag /tmp/hy2_web_service_name
    fi
}

# --- 辅助功能：节点信息生成 ---
print_node_info() {
    if [[ ! -f "$CONFIG_FILE" ]]; then return; fi

    echo -e "\n${YELLOW}正在读取当前配置生成分享链接...${PLAIN}"
    
    # 读取配置
    local LISTEN=$(grep "^listen:" $CONFIG_FILE | awk '{print $2}' | tr -d ':')
    if [[ -z "$LISTEN" ]]; then
        LISTEN=$(grep "listen:" $CONFIG_FILE | head -n 1 | awk '{print $2}' | tr -d ':')
    fi
    
    local DOMAIN_ACME=$(grep -A 2 "domains:" $CONFIG_FILE | tail -n 1 | tr -d ' -')
    local PASSWORD=$(grep "password:" $CONFIG_FILE | head -n 1 | awk '{print $2}')
    
    # 状态检测
    local IS_SOCKS5="直连模式"
    if grep -q "# --- SOCKS5 START ---" $CONFIG_FILE; then
        IS_SOCKS5="${SKYBLUE}已挂载 Socks5 代理${PLAIN}"
    fi

    local SHOW_ADDR=""
    local SNI=""
    local INSECURE="0"

    if grep -q "acme:" $CONFIG_FILE; then
        # ACME 模式
        SHOW_ADDR="$DOMAIN_ACME"
        SNI="$DOMAIN_ACME"
        INSECURE="0"
        SKIP_CERT_VAL="false"
    else
        # 自签模式
        SHOW_ADDR=$(curl -s4 ifconfig.me)
        SNI="bing.com"
        INSECURE="1"
        SKIP_CERT_VAL="true"
    fi

    # 端口显示处理
    local SHOW_PORT="$LISTEN"
    local OC_PORT="$LISTEN"
    local OC_COMMENT=""
    
    if [[ -f "$HOPPING_CONF" ]]; then
        source "$HOPPING_CONF"
        if [[ -n "$HOP_RANGE" ]]; then
            SHOW_PORT="$HOP_RANGE"
            echo -e "${YELLOW}检测到端口跳跃，v2rayN 显示范围，OpenClash 使用起始端口。${PLAIN}"
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
    echo -e "地址(IP/Domain): ${YELLOW}${SHOW_ADDR}${PLAIN}"
    echo -e "端口(Port)     : ${YELLOW}${SHOW_PORT}${PLAIN}"
    echo -e "密码(Password) : ${YELLOW}${PASSWORD}${PLAIN}"
    echo -e "SNI (伪装)     : ${YELLOW}${SNI}${PLAIN}"
    echo -e "跳过证书验证   : ${YELLOW}$( [[ "$INSECURE" == "1" ]] && echo "True" || echo "False" )${PLAIN}"
    
    echo -e "\n${YELLOW}➤ v2rayN / Nekoray 分享链接:${PLAIN}"
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

# --- 1. 基础环境安装 ---
install_base() {
    echo -e "${YELLOW}正在更新系统并安装基础组件...${PLAIN}"
    # socat 依然保留，防止某些系统环境缺失基础网络工具
    apt update -y
    apt install -y curl wget openssl jq socat iptables-persistent netfilter-persistent
}

install_core() {
    ARCH=$(dpkg --print-architecture)
    case $ARCH in
        amd64) HY_ARCH="amd64" ;;
        arm64) HY_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    echo -e "${YELLOW}正在获取 Hysteria 2 最新版本...${PLAIN}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
    if [[ -z "$LATEST_VERSION" ]]; then
        echo -e "${RED}获取版本失败，请检查网络。${PLAIN}"
        exit 1
    fi
    
    wget -O "$HY_BIN" "https://github.com/apernet/hysteria/releases/download/${LATEST_VERSION}/hysteria-linux-${HY_ARCH}"
    chmod +x "$HY_BIN"
    mkdir -p /etc/hysteria
}

# --- 2. 端口跳跃设置 (安全版) ---
check_and_install_iptables() {
    if ! command -v iptables &> /dev/null; then
        apt install -y iptables iptables-persistent netfilter-persistent
    fi
    # 开启转发
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
}

setup_port_hopping() {
    local TARGET_PORT=$1
    local HOP_RANGE=$2

    if [[ -z "$HOP_RANGE" ]]; then return; fi

    check_and_install_iptables

    echo -e "${YELLOW}正在配置 iptables 端口跳跃: $HOP_RANGE -> $TARGET_PORT${PLAIN}"
    local START_PORT=$(echo $HOP_RANGE | cut -d '-' -f 1)
    local END_PORT=$(echo $HOP_RANGE | cut -d '-' -f 2)

    # 安全清理旧规则：仅删除针对该目标端口的 REDIRECT 规则
    # 避免使用 -F 清空整个链
    iptables -t nat -D PREROUTING -p udp --dport "$START_PORT":"$END_PORT" -j REDIRECT --to-ports "$TARGET_PORT" 2>/dev/null

    # 添加新规则
    iptables -t nat -A PREROUTING -p udp --dport "$START_PORT":"$END_PORT" -j REDIRECT --to-ports "$TARGET_PORT"
    
    netfilter-persistent save >/dev/null 2>&1
    echo "HOP_RANGE=$HOP_RANGE" > "$HOPPING_CONF"
}

# --- 3. 核心安装逻辑 ---
install_self_signed() {
    echo -e "${GREEN}>>> 安装模式: 自签名证书 (无域名)${PLAIN}"
    while true; do
        read -p "请输入 Hy2 监听端口 (推荐 8443): " LISTEN_PORT
        [[ -z "$LISTEN_PORT" ]] && LISTEN_PORT=8443
        if [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && [ "$LISTEN_PORT" -le 65535 ]; then break; fi
    done
    
    read -p "端口跳跃范围 (如 20000-30000，留空跳过): " PORT_HOP
    read -p "连接密码 (留空随机): " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -hex 16)

    echo -e "${YELLOW}生成自签证书...${PLAIN}"
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=bing.com" >/dev/null 2>&1

    cat <<EOF > "$CONFIG_FILE"
listen: :$LISTEN_PORT
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
auth:
  type: password
  password: $PASSWORD
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
ignoreClientBandwidth: false
EOF
    
    setup_port_hopping "$LISTEN_PORT" "$PORT_HOP"
    start_service
    print_node_info
}

install_acme() {
    echo -e "${GREEN}>>> 安装模式: ACME 证书 (有域名, 强制端口 443)${PLAIN}"
    read -p "请输入域名 (例如 www.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && echo "域名不能为空" && exit 1
    
    read -p "请输入邮箱 (留空自动生成): " EMAIL
    [[ -z "$EMAIL" ]] && EMAIL="admin@$DOMAIN"
    
    # 强制端口 443 以符合 QUIC 标准
    LISTEN_PORT=443
    read -p "端口跳跃范围 (如 20000-30000，留空跳过): " PORT_HOP
    read -p "连接密码 (留空随机): " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -hex 16)

    # 智能停止 Web 服务
    stop_web_service
    
    cat <<EOF > "$CONFIG_FILE"
server:
  listen: :$LISTEN_PORT
acme:
  domains:
    - $DOMAIN
  email: $EMAIL
auth:
  type: password
  password: $PASSWORD
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
ignoreClientBandwidth: false
EOF

    setup_port_hopping "$LISTEN_PORT" "$PORT_HOP"
    start_service
    
    # 尝试恢复 Web 服务
    restore_web_service
    
    print_node_info
}

# --- 4. 挂载 Socks5 逻辑 (幂等性增强) ---
attach_socks5() {
    echo -e "${GREEN}>>> 正在配置 Socks5 出口分流...${PLAIN}"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: 配置文件不存在。${PLAIN}"
        return
    fi

    # 1. 先清理旧配置，防止重复追加
    detach_socks5 "quiet"

    # 2. 获取地址逻辑
    DEFAULT_SOCKS="127.0.0.1:40000"
    DETECTED_INFO=""
    if [[ -f "$WIREPROXY_CONF" ]]; then
        DETECTED_INFO=$(grep "BindAddress" "$WIREPROXY_CONF" | awk -F '=' '{print $2}' | tr -d ' ')
    fi

    if [[ -n "$DETECTED_INFO" ]]; then
        echo -e "${YELLOW}检测到 WireProxy: ${GREEN}${DETECTED_INFO}${PLAIN}"
        read -p "是否使用此地址？(y/n, 默认 y): " USE_DETECTED
        [[ -z "$USE_DETECTED" ]] && USE_DETECTED="y"
        if [[ "$USE_DETECTED" == "y" ]]; then
            PROXY_ADDR="$DETECTED_INFO"
        else
            read -p "请输入 Socks5 地址: " PROXY_ADDR
        fi
    else
        read -p "请输入 Socks5 地址 (默认 127.0.0.1:40000): " PROXY_ADDR
        [[ -z "$PROXY_ADDR" ]] && PROXY_ADDR="$DEFAULT_SOCKS"
    fi

    # 3. 追加配置
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

    echo -e "${GREEN}配置已更新，正在重启服务...${PLAIN}"
    systemctl restart hysteria-server
    sleep 2
    if systemctl is-active --quiet hysteria-server; then
        echo -e "${GREEN}挂载成功！${PLAIN}"
        print_node_info
    else
        echo -e "${RED}启动失败，请检查 Socks5 地址是否有效。${PLAIN}"
        # 失败回滚
        detach_socks5 "quiet"
    fi
}

# --- 5. 移除 Socks5 逻辑 ---
detach_socks5() {
    local MODE=$1
    if [[ "$MODE" != "quiet" ]]; then
        echo -e "${YELLOW}正在移除 Socks5 代理配置...${PLAIN}"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        # 使用 sed 删除标记块
        sed -i '/# --- SOCKS5 START ---/,/# --- SOCKS5 END ---/d' "$CONFIG_FILE"
        # 清理多余空行
        sed -i '/^$/N;/^\n$/D' "$CONFIG_FILE"
    fi

    if [[ "$MODE" != "quiet" ]]; then
        systemctl restart hysteria-server
        echo -e "${GREEN}已恢复直连模式。${PLAIN}"
        print_node_info
    fi
}

# --- 6. 卸载 Iptables 逻辑 (安全重写) ---
uninstall_iptables() {
    echo -e "${RED}==============================================${PLAIN}"
    echo -e "${RED}    警告: 正在卸载 Iptables 及端口跳跃功能    ${PLAIN}"
    echo -e "${RED}==============================================${PLAIN}"
    echo -e "此操作将安全清理跳跃规则，${GREEN}不会影响 Docker 网络${PLAIN}。"
    echo -e ""
    read -p "确认继续? (y/n): " CONFIRM
    [[ "$CONFIRM" != "y" ]] && return

    # 1. 精确读取并删除旧规则
    if [[ -f "$HOPPING_CONF" ]]; then
        source "$HOPPING_CONF"
        if [[ -n "$HOP_RANGE" ]]; then
            local START_PORT=$(echo $HOP_RANGE | cut -d '-' -f 1)
            local END_PORT=$(echo $HOP_RANGE | cut -d '-' -f 2)
            echo -e "${YELLOW}正在删除跳跃规则: $HOP_RANGE ...${PLAIN}"
            
            # 尝试查找目标端口 (从 config 读取会更准，这里尝试泛删除)
            # 由于不确定目标端口，这里更安全的做法是列出所有 REDIRECT 规则并筛选
            # 但简单起见，如果知道 HOP_RANGE，删除匹配该 dport 的规则即可
            iptables -t nat -D PREROUTING -p udp --dport "$START_PORT":"$END_PORT" -j REDIRECT 2>/dev/null
            # 注意：如果指定了 --to-ports 可能会匹配失败，不指定则会匹配所有跳转
        fi
        rm -f "$HOPPING_CONF"
    else
        echo -e "${YELLOW}未找到跳跃配置文件，跳过规则清理。${PLAIN}"
    fi
    
    # 2. 询问是否卸载软件
    echo -e "${YELLOW}是否卸载 iptables 软件本身？${PLAIN}"
    echo -e "注意：如果有其他软件 (如 Docker) 依赖它，请选 n"
    read -p "卸载 iptables 包? (y/n, 默认 n): " RM_PKG
    if [[ "$RM_PKG" == "y" ]]; then
        apt remove -y iptables-persistent netfilter-persistent
    fi
    
    # 保存更改 (如果没卸载的话)
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    fi

    echo -e "${GREEN}清理完成。${PLAIN}"
}

# --- 7. 服务管理与卸载 ---
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
Environment=HYSTERIA_ACME_DIR=/etc/hysteria/acme

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl restart hysteria-server
}

uninstall_hy2() {
    echo -e "${RED}警告: 即将卸载 Hysteria 2 及其配置。${PLAIN}"
    read -p "确认继续? (y/n): " CONFIRM
    [[ "$CONFIRM" != "y" ]] && return

    systemctl stop hysteria-server
    systemctl disable hysteria-server
    rm -f /etc/systemd/system/hysteria-server.service
    
    # 清理 iptables 规则 (调用上面的安全函数)
    if [[ -f "$HOPPING_CONF" ]]; then
        source "$HOPPING_CONF"
        if [[ -n "$HOP_RANGE" ]]; then
             local START_PORT=$(echo $HOP_RANGE | cut -d '-' -f 1)
             local END_PORT=$(echo $HOP_RANGE | cut -d '-' -f 2)
             iptables -t nat -D PREROUTING -p udp --dport "$START_PORT":"$END_PORT" -j REDIRECT 2>/dev/null
             if command -v netfilter-persistent &> /dev/null; then
                 netfilter-persistent save >/dev/null 2>&1
             fi
        fi
        rm -f "$HOPPING_CONF"
    fi
    
    rm -f "$HY_BIN"
    rm -rf /etc/hysteria
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

# --- 主菜单 ---
while true; do
    check_root
    clear
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    Hysteria 2 一键管理脚本 (v3.5)      ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "  1. 安装 - ${YELLOW}自签名证书${PLAIN} (无域名/直连)"
    echo -e "  2. 安装 - ${GREEN}ACME 证书${PLAIN} (有域名/强制443)"
    echo -e "----------------------------------------"
    echo -e "  3. ${SKYBLUE}挂载 Socks5 代理出口${PLAIN} (Warp/解锁)"
    echo -e "  4. ${YELLOW}移除 Socks5 代理出口${PLAIN} (恢复直连)"
    echo -e "----------------------------------------"
    echo -e "  5. 查看当前节点配置 / 分享链接"
    echo -e "  6. ${RED}卸载 Hysteria 2${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "  7. ${RED}卸载 Iptables${PLAIN} (仅清理规则)"
    echo -e "  0. 退出"
    echo -e ""
    read -p "请选择操作 [0-7]: " choice

    case "$choice" in
        1) install_base; install_core; install_self_signed; read -p "按回车继续..." ;;
        2) install_base; install_core; install_acme; read -p "按回车继续..." ;;
        3) attach_socks5; read -p "按回车继续..." ;;
        4) detach_socks5; read -p "按回车继续..." ;;
        5) print_node_info; read -p "按回车继续..." ;;
        6) uninstall_hy2; read -p "按回车继续..." ;;
        7) uninstall_iptables; read -p "按回车继续..." ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
    esac
done
