#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}开始安装轻量版 WARP (WireProxy)...${PLAIN}"

# 1. 检查 root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# 2. 安装必要工具
apt update -y
apt install -y curl wget grep sed awk

# 3. 准备目录
mkdir -p /etc/wireproxy
cd /etc/wireproxy

# 4. 获取 WGCF 并注册账号 (用于生成证书)
echo -e "${YELLOW}正在使用 WGCF 注册 WARP 账号...${PLAIN}"
rm -f wgcf wgcf-account.toml wgcf-profile.conf

# 下载 WGCF
wget -O wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.19/wgcf_2.2.19_linux_amd64
chmod +x wgcf

# 注册账号
./wgcf register --accept-tos
./wgcf generate

if [[ ! -f wgcf-profile.conf ]]; then
    echo -e "${RED}错误: WARP 账号注册失败，可能是 Cloudflare API 限制，请稍后重试或更换 IP。${PLAIN}"
    exit 1
fi

# 5. 提取密钥信息
PRIVATE_KEY=$(grep 'PrivateKey' wgcf-profile.conf | cut -d' ' -f3)
# 提取 IPv6 地址 (通常 WARP 的 v6 地址更稳定，且 wireproxy 处理得很好)
ADDRESS_6=$(grep 'Address' wgcf-profile.conf | grep ':' | cut -d' ' -f3)
# 如果没提取到 v6，尝试 v4
if [[ -z "$ADDRESS_6" ]]; then
    ADDRESS_6=$(grep 'Address' wgcf-profile.conf | grep '\.' | cut -d' ' -f3)
fi

echo -e "${GREEN}获取成功!${PLAIN}"
echo -e "PrivateKey: $PRIVATE_KEY"
echo -e "Address: $ADDRESS_6"

# 6. 下载 WireProxy (轻量级客户端)
echo -e "${YELLOW}正在下载 WireProxy...${PLAIN}"
wget -O wireproxy.tar.gz https://github.com/pufferffish/wireproxy/releases/download/v1.0.6/wireproxy_linux_amd64.tar.gz
tar -xzf wireproxy.tar.gz
mv wireproxy /usr/local/bin/
rm wireproxy.tar.gz

# 7. 生成 WireProxy 配置文件
# 这是核心：它定义了一个连接到 Cloudflare 的接口，并暴露一个 SOCKS5 端口
cat <<EOF > /etc/wireproxy/config.yaml
# 定义连接 Cloudflare 的 WireGuard 接口
wg:
  address: $ADDRESS_6
  mtu: 1280
  privateKey: $PRIVATE_KEY
  endpoint: engage.cloudflareclient.com:2408
  keepAlive: 25

# 定义 SOCKS5 服务端口
socks5:
  bindAddress: 127.0.0.1:40000
EOF

# 8. 创建 Systemd 服务
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

# 启动 WireProxy
systemctl daemon-reload
systemctl enable wireproxy
systemctl restart wireproxy

# 等待启动并测试
sleep 3
PROXY_IP=$(curl -s4 -x socks5://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace | grep warp | cut -d= -f2)

if [[ "$PROXY_IP" == "on" ]]; then
    echo -e "${GREEN}轻量版 WARP 启动成功！(SOCKS5 端口: 40000)${PLAIN}"
else
    echo -e "${RED}WARP 启动失败，请检查 /etc/wireproxy/config.yaml${PLAIN}"
    echo -e "可能是 Cloudflare 节点暂时无法连接。"
fi

# 9. 修改 Hysteria 2 配置 (如果尚未配置)
CONFIG_FILE="/etc/hysteria/config.yaml"
if [[ -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}正在更新 Hysteria 2 配置以使用 WARP...${PLAIN}"
    
    # 简单的文本替换逻辑很难完美处理 yaml 结构，这里我们追加或重写
    # 为了保险，我们备份并重新生成配置（保留原密码和端口）
    
    OLD_PORT=$(grep "listen:" $CONFIG_FILE | awk -F':' '{print $3}' | tr -d ' ')
    OLD_PASSWORD=$(grep "password:" $CONFIG_FILE | head -n 1 | awk '{print $2}' | tr -d ' ')
    
    cp $CONFIG_FILE "${CONFIG_FILE}.bak_lite"

    cat <<EOF > $CONFIG_FILE
listen: :$OLD_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $OLD_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true

outbounds:
  - name: warp_lite
    type: socks5
    socks5:
      addr: 127.0.0.1:40000

acl:
  inline:
    - "outbound(warp_lite) / all"

ignoreClientBandwidth: false
EOF

    systemctl restart hysteria-server
    echo -e "${GREEN}Hysteria 2 已重启并应用分流！${PLAIN}"
fi

echo -e ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}    轻量化 WARP (WireProxy) 部署完成     ${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "通过使用 WireProxy，我们避免了安装官方臃肿的客户端。"
echo -e "内存占用: < 15MB"
echo -e "出口 IP : $(curl -s4 -x socks5://127.0.0.1:40000 ifconfig.me)"
echo -e "----------------------------------------"
