#!/bin/sh

echo "🔍 第一步：检查 WireProxy 状态..."
# 检查端口 40000 是否被监听
if netstat -an | grep -q "127.0.0.1:40000"; then
    echo "✅ 发现 WireProxy 正在运行 (端口 40000)！"
else
    echo "⚠️ 警告：没检测到端口 40000。"
    echo "尝试启动 WireProxy..."
    rc-service wireproxy restart 2>/dev/null
    sleep 3
    if netstat -an | grep -q "127.0.0.1:40000"; then
        echo "✅ WireProxy 启动成功！"
    else
        echo "❌ 错误：WireProxy 没起来。请先运行之前的 WireProxy 安装脚本。"
        exit 1
    fi
fi

echo "🛑 第二步：停止 Cloudflared..."
rc-service cloudflared stop >/dev/null 2>&1
killall cloudflared >/dev/null 2>&1

# 提取 Token (老规矩，防止丢失)
MY_TOKEN="eyJhIjoiYWYzN2NhNDc5NDRkMDFlNGY1NTQ2ZmU2NWIyMzRlNjQiLCJ0IjoiNWU5MDYwMjMtMzUxMC00MTZlLWI5MjUtMDQ5YmRmNDA1OWVkIiwicyI6Ik1qYzFPVE5oWlRrdE5HRTRNUzAwWkRjNUxXRmpNRGd0TlRGa1pqSmpZemRrTjJJeiJ9"

echo "⚙️ 第三步：配置 Cloudflared 走代理..."
# 我们不再需要复杂的配置文件了，删掉它们，避免干扰
rm -f /etc/cloudflared/config.yml

# 写入带有代理配置的启动脚本
cat > /etc/init.d/cloudflared <<INIT
#!/sbin/openrc-run

name="cloudflared"
description="Cloudflare Tunnel Agent"
command="/usr/bin/cloudflared"
# 只保留最简单的 tunnel run
command_args="tunnel run --token $MY_TOKEN"
command_background=true
pidfile="/run/cloudflared.pid"
output_log="/var/log/cloudflared.log"
error_log="/var/log/cloudflared.err"

depend() {
    need net
    after firewall
    # 关键：必须确保 wireproxy 先启动
    need wireproxy
}

start_pre() {
    # 核心魔法在这里！！！
    # 通过环境变量告诉 cloudflared 使用本地 SOCKS5 代理
    export TUNNEL_PROXY_ADDRESS="127.0.0.1"
    export TUNNEL_PROXY_PORT="40000"
    
    # 既然走了代理，就无需强制 IPv6 了，让它默认去连就行
    # 代理(WARP)会自动处理 IPv4 连接
}
INIT
chmod +x /etc/init.d/cloudflared

echo "🚀 第四步：启动服务..."
rc-service cloudflared restart
sleep 5

echo "📊 检查结果..."
if grep -q "Registered tunnel connection" /var/log/cloudflared.err /var/log/cloudflared.log; then
    echo "✅✅✅ 成功了！Cloudflared 通过 WireProxy 连上了！"
    echo "链路：Cloudflared -> 127.0.0.1:40000 -> WARP -> Cloudflare Edge"
else
    echo "ℹ️ 查看日志："
    echo "--------------------------------"
    tail -n 10 /var/log/cloudflared.err
fi
