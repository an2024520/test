#!/bin/bash

# ============================================================
#  Native WARP 增强模块 (Clean & Pure Edition)
#  - 无需 Wireproxy，由 Xray 内核直接连接 Cloudflare
#  - 纯净模式：移除所有硬编码共享 IP，确保独享与安全
# ============================================================

# --- 1. 全局配置 (与 xray_core.sh 严格配套) ---
XRAY_CONFIG="/usr/local/etc/xray/config.json"
WARP_CONF_FILE="/etc/my_script/warp_native.conf"
mkdir -p "$(dirname "$WARP_CONF_FILE")"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
GRAY='\033[0;37m'

# --- 2. 依赖检查 ---
check_dependencies() {
    # jq 是修改 config.json 的核心工具，xray_core.sh 通常已安装
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${YELLOW}正在安装 jq (JSON处理工具)...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y jq
        elif [ -f /etc/redhat-release ]; then
            yum install -y jq
        fi
    fi
    # python3 用于计算 Reserved 值
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${YELLOW}正在安装 Python3...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y python3
        elif [ -f /etc/redhat-release ]; then
            yum install -y python3
        fi
    fi
}

# --- 3. 核心功能：获取 WARP 凭证 ---
get_warp_credentials() {
    check_dependencies
    clear
    echo -e "${GREEN}================ Native WARP 凭证配置 ================${PLAIN}"
    echo -e "Native 模式需要 WARP 账户的三要素：Private Key, IPv6 Address, Reserved"
    echo -e "----------------------------------------------------"
    echo -e " 1. 自动注册 (推荐: 使用 wgcf 生成独享账号)"
    echo -e " 2. 手动输入 (已有账号，需填入完整信息)"
    echo -e "----------------------------------------------------"
    read -p "请选择: " choice

    local wp_key=""
    local wp_ip=""
    local wp_res=""

    if [ "$choice" == "1" ]; then
        echo -e "${YELLOW}正在准备 wgcf 环境...${PLAIN}"
        
        local arch=$(uname -m)
        local wgcf_arch="amd64"
        case "$arch" in
            aarch64) wgcf_arch="arm64" ;;
            x86_64) wgcf_arch="amd64" ;;
            *) echo "不支持的架构: $arch"; return 1 ;;
        esac

        local tmp_dir=$(mktemp -d)
        pushd "$tmp_dir" >/dev/null || return

        # 下载官方 wgcf (安全可靠)
        wget -qO wgcf "https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${wgcf_arch}"
        chmod +x wgcf
        
        echo "正在向 Cloudflare 注册新账户..."
        ./wgcf register --accept-tos >/dev/null 2>&1
        ./wgcf generate >/dev/null 2>&1

        if [ ! -f wgcf-profile.conf ]; then
            echo -e "${RED}错误：注册失败。Cloudflare 可能限制了本机 IP 注册。${PLAIN}"
            echo -e "${YELLOW}建议：在本地电脑运行 wgcf 注册好后，使用【手动输入】模式填入。${PLAIN}"
            popd >/dev/null; rm -rf "$tmp_dir"; read -p "按回车退出..."; return 1
        fi

        # 提取 PrivateKey
        wp_key=$(grep 'PrivateKey' wgcf-profile.conf | cut -d ' ' -f 3 | tr -d '\n\r ')
        
        # 提取 Address (自动获取 Cloudflare 分配给你的唯一 v6 地址)
        local raw_addr=$(grep 'Address' wgcf-profile.conf | cut -d '=' -f 2 | tr -d ' ')
        if [[ "$raw_addr" == *","* ]]; then
            wp_ip=$(echo "$raw_addr" | awk -F',' '{print $2}' | cut -d'/' -f1 | tr -d '\n\r ')
        else
            wp_ip=$(echo "$raw_addr" | cut -d'/' -f1 | tr -d '\n\r ')
        fi

        # 提取 Reserved (Python 算法)
        local client_id=$(grep "client_id" wgcf-account.toml | cut -d '"' -f 2)
        if [ -n "$client_id" ]; then
            wp_res=$(python3 -c "import base64; d=base64.b64decode('${client_id}'); print(f'[{d[0]}, {d[1]}, {d[2]}]')")
        else
            wp_res="[0, 0, 0]"
        fi

        echo -e "${GREEN}注册成功！已获取独享账号。${PLAIN}"
        echo "Private Key: $wp_key"
        echo "IPv6 Addr:   $wp_ip"
        echo "Reserved:    $wp_res"
        
        popd >/dev/null
        rm -rf "$tmp_dir"

    elif [ "$choice" == "2" ]; then
        echo -e "${YELLOW}请输入 Private Key (私钥):${PLAIN}"
        read -r wp_key
        
        echo -e "${YELLOW}请输入 WARP IPv6 地址 (不带 /128):${PLAIN}"
        echo -e "(例如: 2606:4700:110:xxxx:xxxx:xxxx:xxxx:xxxx)"
        read -r wp_ip
        
        echo -e "${YELLOW}请输入 Reserved 值 (格式如 [123, 45, 67]):${PLAIN}"
        echo -e "(提示: 如果不知道，可尝试填 [0, 0, 0])"
        read -r wp_res
        
        if [ -z "$wp_key" ] || [ -z "$wp_ip" ]; then
            echo -e "${RED}错误：私钥和 IP 不能为空！${PLAIN}"
            return 1
        fi
    else
        return 1
    fi

    # 保存凭证
    cat > "$WARP_CONF_FILE" <<EOF
WP_KEY="$wp_key"
WP_IP="$wp_ip"
WP_RES="$wp_res"
EOF
    echo -e "${GREEN}凭证已保存至 $WARP_CONF_FILE${PLAIN}"
    read -p "按回车键继续..."
}

# --- 4. 核心功能：生成 Outbound JSON ---
generate_warp_outbound() {
    if [ ! -f "$WARP_CONF_FILE" ]; then return 1; fi
    source "$WARP_CONF_FILE"

    # 172.16.0.2 是 WARP 接口的标准内网 IPv4，这是协议固定值，无需修改
    local addr_json="\"172.16.0.2/32\", \"${WP_IP}/128\""

    cat <<EOF
{
  "tag": "warp-out",
  "protocol": "wireguard",
  "settings": {
    "secretKey": "${WP_KEY}",
    "address": [ ${addr_json} ],
    "peers": [
      {
        "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
        "endpoint": "engage.cloudflareclient.com:2408",
        "reserved": ${WP_RES},
        "keepAlive": 30
      }
    ]
  }
}
EOF
}

# --- 5. 核心功能：应用配置到 Xray ---
# 参数1: 模式 (stream / ipv4 / ipv6 / dual / manual_node)
# 参数2: 额外参数
apply_warp_config() {
    local mode="$1"
    local extra_arg="$2"

    if [ ! -f "$XRAY_CONFIG" ]; then echo -e "${RED}未找到 Xray 配置文件！请先安装核心并添加节点。${PLAIN}"; return; fi
    if [ ! -f "$WARP_CONF_FILE" ]; then echo -e "${RED}请先配置 WARP 账号！${PLAIN}"; return; fi

    echo -e "${YELLOW}正在修改 Xray 配置...${PLAIN}"

    # 1. 清理旧配置 (原子操作)
    jq 'del(.outbounds[] | select(.tag=="warp-out"))' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    jq 'del(.routing.rules[] | select(.outboundTag=="warp-out"))' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"

    # 2. 注入 Outbound
    local outbound_json=$(generate_warp_outbound)
    jq --argjson new_out "$outbound_json" '.outbounds += [$new_out]' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"

    # 3. 生成路由规则
    local rule_json=""
    case "$mode" in
        "stream")
            # 模式一：智能分流 (流媒体 + AI)
            rule_json='{
                "type": "field",
                "outboundTag": "warp-out",
                "domain": ["geosite:netflix", "geosite:openai", "geosite:disney", "geosite:google", "geosite:youtube", "geosite:spotify"]
            }'
            ;;
        "ipv4")
            # 模式二：IPv4 全局接管
            rule_json='{ "type": "field", "outboundTag": "warp-out", "network": "tcp,udp", "ip": ["0.0.0.0/0"] }'
            ;;
        "ipv6")
            # 模式二：IPv6 全局接管
            rule_json='{ "type": "field", "outboundTag": "warp-out", "network": "tcp,udp", "ip": ["::/0"] }'
            ;;
        "dual")
            # 模式二：双栈全局接管
            rule_json='{ "type": "field", "outboundTag": "warp-out", "network": "tcp,udp" }'
            ;;
        "manual_node")
            # 模式三：指定节点接管
            rule_json="{ \"type\": \"field\", \"outboundTag\": \"warp-out\", \"inboundTag\": $extra_arg }"
            ;;
    esac

    # 4. 注入路由规则 (优先级最高，插到最前)
    if [ -n "$rule_json" ]; then
        jq --argjson new_rule "$rule_json" '.routing.rules = [$new_rule] + .routing.rules' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    fi

    # 5. 重启
    echo -e "${GREEN}配置注入完成，正在重启 Xray...${PLAIN}"
    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}Native WARP 模式已生效！${PLAIN}"
    else
        echo -e "${RED}Xray 重启失败，请检查日志 (journalctl -u xray -e)。${PLAIN}"
        echo -e "${YELLOW}可能是 Reserved 值不正确，或 IP 被 Cloudflare 拒绝。${PLAIN}"
    fi
}

# --- 6. 辅助功能：卸载 WARP 配置 ---
disable_warp() {
    if [ ! -f "$XRAY_CONFIG" ]; then return; fi
    echo -e "${YELLOW}正在移除 Native WARP 配置...${PLAIN}"
    
    jq 'del(.outbounds[] | select(.tag=="warp-out"))' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    jq 'del(.routing.rules[] | select(.outboundTag=="warp-out"))' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    
    systemctl restart xray
    echo -e "${GREEN}已恢复直连模式。${PLAIN}"
}

# --- 7. 交互逻辑：模式三节点选择器 ---
select_nodes_interactive() {
    if [ ! -f "$XRAY_CONFIG" ]; then echo "无配置文件"; return; fi
    
    echo -e "${SKYBLUE}正在读取当前节点列表...${PLAIN}"
    # 使用 jq 提取 index, tag, port, protocol
    local node_list=$(jq -r '.inbounds[] | "\(.tag)|\(.port)|\(.protocol)"' "$XRAY_CONFIG" | nl -w 2 -s " ")
    
    if [ -z "$node_list" ]; then
        echo -e "${RED}未找到任何入站节点。请先去【节点管理】添加节点。${PLAIN}"; return
    fi

    echo -e "------------------------------------------------"
    echo -e "序号  |  Tag (标签)  |  端口  |  协议"
    echo -e "------------------------------------------------"
    echo "$node_list" | awk -F'|' '{printf "%s | %-12s | %-5s | %s\n", $1, $2, $3, $4}'
    echo -e "------------------------------------------------"
    echo -e "${YELLOW}请输入要走 WARP 的节点序号 (支持多选，空格分隔，如: 1 3)${PLAIN}"
    read -p "选择: " selection

    local selected_tags_json="["
    local first=true

    for num in $selection; do
        local raw_line=$(echo "$node_list" | sed -n "${num}p")
        local tag=$(echo "$raw_line" | awk -F'|' '{print $1}' | awk '{print $2}')
        
        if [ -n "$tag" ] && [ "$tag" != "null" ]; then
            if [ "$first" = true ]; then first=false; else selected_tags_json+=","; fi
            selected_tags_json+="\"$tag\""
            echo -e "已选择: ${GREEN}$tag${PLAIN}"
        fi
    done
    selected_tags_json+="]"

    if [ "$selected_tags_json" == "[]" ]; then
        echo -e "${RED}未选择有效节点。${PLAIN}"
    else
        apply_warp_config "manual_node" "$selected_tags_json"
    fi
}

# --- 8. 主菜单入口 ---
show_warp_menu() {
    check_dependencies
    while true; do
        clear
        local status_text="${RED}未配置${PLAIN}"
        if [ -f "$WARP_CONF_FILE" ]; then status_text="${GREEN}已获取凭证${PLAIN}"; fi
        
        local current_mode="直连"
        if grep -q '"outboundTag": "warp-out"' "$XRAY_CONFIG"; then
            if grep -q '"domain": \[' "$XRAY_CONFIG"; then current_mode="${SKYBLUE}智能分流${PLAIN}";
            elif grep -q '"0.0.0.0/0"' "$XRAY_CONFIG"; then current_mode="${YELLOW}IPv4 接管${PLAIN}";
            elif grep -q '"inboundTag":' "$XRAY_CONFIG"; then current_mode="${YELLOW}指定节点${PLAIN}";
            else current_mode="${YELLOW}WARP 生效中${PLAIN}"; fi
        fi

        echo -e "${GREEN}================ Native WARP 配置向导 ================${PLAIN}"
        echo -e " 凭证状态: [$status_text]   当前模式: [$current_mode]"
        echo -e "----------------------------------------------------"
        echo -e " [基础账号]"
        echo -e " 1. 注册/配置 WARP 凭证 (自动获取 或 手动输入)" # <--- 修正了这里的文案
        echo -e " 2. 查看当前凭证信息"
        echo -e ""
        echo -e " [策略模式 - 单选]"
        echo -e " 3. ${SKYBLUE}模式一：智能流媒体分流 (推荐)${PLAIN}"
        echo -e "    ${GRAY}(Netflix/Disney+/OpenAI/Google -> WARP)${PLAIN}"
        echo -e ""
        echo -e " 4. ${SKYBLUE}模式二：全局接管 (隐藏 IP)${PLAIN}"
        echo -e "    ${GRAY}---> 拯救 Google 验证码 / 单栈变双栈${PLAIN}"
        echo -e ""
        echo -e " 5. ${SKYBLUE}模式三：指定节点接管 (多节点共存)${PLAIN}"
        echo -e "    ${GRAY}---> 选择特定端口强制走 WARP 出口${PLAIN}"
        echo -e ""
        echo -e " [维护]"
        echo -e " 7. ${RED}禁用/卸载 Native WARP (恢复直连)${PLAIN}"
        echo -e " 0. 返回上级菜单"
        echo -e "===================================================="
        read -p "请输入选项: " choice

        case "$choice" in
            1) get_warp_credentials ;; # 进入后会再次询问 1.自动 2.手动
            2) 
                if [ -f "$WARP_CONF_FILE" ]; then
                    source "$WARP_CONF_FILE"
                    echo -e "Private Key: ${YELLOW}$WP_KEY${PLAIN}"
                    echo -e "IPv6 Address:${YELLOW}$WP_IP${PLAIN}"
                    echo -e "Reserved:    ${YELLOW}$WP_RES${PLAIN}"
                else
                    echo "暂无信息，请先选择选项 1 进行配置。"
                fi
                read -p "按回车继续..." 
                ;;
            3) apply_warp_config "stream" ;;
            4) 
                echo -e " a. 仅接管 IPv4"
                echo -e " b. 仅接管 IPv6"
                echo -e " c. 双栈全接管"
                read -p "选择: " sub
                case "$sub" in
                    a) apply_warp_config "ipv4" ;;
                    b) apply_warp_config "ipv6" ;;
                    c) apply_warp_config "dual" ;;
                esac
                read -p "按回车继续..."
                ;;
            5) select_nodes_interactive; read -p "按回车继续..." ;;
            7) disable_warp; read -p "按回车继续..." ;;
            0) break ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# 脚本直接执行入口
show_warp_menu
