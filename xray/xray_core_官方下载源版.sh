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
# [新增] 自动化模式 - 幂等性检查 (防止重复安装)(v1.1 Auto-Fix)
# =================================================
XRAY_BIN_PATH="/usr/local/bin/xray_core/xray"

# 逻辑：如果是自动模式(AUTO_SETUP=true) 且 二进制文件已存在
if [[ "$AUTO_SETUP" == "true" ]] && [[ -f "$XRAY_BIN_PATH" ]]; then
    # 尝试获取当前版本号 (例如 Xray 1.8.4)
    CURRENT_VER=$($XRAY_BIN_PATH version 2>/dev/null | head -n 1 | awk '{print $2}')
    
    echo -e "${GREEN}>>> [自动模式] 检测到 Xray Core (${CURRENT_VER}) 已安装，跳过核心部署。${PLAIN}"
    
    # 兜底操作：确保 Systemd 配置重载，防止服务未加载
    systemctl daemon-reload
    # 确保服务设置为开机自启
    systemctl enable xray >/dev/null 2>&1
    
    # 核心已就绪，直接退出，保护现有环境不被清理
    exit 0
fi
# =================================================

# 2. 系统环境初始化
echo -e "${YELLOW}正在初始化系统环境 (依赖安装 & 时间同步)...${PLAIN}"
apt update -y
# 安装基础工具 + 时间同步服务(chrony)
apt install -y curl wget jq openssl unzip chrony

# 强制立即同步时间 (Xray 对时间极其敏感，误差不能超过90秒)
echo -e "${YELLOW}正在同步系统时间...${PLAIN}"
systemctl enable chrony
systemctl start chrony
chronyc -a makestep
echo -e "${GREEN}当前系统时间: $(date)${PLAIN}"

# 3. 清理旧环境 (确保纯净)
echo -e "${YELLOW}正在清理旧版本残留...${PLAIN}"
systemctl stop xray >/dev/null 2>&1
systemctl disable xray >/dev/null 2>&1
# 删除旧的二进制和临时文件，保留配置文件目录以免误删数据(虽然现在是全新安装)
rm -rf /usr/local/bin/xray_core /usr/local/bin/xray /etc/systemd/system/xray.service
systemctl daemon-reload

# 4. 创建标准目录结构
# /usr/local/bin/xray_core : 存放二进制文件 (xray, geoip.dat, geosite.dat)
# /usr/local/etc/xray      : 存放配置文件 (config.json)
# /var/log/xray            : 存放日志文件
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
LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
if [[ -z "$LATEST_VERSION" ]] || [[ "$LATEST_VERSION" == "null" ]]; then
    echo -e "${RED}获取版本失败，请检查网络。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}即将安装版本: ${LATEST_VERSION}${PLAIN}"
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${XRAY_ARCH}.zip"

wget -O /tmp/xray.zip "$DOWNLOAD_URL"
if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败！${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}正在解压并安装...${PLAIN}"
# 解压到指定目录
unzip -o /tmp/xray.zip -d /usr/local/bin/xray_core
rm -f /tmp/xray.zip

# 赋予执行权限
chmod +x /usr/local/bin/xray_core/xray

# 检查 Geo 文件 (路由规则库)
if [[ -f "/usr/local/bin/xray_core/geoip.dat" ]] && [[ -f "/usr/local/bin/xray_core/geosite.dat" ]]; then
    echo -e "${GREEN}路由规则库 (GeoIP/GeoSite) 安装成功。${PLAIN}"
else
    echo -e "${RED}警告: 压缩包内未找到 Geo 文件，可能影响后续分流功能。${PLAIN}"
fi

# 6. 配置 Systemd 服务 (通用模板)
# 注意：这里我们配置好服务，但先不启动，因为还没有 config.json
cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target

[Service]
User=root
# 核心启动命令
ExecStart=/usr/local/bin/xray_core/xray run -c /usr/local/etc/xray/config.json
# 崩溃自动重启
Restart=on-failure
RestartSec=5
# 允许绑定低位端口 (如 80, 443)
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# 7. 验证安装
echo -e "${YELLOW}正在验证内核版本...${PLAIN}"
VER_INFO=$(/usr/local/bin/xray_core/xray version | head -n 1)

echo -e ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}   Xray 核心 (Core) 安装完成！         ${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "内核版本  : ${YELLOW}${VER_INFO}${PLAIN}"
echo -e "安装路径  : /usr/local/bin/xray_core"
echo -e "配置路径  : /usr/local/etc/xray/config.json"
echo -e "Systemd   : /etc/systemd/system/xray.service"
echo -e "----------------------------------------"
echo -e "⚠️  注意:"
echo -e "服务 **尚未启动** (Status: Inactive)，因为还没有配置文件。"
echo -e "请继续执行 [模块二] 脚本来添加具体的协议节点配置。"
echo -e ""
