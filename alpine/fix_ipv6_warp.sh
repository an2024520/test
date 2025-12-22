#!/bin/bash

# ============================================================
# 脚本名称：fix_ipv6_warp.sh (Native 路由专用版)
# 作用：修复纯 IPv6 环境下 Native WARP 连不通的问题
# 适用：由 menu.sh 或 xray_module_warp_native_route.sh 安装的环境
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 自动定位配置文件 (对齐 menu.sh 的搜索顺序)
CONFIG_FILE=""
PATHS=("/usr/local/etc/xray/config.json" "/etc/xray/config.json" "/usr/local/etc/xray/xr.json")
for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then CONFIG_FILE="$p"; break; fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo -e "${RED}错误: 未找到 Xray 配置文件。请确保已通过菜单安装 Xray。${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}正在修复配置文件: ${CONFIG_FILE}${PLAIN}"

# 2. 环境预检
if ! command -v jq &> /dev/null; then
    if [ -f /etc/debian_version ]; then apt update && apt install -y jq; else apk add jq; fi
fi

# 3. 执行“外科手术”级修复
TMP_FILE=$(mktemp)

# 修复逻辑说明：
# A. 强制将所有 wireguard 协议的 endpoint 替换为物理 IPv6 地址
# B. 注入 UseIPv6 策略，强制 Xray 内部 DNS 走物理通道
# C. 确保 DNS 路由规则置顶，防止分流死循环

jq '
    # A. 修复 Endpoint (强制使用 Cloudflare IPv6 节点)
    ( .outbounds[]? | select(.protocol == "wireguard" or .tag == "warp-out") | .settings.peers[0].endpoint ) |= "[2606:4700:d0::a29f:c001]:2408" |

    # B. 优化 DNS 模块
    .dns = {
        "servers": [
            { "address": "2001:4860:4860::8888", "port": 53 },
            { "address": "2606:4700:4700::1111", "port": 53 },
            "localhost"
        ],
        "queryStrategy": "UseIPv6",
        "tag": "dns_inbound"
    } |

    # C. 路由规则修正：确保 DNS 流量直连出口，且优先级最高
    if .routing.rules == null then .routing.rules = [] else . end |
    # 避免重复注入
    if ([.routing.rules[]? | select(.inboundTag != null and (.inboundTag | index("dns_inbound")))] | length) == 0 then
        .routing.rules = [
            {
                "type": "field",
                "inboundTag": ["dns_inbound"],
                "outboundTag": "direct"
            }
        ] + .routing.rules
    else . end
' "$CONFIG_FILE" > "$TMP_FILE"

# 4. 应用变更
if [[ $? -eq 0 && -s "$TMP_FILE" ]]; then
    mv "$TMP_FILE" "$CONFIG_FILE"
    echo -e "${GREEN}✅ IPv6 物理链路优化已应用。${PLAIN}"
    
    # 5. 重启服务 (兼容 systemd 和进程管理)
    echo -e "${YELLOW}正在重启服务以使变更生效...${PLAIN}"
    if systemctl list-unit-files | grep -q xray; then
        systemctl restart xray
    else
        pkill -x xray
        nohup xray run -c "$CONFIG_FILE" >/dev/null 2>&1 &
    fi
    
    sleep 2
    if pgrep -x xray >/dev/null; then
        echo -e "${GREEN}服务已成功重启！${PLAIN}"
        echo -e "${SKYBLUE}测试命令: curl -4 -m 5 ip.gs${PLAIN}"
    else
        echo -e "${RED}重启失败，请检查配置文件格式。${PLAIN}"
    fi
else
    echo -e "${RED}修复失败，JSON 处理异常。${PLAIN}"
    rm -f "$TMP_FILE"
fi
