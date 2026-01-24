#!/bin/bash
echo "v1.2版"
sleep 2
# ============================================================
#  ACME 证书管理脚本 v1.2
#  - 新增: 手动导入 Cloudflare 15年源证书 (Paste Mode)
#  - 优化: 路径标准化，适配 Sing-box 自动部署
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

INFO_FILE="/etc/acme_info"

check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本！${PLAIN}" && exit 1
}

install_deps() {
    if [[ -n $(command -v apt-get) ]]; then
        apt-get update -y && apt-get install -y socat curl cron
    elif [[ -n $(command -v yum) ]]; then
        yum install -y socat curl cronie
        systemctl enable crond && systemctl start crond
    fi
}

install_acme_core() {
    if ! command -v acme.sh &> /dev/null && [[ ! -f ~/.acme.sh/acme.sh ]]; then
        echo -e "${GREEN}>>> 安装 acme.sh...${PLAIN}"
        read -p "请输入注册邮箱 (可随意填写): " ACME_EMAIL
        [[ -z "$ACME_EMAIL" ]] && ACME_EMAIL="cert@example.com"
        curl https://get.acme.sh | sh -s email="$ACME_EMAIL"
        source ~/.bashrc
    else
        echo -e "${YELLOW}>>> acme.sh 已安装，跳过核心安装。${PLAIN}"
    fi
}

update_info_file() {
    local domain=$1
    echo "CERT_PATH=\"/root/cert/${domain}/fullchain.crt\"" > "$INFO_FILE"
    echo "KEY_PATH=\"/root/cert/${domain}/private.key\"" >> "$INFO_FILE"
    echo "DOMAIN=\"${domain}\"" >> "$INFO_FILE"
    echo -e "${GREEN}>>> 路径信息已更新至: ${INFO_FILE}${PLAIN}"
}

# --- 功能模块 1: ACME 自动申请 ---
issue_cert() {
    install_deps
    install_acme_core
    
    echo -e "\n${GREEN}>>> 请选择证书申请模式:${PLAIN}"
    echo -e "  1. HTTP 模式 (占用 80 端口，适合无 CDN)"
    echo -e "  2. DNS 模式 (Cloudflare API，适合 IPv6/CDN)"
    read -p "请选择 [1-2]: " MODE

    read -p "请输入申请证书的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && echo -e "${RED}域名不能为空！${PLAIN}" && exit 1

    mkdir -p "/root/cert/${DOMAIN}"

    case "$MODE" in
        1)
            if lsof -i :80 &> /dev/null; then
                echo -e "${RED}警告: 80 端口被占用，请先停止 Nginx/Apache。${PLAIN}"
                exit 1
            fi
            ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force
            ;;
        2)
            echo -e "${YELLOW}提示: 需 Cloudflare API Token (Zone.DNS Edit 权限)${PLAIN}"
            read -p "请输入 Token: " CF_TOKEN
            [[ -z "$CF_TOKEN" ]] && echo -e "${RED}Token 不能为空！${PLAIN}" && exit 1
            export CF_Token="$CF_TOKEN"
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" -k ec-256 --force
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}" && exit 1
            ;;
    esac

    if [[ $? -eq 0 ]]; then
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
            --fullchain-file "/root/cert/${DOMAIN}/fullchain.crt" \
            --key-file       "/root/cert/${DOMAIN}/private.key" \
            --reloadcmd      "echo 'Cert updated'"
        
        update_info_file "$DOMAIN"
    else
        echo -e "${RED}>>> 申请失败。${PLAIN}"
    fi
}

# --- 功能模块 2: 手动导入 (粘贴模式) ---
manual_import() {
    echo -e "\n${YELLOW}=== 手动导入 Cloudflare Origin CA (15年证书) ===${PLAIN}"
    read -p "请输入绑定的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && echo -e "${RED}域名不能为空！${PLAIN}" && exit 1

    CERT_DIR="/root/cert/${DOMAIN}"
    mkdir -p "$CERT_DIR"

    echo -e "\n${GREEN}步骤 1/2: 请粘贴证书公钥内容 (.pem / .crt)${PLAIN}"
    echo -e "${YELLOW}提示: 粘贴完成后，按回车键，然后按 Ctrl+D 结束输入${PLAIN}"
    echo -e "-------------------------------------------------------"
    cat > "${CERT_DIR}/fullchain.crt"
    
    if [[ ! -s "${CERT_DIR}/fullchain.crt" ]]; then
        echo -e "${RED}错误: 内容为空，导入失败。${PLAIN}"
        exit 1
    fi

    echo -e "\n${GREEN}步骤 2/2: 请粘贴证书私钥内容 (.key)${PLAIN}"
    echo -e "${YELLOW}提示: 粘贴完成后，按回车键，然后按 Ctrl+D 结束输入${PLAIN}"
    echo -e "-------------------------------------------------------"
    cat > "${CERT_DIR}/private.key"

    if [[ ! -s "${CERT_DIR}/private.key" ]]; then
        echo -e "${RED}错误: 内容为空，导入失败。${PLAIN}"
        exit 1
    fi

    echo -e "\n${GREEN}>>> 证书文件已保存!${PLAIN}"
    update_info_file "$DOMAIN"
}

# --- 功能模块 3: 卸载清理 ---
uninstall_acme() {
    echo -e "\n${RED}>>> [危险] 正在执行卸载程序...${PLAIN}"
    read -p "确定要彻底移除 acme.sh 及其定时任务吗? [y/N]: " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && echo "操作取消" && exit 0

    if [[ -f ~/.acme.sh/acme.sh ]]; then
        ~/.acme.sh/acme.sh --uninstall
    fi
    rm -rf ~/.acme.sh
    rm -f "$INFO_FILE"

    echo -e "${GREEN}>>> acme.sh 核心文件及配置已清理。${PLAIN}"

    read -p "是否删除已申请的证书文件 (/root/cert/)? [y/N]: " DEL_CERT
    if [[ "$DEL_CERT" == "y" || "$DEL_CERT" == "Y" ]]; then
        rm -rf /root/cert
        echo -e "${GREEN}>>> 证书文件已删除。${PLAIN}"
    fi
}

show_menu() {
    echo -e "\n${GREEN}=== ACME 证书管理器 v1.2 ===${PLAIN}"
    echo -e "  1. 申请/续签证书 (ACME 自动模式)"
    echo -e "  2. 卸载 acme.sh (清理)"
    echo -e "  3. 手动导入证书 (CF Origin CA 粘贴模式)"
    echo -e "  0. 退出"
    echo -e "------------------------"
    read -p "请选择: " OPT
    case "$OPT" in
        1) issue_cert ;;
        2) uninstall_acme ;;
        3) manual_import ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
}

# Main
check_root
show_menu