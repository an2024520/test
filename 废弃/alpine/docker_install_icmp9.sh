#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}       ICMP9 Docker Compose 一键部署脚本       ${NC}"
echo -e "${GREEN}=============================================${NC}"

# 1. 检查 Docker 环境
if ! command -v docker &> /dev/null; then
    echo -e "${RED}❌ 未检测到 Docker，请先安装 Docker！${NC}"
    echo "Alpine 安装命令: apk add docker docker-cli-compose && rc-service docker start"
    echo "Ubuntu/Debian 安装命令: curl -fsSL https://get.docker.com | bash"
    exit 1
fi

# 2. 创建目录
WORK_DIR="icmp9_docker"
if [ ! -d "$WORK_DIR" ]; then
    mkdir -p "$WORK_DIR"
    echo -e "${GREEN}✅ 创建工作目录: ${WORK_DIR}${NC}"
else
    echo -e "${YELLOW}⚠️ 工作目录 ${WORK_DIR} 已存在，将在该目录下操作。${NC}"
fi

cd "$WORK_DIR"

# 3. 收集用户输入
echo ""
echo -e "${YELLOW}>>> 请输入配置参数 <<<${NC}"

# API KEY (必填)
while [[ -z "$API_KEY" ]]; do
    read -p "1. 请输入 ICMP9_API_KEY (必填): " API_KEY
done

# SERVER HOST (必填)
while [[ -z "$SERVER_HOST" ]]; do
    read -p "2. 请输入 Cloudflared Tunnel 域名 (SERVER_HOST) (必填): " SERVER_HOST
done

# TOKEN (必填)
while [[ -z "$TOKEN" ]]; do
    read -p "3. 请输入 Cloudflare Tunnel Token (必填): " TOKEN
done

# IPv6 ONLY (选填)
read -p "4. 是否仅 IPv6 (True/False) [默认: False]: " IPV6_INPUT
IPV6_ONLY=${IPV6_INPUT:-False}

# CDN DOMAIN (选填)
read -p "5. 请输入 CDN 优选 IP 或域名 [默认: icook.tw]: " CDN_INPUT
CDN_DOMAIN=${CDN_INPUT:-icook.tw}

# START PORT (选填)
read -p "6. 请输入起始端口 [默认: 39001]: " PORT_INPUT
START_PORT=${PORT_INPUT:-39001}

# 4. 生成 docker-compose.yml
echo ""
echo -e "${GREEN}⏳ 正在生成 docker-compose.yml 文件...${NC}"

cat > docker-compose.yml <<EOF
services:
  icmp9:
    image: nap0o/icmp9:latest
    container_name: icmp9
    restart: always
    network_mode: "host"
    environment:
      # [必填] icmp9 提供的 API KEY
      - ICMP9_API_KEY=${API_KEY}
      # [必填] Cloudflared Tunnel 域名
      - ICMP9_SERVER_HOST=${SERVER_HOST}
      # [必填] Cloudflare Tunnel Token
      - ICMP9_CLOUDFLARED_TOKEN=${TOKEN}
      # [选填] 是否仅 IPv6 (True/False)
      - ICMP9_IPV6_ONLY=${IPV6_ONLY}
      # [选填] CDN 优选 IP 或域名
      - ICMP9_CDN_DOMAIN=${CDN_DOMAIN}
      # [选填] 起始端口
      - ICMP9_START_PORT=${START_PORT}
    volumes:
      - ./data/subscribe:/root/subscribe
EOF

echo -e "${GREEN}✅ 配置文件生成完毕！内容如下：${NC}"
echo "------------------------------------------------"
cat docker-compose.yml
echo "------------------------------------------------"

# 5. 启动容器
echo ""
read -p "是否立即启动容器？(y/n) [默认: y]: " START_NOW
START_NOW=${START_NOW:-y}

if [[ "$START_NOW" == "y" || "$START_NOW" == "Y" ]]; then
    echo -e "${GREEN}🚀 正在启动容器...${NC}"
    docker compose up -d
    
    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✅ ICMP9 部署成功！${NC}"
        echo -e "查看日志命令: ${YELLOW}docker logs -f icmp9${NC}"
    else
        echo -e "${RED}❌ 启动失败，请检查 Docker 服务或配置文件。${NC}"
    fi
else
    echo -e "${YELLOW}已取消启动。你可以稍后进入目录 ${WORK_DIR} 运行 'docker compose up -d' 启动。${NC}"
fi
