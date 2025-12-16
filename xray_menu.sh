#!/bin/bash

# ============================================================
#  模块零：Xray 模块化总管 (Commander v2.0)
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# --- 脚本文件名与下载地址映射 ---
# 核心与环境
FILE_CORE="xray_core.sh"
URL_CORE="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_core.sh"

FILE_WARP="warp_wireproxy_socks5.sh"
URL_WARP="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/warp/warp_wireproxy_socks5.sh"

# 节点增加
FILE_ADD_XHTTP="xray_vless_xhttp_reality.sh"
URL_ADD_XHTTP="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_vless_xhttp_reality.sh"

FILE_ADD_VISION="xray_vless_vision_reality.sh"
URL_ADD_VISION="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_vless_vision_reality.sh"

# 节点删除与查看
FILE_NODE_DEL="xray_module_node_del.sh"
URL_NODE_DEL="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_module_node_del.sh"

FILE_NODE_INFO="xray_get_node_details.sh"
URL_NODE_INFO="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray_get_node_details.sh"

# 流量挂载
FILE_ATTACH="xray_module_attach_warp.sh"
URL_ATTACH="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_module_attach_warp.sh"

FILE_DETACH="xray_module_detach_warp.sh"
URL_DETACH="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_module_detach_warp.sh"

# 系统优化
FILE_BOOST="xray_module_boost.sh"
URL_BOOST="https://raw.githubusercontent.com/an2024520/test/refs/heads/main/xray/xray_module_boost.sh"

# 全局卸载 (本地生成，或者你可以上传这个新脚本到仓库)
FILE_UNINSTALL="xray_uninstall_all.sh"
# 如果你上传了该脚本，请替换下面的 URL；这里暂时假设它在本地生成或后续下载
URL_UNINSTALL="" 

# --- 核心函数：检查并运行 ---
check_run() {
    local script_name="$1"
    local script_url="$2"

    if [[ ! -f "$script_name" ]]; then
        echo -e "${YELLOW}脚本 [$script_name] 不存在，正在尝试下载...${PLAIN}"
        if [[ -z "$script_url" ]]; then
            echo -e "${RED}错误: 未定义下载地址，且本地文件不存在。${PLAIN}"
            read -p "按回车键返回..."
            return
        fi
        
        wget -O "$script_name" "$script_url"
        
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}下载失败！请检查网络或 URL。${PLAIN}"
            read -p "按回车键返回..."
            return
        fi
        echo -e "${GREEN}下载成功！${PLAIN}"
    fi

    chmod +x "$script_name"
    ./"$script_name"
    
    # 执行完脚本后，暂停一下给用户看结果
    echo -e ""
    read -p "操作结束，按回车键继续..."
}

# --- 菜单生成器 ---
while true; do
    clear
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    Xray 模块化管理系统 (Commander v2)   ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${SKYBLUE}1.${PLAIN} 前置安装 / 环境重置"
    echo -e "${SKYBLUE}2.${PLAIN} 节点管理 (新增 / 删除 / 查看)"
    echo -e "${SKYBLUE}3.${PLAIN} 出口分流 (Warp / Socks5)"
    echo -e "${SKYBLUE}4.${PLAIN} 系统内核加速 (BBR + ECN)"
    echo -e "${RED}5.${PLAIN} 彻底卸载 Xray 服务"
    echo -e "----------------------------------------"
    echo -e "${GRAY}0. 退出系统${PLAIN}"
    echo -e ""
    read -p "请选择操作 [0-5]: " main_choice

    case "$main_choice" in
        1)
            # 子菜单：前置安装
            while true; do
                clear
                echo -e "${YELLOW}>>> 子菜单：前置安装与环境${PLAIN}"
                echo -e "  1. 安装/重置 Xray 核心环境 (Core)"
                echo -e "  2. 管理 Warp/WireProxy 代理服务 (安装/卸载)"
                echo -e "  0. 返回上一级"
                echo -e ""
                read -p "请选择: " sub_choice_1
                case "$sub_choice_1" in
                    1) check_run "$FILE_CORE" "$URL_CORE" ;;
                    2) check_run "$FILE_WARP" "$URL_WARP" ;;
                    0) break ;;
                    *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
                esac
            done
            ;;
        2)
            # 子菜单：节点管理
            while true; do
                clear
                echo -e "${YELLOW}>>> 子菜单：节点管理${PLAIN}"
                echo -e "  1. 新增节点: VLESS-XHTTP (Reality - 穿透强)"
                echo -e "  2. 新增节点: VLESS-Vision (Reality - 极稳定)"
                echo -e "  3. 查看当前节点信息/分享链接"
                echo -e "  4. ${RED}删除/清空 节点${PLAIN}"
                echo -e "  0. 返回上一级"
                echo -e ""
                read -p "请选择: " sub_choice_2
                case "$sub_choice_2" in
                    1) check_run "$FILE_ADD_XHTTP" "$URL_ADD_XHTTP" ;;
                    2) check_run "$FILE_ADD_VISION" "$URL_ADD_VISION" ;;
                    3) check_run "$FILE_NODE_INFO" "$URL_NODE_INFO" ;;
                    4) check_run "$FILE_NODE_DEL" "$URL_NODE_DEL" ;;
                    0) break ;;
                    *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
                esac
            done
            ;;
        3)
            # 子菜单：出口分流
            while true; do
                clear
                echo -e "${YELLOW}>>> 子菜单：流量出口控制${PLAIN}"
                echo -e "  1. 挂载 WARP/Socks5 (解锁流媒体/ChatGPT)"
                echo -e "  2. 解除 挂载 (恢复直连/原生IP)"
                echo -e "  0. 返回上一级"
                echo -e ""
                read -p "请选择: " sub_choice_3
                case "$sub_choice_3" in
                    1) check_run "$FILE_ATTACH" "$URL_ATTACH" ;;
                    2) check_run "$FILE_DETACH" "$URL_DETACH" ;;
                    0) break ;;
                    *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
                esac
            done
            ;;
        4)
            # 直接运行加速
            check_run "$FILE_BOOST" "$URL_BOOST"
            ;;
        5)
            # 全局卸载
            # 如果本地没有卸载脚本，这里临时生成一个简单的，或者你可以上传到git后填入URL
            if [[ ! -f "$FILE_UNINSTALL" ]]; then
                cat <<EOF > "$FILE_UNINSTALL"
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
PLAIN='\033[0m'
echo -e "\${RED}警告: 即将删除 Xray 所有组件！\${PLAIN}"
read -p "确认继续? (y/n): " confirm
if [[ "\$confirm" == "y" ]]; then
    systemctl stop xray
    systemctl disable xray
    rm -rf /usr/local/bin/xray_core
    rm -rf /usr/local/etc/xray
    rm -rf /var/log/xray
    rm -f /etc/systemd/system/xray.service
    systemctl daemon-reload
    echo -e "\${GREEN}Xray 已彻底卸载。\${PLAIN}"
else
    echo "操作取消"
fi
EOF
                chmod +x "$FILE_UNINSTALL"
            fi
            ./"$FILE_UNINSTALL"
            echo -e ""
            read -p "操作结束，按回车键继续..."
            ;;
        0)
            echo -e "再见！"
            exit 0
            ;;
        *)
            echo -e "${RED}无效输入，请重试。${PLAIN}"
            sleep 1
            ;;
    esac
done
