#!/bin/bash
echo "av3.3 Enhanced"
# ============================================================
#  Sing-box WARP IPv6 优先分流补丁 (v3.3 Enhanced)
#  - 核心原则: 原生IPv6优先 + WARP IPv4兜底
#  - 优化: 注入前自动清理旧规则（支持覆盖安装）
#  - 优化: 服务重启判断更准确
#  - 优化: 策略输入严格校验
#  - 保留: 仅支持 v1.12+ 原生 WARP (endpoints)
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
        if [[ -f "/etc/sing-box/config.json" ]]; then
            CONFIG_FILE="/etc/sing-box/config.json"
        else
            echo -e "${RED}错误: 未找到配置文件 config.json${PLAIN}"
            exit 1
        fi
    fi
    
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}正在安装依赖 jq...${PLAIN}"
        apt-get install -y jq >/dev/null 2>&1 || yum install -y jq >/dev/null 2>&1
    fi

    if ! jq -e '.endpoints[]? | select(.tag == "WARP")' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}错误: 未找到 Tag 为 'WARP' 的 Endpoint。${PLAIN}"
        echo -e "请先运行 WARP 安装脚本添加原生 WARP 节点。"
        exit 1
    fi
}

# 2. 核心逻辑
patch_config() {
    echo -e "${YELLOW}正在读取入站节点列表...${PLAIN}"
    
    # 获取直连出站 Tag
    local direct_tag="direct"
    if ! jq -e '.outbounds[] | select(.tag == "direct")' "$CONFIG_FILE" >/dev/null 2>&1; then
        direct_tag=$(jq -r '.outbounds[] | select(.type == "direct") | .tag' "$CONFIG_FILE" | head -n 1)
        if [[ -z "$direct_tag" ]]; then
            echo -e "${RED}错误: 未找到 Direct 出站。${PLAIN}"
            exit 1
        fi
    fi
    echo -e "${GREEN}检测到直连出站 Tag: ${direct_tag}${PLAIN}"

    local node_list=$(jq -r '.inbounds[] | "\(.tag) | \(.type)"' "$CONFIG_FILE" | nl)
    if [[ -z "$node_list" ]]; then echo -e "${RED}无有效入站节点。${PLAIN}"; exit 1; fi
    
    echo -e "------------------------------------------------"
    echo "$node_list"
    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}请选择要应用策略的节点序号${PLAIN}"
    read -p "输入序号: " selection
    
    local target_tag=$(echo "$node_list" | sed -n "${selection}p" | awk -F'|' '{print $1}' | awk '{print $2}')
    if [[ -z "$target_tag" ]]; then echo -e "${RED}选择无效。${PLAIN}"; exit 1; fi
    
    echo -e "${GREEN}选中节点: ${target_tag}${PLAIN}"

    # 策略选择（带严格校验）
    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}请选择流量转发策略:${PLAIN}"
    echo -e " 1. IPv6走直连 + IPv4走WARP (默认 - 保留原生IPv6性能)"
    echo -e " 2. 双栈全部走WARP (隐藏真实IPv6)"
    read -p "输入选项 (1 或 2，默认1): " strategy_select
    strategy_select=${strategy_select:-1}
    if [[ ! "$strategy_select" =~ ^[12]$ ]]; then
        echo -e "${YELLOW}输入无效，自动使用默认模式 1${PLAIN}"
        strategy_select=1
    fi

    local v6_outbound_target="$direct_tag"
    if [[ "$strategy_select" == "2" ]]; then
        v6_outbound_target="WARP"
        echo -e "${GREEN}已选择: 双栈 WARP 接管模式${PLAIN}"
    else
        echo -e "${GREEN}已选择: IPv6 直连 + IPv4 WARP 兜底模式${PLAIN}"
    fi

    echo -e "${YELLOW}正在备份并应用配置...${PLAIN}"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    local tmp_json=$(mktemp)

    # Step 1: 设置 inbound domain_strategy = prefer_ipv6
    jq --arg t "$target_tag" '
        (.inbounds[] | select(.tag == $t)).domain_strategy = "prefer_ipv6"
    ' "$CONFIG_FILE" > "$tmp_json" && mv "$tmp_json" "$CONFIG_FILE"

    # Step 2: 清理旧的同类全网规则（防止重复）
    jq --arg t "$target_tag" '
        .route.rules |= [ .[] | select(
            .inbound != [$t] or
            (.ip_cidr != ["::/0"] and .ip_cidr != ["0.0.0.0/0"])
        )]
    ' "$CONFIG_FILE" > "$tmp_json" && mv "$tmp_json" "$CONFIG_FILE"

    # Step 3: 构造并置顶注入新规则
    local rule_v6=$(jq -n --arg t "$target_tag" --arg dt "$v6_outbound_target" '{
        "inbound": [$t], "ip_cidr": ["::/0"], "outbound": $dt
    }')
    local rule_v4=$(jq -n --arg t "$target_tag" '{
        "inbound": [$t], "ip_cidr": ["0.0.0.0/0"], "outbound": "WARP"
    }')

    jq --argjson r1 "$rule_v6" --argjson r2 "$rule_v4" '
        .route.rules = [$r1, $r2] + .route.rules
    ' "$CONFIG_FILE" > "$tmp_json" && mv "$tmp_json" "$CONFIG_FILE"

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}配置应用成功！${PLAIN}"
        echo -e "1. 节点 [${target_tag}] DNS 策略已设为: prefer_ipv6"
        echo -e "2. 已清理旧规则并置顶新规则: IPv6→${v6_outbound_target} | IPv4→WARP"
        
        # 重启服务（更准确判断）
        if systemctl restart sing-box; then
            echo -e "${GREEN}Sing-box 服务已成功重启。${PLAIN}"
        else
            echo -e "${YELLOW}Sing-box 重启失败，请手动检查服务状态。${PLAIN}"
        fi

        echo -e "${SKYBLUE}验证方法:${PLAIN}"
        echo -e "  • ip.sb → 应显示 WARP IPv4"
        if [[ "$v6_outbound_target" == "WARP" ]]; then
            echo -e "  • test-ipv6.com → 应显示 WARP IPv6"
        else
            echo -e "  • test-ipv6.com → 应显示 VPS 原生 IPv6"
        fi
    else
        echo -e "${RED}配置失败，已自动回滚。${PLAIN}"
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        rm -f "$tmp_json"
        exit 1
    fi
    rm -f "$tmp_json"
}

check_env
patch_config