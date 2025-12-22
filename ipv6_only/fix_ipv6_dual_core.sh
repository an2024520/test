#!/bin/bash

# ============================================================
# 脚本名称：fix_ipv6_dual_core.sh (v2.1 DNS Fix)
# 作用：
#   1. [网络] 强制 WARP 使用物理 IPv6 Endpoint
#   2. [启动] 修复 Sing-box 缺失掩码 (/32, /128)
#   3. [适配] 适配 Sing-box 1.12+ 新版 DNS 格式 (移除 port 字段)
#   4. [权限] 修复日志目录权限
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 查找所有可能的配置文件
find_configs() {
    PATHS=(
        "/usr/local/etc/xray/config.json" "/etc/xray/config.json" "/usr/local/etc/xray/xr.json"
        "/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "/usr/local/etc/sing-box/sb.json"
    )
    FOUND_FILES=()
    for p in "${PATHS[@]}"; do
        if [[ -f "$p" ]]; then FOUND_FILES+=("$p"); fi
    done
}

# 2. 执行修复
fix_file() {
    local file="$1"
    local tmp=$(mktemp)
    local is_singbox=0
    
    # 2.1 识别核心类型
    if grep -q "outbounds" "$file" && grep -q "protocol" "$file"; then
        echo -e "${YELLOW}正在修复 Xray 配置: $file${PLAIN}"
        # Xray: 仅修改 Endpoint 为物理 IPv6，并强制 DNS 策略
        jq '
            (.outbounds[]? | select(.protocol == "wireguard" or .tag == "warp-out") | .settings.peers[0].endpoint) |= "[2606:4700:d0::a29f:c001]:2408" |
            .dns = { "servers": [{ "address": "2001:4860:4860::8888", "port": 53 }, "localhost"], "queryStrategy": "UseIPv6", "tag": "dns_inbound" }
        ' "$file" > "$tmp"
        
    elif grep -q "outbounds" "$file" && grep -q "type" "$file"; then
        echo -e "${YELLOW}正在修复 Sing-box 配置: $file${PLAIN}"
        is_singbox=1
        
        # Sing-box 步骤1: 修改 Endpoint 为物理 IPv6
        # 关键修改：DNS 格式适配新版，移除 "port": 53，改为 "address": "2001:4860:4860::8888"
        jq '
            (.outbounds[]? | select(.type == "wireguard" or .tag == "warp-out") | .peers[0].server) |= "2606:4700:d0::a29f:c001" |
            (.outbounds[]? | select(.type == "wireguard" or .tag == "warp-out") | .peers[0].server_port) |= 2408 |
            .dns.servers |= [{ "address": "2001:4860:4860::8888", "strategy": "prefer_ipv6" }]
        ' "$file" > "$tmp"
    fi

    # 2.2 保存 jq 修改结果
    if [[ -s "$tmp" ]]; then 
        mv "$tmp" "$file"
    else 
        rm -f "$tmp"
        echo -e "${RED}JSON 解析/写入失败，跳过文件: $file${PLAIN}"
        return
    fi
    
    # 2.3 Sing-box 掩码暴力补全
    if [[ "$is_singbox" -eq 1 ]]; then
        echo -e "  - 执行掩码补全 (/32, /128)..."
        # 补全 IPv4 /32
        sed -i -E 's/("address": "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"/\1\/32"/g' "$file"
        # 补全 IPv6 /128
        sed -i -E 's/("address": "([0-9a-fA-F]{1,4}:){2,}[0-9a-fA-F]{1,4})"(,?)/\1\/128"\3/g' "$file"
        
        # 修复日志权限
        echo -e "  - 修复日志权限..."
        mkdir -p /var/log/sing-box/ && chmod 777 /var/log/sing-box/
        touch /var/log/sing-box/access.log 2>/dev/null && chmod 666 /var/log/sing-box/access.log 2>/dev/null
    fi
    
    echo -e "${GREEN}修复成功！${PLAIN}"
}

# 3. 主程序
find_configs
if [[ ${#FOUND_FILES[@]} -eq 0 ]]; then echo -e "${RED}未找到配置文件${PLAIN}"; exit 1; fi

for f in "${FOUND_FILES[@]}"; do
    fix_file "$f"
done

# 重启相关服务
systemctl restart xray 2>/dev/null
systemctl restart sing-box 2>/dev/null
echo -e "${GREEN}所有相关服务已尝试重启。请检查运行状态。${PLAIN}"
