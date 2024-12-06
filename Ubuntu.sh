#!/bin/bash
# 介绍信息
printf "\e[92m"
printf "                       |\\__/,|   (\\\\ \n"
printf "                     _.|o o  |_   ) )\n"
printf "       -------------(((---(((-------------------\n"
printf "                    catmi-一键脚本 \n"
printf "       -----------------------------------------\n"
printf "\e[0m"


# 基础依赖检查和安装
initialize_dependencies() {
    echo "检查并安装基础依赖..."
    apt-get update -y && apt install sudo -y && apt install nano -y && apt install wget -y || { echo "依赖安装失败，请检查网络环境！"; exit 1; }
    echo "基础依赖安装完成。"
}

# 创建面板函数
main_menu() {
    clear
    echo -e "\e[92m"
    echo "================================================="
    echo "                   Catmiup 面板            "
    echo "================================================="
    echo -e "\e[0m"
    echo "1) 安装 Kejilion 工具箱"
    echo "2) 安装 Hysteria2"
    echo "3) 安装 warp"
    echo "4) 安装 Sing-box"
    echo "5) 安装 xray"
    echo "0) 退出面板"
    echo
    echo -n "请选择操作: "
    read choice

    case $choice in
        1) install_toolbox ;;
        2) install_hysteria ;;
        3) install_warp ;;
        4) install_singbox ;;
        5) install_xray ;;
        0) exit_program ;;
        *) 
            echo "无效选项，请重新选择。"
            read -p "按回车返回主菜单..."
            main_menu
            ;;
    esac
}

# 安装工具函数
install_toolbox() {
    echo "开始安装 Kejilion 工具箱..."
    curl -sS -O https://raw.githubusercontent.com/kejilion/sh/main/kejilion.sh || { echo "工具箱下载失败"; return; }
    chmod +x kejilion.sh && ./kejilion.sh
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

install_hysteria() {
    echo "开始安装 Alpine-Hysteria2..."
    bash <(curl -fsSL https://github.com/mi1314cat/hysteria2-core/raw/refs/heads/main/hy2-panel.sh) || { echo "Hysteria2 安装失败"; return; }
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

install_warp() {
    echo "开始安装 warp..."
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh; sed -i "s#WIREGUARD_GO_ENABLE=0#WIREGUARD_GO_ENABLE=1#g" menu.sh; bash menu.sh
    
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

install_singbox() {
    echo "开始安装 Sing-box..."
    bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh) || { echo "Sing-box 安装失败"; return; }
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

install_xray() {
    echo "请选择脚本安装方式："
    echo "1) 安装支持 IPv4 的脚本"
    echo "2) 安装支持 IPv6 的脚本"
    read -p "请输入选项 (1 或 2): " vchoice

    case $vchoice in
        1)
            echo "安装支持 IPv4 的脚本..."
            bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/vless.sh) || { echo "IPv4 脚本安装失败"; return; }
            ;;
        2)
            echo "安装支持 IPv6 的脚本..."
            bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/6vless.sh) || { echo "IPv6 脚本安装失败"; return; }
            ;;
        *)
            echo "无效的选项，返回主菜单。"
            ;;
    esac
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

exit_program() {
    echo "退出面板 Catmiup 面板！"
    exit 0
}

# 快捷方式设置函数
create_shortcut() {
    local shortcut_path="/usr/local/bin/catmiup"
    echo "创建快捷方式：${shortcut_path}"
    echo 'bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/Ubuntu.sh)' > "$shortcut_path"
    chmod +x "$shortcut_path"
    echo "快捷方式创建成功！直接运行 'catmiup' 启动面板。"
}

# 主函数
main() {
    initialize_dependencies
    create_shortcut
    main_menu
}

main
