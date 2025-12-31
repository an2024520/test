/**
 * Universal Subscription Hub (通用订阅中心)
 * - 核心: 双轨制分发 (OpenClash 增强 / v2rayN 兼容)
 * - 兼容: VMess / VLESS (Reality) / Hysteria2 / Trojan
 * - KV绑定: SUB_KV
 */
const API_SECRET = "ReplaceWithYourSecurePassword"; // ⚠️ 记得修改回你的密码

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // 1. 上报接口 (POST /update)
    if (request.method === "POST" && url.pathname === "/update") {
      return handleUpdate(request, env);
    }

    // 2. 订阅接口 (GET /sub)
    if (request.method === "GET" && url.pathname.startsWith("/sub")) {
      return handleSubscription(url, request, env);
    }

    // 3. 根路径重定向
    if (url.pathname === "/") {
      return Response.redirect(url.origin + "/sub", 302);
    }

    return new Response("Access Denied", { status: 403 });
  }
};

async function handleUpdate(request, env) {
  const auth = request.headers.get("Authorization");
  if (auth !== API_SECRET) return new Response("Unauthorized", { status: 401 });

  try {
    const data = await request.json();
    if (!data.nodes) throw new Error("Missing nodes field");
    
    // 存入 KV (SUB_KV)
    await env.SUB_KV.put("default_nodes", JSON.stringify(data.nodes));
    
    return new Response(JSON.stringify({ status: "ok", count: data.nodes.length }), {
      headers: { "Content-Type": "application/json" }
    });
  } catch (e) {
    return new Response("Error: " + e.message, { status: 500 });
  }
}

async function handleSubscription(url, request, env) {
  const raw = await env.SUB_KV.get("default_nodes");
  if (!raw) return new Response("No nodes found. Please push data first.", { status: 404 });

  const nodes = JSON.parse(raw);
  const ua = (request.headers.get("User-Agent") || "").toLowerCase();
  const formatParam = url.searchParams.get("format");

  // 1. 强制指定格式 (通过 URL 参数)
  if (formatParam) return serveRawData(nodes, formatParam);

  // 2. 浏览器访问 -> 展示 Web UI
  if (ua.includes("mozilla") && !ua.includes("go-http") && !ua.includes("clash")) {
    return serveHTML(url.href, nodes.length);
  }

  // 3. 客户端访问 -> 自动适配
  const autoFormat = ua.includes("clash") ? "clash" : "v2ray";
  return serveRawData(nodes, autoFormat);
}

function serveRawData(nodes, format) {
  if (format === "clash") {
    return new Response(toClash(nodes), { headers: { "Content-Type": "text/yaml; charset=utf-8" } });
  }
  // 默认返回 Base64
  return new Response(toBase64(nodes), { headers: { "Content-Type": "text/plain; charset=utf-8" } });
}

// --- 核心转换: Clash YAML (完整增强版) ---
function toClash(nodes) {
  let yaml = "mixed-port: 7890\nallow-lan: true\nmode: rule\nlog-level: info\nproxies:\n";
  let names = [];

  nodes.forEach(n => {
    const name = n.name || "Unnamed";
    names.push(name);
    
    // 基础字段
    yaml += `  - name: "${name}"\n`;
    yaml += `    type: ${n.type}\n`;
    yaml += `    server: ${n.server}\n`;
    yaml += `    port: ${n.port}\n`;
    yaml += `    skip-cert-verify: true\n`;
    yaml += `    udp: true\n`;

    // 鉴权字段
    if (n.uuid) yaml += `    uuid: ${n.uuid}\n`;
    if (n.password) yaml += `    password: ${n.password}\n`;
    if (n.cipher) yaml += `    cipher: ${n.cipher}\n`;
    if (n.alterId !== undefined) yaml += `    alterId: ${n.alterId}\n`;
    
    // TLS 配置
    if (n.tls) {
      yaml += `    tls: true\n`;
      if (n.servername) yaml += `    servername: ${n.servername}\n`;
    }
    
    // 指纹 (OpenClash/Meta 需要)
    if (n["client-fingerprint"]) yaml += `    client-fingerprint: ${n["client-fingerprint"]}\n`;
    if (n["fingerprint"]) yaml += `    fingerprint: ${n["fingerprint"]}\n`;
    
    // Reality 配置
    if (n["reality-opts"]) {
      yaml += `    reality-opts:\n`;
      yaml += `      public-key: ${n["reality-opts"]["public-key"]}\n`;
      yaml += `      short-id: ${n["reality-opts"]["short-id"]}\n`;
    }
    // Flow (Vision)
    if (n.flow) yaml += `    flow: ${n.flow}\n`;

    // Hysteria2 特有字段
    if (n.type === 'hysteria2') {
       if (n.obfs) {
           yaml += `    obfs: ${n.obfs}\n`;
           yaml += `    obfs-password: ${n["obfs-password"]}\n`;
       }
       if (n.sni) yaml += `    sni: ${n.sni}\n`;
       if (n.up) yaml += `    up: ${n.up}\n`;
       if (n.down) yaml += `    down: ${n.down}\n`;
    }

    // Network / WebSocket
    if (n.network) yaml += `    network: ${n.network}\n`;
    if (n["ws-opts"]) {
      yaml += `    ws-opts:\n`;
      yaml += `      path: ${n["ws-opts"].path}\n`;
      if (n["ws-opts"].headers) {
         yaml += `      headers:\n        Host: ${n["ws-opts"].headers.Host}\n`;
      }
    }
  });

  // 策略组
  yaml += "\nproxy-groups:\n  - name: '🚀 Proxy'\n    type: select\n    proxies:\n      - DIRECT\n";
  names.forEach(n => yaml += `      - "${n}"\n`);
  
  return yaml + "\nrules:\n  - MATCH, 🚀 Proxy\n";
}

// --- 核心转换: Base64 (兼容 v2rayN) ---
function toBase64(nodes) {
  const links = nodes.map(n => {
    // 1. VMess
    if (n.type === 'vmess') {
       const vmessJson = {
           v: "2", ps: n.name, add: n.server, port: n.port, id: n.uuid,
           aid: "0", net: n.network||"tcp", type: "none", host: n["ws-opts"]?.headers?.Host||"", 
           path: n["ws-opts"]?.path||"/", tls: n.tls?"tls":""
       };
       return "vmess://" + btoa(JSON.stringify(vmessJson));
    } 
    
    // 2. VLESS (v2rayN 支持指纹，故保留)
    else if (n.type === 'vless') {
       const query = [];
       if (n.tls) query.push("security=tls");
       if (n["reality-opts"]) {
           query.push("security=reality");
           query.push("pbk=" + n["reality-opts"]["public-key"]);
           query.push("sid=" + n["reality-opts"]["short-id"]);
       }
       if (n.servername) query.push("sni=" + n.servername);
       if (n.flow) query.push("flow=" + n.flow);
       if (n["client-fingerprint"]) query.push("fp=" + n["client-fingerprint"]);
       if (n.network) query.push("type=" + n.network);
       if (n["ws-opts"]) {
           query.push("path=" + encodeURIComponent(n["ws-opts"].path));
           if (n["ws-opts"].headers && n["ws-opts"].headers.Host) {
               query.push("host=" + n["ws-opts"].headers.Host);
           }
       }
       return `vless://${n.uuid}@${n.server}:${n.port}?${query.join("&")}#${encodeURIComponent(n.name)}`;
    }

    // 3. Hysteria2 (v2rayN 不支持指纹，故意移除)
    else if (n.type === 'hysteria2') {
        const query = [];
        if (n.sni) query.push("sni=" + n.sni);
        if (n.obfs) {
            query.push("obfs=" + n.obfs);
            query.push("obfs-password=" + n["obfs-password"]);
        }
        // ⚠️ 此处不输出 fingerprint，保证 v2rayN 兼容性
        return `hysteria2://${n.password}@${n.server}:${n.port}?${query.join("&")}#${encodeURIComponent(n.name)}`;
    }
    
    // 4. Trojan
    else if (n.type === 'trojan') {
        const query = [];
        if (n.servername) query.push("sni=" + n.servername);
        return `trojan://${n.password}@${n.server}:${n.port}?${query.join("&")}#${encodeURIComponent(n.name)}`;
    }

    return ""; 
  }).filter(l => l !== "");
  
  return btoa(links.join("\n"));
}

// --- Web UI (无品牌版) ---
function serveHTML(currentUrl, count) {
  const html = `
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>订阅中心</title>
<style>
:root { --bg: #0f172a; --card: #1e293b; --text: #e2e8f0; --accent: #38bdf8; --btn: #0ea5e9; }
body { background: var(--bg); color: var(--text); font-family: sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; }
.card { background: var(--card); padding: 2rem; border-radius: 16px; box-shadow: 0 10px 25px rgba(0,0,0,0.5); width: 90%; max-width: 420px; text-align: center; border: 1px solid rgba(255,255,255,0.1); }
h2 { margin-top: 0; color: var(--accent); }
.status { font-size: 13px; color: #94a3b8; margin-bottom: 20px; }
.box { background: rgba(0,0,0,0.3); padding: 12px; border-radius: 8px; margin: 15px 0; word-break: break-all; font-family: monospace; font-size: 12px; color: #cbd5e1; border: 1px dashed #475569; user-select: all; }
label { display: block; text-align: left; font-size: 12px; color: #94a3b8; margin-top: 15px; margin-bottom: 5px; }
select, button { width: 100%; padding: 14px; margin-top: 5px; border-radius: 10px; border: none; font-size: 15px; outline: none; }
select { background: #334155; color: white; border: 1px solid #475569; appearance: none; cursor: pointer; }
button { background: var(--btn); color: white; font-weight: 600; cursor: pointer; }
button:hover { opacity: 0.9; }
.footer { margin-top: 25px; font-size: 12px; color: #64748b; }
</style>
</head>
<body>
<div class="card">
    <h2>🚀 订阅中心</h2>
    <div class="status">云端节点: <b>${count}</b> | KV: <span style="color:#4ade80">SUB_KV</span></div>
    
    <label>通用订阅链接 (OpenClash / v2rayN)</label>
    <div class="box">${currentUrl.split('?')[0]}</div>
    
    <label>强制下载格式</label>
    <select id="fmt">
        <option value="clash">Clash / OpenClash (YAML)</option>
        <option value="v2ray">V2Ray (Base64)</option>
    </select>
    
    <button onclick="jump()">打开 / 下载配置</button>
    
    <div class="footer">
        Powered by Cloudflare Workers
    </div>
</div>
<script>
    function jump() {
        const file = document.getElementById('fmt').value;
        const baseUrl = window.location.href.split('?')[0];
        window.location.href = baseUrl + '?format=' + file;
    }
</script>
</body>
</html>
  `;
  return new Response(html, { headers: { "Content-Type": "text/html; charset=utf-8" } });
}