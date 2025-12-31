import json
import base64
import urllib.request
import urllib.error
import urllib.parse
import sys
import re

# ================= 配置区域 =================
# ⚠️ 只填 Worker 根域名，不要带 /sub
WORKER_URL = "https://plain-sea-2f0a.aaa5461.workers.dev" 
API_SECRET = "ReplaceWithYourSecurePassword" 
SOURCE_FILE = "links.txt"
# ===========================================

class ProxyParser:
    @staticmethod
    def safe_base64_decode(s):
        s = s.strip()
        missing_padding = len(s) % 4
        if missing_padding: s += '=' * (4 - missing_padding)
        return base64.b64decode(s.replace('-', '+').replace('_', '/')).decode('utf-8', errors='ignore')

    @staticmethod
    def parse_vmess(link):
        try:
            raw = ProxyParser.safe_base64_decode(link[8:])
            data = json.loads(raw)
            return {
                "type": "vmess",
                "name": data.get("ps", "unnamed"),
                "server": data.get("add"),
                "port": int(data.get("port")),
                "uuid": data.get("id"),
                "alterId": int(data.get("aid", 0)),
                "cipher": "auto",
                "network": data.get("net", "tcp"),
                "tls": True if data.get("tls") == "tls" else False,
                "servername": data.get("sni", data.get("host", "")),
                "ws-opts": {
                    "path": data.get("path", "/"),
                    "headers": {"Host": data.get("host", "")}
                } if data.get("net") == "ws" else None
            }
        except: return None

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
                "type": "vless",
                "name": urllib.parse.unquote(name).strip(),
                "server": host,
                "port": int(port),
                "uuid": uuid,
                "network": params.get("type", "tcp"),
                "tls": True if params.get("security") in ["tls", "reality"] else False,
                "flow": params.get("flow", ""),
                "servername": params.get("sni", ""),
                "client-fingerprint": params.get("fp", ""),
                "skip-cert-verify": True
            }
            
            # Reality 处理
            if params.get("security") == "reality":
                node["reality-opts"] = {
                    "public-key": params.get("pbk"),
                    "short-id": params.get("sid")
                }
            
            # WS 处理
            if node["network"] == "ws":
                node["ws-opts"] = {
                    "path": params.get("path", "/"),
                    "headers": {"Host": params.get("host", "")}
                }
            
            return node
        except: return None

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
                "type": "hysteria2",
                "name": urllib.parse.unquote(name).strip(),
                "server": host,
                "port": int(port),
                "password": auth,
                "sni": params.get("sni", host),
                "skip-cert-verify": True,
                "obfs": params.get("obfs", ""),
                "obfs-password": params.get("obfs-password", "")
            }
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

def push_to_worker(nodes):
    url = f"{WORKER_URL}/update"
    headers = {
        "Content-Type": "application/json",
        "Authorization": API_SECRET,
        "User-Agent": "ICMP9-Client/Pro"
    }
    payload = json.dumps({"nodes": nodes}).encode('utf-8')

    try:
        print(f"📡 正在连接 Worker: {url} ...")
        req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
        with urllib.request.urlopen(req) as resp:
            if resp.status == 200:
                print(f"✅ 推送成功! 已同步 {len(nodes)} 个节点。")
                print(f"🔗 订阅链接: {WORKER_URL}/sub")
            else:
                print(f"❌ Worker 返回异常: {resp.status}")
    except urllib.error.HTTPError as e:
        print(f"❌ 推送失败 (HTTP {e.code}): {e.read().decode()}")
    except Exception as e:
        print(f"❌ 网络错误: {e}")

def main():
    print(">>> ICMP9 全协议节点推送工具 <<<")
    nodes = []
    
    try:
        with open(SOURCE_FILE, 'r', encoding='utf-8') as f:
            for line in f:
                link = line.strip()
                if not link or link.startswith("#"): continue
                
                node = None
                if link.startswith("vmess://"): node = ProxyParser.parse_vmess(link)
                elif link.startswith("vless://"): node = ProxyParser.parse_vless(link)
                elif link.startswith("hysteria2://"): node = ProxyParser.parse_hy2(link)
                elif link.startswith("trojan://"): node = ProxyParser.parse_trojan(link)
                
                if node:
                    nodes.append(node)
                    print(f"  + [{node['type']}] {node['name']}")
    except FileNotFoundError:
        print(f"❌ 找不到文件 {SOURCE_FILE}"); return

    if not nodes:
        print("❌ 没有提取到有效节点。"); return

    print(f"\n准备推送 {len(nodes)} 个节点...")
    push_to_worker(nodes)

if __name__ == "__main__":
    main()