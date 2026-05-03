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

print_info()  { echo -e "${CYAN}[Info]${RESET} $1" >&2; }
print_ok()    { echo -e "${GREEN}[OK]${RESET}  $1" >&2; }
print_error() { echo -e "${RED}[Error]${RESET} $1" >&2; }

print_title() {
    echo -e "${MAGENTA}${BOLD}" >&2
    echo "╔══════════════════════════════════════════════╗" >&2
    printf "║ %-42s ║\n" "$1" >&2
    echo "╚══════════════════════════════════════════════╝" >&2
    echo -e "${RESET}" >&2
}

# ================================
# 基础路径
# ================================
BASE_DIR="/root/catmi/xgost"
CONF_DIR="$BASE_DIR/client"
GOST_BIN="$BASE_DIR/gost"
SYSTEMD_DIR="/etc/systemd/system"

mkdir -p "$CONF_DIR"

# ================================
# 工具函数
# ================================
clean_input() {
    echo "$1" | tr -d '\000-\037'
}

port_in_use() {
    ss -tuln | awk '{print $5}' | grep -E -q "(:|])$1$"
}

random_port() { shuf -i 10000-60000 -n 1; }

random_free_port() {
    while true; do
        p=$(random_port)
        if ! port_in_use "$p"; then
            echo "$p"
            return
        fi
    done
}

safe_read() {
    local prompt="$1" default="$2" input
    printf "%s (默认: %s): " "$prompt" "$default" >&2
    read input
    input=$(clean_input "$input")
    echo "${input:-$default}"
}

safe_read_port() {
    local default="$1" input port
    while true; do
        printf "请输入端口 (默认: %s): " "$default" >&2
        read input
        input=$(clean_input "$input")
        port="${input:-$default}"

        [[ "$port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; continue; }
        (( port >= 1 && port <= 65535 )) || { print_error "端口范围错误"; continue; }
        port_in_use "$port" && { print_error "端口已占用"; continue; }

        echo "$port"
        return
    done
}

# ================================
# 下载 gost
# ================================
install_gost() {
    if [ -x "$GOST_BIN" ]; then
        return
    fi

    print_info "未检测到 gost，正在下载..."

    local ARCH FILE_SUFFIX API_JSON URL VERSION
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)       FILE_SUFFIX="linux_amd64.tar.gz" ;;
        aarch64)      FILE_SUFFIX="linux_arm64.tar.gz" ;;
        armv7l|armhf) FILE_SUFFIX="linux_armv7.tar.gz" ;;
        *) print_error "不支持的架构: $ARCH"; exit 1 ;;
    esac

    API_JSON=$(curl -sL https://api.github.com/repos/go-gost/gost/releases/latest)
    URL=$(echo "$API_JSON" | grep browser_download_url | cut -d '"' -f4 | grep "$FILE_SUFFIX" | head -n1)

    wget -O /tmp/gost.tar.gz "$URL"
    tar -xzf /tmp/gost.tar.gz -C /tmp
    install -m 755 /tmp/gost "$GOST_BIN"

    print_ok "gost 安装完成：$GOST_BIN"
}

# ================================
# 隧道编号
# ================================
next_id() {
    local n
    n=$(ls "$CONF_DIR"/client-*.env 2>/dev/null | wc -l)
    echo $((n + 1))
}

# ================================
# 列出隧道
# ================================
list_tunnels() {
    print_title "客户端隧道列表"

    echo -e "${CYAN}编号 | 本地端口 | 远程端口 | 域名 | 协议 | 路径 | systemd${RESET}" >&2
    echo "--------------------------------------------------------------------------------" >&2

    for f in "$CONF_DIR"/client-*.env; do
        [[ -f "$f" ]] || continue

        num=$(basename "$f" .env | cut -d'-' -f2)
        local_port=$(grep '^LOCAL_PORT=' "$f" | cut -d'=' -f2)
        remote_port=$(grep '^REMOTE_PORT=' "$f" | cut -d'=' -f2)
        domain=$(grep '^DOMAIN=' "$f" | cut -d'=' -f2)
        scheme=$(grep '^SCHEME=' "$f" | cut -d'=' -f2)
        ws_path=$(grep '^WS_PATH=' "$f" | cut -d'=' -f2)

        svc="xgost-client-$(printf "%02d" "$num").service"

        echo -e "${GREEN}$num${RESET}) 本地: ${YELLOW}$local_port${RESET} | 远程: ${CYAN}$remote_port${RESET} | 域名: ${MAGENTA}$domain${RESET} | 协议: ${BLUE}$scheme${RESET} | 路径: ${WHITE}$ws_path${RESET} | $svc" >&2
    done

    echo "--------------------------------------------------------------------------------" >&2
}

# ================================
# 新增隧道
# ================================
add_tunnel() {
    install_gost
    print_title "新增客户端隧道"

    # ================================
    # 本地端口（LOCAL_PORT）
    # 作用：
    #   - 这是客户端本地监听的端口
    #   - 你的程序连接这个端口后，数据会进入 RTCP 隧道
    #   - 相当于隧道的“入口”
    #   - 每个隧道都需要独立的本地端口
    # ================================
    local_port=$(safe_read_port "$(random_free_port)")

    # ================================
    # RTCP 远程端口（REMOTE_PORT）
    # 作用：
    #   - 这是 RTCP 在远端（Cloudflare 侧）监听的端口
    #   - relay+ws / relay+wss 会连接这个端口
    #   - 相当于隧道的“出口”
    #   - 每个隧道必须使用不同的远程端口
    # ================================
    remote_port=$(safe_read_port "$(random_free_port)")

    domain=$(safe_read "请输入 CF 域名" "")
    [ -z "$domain" ] && { print_error "域名不能为空"; return; }

    # ================================
    # 访问协议选择
    # http  → relay+ws://域名:80
    # https → relay+wss://域名:443
    # Cloudflare 允许的端口：
    #   - 80  (ws)
    #   - 443 (wss)
    # ================================
    echo -e "请选择协议：" >&2
    echo "1) http  (relay+ws, 端口 80)" >&2
    echo "2) https (relay+wss, 端口 443)" >&2
    printf "选择 (默认 2): " >&2
    read proto_choice
    proto_choice=$(clean_input "$proto_choice")

    case "$proto_choice" in
        1) scheme="ws";  port=80 ;;
        2|"") scheme="wss"; port=443 ;;
        *) scheme="wss"; port=443 ;;
    esac

    default_path="/$(cat /proc/sys/kernel/random/uuid)"
    ws_path=$(safe_read "请输入 WS 路径" "$default_path")

    id=$(next_id)
    id2=$(printf "%02d" "$id")
    conf="$CONF_DIR/client-$id2.env"
    svc="xgost-client-$id2.service"

cat > "$conf" <<EOF
ID=$id
LOCAL_PORT=$local_port
REMOTE_PORT=$remote_port
DOMAIN=$domain
SCHEME=$scheme
PORT=$port
WS_PATH=$ws_path
EOF

cat > "$SYSTEMD_DIR/$svc" <<EOF
[Unit]
Description=XGost Client Tunnel $id
After=network.target

[Service]
Type=simple
ExecStart=$GOST_BIN -L "rtcp://:$remote_port/127.0.0.1:$local_port" -F "relay+${scheme}://${domain}:$port?path=$ws_path&host=$domain"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$svc"

    print_ok "客户端隧道创建成功"
    echo -e "编号: $id\n本地端口: $local_port\n远程端口: $remote_port\n域名: $domain\n协议: $scheme\n路径: $ws_path\nsystemd: $svc" >&2
}


# ================================
# 查看状态
# ================================
status_tunnels() {
    print_title "客户端隧道状态"
    for f in "$CONF_DIR"/client-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        svc="xgost-client-$num.service"

        if systemctl is-active --quiet "$svc"; then
            st="${GREEN}运行中${RESET}"
        else
            st="${RED}未运行${RESET}"
        fi

        echo -e "隧道 ${CYAN}$num${RESET} -> $svc : $st" >&2
    done
}

# ================================
# 查看日志
# ================================
view_logs() {
    list_tunnels
    printf "请输入要查看日志的编号: " >&2
    read num
    num=$(clean_input "$num")
    id2=$(printf "%02d" "$num")
    svc="xgost-client-$id2.service"

    if [ ! -f "$SYSTEMD_DIR/$svc" ]; then
        print_error "服务不存在: $svc"
        return
    fi

    print_info "显示 $svc 最近 50 行日志"
    journalctl -u "$svc" -n 50 --no-pager
}

# ================================
# 删除隧道
# ================================
delete_tunnel() {
    list_tunnels
    printf "请输入要删除的编号: " >&2
    read num
    num=$(clean_input "$num")
    id2=$(printf "%02d" "$num")

    conf="$CONF_DIR/client-$id2.env"
    svc="xgost-client-$id2.service"

    if [ ! -f "$conf" ]; then
        print_error "配置不存在: $conf"
        return
    fi

    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "$conf"
    rm -f "$SYSTEMD_DIR/$svc"
    systemctl daemon-reload

    print_ok "已删除客户端隧道 $num"
}

# ================================
# 删除全部隧道
# ================================
delete_all() {
    print_title "删除所有客户端隧道"
    read -p "确认删除所有客户端隧道？(yes/no): " ans
    ans=$(clean_input "$ans")
    [ "$ans" != "yes" ] && { print_info "已取消"; return; }

    for f in "$CONF_DIR"/client-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        svc="xgost-client-$num.service"
        systemctl disable --now "$svc" 2>/dev/null || true
        rm -f "$SYSTEMD_DIR/$svc"
        rm -f "$f"
    done

    systemctl daemon-reload
    print_ok "已删除所有客户端隧道"
}

# ================================
# 主菜单
# ================================
menu() {
    while true; do
        print_title "XGost 客户端隧道面板"

        echo "1) 查看隧道列表" >&2
        echo "2) 新增隧道" >&2
        echo "3) 查看隧道状态" >&2
        echo "4) 查看某个隧道日志" >&2
        echo "5) 删除某个隧道" >&2
        echo "6) 删除所有隧道" >&2
        echo "0) 退出" >&2

        printf "请选择: " >&2
        read c
        c=$(clean_input "$c")

        case "$c" in
            1) list_tunnels;   printf "按回车继续..." >&2; read ;;
            2) add_tunnel;     printf "按回车继续..." >&2; read ;;
            3) status_tunnels; printf "按回车继续..." >&2; read ;;
            4) view_logs;      printf "按回车继续..." >&2; read ;;
            5) delete_tunnel;  printf "按回车继续..." >&2; read ;;
            6) delete_all;     printf "按回车继续..." >&2; read ;;
            0) exit 0 ;;
            *) print_error "无效选项"; printf "按回车继续..." >&2; read ;;
        esac
    done
}

menu
