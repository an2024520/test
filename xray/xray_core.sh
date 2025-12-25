#!/bin/bash

# ============================================================
#  Xray Core 环境部署脚本 (v9.1 Smart Proxy & UA Fix)
#  - 依赖: 仅安装运行必需的软件依赖
#  - 变更: 时间同步已上移至主控脚本 (menu.sh/auto_deploy.sh)
#  - 修复: 替换 wget 为 curl 并伪装 UA，确保下载链条 100% 稳健
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

# =================================================
# 自动化模式 - 幂等性检查
# =================================================
XRAY_BIN_PATH="/usr/local/bin/xray_core/xray"
if [[ "$AUTO_SETUP" == "true" ]] && [[ -f "$XRAY_BIN_PATH" ]]; then
    CURRENT_VER=$($XRAY_BIN_PATH version 2>/dev/null | head -n 1 | awk '{print $2}')
    echo -e "${GREEN}>>> [自动模式] 检测到 Xray Core (${CURRENT_VER}) 已安装，跳过。${PLAIN}"
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
    exit 0
fi

# 1. 安装软件依赖 (精简版)
echo -e "${YELLOW}正在安装 Xray 运行依赖 (curl, jq, unzip, ca-certificates)...${PLAIN}"
apt update -y >/dev/null 2>&1
# 移除 chrony，完全信赖入口脚本校准的时间
apt install -y curl wget jq openssl unzip ca-certificates

# 验证当前系统时间 (确保入口脚本的时间同步已生效)
echo -e "${GREEN}当前系统时间: $(date)${PLAIN}"

# 2. 清理旧环境
echo -e "${YELLOW}正在清理旧版本残留...${PLAIN}"
systemctl stop xray >/dev/null 2>&1
systemctl disable xray >/dev/null 2>&1
rm -rf /usr/local/bin/xray_core /usr/local/bin/xray /etc/systemd/system/xray.service
systemctl daemon-reload

mkdir -p /usr/local/bin/xray_core
mkdir -p /usr/local/etc/xray
mkdir -p /var/log/xray

# 3. 架构检测
ARCH=$(dpkg --print-architecture)
case $ARCH in
    amd64) XRAY_ARCH="64" ;;
    arm64) XRAY_ARCH="arm64-v8a" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac

# 4. 获取最新版本 (Smart Proxy Logic)
echo -e "${YELLOW}正在获取 GitHub 最新版本信息...${PLAIN}"
TARGET_URL="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
# 如果环境变量中有代理，显式使用以增强独立性
if [[ -n "$GH_PROXY_URL" ]]; then
    API_URL="${GH_PROXY_URL}${TARGET_URL}"
else
    API_URL="${TARGET_URL}"
fi

LATEST_VERSION=$(curl -sL -k -m 10 "$API_URL" | jq -r .tag_name)

# 兜底重试
if [[ -z "$LATEST_VERSION" ]] || [[ "$LATEST_VERSION" == "null" ]]; then
    echo -e "${RED}代理 API 请求异常，尝试直连...${PLAIN}"
    LATEST_VERSION=$(curl -sL -k -m 10 "$TARGET_URL" | jq -r .tag_name)
fi

if [[ -z "$LATEST_VERSION" ]] || [[ "$LATEST_VERSION" == "null" ]]; then
    echo -e "${RED}错误: 无法获取 Xray 版本号，请检查网络。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}即将安装版本: ${LATEST_VERSION}${PLAIN}"
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${XRAY_ARCH}.zip"

if [[ -n "$GH_PROXY_URL" ]]; then
    FULL_DL_URL="${GH_PROXY_URL}${DOWNLOAD_URL}"
else
    FULL_DL_URL="${DOWNLOAD_URL}"
fi

# 5. [核心优化] 统一使用 curl 伪装 UA 下载 (防 403)
echo -e "${YELLOW}正在下载核心文件...${PLAIN}"
curl -L -k -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0 Safari/537.36" -o /tmp/xray.zip "$FULL_DL_URL"

if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败！${PLAIN}"; exit 1
fi

echo -e "${YELLOW}正在解压并安装...${PLAIN}"
unzip -o /tmp/xray.zip -d /usr/local/bin/xray_core
rm -f /tmp/xray.zip
chmod +x /usr/local/bin/xray_core/xray

# 6. 配置 Systemd
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
echo -e "${GREEN}Xray 核心 (v${LATEST_VERSION}) 部署完成。${PLAIN}"
