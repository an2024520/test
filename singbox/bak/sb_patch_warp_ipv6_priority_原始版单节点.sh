#!/bin/bash
echo "av3.2"
sleep 5
# ============================================================
#  Sing-box WARP IPv6 优先分流补丁 (v3.2 Auto-Strategy)
#  - 核心功能: 实现 "IPv6优先直连，IPv4兜底WARP" 或 "双栈WARP接管"
#  - 适用版本: Sing-box v1.12+
#  - 自动化: 自动将选中节点的 domain_strategy 修改为 prefer_ipv6
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/sing-box/config.json"
BACKUP_FILE="${CONFIG_FILE}.strategy.bak"

# 1. 基础检查
check_env() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        # 兼容其他安装路径
        if [[ -f "/etc/sing-box/config.json" ]]; then
            CONFIG_FILE="/etc/sing-box/config.json"
        else
            echo -e "${RED}错误: 未找到配置文件 config.json${PLAIN}"
            exit 1
        fi
    fi
    
    # 检查 jq
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}正在安装依赖 jq...${PLAIN}"
        apt-get install -y jq >/dev/null 2>&1 || yum install -y jq >/dev/null 2>&1
    fi

    # 检查 WARP Endpoint 是否存在 (Sing-box v1.12+ 检查 endpoints 字段)
    if ! jq -e '.endpoints[]? | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}错误: 未找到 Tag 为 'WARP' 的 Endpoint。${PLAIN}"
        echo -e "请先运行 WARP 安装脚本添加 Native WARP 节点。"
        exit 1
    fi
}

# 2. 核心逻辑
patch_config() {
    echo -e "${YELLOW}正在读取入站节点列表...${PLAIN}"
    
    # 获取直连出站 Tag (通常是 direct)
    local direct_tag="direct"
    if ! jq -e '.outbounds[] | select(.tag == "direct")' "$CONFIG_FILE" >/dev/null 2>&1; then
        # 尝试寻找类型为 direct 的出站
        direct_tag=$(jq -r '.outbounds[] | select(.type == "direct") | .tag' "$CONFIG_FILE" | head -n 1)
        if [[ -z "$direct_tag" ]]; then
            echo -e "${RED}错误: 未找到 Direct (直连) 出站，无法配置分流。${PLAIN}"
            exit 1
        fi
    fi
    echo -e "${GREEN}检测到直连出站 Tag: ${direct_tag}${PLAIN}"

    # 列出所有入站 (排除 api 等无关项，虽然 sb 通常没有 api 入站但为了保险)
    local node_list=$(jq -r '.inbounds[] | "\(.tag) | \(.type)"' "$CONFIG_FILE" | nl)
    if [[ -z "$node_list" ]]; then echo -e "${RED}配置文件中无有效入站节点。${PLAIN}"; exit 1; fi
    
    echo -e "------------------------------------------------"
    echo "$node_list"
    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}请选择要应用 [IPv6优先+WARP兜底] 策略的节点${PLAIN}"
    echo -e "${YELLOW}注意: 脚本将自动把该节点的 domain_strategy 改为 prefer_ipv6${PLAIN}"
    read -p "输入序号: " selection
    
    local target_tag=$(echo "$node_list" | sed -n "${selection}p" | awk -F'|' '{print $1}' | awk '{print $2}')
    if [[ -z "$target_tag" ]]; then echo -e "${RED}选择无效。${PLAIN}"; exit 1; fi
    
    echo -e "${GREEN}选中节点: ${target_tag}${PLAIN}"

    # ====================================================
    # 新增: 策略选择菜单
    # ====================================================
    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}请选择流量转发策略:${PLAIN}"
    echo -e " 1. IPv6走直连 + IPv4走WARP (默认 - 保留原生IPv6性能)"
    echo -e " 2. 双栈全部走WARP (IPv6优先 - 隐藏真实IP/WARP接管双栈)"
    read -p "输入选项 (默认为1): " strategy_select
    
    local v6_outbound_target="$direct_tag"
    if [[ "$strategy_select" == "2" ]]; then
        v6_outbound_target="WARP"
        echo -e "${GREEN}已选择: 双栈 WARP 接管模式${PLAIN}"
    else
        echo -e "${GREEN}已选择: IPv6 直连模式${PLAIN}"
    fi

    echo -e "${YELLOW}正在备份并注入规则...${PLAIN}"
    
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    
    # ====================================================
    # 步骤 A: 修改 Inbound DNS 策略 (Option B 核心)
    # 强制该节点优先解析 IPv6，否则无法触发 IPv6 路由规则
    # ====================================================
    local tmp_json=$(mktemp)
    jq --arg t "$target_tag" '
        (.inbounds[] | select(.tag == $t)).domain_strategy = "prefer_ipv6"
    ' "$CONFIG_FILE" > "$tmp_json" && mv "$tmp_json" "$CONFIG_FILE"

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}修改入站策略失败，已还原。${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        exit 1
    fi

    # ====================================================
    # 步骤 B: 注入路由规则 (置顶)
    # 1. 目标是 IPv6 (::/0) -> 走 Direct 或 WARP (取决于选择)
    # 2. 目标是 IPv4 (0.0.0.0/0) -> 走 WARP
    # ====================================================
    
    # 规则1: IPv6 -> Target (Direct or WARP)
    local rule_v6=$(jq -n --arg t "$target_tag" --arg dt "$v6_outbound_target" '{ 
        "inbound": [$t], "ip_cidr": ["::/0"], "outbound": $dt 
    }')
    
    # 规则2: IPv4 -> WARP
    local rule_v4=$(jq -n --arg t "$target_tag" '{ 
        "inbound": [$t], "ip_cidr": ["0.0.0.0/0"], "outbound": "WARP" 
    }')
    
    # 插入到 route.rules 的最前面
    jq --argjson r1 "$rule_v6" --argjson r2 "$rule_v4" \
       '.route.rules = [$r1, $r2] + .route.rules' "$CONFIG_FILE" > "$tmp_json" \
       && mv "$tmp_json" "$CONFIG_FILE"
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}配置成功！${PLAIN}"
        echo -e "1. 节点 [${target_tag}] DNS 策略已设为: prefer_ipv6"
        echo -e "2. 路由规则已置顶: [IPv6->${v6_outbound_target}] -> [IPv4->WARP]"
        
        # 重启服务
        if systemctl list-unit-files | grep -q sing-box; then
            systemctl restart sing-box
            echo -e "${GREEN}Sing-box 服务已重启。${PLAIN}"
            echo -e "验证方法: 连接该节点，访问 ip.sb (应显示 IPv4 WARP IP)"
            if [[ "$v6_outbound_target" == "WARP" ]]; then
                echo -e "test-ipv6.com (应显示 WARP IPv6 IP)"
            else
                echo -e "test-ipv6.com (应显示 VPS 原生 IPv6)"
            fi
        else
            echo -e "${YELLOW}未检测到 systemd 服务，请手动重启 Sing-box。${PLAIN}"
        fi
    else
        echo -e "${RED}规则注入失败，已还原配置文件。${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        exit 1
    fi
    rm -f "$tmp_json"
}

check_env
patch_config
