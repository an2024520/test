#!/bin/bash

# 颜色定义
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
echo -e "${RED}      Hysteria 2 卸载脚本 (内置 ACME 版)         ${PLAIN}"
echo -e "${RED}=================================================${PLAIN}"
echo -e "${YELLOW}警告：此操作将彻底删除 Hysteria 2 程序、配置文件以及申请到的证书。${PLAIN}"
echo -e ""

# 2. 确认卸载
read -p "确认要卸载吗？(输入 y 确认，其他键取消): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo -e "${GREEN}已取消卸载。${PLAIN}"
    exit 0
fi

echo -e "${YELLOW}正在停止 Hysteria 服务...${PLAIN}"
systemctl stop hysteria-server 2>/dev/null
systemctl disable hysteria-server 2>/dev/null

echo -e "${YELLOW}正在清理文件...${PLAIN}"

# 3. 删除服务文件
rm -f /etc/systemd/system/hysteria-server.service
systemctl daemon-reload

# 4. 删除二进制文件
rm -f /usr/local/bin/hysteria

# 5. 删除配置目录 (包含 config.yaml 和 acme/ 证书目录)
rm -rf /etc/hysteria

echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}      Hysteria 2 已成功卸载！          ${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${YELLOW}提示：如果之前为了安装 Hy2 停止了 Nginx/Apache，现在可以手动启动它们了。${PLAIN}"
echo -e "例如: systemctl start nginx"
