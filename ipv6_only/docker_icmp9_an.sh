#!/bin/bash

# ============================================================
#  ICMP9 Docker 全平台一键部署脚本 (兼容 Alpine / Debian / Ubuntu)
# ============================================================

# --- Alpine 系统 Bash 自动引导逻辑 ---
# 如果在 Alpine 下且没有 bash，自动安装并重新运行
if [ -f /etc/alpine-release ] && ! command -v bash >/dev/null 2>&1; then
    echo "⚠️ 检测到 Alpine 系统且未安装 Bash，正在自动安装..."
    apk update && apk add bash
    echo "✅ Bash 安装完成，正在重新启动脚本..."
    exec /bin/bash "$0" "$@"
fi

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 0. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ 错误: 请使用 root 用户运行此脚本。${NC}"
   echo -e "请运行: ${YELLOW}sudo -i${NC} 切换用户后再试。"
   exit 1
fi

# 变量定义
IS_ALPINE=false
if [ -f /etc/alpine-release ]; then
    IS_ALPINE=true
fi

echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}     ICMP9 全平台自动部署脚本 (Auto-Detect)    ${NC}"
echo -e "${GREEN}=============================================${NC}"

if [ "$IS_ALPINE" = true ]; then
    echo -e "${BLUE}🐧 检测到系统: Alpine Linux${NC}"
else
    echo -e "${BLUE}🐧 检测到系统: Debian/Ubuntu/CentOS (Standard Linux)${NC}"
fi

# 1. 环境自动安装与检测
echo -e "${BLUE}🔍 正在检测 Docker 环境...${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}⚠️ 未检测到 Docker，正在根据系统类型自动安装...${NC}"
    
    if [ "$IS_ALPINE" = true ]; then
        # --- Alpine 安装逻辑 ---
        apk update
        apk add docker docker-cli-compose
        rc-update add docker default
        rc-service docker start
    else
        # --- Debian/Ubuntu 安装逻辑 ---
        if ! command -v curl &> /dev/null; then
            apt-get update -y && apt-get install -y curl || yum install -y curl
        fi
        curl -fsSL https://get.docker.com | bash
        systemctl enable --now docker
    fi

    # 二次检查
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}❌ Docker 自动安装失败，请手动安装后重试。${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ Docker 安装成功！${NC}"
else
    echo -e "${GREEN}✅ Docker 已安装${NC}"
fi

# 检测 Docker Compose 命令
COMPOSE_CMD=""
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "${YELLOW}⚠️ 未检测到 Docker Compose，正在补充安装...${NC}"
    if [ "$IS_ALPINE" = true ]; then
        apk add docker-cli-compose
    else
        apt-get update -y && apt-get install -y docker-compose-plugin
    fi
    COMPOSE_CMD="docker compose"
fi

# 2. 创建目录
WORK_DIR="icmp9_docker"
if [ ! -d "$WORK_DIR" ]; then
    mkdir -p "$WORK_DIR"
    echo -e "${GREEN}✅ 创建工作目录: ${WORK_DIR}${NC}"
else
    echo -e "${YELLOW}⚠️ 工作目录 ${WORK_DIR} 已存在，将在该目录下操作。${NC}"
fi

cd "$WORK_DIR" || exit

# 3. 收集用户输入
echo ""
echo -e "${YELLOW}>>> 请输入配置参数 <<<${NC}"

# API KEY
while [[ -z "$API_KEY" ]]; do
    read -p "1. 请输入 ICMP9_API_KEY (必填): " API_KEY
done

# SERVER HOST
while [[ -z "$SERVER_HOST" ]]; do
    read -p "2. 请输入 Cloudflared Tunnel 域名 (SERVER_HOST) (必填): " SERVER_HOST
done

# TOKEN
while [[ -z "$TOKEN" ]]; do
    read -p "3. 请输入 Cloudflare Tunnel Token (必填): " TOKEN
done

# IPv6 ONLY
read -p "4. 是否仅 IPv6 (True/False) [默认: False]: " IPV6_INPUT
IPV6_ONLY=${IPV6_INPUT:-False}

# CDN DOMAIN
read -p "5. 请输入 CDN 优选 IP 或域名 [默认: icook.tw]: " CDN_INPUT
CDN_DOMAIN=${CDN_INPUT:-icook.tw}

# START PORT
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
      - ICMP9_API_KEY=${API_KEY}
      - ICMP9_SERVER_HOST=${SERVER_HOST}
      - ICMP9_CLOUDFLARED_TOKEN=${TOKEN}
      - ICMP9_IPV6_ONLY=${IPV6_ONLY}
      - ICMP9_CDN_DOMAIN=${CDN_DOMAIN}
      - ICMP9_START_PORT=${START_PORT}
    volumes:
      - ./data/subscribe:/root/subscribe
EOF

echo -e "${GREEN}✅ 配置文件已生成！${NC}"

# 5. 启动容器
echo ""
read -p "是否立即启动容器？(y/n) [默认: y]: " START_NOW
START_NOW=${START_NOW:-y}

if [[ "$START_NOW" =~ ^[yY]$ ]]; then
    echo -e "${GREEN}🚀 正在启动容器...${NC}"
    
    $COMPOSE_CMD up -d
    
    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✅ ICMP9 部署成功！${NC}"
        echo -e "系统: ${BLUE}$(if [ "$IS_ALPINE" = true ]; then echo "Alpine"; else echo "Debian/Ubuntu"; fi)${NC}"
        echo -e "工作目录: ${YELLOW}$(pwd)${NC}"
        echo -e "查看日志: ${YELLOW}$COMPOSE_CMD logs -f icmp9${NC}"
    else
        echo -e "${RED}❌ 启动失败，请检查端口占用或 Docker 服务。${NC}"
    fi
else
    echo -e "${YELLOW}已取消启动。${NC}"
fi
