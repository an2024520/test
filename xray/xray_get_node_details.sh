#!/bin/bash

# ==============================================================================
# Argosbx 终极净化版 v3.5 (Refactored by Gemini)
# 修复日志：
# v3.5: 重构 List 模块 (移植 jq 解析逻辑) | 快捷指令强制落地 | 修复 Reality 公钥
# v3.4: 修复目录权限
# ==============================================================================

# --- 1. 全局配置 ---
export LANG=en_US.UTF-8
WORKDIR="$HOME/agsbx_clean"
BIN_DIR="$WORKDIR/bin"
CONF_DIR="$WORKDIR/conf"
SCRIPT_PATH="$WORKDIR/agsbx_pure.sh"
BACKUP_DNS="/etc/resolv.conf.bak.agsbx"

# ⚠️ 快捷指令自更新地址 (必填，用于 agsbx 命令修复)
SELF_URL="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/Argosbx_Pure.sh"

# --- 2. 变量映射 ---
[ -z "${vlpt+x}" ] || vlp=yes
[ -z "${vmpt+x}" ] || { vmp=yes; vmag=yes; }
[ -z "${vwpt+x}" ] || { vwp=yes; vmag=yes; }
[ -z "${hypt+x}" ] || hyp=yes
[ -z "${tupt+x}" ] || tup=yes

export uuid=${uuid:-''}
export port_vl_re=${vlpt:-''}
export port_vm_ws=${vmpt:-''}
export port_vw=${vwpt:-''}
export port_hy2=${hypt:-''}
export port_tu=${tupt:-''}
export ym_vl_re=${reym:-''}

export WARP_MODE=${warp:-${wap:-''}}
export WP_KEY=${wpkey:-''}
export WP_IP=${wpip:-''}
export WP_RES=${wpres:-''}

export ARGO_MODE=${argo:-''}
export ARGO_AUTH=${agk:-${token:-''}}
export ARGO_DOMAIN=${agn:-''}

# --- 3. 核心初始化 ---

init_variables() {
    mkdir -p "$BIN_DIR" "$CONF_DIR" "$CONF_DIR/xrk"
    
    # 1. UUID 生成
    if [ -z "$uuid" ]; then
        if [ -f "$CONF_DIR/uuid" ] && [ -s "$CONF_DIR/uuid" ]; then
            uuid=$(cat "$CONF_DIR/uuid")
        else
            uuid=$(cat /proc/sys/kernel/random/uuid)
            echo "$uuid" > "$CONF_DIR/uuid"
        fi
    else
        echo "$uuid" > "$CONF_DIR/uuid"
    fi
    uuid=$(echo "$uuid" | tr -d '\n\r ')

    # 2. 证书生成
    if [ ! -f "$CONF_DIR/cert.pem" ]; then
        openssl ecparam -genkey -name prime256v1 -out "$CONF_DIR/private.key" 2>/dev/null
        openssl req -new -x509 -days 36500 -key "$CONF_DIR/private.key" -out "$CONF_DIR/cert.pem" -subj "/CN=www.bing.com" 2>/dev/null
    fi
}

# --- 4. 清理原版残留 ---

cleanup_original_bloatware() {
    if [ -f ~/.bashrc ]; then
        sed -i '/agsbx/d' ~/.bashrc
        sed -i '/yonggekkk/d' ~/.bashrc
        sed -i '/export PATH="\$HOME\/bin:\$PATH"/d' ~/.bashrc
    fi
    rm -f /usr/local/bin/agsbx
    rm -f /usr/bin/agsbx
    rm -rf "$HOME/bin/agsbx"
    rm -rf "$HOME/bin"
    pkill -f 'agsbx/s' 2>/dev/null
    pkill -f 'agsbx/x' 2>/dev/null
    pkill -f 'agsbx/c' 2>/dev/null
}

# --- 5. 环境检查 ---

check_and_fix_network() {
    # 增加 jq 依赖
    if ! command -v jq >/dev/null 2>&1; then
        if [ -f /etc/debian_version ]; then 
            sudo apt-get update -y && sudo apt-get install -y curl wget tar unzip socat openssl iptables jq
        elif [ -f /etc/redhat-release ]; then 
            sudo yum update -y && sudo yum install -y curl wget tar unzip socat openssl iptables jq
        fi
    fi
    
    if ! curl -4 -s --connect-timeout 2 https://1.1.1.1 >/dev/null && curl -6 -s --connect-timeout 2 https://2606:4700:4700::1111 >/dev/null; then
        if [ ! -f "$BACKUP_DNS" ]; then
            echo " ⚠️  检测到纯 IPv6 环境，正在临时优化 DNS..."
            sudo cp /etc/resolv.conf "$BACKUP_DNS"
            echo -e "nameserver 2001:67c:2b0::4\nnameserver 2001:67c:2b0::6" | sudo tee /etc/resolv.conf >/dev/null
        fi
    fi
}

check_dependencies() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) XRAY_ARCH="64"; SB_ARCH="amd64"; CF_ARCH="amd64"; WGCF_ARCH="amd64" ;;
        aarch64) XRAY_ARCH="arm64-v8a"; SB_ARCH="arm64"; CF_ARCH="arm64"; WGCF_ARCH="arm64" ;;
        *) echo "❌ 不支持的 CPU 架构: $ARCH"; exit 1 ;;
    esac
}

get_ip() {
    v4=$(curl -s4m5 https://icanhazip.com)
    v6=$(curl -s6m5 https://icanhazip.com)
    server_ip=${v4:-$v6}
    [[ "$server_ip" =~ : ]] && server_ip="[$server_ip]"
    raw_ip=${v4:-$v6}
}

# --- 6. 配置逻辑 ---

configure_argo_if_needed() {
    if [ -z "$ARGO_MODE" ]; then return; fi
    echo " ☁️  检测到 Argo 参数: argo=$ARGO_MODE"
    if [ "$ARGO_MODE" == "vmpt" ]; then vmp=yes; elif [ "$ARGO_MODE" == "vwpt" ]; then vwp=yes; else ARGO_MODE=""; return; fi
    if [ -z "$ARGO_AUTH" ]; then echo " ⚠️  将在安装后启动 TryCloudflare 临时隧道。"; fi
}

configure_warp_if_needed() {
    if [ -z "$WARP_MODE" ]; then return; fi
    if [ -n "$WP_KEY" ] && [ -n "$WP_IP" ]; then return; fi
    echo " ⚠️  未检测到 WARP 账户，是否自动注册？(y/n) [默认y]"
    read -p " 输入: " choice
    choice=${choice:-y}
    if [[ "$choice" == "y" ]]; then
        wget -qO wgcf https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${WGCF_ARCH}
        chmod +x wgcf && ./wgcf register --accept-tos >/dev/null 2>&1 && ./wgcf generate >/dev/null 2>&1
        WP_KEY=$(grep 'PrivateKey' wgcf-profile.conf | cut -d ' ' -f 3 | tr -d '\n\r ')
        RAW_ADDR=$(grep 'Address' wgcf-profile.conf | cut -d '=' -f 2 | tr -d ' ')
        [[ "$RAW_ADDR" == *","* ]] && WP_IP=$(echo "$RAW_ADDR" | awk -F',' '{print $2}' | cut -d'/' -f1 | tr -d '\n\r ') || WP_IP=$(echo "$RAW_ADDR" | cut -d'/' -f1 | tr -d '\n\r ')
        CLIENT_ID=$(grep "client_id" wgcf-account.toml | cut -d '"' -f 2)
        [ -n "$CLIENT_ID" ] && WP_RES=$(python3 -c "import base64; d=base64.b64decode('${CLIENT_ID}'); print(f'[{d[0]}, {d[1]}, {d[2]}]')") || WP_RES="[]"
        echo "✅ 注册成功。Key: $WP_KEY"
        rm -f wgcf wgcf-account.toml wgcf-profile.conf
    else
        WARP_MODE=""
    fi
}

# --- 7. 下载与生成配置 ---

download_core() {
    if [ ! -f "$BIN_DIR/xray" ]; then
        local latest=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep "tag_name" | cut -d '"' -f 4)
        wget -qO "$WORKDIR/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${XRAY_ARCH}.zip"
        unzip -o "$WORKDIR/xray.zip" -d "$WORKDIR/temp_xray" >/dev/null
        mv "$WORKDIR/temp_xray/xray" "$BIN_DIR/xray"; chmod +x "$BIN_DIR/xray"; mv "$WORKDIR/temp_xray/geo"* "$BIN_DIR/" 2>/dev/null; rm -rf "$WORKDIR/xray.zip" "$WORKDIR/temp_xray"
    fi
    if [ ! -f "$BIN_DIR/sing-box" ]; then
        local latest=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep "tag_name" | cut -d '"' -f 4)
        local ver_num=${latest#v}
        wget -qO "$WORKDIR/sb.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/${latest}/sing-box-${ver_num}-linux-${SB_ARCH}.tar.gz"
        tar -zxvf "$WORKDIR/sb.tar.gz" -C "$WORKDIR" >/dev/null
        mv "$WORKDIR"/sing-box*linux*/sing-box "$BIN_DIR/sing-box"; chmod +x "$BIN_DIR/sing-box"; rm -rf "$WORKDIR/sb.tar.gz" "$WORKDIR"/sing-box*linux*
    fi
    if [ -n "$ARGO_MODE" ] && [ ! -f "$BIN_DIR/cloudflared" ]; then
        wget -qO "$BIN_DIR/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
        chmod +x "$BIN_DIR/cloudflared"
    fi
}

generate_config() {
    echo "⚙️ 生成配置..."
    [ -z "$ym_vl_re" ] && ym_vl_re="apple.com"
    echo "$ym_vl_re" > "$CONF_DIR/ym_vl_re"

    # 生成 Xray 密钥 (这里只需确保文件有内容，内容正确与否交给 Xray 自己)
    if [ -n "$vwp" ] || [ -n "$vlp" ]; then
        # 如果不存在私钥，生成之
        if [ ! -s "$CONF_DIR/xrk/private_key" ]; then
            "$BIN_DIR/xray" x25519 > "$CONF_DIR/temp_key"
            grep "Private Key" "$CONF_DIR/temp_key" | cut -d: -f2 | tr -d ' \n\r' > "$CONF_DIR/xrk/private_key"
            grep "Public Key" "$CONF_DIR/temp_key" | cut -d: -f2 | tr -d ' \n\r' > "$CONF_DIR/xrk/public_key"
            rm "$CONF_DIR/temp_key"
            openssl rand -hex 4 | tr -d '\n\r ' > "$CONF_DIR/xrk/short_id"
        fi
        # ENC 密钥
        if [ ! -f "$CONF_DIR/xrk/dekey" ]; then
            vlkey=$("$BIN_DIR/xray" vlessenc)
            echo "$vlkey" | grep '"decryption":' | cut -d: -f2 | tr -d ' ",\n\r' > "$CONF_DIR/xrk/dekey"
            echo "$vlkey" | grep '"encryption":' | cut -d: -f2 | tr -d ' ",\n\r' > "$CONF_DIR/xrk/enkey"
        fi
        dekey=$(cat "$CONF_DIR/xrk/dekey")
        # enkey 变量在 list 时动态获取
    fi

    # 端口生成 (包含 UDP 放行)
    open_port() {
        if command -v iptables >/dev/null; then
            iptables -I INPUT -p tcp --dport $1 -j ACCEPT 2>/dev/null
            iptables -I INPUT -p udp --dport $1 -j ACCEPT 2>/dev/null
        fi
        if command -v ufw >/dev/null; then ufw allow $1 >/dev/null 2>&1; fi
    }

    if [ -n "$vmp" ]; then
        [ -z "$port_vm_ws" ] && [ -f "$CONF_DIR/port_vm_ws" ] && port_vm_ws=$(cat "$CONF_DIR/port_vm_ws")
        [ -z "$port_vm_ws" ] && port_vm_ws=$(shuf -i 10000-65535 -n 1)
        echo "$port_vm_ws" > "$CONF_DIR/port_vm_ws"
        open_port $port_vm_ws
    fi
    if [ -n "$vwp" ]; then
        [ -z "$port_vw" ] && [ -f "$CONF_DIR/port_vw" ] && port_vw=$(cat "$CONF_DIR/port_vw")
        [ -z "$port_vw" ] && port_vw=$(shuf -i 10000-65535 -n 1)
        echo "$port_vw" > "$CONF_DIR/port_vw"
        open_port $port_vw
    fi

    ENABLE_WARP=false
    if [ -n "$WARP_MODE" ] && [ -n "$WP_KEY" ]; then
        ENABLE_WARP=true
        if [[ "$WP_IP" =~ .*:.* ]]; then WARP_ADDR="\"172.16.0.2/32\", \"${WP_IP}/128\""; else WARP_ADDR="\"${WP_IP}/32\", \"2606:4700:110:8d8d:1845:c39f:2dd5:a03a/128\""; fi
        ROUTE_V4=false; ROUTE_V6=false
        [[ "$WARP_MODE" == *"4"* ]] && ROUTE_V4=true; [[ "$WARP_MODE" == *"6"* ]] && ROUTE_V6=true; if [ "$ROUTE_V4" = false ] && [ "$ROUTE_V6" = false ]; then ROUTE_V4=true; fi
    fi

    # ================= XRAY JSON =================
    cat > "$CONF_DIR/xr.json" <<EOF
{ "log": { "loglevel": "none" }, "inbounds": [
EOF
    if [ -n "$vlp" ] || [ -z "${vmp}${vwp}${hyp}${tup}" ]; then 
        [ -z "$port_vl_re" ] && port_vl_re=$(shuf -i 10000-65535 -n 1)
        echo "$port_vl_re" > "$CONF_DIR/port_vl_re"
        open_port $port_vl_re
        cat >> "$CONF_DIR/xr.json" <<EOF
    { "tag": "vless-reality", "listen": "::", "port": $port_vl_re, "protocol": "vless", "settings": { "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }], "decryption": "none" }, "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "dest": "${ym_vl_re}:443", "serverNames": ["${ym_vl_re}"], "privateKey": "$(cat $CONF_DIR/xrk/private_key)", "shortIds": ["$(cat $CONF_DIR/xrk/short_id)"] } } },
EOF
    fi
    if [ -n "$vmp" ]; then
        cat >> "$CONF_DIR/xr.json" <<EOF
    { "tag": "vmess-ws", "listen": "::", "port": ${port_vm_ws}, "protocol": "vmess", "settings": { "clients": [{ "id": "${uuid}" }] }, "streamSettings": { "network": "ws", "wsSettings": { "path": "/${uuid}-vm" } } },
EOF
    fi
    if [ -n "$vwp" ]; then
        cat >> "$CONF_DIR/xr.json" <<EOF
    { "tag": "vless-ws", "listen": "::", "port": ${port_vw}, "protocol": "vless", "settings": { "clients": [{ "id": "${uuid}" }], "decryption": "${dekey}" }, "streamSettings": { "network": "ws", "wsSettings": { "path": "/${uuid}-vw" } } },
EOF
    fi
    sed -i '$ s/,$//' "$CONF_DIR/xr.json"
    cat >> "$CONF_DIR/xr.json" <<EOF
  ], "outbounds": [ { "protocol": "freedom", "tag": "direct" }
EOF
    if [ "$ENABLE_WARP" = true ]; then
        cat >> "$CONF_DIR/xr.json" <<EOF
    ,{ "tag": "warp-out", "protocol": "wireguard", "settings": { "secretKey": "${WP_KEY}", "address": [ ${WARP_ADDR} ], "peers": [{ "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "endpoint": "engage.cloudflareclient.com:2408", "reserved": ${WP_RES} }] } }
EOF
    fi
    cat >> "$CONF_DIR/xr.json" <<EOF
  ], "routing": { "rules": [
EOF
    if [ "$ENABLE_WARP" = true ]; then
        cat >> "$CONF_DIR/xr.json" <<EOF
      { "type": "field", "domain": [ "geosite:openai", "geosite:netflix", "geosite:google" ], "outboundTag": "warp-out" },
EOF
        if [ "$ROUTE_V4" = true ]; then echo '      { "type": "field", "ip": [ "0.0.0.0/0" ], "outboundTag": "warp-out" },' >> "$CONF_DIR/xr.json"; fi
        if [ "$ROUTE_V6" = true ]; then echo '      { "type": "field", "ip": [ "::/0" ], "outboundTag": "warp-out" },' >> "$CONF_DIR/xr.json"; fi
    fi
    cat >> "$CONF_DIR/xr.json" <<EOF
      { "type": "field", "outboundTag": "direct", "port": "0-65535" } ] } }
EOF

    # ================= SING-BOX JSON =================
    cat > "$CONF_DIR/sb.json" <<EOF
{ "log": { "level": "info" }, "inbounds": [
EOF
    if [ -n "$hyp" ] || [ -z "${vmp}${vwp}${vlp}${tup}" ]; then 
        [ -z "$port_hy2" ] && port_hy2=$(shuf -i 10000-65535 -n 1)
        echo "$port_hy2" > "$CONF_DIR/port_hy2"
        open_port $port_hy2
        cat >> "$CONF_DIR/sb.json" <<EOF
    { "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": ${port_hy2}, "users": [{ "password": "${uuid}" }], "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CONF_DIR/cert.pem", "key_path": "$CONF_DIR/private.key" } },
EOF
    fi
    if [ -n "$tup" ]; then
        [ -z "$port_tu" ] && port_tu=$(shuf -i 10000-65535 -n 1)
        echo "$port_tu" > "$CONF_DIR/port_tu"
        open_port $port_tu
        cat >> "$CONF_DIR/sb.json" <<EOF
    { "type": "tuic", "tag": "tuic-in", "listen": "::", "listen_port": ${port_tu}, "users": [{ "uuid": "${uuid}", "password": "${uuid}" }], "congestion_control": "bbr", "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CONF_DIR/cert.pem", "key_path": "$CONF_DIR/private.key" } },
EOF
    fi
    sed -i '$ s/,$//' "$CONF_DIR/sb.json"
    
    cat >> "$CONF_DIR/sb.json" <<EOF
  ], "outbounds": [ { "type": "direct", "tag": "direct" }
EOF
    if [ "$ENABLE_WARP" = true ]; then
        cat >> "$CONF_DIR/sb.json" <<EOF
    ,{ "type": "wireguard", "tag": "warp-out", "address": [ ${WARP_ADDR} ], "private_key": "${WP_KEY}", "peers": [{ "server": "engage.cloudflareclient.com", "server_port": 2408, "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "reserved": ${WP_RES} }] }
EOF
    fi
    cat >> "$CONF_DIR/sb.json" <<EOF
  ], "route": { "rules": [
EOF
    if [ "$ENABLE_WARP" = true ]; then
        cat >> "$CONF_DIR/sb.json" <<EOF
      { "geosite": [ "openai", "netflix", "google" ], "outbound": "warp-out" },
EOF
        if [ "$ROUTE_V4" = true ]; then echo '      { "ip_cidr": [ "0.0.0.0/0" ], "outbound": "warp-out" },' >> "$CONF_DIR/sb.json"; fi
        if [ "$ROUTE_V6" = true ]; then echo '      { "ip_cidr": [ "::/0" ], "outbound": "warp-out" },' >> "$CONF_DIR/sb.json"; fi
    fi
    cat >> "$CONF_DIR/sb.json" <<EOF
      { "port": [0, 65535], "outbound": "direct" } ] } }
EOF
}

# --- 8. 服务与输出 ---

setup_services() {
    USER_NAME=$(whoami)
    sudo tee /etc/systemd/system/xray-clean.service > /dev/null <<EOF
[Unit]
Description=Xray Clean Service
After=network.target
[Service]
User=$USER_NAME
Type=simple
ExecStart=$BIN_DIR/xray run -c $CONF_DIR/xr.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    sudo tee /etc/systemd/system/singbox-clean.service > /dev/null <<EOF
[Unit]
Description=Sing-box Clean Service
After=network.target
[Service]
User=$USER_NAME
Type=simple
ExecStart=$BIN_DIR/sing-box run -c $CONF_DIR/sb.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

    if [ -n "$ARGO_MODE" ]; then
        if [ "$ARGO_MODE" == "vmpt" ]; then TARGET_PORT=$port_vm_ws; fi
        if [ "$ARGO_MODE" == "vwpt" ]; then TARGET_PORT=$port_vw; fi
        if [ -n "$ARGO_AUTH" ]; then EXEC_START="$BIN_DIR/cloudflared tunnel --no-autoupdate run --token $ARGO_AUTH"; DESC="Argo (Token)"; else EXEC_START="$BIN_DIR/cloudflared tunnel --url http://localhost:$TARGET_PORT --no-autoupdate"; DESC="Argo (Quick)"; fi
        sudo tee /etc/systemd/system/argo-clean.service > /dev/null <<EOF
[Unit]
Description=$DESC
After=network.target
[Service]
User=$USER_NAME
Type=simple
ExecStart=$EXEC_START
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload; sudo systemctl enable argo-clean; sudo systemctl restart argo-clean
    fi
    sudo systemctl daemon-reload; sudo systemctl enable xray-clean singbox-clean; restart_services
}

restart_services() {
    systemctl is-active --quiet xray-clean && sudo systemctl restart xray-clean
    systemctl is-active --quiet singbox-clean && sudo systemctl restart singbox-clean
    if [ -n "$ARGO_MODE" ]; then systemctl is-active --quiet argo-clean && sudo systemctl restart argo-clean; fi
}

setup_shortcut() {
    # 强制落地策略：无论如何，先把脚本内容写入磁盘
    # 1. 尝试下载
    if [ -n "$SELF_URL" ]; then
        wget -qO "$SCRIPT_PATH" "$SELF_URL"
    fi
    
    # 2. 如果下载失败（文件不存在或为空），尝试复制 $0
    if [ ! -s "$SCRIPT_PATH" ] && [[ -f "$0" ]] && [[ "$0" != "bash" ]]; then
        cp "$0" "$SCRIPT_PATH"
    fi
    
    # 3. 赋予权限并链接
    if [ -s "$SCRIPT_PATH" ]; then
        chmod +x "$SCRIPT_PATH"
        sudo ln -sf "$SCRIPT_PATH" /usr/local/bin/agsbx 2>/dev/null
        hash -r 2>/dev/null
    else
        echo "⚠️ 警告：无法下载或复制脚本到 $SCRIPT_PATH，'agsbx' 命令可能不可用。"
    fi
}

# --- 9. 核心 List 逻辑 (JQ 重构版) ---

cmd_list() {
    get_ip
    echo ""
    echo "================ [Argosbx 净化版 v3.5] ================"
    echo "  IP: $server_ip"
    
    # --- Argo 信息预处理 ---
    ARGO_URL=""
    if systemctl is-active --quiet argo-clean; then
        echo "  Argo: ✅ 运行中"
        if [ -n "$ARGO_DOMAIN" ]; then
            ARGO_URL="$ARGO_DOMAIN"
        else
            ARGO_URL=$(journalctl -u argo-clean -n 20 --no-pager | grep -o 'https://.*\.trycloudflare\.com' | tail -n 1 | sed 's/https:\/\///')
        fi
        [ -n "$ARGO_URL" ] && echo "  域名: $ARGO_URL"
    fi
    echo "------------------------ [v2rayN / 标准链接] ------------------------"

    # --- 解析 Xray 配置 (基于 config.json) ---
    if [ -f "$CONF_DIR/xr.json" ]; then
        # 遍历所有 inbounds
        # 使用 base64 避免换行符导致的 jq 遍历错误
        for row in $(jq -r '.inbounds[] | @base64' "$CONF_DIR/xr.json"); do
            _jq() { echo ${row} | base64 --decode | jq -r ${1}; }
            
            PROTO=$(_jq '.protocol')
            TAG=$(_jq '.tag')
            PORT=$(_jq '.port')
            
            # 1. Reality
            if [[ "$TAG" == "vless-reality" ]]; then
                UUID=$(_jq '.settings.clients[0].id')
                SNI=$(_jq '.streamSettings.realitySettings.serverNames[0]')
                SID=$(_jq '.streamSettings.realitySettings.shortIds[0]')
                # 核心：直接用私钥反推公钥，不再依赖安装时的变量
                PRI_KEY=$(_jq '.streamSettings.realitySettings.privateKey')
                PUB_KEY=$("$BIN_DIR/xray" x25519 -i "$PRI_KEY" | grep "Public Key" | cut -d: -f2 | tr -d ' \n\r')
                
                echo "🔥 [Reality] vless://$UUID@$raw_ip:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB_KEY&sid=$SID&type=tcp&headerType=none#Clean-Reality"
                
                # 缓存给 OpenClash 用
                REALITY_OC="  - name: Clean-Reality\n    type: vless\n    server: $raw_ip\n    port: $PORT\n    uuid: $UUID\n    network: tcp\n    tls: true\n    udp: true\n    flow: xtls-rprx-vision\n    servername: $SNI\n    reality-opts:\n      public-key: $PUB_KEY\n      short-id: $SID\n    client-fingerprint: chrome"
            fi
            
            # 2. VMess-WS (自动适配 Argo)
            if [[ "$TAG" == "vmess-ws" ]]; then
                UUID=$(_jq '.settings.clients[0].id')
                PATH_VAL=$(_jq '.streamSettings.wsSettings.path')
                
                if [ -n "$ARGO_URL" ]; then
                    # Argo 链接
                    vm_json="{\"v\":\"2\",\"ps\":\"Clean-VMess-Argo\",\"add\":\"$ARGO_URL\",\"port\":\"443\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$ARGO_URL\",\"path\":\"$PATH_VAL\",\"tls\":\"tls\",\"sni\":\"$ARGO_URL\"}"
                    echo "🌀 [VMess-Argo] vmess://$(echo -n "$vm_json" | base64 -w 0)"
                    
                    VMESS_OC="  - name: Clean-VMess-Argo\n    type: vmess\n    server: $ARGO_URL\n    port: 443\n    uuid: $UUID\n    alterId: 0\n    cipher: auto\n    udp: true\n    tls: true\n    skip-cert-verify: false\n    network: ws\n    ws-opts:\n      path: $PATH_VAL\n      headers:\n        Host: $ARGO_URL"
                else
                    # 普通链接
                    vm_json="{\"v\":\"2\",\"ps\":\"Clean-VMess\",\"add\":\"$raw_ip\",\"port\":\"$PORT\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"www.bing.com\",\"path\":\"$PATH_VAL\",\"tls\":\"\"}"
                    echo "🌀 [VMess] vmess://$(echo -n "$vm_json" | base64 -w 0)"
                    
                    VMESS_OC="  - name: Clean-VMess\n    type: vmess\n    server: $raw_ip\n    port: $PORT\n    uuid: $UUID\n    alterId: 0\n    cipher: auto\n    udp: true\n    tls: false\n    network: ws\n    ws-opts:\n      path: $PATH_VAL\n      headers:\n        Host: www.bing.com"
                fi
            fi
        done
    fi

    # --- 解析 Sing-box 配置 (基于 config.json) ---
    if [ -f "$CONF_DIR/sb.json" ]; then
        for row in $(jq -r '.inbounds[] | @base64' "$CONF_DIR/sb.json"); do
            _jq() { echo ${row} | base64 --decode | jq -r ${1}; }
            TYPE=$(_jq '.type')
            
            # 3. Hysteria2
            if [[ "$TYPE" == "hysteria2" ]]; then
                PORT=$(_jq '.listen_port')
                PASS=$(_jq '.users[0].password')
                echo "🚀 [Hysteria2] hysteria2://$PASS@$raw_ip:$PORT?security=tls&alpn=h3&insecure=1&sni=www.bing.com#Clean-Hy2"
                
                HY2_OC="  - name: Clean-Hy2\n    type: hysteria2\n    server: $raw_ip\n    port: $PORT\n    password: $PASS\n    sni: www.bing.com\n    skip-cert-verify: true\n    alpn:\n      - h3"
            fi
        done
    fi

    echo ""
    echo "================ [Clash Meta / OpenClash 格式配置] ================"
    echo "proxies:"
    echo -e "$REALITY_OC"
    echo -e "$HY2_OC"
    echo -e "$VMESS_OC"
    echo "==================================================================="
}

cmd_uninstall() {
    echo "💣 卸载中..."
    sudo systemctl stop xray-clean argo-clean singbox-clean 2>/dev/null
    sudo systemctl disable xray-clean argo-clean singbox-clean 2>/dev/null
    sudo rm -f /etc/systemd/system/xray-clean.service /etc/systemd/system/argo-clean.service /etc/systemd/system/singbox-clean.service /usr/local/bin/agsbx
    sudo systemctl daemon-reload
    rm -rf "$WORKDIR"
    if [ -f "$BACKUP_DNS" ]; then sudo cp "$BACKUP_DNS" /etc/resolv.conf; echo "✅ DNS 已还原"; fi
    echo "✅ 卸载完成。"
}

if [[ -z "$1" ]] || [[ "$1" == "rep" ]]; then
    cleanup_original_bloatware
    check_and_fix_network
    check_dependencies
    init_variables
fi

case "$1" in
    list) cmd_list ;;
    del)  cmd_uninstall ;;
    res)  restart_services && echo "✅ 服务已重启" ;;
    rep)  
        echo "♻️ 重置配置..."
        echo "⚠️ 注意：增加协议请带上所有变量！"
        rm -rf "$CONF_DIR"/*.json "$CONF_DIR"/port*
        configure_argo_if_needed
        configure_warp_if_needed
        generate_config
        restart_services
        cmd_list
        ;;
    *)
        echo ">>> 开始安装 Argosbx 净化版 v3.5..."
        configure_argo_if_needed
        configure_warp_if_needed
        download_core
        generate_config
        setup_services
        setup_shortcut
        echo "✅ 安装完成！快捷指令: agsbx"
        cmd_list
        ;;
esac
