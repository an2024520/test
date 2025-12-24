#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [模块一] 开始部署 Xray 核心基础环境...${PLAIN}"

# 1. 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# =================================================
# [新增] 自动化模式 - 幂等性检查
# =================================================
XRAY_BIN_PATH="/usr/local/bin/xray_core/xray"
if [[ "$AUTO_SETUP" == "true" ]] && [[ -f "$XRAY_BIN_PATH" ]]; then
    CURRENT_VER=$($XRAY_BIN_PATH version 2>/dev/null | head -n 1 | awk '{print $2}')
    echo -e "${GREEN}>>> [自动模式] 检测到 Xray Core (${CURRENT_VER}) 已安装，跳过核心部署。${PLAIN}"
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
    exit 0
fi

# 2. 系统环境初始化
echo -e "${YELLOW}正在初始化系统环境 (依赖安装 & 时间同步)...${PLAIN}"
apt update -y
# [修正 1] 加入 ca-certificates 防止 SSL 报错
apt install -y curl wget jq openssl unzip chrony ca-certificates

# 强制同步时间
echo -e "${YELLOW}正在同步系统时间...${PLAIN}"
systemctl enable chrony
systemctl start chrony
chronyc -a makestep
echo -e "${GREEN}当前系统时间: $(date)${PLAIN}"

# 3. 清理旧环境
echo -e "${YELLOW}正在清理旧版本残留...${PLAIN}"
systemctl stop xray >/dev/null 2>&1
systemctl disable xray >/dev/null 2>&1
rm -rf /usr/local/bin/xray_core /usr/local/bin/xray /etc/systemd/system/xray.service
systemctl daemon-reload

# 4. 创建目录
mkdir -p /usr/local/bin/xray_core
mkdir -p /usr/local/etc/xray
mkdir -p /var/log/xray

# 5. 下载并安装 Xray 核心
ARCH=$(dpkg --print-architecture)
case $ARCH in
    amd64) XRAY_ARCH="64" ;;
    arm64) XRAY_ARCH="arm64-v8a" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac

echo -e "${YELLOW}正在获取 GitHub 最新版本信息...${PLAIN}"
# 注意: 这里的 api.github.com 会被 Worker 自动代理，无需手动修改
LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
if [[ -z "$LATEST_VERSION" ]] || [[ "$LATEST_VERSION" == "null" ]]; then
    echo -e "${RED}获取版本失败，请检查网络。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}即将安装版本: ${LATEST_VERSION}${PLAIN}"
DOWNLOAD_URL="https://dl.fun777.dpdns.org/https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${XRAY_ARCH}.zip"

# [修正 2] 加入 --no-check-certificate 解决 Worker 证书信任问题
wget --no-check-certificate -O /tmp/xray.zip "$DOWNLOAD_URL"
if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败！${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}正在解压并安装...${PLAIN}"
unzip -o /tmp/xray.zip -d /usr/local/bin/xray_core
rm -f /tmp/xray.zip
chmod +x /usr/local/bin/xray_core/xray

if [[ -f "/usr/local/bin/xray_core/geoip.dat" ]] && [[ -f "/usr/local/bin/xray_core/geosite.dat" ]]; then
    echo -e "${GREEN}路由规则库 (GeoIP/GeoSite) 安装成功。${PLAIN}"
else
    echo -e "${RED}警告: 压缩包内未找到 Geo 文件。${PLAIN}"
fi

# 6. 配置 Systemd
cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/xray_core/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# 7. 验证安装
VER_INFO=$(/usr/local/bin/xray_core/xray version | head -n 1)
echo -e ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}   Xray 核心 (Core) 安装完成！         ${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "内核版本  : ${YELLOW}${VER_INFO}${PLAIN}"
echo -e "----------------------------------------"
