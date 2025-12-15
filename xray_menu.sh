#!/bin/bash
echo -e "开始下载所有所需脚本。"
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
        echo -e "开始下载所有所需脚本。"
wget -O xray_core.sh https://raw.githubusercontent.com/an2024520/test/refs/heads/main/%E5%9C%B0%E5%9F%BA_xray_core
wget -O xray_vless_xhttp.sh https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray%E6%A8%A1%E5%9D%97_vless%2Bxhttp%2Breality.sh
wget -O xray_vless_vision.sh https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray%E6%A8%A1%E5%9D%97_vless_tcp_reality_Vision
wget -O xray_module4_remove.sh https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray_%E5%88%A0%E9%99%A4%E8%8A%82%E7%82%B9%E4%BB%A5%E5%8F%8A%E5%AF%B9%E5%BA%94%E8%B7%AF%E7%94%B1%E8%A7%84%E5%88%99.sh
wget -O xray_module5_boost.sh https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray_BBR%20%2B%20ECN%20%2B%20%E5%86%85%E6%A0%B8%E4%BC%98%E5%8C%96
wget -O xray_module6_attach_warp.sh https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray_%E7%BB%99%E8%8A%82%E7%82%B9%E5%A5%97%E4%B8%8A%E6%9C%AC%E5%9C%B0SOCKS5.sh
wget -O xray_module7_detach_warp.sh https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray_%E5%8F%96%E6%B6%88%E8%8A%82%E7%82%B9%E7%9A%84socks5%E5%87%BA%E5%8F%A3.sh
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
