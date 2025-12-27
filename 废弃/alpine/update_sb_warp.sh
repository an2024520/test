#!/bin/sh

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
BACKUP_FILE="/etc/sing-box/config.json.bak.$(date +%s)"

echo -e "${GREEN}=== Sing-box 路由修改工具 (对接 WireProxy) ===${NC}"

# 1. 检查必要工具
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YELLOW}正在安装 jq (用于处理 JSON)...${NC}"
    apk add --no-cache jq
fi

# 2. 检查配置文件
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}未找到配置文件: $CONFIG_FILE${NC}"
    exit 1
fi

# 3. 备份
echo -e "${YELLOW}正在备份原配置...${NC}"
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo -e "备份已保存至: $BACKUP_FILE"

# 4. 生成新的 JSON 配置 (使用 jq 注入)
# 逻辑：保留 inbounds 和 log，重写 outbounds 和 route
echo -e "${YELLOW}正在修改配置以使用 SOCKS5 (127.0.0.1:40000)...${NC}"

# 创建临时文件
TMP_JSON="/tmp/sb_new.json"

jq '
  .outbounds = [
    {
      "type": "socks",
      "tag": "warp-out",
      "server": "127.0.0.1",
      "server_port": 40000
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ] |
  .route = {
    "rules": [
      {
        "inbound": "vless-in",
        "outbound": "warp-out"
      }
    ]
  }
' "$CONFIG_FILE" > "$TMP_JSON"

# 5. 验证并应用
if [ -s "$TMP_JSON" ]; then
    # 简单的 JSON 校验
    if jq empty "$TMP_JSON" >/dev/null 2>&1; then
        mv "$TMP_JSON" "$CONFIG_FILE"
        echo -e "${GREEN}配置文件修改成功！${NC}"
        
        echo -e "${YELLOW}正在重启 Sing-box 服务...${NC}"
        if rc-service sing-box restart; then
            echo -e "${GREEN}✅ 服务重启成功！现在流量已通过 WARP 出口。${NC}"
            echo -e "你的 IPv6 小鸡现在可以访问 GitHub/IPv4 网络了。"
        else
            echo -e "${RED}服务重启失败，请检查日志。${NC}"
            echo -e "恢复备份命令: cp $BACKUP_FILE $CONFIG_FILE && rc-service sing-box restart"
        fi
    else
        echo -e "${RED}生成的 JSON 格式错误，未应用更改。${NC}"
    fi
else
    echo -e "${RED}生成新配置失败。${NC}"
fi
