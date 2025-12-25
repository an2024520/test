#!/bin/bash

# ============================================================
#  Hysteria 2 官方内核卸载 (全能合并版)
#  - 适用: 无论是自签还是 ACME 安装，均可使用此脚本清理
#  - 逻辑: 停止服务 -> 删除文件 -> 清理配置 -> 提示后续
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

echo -e "${RED}=================================================${PLAIN}"
echo -e "${RED}         Hysteria 2 卸载向导 (官方内核)          ${PLAIN}"
echo -e "${RED}=================================================${PLAIN}"
echo -e "${YELLOW}警告：此操作将执行以下清理：${PLAIN}"
echo -e "1. 停止并删除 hysteria-server 系统服务"
echo -e "2. 删除核心二进制文件 (/usr/local/bin/hysteria)"
echo -e "3. 删除所有配置文件和证书 (/etc/hysteria)"
echo -e ""

# 2. 确认卸载
read -p "确认要执行卸载吗？(输入 y 确认): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo -e "${GREEN}已取消操作。${PLAIN}"
    exit 0
fi

echo -e "${YELLOW}正在停止 Hysteria 服务...${PLAIN}"
# 尝试停止服务，忽略错误
systemctl stop hysteria-server 2>/dev/null
systemctl disable hysteria-server 2>/dev/null

echo -e "${YELLOW}正在清理文件系统...${PLAIN}"

# 3. 删除服务文件
rm -f /etc/systemd/system/hysteria-server.service
systemctl daemon-reload
systemctl reset-failed

# 4. 删除二进制文件
rm -f /usr/local/bin/hysteria

# 5. 删除配置目录 (无论里面是自签证书还是ACME数据，一并清空)
rm -rf /etc/hysteria

echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}      Hysteria 2 已成功卸载！          ${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${YELLOW}后续建议:${PLAIN}"
echo -e "1. 如果您曾为申请证书停止了 Nginx/Apache，请记得手动启动它们。"
echo -e "   (指令: systemctl start nginx 或 systemctl start apache2)"
echo -e "2. 如果您手动添加了防火墙规则 (如 iptables/ufw)，请按需清理。"
echo -e ""
