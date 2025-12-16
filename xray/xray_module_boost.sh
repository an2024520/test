#!/bin/bash

# ============================================================
#  模块五：系统内核加速 (BBR + ECN + 调优)
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}>>> [模块五] 开始进行系统内核网络优化...${PLAIN}"

# 1. 检查是否具有 root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# 2. 开启 BBR 和 ECN (写入 /etc/sysctl.conf)
# -----------------------------------------------------------
echo -e "${YELLOW}正在配置 BBR 拥塞控制与 ECN...${PLAIN}"

# 备份原配置
if [ ! -f /etc/sysctl.conf.bak ]; then
    cp /etc/sysctl.conf /etc/sysctl.conf.bak
    echo -e "已备份原配置到 /etc/sysctl.conf.bak"
fi

# 定义我们需要添加的参数
# net.core.default_qdisc = fq (BBR 依赖的队列算法)
# net.ipv4.tcp_congestion_control = bbr (开启 BBR)
# net.ipv4.tcp_ecn = 1 (开启 ECN，这就是你想要的！)
# net.ipv4.tcp_window_scaling = 1 (开启窗口扩大因子)

# 使用 sed 删除旧的重复项，防止配置冲突
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_ecn/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_window_scaling/d' /etc/sysctl.conf

# 追加新配置
cat <<EOF >> /etc/sysctl.conf

# === Xray Module 5 Optimization ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_window_scaling = 1
# ==================================
EOF

# 应用更改
sysctl -p > /dev/null 2>&1

# 3. 验证 BBR 是否开启成功
# -----------------------------------------------------------
BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
if [[ "$BBR_STATUS" == "bbr" ]]; then
    echo -e "${GREEN}BBR 加速: [已开启]${PLAIN}"
else
    echo -e "${RED}BBR 开启失败，当前状态: $BBR_STATUS ${PLAIN}"
    # 注意: 部分 OpenVZ 架构的 VPS 无法开启 BBR，如果是 KVM 架构通常没问题
fi

# 4. 验证 ECN 是否开启成功
# -----------------------------------------------------------
ECN_STATUS=$(sysctl net.ipv4.tcp_ecn | awk '{print $3}')
if [[ "$ECN_STATUS" == "1" ]]; then
    echo -e "${GREEN}ECN 功能: [已开启]${PLAIN}"
else
    echo -e "${RED}ECN 开启失败。${PLAIN}"
fi

# 5. 优化文件打开数限制 (ulimit)
# -----------------------------------------------------------
echo -e "${YELLOW}正在优化最大连接数限制...${PLAIN}"

# 在 /etc/security/limits.conf 中添加配置
if ! grep -q "soft nofile 65535" /etc/security/limits.conf; then
    cat <<EOF >> /etc/security/limits.conf
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
    echo -e "${GREEN}最大文件句柄数已提升至 65535。${PLAIN}"
else
    echo -e "最大文件句柄数已优化，跳过。"
fi

echo -e ""
echo -e "${GREEN}========================================${PLAIN}"
echo -e "${GREEN}    [模块五] 系统加速优化完成！        ${PLAIN}"
echo -e "${GREEN}========================================${PLAIN}"
echo -e "现在你的所有节点（XHTTP / Vision）都已获得:"
echo -e "1. ${YELLOW}BBR${PLAIN} (抗丢包，速度更快)"
echo -e "2. ${YELLOW}ECN${PLAIN} (更聪明的防拥塞机制)"
echo -e "----------------------------------------"
echo -e "💡 提示: 无需重启服务器，配置已立即生效。"
