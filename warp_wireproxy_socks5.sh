#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> 步骤 1/2: 安装轻量级 WARP (WireProxy)...${PLAIN}"

# 1. 检查 root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# 2. 准备工作
apt update -y
apt install -y curl wget grep

mkdir -p /etc/wireproxy
cd /etc/wireproxy

# 3. 注册 WARP 账号 (WGCF)
echo -e "${YELLOW}正在注册 WARP 账号...${PLAIN}"
# 清理旧文件
rm -f wgcf wgcf-account.toml wgcf-profile.conf

# 下载并执行注册
wget -O wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.19/wgcf_2.2.19_linux_amd64
chmod +x wgcf

./wgcf register --accept-tos
./wgcf generate

if [[ ! -f wgcf-profile.conf ]]; then
    echo -e "${RED}注册失败！可能是 IP 注册频率受限。请稍后再试或本地生成后上传。${PLAIN}"
    exit 1
fi

# 4. 提取配置
PRIVATE_KEY=$(grep 'PrivateKey' wgcf-profile.conf | cut -d' ' -f3)
ADDRESS_6=$(grep 'Address' wgcf-profile.conf | grep ':' | cut -d' ' -f3)
if [[ -z "$ADDRESS_6" ]]; then
    ADDRESS_6=$(grep 'Address' wgcf-profile.conf | grep '\.' | cut -d' ' -f3)
fi

# 5. 下载 WireProxy
echo -e "${YELLOW}正在配置 WireProxy...${PLAIN}"
wget -O wireproxy.tar.gz https://github.com/pufferffish/wireproxy/releases/download/v1.0.6/wireproxy_linux_amd64.tar.gz
tar -xzf wireproxy.tar.gz
mv wireproxy /usr/local/bin/
rm wireproxy.tar.gz

# 6. 生成配置文件
cat <<EOF > /etc/wireproxy/config.yaml
wg:
  address: $ADDRESS_6
  mtu: 1280
  privateKey: $PRIVATE_KEY
  endpoint: engage.cloudflareclient.com:2408
  keepAlive: 25

socks5:
  bindAddress: 127.0.0.1:40000
EOF

# 7. 配置 Systemd
cat <<EOF > /etc/systemd/system/wireproxy.service
[Unit]
Description=WireProxy (Lightweight WARP SOCKS5)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/wireproxy
ExecStart=/usr/local/bin/wireproxy -c /etc/wireproxy/config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 8. 启动
systemctl daemon-reload
systemctl enable wireproxy
systemctl restart wireproxy

# 9. 验证
sleep 2
CHECK_IP=$(curl -s4 -x socks5://127.0.0.1:40000 ifconfig.me)

if [[ -n "$CHECK_IP" ]]; then
    echo -e "${GREEN}WARP 代理启动成功！${PLAIN}"
    echo -e "SOCKS5 地址: 127.0.0.1:40000"
    echo -e "当前出口 IP: $CHECK_IP"
else
    echo -e "${RED}WARP 启动失败，请检查 /etc/wireproxy/config.yaml${PLAIN}"
fi
