import json
import base64
import urllib.request
import urllib.error
import sys

# === 配置区 (用户修改) ===
WORKER_URL = "https://your-worker.your-domain.workers.dev" # 你的 Worker 地址
API_SECRET = "ReplaceWithYourSecurePassword"               # 你的 Worker 密码
SOURCE_FILE = "links.txt"                                  # 存放节点链接的文件

def parse_vmess(vmess_str):
    """简单的 vmess 解析器"""
    try:
        if not vmess_str.startswith("vmess://"): return None
        b64 = vmess_str.replace("vmess://", "")
        # 补全 padding
        b64 += "=" * ((4 - len(b64) % 4) % 4)
        conf = json.loads(base64.b64decode(b64).decode('utf-8'))
        return {
            "ps": conf.get("ps", "Unnamed"),
            "add": conf.get("add"),
            "port": conf.get("port"),
            "id": conf.get("id"),
            "path": conf.get("path", "/"),
            "tls": conf.get("tls", "none")
        }
    except Exception as e:
        print(f"解析失败: {vmess_str[:20]}... {e}")
        return None

def push_to_worker(nodes):
    url = f"{WORKER_URL}/update"
    headers = {
        "Content-Type": "application/json",
        "Authorization": API_SECRET,
        "User-Agent": "ICMP9-Client/1.0"
    }
    payload = json.dumps({"nodes": nodes}).encode('utf-8')

    try:
        req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
        with urllib.request.urlopen(req) as resp:
            print(f"✅ 推送成功! 状态码: {resp.status}")
            print(f"🔗 订阅链接: {WORKER_URL}/sub")
    except urllib.error.HTTPError as e:
        print(f"❌ 推送失败: HTTP {e.code} - {e.read().decode()}")
    except Exception as e:
        print(f"❌ 网络错误: {e}")

def main():
    nodes = []
    try:
        with open(SOURCE_FILE, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"): continue
                
                # 目前仅支持 vmess 解析，可扩展
                node = parse_vmess(line)
                if node:
                    nodes.append(node)
                    print(f"读取节点: {node['ps']}")
    except FileNotFoundError:
        print(f"找不到文件: {SOURCE_FILE}")
        return

    if not nodes:
        print("没有有效节点，退出。")
        return

    print(f"\n准备推送 {len(nodes)} 个节点到云端...")
    push_to_worker(nodes)

if __name__ == "__main__":
    main()