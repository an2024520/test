#!/bin/bash

# ============================================================
# 脚本名称：sb_camouflage.sh (Self-Healing V2)
# 核心功能：
# 1. 自动识别并修复“文件已移动但缺软链接”的半死状态
# 2. 建立 Symlink 确保 Hy2 证书路径(/usr/local/etc/...)有效
# 3. 修复 Sing-box v1.12+ 的 WorkingDirectory 问题
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# --- 路径定义 ---
STD_BIN="/usr/local/bin/sing-box"
STD_CONF_DIR="/usr/local/etc/sing-box"
STD_CONF_FILE="${STD_CONF_DIR}/config.json"
STD_SERVICE="sing-box"
STD_SERVICE_FILE="/etc/systemd/system/sing-box.service"

HIDE_BIN="/usr/local/bin/sys-service-manager"
HIDE_CONF_DIR="/usr/local/include/sys-helper"
HIDE_CONF_FILE="${HIDE_CONF_DIR}/core.conf"
HIDE_SERVICE="sys-daemon"
HIDE_SERVICE_FILE="/etc/systemd/system/sys-daemon.service"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# ============================================================
# 1. 执行隐藏 (标准 -> 隐身) & 自动修复
# ============================================================
do_hide() {
    # --- 阶段 1: 文件迁移与状态判断 ---
    if [[ ! -f "$STD_BIN" ]] && [[ -f "$HIDE_BIN" ]]; then
        echo -e "${YELLOW}>>> 检测到文件已在隐身位置，进入[故障自愈]模式...${PLAIN}"
        # 这种情况通常是上次隐身一半失败了，或者缺了软链接
    elif [[ -f "$STD_BIN" ]]; then
        echo -e "${YELLOW}>>> 正在执行标准伪装流程...${PLAIN}"
        
        systemctl stop "$STD_SERVICE"
        systemctl disable "$STD_SERVICE"

        echo -e "正在迁移文件路径..."
        mkdir -p "$(dirname "$HIDE_CONF_DIR")"
        
        # 移动核心文件
        mv "$STD_CONF_DIR" "$HIDE_CONF_DIR"
        mv "$STD_BIN" "$HIDE_BIN"
        mv "${HIDE_CONF_DIR}/config.json" "$HIDE_CONF_FILE"
        rm -f "$STD_SERVICE_FILE"
    else
        echo -e "${RED}错误：找不到 Sing-box 二进制文件（标准/隐身位置均无）！${PLAIN}"
        return
    fi

    # --- 阶段 2: 关键修复 (创建传送门) ---
    # 无论刚才是否移动了文件，都要强制检查并创建软链接
    # 这就是修复你报错 "no such file or directory" 的核心
    if [[ ! -L "$STD_CONF_DIR" ]]; then
        echo -e "正在构建路径映射 (Fixing Hy2 Cert Path)..."
        # 如果原来有个空目录挡路，先删掉
        if [[ -d "$STD_CONF_DIR" ]]; then rmdir "$STD_CONF_DIR"; fi
        # 建立链接: /usr/local/etc/sing-box -> /usr/local/include/sys-helper
        ln -s "$HIDE_CONF_DIR" "$STD_CONF_DIR"
    else
        echo -e "路径映射已存在，跳过。"
    fi

    # --- 阶段 3: 重建 Systemd 服务 ---
    echo -e "正在配置守护进程 [sys-daemon]..."
    cat > "$HIDE_SERVICE_FILE" <<EOF
[Unit]
Description=System Daemon Service Manager
After=network.target nss-lookup.target

[Service]
User=root
# 必须指定工作目录，修复 v1.12+ 相对路径报错
WorkingDirectory=${HIDE_CONF_DIR}
ExecStart=${HIDE_BIN} run -c ${HIDE_CONF_FILE}
Restart=always
RestartSec=5s
SyslogIdentifier=sys-daemon
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    # --- 阶段 4: 启动验证 ---
    systemctl daemon-reload
    systemctl enable "$HIDE_SERVICE"
    systemctl restart "$HIDE_SERVICE"

    sleep 2
    if systemctl is-active --quiet "$HIDE_SERVICE"; then
        echo -e "${GREEN}✅ 隐身/修复成功！${PLAIN}"
        echo -e "进程状态: ${GREEN}Active${PLAIN}"
        echo -e "证书映射: ${SKYBLUE}${STD_CONF_DIR} -> ${HIDE_CONF_DIR}${PLAIN}"
    else
        echo -e "${RED}❌ 启动失败，最终日志：${PLAIN}"
        journalctl -u sys-daemon -n 10 --no-pager
    fi
}

# ============================================================
# 2. 执行还原 (隐身 -> 标准)
# ============================================================
do_restore() {
    if [[ -f "$HIDE_BIN" ]]; then
        echo -e "${YELLOW}>>> 正在执行还原流程...${PLAIN}"
        
        systemctl stop "$HIDE_SERVICE"
        systemctl disable "$HIDE_SERVICE"

        echo -e "正在清理映射并还原文件..."
        
        # 1. 删除软链接 (非常重要，否则 mv 会报错或把文件移到链接里)
        if [[ -L "$STD_CONF_DIR" ]]; then
            rm "$STD_CONF_DIR"
            echo -e "已拆除路径映射。"
        fi
        
        # 2. 还原文件
        mkdir -p "$(dirname "$STD_CONF_DIR")"
        mv "$HIDE_BIN" "$STD_BIN"
        mv "$HIDE_CONF_FILE" "${HIDE_CONF_DIR}/config.json"
        mv "$HIDE_CONF_DIR" "$STD_CONF_DIR"
        rm -f "$HIDE_SERVICE_FILE"
        
    elif [[ -f "$STD_BIN" ]]; then
        echo -e "${YELLOW}>>> 检测到文件已在标准位置，仅刷新服务配置...${PLAIN}"
    else
        echo -e "${RED}错误：无法定位程序文件。${PLAIN}"
        return
    fi

    # 重建标准服务
    cat > "$STD_SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
WorkingDirectory=${STD_CONF_DIR}
ExecStart=${STD_BIN} run -c ${STD_CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$STD_SERVICE"
    systemctl restart "$STD_SERVICE"

    sleep 2
    if systemctl is-active --quiet "$STD_SERVICE"; then
        echo -e "${GREEN}✅ 还原成功！${PLAIN}"
    else
        echo -e "${RED}❌ 还原失败。${PLAIN}"
    fi
}

# ============================================================
# 3. 主菜单
# ============================================================
clear
echo -e "#############################################################"
echo -e "#    Sing-box 伪装/修复工具箱 (v2.0 Self-Healing)           #"
echo -e "#############################################################"
echo -e ""
if pgrep -x "sys-service-man" > /dev/null; then
    echo -e "状态：${GREEN} [已隐身] ${PLAIN} (正常运行)"
elif [[ -f "$HIDE_BIN" ]]; then
    echo -e "状态：${RED} [隐身故障] ${PLAIN} (文件已移动，但服务挂了)"
    echo -e "提示：请选择 1 进行自愈修复"
elif pgrep -x "sing-box" > /dev/null; then
    echo -e "状态：${YELLOW} [标准模式] ${PLAIN} (正常运行)"
else
    echo -e "状态：${RED} [未知/停止] ${PLAIN}"
fi
echo -e ""
echo -e "  ${GREEN}1.${PLAIN} 🛡️  开启隐身 / 修复故障 (推荐)"
echo -e "  ${YELLOW}2.${PLAIN} 🔄 还原为标准模式"
echo -e "  ${SKYBLUE}0.${PLAIN} 退出"
echo -e ""
read -p "请选择: " choice

case $choice in
    1) do_hide ;;
    2) do_restore ;;
    0) exit 0 ;;
    *) echo -e "无效选项" ;;
esac
