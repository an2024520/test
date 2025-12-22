#!/bin/bash

# ============================================================
#  Commander Auto-Deploy (无人值守部署入口)
#  - 功能: 接收环境变量 -> 自动编排安装流程
#  - 用法: export UUID=... bash auto_deploy.sh
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 基础环境检查与变量加载
# ------------------------------------------------
# 引用远程或本地的 URL 列表 (保持与 menu.sh 一致)
URL_LIST_FILE="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/sh_url.txt"
LOCAL_LIST_FILE="/tmp/sh_url.txt"

# 下载辅助函数 (复用 menu.sh 的逻辑)
init_urls() {
    wget -T 15 -t 3 -qO "$LOCAL_LIST_FILE" "${URL_LIST_FILE}?t=$(date +%s)"
    if [[ $? -ne 0 ]]; then
        [[ -f "$LOCAL_LIST_FILE" ]] || { echo -e "${RED}错误: 无法获取脚本列表。${PLAIN}"; exit 1; }
    fi
}

get_url_by_name() {
    grep "^$1" "$LOCAL_LIST_FILE" | awk '{print $2}' | head -n 1
}

# 运行子脚本函数 (带下载功能)
run_script() {
    local script_name="$1"
    if [[ ! -f "$script_name" ]]; then
        echo -e "${YELLOW}正在下载组件 [$script_name] ...${PLAIN}"
        local script_url=$(get_url_by_name "$script_name")
        [[ -z "$script_url" ]] && { echo -e "${RED}错误: sh_url.txt 未找到记录。${PLAIN}"; exit 1; }
        wget -qO "$script_name" "${script_url}?t=$(date +%s)"
        chmod +x "$script_name"
    fi
    # 关键点：直接运行，不再需要用户交互，因为变量已经 export 了
    ./"$script_name"
}

# 2. 自动化编排逻辑
# ------------------------------------------------
echo -e "${GREEN}>>> 进入 Commander 自动化部署模式...${PLAIN}"

init_urls

# 场景 A: 部署 Sing-box + Vision 节点
# 触发条件: 只要设置了 INSTALL_SB=true
if [[ "$INSTALL_SB" == "true" ]]; then
    echo -e "${GREEN}>>> [任务 1/2] 部署 Sing-box 核心环境${PLAIN}"
    # 这一步需要 sb_install_core.sh 具备“已安装则跳过”的能力
    run_script "sb_install_core.sh"

    if [[ "$DEPLOY_VISION" == "true" ]]; then
        echo -e "${GREEN}>>> [任务 2/2] 部署 VLESS-Vision-Reality 节点${PLAIN}"
        # 这一步需要 sb_vless_vision_reality.sh 具备“读取环境变量”的能力
        # 必须确保 UUID 和 PORT 变量已存在
        if [[ -z "$UUID" ]]; then
            echo -e "${RED}错误: 自动化模式下必须提供 UUID 变量！${PLAIN}"
            exit 1
        fi
        run_script "sb_vless_vision_reality.sh"
    fi
fi

echo -e "${GREEN}✅ 所有自动化任务执行完毕！${PLAIN}"
