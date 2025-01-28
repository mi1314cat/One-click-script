#!/bin/bash

# 检查系统类型并运行对应的脚本
run_script() {
    local os_name="$(grep -E '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')"

    case "$os_name" in
        debian|ubuntu)
            echo "检测到系统: $os_name"
            apt update && apt install bash  &&  apt install curl -y && bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/Ubuntu.sh)
            ;;
        alpine)
            echo "检测到系统: $os_name"
            apt update && apt install bash  &&  apt install curl -y && bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/Ubuntu.sh)
            ;;
        *)
            echo "不支持的系统: $os_name。此脚本不支持当前系统，程序退出。"
            exit 1
            ;;
    esac
}



# 调用函数
run_script
