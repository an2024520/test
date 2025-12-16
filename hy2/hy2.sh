#!/bin/bash

# ============================================================
#  Hysteria 2 全能管理脚本 (v3.3 修复版)
#  - 修复: 找回 OpenClash 配置输出
#  - 修复: v2rayN 节点备注显示问题
#  - 功能: 安装/卸载/端口跳跃/Socks5分流
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

# --- 辅助功能：节点信息生成 (核心修复部分) ---
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
    local OC_PORT="$LISTEN" # OpenClash 专用端口变量
    local OC_COMMENT=""     # OpenClash 备注
    
    if [[ -f "$HOPPING_CONF" ]]; then
        source "$HOPPING_CONF"
        if [[ -n "$HOP_RANGE" ]]; then
            SHOW_PORT="$HOP_RANGE"
            echo -e "${YELLOW}检测到端口跳跃设置，v2rayN 将显示范围，OpenClash 将使用起始端口。${PLAIN}"
            
            # 提取起始端口给 OpenClash (Clash config 通常只能读整数端口)
            local START_PORT=$(echo $HOP_RANGE | cut -d '-' -f 1)
            OC_PORT="$START_PORT"
            OC_COMMENT="# 端口跳跃范围: ${HOP_RANGE} (Clash仅连接其中一个即可)"
        fi
    fi

    # 生成链接 (使用 # 符号作为备注，修复 v2rayN 别名问题)
    local NODE_NAME="Hy2-${SHOW_ADDR}"
    local V2RAYN_LINK="hysteria2://${PASSWORD}@${SHOW_ADDR}:${SHOW_PORT}/?sni=${SNI}&insecure=${INSECURE}#${NODE_NAME}"

    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}      Hysteria 2 配置信息 (${IS_SOCKS5})      ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "地址(IP/Domain): ${YELLOW}${SHOW_ADDR}${PLAIN}"
    echo -e "端口(Port)     : ${YELLOW}${SHOW_PORT}${PLAIN}"
    echo -e "密码(Password) : ${YELLOW}${PASSWORD}${PLAIN}"
    echo -e "SNI (伪装)     : ${YELLOW}${SNI}${PLAIN}"
    echo -e "跳过证书验证   : ${YELLOW}$( [[ "$INSECURE" == "1" ]] && echo "True (是)" || echo "False (否)" )${PLAIN}"
    
    echo -e "\n${YELLOW}➤ v2rayN / Nekoray 分享链接:${PLAIN}"
    echo -e "----------------------------------------------"
    echo -e "${V2RAYN_LINK}"
    echo -e "----------------------------------------------"
    
    echo -e "\n${YELLOW}➤ OpenClash / Clash Meta (YAML) 配置:${PLAIN}"
    echo -e "----------------------------------------------"
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

# --- 1. 基础环境安装 (不含 iptables) ---
install_base() {
    echo -e "${YELLOW}正在更新系统并安装基础组件...${PLAIN}"
    apt update -y
    apt install -y curl wget openssl jq socat
}

install_core() {
    ARCH=$(dpkg --print-architecture)
    case $ARCH in
        amd64) HY_ARCH="amd64" ;;
        arm64) HY_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
    wget -O "$HY_BIN" "https://github.com/apernet/hysteria/releases/download/${LATEST_VERSION}/hysteria-linux-${HY_ARCH}"
    chmod +x "$HY_BIN"
    mkdir -p /etc/hysteria
}

# --- 2. 端口跳跃设置 (按需安装 Iptables) ---
check_and_install_iptables() {
    if ! command -v iptables &> /dev/null; then
        echo -e "${YELLOW}检测到需要端口跳跃但未安装 iptables，正在安装...${PLAIN}"
        apt install -y iptables iptables-persistent netfilter-persistent
        if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
            sysctl -p
        fi
    else
        if ! dpkg -s iptables-persistent &> /dev/null; then
             apt install -y iptables-persistent netfilter-persistent
        fi
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

    iptables -t nat -F PREROUTING 2>/dev/null
    iptables -t nat -A PREROUTING -p udp --dport "$START_PORT":"$END_PORT" -j REDIRECT --to-ports "$TARGET_PORT"
    
    netfilter-persistent save
    echo "HOP_RANGE=$HOP_RANGE" > "$HOPPING_CONF"
}

# --- 3. 核心安装逻辑 ---
install_self_signed() {
    echo -e "${GREEN}>>> 安装模式: 自签名证书 (无域名)${PLAIN}"
    while true; do
        read -p "请输入 Hy2 监听端口 (默认 8443): " LISTEN_PORT
        [[ -z "$LISTEN_PORT" ]] && LISTEN_PORT=8443
        if [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && [ "$LISTEN_PORT" -le 65535 ]; then break; fi
    done
    
    read -p "端口跳跃范围 (如 20000-30000，留空跳过): " PORT_HOP
    read -p "连接密码 (留空随机): " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -hex 8)

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
    
    LISTEN_PORT=443
    read -p "端口跳跃范围 (如 20000-30000，留空跳过): " PORT_HOP
    read -p "连接密码 (留空随机): " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -hex 8)

    systemctl stop nginx 2>/dev/null
    
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
EOF

    setup_port_hopping "$LISTEN_PORT" "$PORT_HOP"
    start_service
    print_node_info
}

# --- 4. 挂载 Socks5 逻辑 ---
attach_socks5() {
    echo -e "${GREEN}>>> 正在配置 Socks5 出口分流...${PLAIN}"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误: Hysteria 2 未安装，找不到配置文件。${PLAIN}"
        return
    fi

    if grep -q "# --- SOCKS5 START ---" "$CONFIG_FILE"; then
        echo -e "${RED}检测到当前已经挂载了 Socks5 代理！${PLAIN}"
        read -p "是否先移除旧代理再重新挂载？(y/n): " RE_ATTACH
        if [[ "$RE_ATTACH" == "y" ]]; then
            detach_socks5 "quiet"
        else
            echo "操作取消。"
            return
        fi
    fi

    DEFAULT_SOCKS="127.0.0.1:40000"
    DETECTED_INFO=""
    
    if [[ -f "$WIREPROXY_CONF" ]]; then
        DETECTED_INFO=$(grep "BindAddress" "$WIREPROXY_CONF" | awk -F '=' '{print $2}' | tr -d ' ')
    fi

    if [[ -n "$DETECTED_INFO" ]]; then
        echo -e "${YELLOW}检测到 WireProxy 配置地址: ${GREEN}${DETECTED_INFO}${PLAIN}"
        read -p "是否使用此地址作为出口？(y/n, 默认 y): " USE_DETECTED
        [[ -z "$USE_DETECTED" ]] && USE_DETECTED="y"
        
        if [[ "$USE_DETECTED" == "y" ]]; then
            PROXY_ADDR="$DETECTED_INFO"
        else
            read -p "请输入自定义 Socks5 地址 (例如 127.0.0.1:40000): " PROXY_ADDR
        fi
    else
        echo -e "${YELLOW}未检测到 WireProxy 默认配置，请手动输入。${PLAIN}"
        read -p "请输入 Socks5 地址 (默认 127.0.0.1:40000): " PROXY_ADDR
        [[ -z "$PROXY_ADDR" ]] && PROXY_ADDR="$DEFAULT_SOCKS"
    fi

    echo -e "${YELLOW}正在测试代理连通性: ${PROXY_ADDR}...${PLAIN}"
    P_IP=$(echo $PROXY_ADDR | cut -d: -f1)
    P_PORT=$(echo $PROXY_ADDR | cut -d: -f2)
    
    if curl -s --max-time 5 -x "socks5://${P_IP}:${P_PORT}" https://www.google.com >/dev/null; then
        echo -e "${GREEN}代理连通性测试通过！${PLAIN}"
    else
        echo -e "${RED}警告: 代理连接测试失败(Google)。${PLAIN}"
        read -p "是否强制继续？(y/n): " FORCE_GO
        if [[ "$FORCE_GO" != "y" ]]; then echo "操作取消"; return; fi
    fi

    echo -e "${YELLOW}正在写入配置文件...${PLAIN}"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

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

    echo -e "${GREEN}配置已追加。正在重启服务...${PLAIN}"
    systemctl restart hysteria-server
    sleep 2
    if systemctl is-active --quiet hysteria-server; then
        echo -e "${GREEN}挂载成功！所有流量已转发至 Socks5 (${PROXY_ADDR})${PLAIN}"
        print_node_info
    else
        echo -e "${RED}重启失败，请检查配置。正在还原...${PLAIN}"
        cp "${CONFIG_FILE}.bak" "$CONFIG_FILE"
        systemctl restart hysteria-server
    fi
}

# --- 5. 移除 Socks5 逻辑 ---
detach_socks5() {
    local MODE=$1
    if [[ "$MODE" != "quiet" ]]; then
        echo -e "${YELLOW}正在移除 Socks5 代理配置...${PLAIN}"
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}配置文件不存在。${PLAIN}"
        return
    fi

    if ! grep -q "# --- SOCKS5 START ---" "$CONFIG_FILE"; then
        if [[ "$MODE" != "quiet" ]]; then
            echo -e "${RED}当前未检测到已挂载的 Socks5 配置，无需移除。${PLAIN}"
        fi
        return
    fi

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    sed -i '/# --- SOCKS5 START ---/,/# --- SOCKS5 END ---/d' "$CONFIG_FILE"
    sed -i '/^$/N;/^\n$/D' "$CONFIG_FILE"

    if [[ "$MODE" != "quiet" ]]; then
        echo -e "${GREEN}配置已清理。正在重启服务...${PLAIN}"
        systemctl restart hysteria-server
        echo -e "${GREEN}已恢复直连模式。${PLAIN}"
        print_node_info
    fi
}

# --- 6. 卸载 Iptables 逻辑 ---
uninstall_iptables() {
    echo -e "${RED}==============================================${PLAIN}"
    echo -e "${RED}    警告: 正在卸载 Iptables 及端口跳跃功能    ${PLAIN}"
    echo -e "${RED}==============================================${PLAIN}"
    echo -e "此操作将执行："
    echo -e "1. ${YELLOW}清空${PLAIN} 所有 iptables 转发规则 (端口跳跃失效)"
    echo -e "2. ${YELLOW}卸载${PLAIN} iptables, netfilter-persistent 等组件"
    echo -e "3. ${YELLOW}释放${PLAIN} 内存与磁盘空间"
    echo -e ""
    read -p "确认继续? (y/n): " CONFIRM
    [[ "$CONFIRM" != "y" ]] && return

    echo -e "${YELLOW}步骤 1/3: 正在清除防火墙规则...${PLAIN}"
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -t nat -F
    iptables -t mangle -F
    iptables -F
    iptables -X
    
    echo -e "${YELLOW}步骤 2/3: 正在卸载相关组件...${PLAIN}"
    systemctl stop netfilter-persistent 2>/dev/null
    apt remove -y iptables iptables-persistent netfilter-persistent
    apt autoremove -y
    
    echo -e "${YELLOW}步骤 3/3: 清理标记文件...${PLAIN}"
    rm -f "$HOPPING_CONF"

    echo -e "${GREEN}卸载完成！您的系统已恢复轻量状态。${PLAIN}"
    echo -e "注意：Hysteria 2 主端口依然可用，但跳跃端口已失效。"
}

# --- 7. 服务管理 ---
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
    
    iptables -t nat -F PREROUTING 2>/dev/null
    if command -v netfilter-persistent &> /dev/null; then
         netfilter-persistent save
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
    echo -e "${GREEN}    Hysteria 2 一键管理脚本 (v3.3)      ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "  1. 安装 - ${YELLOW}自签名证书${PLAIN} (无域名/直连)"
    echo -e "  2. 安装 - ${GREEN}ACME 证书${PLAIN} (有域名/直连)"
    echo -e "----------------------------------------"
    echo -e "  3. ${SKYBLUE}挂载 Socks5 代理出口${PLAIN} (Warp/解锁)"
    echo -e "  4. ${YELLOW}移除 Socks5 代理出口${PLAIN} (恢复直连)"
    echo -e "----------------------------------------"
    echo -e "  5. 查看当前节点配置 / 分享链接"
    echo -e "  6. ${RED}卸载 Hysteria 2${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "  7. ${RED}卸载 Iptables${PLAIN} (清理端口跳跃残留)"
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
