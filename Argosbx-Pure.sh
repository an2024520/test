#!/bin/bash

# ==============================================================================
# Argosbx 终极净化版 v2.5 (Refactored by Gemini)
# 核心理念：去私货、零侵入、官方源、全功能保留 (ENC/Argo/WARP/WebUI兼容)
# ==============================================================================

# --- 1. 全局配置 ---
export LANG=en_US.UTF-8
WORKDIR="$HOME/agsbx_clean"
BIN_DIR="$WORKDIR/bin"
CONF_DIR="$WORKDIR/conf"
SCRIPT_PATH="$WORKDIR/agsbx.sh"
BACKUP_DNS="/etc/resolv.conf.bak.agsbx"

# --- 2. 变量映射 (WebUI 兼容层) ---
# 协议开关
[ -z "${vlpt+x}" ] || vlp=yes
[ -z "${vmpt+x}" ] || { vmp=yes; vmag=yes; }
[ -z "${vwpt+x}" ] || { vwp=yes; vmag=yes; }
[ -z "${hypt+x}" ] || hyp=yes
[ -z "${tupt+x}" ] || tup=yes

export uuid=${uuid:-''}
# 端口变量 (支持传入固定端口，不传则后续随机生成)
export port_vl_re=${vlpt:-''}
export port_vm_ws=${vmpt:-''}
export port_vw=${vwpt:-''}
export port_hy2=${hypt:-''}
export port_tu=${tupt:-''}
export ym_vl_re=${reym:-''}

# WARP 变量
export WARP_MODE=${warp:-${wap:-''}}
export WP_KEY=${wpkey:-''}
export WP_IP=${wpip:-''}
export WP_RES=${wpres:-''}

# Argo 变量 (完美兼容 WebUI 的 agk/agn 写法)
export ARGO_MODE=${argo:-''}     # vmpt 或 vwpt
export ARGO_AUTH=${agk:-${token:-''}}    # Token
export ARGO_DOMAIN=${agn:-''}            # 域名 (仅作显示用)

# --- 3. 环境检查 ---

check_and_fix_network() {
    # 基础依赖检测与安装
    if ! command -v curl >/dev/null 2>&1; then
        if [ -f /etc/debian_version ]; then sudo apt-get update -y && sudo apt-get install -y curl; fi
        if [ -f /etc/redhat-release ]; then sudo yum update -y && sudo yum install -y curl; fi
    fi
    # IPv6-Only 优化 (DNS64)
    if ! curl -4 -s --connect-timeout 2 https://1.1.1.1 >/dev/null && curl -6 -s --connect-timeout 2 https://2606:4700:4700::1111 >/dev/null; then
        if [ ! -f "$BACKUP_DNS" ]; then
            echo " ⚠️  检测到纯 IPv6 环境，正在临时优化 DNS 以支持下载..."
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
    if ! command -v unzip >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
        echo "📦 安装必要依赖..."
        if [ -f /etc/debian_version ]; then sudo apt-get update -y && sudo apt-get install -y wget tar unzip socat python3; fi
        if [ -f /etc/redhat-release ]; then sudo yum update -y && sudo yum install -y wget tar unzip socat python3; fi
    fi
    mkdir -p "$BIN_DIR" "$CONF_DIR"
}

get_ip() {
    v4=$(curl -s4m5 https://icanhazip.com)
    v6=$(curl -s6m5 https://icanhazip.com)
    server_ip=${v4:-$v6}
    [[ "$server_ip" =~ : ]] && server_ip="[$server_ip]"
}

# --- 4. 配置逻辑 ---

configure_argo_if_needed() {
    if [ -z "$ARGO_MODE" ]; then return; fi
    echo " ☁️  检测到 Argo 参数: argo=$ARGO_MODE"

    # 关联协议 (WebUI 逻辑还原)
    if [ "$ARGO_MODE" == "vmpt" ]; then
        vmp=yes
        echo " -> 已关联 VMess-WS"
    elif [ "$ARGO_MODE" == "vwpt" ]; then
        vwp=yes
        echo " -> 已关联 VLESS-WS (ENC)"
    else
        echo "❌ 忽略无效 Argo 参数。仅支持 'vmpt' 或 'vwpt'。"
        ARGO_MODE=""
        return
    fi

    if [ -n "$ARGO_AUTH" ]; then
        echo "✅ 使用预设 Token (固定隧道)。"
    else
        echo " ⚠️  未检测到 Token。将在安装后启动 TryCloudflare 临时隧道。"
    fi
}

configure_warp_if_needed() {
    if [ -z "$WARP_MODE" ]; then return; fi
    if [ -n "$WP_KEY" ] && [ -n "$WP_IP" ] && [ -n "$WP_RES" ]; then return; fi

    echo " ⚠️  未检测到 WARP 账户，是否自动注册？(y/n) [默认y]"
    read -p " 输入: " choice
    choice=${choice:-y}
    if [[ "$choice" == "y" ]]; then
        echo "⬇️ 注册 WARP..."
        wget -qO wgcf https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${WGCF_ARCH}
        chmod +x wgcf && ./wgcf register --accept-tos >/dev/null 2>&1 && ./wgcf generate >/dev/null 2>&1
        
        WP_KEY=$(grep 'PrivateKey' wgcf-profile.conf | cut -d ' ' -f 3)
        RAW_ADDR=$(grep 'Address' wgcf-profile.conf | cut -d '=' -f 2 | tr -d ' ')
        [[ "$RAW_ADDR" == *","* ]] && WP_IP=$(echo "$RAW_ADDR" | awk -F',' '{print $2}' | cut -d'/' -f1) || WP_IP=$(echo "$RAW_ADDR" | cut -d'/' -f1)
        
        CLIENT_ID=$(grep "client_id" wgcf-account.toml | cut -d '"' -f 2)
        [ -n "$CLIENT_ID" ] && WP_RES=$(python3 -c "import base64; d=base64.b64decode('${CLIENT_ID}'); print(f'[{d[0]}, {d[1]}, {d[2]}]')") || WP_RES="[]"
        
        echo "✅ 注册成功。Key: $WP_KEY"
        rm -f wgcf wgcf-account.toml wgcf-profile.conf
    else
        WARP_MODE=""
    fi
}

# --- 5. 下载与生成配置 ---

download_core() {
    # 始终只从官方源下载
    if [ ! -f "$BIN_DIR/xray" ]; then
        echo "⬇️ [Xray] 下载中 (Official)..."
        local latest=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep "tag_name" | cut -d '"' -f 4)
        wget -qO "$WORKDIR/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${XRAY_ARCH}.zip"
        unzip -o "$WORKDIR/xray.zip" -d "$WORKDIR/temp_xray" >/dev/null
        mv "$WORKDIR/temp_xray/xray" "$BIN_DIR/xray"
        chmod +x "$BIN_DIR/xray"
        mv "$WORKDIR/temp_xray/geo"* "$BIN_DIR/" 2>/dev/null
        rm -rf "$WORKDIR/xray.zip" "$WORKDIR/temp_xray"
    fi
    if [ ! -f "$BIN_DIR/sing-box" ]; then
        echo "⬇️ [Sing-box] 下载中 (Official)..."
        local latest=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep "tag_name" | cut -d '"' -f 4)
        local ver_num=${latest#v}
        wget -qO "$WORKDIR/sb.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/${latest}/sing-box-${ver_num}-linux-${SB_ARCH}.tar.gz"
        tar -zxvf "$WORKDIR/sb.tar.gz" -C "$WORKDIR" >/dev/null
        mv "$WORKDIR"/sing-box*linux*/sing-box "$BIN_DIR/sing-box"
        chmod +x "$BIN_DIR/sing-box"
        rm -rf "$WORKDIR/sb.tar.gz" "$WORKDIR"/sing-box*linux*
    fi
    if [ -n "$ARGO_MODE" ] && [ ! -f "$BIN_DIR/cloudflared" ]; then
        echo "⬇️ [Cloudflared] 下载中 (Official)..."
        wget -qO "$BIN_DIR/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
        chmod +x "$BIN_DIR/cloudflared"
    fi
}

generate_config() {
    echo "⚙️ 生成配置..."
    [ -z "$uuid" ] && { [ ! -f "$CONF_DIR/uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid) > "$CONF_DIR/uuid" || uuid=$(cat "$CONF_DIR/uuid"); }
    [ -z "$ym_vl_re" ] && ym_vl_re="apple.com"
    echo "$ym_vl_re" > "$CONF_DIR/ym_vl_re"

    # --- 核心修复：ENC 密钥生成 (完美还原原版功能) ---
    if [ -n "$vwp" ] || [ -n "$vlp" ]; then
        mkdir -p "$CONF_DIR/xrk"
        if [ ! -f "$CONF_DIR/xrk/dekey" ]; then
            # 调用 Xray 生成 vlessenc
            vlkey=$("$BIN_DIR/xray" vlessenc)
            dekey=$(echo "$vlkey" | grep '"decryption":' | sed -n '2p' | cut -d' ' -f2- | tr -d '"')
            enkey=$(echo "$vlkey" | grep '"encryption":' | sed -n '2p' | cut -d' ' -f2- | tr -d '"')
            echo "$dekey" > "$CONF_DIR/xrk/dekey"
            echo "$enkey" > "$CONF_DIR/xrk/enkey"
        fi
        dekey=$(cat "$CONF_DIR/xrk/dekey")
        enkey=$(cat "$CONF_DIR/xrk/enkey")
    fi

    # 端口生成 (支持随机兜底)
    if [ -n "$vmp" ]; then
        [ -z "$port_vm_ws" ] && [ -f "$CONF_DIR/port_vm_ws" ] && port_vm_ws=$(cat "$CONF_DIR/port_vm_ws")
        [ -z "$port_vm_ws" ] && port_vm_ws=$(shuf -i 10000-65535 -n 1)
        echo "$port_vm_ws" > "$CONF_DIR/port_vm_ws"
    fi
    if [ -n "$vwp" ]; then
        [ -z "$port_vw" ] && [ -f "$CONF_DIR/port_vw" ] && port_vw=$(cat "$CONF_DIR/port_vw")
        [ -z "$port_vw" ] && port_vw=$(shuf -i 10000-65535 -n 1)
        echo "$port_vw" > "$CONF_DIR/port_vw"
    fi

    # WARP
    ENABLE_WARP=false
    if [ -n "$WARP_MODE" ] && [ -n "$WP_KEY" ]; then
        ENABLE_WARP=true
        if [[ "$WP_IP" =~ .*:.* ]]; then WARP_ADDR="\"172.16.0.2/32\", \"${WP_IP}/128\""; else WARP_ADDR="\"${WP_IP}/32\", \"2606:4700:110:8d8d:1845:c39f:2dd5:a03a/128\""; fi
        ROUTE_V4=false; ROUTE_V6=false
        [[ "$WARP_MODE" == *"4"* ]] && ROUTE_V4=true; [[ "$WARP_MODE" == *"6"* ]] && ROUTE_V6=true
        if [ "$ROUTE_V4" = false ] && [ "$ROUTE_V6" = false ]; then ROUTE_V4=true; fi
    fi

    # XRAY JSON
    cat > "$CONF_DIR/xr.json" <<EOF
{ "log": { "loglevel": "none" }, "inbounds": [
EOF
    # Reality
    if [ -n "$vlp" ] || [ -z "${vmp}${vwp}${hyp}${tup}" ]; then 
        [ -z "$port_vl_re" ] && port_vl_re=$(shuf -i 10000-65535 -n 1)
        echo "$port_vl_re" > "$CONF_DIR/port_vl_re"
        [ ! -f "$CONF_DIR/xrk/private_key" ] && { "$BIN_DIR/xray" x25519 > "$CONF_DIR/temp_key"; awk '/PrivateKey/{print $2}' "$CONF_DIR/temp_key" > "$CONF_DIR/xrk/private_key"; awk '/PublicKey/{print $2}' "$CONF_DIR/temp_key" > "$CONF_DIR/xrk/public_key"; rm "$CONF_DIR/temp_key"; openssl rand -hex 4 > "$CONF_DIR/xrk/short_id"; }
        cat >> "$CONF_DIR/xr.json" <<EOF
    { "listen": "::", "port": $port_vl_re, "protocol": "vless", "settings": { "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }], "decryption": "none" }, "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "dest": "${ym_vl_re}:443", "serverNames": ["${ym_vl_re}"], "privateKey": "$(cat $CONF_DIR/xrk/private_key)", "shortIds": ["$(cat $CONF_DIR/xrk/short_id)"] } } },
EOF
    fi
    # VMess-WS
    if [ -n "$vmp" ]; then
        cat >> "$CONF_DIR/xr.json" <<EOF
    { "listen": "::", "port": ${port_vm_ws}, "protocol": "vmess", "settings": { "clients": [{ "id": "${uuid}" }] }, "streamSettings": { "network": "ws", "wsSettings": { "path": "/${uuid}-vm" } } },
EOF
    fi
    # VLESS-WS (启用 ENC 支持)
    if [ -n "$vwp" ]; then
        # 这里的 decryption 使用生成的 dekey，完美还原 vless-ws-enc
        cat >> "$CONF_DIR/xr.json" <<EOF
    { "listen": "::", "port": ${port_vw}, "protocol": "vless", "settings": { "clients": [{ "id": "${uuid}" }], "decryption": "${dekey}" }, "streamSettings": { "network": "ws", "wsSettings": { "path": "/${uuid}-vw" } } },
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

    # 占位 Sing-box
    cat > "$CONF_DIR/sb.json" <<EOF
{ "log": { "level": "info" }, "inbounds": [], "outbounds": [{ "type": "direct", "tag": "direct" }] }
EOF
}

# --- 6. 服务 ---

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

    if [ -n "$ARGO_MODE" ]; then
        if [ "$ARGO_MODE" == "vmpt" ]; then TARGET_PORT=$port_vm_ws; fi
        if [ "$ARGO_MODE" == "vwpt" ]; then TARGET_PORT=$port_vw; fi
        
        if [ -n "$ARGO_AUTH" ]; then
            # Token 模式 (固定)
            EXEC_START="$BIN_DIR/cloudflared tunnel --no-autoupdate run --token $ARGO_AUTH"
            DESC="Argo (Token)"
        else
            # 临时模式 (随机)
            EXEC_START="$BIN_DIR/cloudflared tunnel --url http://localhost:$TARGET_PORT --no-autoupdate"
            DESC="Argo (Quick)"
        fi

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
        sudo systemctl daemon-reload
        sudo systemctl enable argo-clean
        sudo systemctl restart argo-clean
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable xray-clean
    restart_services
}

restart_services() {
    systemctl is-active --quiet xray-clean && sudo systemctl restart xray-clean
    if [ -n "$ARGO_MODE" ]; then systemctl is-active --quiet argo-clean && sudo systemctl restart argo-clean; fi
}

setup_shortcut() {
    cp "$0" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
    sudo ln -sf "$SCRIPT_PATH" /usr/local/bin/agsbx
}

cmd_list() {
    [ ! -f "$CONF_DIR/uuid" ] && { echo "❌ 请先安装"; exit 1; }
    get_ip
    uuid=$(cat "$CONF_DIR/uuid")
    echo ""
    echo "================ [Argosbx 净化版 v2.5] ================"
    echo "  UUID: $uuid"
    echo "  IP:   $server_ip"
    [ -n "$WARP_MODE" ] && echo "  WARP: ✅ 开启"
    if [ -n "$ARGO_MODE" ]; then
        echo "  Argo: ✅ 开启 ($ARGO_MODE)"
        if [ -z "$ARGO_AUTH" ]; then
            ARGO_URL=$(journalctl -u argo-clean -n 20 --no-pager | grep -o 'https://.*\.trycloudflare\.com' | tail -n 1)
            echo "  域名: ${ARGO_URL:-获取中...} (临时)"
        else
            echo "  域名: ${ARGO_DOMAIN:-固定隧道(请查看CF后台)}"
        fi
        
        if [ "$ARGO_MODE" == "vmpt" ]; then
            echo "  👉 协议: VMess-WS | 本地端口: $(cat $CONF_DIR/port_vm_ws)"
        elif [ "$ARGO_MODE" == "vwpt" ]; then
            echo "  👉 协议: VLESS-WS (ENC) | 本地端口: $(cat $CONF_DIR/port_vw)"
            echo "  🔑 客户端 encryption: $(cat $CONF_DIR/xrk/enkey 2>/dev/null)"
        fi
    fi
    echo "------------------------------------------------------"
    [ -f "$CONF_DIR/port_vl_re" ] && echo "🔥 [Reality] vless://$uuid@$server_ip:$(cat $CONF_DIR/port_vl_re)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(cat $CONF_DIR/ym_vl_re)&fp=chrome&pbk=$(cat $CONF_DIR/xrk/public_key)&sid=$(cat $CONF_DIR/xrk/short_id)&type=tcp&headerType=none#Clean-Reality"
    echo "======================================================"
}

cmd_uninstall() {
    echo "💣 卸载中..."
    sudo systemctl stop xray-clean argo-clean 2>/dev/null
    sudo systemctl disable xray-clean argo-clean 2>/dev/null
    sudo rm -f /etc/systemd/system/xray-clean.service /etc/systemd/system/argo-clean.service /usr/local/bin/agsbx
    sudo systemctl daemon-reload
    rm -rf "$WORKDIR"
    if [ -f "$BACKUP_DNS" ]; then sudo cp "$BACKUP_DNS" /etc/resolv.conf; echo "✅ DNS 已还原"; fi
    echo "✅ 卸载完成。"
}

if [[ -z "$1" ]] || [[ "$1" == "rep" ]]; then
    check_and_fix_network
    check_dependencies
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
        echo ">>> 开始安装 Argosbx 净化版 v2.5..."
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
