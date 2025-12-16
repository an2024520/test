#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> 步骤 1/2: 安装轻量级 WARP (WireProxy 最终完美版)...${PLAIN}"

# 1. 检查 root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# 2. 准备工作 & 清理旧环境
# 先停止服务，防止端口占用
systemctl stop wireproxy >/dev/null 2>&1

apt update -y
apt install -y curl wget grep sed

mkdir -p /etc/wireproxy
cd /etc/wireproxy

# 3. 注册 WARP 账号 (WGCF)
echo -e "${YELLOW}正在注册 WARP 账号...${PLAIN}"
# 清理旧文件
rm -f wgcf wgcf-account.toml wgcf-profile.conf wireproxy.conf

# 下载 WGCF
wget -O wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.19/wgcf_2.2.19_linux_amd64
chmod +x wgcf

# 注册并生成配置
./wgcf register --accept-tos
./wgcf generate

if [[ ! -f wgcf-profile.conf ]]; then
    echo -e "${RED}注册失败！可能是 IP 注册频率受限。${PLAIN}"
    exit 1
fi

# 4. 配置文件优化 (核心步骤)
echo -e "${YELLOW}正在优化配置 (DNS + 固定 IP + 防掉线)...${PLAIN}"

# 复制原始配置 (wgcf 生成的默认配置里已经包含了 DNS，我们保留它)
cp wgcf-profile.conf wireproxy.conf

# --- 优化 A: 将 Endpoint 域名修改为固定 IPv4 地址 ---
# 将 engage.cloudflareclient.com 替换为 162.159.192.1 (Cloudflare Anycast IP)
sed -i 's/engage.cloudflareclient.com/162.159.192.1/g' wireproxy.conf

# --- 优化 B: 设置 PersistentKeepalive = 10 (防掉线) ---
# 先清理可能存在的旧配置，防止重复
sed -i '/KeepAlive/d' wireproxy.conf
sed -i '/PersistentKeepalive/d' wireproxy.conf
# 在 Endpoint 行后面插入 Keepalive 配置
sed -i '/Endpoint/a PersistentKeepalive = 10' wireproxy.conf

# --- 优化 C: 追加 Socks5 配置块 ---
cat <<EOF >> wireproxy.conf

[Socks5]
BindAddress = 127.0.0.1:40000
EOF

echo -e "${YELLOW}生成的配置文件内容预览 (后12行):${PLAIN}"
tail -n 12 wireproxy.conf

# 5. 下载 WireProxy (主程序)
echo -e "${YELLOW}正在下载 WireProxy...${PLAIN}"
wget -O wireproxy.tar.gz https://github.com/pufferffish/wireproxy/releases/download/v1.0.9/wireproxy_linux_amd64.tar.gz
tar -xzf wireproxy.tar.gz
mv wireproxy /usr/local/bin/
rm wireproxy.tar.gz

# 6. 配置 Systemd 服务
cat <<EOF > /etc/systemd/system/wireproxy.service
[Unit]
Description=WireProxy (Lightweight WARP SOCKS5)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/wireproxy
# 显式指定配置文件路径
ExecStart=/usr/local/bin/wireproxy -c /etc/wireproxy/wireproxy.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 7. 启动服务
systemctl daemon-reload
systemctl enable wireproxy
systemctl restart wireproxy

# 8. 验证
echo -e "${YELLOW}正在等待服务启动...${PLAIN}"
sleep 3
# 测试 socks5 端口是否通畅
CHECK_IP=$(curl -s4 -x socks5://127.0.0.1:40000 ifconfig.me)

if [[ -n "$CHECK_IP" ]]; then
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}      WARP 代理 (WireProxy) 启动成功    ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "配置文件    : /etc/wireproxy/wireproxy.conf"
    echo -e "SOCKS5 地址 : 127.0.0.1:40000"
    echo -e "当前出口 IP : ${CHECK_IP}"
    echo -e "DNS 策略    : ${YELLOW}已启用 (强制使用 Cloudflare DNS)${PLAIN}"
    echo -e "连接策略    : ${YELLOW}固定 IP + 10s 心跳保活${PLAIN}"
    echo -e "----------------------------------------"
else
    echo -e "${RED}WARP 启动失败！${PLAIN}"
    echo -e "请运行 'systemctl status wireproxy' 查看详细错误。"
fi
