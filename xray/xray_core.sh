#!/bin/bash

# ============================================================
#  Xray Core 环境部署脚本 (v9.0 Clean Dependency)
#  - 依赖: 仅负责安装软件依赖和 Xray 核心
#  - 变更: 时间同步已移交主控脚本处理
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [模块一] 开始部署 Xray 核心基础环境...${PLAIN}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# 1. 幂等性检查
XRAY_BIN_PATH="/usr/local/bin/xray_core/xray"
if [[ "$AUTO_SETUP" == "true" ]] && [[ -f "$XRAY_BIN_PATH" ]]; then
    CURRENT_VER=$($XRAY_BIN_PATH version 2>/dev/null | head -n 1 | awk '{print $2}')
    echo -e "${GREEN}>>> [自动模式] Xray Core (${CURRENT_VER}) 已安装，跳过。${PLAIN}"
    # 确保服务已注册
    systemctl enable xray >/dev/null 2>&1
    exit 0
fi

# 2. 软件依赖安装 (保留 Worker 代理所需的工具)
echo -e "${YELLOW}正在安装 Xray 运行依赖...${PLAIN}"
apt update -y
# 注意：移除了 systemd-timesyncd 的重复调用，但保留 curl/wget/ca-certificates
apt install -y curl wget jq openssl unzip ca-certificates

# 时间同步状态展示 (由主控脚本保证)
echo -e "${GREEN}当前系统时间: $(date)${PLAIN}"

# 3. 清理旧环境
echo -e "${YELLOW}正在清理旧版本...${PLAIN}"
systemctl stop xray >/dev/null 2>&1
systemctl disable xray >/dev/null 2>&1
rm -rf /usr/local/bin/xray_core /usr/local/bin/xray /etc/systemd/system/xray.service
systemctl daemon-reload

mkdir -p /usr/local/bin/xray_core
mkdir -p /usr/local/etc/xray
mkdir -p /var/log/xray

# 4. 下载 Xray 核心
ARCH=$(dpkg --print-architecture)
case $ARCH in
    amd64) XRAY_ARCH="64" ;;
    arm64) XRAY_ARCH="arm64-v8a" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac

echo -e "${YELLOW}获取最新版本信息...${PLAIN}"
# PRO Fix: 显式使用 Worker 代理前缀
PROXY_PREFIX="${GH_PROXY_URL:-https://dl.fun777.dpdns.org/}"
API_URL="${PROXY_PREFIX}https://api.github.com/repos/XTLS/Xray-core/releases/latest"

LATEST_VERSION=$(curl -sL -m 10 "$API_URL" | jq -r .tag_name)
if [[ -z "$LATEST_VERSION" ]] || [[ "$LATEST_VERSION" == "null" ]]; then
    # 备用：直连尝试
    echo -e "${RED}代理获取版本失败，尝试直连...${PLAIN}"
    LATEST_VERSION=$(curl -sL -m 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
fi

if [[ -z "$LATEST_VERSION" ]]; then
    echo -e "${RED}严重错误: 无法获取 Xray 版本号。请检查网络。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}版本: ${LATEST_VERSION}${PLAIN}"
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${XRAY_ARCH}.zip"

# 使用 curl 模拟浏览器下载，避开 403 (PRO Fix)
curl -L -k -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0 Safari/537.36" -o /tmp/xray.zip "$DOWNLOAD_URL"

if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败！${PLAIN}"; exit 1
fi

echo -e "${YELLOW}安装中...${PLAIN}"
unzip -o /tmp/xray.zip -d /usr/local/bin/xray_core
rm -f /tmp/xray.zip
chmod +x /usr/local/bin/xray_core/xray

# 5. 配置 Systemd
cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/xray_core/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo -e "${GREEN}Xray 核心安装完成。${PLAIN}"
