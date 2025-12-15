#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/hysteria/config.yaml"

echo -e "${GREEN}>>> 步骤 2/2: 修改 Hysteria 2 配置文件...${PLAIN}"

# 1. 检查文件是否存在
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 找不到 $CONFIG_FILE，请先安装 Hysteria 2。${PLAIN}"
    exit 1
fi

# 2. 检查是否已经修改过 (防止重复追加)
if grep -q "warp_lite" "$CONFIG_FILE"; then
    echo -e "${RED}检测到配置文件中已存在 warp_lite 相关设置，跳过修改。${PLAIN}"
    echo -e "如果想重新配置，请手动编辑或还原 config.yaml。"
    exit 0
fi

# 3. 备份原配置
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
echo -e "${YELLOW}已备份原配置到 ${CONFIG_FILE}.bak${PLAIN}"

# 4. 追加配置 (Append)
# 注意：我们在追加前先 echo 一个空行，确保不会接在最后一行文字屁股后面
echo "" >> "$CONFIG_FILE"

cat <<EOF >> "$CONFIG_FILE"
# --- WARP 分流配置 (追加) ---
outbounds:
  - name: warp_lite
    type: socks5
    socks5:
      addr: 127.0.0.1:40000

acl:
  inline:
    - warp_lite(all)
EOF

echo -e "${GREEN}配置已追加成功！${PLAIN}"

# 5. 重启服务
echo -e "${YELLOW}正在重启 Hysteria 2 服务...${PLAIN}"
systemctl restart hysteria-server

# 6. 验证状态
if systemctl is-active --quiet hysteria-server; then
    echo -e "${GREEN}Hysteria 2 重启成功！现在流量已通过 WARP 转发。${PLAIN}"
else
    echo -e "${RED}Hysteria 2 启动失败！${PLAIN}"
    echo -e "请使用 'systemctl status hysteria-server' 查看日志。"
    echo -e "你可以通过 'cp ${CONFIG_FILE}.bak ${CONFIG_FILE}' 还原配置。"
fi
