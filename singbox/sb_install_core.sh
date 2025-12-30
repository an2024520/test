#!/bin/bash

# ============================================================
#  Sing-box 核心安装/重置脚本 (Universal + Auto)
#  - 功能: 下载最新内核 / 配置 Systemd / 初始化配置
#  - 架构: 自动适配 AMD64 / ARM64
#  - 特性: 兼容 Commander 自动化防重复判断
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 1. 检查 root 权限 (移至最前，确保安全)
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

# 核心路径定义 (遵循 Xray 脚本的目录规范)
BIN_PATH="/usr/local/bin/sing-box"
CONF_DIR="/usr/local/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"
LOG_DIR="/var/log/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

# =================================================
# [新增] 自动化模式 - 幂等性检查 (优化版)
# =================================================
# 逻辑：在自动模式下，如果核心文件已存在且可运行，跳过安装
if [[ "$AUTO_SETUP" == "true" ]] && [[ -f "$BIN_PATH" ]]; then
    # 尝试获取版本
    CURRENT_VER=$($BIN_PATH version 2>/dev/null | grep -oP 'sing-box version \K[0-9.]+' | head -n 1)
    if [[ -n "$CURRENT_VER" ]]; then
         echo -e "${GREEN}>>> [自动模式] 检测到 Sing-box (${CURRENT_VER}) 已安装，跳过核心部署。${PLAIN}"
         systemctl daemon-reload
         systemctl enable sing-box >/dev/null 2>&1
         exit 0
    fi
fi

# =================================================
# 2. 系统环境初始化 (依赖 & 时间同步)
# =================================================
echo -e "${YELLOW}正在初始化系统环境...${PLAIN}"

# [新增] 虚拟化环境检测 (适配 LXC/OpenVZ/Podman 等容器)
VIRT_TYPE=$(systemd-detect-virt 2>/dev/null)
echo -e "${YELLOW}检测到虚拟化环境: ${VIRT_TYPE}${PLAIN}"

# [关键修正] 时间校准逻辑 (全环境通用版 - 移植自 Xray 脚本)
echo -e "${YELLOW}正在校准系统时间...${PLAIN}"

# 1. 无论什么环境，先设置时区 (纠正显示偏移)
timedatectl set-timezone Asia/Shanghai

# 2. 根据环境决定是否强制同步
if [[ "$VIRT_TYPE" == "lxc" || "$VIRT_TYPE" == "openvz" || "$VIRT_TYPE" == "docker" || "$VIRT_TYPE" == "podman" || "$VIRT_TYPE" == "wsl" ]]; then
    echo -e "${SKYBLUE}>>> 容器环境 ($VIRT_TYPE) 无法直接控制内核时钟，跳过主动同步。${PLAIN}"
    echo -e "${SKYBLUE}>>> 已依赖宿主机时间。若时间误差过大，请联系 VPS 商家。${PLAIN}"
else
    # KVM / VMWare / 物理机 -> 强制执行原生同步
    echo -e "${GREEN}>>> 独立内核环境，正在强制重置 systemd-timesyncd...${PLAIN}"
    
    # 确保 systemd-timesyncd 存在 (防止精简版系统缺失)
    if ! command -v /lib/systemd/systemd-timesyncd >/dev/null 2>&1; then
        apt update -y && apt install -y systemd-timesyncd >/dev/null 2>&1
    fi

    timedatectl set-ntp false
    # 清理冲突 (移除 chrony/ntp 避免死锁)
    if systemctl is-active --quiet chrony; then systemctl stop chrony; systemctl disable chrony; fi
    
    # 重启服务并等待
    systemctl restart systemd-timesyncd
    timedatectl set-ntp true
    sleep 2
fi

# 显示最终时间供确认
echo -e "${GREEN}当前系统时间: $(date)${PLAIN}"

# [修正后] 只有时间没问题了，才运行 apt update
apt update -y
# 安装基础依赖 (Sing-box 不需要 unzip，但需要 tar)
apt install -y curl wget tar openssl

# 3. 创建目录结构
mkdir -p "$CONF_DIR"
mkdir -p "$LOG_DIR"
# 清理旧二进制 (如果存在)
rm -f "$BIN_PATH"

# 4. 架构判断与下载
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64) SB_ARCH="amd64" ;;
    arm64) SB_ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac

echo -e "${YELLOW}正在获取 Sing-box 核心...${PLAIN}"

# [修改] 切换为固定版本源 (Fixed Version Source)
# API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
# LATEST_VERSION=$(curl -s "$API_URL" | grep '"tag_name":' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
# if [[ -z "$LATEST_VERSION" ]]; then
#     echo -e "${RED}获取最新版本失败，请检查网络连接。${PLAIN}"
#     exit 1
# fi
LATEST_VERSION="Fixed-Repo-Version"

echo -e "${GREEN}即将安装版本: ${LATEST_VERSION}${PLAIN}"
# DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${SB_ARCH}.tar.gz"

# [修改] 使用用户自定义仓库源 (注意: 文件名已简化为 sing-box-linux-arch.tar.gz)
DOWNLOAD_URL="https://raw.githubusercontent.com/an2024520/mysh2026/refs/heads/main/singbox/sing-box-linux-${SB_ARCH}.tar.gz"

echo -e "${YELLOW}下载链接: $DOWNLOAD_URL${PLAIN}"

# 创建临时目录
TMP_DIR=$(mktemp -d)
wget -O "${TMP_DIR}/sing-box.tar.gz" "$DOWNLOAD_URL"

if [[ $? -ne 0 ]]; then
    echo -e "${RED}下载失败！${PLAIN}"
    rm -rf "$TMP_DIR"
    exit 1
fi

echo -e "${YELLOW}正在解压并安装...${PLAIN}"
# 解压 (由于文件名结构可能变化，我们直接解压并查找二进制文件)
tar -zxf "${TMP_DIR}/sing-box.tar.gz" -C "$TMP_DIR"

# 查找解压后的二进制文件 (find 兼容任意目录结构)
SB_BIN_FIND=$(find "$TMP_DIR" -type f -name "sing-box" | head -n 1)

if [[ -n "$SB_BIN_FIND" ]]; then
    mv "$SB_BIN_FIND" "$BIN_PATH"
    chmod +x "$BIN_PATH"
else
    echo -e "${RED}错误: 解压后未找到 sing-box 二进制文件！${PLAIN}"
    ls -R "$TMP_DIR"
    rm -rf "$TMP_DIR"
    exit 1
fi

# 清理临时文件
rm -rf "$TMP_DIR"

# 验证安装
if ! "$BIN_PATH" version >/dev/null 2>&1; then
    echo -e "${RED}安装失败: 二进制文件无法运行。${PLAIN}"
    exit 1
fi

# 5. 初始化配置 (仅当不存在时生成)
if [[ ! -f "$CONF_FILE" ]]; then
    echo -e "${YELLOW}检测到配置文件缺失，正在生成默认配置...${PLAIN}"
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

systemctl daemon-reload

# 7. 结束输出
VER_INFO=$("$BIN_PATH" version | head -n 1)
echo -e ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}   Sing-box 核心安装完成！             ${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "内核版本  : ${YELLOW}${VER_INFO}${PLAIN}"
echo -e "安装路径  : ${BIN_PATH}"
echo -e "配置路径  : ${CONF_FILE}"
echo -e "Systemd   : ${SERVICE_FILE}"
echo -e "----------------------------------------"
echo -e "⚠️  注意:"
echo -e "服务 **尚未启动** (Status: Inactive)。"
echo -e "请继续添加具体的协议节点配置。"
echo -e ""