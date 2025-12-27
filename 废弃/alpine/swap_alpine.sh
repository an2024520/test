#!/bin/sh

# ============================================================
# 脚本名称：swap_alpine.sh (v1.0)
# 适用系统：Alpine Linux
# 特性：自动安装依赖、磁盘空间检查、OpenRC 兼容
# ============================================================

# 颜色定义
Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
Font="\033[0m"

# 1. Root 权限检查
root_need(){
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${Red}错误: 必须使用 root 用户运行此脚本！${Font}"
        exit 1
    fi
}

# 2. 环境初始化 (安装必要工具)
init_alpine(){
    echo -e "${Yellow}正在初始化 Alpine 环境...${Font}"
    # 安装 util-linux 以获得更可靠的 mkswap/swapon 和 bash (可选但推荐)
    apk update >/dev/null 2>&1
    apk add util-linux >/dev/null 2>&1
}

# 3. 虚拟化检查
ovz_check(){
    if [ -d "/proc/vz" ]; then
        echo -e "${Red}错误: 您的 VPS 基于 OpenVZ 架构，不支持创建 Swap 文件。${Font}"
        exit 1
    fi
}

# 4. 添加 Swap
add_swap(){
    echo -e "${Green}请输入需要添加的 Swap 值 (单位: MB):${Font}"
    read -p "建议为内存的 2 倍: " swapsize
    
    # 基础校验
    if ! [ "$swapsize" -eq "$swapsize" ] 2>/dev/null; then
        echo -e "${Red}错误: 请输入有效的数字。${Font}"; return
    fi

    # 磁盘空间检查
    # 获取根目录剩余空间 (KB)
    free_disk=$(df -k / | awk 'NR==2 {print $4}')
    need_disk=$((swapsize * 1024))
    
    if [ "$need_disk" -gt "$free_disk" ]; then
        echo -e "${Red}错误: 磁盘空间不足！剩余: $((free_disk/1024)) MB, 需要: ${swapsize} MB${Font}"
        return
    fi

    # 检查冲突
    if grep -q "/swapfile" /etc/fstab; then
        echo -e "${Red}错误: swapfile 已存在，请先删除后再设置！${Font}"
        return
    fi

    echo -e "${Yellow}正在创建 swapfile (${swapsize}MB)...${Font}"
    # Alpine 下使用 dd 确保最大兼容性
    dd if=/dev/zero of=/swapfile bs=1M count=${swapsize} status=progress
    
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # 写入 fstab 实现开机自启
    echo '/swapfile none swap defaults 0 0' >> /etc/fstab
    
    echo -e "${Green}Swap 创建成功！${Font}"
    free -m
}

# 5. 删除 Swap
del_swap(){
    if ! grep -q "/swapfile" /etc/fstab; then
        echo -e "${Red}未发现 swapfile 条目。${Font}"
        return
    fi

    echo -e "${Yellow}正在移除 swapfile...${Font}"
    swapoff /swapfile 2>/dev/null
    sed -i '/\/swapfile/d' /etc/fstab
    rm -f /swapfile
    
    echo -e "${Green}Swap 已成功删除。${Font}"
    free -m
}

# 主菜单
main(){
    root_need
    init_alpine
    ovz_check
    
    clear
    echo -e "———————————————————————————————————————"
    echo -e "${Green}Alpine Linux Swap 管理脚本 (优化版)${Font}"
    echo -e " 1. 添加 Swap"
    echo -e " 2. 删除 Swap"
    echo -e " 0. 退出"
    echo -e "———————————————————————————————————————"
    read -p "请选择 [0-2]: " num
    
    case "$num" in
        1) add_swap ;;
        2) del_swap ;;
        0) exit 0 ;;
        *) main ;;
    esac
}

main
