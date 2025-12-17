#!/bin/bash

# ==========================================
# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

echo -e "${GREEN}开始运行 Xray 安装脚本...${PLAIN}"

# 1. 安装必要的工具
echo -e "${YELLOW}正在安装 curl 和 wget...${PLAIN}"
apt-get update -y && apt-get install -y curl wget unzip

# 2. 获取或生成 UUID
# 如果之前已经生成过，可以手动填在这里，否则自动生成
UUID=$(cat /proc/sys/kernel/random/uuid)
echo -e "${GREEN}生成的 UUID 是: ${UUID}${PLAIN}"

# 3. 安装 Xray (使用官方一键脚本，如果已安装会自动更新/跳过)
echo -e "${YELLOW}正在下载并安装 Xray 核心...${PLAIN}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 4. 生成 Xray 配置文件 (VLESS + WS)
# 注意：这里监听 8080 端口，Cloudflare 可以在后台设置回源到这个端口
echo -e "${YELLOW}正在写入配置文件 /usr/local/etc/xray/config.json...${PLAIN}"
cat > /usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": 8080,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

# 5. 重启 Xray 服务
echo -e "${YELLOW}正在重启 Xray 服务...${PLAIN}"
systemctl restart xray
systemctl enable xray

# ==========================================
# 核心修改：输出 v2rayN 和 OpenClash 配置格式
# ==========================================

# 定义占位符变量
DOMAIN_PLACEHOLDER="你的CF域名"

echo -e "\n"
echo -e "========================================================"
echo -e "${GREEN} 🎉  安装成功！请复制以下信息配置客户端 ${PLAIN}"
echo -e "========================================================"
echo -e "${RED}注意：请将 '${DOMAIN_PLACEHOLDER}' 替换为你真实绑定的 Cloudflare 域名/优选IP${PLAIN}"

# --- 1. v2rayN 格式 ---
# 构造标准 VLESS 链接
# 格式: vless://uuid@host:443?encryption=none&security=tls&sni=host&type=ws&host=host&path=/#别名
VLESS_LINK="vless://${UUID}@${DOMAIN_PLACEHOLDER}:443?encryption=none&security=tls&sni=${DOMAIN_PLACEHOLDER}&fp=random&type=ws&host=${DOMAIN_PLACEHOLDER}&path=%2F#CF_NODE"

echo -e "\n${YELLOW}👉 [1] v2rayN / V2RayNG 格式 (直接导入剪贴板):${PLAIN}"
echo -e "${GREEN}${VLESS_LINK}${PLAIN}"

# --- 2. OpenClash 格式 ---
echo -e "\n${YELLOW}👉 [2] OpenClash / Clash Meta 格式 (添加到 proxies 下):${PLAIN}"
cat <<EOF
  - name: CF_NODE
    type: vless
    server: ${DOMAIN_PLACEHOLDER}
    port: 443
    uuid: ${UUID}
    cipher: auto
    tls: true
    udp: true
    skip-cert-verify: true
    network: ws
    servername: ${DOMAIN_PLACEHOLDER}
    ws-opts:
      path: "/"
      headers:
        Host: ${DOMAIN_PLACEHOLDER}
EOF

echo -e "\n========================================================"
echo -e "记得在 Cloudflare 后台将 SSL/TLS 设置为 ${YELLOW}Full (Strict)${PLAIN} 或 ${YELLOW}Flexible${PLAIN}"
echo -e "如果连不上，请检查 VPS 防火墙是否放行了 ${YELLOW}8080${PLAIN} 端口"
echo -e "========================================================"
