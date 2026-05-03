#!/usr/bin/env bash
set -e

# ================================
# 彩色定义
# ================================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
WHITE="\e[97m"
BOLD="\e[1m"
RESET="\e[0m"

print_title() {
    echo -e "${MAGENTA}${BOLD}" >&2
    echo "╔══════════════════════════════════════════════╗" >&2
    printf "║ %-42s ║\n" "$1" >&2
    echo "╚══════════════════════════════════════════════╝" >&2
    echo -e "${RESET}" >&2
}

# ================================
# Banner
# ================================
print_banner() {
cat << "EOF"
                       |\__/,|   (\\
                     _.|o o  |_   ) )
       -------------(((---(((-------------------
                   catmi.xgost
       -----------------------------------------
EOF
}

BASE_DIR="/root/catmi/xgost"
SERVER_CONF="$BASE_DIR/server"
CLIENT_CONF="$BASE_DIR/client"

mkdir -p "$SERVER_CONF" "$CLIENT_CONF"

# ================================
# 查看所有隧道端口
# ================================
show_ports() {
    print_title "Gost 隧道端口总览"

    echo -e "${CYAN}类型 | 本地端口 | 远程端口 | 域名 | 路径 | systemd${RESET}" >&2
    echo "--------------------------------------------------------------------------------" >&2

    # -------- 服务端隧道 --------
    for f in "$SERVER_CONF"/server-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        local_port=$(grep '^LOCAL_PORT=' "$f" | cut -d'=' -f2)
        ws_path=$(grep '^WS_PATH=' "$f" | cut -d'=' -f2)
        svc="xgost-server-$num.service"

        echo -e "${GREEN}服务端${RESET} | ${YELLOW}$local_port${RESET} | - | - | ${MAGENTA}$ws_path${RESET} | ${BLUE}$svc${RESET}" >&2
    done

    # -------- 客户端隧道 --------
    for f in "$CLIENT_CONF"/client-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        local_port=$(grep '^LOCAL_PORT=' "$f" | cut -d'=' -f2)
        remote_port=$(grep '^REMOTE_PORT=' "$f" | cut -d'=' -f2)
        domain=$(grep '^DOMAIN=' "$f" | cut -d'=' -f2)
        ws_path=$(grep '^WS_PATH=' "$f" | cut -d'=' -f2)
        svc="xgost-client-$num.service"

        echo -e "${GREEN}客户端${RESET} | ${YELLOW}$local_port${RESET} | ${CYAN}$remote_port${RESET} | ${MAGENTA}$domain${RESET} | ${WHITE}$ws_path${RESET} | ${BLUE}$svc${RESET}" >&2
    done

    echo "--------------------------------------------------------------------------------" >&2
}

# ================================
# 主菜单
# ================================
menu() {
    while true; do
        clear
        print_banner
        print_title "XGost 总面板"

        echo "1) 进入服务端面板 (gosts.sh)" >&2
        echo "2) 进入客户端面板 (gostc.sh)" >&2
        echo "3) 查看所有 gost 隧道端口" >&2
        echo "0) 退出" >&2

        printf "请选择: " >&2
        read c

        case "$c" in
            1)
                bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/gost/gosts.sh)
                ;;
            2)
                bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/gost/gostc.sh)
                ;;
            3)
                show_ports
                printf "按回车继续..." >&2
                read
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项${RESET}" >&2
                ;;
        esac
    done
}

menu
