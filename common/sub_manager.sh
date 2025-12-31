#!/bin/bash

# ============================================================
#  Universal Subscription Manager (通用订阅管理器) v2.0
#  - 核心: 集成 converter_pro.py (OpenClash 专用验证版)
#  - 架构: Bash 管理 + Python 转换核心
#  - 功能: 扫描文件 -> 转换 Clash(Pro)/V2Ray -> Web UI / Worker
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 默认扫描路径
SCAN_PATHS=("/root" "/usr/local/etc")
# 默认配置目录
BASE_DIR="/root/icmp9_subs"
# Tunnel 配置文件
TUNNEL_CFG="/etc/cloudflared/config.yml"
# 本地服务端口
LOCAL_PORT=8080

# ============================================================
# 1. Python 核心: 格式转换引擎 (移植自 converter_pro.py)
# ============================================================
generate_converter_py() {
    cat > /tmp/sub_converter.py <<'EOF'
import sys
import json
import base64
import re
import urllib.parse
import os

# 复用 converter_pro.py 的核心解析类
class ProxyConverter:
    @staticmethod
    def safe_base64_decode(s):
        s = s.strip()
        missing_padding = len(s) % 4
        if missing_padding:
            s += '=' * (4 - missing_padding)
        s = s.replace('-', '+').replace('_', '/')
        return base64.b64decode(s).decode('utf-8', errors='ignore')

    @staticmethod
    def parse_vmess(link):
        try:
            raw = ProxyConverter.safe_base64_decode(link[8:])
            data = json.loads(raw)
            node = {
                "name": data.get("ps", "VMess_Node"),
                "type": "vmess",
                "server": data.get("add"),
                "port": int(data.get("port")),
                "uuid": data.get("id"),
                "alterId": int(data.get("aid", 0)),
                "cipher": "auto",
                "tls": True if data.get("tls") == "tls" else False,
                "skip-cert-verify": True,
                "udp": True
            }
            if node["tls"]:
                node["servername"] = data.get("sni", data.get("host", ""))
            
            net = data.get("net", "tcp")
            node["network"] = net
            
            if net == "ws":
                node["ws-opts"] = {
                    "path": data.get("path", "/"),
                    "headers": {"Host": data.get("host", "")}
                }
            elif net == "grpc":
                node["grpc-opts"] = {
                    "grpc-service-name": data.get("path", "")
                }
            return node
        except:
            return None

    @staticmethod
    def parse_vless(link):
        try:
            # vless://uuid@host:port?params#name
            pattern = r'vless://([^@]+)@([^:]+):(\d+)\?(.+)#(.*)'
            match = re.match(pattern, link)
            if not match: return None
            
            uuid, host, port, params_str, name = match.groups()
            params = dict(urllib.parse.parse_qsl(params_str))
            
            node = {
                "name": urllib.parse.unquote(name).strip(),
                "type": "vless",
                "server": host,
                "port": int(port),
                "uuid": uuid,
                "cipher": "auto",
                "udp": True,
                "skip-cert-verify": True
            }

            # Flow (Vision)
            if params.get("flow"):
                node["flow"] = params.get("flow")

            # TLS / Reality
            security = params.get("security", "")
            if security == "tls":
                node["tls"] = True
                node["servername"] = params.get("sni", "")
            elif security == "reality":
                node["tls"] = True
                node["servername"] = params.get("sni", "")
                node["reality-opts"] = {
                    "public-key": params.get("pbk"),
                    "short-id": params.get("sid")
                }
                if params.get("fp"):
                    node["client-fingerprint"] = params.get("fp")

            # Network
            net = params.get("type", "tcp")
            node["network"] = net
            
            if net == "ws":
                node["ws-opts"] = {
                    "path": params.get("path", "/"),
                    "headers": {"Host": params.get("host", "")}
                }
            elif net == "grpc":
                node["grpc-opts"] = {
                    "grpc-service-name": params.get("serviceName", "")
                }
            return node
        except:
            return None

    @staticmethod
    def parse_hy2(link):
        try:
            # hysteria2://password@host:port?params#name
            pattern = r'hysteria2://([^@]+)@([^:]+):(\d+)\?(.+)#(.*)'
            match = re.match(pattern, link)
            if not match: return None
            
            auth, host, port, params_str, name = match.groups()
            params = dict(urllib.parse.parse_qsl(params_str))
            
            node = {
                "name": urllib.parse.unquote(name).strip(),
                "type": "hysteria2",
                "server": host,
                "port": int(port),
                "password": auth,
                "sni": params.get("sni", host),
                "skip-cert-verify": True
            }
            if params.get("obfs") == "salamander":
                node["obfs"] = "salamander"
                node["obfs-password"] = params.get("obfs-password", "")
            return node
        except:
            return None

    @staticmethod
    def parse_trojan(link):
        try:
            pattern = r'trojan://([^@]+)@([^:]+):(\d+)\?(.+)#(.*)'
            match = re.match(pattern, link)
            if not match: return None
            
            password, host, port, params_str, name = match.groups()
            params = dict(urllib.parse.parse_qsl(params_str))
            
            node = {
                "name": urllib.parse.unquote(name).strip(),
                "type": "trojan",
                "server": host,
                "port": int(port),
                "password": password,
                "skip-cert-verify": True,
                "udp": True,
                "sni": params.get("sni", "")
            }
            return node
        except:
            return None
            
    @staticmethod
    def parse_ss(link):
        try:
            # ss://base64#name
            base = link.replace("ss://", "").split("#")
            raw_info = ProxyConverter.safe_base64_decode(base[0])
            method, rest = raw_info.split(":", 1)
            password, server_port = rest.split("@")
            server, port = server_port.split(":")
            
            node = {
                "name": urllib.parse.unquote(base[1]) if len(base)>1 else "SS_Node",
                "type": "ss",
                "server": server,
                "port": int(port),
                "cipher": method,
                "password": password,
                "udp": True
            }
            return node
        except:
            return None

def generate_openclash_yaml(nodes, group_name="🚀 Proxy"):
    # 手动生成 YAML，避免依赖 pyyaml 库
    f_content = "mixed-port: 7890\nallow-lan: true\nmode: rule\nlog-level: info\nproxies:\n"
    
    for p in nodes:
        f_content += f"  - name: \"{p['name']}\"\n"
        f_content += f"    type: {p['type']}\n"
        f_content += f"    server: {p['server']}\n"
        f_content += f"    port: {p['port']}\n"
        
        if 'uuid' in p: f_content += f"    uuid: {p['uuid']}\n"
        if 'alterId' in p: f_content += f"    alterId: {p['alterId']}\n"
        if 'cipher' in p: f_content += f"    cipher: {p['cipher']}\n"
        if 'password' in p: f_content += f"    password: {p['password']}\n"
        if 'tls' in p: f_content += f"    tls: {str(p['tls']).lower()}\n"
        if 'skip-cert-verify' in p: f_content += f"    skip-cert-verify: {str(p['skip-cert-verify']).lower()}\n"
        if 'udp' in p: f_content += f"    udp: {str(p['udp']).lower()}\n"
        if 'servername' in p: f_content += f"    servername: {p['servername']}\n"
        if 'sni' in p: f_content += f"    sni: {p['sni']}\n"
        if 'network' in p: f_content += f"    network: {p['network']}\n"
        if 'flow' in p: f_content += f"    flow: {p['flow']}\n"
        if 'client-fingerprint' in p: f_content += f"    client-fingerprint: {p['client-fingerprint']}\n"

        # Reality Opts
        if 'reality-opts' in p:
            f_content += "    reality-opts:\n"
            f_content += f"      public-key: {p['reality-opts']['public-key']}\n"
            f_content += f"      short-id: {p['reality-opts']['short-id']}\n"
            
        # WS Opts
        if 'ws-opts' in p:
            f_content += "    ws-opts:\n"
            f_content += f"      path: {p['ws-opts']['path']}\n"
            if 'headers' in p['ws-opts']:
                f_content += "      headers:\n"
                f_content += f"        Host: {p['ws-opts']['headers']['Host']}\n"
        
        # GRPC Opts
        if 'grpc-opts' in p:
            f_content += "    grpc-opts:\n"
            f_content += f"      grpc-service-name: {p['grpc-opts']['grpc-service-name']}\n"

        # Hysteria2 Obfs
        if 'obfs' in p:
            f_content += f"    obfs: {p['obfs']}\n"
            f_content += f"    obfs-password: {p['obfs-password']}\n"
            
    # Proxy Groups
    f_content += "\nproxy-groups:\n"
    f_content += f"  - name: \"{group_name}\"\n"
    f_content += "    type: select\n"
    f_content += "    proxies:\n"
    
    seen = set()
    for p in nodes:
        n = p['name']
        if n not in seen:
            safe_name = n.replace('"', '\\"')
            f_content += f"      - \"{safe_name}\"\n"
            seen.add(n)
            
    f_content += "\nrules:\n  - MATCH, " + group_name + "\n"
    return f_content

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 script.py <input_file> <output_dir>")
        sys.exit(1)

    infile = sys.argv[1]
    outdir = sys.argv[2]
    
    nodes = []
    raw_links = []
    
    with open(infile, 'r', encoding='utf-8') as f:
        for line in f:
            link = line.strip()
            if not link or link.startswith("#"): continue
            raw_links.append(link)
            
            node = None
            if link.startswith("vmess://"): node = ProxyConverter.parse_vmess(link)
            elif link.startswith("vless://"): node = ProxyConverter.parse_vless(link)
            elif link.startswith("hysteria2://") or link.startswith("hy2://"): node = ProxyConverter.parse_hy2(link)
            elif link.startswith("trojan://"): node = ProxyConverter.parse_trojan(link)
            elif link.startswith("ss://"): node = ProxyConverter.parse_ss(link)
            
            if node: nodes.append(node)

    if not nodes:
        print("Error: No valid nodes found")
        sys.exit(1)

    # 1. Output V2Ray Base64 (纯文本链接列表转 Base64)
    with open(os.path.join(outdir, "v2ray.txt"), "wb") as f:
        f.write(base64.b64encode("\n".join(raw_links).encode('utf-8')))

    # 2. Output OpenClash YAML (使用你的验证过的逻辑)
    with open(os.path.join(outdir, "clash.yaml"), "w", encoding='utf-8') as f:
        f.write(generate_openclash_yaml(nodes))
        
    # 3. Output Worker Payload JSON (复用解析好的字典结构)
    # 这确保了 Worker 接收到的数据结构和 OpenClash 是一致的
    worker_payload = {"nodes": nodes}
    with open(os.path.join(outdir, "worker_payload.json"), "w", encoding='utf-8') as f:
        json.dump(worker_payload, f, ensure_ascii=False)
        
    # 4. Sing-box (可选，保留基础支持)
    # 暂时输出空文件或简单结构，避免报错
    with open(os.path.join(outdir, "singbox_outbounds.json"), "w", encoding='utf-8') as f:
        f.write("{}")

    print(f"Success: Processed {len(nodes)} nodes.")

if __name__ == "__main__":
    main()
EOF
}

# ============================================================
# 2. Python Server: Web UI (方案B核心)
# ============================================================
generate_server_py() {
    cat > /usr/local/bin/icmp9_server.py <<EOF
import http.server
import socketserver
import os

PORT = $LOCAL_PORT
TOKEN = "$SUB_TOKEN"
BASE_DIR = "$BASE_DIR"
ARGO_DOMAIN = "$ARGO_DOMAIN"

class AutoHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        # 允许 /TOKEN 或 /TOKEN/
        if self.path.strip('/') == TOKEN:
            self.send_response(200)
            ua = self.headers.get('User-Agent', '').lower()
            
            # API 适配
            if "clash" in ua:
                self.serve_file("clash.yaml", "text/yaml; charset=utf-8")
                return
            
            # 浏览器适配
            if "mozilla" in ua and "go-http" not in ua:
                self.serve_html()
                return

            # 默认适配
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
<title>ICMP9 订阅中心</title>
<style>
:root {{ --bg: #111; --text: #eee; --accent: #007bff; }}
body {{ background: var(--bg); color: var(--text); font-family: sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; margin: 0; }}
.card {{ background: #222; padding: 20px; border-radius: 12px; width: 90%; max-width: 400px; text-align: center; box-shadow: 0 4px 15px rgba(0,0,0,0.5); }}
input, select, button {{ width: 100%; padding: 10px; margin-top: 10px; box-sizing: border-box; border-radius: 6px; border: 1px solid #444; background: #333; color: white; }}
button {{ background: var(--accent); border: none; font-weight: bold; cursor: pointer; }}
.url {{ word-break: break-all; font-family: monospace; font-size: 12px; color: #aaa; margin: 10px 0; }}
</style>
</head>
<body>
<div class="card">
    <h3>🚀 OpenClash 订阅</h3>
    <div class="url">https://{ARGO_DOMAIN}/{TOKEN}</div>
    <select id="fmt">
        <option value="clash.yaml">Clash (YAML)</option>
        <option value="v2ray.txt">V2Ray (Base64)</option>
    </select>
    <button onclick="go()">打开/下载</button>
</div>
<script>
function go() {{ window.location.href = window.location.pathname.replace(/\/$/, '') + '/' + document.getElementById('fmt').value; }}
</script>
</body>
</html>
"""
        self.send_header("Content-type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(html.encode('utf-8'))))
        self.end_headers()
        self.wfile.write(html.encode('utf-8'))

os.chdir(BASE_DIR)
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", PORT), AutoHandler) as httpd:
    httpd.serve_forever()
EOF
}

# ============================================================
# 3. 功能函数
# ============================================================

# 扫描并选择节点文件
scan_and_select() {
    echo -e "${YELLOW}>>> 正在扫描本地节点文件 (.txt)...${PLAIN}"
    local files=()
    local i=1
    
    # 查找包含 vmess:// 或 vless:// 的 .txt 文件
    while IFS= read -r file; do
        files+=("$file")
        echo -e "$i. ${SKYBLUE}$file${PLAIN}"
        ((i++))
    done < <(find "${SCAN_PATHS[@]}" -maxdepth 3 -name "*.txt" -type f -exec grep -l -E "vmess://|vless://" {} + 2>/dev/null)

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}未找到任何节点文件！${PLAIN}"
        return 1
    fi

    read -p "请选择文件编号 [1-${#files[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#files[@]} ]; then
        SELECTED_FILE="${files[$((choice-1))]}"
        echo -e "已选: ${GREEN}$SELECTED_FILE${PLAIN}"
        return 0
    fi
    return 1
}

# 转换处理
process_subs() {
    # 1. 确保有 Token
    if [[ -z "$SUB_TOKEN" ]]; then
        SUB_TOKEN=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 12 | head -n 1)
        echo -e "生成新 Token: ${GREEN}$SUB_TOKEN${PLAIN}"
    fi
    
    # 2. 准备目录
    local target_dir="${BASE_DIR}/${SUB_TOKEN}"
    mkdir -p "$target_dir"
    
    # 3. 调用 Python 转换
    echo -e "${YELLOW}>>> 正在转换订阅格式 (Clash/OpenClash)...${PLAIN}"
    generate_converter_py
    python3 /tmp/sub_converter.py "$SELECTED_FILE" "$target_dir"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}>>> 转换完成！文件已存入: $target_dir${PLAIN}"
    else
        echo -e "${RED}>>> 转换失败！请检查源文件格式。${PLAIN}"
        return 1
    fi
}

# 方案 A: 推送 Worker
push_worker() {
    local payload_file="${BASE_DIR}/${SUB_TOKEN}/worker_payload.json"
    if [[ ! -f "$payload_file" ]]; then echo -e "${RED}请先执行转换！${PLAIN}"; return; fi
    
    read -p "Worker URL: " url
    read -p "Worker Secret: " sec
    
    echo -e "${YELLOW}>>> 推送中...${PLAIN}"
    status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${url}/update" \
        -H "Content-Type: application/json" \
        -H "Authorization: ${sec}" \
        -d @"$payload_file")
        
    if [[ "$status" == "200" ]]; then
        echo -e "${GREEN}>>> 推送成功！订阅地址: ${url}/sub${PLAIN}"
    else
        echo -e "${RED}>>> 推送失败 (HTTP $status)${PLAIN}"
    fi
}

# 方案 B: 本地 Web UI
start_local_web() {
    if [[ -z "$ARGO_DOMAIN" ]]; then
        read -p "请输入 Argo 域名 (用于拼接链接): " ARGO_DOMAIN
    fi
    
    echo -e "${YELLOW}>>> 检查 Tunnel 配置...${PLAIN}"
    if [[ -f "$TUNNEL_CFG" ]]; then
        if ! grep -q "path: /$SUB_TOKEN" "$TUNNEL_CFG"; then
            sed -i "/^ingress:/a \\  - hostname: $ARGO_DOMAIN\\n    path: /$SUB_TOKEN\\n    service: http://localhost:$LOCAL_PORT" "$TUNNEL_CFG"
            systemctl restart cloudflared
            echo -e "${GREEN}>>> Tunnel 规则已添加并重启。${PLAIN}"
        fi
    fi

    generate_server_py
    
    read -p "开启时长(分钟, 默认60): " min
    min=${min:-60}
    
    pkill -f "icmp9_server.py"
    (timeout "${min}m" python3 /usr/local/bin/icmp9_server.py >/dev/null 2>&1 &)
    
    echo -e "${GREEN}>>> 服务已启动！${PLAIN}"
    echo -e "访问: ${SKYBLUE}https://${ARGO_DOMAIN}/${SUB_TOKEN}${PLAIN}"
}

# ============================================================
# 主菜单
# ============================================================
menu() {
    clear
    echo -e "  ${GREEN}通用订阅管理器 (Sub-Manager Pro)${PLAIN}"
    echo -e "--------------------------------"
    echo -e "核心转换引擎: ${YELLOW}Converter-Pro (OpenClash 优化版)${PLAIN}"
    echo -e "当前文件: ${SKYBLUE}${SELECTED_FILE:-未选择}${PLAIN}"
    echo -e "当前Token: ${YELLOW}${SUB_TOKEN:-未生成}${PLAIN}"
    echo -e "--------------------------------"
    echo -e "  1. 扫描并选择节点文件"
    echo -e "  2. 执行格式转换 (OpenClash/V2Ray)"
    echo -e "  3. ${GREEN}方案 A${PLAIN}: 推送到 Worker"
    echo -e "  4. ${SKYBLUE}方案 B${PLAIN}: 开启本地 Web UI"
    echo -e "  5. 重置 Token"
    echo -e "  0. 退出"
    echo -e "--------------------------------"
    
    read -p "请选择: " opt
    case "$opt" in
        1) scan_and_select ;;
        2) 
           if [[ -z "$SELECTED_FILE" ]]; then scan_and_select; fi
           process_subs 
           ;;
        3) push_worker ;;
        4) start_local_web ;;
        5) SUB_TOKEN=""; process_subs ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
    
    read -p "按回车继续..."
    menu
}

if [[ -f "/usr/local/bin/icmp9_server.py" ]]; then
    SUB_TOKEN=$(grep '^TOKEN =' "/usr/local/bin/icmp9_server.py" | cut -d'"' -f2)
    ARGO_DOMAIN=$(grep '^ARGO_DOMAIN =' "/usr/local/bin/icmp9_server.py" | cut -d'"' -f2)
fi

menu