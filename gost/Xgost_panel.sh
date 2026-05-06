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

get_env() {
    grep "^$2=" "$1" | cut -d'=' -f2
}

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
        local_port=$(get_env "$f" "LOCAL_PORT")
        ws_path=$(get_env "$f" "WS_PATH")
        svc="xgost-server-$num.service"

        echo -e "${GREEN}服务端${RESET} | ${YELLOW}$local_port${RESET} | - | - | ${MAGENTA}$ws_path${RESET} | ${BLUE}$svc${RESET}" >&2
    done

    # -------- 客户端隧道 --------
    for f in "$CLIENT_CONF"/client-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        local_port=$(get_env "$f" "LOCAL_PORT")
        remote_port=$(get_env "$f" "REMOTE_PORT")
        domain=$(get_env "$f" "DOMAIN")
        ws_path=$(get_env "$f" "WS_PATH")
        svc="xgost-client-$num.service"

        echo -e "${GREEN}客户端${RESET} | ${YELLOW}$local_port${RESET} | ${CYAN}$remote_port${RESET} | ${MAGENTA}$domain${RESET} | ${WHITE}$ws_path${RESET} | ${BLUE}$svc${RESET}" >&2
    done

    echo "--------------------------------------------------------------------------------" >&2
}

# ================================
# 显示 gost 监听端口 + 连接数 + IP 列表 + 延迟
# ================================
show_gost_listen_ports() {
    print_title "Gost 监听端口（连接数 / IP 列表 / 延迟）"

    echo -e "${CYAN}端口 | 连接数 | 连接 IP:端口 | 延迟(ms)${RESET}"
    echo "--------------------------------------------------------------------------------"

    # 获取所有 gost 监听端口
    ports=$(ss -lntp | grep gost | awk '{print $4}' | sed 's/.*://g' | sort -n | uniq)

    for p in $ports; do
        # 获取连接列表
        conns=$(ss -tn sport = :$p | grep ESTAB | awk '{print $5}')

        # 连接数
        count=$(echo "$conns" | wc -l)
        [[ "$conns" == "" ]] && count=0

        # 输出端口行
        echo -e "${YELLOW}$p${RESET} | ${GREEN}$count${RESET}"

        # 如果没有连接，继续下一个端口
        if [[ "$count" -eq 0 ]]; then
            echo "--------------------------------------------------------------------------------"
            continue
        fi

        # 遍历每个连接
        while read -r ipport; do
            [[ -z "$ipport" ]] && continue

            ip=$(echo "$ipport" | cut -d':' -f1)

            # ping 获取延迟（只 ping 一次）
            delay=$(ping -c 1 -W 1 "$ip" 2>/dev/null | grep "time=" | sed 's/.*time=\(.*\) ms/\1/')

            [[ -z "$delay" ]] && delay="超时"

            echo -e "      → ${MAGENTA}$ipport${RESET} | ${CYAN}$delay${RESET} ms"
        done <<< "$conns"

        echo "--------------------------------------------------------------------------------"
    done
}

# ================================
# 查看客户端映射状态（服务端可见）
# ================================
check_client_mapping() {
    print_title "客户端映射状态（服务端可见）"

    echo -e "${CYAN}服务端端口 | 客户端连接数 | 客户端 IP:端口 列表${RESET}" >&2
    echo "--------------------------------------------------------------------------------" >&2

    for f in "$SERVER_CONF"/server-*.env; do
        [[ -f "$f" ]] || continue

        local_port=$(get_env "$f" "LOCAL_PORT")

        connections=$(ss -tn sport = :$local_port | grep ESTAB | wc -l || true)
        client_info=$(ss -tn sport = :$local_port | grep ESTAB | awk '{print $5}' | tr '\n' ' ' || true)

        if [ "$connections" -gt 0 ]; then
            status="${GREEN}已映射${RESET}"
        else
            status="${RED}未映射${RESET}"
        fi

        echo -e "${YELLOW}$local_port${RESET} | ${CYAN}$connections${RESET} | $status | ${MAGENTA}${client_info:--}${RESET}" >&2
    done

    echo "--------------------------------------------------------------------------------" >&2

    echo -e "\n${CYAN}↓ 同时显示所有隧道端口 ↓${RESET}\n" >&2
    show_ports

    echo -e "\n${CYAN}↓ Gost 监听端口（含连接数 / IP / 延迟） ↓${RESET}\n" >&2
    show_gost_listen_ports
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
        echo "4) 查看客户端映射状态（服务端）" >&2
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
            4)
                check_client_mapping
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
