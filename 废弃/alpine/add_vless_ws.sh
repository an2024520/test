#!/bin/sh

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}=== Cloudflare Tunnel 后端 Xray 部署脚本 (Alpine版) ===${NC}"

# 1. 检查 Root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请使用 root 用户运行此脚本。${NC}"
    exit 1
fi

# 2. 检查 Xray 二进制文件
XRAY_BIN="/usr/local/bin/xray"
if [ ! -f "$XRAY_BIN" ]; then
    echo -e "${RED}未找到 Xray 文件！${NC}"
    echo -e "请确认您已经安装了之前的 icmp9 脚本，或者 Xray 是否位于 /usr/local/bin/xray"
    exit 1
fi

# 3. 获取用户自定义配置
echo ""
echo -e "${YELLOW}--- 配置参数 ---${NC}"

# 设置端口
read -p "请输入本地监听端口 [默认: 10086]: " PORT
PORT=${PORT:-10086}

# 设置 WebSocket 路径
read -p "请输入 WebSocket 路径 [默认: /myway]: " WSPATH
WSPATH=${WSPATH:-/myway}
# 确保路径以 / 开头
case "$WSPATH" in
    /*) ;;
    *) WSPATH="/$WSPATH" ;;
esac

# 生成 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
echo -e "为您生成的随机 UUID: ${CYAN}$UUID${NC}"

# 4. 创建配置目录和文件
CONF_DIR="/etc/xray-server"
CONF_FILE="$CONF_DIR/config.json"

echo -e "${YELLOW}正在创建配置文件...${NC}"
mkdir -p "$CONF_DIR"

cat > "$CONF_FILE" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray-server.access.log",
    "error": "/var/log/xray-server.error.log"
  },
  "inbounds": [
    {
      "port": $PORT,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WSPATH"
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

# 5. 创建 OpenRC 服务脚本
SERVICE_FILE="/etc/init.d/xray-server"
echo -e "${YELLOW}正在创建系统服务...${NC}"

cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="Xray Server"
description="Xray VLESS WebSocket Server for Cloudflare Tunnel"
command="$XRAY_BIN"
command_args="run -c $CONF_FILE"
command_background="yes"
pidfile="/run/xray-server.pid"
output_log="/var/log/xray-server.log"
error_log="/var/log/xray-server.err"

depend() {
    need net
    after firewall
}
EOF

chmod +x "$SERVICE_FILE"

# 6. 启动服务
echo -e "${YELLOW}正在启动服务...${NC}"
if rc-service xray-server restart; then
    rc-update add xray-server default >/dev/null 2>&1
    echo -e "${GREEN}服务启动成功！已设置开机自启。${NC}"
else
    echo -e "${RED}服务启动失败，请检查日志。${NC}"
    exit 1
fi

# 7. 输出配置信息 (已根据要求修改)
DOMAIN_PLACEHOLDER="你的CF域名"
# 这里的端口写死为443，因为 Tunnel 对外通常是 HTTPS 443 端口
VLESS_LINK="vless://${UUID}@${DOMAIN_PLACEHOLDER}:443?encryption=none&security=tls&sni=${DOMAIN_PLACEHOLDER}&type=ws&host=${DOMAIN_PLACEHOLDER}&path=${WSPATH}#CF_Tunnel"

echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}           🚀 节点信息生成完毕           ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo ""

echo -e "${YELLOW}👉 [Cloudflare Tunnel 必填信息]:${NC}"
echo -e "   - Service Type : HTTP"
echo -e "   - URL          : localhost:${PORT}"
echo ""

echo -e "${YELLOW}👉 [v2rayN] 格式 (复制下方链接导入):${NC}"
echo -e "${CYAN}${VLESS_LINK}${NC}"
echo ""

echo -e "${YELLOW}👉 [OpenClash] 格式 (复制到 proxies 下方):${NC}"
cat << EOF
  - name: CF_Tunnel
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
      path: "${WSPATH}"
      headers:
        Host: ${DOMAIN_PLACEHOLDER}
EOF

echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "提示："
echo -e "1. 请在 Cloudflare Tunnel 面板将 ${YELLOW}localhost:${PORT}${NC} 映射到你的域名。"
echo -e "2. 复制上面的配置后，请将 ${RED}'${DOMAIN_PLACEHOLDER}'${NC} 替换为你 Tunnel 绑定的真实域名。"
echo -e "${GREEN}==============================================${NC}"
