#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> 步骤 1/2: 安装轻量级 WARP (WireProxy - 原生配置版)...${PLAIN}"

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
rm -f wgcf wgcf-account.toml wgcf-profile.conf wireproxy.conf

# 下载并执行注册
wget -O wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.19/wgcf_2.2.19_linux_amd64
chmod +x wgcf

# 注册并生成配置
./wgcf register --accept-tos
./wgcf generate

if [[ ! -f wgcf-profile.conf ]]; then
    echo -e "${RED}注册失败！可能是 IP 注册频率受限。${PLAIN}"
    exit 1
fi

# 4. 修改配置文件 (这是核心修改！)
# 直接将 wgcf 生成的配置复制过来，不再转换格式
cp wgcf-profile.conf wireproxy.conf

# 去掉默认的 DNS 行（有时候 WARP 的 DNS 会导致本地解析慢，通常 VPS 用自带的 DNS 即可）
# 如果你需要 WARP 的 DNS，可以注释掉下面这行
sed -i '/DNS/d' wireproxy.conf

# 追加 Socks5 配置块到文件末尾
# 注意：这里我们设定端口为 40000，以配合后面的脚本
cat <<EOF >> wireproxy.conf

[Socks5]
BindAddress = 127.0.0.1:40000
EOF

echo -e "${YELLOW}生成的配置文件内容预览 (后5行):${PLAIN}"
tail -n 5 wireproxy.conf

# 5. 下载 WireProxy
echo -e "${YELLOW}正在下载 WireProxy...${PLAIN}"
wget -O wireproxy.tar.gz https://github.com/pufferffish/wireproxy/releases/download/v1.0.6/wireproxy_linux_amd64.tar.gz
tar -xzf wireproxy.tar.gz
mv wireproxy /usr/local/bin/
rm wireproxy.tar.gz

# 6. 配置 Systemd
cat <<EOF > /etc/systemd/system/wireproxy.service
[Unit]
Description=WireProxy (Lightweight WARP SOCKS5)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/wireproxy
# 注意：这里直接指定文件名，wireproxy 会自动识别格式
ExecStart=/usr/local/bin/wireproxy -c /etc/wireproxy/wireproxy.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 7. 启动
systemctl daemon-reload
systemctl enable wireproxy
systemctl restart wireproxy

# 8. 验证
echo -e "${YELLOW}正在等待服务启动...${PLAIN}"
sleep 3
# 测试 socks5 端口是否通畅
CHECK_IP=$(curl -s4 -x socks5://127.0.0.1:40000 ifconfig.me)

if [[ -n "$CHECK_IP" ]]; then
    echo -e "${GREEN}WARP 代理启动成功！${PLAIN}"
    echo -e "配置文件路径: /etc/wireproxy/wireproxy.conf"
    echo -e "SOCKS5 地址 : 127.0.0.1:40000"
    echo -e "当前出口 IP : $CHECK_IP"
else
    echo -e "${RED}WARP 启动失败！${PLAIN}"
    echo -e "请运行 'systemctl status wireproxy' 查看详细错误。"
fi
