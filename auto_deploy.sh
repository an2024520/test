#!/bin/bash
# ============================================================
#  Commander Auto-Deploy (无人值守入口)
#  - 核心功能: 开启 AUTO_SETUP 开关，调度子脚本
#  - 使用方法: export INSTALL_SB=true UUID=... bash auto_deploy.sh
# ============================================================

# 颜色定义
GREEN='\033[0;32m'
PLAIN='\033[0m'

# 1. 开启自动模式开关 (关键！)
# 子脚本检测到这个变量，就会走“自动通道”，否则走“原有手动通道”
export AUTO_SETUP=true

# 2. 基础依赖函数
URL_LIST="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/sh_url.txt"
LOCAL_LIST="/tmp/sh_url.txt"

init_urls() {
    wget -qO "$LOCAL_LIST" "$URL_LIST"
}

run() {
    local script=$1
    if [ ! -f "$script" ]; then
        url=$(grep "^$script" "$LOCAL_LIST" | awk '{print $2}' | head -1)
        wget -qO "$script" "$url" && chmod +x "$script"
    fi
    ./"$script"
}

# 3. 调度流程
echo -e "${GREEN}>>> 启动 Commander 自动化部署...${PLAIN}"
init_urls

# 任务：部署 Sing-box 核心
if [[ "$INSTALL_SB" == "true" ]]; then
    echo -e "${GREEN}>>> [1/2] 部署 Sing-box 核心...${PLAIN}"
    run "sb_install_core.sh"
    
    # 任务：部署 Vision 节点
    if [[ "$DEPLOY_VISION" == "true" ]]; then
        echo -e "${GREEN}>>> [2/2] 部署 Vision 节点...${PLAIN}"
        run "sb_vless_vision_reality.sh"
    fi
    
    # 后续可在此处扩展其他节点部署任务...
fi

echo -e "${GREEN}>>> 自动化任务完成。${PLAIN}"
