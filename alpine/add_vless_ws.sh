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

# 7. 输出配置信息
echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}       部署完成！请记录以下信息       ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo ""
echo -e "${YELLOW}1. Cloudflare Tunnel 配置 (Public Hostname):${NC}"
echo -e "   - Service Type : ${CYAN}HTTP${NC}"
echo -e "   - URL          : ${CYAN}localhost:$PORT${NC}"
echo -e "   - Public Domain: (你的域名，例如 vless.example.com)"
echo ""
echo -e "${YELLOW}2. 客户端 (V2RayN) 连接信息:${NC}"
echo -e "   - 地址 (address): ${CYAN}(你的 Cloudflare 域名)${NC}"
echo -e "   - 端口 (port)   : ${CYAN}443${NC} (注意是443，不是$PORT)"
echo -e "   - 用户ID (id)   : ${CYAN}$UUID${NC}"
echo -e "   - 传输协议      : ${CYAN}ws${NC}"
echo -e "   - 伪装域名/Host : ${CYAN}(你的 Cloudflare 域名)${NC}"
echo -e "   - 路径 (path)   : ${CYAN}$WSPATH${NC}"
echo -e "   - TLS           : ${CYAN}开启 (tls)${NC}"
echo ""
echo -e "${GREEN}==============================================${NC}"
