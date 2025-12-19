#!/bin/sh

echo "☢️ 启动核弹级清理..."

# 1. 停止服务
rc-service cloudflared stop >/dev/null 2>&1
killall cloudflared >/dev/null 2>&1

# 2. 删除所有可能的残留配置 (关键步骤！)
# 你的报错一定是因为这其中某个文件还活着
echo "🧹 删除旧配置..."
rm -f /root/.cloudflared/config.yml
rm -f /root/.cloudflared/config.yaml
rm -rf /root/.cloudflared
rm -f /etc/cloudflared/config.yml
rm -f /etc/cloudflared/config.yaml
rm -f /usr/local/etc/cloudflared/config.yml
rm -f /usr/local/etc/cloudflared/config.yaml

# 3. 准备 Token (之前已提取成功，直接硬编码在脚本里)
MY_TOKEN="eyJhIjoiYWYzN2NhNDc5NDRkMDFlNGY1NTQ2ZmU2NWIyMzRlNjQiLCJ0IjoiNWU5MDYwMjMtMzUxMC00MTZlLWI5MjUtMDQ5YmRmNDA1OWVkIiwicyI6Ik1qYzFPVE5oWlRrdE5HRTRNUzAwWkRjNUxXRmpNRGd0TlRGa1pqSmpZemRrTjJJeiJ9"

echo "📝 建立唯一的配置文件..."
mkdir -p /etc/cloudflared
# 只写入 Token 和日志路径，绝不写会导致报错的参数
cat > /etc/cloudflared/config.yml <<EOF
tunnel: "$MY_TOKEN"
logfile: "/var/log/cloudflared.log"
loglevel: "info"
EOF

echo "⚙️ 重写启动脚本 (注入环境变量)..."
cat > /etc/init.d/cloudflared <<INIT
#!/sbin/openrc-run

name="cloudflared"
description="Cloudflare Tunnel Agent"
command="/usr/bin/cloudflared"
# 强制指定配置文件路径，防止它乱读
command_args="tunnel run --config /etc/cloudflared/config.yml"
command_background=true
pidfile="/run/cloudflared.pid"
output_log="/var/log/cloudflared.log"
error_log="/var/log/cloudflared.err"

depend() {
    need net
    after firewall
}

start_pre() {
    # 使用环境变量强制 IPv6 和 HTTP2
    # 这比配置文件更可靠，不会有类型错误
    export TUNNEL_EDGE_IP_VERSION="6"
    export TUNNEL_PROTOCOL="http2"
}
INIT
chmod +x /etc/init.d/cloudflared

echo "🚀 启动服务..."
rc-service cloudflared restart
sleep 5

echo "📊 最终检查..."
# 检查是否还有那个该死的错误
if grep -q "expected string found int" /var/log/cloudflared.err; then
    echo "❌ 失败：幽灵文件依然存在！(请检查 /home 目录下是否有配置)"
    find / -name config.yml 2>/dev/null | grep cloudflared
elif grep -q "Registered tunnel connection" /var/log/cloudflared.err /var/log/cloudflared.log; then
    echo "✅✅✅ 成功连接！这次是真的！"
else
    echo "ℹ️ 无格式错误，查看连接状态..."
    tail -n 10 /var/log/cloudflared.err
fi
