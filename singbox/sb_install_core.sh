#!/bin/bash

# ============================================================
#  Sing-box 核心安装/重置脚本 (Universal)
#  - 功能: 下载最新内核 / 配置 Systemd / 初始化配置
#  - 架构: 自动适配 AMD64 / ARM64
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 核心路径定义 (遵循 Xray 脚本的目录规范)
BIN_PATH="/usr/local/bin/sing-box"
CONF_DIR="/usr/local/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"
LOG_DIR="/var/log/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

# 1. 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

echo -e "${GREEN}>>> 开始安装/重置 Sing-box 核心环境...${PLAIN}"

# 2. 检查系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        DOWNLOAD_ARCH="amd64"
        ;;
    aarch64)
        DOWNLOAD_ARCH="arm64"
        ;;
    *)
        echo -e "${RED}不支持的架构: $ARCH${PLAIN}"
        exit 1
        ;;
esac
echo -e "检测到架构: ${SKYBLUE}$ARCH${PLAIN} -> 下载目标: ${SKYBLUE}$DOWNLOAD_ARCH${PLAIN}"

# 3. 获取最新版本 (GitHub API)
echo -e "${YELLOW}正在获取最新 Release 版本信息...${PLAIN}"
LATEST_VERSION=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [[ -z "$LATEST_VERSION" ]]; then
    echo -e "${RED}错误: 无法获取 Sing-box 版本信息，请检查网络连接。${PLAIN}"
    exit 1
fi

# 去除 v 前缀用于文件名拼接 (例如 v1.8.0 -> 1.8.0)
VERSION_NUM=${LATEST_VERSION#v}
echo -e "最新版本: ${GREEN}$LATEST_VERSION${PLAIN}"

# 4. 下载并解压
TMP_DIR=$(mktemp -d)
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${VERSION_NUM}-linux-${DOWNLOAD_ARCH}.tar.gz"
FILENAME="sing-box.tar.gz"

echo -e "${YELLOW}正在下载核心文件...${PLAIN}"
wget -O "${TMP_DIR}/${FILENAME}" "$DOWNLOAD_URL"

if [[ $? -ne 0 ]]; then
    echo -e "${RED}下载失败！请检查网络或 GitHub 访问情况。${PLAIN}"
    rm -rf "$TMP_DIR"
    exit 1
fi

echo -e "正在解压..."
tar -xzf "${TMP_DIR}/${FILENAME}" -C "$TMP_DIR"

# 移动二进制文件 (解压后的目录名通常包含版本号)
EXTRACTED_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "sing-box*")
if [[ -f "${EXTRACTED_DIR}/sing-box" ]]; then
    # 停止旧服务
    systemctl stop sing-box 2>/dev/null
    
    mv "${EXTRACTED_DIR}/sing-box" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    echo -e "${GREEN}核心文件已安装至: $BIN_PATH${PLAIN}"
else
    echo -e "${RED}解压异常，未找到二进制文件！${PLAIN}"
    rm -rf "$TMP_DIR"
    exit 1
fi

rm -rf "$TMP_DIR"

# 5. 初始化配置环境
mkdir -p "$CONF_DIR"
mkdir -p "$LOG_DIR"
touch "${LOG_DIR}/access.log"
touch "${LOG_DIR}/error.log"
chown -R nobody:nogroup "$LOG_DIR" 2>/dev/null || chown -R nobody:nobody "$LOG_DIR"

# 生成基础 config.json (如果不存在)
# 这里生成一个"最小可用配置"，包含日志和一个 Direct 出站，防止启动报错
if [[ ! -f "$CONF_FILE" ]]; then
    echo -e "${YELLOW}未检测到配置文件，正在生成默认配置...${PLAIN}"
    cat > "$CONF_FILE" <<EOF
{
  "log": {
    "level": "info",
    "output": "${LOG_DIR}/access.log",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": []
  }
}
EOF
    echo -e "${GREEN}默认配置已生成。${PLAIN}"
else
    echo -e "${YELLOW}检测到现有配置文件，跳过覆盖。${PLAIN}"
fi

# 6. 配置 Systemd 服务
echo -e "${YELLOW}正在配置 Systemd 服务...${PLAIN}"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${BIN_PATH} run -c ${CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

# 7. 启动服务
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box

echo -e "----------------------------------------------------"
if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}Sing-box 安装并启动成功！${PLAIN} [v${VERSION_NUM}]"
    echo -e "配置文件: ${SKYBLUE}$CONF_FILE${PLAIN}"
    echo -e "日志目录: ${SKYBLUE}$LOG_DIR${PLAIN}"
else
    echo -e "${RED}服务启动失败！请检查日志：journalctl -u sing-box -e${PLAIN}"
fi
echo -e "----------------------------------------------------"
