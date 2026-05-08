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
print_warn()  { echo -e "${YELLOW}[注意]${RESET} $1" >&2; }

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
BASE_DIR="/root/catmi/nodepass"
CONF_DIR="$BASE_DIR/server"
BIN_PATH="$BASE_DIR/nodepass"
SYSTEMD_DIR="/etc/systemd/system"
mkdir -p "$CONF_DIR"

clean_input() {
    echo "$1" | tr -d '\000-\037'
}

# ================================
# 端口工具
# ================================
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
        printf "请输入本地监听端口 (默认: %s): " "$default" >&2
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
# NodePass 下载
# ================================
install_nodepass() {
    if [ -x "$BIN_PATH" ]; then
        return
    fi

    print_info "正在下载 NodePass 最新版本..."

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)   ARCH2="amd64" ;;
        aarch64)  ARCH2="arm64" ;;
        *) print_error "不支持的架构: $ARCH"; exit 1 ;;
    esac

    VERSION=$(curl -sL https://api.github.com/repos/NodePassProject/nodepass/releases/latest | grep tag_name | cut -d '"' -f4 | sed 's/v//')
    URL="https://github.com/NodePassProject/nodepass/releases/download/v${VERSION}/nodepass_${VERSION}_linux_${ARCH2}.tar.gz"

    mkdir -p "$BASE_DIR"
    wget -q --show-progress -O /tmp/nodepass.tar.gz "$URL"
    tar -xzf /tmp/nodepass.tar.gz -C /tmp
    install -m 755 /tmp/nodepass "$BIN_PATH"

    print_ok "NodePass 安装完成：$BIN_PATH"
}

# ================================
# ID 管理
# ================================
next_id() {
    local n
    n=$(ls "$CONF_DIR"/server-*.env 2>/dev/null | wc -l)
    echo $((n + 1))
}

gen_path() {
    echo "/$(cat /proc/sys/kernel/random/uuid | cut -d'-' -f1)"
}

gen_pass() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 24 | head -n 1
}

# ================================
# 新增隧道
# ================================
add_tunnel() {
    install_nodepass
    print_title "新增 NodePass 服务端隧道"

    # 服务 IP（用于 -tunnel-addr）
    service_ip=$(safe_read "请输入服务 IP" "127.0.0.1")

    # 本地监听端口
    default_port=$(random_free_port)
    local_port=$(safe_read_port "$default_port")

    # 路径
    default_path=$(gen_path)
    ws_path=$(safe_read "请输入路径" "$default_path")

    # 后端
    target_ip=$(safe_read "请输入后端 IP" "127.0.0.1")
    target_port=$(safe_read "请输入后端端口" "8080")

    # 密码（统一逻辑）
    random_pw=$(gen_pass)
    password=$(safe_read "请输入密码" "$random_pw")

    # 分配 ID
    id=$(next_id)
    id2=$(printf "%02d" "$id")
    conf="$CONF_DIR/server-$id2.env"
    svc="nodepass-server-$id2.service"

    # 保存 env
    cat > "$conf" <<EOF
ID=$id
SERVICE_IP=$service_ip
LOCAL_PORT=$local_port
WS_PATH=$ws_path
TARGET_IP=$target_ip
TARGET_PORT=$target_port
PASSWORD=$password
EOF

    # 写入 systemd
    cat > "$SYSTEMD_DIR/$svc" <<EOF
[Unit]
Description=NodePass Server Tunnel $id (ws $ws_path)
After=network.target

[Service]
Type=simple
ExecStart=$BIN_PATH server -tunnel-addr $service_ip -tunnel-port $local_port -pool 2 -tls 0 -target-addr $target_ip -target-port $target_port -password $password
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$svc"

    # ============================
    # 美化输出 + 客户端命令
    # ============================
    print_title "隧道创建成功"

    echo -e "${CYAN}协议:${RESET} ws"
    echo -e "${CYAN}服务 IP:${RESET} $service_ip"
    echo -e "${CYAN}监听:${RESET} $service_ip:$local_port"
    echo -e "${CYAN}路径:${RESET} $ws_path"
    echo -e "${CYAN}后端:${RESET} $target_ip:$target_port"
    echo -e "${CYAN}密码:${RESET} $password"
    echo -e "${CYAN}服务名:${RESET} $svc"
    echo

    print_info "客户端连接示例（NodePass 客户端）："
    echo -e "${GREEN}nodepass client -server ws://yourdomain.com$ws_path -password $password${RESET}"
    echo
}


# ================================
# 列表（带运行状态 + 明文密码）
# ================================
list_tunnels() {
    print_title "当前 NodePass 隧道列表"
    echo -e "${CYAN}编号 | 端口 | 路径 | 后端 | 密码 | 状态 | systemd 名称${RESET}" >&2
    echo "--------------------------------------------------------------------------------------------------------" >&2

    local any=0
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        any=1
        num=$(basename "$f" .env | cut -d'-' -f2)
        source "$f"
        svc="nodepass-server-$num.service"
        if systemctl is-active --quiet "$svc"; then
            st="${GREEN}运行中${RESET}"
        else
            st="${RED}未运行${RESET}"
        fi
        echo -e "${GREEN}$num${RESET}) 端口: ${YELLOW}$LOCAL_PORT${RESET} | 路径: ${MAGENTA}$WS_PATH${RESET} | 后端: ${BLUE}$TARGET_IP:$TARGET_PORT${RESET} | 密码: ${CYAN}$PASSWORD${RESET} | 状态: $st | 服务: ${CYAN}$svc${RESET}" >&2
    done

    [[ "$any" -eq 0 ]] && echo -e "${YELLOW}暂无隧道${RESET}" >&2
    echo "--------------------------------------------------------------------------------------------------------" >&2
}

# ================================
# 运行状态（单独视图）
# ================================
status_tunnels() {
    print_title "隧道运行状态"
    local any=0
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        any=1
        num=$(basename "$f" .env | cut -d'-' -f2)
        svc="nodepass-server-$num.service"
        if systemctl is-active --quiet "$svc"; then
            st="${GREEN}运行中${RESET}"
        else
            st="${RED}未运行${RESET}"
        fi
        echo -e "隧道 ${CYAN}$num${RESET} -> $svc : $st" >&2
    done
    [[ "$any" -eq 0 ]] && echo -e "${YELLOW}暂无隧道${RESET}" >&2
}

# ================================
# 日志
# ================================
view_logs() {
    list_tunnels
    printf "请输入要查看日志的编号: " >&2
    read num
    num=$(clean_input "$num")
    [[ -z "$num" || ! "$num" =~ ^[0-9]+$ ]] && { print_error "编号无效"; return; }
    id2=$(printf "%02d" "$num")
    svc="nodepass-server-$id2.service"

    if [ ! -f "$SYSTEMD_DIR/$svc" ]; then
        print_error "服务不存在: $svc"
        return
    fi

    print_info "显示 $svc 最近 50 行日志"
    journalctl -u "$svc" -n 50 --no-pager
}

# ================================
# 停止 / 启动 / 重启 / 删除
# ================================
stop_tunnel() {
    list_tunnels
    printf "请输入要停止的隧道编号: " >&2
    read num
    num=$(clean_input "$num")
    [[ -z "$num" || ! "$num" =~ ^[0-9]+$ ]] && { print_error "编号无效"; return; }
    id2=$(printf "%02d" "$num")
    svc="nodepass-server-$id2.service"
    if [ ! -f "$SYSTEMD_DIR/$svc" ]; then
        print_error "服务不存在: $svc"
        return
    fi
    systemctl stop "$svc"
    print_ok "已停止 $svc"
    systemctl status "$svc" --no-pager -l | head -n 5 >&2
}

start_tunnel() {
    list_tunnels
    printf "请输入要启动的隧道编号: " >&2
    read num
    num=$(clean_input "$num")
    [[ -z "$num" || ! "$num" =~ ^[0-9]+$ ]] && { print_error "编号无效"; return; }
    id2=$(printf "%02d" "$num")
    svc="nodepass-server-$id2.service"
    if [ ! -f "$SYSTEMD_DIR/$svc" ]; then
        print_error "服务不存在: $svc"
        return
    fi
    systemctl start "$svc"
    print_ok "已启动 $svc"
    systemctl status "$svc" --no-pager -l | head -n 5 >&2
}

restart_tunnel() {
    list_tunnels
    printf "请输入要重启的隧道编号: " >&2
    read num
    num=$(clean_input "$num")
    [[ -z "$num" || ! "$num" =~ ^[0-9]+$ ]] && { print_error "编号无效"; return; }
    id2=$(printf "%02d" "$num")
    svc="nodepass-server-$id2.service"
    if [ ! -f "$SYSTEMD_DIR/$svc" ]; then
        print_error "服务不存在: $svc"
        return
    fi
    systemctl restart "$svc"
    print_ok "已重启 $svc"
    systemctl status "$svc" --no-pager -l | head -n 5 >&2
}

delete_tunnel() {
    list_tunnels
    printf "请输入要删除的编号: " >&2
    read num
    num=$(clean_input "$num")
    [[ -z "$num" || ! "$num" =~ ^[0-9]+$ ]] && { print_error "编号无效"; return; }
    id2=$(printf "%02d" "$num")

    conf="$CONF_DIR/server-$id2.env"
    svc="nodepass-server-$id2.service"

    if [ ! -f "$conf" ]; then
        print_error "配置不存在: $conf"
        return
    fi

    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "$conf"
    rm -f "$SYSTEMD_DIR/$svc"
    systemctl daemon-reload

    print_ok "已删除隧道 $num"
}

delete_all() {
    print_title "删除所有隧道"
    read -p "确认删除所有隧道？(yes/no): " ans
    ans=$(clean_input "$ans")
    [ "$ans" != "yes" ] && { print_info "已取消"; return; }

    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        svc="nodepass-server-$num.service"
        systemctl disable --now "$svc" 2>/dev/null || true
        rm -f "$SYSTEMD_DIR/$svc"
        rm -f "$f"
    done

    systemctl daemon-reload
    print_ok "已删除所有隧道"
}

# ================================
# 菜单
# ================================
menu() {
    while true; do
        print_title "NodePass 服务端隧道面板"
        echo "1) 查看隧道列表 (含运行状态 + 密码)" >&2
        echo "2) 新增隧道" >&2
        echo "3) 查看隧道运行状态" >&2
        echo "4) 查看某个隧道日志" >&2
        echo "5) 停止某个隧道" >&2
        echo "6) 启动某个隧道" >&2
        echo "7) 重启某个隧道" >&2
        echo "8) 删除某个隧道" >&2
        echo "9) 删除所有隧道" >&2
        echo "0) 退出" >&2
        printf "请选择: " >&2

        read c
        c=$(clean_input "$c")

        case "$c" in
            1) list_tunnels;     printf "按回车继续..." >&2; read ;;
            2) add_tunnel;       printf "按回车继续..." >&2; read ;;
            3) status_tunnels;   printf "按回车继续..." >&2; read ;;
            4) view_logs;        printf "按回车继续..." >&2; read ;;
            5) stop_tunnel;      printf "按回车继续..." >&2; read ;;
            6) start_tunnel;     printf "按回车继续..." >&2; read ;;
            7) restart_tunnel;   printf "按回车继续..." >&2; read ;;
            8) delete_tunnel;    printf "按回车继续..." >&2; read ;;
            9) delete_all;       printf "按回车继续..." >&2; read ;;
            0) exit 0 ;;
            *) print_error "无效选项"; printf "按回车继续..." >&2; read ;;
        esac
    done
}

menu
