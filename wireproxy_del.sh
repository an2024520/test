# 1. 停止并禁用服务
systemctl stop wireproxy
systemctl disable wireproxy

# 2. 删除旧的服务文件
rm -f /etc/systemd/system/wireproxy.service
systemctl daemon-reload

# 3. 删除旧的二进制文件 (防止文件被占用导致覆盖失败)
rm -f /usr/local/bin/wireproxy

# 4. 清理配置文件目录 (保留目录结构，清空内容)
# 注意：这会删除旧的账号信息。如果你之前注册成功了且担心现在注册受限，
# 你可以先手动备份 /etc/wireproxy/wgcf-account.toml
rm -rf /etc/wireproxy/*

echo "旧版本清理完成，现在可以运行 install_warp_proxy.sh 了。"
