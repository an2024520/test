#!/bin/bash

# ==============================================================================
# Argosbx 终极净化·WARP增强版 (v3.0)
# 功能：Install | List | Del | Upx/Ups | Res | Rep
# 特性：官方源内核 | 自动生成/计算WARP信息(含Reserved) | 注册工具用完即焚
# ==============================================================================

# --- 1. 全局配置 ---
export LANG=en_US.UTF-8
WORKDIR="$HOME/agsbx_clean"
BIN_DIR="$WORKDIR/bin"
CONF_DIR="$WORKDIR/conf"
SCRIPT_PATH="$WORKDIR/agsbx.sh"

# --- 2. 变量映射 (WebUI & 自定义参数) ---
# 代理协议变量
[ -z "${vlpt+x}" ] || vlp=yes
[ -z "${vmpt+x}" ] || { vmp=yes; vmag=yes; }
[ -z "${hypt+x}" ] || hyp=yes
[ -z "${tupt+x}" ] || tup=yes
# 导出变量
export uuid=${uuid:-''}
export port_vl_re=${vlpt:-''}
export port_vm_ws=${vmpt:-''}
export port_hy2=${hypt:-''}
export port_tu=${tupt:-''}
export ym_vl_re=${reym:-''}

# WARP 变量 (用户可手动通过环境变量传入，也可由脚本自动生成)
export WP_KEY=${wpkey:-''}      # PrivateKey
export WP_IP=${wpip:-''}        # IPv6 or IPv4 Internal
export WP_RES=${wpres:-''}      # Reserved [x,y,z]

# --- 3. 核心工具函数 ---

check_env() {
    # 架构判断
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) XRAY_ARCH="64"; SB_ARCH="amd64"; WGCF_ARCH="amd64" ;;
        aarch64) XRAY_ARCH="arm64-v8a"; SB_ARCH="arm64"; WGCF_ARCH="arm64" ;;
        *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
    esac
    
    # 依赖检查 (新增 python3 用于计算 Reserved)
    if ! command -v unzip >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
        echo "📦 安装必要依赖 (curl, python3, etc)..."
        if [ -f /etc/debian_version ]; then
            sudo apt-get update -y && sudo apt-get install -y curl wget tar unzip socat python3
        elif [ -f /etc/redhat-release ]; then
            sudo yum update -y && sudo yum install -y curl wget tar unzip socat python3
        fi
    fi
    mkdir -p "$BIN_DIR" "$CONF_DIR"
}

get_ip() {
    v4=$(curl -s4m5 https://icanhazip.com)
    v6=$(curl -s6m5 https://icanhazip.com)
    server_ip=${v4:-$v6}
    [[ "$server_ip" =~ : ]] && server_ip="[$server_ip]"
}

# --- 4. WARP 注册与处理模块 (核心新增) ---

register_warp() {
    # 如果变量已存在，说明用户手动提供了，直接跳过
    if [ -n "$WP_KEY" ]; then
        echo "✅ 检测到环境变量中已包含 WARP 信息，使用现有信息。"
        return
    fi

    echo ""
    echo "================================================================"
    echo " ☁️  Cloudflare WARP 免费账号配置"
    echo "----------------------------------------------------------------"
    echo " 系统检测到你未提供 WARP 密钥。"
    echo " 脚本可以临时下载工具帮你注册一个全新账号，并提取关键的 Reserved 值。"
    echo " ⚠️  注意：注册工具仅在当前运行，获取信息后会自动删除，不会残留。"
    echo "================================================================"
    read -p " 是否自动生成 WARP 注册信息？(y/n) [默认y]: " choice
    choice=${choice:-y}

    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        echo "⬇️ 正在下载 wgcf 注册工具..."
        wget -qO wgcf https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${WGCF_ARCH}
        chmod +x wgcf

        echo "📝 正在注册 WARP 账号..."
        if ! ./wgcf register --accept-tos >/dev/null 2>&1; then
            echo "❌ WARP 注册失败 (可能是 CF 接口限制)，将跳过 WARP 配置。"
            rm -f wgcf wgcf-account.toml
            return
        fi

        echo "⚙️ 正在生成配置文件..."
        ./wgcf generate >/dev/null 2>&1

        # --- 提取信息 ---
        echo "🔍 正在提取关键参数..."
        
        # 1. 提取 PrivateKey
        WP_KEY=$(grep 'PrivateKey' wgcf-profile.conf | cut -d ' ' -f 3)
        
        # 2. 提取 Address (优先取 IPv6, 如果没有取 IPv4)
        # wgcf-profile 通常格式: Address = 172.16.0.2/32, 2606:4700.../128
        # 我们取逗号后的 IPv6，如果没有逗号，取第一个
        RAW_ADDR=$(grep 'Address' wgcf-profile.conf | cut -d '=' -f 2 | tr -d ' ')
        if [[ "$RAW_ADDR" == *","* ]]; then
            WP_IP=$(echo "$RAW_ADDR" | awk -F',' '{print $2}' | cut -d'/' -f1)
        else
            WP_IP=$(echo "$RAW_ADDR" | cut -d'/' -f1)
        fi
        
        # 3. 计算 Reserved (通过 Python 解码 wgcf-account.toml 中的 client_id)
        # client_id 是 Base64，Reserved 是其前3个字节的十进制表示
        CLIENT_ID=$(grep "client_id" wgcf-account.toml | cut -d '"' -f 2)
        if [ -n "$CLIENT_ID" ]; then
            WP_RES=$(python3 -c "import base64; d=base64.b64decode('${CLIENT_ID}'); print(f'[{d[0]}, {d[1]}, {d[2]}]')")
        else
            WP_RES=""
        fi

        # --- 展示并保存信息 ---
        echo ""
        echo "################################################################"
        echo "🎉 WARP 账号获取成功！请务必保存以下信息！"
        echo "----------------------------------------------------------------"
        echo "🔴 PrivateKey (私钥):  $WP_KEY"
        echo "🔵 Internal IP (内网): $WP_IP"
        echo "🟣 Reserved (保留值):  $WP_RES"
        echo "----------------------------------------------------------------"
        echo "💡 提示：如果未来重装，你可以使用 'wpkey=... wpip=... wpres=... ./install.sh' 直接使用此账号。"
        echo "################################################################"
        echo "按回车键继续安装..."
        read

        # --- 清理残留 ---
        echo "🧹 清理注册工具及临时文件..."
        rm -f wgcf wgcf-account.toml wgcf-profile.conf
        echo "✅ 清理完成"
    else
        echo "🚫 已跳过 WARP 配置（仅安装单栈节点）。"
    fi
}

# --- 5. 核心下载与配置生成 ---

download_core() {
    # Xray
    if [ ! -f "$BIN_DIR/xray" ]; then
        echo "⬇️ [Xray] 下载中 (官方源)..."
        local latest=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep "tag_name" | cut -d '"' -f 4)
        wget -qO "$WORKDIR/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${XRAY_ARCH}.zip"
        unzip -o "$WORKDIR/xray.zip" -d "$WORKDIR/temp_xray" >/dev/null
        mv "$WORKDIR/temp_xray/xray" "$BIN_DIR/xray"
        chmod +x "$BIN_DIR/xray"
        rm -rf "$WORKDIR/xray.zip" "$WORKDIR/temp_xray"
    fi
    # Sing-box
    if [ ! -f "$BIN_DIR/sing-box" ]; then
        echo "⬇️ [Sing-box] 下载中 (官方源)..."
        local latest=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep "tag_name" | cut -d '"' -f 4)
        local ver_num=${latest#v}
        wget -qO "$WORKDIR/sb.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/${latest}/sing-box-${ver_num}-linux-${SB_ARCH}.tar.gz"
        tar -zxvf "$WORKDIR/sb.tar.gz" -C "$WORKDIR" >/dev/null
        mv "$WORKDIR"/sing-box*linux*/sing-box "$BIN_DIR/sing-box"
        chmod +x "$BIN_DIR/sing-box"
        rm -rf "$WORKDIR/sb.tar.gz" "$WORKDIR"/sing-box*linux*
    fi
}

generate_config() {
    echo "⚙️ 生成配置文件..."
    # 基础信息
    [ -z "$uuid" ] && { [ ! -f "$CONF_DIR/uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid) > "$CONF_DIR/uuid" || uuid=$(cat "$CONF_DIR/uuid"); }
    [ -z "$ym_vl_re" ] && ym_vl_re="apple.com"
    echo "$ym_vl_re" > "$CONF_DIR/ym_vl_re"

    # 证书与Key
    [ ! -f "$CONF_DIR/cert.pem" ] && { openssl ecparam -genkey -name prime256v1 -out "$CONF_DIR/private.key"; openssl req -new -x509 -days 36500 -key "$CONF_DIR/private.key" -out "$CONF_DIR/cert.pem" -subj "/CN=www.bing.com"; }
    mkdir -p "$CONF_DIR/xrk"
    if [ ! -f "$CONF_DIR/xrk/private_key" ]; then
        key_pair=$("$BIN_DIR/xray" x25519)
        echo "$key_pair" | awk '/PrivateKey/{print $2}' > "$CONF_DIR/xrk/private_key"
        echo "$key_pair" | awk '/PublicKey/{print $2}' > "$CONF_DIR/xrk/public_key"
        openssl rand -hex 4 > "$CONF_DIR/xrk/short_id"
    fi

    # --- WARP 参数处理 ---
    ENABLE_WARP=false
    if [ -n "$WP_KEY" ] && [ -n "$WP_IP" ] && [ -n "$WP_RES" ]; then
        ENABLE_WARP=true
        # 构建 Address 字符串
        if [[ "$WP_IP" =~ .*:.* ]]; then
             WARP_ADDR_X="\"172.16.0.2/32\", \"${WP_IP}/128\""
             WARP_ADDR_S="\"172.16.0.2/32\", \"${WP_IP}/128\""
        else
             WARP_ADDR_X="\"${WP_IP}/32\", \"2606:4700:110:8d8d:1845:c39f:2dd5:a03a/128\""
             WARP_ADDR_S="\"${WP_IP}/32\", \"2606:4700:110:8d8d:1845:c39f:2dd5:a03a/128\""
        fi
    fi

    # ================= XRAY JSON =================
    cat > "$CONF_DIR/xr.json" <<EOF
{ "log": { "loglevel": "none" }, "inbounds": [
EOF
    # Reality
    if [ -n "$vlp" ] || [ -z "${vmp}${vwp}${hyp}${tup}" ]; then 
        [ -z "$port_vl_re" ] && port_vl_re=$(shuf -i 10000-65535 -n 1)
        echo "$port_vl_re" > "$CONF_DIR/port_vl_re"
        cat >> "$CONF_DIR/xr.json" <<EOF
    { "listen": "::", "port": $port_vl_re, "protocol": "vless", "settings": { "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }], "decryption": "none" }, "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "dest": "${ym_vl_re}:443", "serverNames": ["${ym_vl_re}"], "privateKey": "$(cat $CONF_DIR/xrk/private_key)", "shortIds": ["$(cat $CONF_DIR/xrk/short_id)"] } } },
EOF
    fi
    # VMess
    if [ -n "$vmp" ]; then
        [ -z "$port_vm_ws" ] && port_vm_ws=$(shuf -i 10000-65535 -n 1)
        echo "$port_vm_ws" > "$CONF_DIR/port_vm_ws"
        cat >> "$CONF_DIR/xr.json" <<EOF
    { "listen": "::", "port": ${port_vm_ws}, "protocol": "vmess", "settings": { "clients": [{ "id": "${uuid}" }] }, "streamSettings": { "network": "ws", "wsSettings": { "path": "/${uuid}-vm" } } },
EOF
    fi
    sed -i '$ s/,$//' "$CONF_DIR/xr.json"
    
    # Xray Outbounds
    cat >> "$CONF_DIR/xr.json" <<EOF
  ], "outbounds": [ { "protocol": "freedom", "tag": "direct" }
EOF
    if [ "$ENABLE_WARP" = true ]; then
        cat >> "$CONF_DIR/xr.json" <<EOF
    ,{ "tag": "warp-out", "protocol": "wireguard", "settings": { "secretKey": "${WP_KEY}", "address": [ ${WARP_ADDR_X} ], "peers": [{ "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "endpoint": "engage.cloudflareclient.com:2408", "reserved": ${WP_RES} }] } }
EOF
    fi
    # Xray Routing
    cat >> "$CONF_DIR/xr.json" <<EOF
  ], "routing": { "rules": [
EOF
    if [ "$ENABLE_WARP" = true ]; then
        cat >> "$CONF_DIR/xr.json" <<EOF
      { "type": "field", "ip": [ "0.0.0.0/0" ], "outboundTag": "warp-out" },
      { "type": "field", "domain": [ "geosite:openai", "geosite:netflix", "geosite:google" ], "outboundTag": "warp-out" },
EOF
    fi
    cat >> "$CONF_DIR/xr.json" <<EOF
      { "type": "field", "outboundTag": "direct", "port": "0-65535" } ] } }
EOF

    # ================= SING-BOX JSON =================
    cat > "$CONF_DIR/sb.json" <<EOF
{ "log": { "level": "info" }, "inbounds": [
EOF
    # Hysteria2
    if [ -n "$hyp" ] || [ -z "${vmp}${vwp}${vlp}${tup}" ]; then 
        [ -z "$port_hy2" ] && port_hy2=$(shuf -i 10000-65535 -n 1)
        echo "$port_hy2" > "$CONF_DIR/port_hy2"
        cat >> "$CONF_DIR/sb.json" <<EOF
    { "type": "hysteria2", "listen": "::", "listen_port": ${port_hy2}, "users": [{ "password": "${uuid}" }], "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CONF_DIR/cert.pem", "key_path": "$CONF_DIR/private.key" } },
EOF
    fi
    # Tuic
    if [ -n "$tup" ]; then
        [ -z "$port_tu" ] && port_tu=$(shuf -i 10000-65535 -n 1)
        echo "$port_tu" > "$CONF_DIR/port_tu"
        cat >> "$CONF_DIR/sb.json" <<EOF
    { "type": "tuic", "listen": "::", "listen_port": ${port_tu}, "users": [{ "uuid": "${uuid}", "password": "${uuid}" }], "congestion_control": "bbr", "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CONF_DIR/cert.pem", "key_path": "$CONF_DIR/private.key" } },
EOF
    fi
    sed -i '$ s/,$//' "$CONF_DIR/sb.json"

    # Sing-box Outbounds
    cat >> "$CONF_DIR/sb.json" <<EOF
  ], "outbounds": [ { "type": "direct", "tag": "direct" }
EOF
    if [ "$ENABLE_WARP" = true ]; then
        cat >> "$CONF_DIR/sb.json" <<EOF
    ,{ "type": "wireguard", "tag": "warp-out", "address": [ ${WARP_ADDR_S} ], "private_key": "${WP_KEY}", "peers": [{ "server": "engage.cloudflareclient.com", "server_port": 2408, "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "reserved": ${WP_RES} }] }
EOF
    fi
    # Sing-box Routing
    cat >> "$CONF_DIR/sb.json" <<EOF
  ], "route": { "rules": [
EOF
    if [ "$ENABLE_WARP" = true ]; then
        cat >> "$CONF_DIR/sb.json" <<EOF
      { "ip_cidr": [ "0.0.0.0/0" ], "outbound": "warp-out" },
      { "geosite": [ "openai", "netflix", "google" ], "outbound": "warp-out" },
EOF
    fi
    cat >> "$CONF_DIR/sb.json" <<EOF
      { "port": [0, 65535], "outbound": "direct" } ] } }
EOF
}

# --- 6. 服务与快捷方式 ---

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
    sudo systemctl daemon-reload
    sudo systemctl enable xray-clean singbox-clean
    restart_services
}

restart_services() {
    systemctl is-active --quiet xray-clean && sudo systemctl restart xray-clean
    systemctl is-active --quiet singbox-clean && sudo systemctl restart singbox-clean
}

setup_shortcut() {
    cp "$0" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
    sudo ln -sf "$SCRIPT_PATH" /usr/local/bin/agsbx
}

# --- 7. 指令功能 ---

cmd_list() {
    [ ! -f "$CONF_DIR/uuid" ] && { echo "❌ 请先安装"; exit 1; }
    get_ip
    uuid=$(cat "$CONF_DIR/uuid")
    echo ""
    echo "================ [Argosbx 净化·WARP版] ================"
    echo "  UUID: $uuid"
    echo "  IP:   $server_ip (若开启WARP则显示WARP IP)"
    echo "------------------------------------------------------"
    [ -f "$CONF_DIR/port_vl_re" ] && echo "🔥 [Reality] vless://$uuid@$server_ip:$(cat $CONF_DIR/port_vl_re)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(cat $CONF_DIR/ym_vl_re)&fp=chrome&pbk=$(cat $CONF_DIR/xrk/public_key)&sid=$(cat $CONF_DIR/xrk/short_id)&type=tcp&headerType=none#Clean-Reality"
    [ -f "$CONF_DIR/port_hy2" ] && echo "🚀 [Hysteria2] hysteria2://$uuid@$server_ip:$(cat $CONF_DIR/port_hy2)?security=tls&alpn=h3&insecure=1&sni=www.bing.com#Clean-Hy2"
    [ -f "$CONF_DIR/port_vm_ws" ] && vm_json="{\"v\":\"2\",\"ps\":\"Clean-VMess\",\"add\":\"$server_ip\",\"port\":\"$(cat $CONF_DIR/port_vm_ws)\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"www.bing.com\",\"path\":\"/$uuid-vm\",\"tls\":\"\"}" && echo "🌀 [VMess] vmess://$(echo -n "$vm_json" | base64 -w 0)"
    echo "======================================================"
}

# --- 8. 入口 ---

if [[ -z "$1" ]] || [[ "$1" == "rep" ]]; then
    check_env
fi

case "$1" in
    list) cmd_list ;;
    del)  
        echo "💣 卸载中..."
        sudo systemctl stop xray-clean singbox-clean 2>/dev/null
        sudo systemctl disable xray-clean singbox-clean 2>/dev/null
        sudo rm -f /etc/systemd/system/xray-clean.service /etc/systemd/system/singbox-clean.service /usr/local/bin/agsbx
        sudo systemctl daemon-reload
        rm -rf "$WORKDIR"
        echo "✅ 完成。"
        ;;
    res)  restart_services && echo "✅ 服务已重启" ;;
    upx)  check_env && rm -f "$BIN_DIR/xray" && download_core && restart_services && echo "✅ Xray 升级完成" ;;
    ups)  check_env && rm -f "$BIN_DIR/sing-box" && download_core && restart_services && echo "✅ Sing-box 升级完成" ;;
    rep)
        echo "♻️ 重置配置..."
        # 仅删除配置，保留二进制文件
        rm -rf "$CONF_DIR"/*.json "$CONF_DIR"/port*
        register_warp # 重新检测或询问WARP
        generate_config
        restart_services
        cmd_list
        ;;
    *)
        echo ">>> 开始安装 Argosbx 净化·WARP版..."
        register_warp # 核心：询问或生成 WARP
        download_core
        generate_config
        setup_services
        setup_shortcut
        echo "✅ 安装完成！快捷指令: agsbx"
        cmd_list
        ;;
esac
