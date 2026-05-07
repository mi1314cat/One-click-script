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

# ================================
# 基础变量
# ================================
BASE_DIR="/root/catmi/nodepass"
BIN_PATH="$BASE_DIR/nodepass"
CLIENT_BASE="$BASE_DIR/client"
LOG_DIR="$BASE_DIR/logs"
REPO="NodePassProject/nodepass"

mkdir -p "$BASE_DIR" "$CLIENT_BASE" "$LOG_DIR"

# ================================
# 打印函数
# ================================
print_info()  { echo -e "${CYAN}[信息]${RESET} $1" >&2; }
print_error() { echo -e "${RED}[错误]${RESET} $1" >&2; }
print_warn()  { echo -e "${YELLOW}[警告]${RESET} $1" >&2; }
print_ok()    { echo -e "${GREEN}[OK]${RESET} $1" >&2; }

clean_input() { echo "$1" | tr -d ' \t\r\n'; }

# ================================
# 端口检测
# ================================
port_in_use() {
    ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$1\$"
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

        if port_in_use "$port"; then
            print_error "端口 $port 已占用"
            printf "选择操作: [1] 强制使用] [2] 自动换端口] [3] 重新输入]: " >&2
            read choice
            choice=$(clean_input "$choice")

            case "$choice" in
                1) echo "$port"; return ;;
                2)
                    local new_port="$port"
                    while port_in_use "$new_port"; do
                        ((new_port++))
                        ((new_port > 65535)) && { print_error "没有可用端口"; continue 2; }
                    done
                    print_info "自动选择可用端口: $new_port"
                    echo "$new_port"
                    return
                    ;;
                3) continue ;;
                *) print_error "无效选择" ;;
            esac
        fi

        echo "$port"
        return
    done
}

# ================================
# 架构检测 + 下载 NodePass
# ================================
detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) print_error "不支持的架构"; exit 1 ;;
    esac
}

download_nodepass() {
    if [[ -x "$BIN_PATH" ]]; then
        print_info "NodePass 已存在"
        return
    fi

    local arch tag version url tmpdir tarfile
    arch=$(detect_arch)

    print_info "获取 NodePass 最新版本..."
    tag=$(curl -s "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    version="${tag#v}"

    url="https://github.com/${REPO}/releases/download/${tag}/nodepass_${version}_linux_${arch}.tar.gz"

    print_info "下载: $url"

    tmpdir=$(mktemp -d)
    tarfile="$tmpdir/nodepass.tar.gz"

    curl -L "$url" -o "$tarfile"
    tar -xzf "$tarfile" -C "$tmpdir"

    mv "$tmpdir/nodepass" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -rf "$tmpdir"

    print_ok "NodePass 下载完成"
}

# ================================
# 隧道编号
# ================================
next_id() {
    local max=0 id
    for d in "$CLIENT_BASE"/*; do
        [[ -d "$d" ]] || continue
        id=$(basename "$d")
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        ((10#$id > max)) && max=$((10#$id))
    done
    printf "%02d" $((max + 1))
}

get_client_dir() { echo "$CLIENT_BASE/$1"; }
get_service_name() { echo "nodepass-client-$1"; }

# ================================
# 创建隧道
# ================================
create_tunnel() {
    download_nodepass

    local id dir argo_domain wss_path local_port
    id=$(next_id)
    dir=$(get_client_dir "$id")
    mkdir -p "$dir"

    printf "请输入 Argo 域名: " >&2
    read argo_domain
    argo_domain=$(clean_input "$argo_domain")
    [[ -z "$argo_domain" ]] && { print_error "Argo 域名不能为空"; return; }

    printf "请输入 WSS 路径（至少 16 位）: " >&2
    read wss_path
    wss_path=$(clean_input "$wss_path")
    [[ -z "$wss_path" ]] && { print_error "WSS 路径不能为空"; return; }

    local_port=$(safe_read_port "8888")

    cat >"$dir/client.json" <<EOF
{
  "server": "wss://$argo_domain/$wss_path",
  "local": "127.0.0.1:$local_port",
  "pool": { "size": 8 }
}
EOF

    local svc="/etc/systemd/system/$(get_service_name "$id").service"

    cat >"$svc" <<EOF
[Unit]
Description=NodePass Client $id
After=network.target

[Service]
WorkingDirectory=$dir
ExecStart=$BIN_PATH client -c $dir/client.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$(get_service_name "$id")"
    systemctl restart "$(get_service_name "$id")"

    print_ok "创建客户端隧道成功：ID=$id"
}

# ================================
# 美化版隧道列表（含状态）
# ================================
list_tunnels() {
    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║                NodePass 客户端隧道列表（状态版）              ║${RESET}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"

    printf "${GREEN}%-5s %-24s %-20s %-10s %-10s${RESET}\n" "ID" "Argo 域名" "WSS 路径" "端口" "状态"
    echo "--------------------------------------------------------------------------"

    for d in "$CLIENT_BASE"/*; do
        [[ -d "$d" ]] || continue

        id=$(basename "$d")
        conf="$d/client.json"

        server=$(jq -r '.server' "$conf")
        local_port=$(jq -r '.local' "$conf" | sed -E 's/.*:([0-9]+)$/\1/')
        domain=$(echo "$server" | sed -E 's#^wss://([^/]+)/.*#\1#')
        path=$(echo "$server" | sed -E 's#^wss://[^/]+/(.*)$#/\1#')

        svc="nodepass-client-$id"

        if systemctl is-active --quiet "$svc"; then
            status="${GREEN}运行中${RESET}"
        else
            status="${RED}停止${RESET}"
        fi

        printf "%-5s %-24s %-20s %-10s %b\n" "$id" "$domain" "$path" "$local_port" "$status"
    done

    echo
}

# ================================
# 选择隧道（带状态提示）
# ================================
choose_id() {
    list_tunnels
    printf "${YELLOW}请输入隧道 ID: ${RESET}" >&2
    read id
    id=$(clean_input "$id")

    [[ -d "$(get_client_dir "$id")" ]] || { print_error "隧道不存在"; return 1; }

    svc="nodepass-client-$id"
    if systemctl is-active --quiet "$svc"; then
        print_ok "隧道 $id 当前状态：运行中"
    else
        print_warn "隧道 $id 当前状态：停止"
    fi

    echo "$id"
}

# ================================
# 隧道操作
# ================================
show_logs() { id=$(choose_id) || return; journalctl -u "$(get_service_name "$id")" -f -n 100; }
start_tunnel() { id=$(choose_id) || return; systemctl start "$(get_service_name "$id")"; print_ok "已启动"; }
stop_tunnel() { id=$(choose_id) || return; systemctl stop "$(get_service_name "$id")"; print_ok "已停止"; }
restart_tunnel() { id=$(choose_id) || return; systemctl restart "$(get_service_name "$id")"; print_ok "已重启"; }
show_conf() { id=$(choose_id) || return; cat "$(get_client_dir "$id")/client.json"; }

delete_tunnel() {
    id=$(choose_id) || return
    dir=$(get_client_dir "$id")
    svc=$(get_service_name "$id")

    systemctl stop "$svc" || true
    systemctl disable "$svc" || true
    rm -f "/etc/systemd/system/$svc.service"
    systemctl daemon-reload
    rm -rf "$dir"

    print_ok "已彻底删除隧道 $id"
}

# ================================
# 主菜单（美化版）
# ================================
menu() {
    while true; do
        echo -e "\n${MAGENTA}${BOLD}"
        echo "╔══════════════════════════════════════════════╗"
        echo "║        NodePass 客户端多隧道管理面板         ║"
        echo "╚══════════════════════════════════════════════╝"
        echo -e "${RESET}"

        echo -e "${CYAN}1${RESET}) 创建新的客户端隧道"
        echo -e "${CYAN}2${RESET}) 查看所有隧道（含状态）"
        echo -e "${CYAN}3${RESET}) 查看某个隧道日志"
        echo -e "${CYAN}4${RESET}) 删除某个隧道"
        echo -e "${CYAN}5${RESET}) 重启某个隧道"
        echo -e "${CYAN}6${RESET}) 停止某个隧道"
        echo -e "${CYAN}7${RESET}) 启动某个隧道"
        echo -e "${CYAN}8${RESET}) 查看某个隧道配置"
        echo -e "${CYAN}0${RESET}) 退出"
        echo

        printf "${YELLOW}请选择操作: ${RESET}"
        read choice
        choice=$(clean_input "$choice")

        case "$choice" in
            1) create_tunnel ;;
            2) list_tunnels; read -p "按回车继续..." ;;
            3) show_logs ;;
            4) delete_tunnel ;;
            5) restart_tunnel ;;
            6) stop_tunnel ;;
            7) start_tunnel ;;
            8) show_conf ;;
            0) exit 0 ;;
            *) print_error "无效选项"; read -p "按回车继续..." ;;
        esac
    done
}

menu
