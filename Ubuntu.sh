#!/bin/bash
# 定义颜色变量
GREEN="\033[32m"
RED="\033[31m"
PLAIN="\033[0m"


# 介绍信息
printf "\e[92m"
printf "                       |\\__/,|   (\\\\ \n"
printf "                     _.|o o  |_   ) )\n"
printf "       -------------(((---(((-------------------\n"
printf "                    catmi-一键脚本 \n"
printf "       -----------------------------------------\n"
printf "\e[0m"




# 创建面板函数
main_menu() {
    clear
    echo -e "\e[92m"
    echo "================================================="
    echo "                   Catmiup 面板            "
    echo "================================================="
    echo -e "\e[0m"
    echo "00) 安装基础依赖"
    echo "1) 安装 Kejilion 工具箱"
    echo "2) 安装 Hysteria2"
    echo "3) 安装 warp"
    echo "4) 安装 Sing-box"
    echo "5) 安装 xray"
    echo "6) 安装 mihomo"
    echo "99) 节点信息"
    echo "0) 退出面板"
    echo
    echo -n "请选择操作: "
    read choice

    case $choice in
        00) initialize_dependencies ;;
        1) install_toolbox ;;
        2) install_hysteria ;;
        3) install_warp ;;
        4) install_singbox ;;
        5) install_xray ;;
        6) bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/mihomo-au.sh) ;;
        99) catmi-xx ;;
        0) exit_program ;;
        *) 
            echo "无效选项，请重新选择。"
            read -p "按回车返回主菜单..."
            main_menu
            ;;
    esac
}
# 基础依赖检查和安装
initialize_dependencies() {
    echo "检查并安装基础依赖..."
    apt update 
    apt install ufw -y
    apt install -y curl socat git cron openssl gzip nano sudo wget
  
    echo "基础依赖安装完成。"
    read -p "安装完成，按回车返回主菜单..."
    main_menu
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
    echo "开始安装 Hysteria2..."
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
    echo "选择 Sing-box 安装源:"
    echo "0) 返回主菜单"
    echo "1) 使用 catmi 2 "
    echo "2) 使用 catmising-box 6"
    echo "3) 使用 catmising-box 4"
    echo "4) 使用 sb "
    read -p "请输入选项 [0-4]: " choice

    case $choice in
        0)
            echo "已选择返回主菜单..."
            main_menu
            return
            ;;
        1)
            echo "开始安装 Sing-box ..."
            bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh) || { echo "Sing-box 安装失败"; return; }
            ;;
        2)
            echo "开始安装 Sing-box ..."
            bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/singbox.sh) || { echo "Sing-box 安装失败"; return; }
            ;;
        3)
            echo "开始安装 Sing-box ..."
            bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/nsb.sh) || { echo "Sing-box 安装失败"; return; }
            ;;    
        4)
            echo "开始安装 Sing-box ..."
            bash <(wget -qO- https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh) || { echo "Sing-box 安装失败"; return; }
            ;;    
        *)
            echo "无效的选项，返回主菜单..."
            main_menu
            return
            ;;
    esac

    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

install_xray() {
# 获取服务状态
xrayls_server_status=$(systemctl is-active xrayls.service)

# 生成状态文本
xrayls_server_status_text=$(
    if [[ "$xrayls_server_status" == "active" ]]; then
        printf "${GREEN}启动${PLAIN}"
    else
        printf "${RED}未启动${PLAIN}"
    fi
)

    echo "请选择脚本安装方式："
    echo -e "\e[92m"
    echo "================================================="
    echo "         xrayls 服务状态: ${xrayls_server_status_text}                      "
    echo "================================================="
    echo -e "\e[0m"
    echo "0) 返回主菜单"
    echo "1) 安装nginx+xray vless vmess xhttp"
    echo "2) 安装nginx+xray+argo vless vmess"
    echo "3) 安装跟新xray-core"
    read -p "请输入选项: " vchoice

    case $vchoice in
        0)
            echo "已选择返回主菜单..."
            main_menu
            return
            ;;
        1)
            echo "安装nginx+xray vless vmess xhttp..."
            bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/xary-core/raw/refs/heads/main/xray-panel.sh) || { echo "脚本安装失败"; return; }
            ;;
        2)
            echo "安装nginx+xray+argo vless vmess..."
            bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/xargo.sh) || { echo "脚本安装失败"; return; }
            ;;
        3)
            echo "安装跟新xray-core"
            bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/upxray.sh) || { echo "安装跟新xray-core失败"; return; }
            ;;    
        *)
            echo "无效的选项，返回主菜单。"
            ;;
    esac
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}
catmi-xx() {
    echo "========== 配置文件 =========="

    for file in \
        /root/hy2/config.yaml \
        /root/catmi/xray/clash-meta.yaml \
        /root/catmi/mihomo/clash-meta.yaml \
        /root/catmi/singbox/clash-meta.yaml
    do
        echo "------ $file ------"
        if [ -f "$file" ]; then
            cat "$file"
        else
            echo "[未找到] $file"
        fi
        echo
    done

    echo "*********************************"
    echo "========== V2Ray 文件 =========="

    for file in \
        /root/catmi/singbox/v2ray.txt \
        /root/catmi/mihomo/v2ray.txt \
        /root/catmi/xray/v2ray.txt
    do
        echo "------ $file ------"
        if [ -f "$file" ]; then
            cat "$file"
        else
            echo "[未找到] $file"
        fi
        echo
    done

    echo "*********************************"
    echo "========== xhttp.json =========="

    file=/root/catmi/xray/xhttp.json
    echo "------ $file ------"
    if [ -f "$file" ]; then
        cat "$file"
    else
        echo "[未找到] $file"
    fi

    echo
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
    
    create_shortcut
    main_menu
}

main
