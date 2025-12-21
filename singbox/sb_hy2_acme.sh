#!/bin/bash

# ============================================================
#  Sing-box 节点新增: Hysteria 2 + ACME (通用版 v3.3)
#  - 修复: 更改密码生成逻辑为 Hex，解决客户端链接解析兼容性问题
#  - 模式 1: 手动指定证书路径 (适合已有证书)
#  - 模式 2: 自动申请证书 (集成 acme.sh，需 80 端口)
#  - 核心: 写入 Inbounds + 写入 .meta + 端口霸占清理
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'
SKYBLUE='\033[0;36m'

echo -e "${GREEN}>>> [Sing-box] 智能添加节点: Hysteria 2 (ACME/证书版) ...${PLAIN}"

# 1. 智能路径查找
# ------------------------------------------------
CONFIG_FILE=""
PATHS=("/usr/local/etc/sing-box/config.json" "/etc/sing-box/config.json" "$HOME/sing-box/config.json")

for p in "${PATHS[@]}"; do
    if [[ -f "$p" ]]; then
        CONFIG_FILE="$p"
        break
    fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FILE="/usr/local/etc/sing-box/config.json"
fi

CONFIG_DIR=$(dirname "$CONFIG_FILE")
CERT_SAVE_DIR="${CONFIG_DIR}/cert" # 证书统一存放目录
META_FILE="${CONFIG_FILE}.meta"
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")

echo -e "${GREEN}>>> 锁定配置文件: ${CONFIG_FILE}${PLAIN}"

# 2. 环境检查
if [[ ! -f "$SB_BIN" ]]; then
    echo -e "${RED}错误: 未找到 Sing-box 核心！请先运行 [核心环境管理] 安装。${PLAIN}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}检测到缺少必要工具，正在安装 jq...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y jq socat
    elif [ -f /etc/redhat-release ]; then
        yum install -y jq socat
    fi
fi
# 确保安装 socat (acme.sh 依赖)
if ! command -v socat &> /dev/null; then
    apt install -y socat 2>/dev/null || yum install -y socat 2>/dev/null
fi

# 3. 初始化配置
if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$CONFIG_DIR"
    cat <<EOF > "$CONFIG_FILE"
{
  "log": { "level": "info", "output": "", "timestamp": false },
  "inbounds": [],
  "outbounds": [ { "type": "direct", "tag": "direct" }, { "type": "block", "tag": "block" } ],
  "route": { "rules": [] }
}
EOF
fi
mkdir -p "$CERT_SAVE_DIR"

# 4. 证书模式选择
# ------------------------------------------------
echo -e "${YELLOW}--- 请选择证书获取方式 ---${PLAIN}"
echo -e "  1. ${SKYBLUE}手动输入路径${PLAIN} (适合已有证书文件)"
echo -e "  2. ${GREEN}自动申请证书${PLAIN} (使用 acme.sh，需占用 80 端口)"
echo -e ""
read -p "请选择 [1-2] (默认 1): " CERT_MODE

CERT_PATH=""
KEY_PATH=""
DOMAIN=""

if [[ "$CERT_MODE" == "2" ]]; then
    # === 模式 2: 自动申请逻辑 (参考 hy2.sh) ===
    echo -e "${YELLOW}>>> 进入 ACME 自动申请模式...${PLAIN}"
    
    # 输入域名
    read -p "请输入解析到本机 IP 的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && echo -e "${RED}域名不能为空。${PLAIN}" && exit 1
    
    # 邮箱 (可选)
    read -p "请输入注册邮箱 (回车跳过): " EMAIL
    [[ -z "$EMAIL" ]] && EMAIL="install@${DOMAIN}"

    # 安装 acme.sh
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        echo -e "${YELLOW}正在安装 acme.sh ...${PLAIN}"
        curl https://get.acme.sh | sh -s email=$EMAIL
    fi
    ACME_BIN=~/.acme.sh/acme.sh

    # 端口释放检测 (参考 hy2.sh 逻辑)
    if lsof -i :80 | grep -q "LISTEN"; then
        echo -e "${RED}警告: 检测到 80 端口被占用 (可能是 Nginx/Apache)。${PLAIN}"
        echo -e "${YELLOW}为了申请证书，脚本将尝试临时停止 Web 服务。${PLAIN}"
        read -p "是否继续? (y/n): " STOP_WEB
        if [[ "$STOP_WEB" == "y" ]]; then
            systemctl stop nginx 2>/dev/null
            systemctl stop apache2 2>/dev/null
            systemctl stop httpd 2>/dev/null
        else
            echo -e "${RED}取消操作。请手动释放 80 端口。${PLAIN}"
            exit 1
        fi
    fi

    # 申请证书 (Standalone 模式)
    echo -e "${YELLOW}正在申请证书 (${DOMAIN}) ...${PLAIN}"
    $ACME_BIN --issue -d "$DOMAIN" --standalone --force
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}证书申请失败！请检查域名解析或防火墙 80 端口。${PLAIN}"
        exit 1
    fi

    # 安装证书到 Sing-box 目录
    echo -e "${YELLOW}正在安装证书到: $CERT_SAVE_DIR ...${PLAIN}"
    $ACME_BIN --install-cert -d "$DOMAIN" \
        --key-file       "$CERT_SAVE_DIR/${DOMAIN}.key"  \
        --fullchain-file "$CERT_SAVE_DIR/${DOMAIN}.cer" \
        --reloadcmd     "systemctl restart sing-box"

    CERT_PATH="$CERT_SAVE_DIR/${DOMAIN}.cer"
    KEY_PATH="$CERT_SAVE_DIR/${DOMAIN}.key"
    
    if [[ ! -f "$CERT_PATH" ]]; then
        echo -e "${RED}证书文件安装失败。${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}证书申请并配置成功！${PLAIN}"

else
    # === 模式 1: 手动输入逻辑 ===
    echo -e "${YELLOW}>>> 进入手动路径模式...${PLAIN}"
    
    read -p "请输入绑定域名 (用于分享链接): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then echo -e "${RED}域名不能为空。${PLAIN}"; exit 1; fi

    echo -e "${YELLOW}请输入证书文件绝对路径 (.crt / .cer / .pem):${PLAIN}"
    read -p "路径: " CERT_PATH
    if [[ ! -f "$CERT_PATH" ]]; then echo -e "${RED}错误: 找不到文件 $CERT_PATH${PLAIN}"; exit 1; fi

    echo -e "${YELLOW}请输入密钥文件绝对路径 (.key):${PLAIN}"
    read -p "路径: " KEY_PATH
    if [[ ! -f "$KEY_PATH" ]]; then echo -e "${RED}错误: 找不到文件 $KEY_PATH${PLAIN}"; exit 1; fi
fi

# 5. 节点参数配置
# ------------------------------------------------
echo -e "${YELLOW}--- 配置 Hysteria 2 节点参数 ---${PLAIN}"

# A. 端口设置
while true; do
    read -p "请输入 UDP 监听端口 (推荐 443, 8443, 默认 443): " CUSTOM_PORT
    [[ -z "$CUSTOM_PORT" ]] && PORT=443 && break
    
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -le 65535 ]; then
        if grep -q "\"listen_port\": $CUSTOM_PORT" "$CONFIG_FILE"; then
             echo -e "${YELLOW}提示: 端口 $CUSTOM_PORT 已被占用，脚本将强制覆盖。${PLAIN}"
        fi
        PORT="$CUSTOM_PORT"
        break
    else
        echo -e "${RED}无效端口。${PLAIN}"
    fi
done

# B. 密码与混淆 (修复点: 使用 Hex 生成 URL 安全密码)
PASSWORD=$(openssl rand -hex 16)
OBFS_PASS=$(openssl rand -hex 8)
echo -e "${YELLOW}已自动生成高强度密码与混淆密钥 (Hex模式/无特殊字符)。${PLAIN}"

# 6. 构建与注入节点
echo -e "${YELLOW}正在更新配置文件...${PLAIN}"

NODE_TAG="Hy2-${DOMAIN}-${PORT}"

# === 步骤 1: 强制日志托管 ===
tmp_log=$(mktemp)
jq '.log.output = "" | .log.timestamp = false' "$CONFIG_FILE" > "$tmp_log" && mv "$tmp_log" "$CONFIG_FILE"

# === 步骤 2: 端口霸占清理 ===
tmp0=$(mktemp)
jq --argjson port "$PORT" 'del(.inbounds[]? | select(.listen_port == $port))' "$CONFIG_FILE" > "$tmp0" && mv "$tmp0" "$CONFIG_FILE"

# === 步骤 3: 构建 Hysteria 2 JSON ===
NODE_JSON=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$NODE_TAG" \
    --arg pass "$PASSWORD" \
    --arg obfs "$OBFS_PASS" \
    --arg cert "$CERT_PATH" \
    --arg key "$KEY_PATH" \
    '{
        "type": "hysteria2",
        "tag": $tag,
        "listen": "::",
        "listen_port": ($port | tonumber),
        "users": [
            {
                "password": $pass
            }
        ],
        "obfs": {
            "type": "salamander",
            "password": $obfs
        },
        "tls": {
            "enabled": true,
            "certificate_path": $cert,
            "key_path": $key
        }
    }')

# 插入新节点
tmp=$(mktemp)
jq --argjson new_node "$NODE_JSON" 'if .inbounds == null then .inbounds = [] else . end | .inbounds += [$new_node]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# === 步骤 4: 写入 Meta (记录域名和类型) ===
if [[ ! -f "$META_FILE" ]]; then echo "{}" > "$META_FILE"; fi
tmp_meta=$(mktemp)
# 记录 type 为 hy2-acme，方便后续读取
jq --arg tag "$NODE_TAG" --arg pass "$PASSWORD" --arg obfs "$OBFS_PASS" --arg domain "$DOMAIN" \
   '. + {($tag): {"type": "hy2-acme", "pass": $pass, "obfs": $obfs, "domain": $domain}}' "$META_FILE" > "$tmp_meta" && mv "$tmp_meta" "$META_FILE"

# 7. 重启与输出
echo -e "${YELLOW}正在重启服务...${PLAIN}"
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    PUBLIC_IP=$(curl -s4m5 https://api.ip.sb/ip || curl -s4 ifconfig.me)
    SHARE_HOST="$DOMAIN"
    NODE_NAME="$NODE_TAG"
    
    # 构造链接
    SHARE_LINK="hysteria2://${PASSWORD}@${SHARE_HOST}:${PORT}?insecure=0&obfs=salamander&obfs-password=${OBFS_PASS}&sni=${DOMAIN}#${NODE_NAME}"

    echo -e ""
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}   [Sing-box] Hy2 (证书) 节点添加成功   ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "节点 Tag    : ${YELLOW}${NODE_TAG}${PLAIN}"
    echo -e "端口        : ${YELLOW}${PORT}${PLAIN}"
    echo -e "认证密码    : ${YELLOW}${PASSWORD}${PLAIN}"
    echo -e "混淆密码    : ${YELLOW}${OBFS_PASS}${PLAIN}"
    echo -e "绑定域名    : ${YELLOW}${DOMAIN}${PLAIN}"
    echo -e "证书状态    : $( [[ "$CERT_MODE" == "2" ]] && echo "${GREEN}自动续期 (acme.sh)${PLAIN}" || echo "${SKYBLUE}手动管理${PLAIN}" )"
    echo -e "----------------------------------------"
    echo -e "🚀 [v2rayN 分享链接]:"
    echo -e "${YELLOW}${SHARE_LINK}${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "🐱 [OpenClash / Clash Meta 配置块]:"
    echo -e "${YELLOW}"
    cat <<EOF
- name: "${NODE_NAME}"
  type: hysteria2
  server: "${SHARE_HOST}"
  port: ${PORT}
  password: "${PASSWORD}"
  sni: "${DOMAIN}"
  skip-cert-verify: false
  obfs: salamander
  obfs-password: "${OBFS_PASS}"
EOF
    echo -e "${PLAIN}----------------------------------------"
    echo -e "📱 [Sing-box 客户端配置块]:"
    echo -e "${YELLOW}"
    cat <<EOF
{
  "type": "hysteria2",
  "tag": "proxy-out",
  "server": "${SHARE_HOST}",
  "server_port": ${PORT},
  "password": "${PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${DOMAIN}",
    "insecure": false
  },
  "obfs": {
    "type": "salamander",
    "password": "${OBFS_PASS}"
  }
}
EOF
    echo -e "${PLAIN}----------------------------------------"
else
    echo -e "${RED}启动失败！请检查日志: journalctl -u sing-box -e${PLAIN}"
fi
