#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 检查是否为 Root 用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

echo -e "${YELLOW}========================================${PLAIN}"
echo -e "${YELLOW}       Hysteria 2 一键卸载脚本         ${PLAIN}"
echo -e "${YELLOW}========================================${PLAIN}"
echo -e "此操作将执行以下动作："
echo -e "1. 停止并删除 hysteria-server 服务"
echo -e "2. 删除配置文件和证书 (/etc/hysteria)"
echo -e "3. 删除主程序 (/usr/local/bin/hysteria)"
echo -e "4. 卸载 acme.sh 及相关数据 (/root/.acme.sh)"
echo -e ""
read -p "确定要继续卸载吗？(y/n): " confirm

if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo -e "${GREEN}卸载已取消。${PLAIN}"
    exit 0
fi

echo -e "\n${GREEN}正在停止服务...${PLAIN}"
systemctl stop hysteria-server 2>/dev/null
systemctl disable hysteria-server 2>/dev/null

echo -e "${GREEN}正在删除系统服务文件...${PLAIN}"
rm -f /etc/systemd/system/hysteria-server.service
systemctl daemon-reload

echo -e "${GREEN}正在删除配置文件和证书...${PLAIN}"
rm -rf /etc/hysteria

echo -e "${GREEN}正在删除 Hysteria 二进制文件...${PLAIN}"
rm -f /usr/local/bin/hysteria

echo -e "${GREEN}正在卸载 acme.sh...${PLAIN}"
if [ -f /root/.acme.sh/acme.sh ]; then
    /root/.acme.sh/acme.sh --uninstall 2>/dev/null
fi
rm -rf /root/.acme.sh

echo -e "${GREEN}正在清理残留...${PLAIN}"
# 清理可能存在的安装脚本（可选）
rm -f install_hy2.sh install_hy2_domain.sh

echo -e ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}      Hysteria 2 卸载完成！            ${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "注意：脚本安装的依赖软件 (curl, socat, cron 等) 未被卸载，"
echo -e "因为它们是常用系统工具，保留不会影响系统运行。"
echo -e ""
