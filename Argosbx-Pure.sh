#!/bin/bash

# ==============================================================================
# Argosbx 终极净化版 v2.8 (Refactored by Gemini)
# 更新日志：
# v2.8: 修复Singbox配置被覆盖BUG | 修复VMess JSON转义 | 增强管道安装兼容性
# v2.6: 新增 OpenClash 输出
# ==============================================================================

# --- 1. 全局配置 ---
export LANG=en_US.UTF-8
WORKDIR="$HOME/agsbx_clean"
BIN_DIR="$WORKDIR/bin"
CONF_DIR="$WORKDIR/conf"
# 修正：定义自下载地址，用于管道安装时的自我修复
SELF_URL="https://raw.githubusercontent.com/yonggekkk/argosbx/main/argosbx.sh" # ⚠️注意：这里建议替换为你自己仓库的 Raw 地址，否则还是下的原版
# 为了方便你测试，这里暂时保留结构，请在最后保存时替换为你自己 GitHub 仓库的 Raw 地址
# 例如：SELF_URL="https://raw.githubusercontent.com/an2024520/test/main/Argosbx-Pure.sh"

BACKUP_DNS="/etc/resolv.conf.bak.agsbx"

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

# --- 3. 环境检查 ---

check_and_fix_network() {
    if ! command -v curl >/dev/null 2>&1; then
        if [ -f /etc/debian_version ]; then sudo apt-get update -y && sudo apt-get install -y curl; fi
        if [ -f /etc/redhat-release ]; then sudo yum update -y && sudo yum install -y curl; fi
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
    if ! command -v unzip >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
        echo "📦 安装依赖..."
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
    raw_ip=${v4:-$v6}
}

# --- 4. 配置逻辑 ---

configure_argo_if_needed() {
    if [ -z "$ARGO_MODE" ]; then return; fi
    echo " ☁️  检测到 Argo 参数: argo=$ARGO_MODE"
    if [ "$ARGO_MODE" == "vmpt" ]; then vmp=yes; echo " -> 关联 VMess-WS"; elif [ "$ARGO_MODE" == "vwpt" ]; then vwp=yes; echo " -> 关联 VLESS-WS (ENC)"; else ARGO_MODE=""; return; fi
    if [ -n "$ARGO_AUTH" ]; then echo "✅ 使用预设 Token。"; else echo " ⚠️  将在安装后启动 TryCloudflare 临时隧道。"; fi
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
    [ -z "$uuid" ] && { [ ! -f "$CONF_DIR/uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid) > "$CONF_DIR/uuid" || uuid=$(cat "$CONF_DIR/uuid"); }
    [ -z "$ym_vl_re" ] && ym_vl_re="apple.com"
    echo "$ym_vl_re" > "$CONF_DIR/ym_vl_re"

    # 生成证书 (Hysteria2/Tuic 必需)
    if [ ! -f "$CONF_DIR/cert.pem" ]; then
        openssl ecparam -genkey -name prime256v1 -out "$CONF_DIR/private.key"
        openssl req -new -x509 -days 36500 -key "$CONF_DIR/private.key" -out "$CONF_DIR/cert.pem" -subj "/CN=www.bing.com" 2>/dev/null
    fi

    if [ -n "$vwp" ] || [ -n "$vlp" ]; then
        mkdir -p "$CONF_DIR/xrk"
        if [ ! -f "$CONF_DIR/xrk/dekey" ]; then
            vlkey=$("$BIN_DIR/xray" vlessenc)
            dekey=$(echo "$vlkey" | grep '"decryption":' | sed -n '2p' | cut -d' ' -f2- | tr -d '"')
            enkey=$(echo "$vlkey" | grep '"encryption":' | sed -n '2p' | cut -d' ' -f2- | tr -d '"')
            echo "$dekey" > "$CONF_DIR/xrk/dekey"; echo "$enkey" > "$CONF_DIR/xrk/enkey"
        fi
        dekey=$(cat "$CONF_DIR/xrk/dekey"); enkey=$(cat "$CONF_DIR/xrk/enkey")
    fi

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
        [ ! -f "$CONF_DIR/xrk/private_key" ] && { "$BIN_DIR/xray" x25519 > "$CONF_DIR/temp_key"; awk '/PrivateKey/{print $2}' "$CONF_DIR/temp_key" > "$CONF_DIR/xrk/private_key"; awk '/PublicKey/{print $2}' "$CONF_DIR/temp_key" > "$CONF_DIR/xrk/public_key"; rm "$CONF_DIR/temp_key"; openssl rand -hex 4 > "$CONF_DIR/xrk/short_id"; }
        cat >> "$CONF_DIR/xr.json" <<EOF
    { "listen": "::", "port": $port_vl_re, "protocol": "vless", "settings": { "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }], "decryption": "none" }, "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "dest": "${ym_vl_re}:443", "serverNames": ["${ym_vl_re}"], "privateKey": "$(cat $CONF_DIR/xrk/private_key)", "shortIds": ["$(cat $CONF_DIR/xrk/short_id)"] } } },
EOF
    fi
    if [ -n "$vmp" ]; then
        cat >> "$CONF_DIR/xr.json" <<EOF
    { "listen": "::", "port": ${port_vm_ws}, "protocol": "vmess", "settings": { "clients": [{ "id": "${uuid}" }] }, "streamSettings": { "network": "ws", "wsSettings": { "path": "/${uuid}-vm" } } },
EOF
    fi
    if [ -n "$vwp" ]; then
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

    # ================= SING-BOX JSON =================
    cat > "$CONF_DIR/sb.json" <<EOF
{ "log": { "level": "info" }, "inbounds": [
EOF
    if [ -n "$hyp" ] || [ -z "${vmp}${vwp}${vlp}${tup}" ]; then 
        [ -z "$port_hy2" ] && port_hy2=$(shuf -i 10000-65535 -n 1)
        echo "$port_hy2" > "$CONF_DIR/port_hy2"
        cat >> "$CONF_DIR/sb.json" <<EOF
    { "type": "hysteria2", "listen": "::", "listen_port": ${port_hy2}, "users": [{ "password": "${uuid}" }], "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CONF_DIR/cert.pem", "key_path": "$CONF_DIR/private.key" } },
EOF
    fi
    if [ -n "$tup" ]; then
        [ -z "$port_tu" ] && port_tu=$(shuf -i 10000-65535 -n 1)
        echo "$port_tu" > "$CONF_DIR/port_tu"
        cat >> "$CONF_DIR/sb.json" <<EOF
    { "type": "tuic", "listen": "::", "listen_port": ${port_tu}, "users": [{ "uuid": "${uuid}", "password": "${uuid}" }], "congestion_control": "bbr", "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CONF_DIR/cert.pem", "key_path": "$CONF_DIR/private.key" } },
EOF
    fi
    sed -i '$ s/,$//' "$CONF_DIR/sb.json"
    
    # 修复：只追加 Outbounds，不覆盖文件
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

# --- 6. 服务与输出 ---

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
    # 修复：如果 $0 是 bash (管道运行)，则从指定 URL 下载脚本作为快捷指令
    if [[ "$0" == "bash" ]] || [[ "$0" == "-bash" ]]; then
        # ⚠️ 请确保这里的 SELF_URL 变量已修改为你自己的仓库地址
        # 如果未设置，将无法生成有效的 agsbx 命令
        if [ -n "$SELF_URL" ]; then
            wget -qO "$SCRIPT_PATH" "$SELF_URL" && chmod +x "$SCRIPT_PATH"
        else
            echo "⚠️ 警告：无法创建快捷指令 (未配置下载源)，请手动保存脚本。"
        fi
    else
        # 正常运行，复制自身
        cp "$0" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
    fi
    sudo ln -sf "$SCRIPT_PATH" /usr/local/bin/agsbx
}

print_clash_meta() {
    echo ""
    echo "================ [Clash Meta / OpenClash 格式配置] ================"
    echo "proxies:"
    if [ -f "$CONF_DIR/port_vl_re" ]; then
        echo "  - name: Clean-Reality"
        echo "    type: vless"
        echo "    server: $raw_ip"
        echo "    port: $(cat $CONF_DIR/port_vl_re)"
        echo "    uuid: $uuid"
        echo "    network: tcp"
        echo "    tls: true"
        echo "    udp: true"
        echo "    flow: xtls-rprx-vision"
        echo "    servername: $(cat $CONF_DIR/ym_vl_re)"
        echo "    reality-opts:"
        echo "      public-key: $(cat $CONF_DIR/xrk/public_key)"
        echo "      short-id: $(cat $CONF_DIR/xrk/short_id)"
        echo "    client-fingerprint: chrome"
    fi
    if [ -f "$CONF_DIR/port_hy2" ]; then
        echo "  - name: Clean-Hy2"
        echo "    type: hysteria2"
        echo "    server: $raw_ip"
        echo "    port: $(cat $CONF_DIR/port_hy2)"
        echo "    password: $uuid"
        echo "    sni: www.bing.com"
        echo "    skip-cert-verify: true"
        echo "    alpn:"
        echo "      - h3"
    fi
    if [ -n "$ARGO_MODE" ] || [ -f "$CONF_DIR/port_vm_ws" ]; then
        if [ -n "$ARGO_MODE" ]; then
            if [ -z "$ARGO_AUTH" ]; then 
                SERVER_ADDR=$(journalctl -u argo-clean -n 20 --no-pager | grep -o 'https://.*\.trycloudflare\.com' | tail -n 1 | sed 's/https:\/\///')
            else 
                SERVER_ADDR="${ARGO_DOMAIN}"
            fi
            SERVER_PORT=443; IS_TLS=true; SKIP_CERT=false; ARGO_HOST="$SERVER_ADDR"
        else
            SERVER_ADDR="$raw_ip"; SERVER_PORT=$(cat $CONF_DIR/port_vm_ws); IS_TLS=false; SKIP_CERT=true; ARGO_HOST="www.bing.com"
        fi

        if [ -f "$CONF_DIR/port_vm_ws" ]; then
            echo "  - name: Clean-VMess"
            echo "    type: vmess"
            echo "    server: $SERVER_ADDR"
            echo "    port: $SERVER_PORT"
            echo "    uuid: $uuid"
            echo "    alterId: 0"
            echo "    cipher: auto"
            echo "    udp: true"
            echo "    tls: $IS_TLS"
            echo "    skip-cert-verify: $SKIP_CERT"
            echo "    network: ws"
            echo "    ws-opts:"
            echo "      path: /$uuid-vm"
            echo "      headers:"
            echo "        Host: $ARGO_HOST"
        fi
        if [ -f "$CONF_DIR/port_vw" ] && [ -n "$ARGO_MODE" ]; then
             echo "  - name: Clean-VLESS-Argo"
             echo "    type: vless"
             echo "    server: $SERVER_ADDR"
             echo "    port: $SERVER_PORT"
             echo "    uuid: $uuid"
             echo "    udp: true"
             echo "    tls: true"
             echo "    network: ws"
             echo "    ws-opts:"
             echo "      path: /$uuid-vw"
             echo "      headers:"
             echo "        Host: $ARGO_HOST"
        fi
    fi
    echo "==================================================================="
}

cmd_list() {
    [ ! -f "$CONF_DIR/uuid" ] && { echo "❌ 请先安装"; exit 1; }
    get_ip
    uuid=$(cat "$CONF_DIR/uuid")
    echo ""
    echo "================ [Argosbx 净化版 v2.8] ================"
    echo "  UUID: $uuid"
    echo "  IP:   $server_ip"
    [ -n "$WARP_MODE" ] && echo "  WARP: ✅ 开启"
    if [ -n "$ARGO_MODE" ]; then
        echo "  Argo: ✅ 开启 ($ARGO_MODE)"
        if [ -z "$ARGO_AUTH" ]; then
            ARGO_URL=$(journalctl -u argo-clean -n 20 --no-pager | grep -o 'https://.*\.trycloudflare\.com' | tail -n 1)
            echo "  域名: ${ARGO_URL:-获取中...}"
        else
            echo "  域名: ${ARGO_DOMAIN:-固定隧道}"
        fi
    fi
    echo "------------------------ [v2rayN / 标准链接] ------------------------"
    [ -f "$CONF_DIR/port_vl_re" ] && echo "🔥 [Reality] vless://$uuid@$server_ip:$(cat $CONF_DIR/port_vl_re)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(cat $CONF_DIR/ym_vl_re)&fp=chrome&pbk=$(cat $CONF_DIR/xrk/public_key)&sid=$(cat $CONF_DIR/xrk/short_id)&type=tcp&headerType=none#Clean-Reality"
    [ -f "$CONF_DIR/port_hy2" ] && echo "🚀 [Hysteria2] hysteria2://$uuid@$server_ip:$(cat $CONF_DIR/port_hy2)?security=tls&alpn=h3&insecure=1&sni=www.bing.com#Clean-Hy2"
    if [ -f "$CONF_DIR/port_vm_ws" ]; then
       if [ -n "$ARGO_MODE" ]; then
          HOST_ADDR=${ARGO_URL:-$ARGO_DOMAIN}
          HOST_ADDR=$(echo $HOST_ADDR | sed 's/https:\/\///')
          # 修复 JSON 格式 (正确转义)
          vm_json="{\"v\":\"2\",\"ps\":\"Clean-VMess-Argo\",\"add\":\"$HOST_ADDR\",\"port\":\"443\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$HOST_ADDR\",\"path\":\"/$uuid-vm\",\"tls\":\"tls\",\"sni\":\"$HOST_ADDR\"}"
       else
          vm_json="{\"v\":\"2\",\"ps\":\"Clean-VMess\",\"add\":\"$server_ip\",\"port\":\"$(cat $CONF_DIR/port_vm_ws)\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"www.bing.com\",\"path\":\"/$uuid-vm\",\"tls\":\"\"}"
       fi
       echo "🌀 [VMess] vmess://$(echo -n "$vm_json" | base64 -w 0)"
    fi
    print_clash_meta
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
        echo ">>> 开始安装 Argosbx 净化版 v2.8..."
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
