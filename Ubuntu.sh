#!/bin/bash
# 介绍信息
printf "\e[92m"
printf "                       |\\__/,|   (\\\\ \n"
printf "                     _.|o o  |_   ) )\n"
printf "       -------------(((---(((-------------------\n"
printf "                    catmi-一键脚本 \n"
printf "       -----------------------------------------\n"
printf "\e[0m"
apt-get update -y && apt install sudo -y && apt install nano -y && apt install wget -y

# 添加回车等待
#!/bin/bash

# 按回车继续执行安装kejilion工具箱脚本
read -p "按回车继续执行安装warp（输入n跳过）..." input
if [[ "$input" != "n" ]]; then
    clear
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh; sed -i "s#WIREGUARD_GO_ENABLE=0#WIREGUARD_GO_ENABLE=1#g" menu.sh; bash menu.sh
fi

# 添加回车等待安装 hysteria2
read -p "按回车继续执行安装hysteria2（输入n跳过）..." input
if [[ "$input" != "n" ]]; then
    clear
    bash <(curl -fsSL https://github.com/mi1314cat/hysteria2-core/raw/refs/heads/main/hy2-panel.sh)
fi

# 添加回车等待安装 sing-box
read -p "按回车继续执行安装sing-box（输入n跳过）..." input
if [[ "$input" != "n" ]]; then
    bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh)
fi
