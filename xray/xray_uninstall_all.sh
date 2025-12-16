#!/bin/bash

# ============================================================
#  模块五 (新增)：Xray 全局一键卸载工具
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 核心路径
CONFIG_DIR="/usr/local/etc/xray"
BIN_DIR="/usr/local/bin/xray_core"
LOG_DIR="/var/log/xray"
SERVICE_FILE="/etc/systemd/system/xray.service"

echo -e "${RED}========================================${PLAIN}"
echo -e "${RED}    警告：Xray 全局卸载工具${PLAIN}"
echo -e "${RED}========================================${PLAIN}"
echo -e "此操作将执行以下删除："
echo -e "  1. 停止并禁用 Xray 服务"
echo -e "  2. 删除 Xray 核心文件 ($BIN_DIR)"
echo -e "  3. 删除 所有配置文件与证书 ($CONFIG_DIR)"
echo -e "  4. 删除 所有日志文件 ($LOG_DIR)"
echo -e "  5. 删除 Systemd 服务配置"
echo -e ""
read -p "你确定要彻底卸载吗？(y/n): " CONFIRM

if [[ "$CONFIRM" != "y" ]]; then
    echo -e "${GREEN}操作已取消。${PLAIN}"
    exit 0
fi

echo -e "${YELLOW}正在停止服务...${PLAIN}"
systemctl stop xray >/dev/null 2>&1
systemctl disable xray >/dev/null 2>&1

echo -e "${YELLOW}正在删除文件...${PLAIN}"
rm -rf "$BIN_DIR"
rm -rf "$CONFIG_DIR"
rm -rf "$LOG_DIR"
rm -f "$SERVICE_FILE"

echo -e "${YELLOW}正在清理系统配置...${PLAIN}"
systemctl daemon-reload

echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}    卸载完成！Xray 已从系统中移除。${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "提示: 如果你安装了 Warp/WireProxy，请单独在对应模块中卸载。"
