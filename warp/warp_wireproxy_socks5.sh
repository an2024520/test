#!/bin/bash

# ============================================================
#  Warp WireProxy 管理器 (安装 / 卸载)
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查 root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

install_wireproxy() {
    echo -e "${GREEN}>>> 开始安装/重置 WARP (WireProxy)...${PLAIN}"

    # 1. 准备工作
    systemctl stop wireproxy >/dev/null 2>&1
    apt update -y
    apt install -y curl wget grep sed

    mkdir -p /etc/wireproxy
    cd /etc/wireproxy

    # 2. 注册 WARP
    echo -e "${YELLOW}正在注册 WARP 账号...${PLAIN}"
    rm -f wgcf wgcf-account.toml wgcf-profile.conf wireproxy.conf
    wget -O wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.19/wgcf_2.2.19_linux_amd64
    chmod +x wgcf
    
    ./wgcf register --accept-tos
    ./wgcf generate

    if [[ ! -f wgcf-profile.conf ]]; then
        echo -e "${RED}注册失败！可能是 IP 注册频率受限。${PLAIN}"
        return
    fi

    # 3. 配置文件优化
    echo -e "${YELLOW}正在生成配置...${PLAIN}"
    cp wgcf-profile.conf wireproxy.conf
    sed -i 's/engage.cloudflareclient.com/162.159.192.1/g' wireproxy.conf
    sed -i '/KeepAlive/d' wireproxy.conf
    sed -i '/PersistentKeepalive/d' wireproxy.conf
    sed -i '/Endpoint/a PersistentKeepalive = 10' wireproxy.conf

    cat <<EOF >> wireproxy.conf

[Socks5]
BindAddress = 127.0.0.1:40000
EOF

    # 4. 下载主程序
    if [[ ! -f /usr/local/bin/wireproxy ]]; then
        echo -e "${YELLOW}下载 WireProxy 程序...${PLAIN}"
        wget -O wireproxy.tar.gz https://github.com/pufferffish/wireproxy/releases/download/v1.0.9/wireproxy_linux_amd64.tar.gz
        tar -xzf wireproxy.tar.gz
        mv wireproxy /usr/local/bin/
        rm wireproxy.tar.gz
    fi

    # 5. 服务配置
    cat <<EOF > /etc/systemd/system/wireproxy.service
[Unit]
Description=WireProxy (Lightweight WARP SOCKS5)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/wireproxy
ExecStart=/usr/local/bin/wireproxy -c /etc/wireproxy/wireproxy.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # 6. 启动
    systemctl daemon-reload
    systemctl enable wireproxy
    systemctl restart wireproxy
    
    echo -e "${YELLOW}等待服务启动...${PLAIN}"
    sleep 3
    
    if systemctl is-active --quiet wireproxy; then
        echo -e "${GREEN}WARP (Socks5:40000) 安装并启动成功！${PLAIN}"
    else
        echo -e "${RED}启动失败，请检查日志。${PLAIN}"
    fi
}

uninstall_wireproxy() {
    echo -e "${RED}>>> 正在卸载 WireProxy...${PLAIN}"
    systemctl stop wireproxy
    systemctl disable wireproxy
    rm -f /etc/systemd/system/wireproxy.service
    rm -rf /etc/wireproxy
    rm -f /usr/local/bin/wireproxy
    systemctl daemon-reload
    echo -e "${GREEN}WireProxy 已卸载清除。${PLAIN}"
}

# --- 菜单逻辑 ---
echo -e "${YELLOW}请选择操作:${PLAIN}"
echo -e "  1. 安装 / 重置 WireProxy (WARP)"
echo -e "  2. 卸载 WireProxy"
read -p "选择 [1-2]: " choice

case $choice in
    1) install_wireproxy ;;
    2) uninstall_wireproxy ;;
    *) echo -e "取消操作。" ;;
esac
