import base64
import json
import urllib.parse
import sys

# ================= 配置区域 =================
INPUT_FILE = "links.txt"       # 输入文件
OUTPUT_FILE = "openclash_new.yaml" # 输出文件
GROUP_NAME = "Proxy"           # 策略组名称
# ===========================================

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
                "skip-cert-verify": True if data.get("verify_cert") == False else False,
                "network": data.get("net", "tcp"),
                "udp": True
            }
            if node["tls"]:
                node["servername"] = data.get("sni") or data.get("host")
            ProxyConverter._apply_transport(node, node["network"], {
                "path": data.get("path"),
                "host": data.get("host"),
                "type": data.get("type") 
            })
            return node
        except Exception:
            return None

    @staticmethod
    def parse_ss(link):
        try:
            link = link.replace("ss://", "")
            if "#" in link:
                main_part, name = link.split("#", 1)
                name = urllib.parse.unquote(name)
            else:
                main_part, name = link, "SS_Node"
            
            if "@" in main_part:
                user_info, server_info = main_part.split("@", 1)
                user_decoded = ProxyConverter.safe_base64_decode(user_info)
                method, password = user_decoded.split(":", 1)
                server, port = server_info.split(":", 1)
            else:
                decoded = ProxyConverter.safe_base64_decode(main_part)
                if "@" in decoded:
                    auth, server_part = decoded.split("@")
                    method, password = auth.split(":", 1)
                    server, port = server_part.split(":", 1)
                else:
                    return None
            return {
                "name": name, "type": "ss", "server": server, "port": int(port),
                "cipher": method, "password": password, "udp": True
            }
        except Exception:
            return None

    @staticmethod
    def parse_url_based(link):
        try:
            u = urllib.parse.urlparse(link)
            params = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
            scheme = u.scheme.lower()
            node = {
                "name": urllib.parse.unquote(u.fragment) or f"{scheme.upper()}_Node",
                "server": u.hostname, "port": u.port, "udp": True
            }
            
            if scheme in ["vless", "trojan"]:
                node["type"] = scheme
                node["uuid"] = u.username if scheme == "vless" else None
                node["password"] = u.username if scheme == "trojan" else None
                node["tls"] = True if params.get("security") in ["tls", "xtls", "reality"] else False
                node["network"] = params.get("type", "tcp")
                node["skip-cert-verify"] = True if params.get("allowInsecure") == "1" else False
                if node["tls"]:
                    node["servername"] = params.get("sni")
                    node["client-fingerprint"] = params.get("fp", "chrome")
                    if params.get("security") == "reality":
                        node["reality-opts"] = {"public-key": params.get("pbk"), "short-id": params.get("sid", "")}
                    if params.get("flow"): node["flow"] = params.get("flow")
                ProxyConverter._apply_transport(node, node["network"], params)

            elif scheme == "hysteria2":
                node["type"] = "hysteria2"
                node["auth"] = u.username
                node["tls"] = True
                node["skip-cert-verify"] = True if params.get("insecure") == "1" else False
                node["servername"] = params.get("sni")
                if "obfs" in params:
                    node["obfs"] = params["obfs"]
                    node["obfs-password"] = params.get("obfs-password", "")

            elif scheme == "tuic":
                node["type"] = "tuic"
                node["uuid"] = u.username
                node["password"] = u.password 
                node["tls"] = True
                node["skip-cert-verify"] = True if params.get("allow_insecure") == "1" else False
                node["servername"] = params.get("sni")
                node["congestion-controller"] = params.get("congestion_control", "bbr")
                node["udp-relay-mode"] = params.get("udp_relay_mode", "native")
            return node
        except Exception:
            return None

    @staticmethod
    def _apply_transport(node, net, params):
        # 自动补齐 path 斜杠
        def fix_path(p): return p if p and p.startswith("/") else "/" + (p or "")
        
        if net == "ws":
            node["ws-opts"] = {"path": fix_path(params.get("path")), "headers": {"Host": params.get("host", "")}}
        elif net == "grpc":
            node["grpc-opts"] = {"grpc-service-name": params.get("serviceName") or params.get("path")}
        elif net == "h2":
            node["h2-opts"] = {"path": fix_path(params.get("path")), "host": [params.get("host")] if params.get("host") else []}

    @staticmethod
    def generate_simple_config(proxies):
        """极简版生成：Proxies + 一个简单的策略组"""
        print(f"正在转换 {len(proxies)} 个节点...")
        
        key_order = [
            "name", "type", "server", "port", "uuid", "password", "auth", "cipher",
            "tls", "servername", "skip-cert-verify", "network", "flow", "client-fingerprint",
            "udp", "ws-opts", "grpc-opts", "h2-opts", "reality-opts", "obfs", "obfs-password",
            "congestion-controller", "udp-relay-mode"
        ]

        try:
            with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
                # 1. 写入 Proxies
                f.write("proxies:\n")
                for p in proxies:
                    # 修复反斜杠报错：先在外部处理好字符串
                    safe_name = str(p['name']).replace('"', '\\"')
                    f.write(f"  - name: \"{safe_name}\"\n")
                    
                    for key in key_order:
                        if key in p and key != "name":
                            val = p[key]
                            if isinstance(val, bool): val = str(val).lower()
                            
                            if key == "ws-opts":
                                f.write(f"    ws-opts:\n      path: \"{val['path']}\"\n")
                                if val['headers'].get('Host'): f.write(f"      headers:\n        Host: {val['headers']['Host']}\n")
                            elif key == "grpc-opts": f.write(f"    grpc-opts:\n      grpc-service-name: \"{val['grpc-service-name']}\"\n")
                            elif key == "reality-opts": f.write(f"    reality-opts:\n      public-key: {val['public-key']}\n      short-id: {val['short-id']}\n")
                            elif key == "h2-opts": f.write(f"    h2-opts:\n      path: \"{val['path']}\"\n")
                            else: f.write(f"    {key}: {val}\n")
                    f.write("\n")
                
                # 2. 写入 Proxy Groups (仅包含新转换的节点)
                f.write("proxy-groups:\n")
                f.write(f"  - name: \"{GROUP_NAME}\"\n")
                f.write(f"    type: select\n")
                f.write(f"    proxies:\n")
                
                seen_names = set()
                for p in proxies:
                    name = p['name']
                    if name not in seen_names:
                        # 修复反斜杠报错：同样在外部处理
                        safe_name_ref = str(name).replace('"', '\\"')
                        f.write(f"      - \"{safe_name_ref}\"\n")
                        seen_names.add(name)

            print(f"✅ 转换成功！请打开 {OUTPUT_FILE} 进行复制粘贴。")
            
        except Exception as e:
            print(f"❌ 写入文件失败: {e}")

def main():
    try:
        with open(INPUT_FILE, 'r', encoding='utf-8') as f:
            links = [line.strip() for line in f if line.strip()]
    except FileNotFoundError:
        print(f"❌ 未找到 {INPUT_FILE}。")
        return

    proxies = []
    for link in links:
        if link.startswith("vmess://"): res = ProxyConverter.parse_vmess(link)
        elif link.startswith("ss://"): res = ProxyConverter.parse_ss(link)
        elif link.startswith(("vless://", "trojan://", "hysteria2://", "tuic://")): res = ProxyConverter.parse_url_based(link)
        else: continue
        if res: proxies.append(res)

    if proxies: ProxyConverter.generate_simple_config(proxies)
    else: print("❌ 没有有效节点。")

if __name__ == "__main__":
    main()
