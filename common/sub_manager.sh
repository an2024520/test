#!/bin/bash
echo "v3.7"
sleep 3
# ============================================================
#  Universal Subscription Manager (通用订阅管理器) v3.7
#  - 修复: Python 服务增加 IPv6 自动降级支持 (解决 IPv6 Only 启动崩溃问题)
#  - 修复: 强制补全 net-tools 依赖
#  - 核心: Token 持久化 + 端口暴力清理 + 优先读配置
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# ============================================================
# 0. 预检与配置加载
# ============================================================
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# [修复] 检查并安装必要依赖
echo -e "${YELLOW}>>> 正在检查系统依赖...${PLAIN}"
if ! command -v python3 &> /dev/null; then apt-get update && apt-get install -y python3; fi
if ! command -v curl &> /dev/null; then apt-get install -y curl; fi
if ! command -v netstat &> /dev/null; then 
    echo -e "${YELLOW}安装 net-tools (用于端口检测)...${PLAIN}"
    apt-get install -y net-tools
fi

# --- 通用默认配置 ---
SCAN_PATHS=("/root" "/usr/local/etc")
BASE_DIR="/root/sub_store"              
TUNNEL_CFG="/etc/cloudflared/config.yml"
LOCAL_PORT=8080
CONFIG_FILE="/root/.sub_manager_config" 

# 优先读取配置文件中的 TOKEN
if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE"; fi

# 辅助函数: 保存配置到文件
save_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then touch "$CONFIG_FILE"; fi
    
    if grep -q "SUB_TOKEN=" "$CONFIG_FILE"; then
        sed -i "s|^SUB_TOKEN=.*|SUB_TOKEN=\"$SUB_TOKEN\"|" "$CONFIG_FILE"
    else
        echo "SUB_TOKEN=\"$SUB_TOKEN\"" >> "$CONFIG_FILE"
    fi

    if [[ -n "$ARGO_DOMAIN" ]]; then
        if grep -q "ARGO_DOMAIN=" "$CONFIG_FILE"; then
            sed -i "s|^ARGO_DOMAIN=.*|ARGO_DOMAIN=\"$ARGO_DOMAIN\"|" "$CONFIG_FILE"
        else
            echo "ARGO_DOMAIN=\"$ARGO_DOMAIN\"" >> "$CONFIG_FILE"
        fi
    fi

    if [[ -n "$SAVED_WORKER_URL" ]]; then
        if grep -q "SAVED_WORKER_URL=" "$CONFIG_FILE"; then
            sed -i "s|^SAVED_WORKER_URL=.*|SAVED_WORKER_URL=\"$SAVED_WORKER_URL\"|" "$CONFIG_FILE"
        else
            echo "SAVED_WORKER_URL=\"$SAVED_WORKER_URL\"" >> "$CONFIG_FILE"
        fi
        if grep -q "SAVED_WORKER_SECRET=" "$CONFIG_FILE"; then
            sed -i "s|^SAVED_WORKER_SECRET=.*|SAVED_WORKER_SECRET=\"$SAVED_WORKER_SECRET\"|" "$CONFIG_FILE"
        else
            echo "SAVED_WORKER_SECRET=\"$SAVED_WORKER_SECRET\"" >> "$CONFIG_FILE"
        fi
    fi
}

# ============================================================
# 1. Python 核心: 全协议解析引擎
# ============================================================
generate_converter_py() {
    cat > /tmp/sub_converter.py <<'EOF'
import sys
import json
import base64
import re
import urllib.parse
import os

class ProxyConverter:
    @staticmethod
    def safe_base64_decode(s):
        s = s.strip()
        missing_padding = len(s) % 4
        if missing_padding: s += '=' * (4 - missing_padding)
        return base64.b64decode(s.replace('-', '+').replace('_', '/')).decode('utf-8', errors='ignore')

    @staticmethod
    def parse_vmess(link):
        try:
            raw = ProxyConverter.safe_base64_decode(link[8:])
            data = json.loads(raw)
            return {
                "type": "vmess",
                "name": data.get("ps", "unnamed"),
                "server": data.get("add"),
                "port": int(data.get("port")),
                "uuid": data.get("id"),
                "alterId": int(data.get("aid", 0)),
                "cipher": "auto",
                "tls": True if data.get("tls") == "tls" else False,
                "servername": data.get("sni", data.get("host", "")),
                "network": data.get("net", "tcp"),
                "ws-opts": {"path": data.get("path", "/"), "headers": {"Host": data.get("host", "")}} if data.get("net") == "ws" else None,
                "skip-cert-verify": True,
                "udp": True
            }
        except: return None

    @staticmethod
    def parse_vless(link):
        try:
            pattern = r'vless://([^@]+)@([^:]+):(\d+)\?(.+)#(.*)'
            match = re.match(pattern, link)
            if not match: return None
            uuid, host, port, params_str, name = match.groups()
            params = dict(urllib.parse.parse_qsl(params_str))
            
            node = {
                "type": "vless",
                "name": urllib.parse.unquote(name).strip(),
                "server": host,
                "port": int(port),
                "uuid": uuid,
                "network": params.get("type", "tcp"),
                "tls": True if params.get("security") in ["tls", "reality"] else False,
                "servername": params.get("sni", ""),
                "flow": params.get("flow", ""),
                "client-fingerprint": params.get("fp", "chrome"),
                "skip-cert-verify": True,
                "udp": True
            }
            if params.get("security") == "reality":
                node["reality-opts"] = {"public-key": params.get("pbk"), "short-id": params.get("sid")}
            if node["network"] == "ws":
                node["ws-opts"] = {"path": params.get("path", "/"), "headers": {"Host": params.get("host", "")}}
            return node
        except: return None

    @staticmethod
    def parse_hy2(link):
        try:
            pattern = r'hysteria2://([^@]+)@([^:]+):(\d+)\?(.+)#(.*)'
            match = re.match(pattern, link)
            if not match: return None
            auth, host, port, params_str, name = match.groups()
            params = dict(urllib.parse.parse_qsl(params_str))
            
            node = {
                "type": "hysteria2",
                "name": urllib.parse.unquote(name).strip(),
                "server": host,
                "port": int(port),
                "password": auth,
                "sni": params.get("sni", host),
                "skip-cert-verify": True,
                "obfs": params.get("obfs", ""),
                "obfs-password": params.get("obfs-password", ""),
                "fingerprint": params.get("fp", "chrome"),
                "udp": True
            }
            if params.get("up_mbps"): node["up"] = f"{params.get('up_mbps')} Mbps"
            if params.get("down_mbps"): node["down"] = f"{params.get('down_mbps')} Mbps"
            return node
        except: return None
        
    @staticmethod
    def parse_trojan(link):
        try:
            pattern = r'trojan://([^@]+)@([^:]+):(\d+)\?(.+)#(.*)'
            match = re.match(pattern, link)
            if not match: return None
            password, host, port, params_str, name = match.groups()
            params = dict(urllib.parse.parse_qsl(params_str))
            return {
                "type": "trojan",
                "name": urllib.parse.unquote(name).strip(),
                "server": host,
                "port": int(port),
                "password": password,
                "sni": params.get("sni", ""),
                "skip-cert-verify": True,
                "udp": True
            }
        except: return None

def generate_clash_local(nodes):
    yaml = "mixed-port: 7890\nallow-lan: true\nmode: rule\nlog-level: info\nproxies:\n"
    names = []
    for n in nodes:
        names.append(n['name'])
        yaml += f"  - name: \"{n['name']}\"\n    type: {n['type']}\n    server: {n['server']}\n    port: {n['port']}\n"
        if 'uuid' in n: yaml += f"    uuid: {n['uuid']}\n"
        if 'password' in n: yaml += f"    password: {n['password']}\n"
        if n.get('tls'): yaml += "    tls: true\n"
        if n.get('client-fingerprint'): yaml += f"    client-fingerprint: {n['client-fingerprint']}\n"
        if n.get('fingerprint'): yaml += f"    fingerprint: {n['fingerprint']}\n"
    
    yaml += "\nproxy-groups:\n  - name: '🚀 Proxy'\n    type: select\n    proxies:\n      - DIRECT\n"
    for name in names: yaml += f"      - \"{name}\"\n"
    yaml += "\nrules:\n  - MATCH, 🚀 Proxy\n"
    return yaml

def main():
    infile = sys.argv[1]
    outdir = sys.argv[2]
    
    nodes = []
    raw_links = []
    
    protocols = ["vmess://", "vless://", "hysteria2://", "hy2://", "trojan://", "ss://"]

    with open(infile, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"): continue
            
            clean_link = None
            for p in protocols:
                idx = line.find(p)
                if idx != -1:
                    clean_link = line[idx:].strip()
                    break
            
            if not clean_link: continue

            raw_links.append(clean_link)
            
            node = None
            if clean_link.startswith("vmess://"): node = ProxyConverter.parse_vmess(clean_link)
            elif clean_link.startswith("vless://"): node = ProxyConverter.parse_vless(clean_link)
            elif clean_link.startswith("hysteria2://") or clean_link.startswith("hy2://"): node = ProxyConverter.parse_hy2(clean_link)
            elif clean_link.startswith("trojan://"): node = ProxyConverter.parse_trojan(clean_link)
            
            if node: nodes.append(node)

    if not nodes:
        print("Error: No valid nodes found")
        sys.exit(1)

    with open(os.path.join(outdir, "v2ray.txt"), "wb") as f:
        f.write(base64.b64encode("\n".join(raw_links).encode('utf-8')))

    with open(os.path.join(outdir, "clash.yaml"), "w", encoding='utf-8') as f:
        f.write(generate_clash_local(nodes))
        
    worker_payload = {"nodes": nodes}
    with open(os.path.join(outdir, "worker_payload.json"), "w", encoding='utf-8') as f:
        json.dump(worker_payload, f, ensure_ascii=False)

    print(f"Success: Processed {len(nodes)} nodes.")

if __name__ == "__main__":
    main()
EOF
}

# ============================================================
# 2. Python Server (IPv6 增强版) & 3. 功能函数
# ============================================================
generate_server_py() {
    cat > /usr/local/bin/sub_server.py <<EOF
import http.server
import socketserver
import os
import socket

PORT = $LOCAL_PORT
TOKEN = "$SUB_TOKEN"
BASE_DIR = "$BASE_DIR"
ARGO_DOMAIN = "$ARGO_DOMAIN"

class AutoHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.strip('/') == TOKEN:
            self.send_response(200)
            ua = self.headers.get('User-Agent', '').lower()
            if "clash" in ua:
                self.serve_file("clash.yaml", "text/yaml; charset=utf-8")
                return
            if "mozilla" in ua and "go-http" not in ua:
                self.serve_html()
                return
            self.serve_file("v2ray.txt", "text/plain; charset=utf-8")
            return
        super().do_GET()

    def serve_file(self, filename, content_type):
        file_path = os.path.join(BASE_DIR, TOKEN, filename)
        try:
            with open(file_path, 'rb') as f:
                content = f.read()
            self.send_header("Content-type", content_type)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        except:
            self.send_error(404, "File not found")

    def serve_html(self):
        html = f"""
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>本地订阅服务</title>
<style>
body {{ background: #111; color: #eee; font-family: sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }}
.card {{ background: #222; padding: 20px; border-radius: 12px; width: 320px; text-align: center; box-shadow: 0 4px 15px rgba(0,0,0,0.5); }}
h3 {{ color: #38bdf8; margin-top: 0; }}
.url {{ word-break: break-all; font-family: monospace; font-size: 12px; color: #aaa; margin: 15px 0; background: #333; padding: 10px; border-radius: 5px; border: 1px dashed #555; }}
p {{ font-size: 12px; color: #666; margin-bottom: 0; }}
</style>
</head>
<body>
<div class="card">
    <h3>📂 临时订阅分发</h3>
    <div class="url">https://{ARGO_DOMAIN}/{TOKEN}</div>
    <p>支持自动识别 Clash / v2rayN 客户端</p>
</div>
</body>
</html>
"""
        self.send_header("Content-type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(html.encode('utf-8'))))
        self.end_headers()
        self.wfile.write(html.encode('utf-8'))

# [修复] 适配 IPv6 的服务器类
class DualStackServer(socketserver.TCPServer):
    address_family = socket.AF_INET6
    allow_reuse_address = True

os.chdir(BASE_DIR)

# [修复] 启动逻辑: 优先尝试 IPv4, 失败(如 IPv6 Only)则切换到 IPv6
try:
    with socketserver.TCPServer(("", PORT), AutoHandler) as httpd:
        httpd.serve_forever()
except OSError:
    try:
        # IPv6 Fallback
        with DualStackServer(("", PORT), AutoHandler) as httpd:
            httpd.serve_forever()
    except Exception as e:
        print(f"CRITICAL ERROR: Server failed to start: {e}")
        exit(1)
EOF
}

scan_and_select() {
    echo -e "${YELLOW}>>> 正在扫描本地节点文件 (.txt)...${PLAIN}"
    local files=()
    local i=1
    while IFS= read -r file; do
        files+=("$file")
        echo -e "$i. ${SKYBLUE}$file${PLAIN}"
        ((i++))
    done < <(find "${SCAN_PATHS[@]}" -maxdepth 3 -name "*.txt" -type f -exec grep -l -E "vmess://|vless://|hysteria2://" {} + 2>/dev/null)

    if [ ${#files[@]} -eq 0 ]; then echo -e "${RED}未找到任何节点文件！${PLAIN}"; return 1; fi

    read -p "请选择文件编号 [1-${#files[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#files[@]} ]; then
        SELECTED_FILE="${files[$((choice-1))]}"
        echo -e "已选: ${GREEN}$SELECTED_FILE${PLAIN}"
        return 0
    fi
    return 1
}

process_subs() {
    if [[ -z "$SUB_TOKEN" ]]; then
        echo -e "\n${YELLOW}>>> Token 配置 (配合 Cloudflare Tunnel 网页端路径)${PLAIN}"
        read -p "请输入自定义 Token (留空则随机生成): " input_token
        if [[ -n "$input_token" ]]; then
            SUB_TOKEN="$input_token"
            echo -e "使用自定义 Token: ${GREEN}$SUB_TOKEN${PLAIN}"
        else
            SUB_TOKEN=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 12 | head -n 1)
            echo -e "生成随机 Token: ${GREEN}$SUB_TOKEN${PLAIN}"
        fi
    fi
    
    save_config
    
    local target_dir="${BASE_DIR}/${SUB_TOKEN}"
    mkdir -p "$target_dir"
    echo -e "${YELLOW}>>> 正在解析节点并生成配置...${PLAIN}"
    generate_converter_py
    python3 /tmp/sub_converter.py "$SELECTED_FILE" "$target_dir"
    if [ $? -eq 0 ]; then echo -e "${GREEN}>>> 转换完成！数据已就绪。${PLAIN}"; else echo -e "${RED}>>> 转换失败！${PLAIN}"; return 1; fi
}

push_worker() {
    local payload_file="${BASE_DIR}/${SUB_TOKEN}/worker_payload.json"
    if [[ ! -f "$payload_file" ]]; then echo -e "${RED}请先执行步骤 2 进行转换！${PLAIN}"; return; fi
    
    if [[ -z "$SAVED_WORKER_URL" ]]; then
        read -p "请输入 Worker URL (不带 /sub): " SAVED_WORKER_URL
        read -p "请输入 Worker Secret: " SAVED_WORKER_SECRET
    else
        echo -e "使用已保存 Worker: ${SKYBLUE}$SAVED_WORKER_URL${PLAIN}"
        read -p "是否修改配置? [y/N]: " change
        if [[ "$change" == "y" ]]; then
             read -p "新 Worker URL: " SAVED_WORKER_URL
             read -p "新 Secret: " SAVED_WORKER_SECRET
        fi
    fi
    save_config
    
    echo -e "${YELLOW}>>> 正在推送到云端...${PLAIN}"
    status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${SAVED_WORKER_URL}/update" \
        -H "Content-Type: application/json" -H "Authorization: ${SAVED_WORKER_SECRET}" -d @"$payload_file")
    if [[ "$status" == "200" ]]; then echo -e "${GREEN}>>> 推送成功！${PLAIN}"; echo -e "订阅地址: ${SKYBLUE}${SAVED_WORKER_URL}/sub${PLAIN}"; else echo -e "${RED}>>> 推送失败 (HTTP $status)${PLAIN}"; fi
}

start_local_web() {
    if [[ -z "$ARGO_DOMAIN" ]]; then 
        read -p "请输入 Argo 域名: " ARGO_DOMAIN
        save_config
    fi
    
    echo -e "${YELLOW}>>> 正在准备服务环境...${PLAIN}"
    pkill -f "sub_server.py" >/dev/null 2>&1
    
    # 端口清理
    if command -v fuser &>/dev/null; then
        fuser -k -n tcp "$LOCAL_PORT" >/dev/null 2>&1
    else
        pid=$(netstat -tulpn 2>/dev/null | grep ":$LOCAL_PORT " | grep "python" | awk '{print $7}' | cut -d'/' -f1)
        if [[ -n "$pid" ]]; then kill -9 "$pid"; fi
    fi
    sleep 1

    if [[ -f "$TUNNEL_CFG" ]]; then
        if ! grep -q "path: /$SUB_TOKEN" "$TUNNEL_CFG"; then
            sed -i "/^ingress:/a \\  - hostname: $ARGO_DOMAIN\\n    path: /$SUB_TOKEN\\n    service: http://localhost:$LOCAL_PORT" "$TUNNEL_CFG"
            systemctl restart cloudflared >/dev/null 2>&1
            echo -e "${GREEN}>>> (本地配置模式) Tunnel 规则已更新。${PLAIN}"
        fi
    fi
    
    generate_server_py
    
    read -p "开启时长(分钟, 默认60): " min
    min=${min:-60}
    
    echo -e "${YELLOW}>>> 正在启动新服务 (Token: $SUB_TOKEN)...${PLAIN}"
    # 移除 >/dev/null 来让用户在必要时看到崩溃信息 (但为了后台运行仍保留 &)
    (timeout "${min}m" python3 /usr/local/bin/sub_server.py >/dev/null 2>&1 &)
    
    sleep 2
    # 检测逻辑：只要端口有 Python 监听就算成功 (IPv4 或 IPv6)
    if netstat -tulpn 2>/dev/null | grep -q ":$LOCAL_PORT "; then
        echo -e "${GREEN}>>> 服务启动成功！${PLAIN}"
        echo -e "访问地址: ${SKYBLUE}https://${ARGO_DOMAIN}/${SUB_TOKEN}${PLAIN}"
    else
        echo -e "${RED}>>> 错误: 服务启动失败！${PLAIN}"
        echo -e "${YELLOW}>>> 请运行以下命令手动查看报错信息:${PLAIN}"
        echo -e "python3 /usr/local/bin/sub_server.py"
    fi
}

menu() {
    clear
    echo -e "  ${GREEN}通用订阅管理器 (Sub-Manager Smart v3.7)${PLAIN}"
    echo -e "--------------------------------"
    echo -e "当前文件: ${SKYBLUE}${SELECTED_FILE:-未选择}${PLAIN}"
    echo -e "当前Token: ${YELLOW}${SUB_TOKEN:-未设置}${PLAIN}"
    echo -e "云端配置: ${SAVED_WORKER_URL:-未设置}"
    echo -e "--------------------------------"
    echo -e "  1. 扫描并选择节点文件"
    echo -e "  2. 执行转换 (生成/使用固定 Token)"
    echo -e "  3. ${GREEN}方案 A${PLAIN}: 推送 Worker (双轨分发)"
    echo -e "  4. ${SKYBLUE}方案 B${PLAIN}: 本地 Web 分享"
    echo -e "  5. 修改/重置 Token"
    echo -e "  0. 退出"
    echo -e "--------------------------------"
    read -p "请选择: " opt
    case "$opt" in
        1) scan_and_select ;;
        2) if [[ -z "$SELECTED_FILE" ]]; then scan_and_select; fi; process_subs ;;
        3) push_worker ;;
        4) start_local_web ;;
        5) SUB_TOKEN=""; process_subs ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
    read -p "按回车继续..."
    menu
}
menu