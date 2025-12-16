#!/bin/bash

# ============================================================
#  Hysteria 2 一键管理脚本 (整合版 + 端口跳跃)
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 核心路径
CONFIG_FILE="/etc/hysteria/config.yaml"
HOPPING_CONF="/etc/hysteria/hopping.conf" # 用于记录跳跃规则以便卸载
HY_BIN="/usr/local/bin/hysteria"

# 1. 基础检查与依赖安装
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

install_base() {
    echo -e "${YELLOW}正在更新系统并安装必要组件 (iptables, curl, wget...)${PLAIN}"
    # 强制安装 iptables 和持久化工具，解决 VPS 没有 iptables 的问题
    apt update -y
    apt install -y curl wget openssl jq iptables iptables-persistent netfilter-persistent
    
    # 开启内核转发 (防止某些环境下转发失效)
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p
    fi
}

# 2. 核心功能：设置 Iptables 端口跳跃
setup_port_hopping() {
    local TARGET_PORT=$1
    local HOP_RANGE=$2

    if [[ -z "$HOP_RANGE" ]]; then
        echo -e "${YELLOW}未配置端口跳跃，跳过。${PLAIN}"
        return
    fi

    echo -e "${YELLOW}正在配置 iptables 端口跳跃规则: $HOP_RANGE -> $TARGET_PORT${PLAIN}"

    # 提取开始和结束端口 (格式 20000-30000)
    local START_PORT=$(echo $HOP_RANGE | cut -d '-' -f 1)
    local END_PORT=$(echo $HOP_RANGE | cut -d '-' -f 2)

    # 1. 清理可能存在的旧规则 (避免重复)
    iptables -t nat -F PREROUTING 2>/dev/null

    # 2. 添加新规则 (将 UDP 流量从范围转发到目标端口)
    iptables -t nat -A PREROUTING -p udp --dport "$START_PORT":"$END_PORT" -j REDIRECT --to-ports "$TARGET_PORT"

    # 3. 保存规则持久化
    netfilter-persistent save

    # 4. 将配置写入文件，方便卸载时读取
    echo "HOP_RANGE=$HOP_RANGE" > "$HOPPING_CONF"
}

# 3. 安装逻辑：Hysteria 2 核心下载
install_core() {
    ARCH=$(dpkg --print-architecture)
    case $ARCH in
        amd64) HY_ARCH="amd64" ;;
        arm64) HY_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    echo -e "${YELLOW}正在获取 Hysteria 2 最新版本...${PLAIN}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
    [[ -z "$LATEST_VERSION" ]] && { echo -e "${RED}获取版本失败${PLAIN}"; exit 1; }

    echo -e "${GREEN}下载版本: ${LATEST_VERSION}${PLAIN}"
    wget -O "$HY_BIN" "https://github.com/apernet/hysteria/releases/download/${LATEST_VERSION}/hysteria-linux-${HY_ARCH}"
    chmod +x "$HY_BIN"
    mkdir -p /etc/hysteria
}

# 4. 模式一：自签名证书安装
install_self_signed() {
    echo -e "${GREEN}>>> 模式选择: 自签名证书 (无需域名)${PLAIN}"
    
    # 输入监听端口
    while true; do
        read -p "请输入 Hy2 监听端口 (目标端口，例如 8443): " LISTEN_PORT
        if [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && [ "$LISTEN_PORT" -le 65535 ]; then break; fi
        echo -e "${RED}端口无效。${PLAIN}"
    done

    # 输入跳跃范围
    read -p "请输入端口跳跃范围 (格式如 20000-30000，留空不开启): " PORT_HOP
    if [[ -n "$PORT_HOP" ]] && ! [[ "$PORT_HOP" =~ ^[0-9]+-[0-9]+$ ]]; then
        echo -e "${RED}格式错误，跳过端口跳跃设置。${PLAIN}"
        PORT_HOP=""
    fi

    # 输入密码
    read -p "设置连接密码 (留空随机): " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -hex 8)

    # 生成证书
    echo -e "${YELLOW}生成自签名证书...${PLAIN}"
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=bing.com"

    # 写入配置
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

    # 配置跳跃
    setup_port_hopping "$LISTEN_PORT" "$PORT_HOP"
    
    # 启动服务
    start_service
    
    # 输出信息
    PUBLIC_IP=$(curl -s4 ifconfig.me)
    echo -e "${GREEN}安装完成！${PLAIN}"
    echo -e "IP: ${YELLOW}$PUBLIC_IP${PLAIN}"
    echo -e "端口: ${YELLOW}$LISTEN_PORT${PLAIN}"
    [[ -n "$PORT_HOP" ]] && echo -e "端口跳跃: ${YELLOW}$PORT_HOP${PLAIN}"
    echo -e "密码: ${YELLOW}$PASSWORD${PLAIN}"
    
    # 生成客户端配置建议
    SERVER_STR="${PUBLIC_IP}:${LISTEN_PORT}"
    [[ -n "$PORT_HOP" ]] && SERVER_STR="${PUBLIC_IP}:${PORT_HOP}"
    
    echo -e "\n${YELLOW}=== 客户端配置建议 ===${PLAIN}"
    echo -e "地址(server): ${GREEN}${SERVER_STR}${PLAIN}"
    echo -e "开启跳过证书验证(insecure): ${GREEN}true${PLAIN}"
}

# 5. 模式二：ACME 证书安装
install_acme() {
    echo -e "${GREEN}>>> 模式选择: ACME 自动证书 (需要域名 + 80/443端口)${PLAIN}"
    
    read -p "请输入域名 (例如 www.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && exit 1
    
    read -p "请输入邮箱 (可选): " EMAIL
    [[ -z "$EMAIL" ]] && EMAIL="admin@$DOMAIN"
    
    # ACME 模式强制监听 443
    LISTEN_PORT=443
    echo -e "${YELLOW}注意: ACME 模式强制监听 443 端口。${PLAIN}"

    # 输入跳跃范围
    read -p "请输入端口跳跃范围 (格式如 20000-30000，留空不开启): " PORT_HOP
    if [[ -n "$PORT_HOP" ]] && ! [[ "$PORT_HOP" =~ ^[0-9]+-[0-9]+$ ]]; then
        echo -e "${RED}格式错误，跳过端口跳跃设置。${PLAIN}"
        PORT_HOP=""
    fi

    read -p "设置连接密码 (留空随机): " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -hex 8)

    # 释放端口
    systemctl stop nginx 2>/dev/null
    systemctl stop apache2 2>/dev/null

    # 写入配置
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

    # 配置跳跃
    setup_port_hopping "$LISTEN_PORT" "$PORT_HOP"

    # 启动服务
    start_service

    # 输出信息
    echo -e "${GREEN}安装完成！${PLAIN}"
    echo -e "域名: ${YELLOW}$DOMAIN${PLAIN}"
    [[ -n "$PORT_HOP" ]] && echo -e "端口跳跃: ${YELLOW}$PORT_HOP${PLAIN} (自动转发到 443)"
    
    # 生成客户端配置建议
    SERVER_STR="${DOMAIN}:${LISTEN_PORT}"
    [[ -n "$PORT_HOP" ]] && SERVER_STR="${DOMAIN}:${PORT_HOP}"
    
    echo -e "\n${YELLOW}=== 客户端配置建议 ===${PLAIN}"
    echo -e "地址(server): ${GREEN}${SERVER_STR}${PLAIN}"
    echo -e "SNI: ${GREEN}${DOMAIN}${PLAIN}"
    echo -e "不安全连接(insecure): ${GREEN}false${PLAIN}"
}

# 6. 通用：启动服务
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

# 7. 卸载功能
uninstall_hy2() {
    echo -e "${RED}正在卸载 Hysteria 2...${PLAIN}"
    
    # 1. 停止服务
    systemctl stop hysteria-server
    systemctl disable hysteria-server
    rm -f /etc/systemd/system/hysteria-server.service
    
    # 2. 清理 iptables 规则
    if [[ -f "$HOPPING_CONF" ]]; then
        source "$HOPPING_CONF"
        if [[ -n "$HOP_RANGE" ]]; then
            START_PORT=$(echo $HOP_RANGE | cut -d '-' -f 1)
            END_PORT=$(echo $HOP_RANGE | cut -d '-' -f 2)
            echo -e "${YELLOW}正在删除端口跳跃规则: $HOP_RANGE${PLAIN}"
            # 尝试删除对应的规则 (使用 -D)
            # 注意：这里需要准确匹配之前添加的规则参数
            # 如果不知道目标端口，直接 flush PREROUTING 可能会误伤其他服务
            # 但作为一个 Hy2 专用脚本，这里简单粗暴地清理 PREROUTING 中 UDP 的引用是比较保险的策略，或者让用户手动重启机器
            
            # 尝试通过 range 精确删除 (需要知道之前的目标端口，这里稍微麻烦)
            # 简单方法：列出所有 nat 规则并根据端口范围删除
            iptables -t nat -S PREROUTING | grep "$START_PORT:$END_PORT" | sed 's/^-A/-D/' | while read rule; do
                iptables -t nat $rule
            done
            netfilter-persistent save
        fi
        rm -f "$HOPPING_CONF"
    fi

    # 3. 删除文件
    rm -f "$HY_BIN"
    rm -rf /etc/hysteria
    
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

# --- 主菜单 ---
check_root

echo -e "${GREEN}Hysteria 2 综合管理脚本${PLAIN}"
echo -e "--------------------------------"
echo -e "1. 安装 - ${YELLOW}自签名证书模式${PLAIN} (支持端口跳跃)"
echo -e "2. 安装 - ${GREEN}ACME 证书模式${PLAIN} (域名 + 443 + 端口跳跃)"
echo -e "3. ${RED}卸载 Hysteria 2${PLAIN}"
echo -e "0. 退出"
echo -e "--------------------------------"
read -p "请选择 [0-3]: " CHOICE

case "$CHOICE" in
    1)
        install_base
        install_core
        install_self_signed
        ;;
    2)
        install_base
        install_core
        install_acme
        ;;
    3)
        uninstall_hy2
        ;;
    0)
        exit 0
        ;;
    *)
        echo "无效选择"
        ;;
esac
