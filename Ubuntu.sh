#!/bin/bash
# 介绍信息
printf "\e[92m"
printf "                       |\\__/,|   (\\\\ \n"
printf "                     _.|o o  |_   ) )\n"
printf "       -------------(((---(((-------------------\n"
printf "                    catmi-一键脚本 \n"
printf "       -----------------------------------------\n"
printf "\e[0m"
apt-get update -y && apt install curl -y && apt install sudo -y && apt install nano -y

# 添加回车等待
read -p "按回车继续执行安装kejilion工具箱脚本..."
clear
curl -sS -O https://raw.githubusercontent.com/kejilion/sh/main/kejilion.sh && chmod +x kejilion.sh && ./kejilion.sh


# 添加回车等待
read -p "按回车继续执行安装hysteria2..."
clear
bash <(curl -fsSL https://github.com/mi1314cat/hysteria2-core/raw/refs/heads/main/hy2-panel.sh)

# 添加回车等待
read -p "按回车继续执行安装sing-box..."

bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh)
