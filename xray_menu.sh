#!/bin/bash

# ============================================================
#  模块零：Xray 模块化总管 (Commander)
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'


# 定义各模块脚本的文件名 (请根据你实际保存的文件名修改这里)
# 建议你把之前的脚本都重命名为下面这样，或者修改这里的变量
SCRIPT_CORE="xray_core.sh"                  # 模块一
SCRIPT_ADD_XHTTP="xray_vless_xhttp.sh"      # 模块二
SCRIPT_ADD_VISION="xray_vless_vision.sh"    # 模块三
SCRIPT_REMOVE="xray_module4_remove.sh"      # 模块四
SCRIPT_BOOST="xray_module5_boost.sh"        # 模块五
SCRIPT_ATTACH="xray_module6_attach_warp.sh" # 模块六
SCRIPT_DETACH="xray_module7_detach_warp.sh" # 模块七

# 检查脚本是否存在的函数
check_run() {
    if [[ -f "$1" ]]; then
        chmod +x "$1"
        ./"$1"
    else
        echo -e "${RED}错误: 找不到脚本文件 [$1]${PLAIN}"
        echo -e "请确保所有模块脚本都在当前目录下。"
        read -p "按回车键返回菜单..."
    fi
}

while true; do
    clear
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    Xray 模块化管理系统 (The Modular)    ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${YELLOW}--- 基础建设 ---${PLAIN}"
    echo -e "  1. 安装/重置 Xray 核心环境 (模块一)"
    echo -e "  2. 系统内核加速 BBR+ECN    (模块五)"
    echo -e ""
    echo -e "${YELLOW}--- 节点管理 (增/删) ---${PLAIN}"
    echo -e "  3. 添加 VLESS-XHTTP 节点   (模块二 - 穿透)"
    echo -e "  4. 添加 VLESS-Vision 节点  (模块三 - 稳定)"
    echo -e "  5. ${RED}删除/清空 节点           (模块四)${PLAIN}"
    echo -e ""
    echo -e "${YELLOW}--- 流量控制 (挂/卸) ---${PLAIN}"
    echo -e "  6. 挂载 WARP/Socks5 出口   (模块六 - 解锁)"
    echo -e "  7. 恢复 直连模式           (模块七 - 极速)"
    echo -e ""
    echo -e "${GRAY}----------------------------------------${PLAIN}"
    echo -e "  0. 退出系统"
    echo -e ""
    read -p "请选择操作 [0-7]: " choice

    case "$choice" in
        1) check_run "$SCRIPT_CORE" ;;
        2) check_run "$SCRIPT_BOOST" ;;
        3) check_run "$SCRIPT_ADD_XHTTP" ;;
        4) check_run "$SCRIPT_ADD_VISION" ;;
        5) check_run "$SCRIPT_REMOVE" ;;
        6) check_run "$SCRIPT_ATTACH" ;;
        7) check_run "$SCRIPT_DETACH" ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入，请重试。${PLAIN}"; sleep 1 ;;
    esac
    
    echo -e ""
    read -p "操作完成，按回车键返回主菜单..."
done
