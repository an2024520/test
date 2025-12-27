#!/bin/sh

# ============================================================
#  Alpine WireProxy (WARP) 一键安装脚本
#  功能：在本地 127.0.0.1:40000 开启 WARP SOCKS5 代理
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PLAIN='\033[0m'

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

install_wireproxy() {
    echo -e "${GREEN}>>> 开始安装/重置 WARP (WireProxy) for Alpine...${PLAIN}"

    # 1. 准备工作 & 安装依赖
    # libc6-compat 是必须要的，否则二进制文件无法运行
    echo -e "${YELLOW}安装必要依赖 (libc6-compat, curl, grep)...${PLAIN}"
    rc-service wireproxy stop >/dev/null 2>&1
    apk update
    apk add --no-cache curl wget grep sed libc6-compat ca-certificates

    mkdir -p /etc/wireproxy
    cd /etc/wireproxy

    # 2. 下载 wgcf 并注册账号
    # 注意：如果 VPS 无法访问 GitHub，你可能需要手动上传 wgcf 和 wireproxy 到 /usr/local/bin/
    echo -e "${YELLOW}正在下载 wgcf 并注册...${PLAIN}"
    rm -f wgcf wgcf-account.toml wgcf-profile.conf wireproxy.conf
    
    # 下载 wgcf (使用原脚本版本)
    wget -O wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.19/wgcf_2.2.19_linux_amd64
    chmod +x wgcf
    
    # 注册
    echo -e "${YELLOW}执行注册 (若卡住请检查网络)...${PLAIN}"
    ./wgcf register --accept-tos
    ./wgcf generate

    if [ ! -f wgcf-profile.conf ]; then
        echo -e "${RED}注册失败！可能是 GitHub 连不上或 IP 注册频率受限。${PLAIN}"
        echo -e "如果下载失败，请手动下载 wgcf 上传到 /etc/wireproxy/ 目录。"
        return
    fi

    # 3. 配置文件优化
    echo -e "${YELLOW}正在生成 WireProxy 配置...${PLAIN}"
    cp wgcf-profile.conf wireproxy.conf
    
    # [重要修改] 你的 VPS 是纯 IPv6，绝对不能把 Endpoint 改成 IPv4 (162.159...)
    # 我们保留 engage.cloudflareclient.com，系统会自动解析为 IPv6 地址连接
    
    # 删除无关参数
    sed -i '/KeepAlive/d' wireproxy.conf
    sed -i '/PersistentKeepalive/d' wireproxy.conf
    sed -i '/Endpoint/a PersistentKeepalive = 25' wireproxy.conf

    # 添加 SOCKS5 监听配置
    cat <<EOF >> wireproxy.conf

[Socks5]
BindAddress = 127.0.0.1:40000
EOF

    # 4. 下载 WireProxy 主程序
    if [ ! -f /usr/local/bin/wireproxy ]; then
        echo -e "${YELLOW}下载 WireProxy 程序...${PLAIN}"
        wget -O wireproxy.tar.gz https://github.com/pufferffish/wireproxy/releases/download/v1.0.9/wireproxy_linux_amd64.tar.gz
        tar -xzf wireproxy.tar.gz
        mv wireproxy /usr/local/bin/
        rm wireproxy.tar.gz
    fi
    chmod +x /usr/local/bin/wireproxy

    # 5. 创建 OpenRC 服务 (Alpine 专用)
    echo -e "${YELLOW}配置 OpenRC 服务...${PLAIN}"
    cat <<EOF > /etc/init.d/wireproxy
#!/sbin/openrc-run

name="wireproxy"
description="WireProxy (Lightweight WARP SOCKS5)"
command="/usr/local/bin/wireproxy"
command_args="-c /etc/wireproxy/wireproxy.conf"
command_background=true
pidfile="/run/wireproxy.pid"
output_log="/var/log/wireproxy.log"
error_log="/var/log/wireproxy.err"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/wireproxy

    # 6. 启动
    echo -e "${YELLOW}启动服务...${PLAIN}"
    rc-update add wireproxy default
    rc-service wireproxy restart
    
    sleep 2
    
    if rc-service wireproxy status | grep -q "started"; then
        echo -e "${GREEN}✅ WARP (Socks5:40000) 安装成功！${PLAIN}"
        echo -e "本地监听端口: 127.0.0.1:40000"
    else
        echo -e "${RED}❌ 启动失败，请查看日志: cat /var/log/wireproxy.err${PLAIN}"
    fi
}

uninstall_wireproxy() {
    echo -e "${RED}>>> 正在卸载 WireProxy...${PLAIN}"
    rc-service wireproxy stop
    rc-update del wireproxy default
    rm -f /etc/init.d/wireproxy
    rm -rf /etc/wireproxy
    rm -f /usr/local/bin/wireproxy
    echo -e "${GREEN}WireProxy 已卸载清除。${PLAIN}"
}

# --- 菜单逻辑 ---
echo -e "${YELLOW}请选择操作:${PLAIN}"
echo -e "  1. 安装 / 重置 WireProxy (Alpine版)"
echo -e "  2. 卸载 WireProxy"
printf "选择 [1-2]: "
read choice

case $choice in
    1) install_wireproxy ;;
    2) uninstall_wireproxy ;;
    *) echo -e "取消操作。" ;;
esac
