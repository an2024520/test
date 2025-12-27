#!/bin/sh

# 定义颜色
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"

echo -e "${GREEN}=== Sing-box 节点链接生成器 ===${NC}"

# 1. 检查 jq
if ! command -v jq >/dev/null 2>&1; then
    apk add --no-cache jq >/dev/null
fi

# 2. 读取配置
if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误：找不到配置文件 $CONFIG_FILE"
    exit 1
fi

# 提取关键信息
UUID=$(jq -r '.inbounds[0].users[0].uuid' "$CONFIG_FILE")
WSPATH=$(jq -r '.inbounds[0].transport.path' "$CONFIG_FILE")

# 检查是否读取成功
if [ "$UUID" = "null" ] || [ -z "$UUID" ]; then
    echo "错误：无法从配置文件读取 UUID，请检查配置格式。"
    exit 1
fi

# 3. 交互输入域名
echo ""
echo -e "${YELLOW}因为配置文件里不包含你的域名，请手动输入：${NC}"
echo -e "请输入你绑定在 Cloudflare Tunnel 上的域名 (例如 vless.abc.com):"
read -r USER_DOMAIN

if [ -z "$USER_DOMAIN" ]; then
    USER_DOMAIN="你的域名.com"
fi

# 默认优选 IP (新加坡 Visa)
BEST_IP="www.visa.com.sg"

# 4. 生成链接
# VLESS Link 格式
# vless://uuid@host:443?encryption=none&security=tls&sni=host&type=ws&host=host&path=path#alias
VLESS_URL="vless://${UUID}@${BEST_IP}:443?encryption=none&security=tls&sni=${USER_DOMAIN}&type=ws&host=${USER_DOMAIN}&path=${WSPATH}#CF_Tunnel_WARP"

# OpenClash YAML
YAML_CONFIG="  - name: CF_Tunnel_WARP
    type: vless
    server: ${BEST_IP}
    port: 443
    uuid: ${UUID}
    cipher: auto
    tls: true
    udp: true
    skip-cert-verify: true
    network: ws
    servername: ${USER_DOMAIN}
    ws-opts:
      path: \"${WSPATH}\"
      headers:
        Host: ${USER_DOMAIN}"

# 5. 输出结果
echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}           🚀 节点配置信息生成的           ${NC}"
echo -e "${GREEN}==============================================${NC}"

echo -e "${YELLOW}👉 [v2rayN / V2RayNG] 格式 (直接复制导入):${NC}"
echo -e "${CYAN}${VLESS_URL}${NC}"
echo ""

echo -e "${YELLOW}👉 [OpenClash / Meta] 格式 (复制到 proxies 下):${NC}"
echo -e "${CYAN}${YAML_CONFIG}${NC}"

echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "说明："
echo -e "1. 地址(Address)已自动设为优选域名: ${YELLOW}${BEST_IP}${NC}"
echo -e "2. 伪装域名(SNI)已设为你的域名: ${YELLOW}${USER_DOMAIN}${NC}"
echo -e "3. 如果客户端连不上，请确保客户端开启了 [跳过证书验证] (allowInsecure: true)"
echo -e "${GREEN}==============================================${NC}"
