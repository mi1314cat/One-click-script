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

BASE_DIR="/root/catmi/xgost"
CONF_DIR="$BASE_DIR/server"
GOST_BIN="$BASE_DIR/gost"
SYSTEMD_DIR="/etc/systemd/system"
mkdir -p "$CONF_DIR"

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

# 生成随机强密码（32位）
random_auth_pass() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1
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

# ---------- Base64 编码工具 ----------
base64_encode() {
    local input="$1"
    if command -v base64 >/dev/null 2>&1; then
        echo -n "$input" | base64 -w 0
    elif command -v openssl >/dev/null 2>&1; then
        echo -n "$input" | openssl base64 -A
    else
        print_error "系统中未找到 base64 或 openssl 命令，无法进行认证编码。"
        print_info "请安装 coreutils 或 openssl 后重试。"
        exit 1
    fi
}

install_gost() {
    if [ -x "$GOST_BIN" ]; then
        if "$GOST_BIN" -V 2>&1 | grep -qi "gost"; then
            return
        fi
    fi
    print_info "未检测到 gost，正在下载最新版 (v3)..."
    local ARCH FILE_SUFFIX API_JSON URL VERSION
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)       FILE_SUFFIX="linux_amd64.tar.gz" ;;
        aarch64)      FILE_SUFFIX="linux_arm64.tar.gz" ;;
        armv7l|armhf) FILE_SUFFIX="linux_armv7.tar.gz" ;;
        *) print_error "不支持的架构: $ARCH"; exit 1 ;;
    esac
    API_JSON=$(curl -sL https://api.github.com/repos/go-gost/gost/releases/latest)
    if echo "$API_JSON" | grep -q '"browser_download_url"'; then
        URL=$(echo "$API_JSON" | grep browser_download_url | cut -d '"' -f4 | grep "$FILE_SUFFIX" | head -n1)
    else
        VERSION=$(curl -sI https://github.com/go-gost/gost/releases/latest | grep -i '^location:' | sed -E 's#.*tag/v##I' | tr -d '\r')
        URL="https://github.com/go-gost/gost/releases/download/v${VERSION}/gost_${VERSION}_${FILE_SUFFIX}"
    fi
    mkdir -p "$BASE_DIR"
    wget -q --show-progress -O /tmp/gost.tar.gz "$URL"
    tar -xzf /tmp/gost.tar.gz -C /tmp
    install -m 755 /tmp/gost "$GOST_BIN"
    print_ok "gost v3 安装完成：$GOST_BIN"
}

next_id() {
    local n
    n=$(ls "$CONF_DIR"/server-*.env 2>/dev/null | wc -l)
    echo $((n + 1))
}

list_tunnels() {
    print_title "当前服务端隧道列表（含认证信息）"
    echo -e "${CYAN}编号 | 本地端口 | 路径 | 认证 (用户名:密码) | systemd 名称${RESET}" >&2
    echo "--------------------------------------------------------------------------------------------" >&2
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        source "$f"  # 导入 LOCAL_PORT, WS_PATH, AUTH_USER, AUTH_PASS
        local_port="${LOCAL_PORT:-?}"
        ws_path="${WS_PATH:-?}"
        auth_user="${AUTH_USER:-?}"
        auth_pass="${AUTH_PASS:-?}"
        masked_pass=$(echo "$auth_pass" | sed 's/./*/g')
        svc="xgost-server-$(printf "%02d" "$num").service"
        echo -e "${GREEN}$num${RESET}) 端口: ${YELLOW}$local_port${RESET} | 路径: ${MAGENTA}$ws_path${RESET} | 认证: ${BLUE}$auth_user:$masked_pass${RESET} | 服务: ${CYAN}$svc${RESET}" >&2
    done
    echo "--------------------------------------------------------------------------------------------" >&2
    echo -e "${YELLOW}提示：完整认证信息请查看对应配置文件 ${CONF_DIR}/server-*.env${RESET}" >&2
}

add_tunnel() {
    install_gost
    print_title "新增服务端隧道 (relay+ws with auth)"

    default_port=$(random_free_port)
    local_port=$(safe_read_port "$default_port")
    default_path="/$(cat /proc/sys/kernel/random/uuid | cut -d'-' -f1)"
    ws_path=$(safe_read "请输入 WS 路径" "$default_path")

    # 生成随机认证用户名和密码
    default_auth_user="gost_$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1)"
    auth_user=$(safe_read "请输入认证用户名" "$default_auth_user")
    auth_pass=$(random_auth_pass)
    print_info "自动生成强密码: $auth_pass (请妥善保存)"
    read -p "是否自定义密码？(y/N): " custom_pw
    if [[ "$custom_pw" =~ ^[Yy]$ ]]; then
        read -s -p "请输入密码: " auth_pass
        echo
        read -s -p "确认密码: " auth_pass2
        echo
        if [[ "$auth_pass" != "$auth_pass2" ]]; then
            print_error "两次密码不一致，使用随机密码"
            auth_pass=$(random_auth_pass)
        fi
    fi

    # Base64 编码认证信息（gost v3 服务端要求）
    AUTH_BASE64=$(base64_encode "$auth_user:$auth_pass")

    id=$(next_id)
    id2=$(printf "%02d" "$id")
    conf="$CONF_DIR/server-$id2.env"
    svc="xgost-server-$id2.service"

    # 保存明文配置（方便查看）
    cat > "$conf" <<EOF
ID=$id
LOCAL_PORT=$local_port
WS_PATH=$ws_path
AUTH_USER=$auth_user
AUTH_PASS=$auth_pass
EOF

    # 服务文件写入 Base64 编码的 auth 参数
    cat > "$SYSTEMD_DIR/$svc" <<EOF
[Unit]
Description=XGost Server Tunnel $id (with auth)
After=network.target

[Service]
Type=simple
ExecStart=$GOST_BIN -L "relay+ws://127.0.0.1:$local_port?path=$ws_path&bind=true&auth=$AUTH_BASE64"
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$svc"

    print_ok "服务端隧道创建成功（已启用认证）"
    echo -e "编号: $id" >&2
    echo -e "本地端口: $local_port" >&2
    echo -e "路径: $ws_path" >&2
    echo -e "用户名: $auth_user" >&2
    echo -e "密码: $auth_pass" >&2
    echo -e "systemd 服务: $svc" >&2
    echo "" >&2
    print_info "客户端配置示例（需使用相同认证）："
    echo "  -F \"relay+wss://yourdomain:443?path=$ws_path&auth=$auth_user:$auth_pass&host=yourdomain\"" >&2
}

status_tunnels() {
    print_title "服务端隧道运行状态"
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        svc="xgost-server-$num.service"
        if systemctl is-active --quiet "$svc"; then
            st="${GREEN}运行中${RESET}"
        else
            st="${RED}未运行${RESET}"
        fi
        echo -e "隧道 ${CYAN}$num${RESET} -> $svc : $st" >&2
    done
}

view_logs() {
    list_tunnels
    printf "请输入要查看日志的编号: " >&2
    read num
    num=$(clean_input "$num")
    id2=$(printf "%02d" "$num")
    svc="xgost-server-$id2.service"
    if [ ! -f "$SYSTEMD_DIR/$svc" ]; then
        print_error "服务不存在: $svc"
        return
    fi
    print_info "显示 $svc 最近 50 行日志"
    journalctl -u "$svc" -n 50 --no-pager
}

stop_tunnel() {
    list_tunnels
    printf "请输入要停止的隧道编号: " >&2
    read num
    num=$(clean_input "$num")
    id2=$(printf "%02d" "$num")
    svc="xgost-server-$id2.service"
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
    id2=$(printf "%02d" "$num")
    svc="xgost-server-$id2.service"
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
    id2=$(printf "%02d" "$num")
    svc="xgost-server-$id2.service"
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
    id2=$(printf "%02d" "$num")
    conf="$CONF_DIR/server-$id2.env"
    svc="xgost-server-$id2.service"
    if [ ! -f "$conf" ]; then
        print_error "配置不存在: $conf"
        return
    fi
    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "$conf"
    rm -f "$SYSTEMD_DIR/$svc"
    systemctl daemon-reload
    print_ok "已删除服务端隧道 $num"
}

delete_all() {
    print_title "删除所有服务端隧道"
    read -p "确认删除所有服务端隧道？(yes/no): " ans
    ans=$(clean_input "$ans")
    [ "$ans" != "yes" ] && { print_info "已取消"; return; }
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        svc="xgost-server-$num.service"
        systemctl disable --now "$svc" 2>/dev/null || true
        rm -f "$SYSTEMD_DIR/$svc"
        rm -f "$f"
    done
    systemctl daemon-reload
    print_ok "已删除所有服务端隧道"
}

menu() {
    while true; do
        print_title "XGost 服务端隧道面板 (v3 + 认证)"
        echo "1) 查看隧道列表 (含认证信息)" >&2
        echo "2) 新增隧道 (自动启用认证)" >&2
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
            1) list_tunnels; printf "按回车继续..." >&2; read ;;
            2) add_tunnel;   printf "按回车继续..." >&2; read ;;
            3) status_tunnels; printf "按回车继续..." >&2; read ;;
            4) view_logs;    printf "按回车继续..." >&2; read ;;
            5) stop_tunnel;  printf "按回车继续..." >&2; read ;;
            6) start_tunnel; printf "按回车继续..." >&2; read ;;
            7) restart_tunnel; printf "按回车继续..." >&2; read ;;
            8) delete_tunnel; printf "按回车继续..." >&2; read ;;
            9) delete_all;   printf "按回车继续..." >&2; read ;;
            0) exit 0 ;;
            *) print_error "无效选项"; printf "按回车继续..." >&2; read ;;
        esac
    done
}

menu
