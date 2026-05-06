#!/usr/bin/env bash
set -e

BASE_DIR="/root/catmi/nodepass"
BIN_PATH="$BASE_DIR/nodepass"
SERVER_BASE="$BASE_DIR/server"
LOG_DIR="$BASE_DIR/logs"
REPO="NodePassProject/nodepass"

mkdir -p "$BASE_DIR" "$SERVER_BASE" "$LOG_DIR"

print_info()  { printf "\033[32m[信息]\033[0m %s\n" "$*" >&2; }
print_error() { printf "\033[31m[错误]\033[0m %s\n" "$*" >&2; }
print_warn()  { printf "\033[33m[警告]\033[0m %s\n" "$*" >&2; }

clean_input() {
    echo "$1" | tr -d ' \t\r\n'
}

port_in_use() {
    local port="$1"
    ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$port\$"
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
            printf "选择操作: [1] 强制使用 [2] 自动换端口 [3] 重新输入: " >&2
            read choice
            choice=$(clean_input "$choice")

            case "$choice" in
                1)
                    echo "$port"
                    return
                    ;;
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
                3)
                    continue
                    ;;
                *)
                    print_error "无效选择"
                    continue
                    ;;
            esac
        fi

        echo "$port"
        return
    done
}

gen_random_path() {
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c16
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)
            print_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

download_nodepass() {
    if [[ -x "$BIN_PATH" ]]; then
        print_info "NodePass 已存在: $BIN_PATH"
        return
    fi

    local arch tag version url tmpdir tarfile
    arch=$(detect_arch)

    print_info "获取 NodePass 最新版本..."
    tag=$(curl -s "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$tag" ]]; then
        print_error "无法获取最新版本 tag"
        exit 1
    fi
    version="${tag#v}"
    print_info "最新版本: $version (tag: $tag)"

    url="https://github.com/${REPO}/releases/download/${tag}/nodepass_${version}_linux_${arch}.tar.gz"
    print_info "下载: $url"

    tmpdir=$(mktemp -d)
    tarfile="$tmpdir/nodepass.tar.gz"

    curl -L --retry 3 --connect-timeout 10 "$url" -o "$tarfile"
    if [[ $? -ne 0 ]]; then
        print_error "下载失败"
        rm -rf "$tmpdir"
        exit 1
    fi

    tar -xzf "$tarfile" -C "$tmpdir"
    if [[ ! -f "$tmpdir/nodepass" ]]; then
        print_error "解压后未找到 nodepass 可执行文件"
        ls -al "$tmpdir"
        rm -rf "$tmpdir"
        exit 1
    fi

    mv "$tmpdir/nodepass" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -rf "$tmpdir"

    print_info "NodePass 安装完成: $BIN_PATH"
}

next_id() {
    local max=0 id
    for d in "$SERVER_BASE"/*; do
        [[ -d "$d" ]] || continue
        id=$(basename "$d")
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        ((10#$id > max)) && max=$((10#$id))
    done
    printf "%02d" $((max + 1))
}

get_server_dir() {
    local id="$1"
    echo "$SERVER_BASE/$id"
}

get_service_name() {
    local id="$1"
    echo "nodepass-server-$id"
}

create_tunnel() {
    download_nodepass

    local id dir default_port port wss_path
    id=$(next_id)
    dir=$(get_server_dir "$id")
    mkdir -p "$dir"

    default_port=$(( (RANDOM % 20000) + 40000 ))
    port=$(safe_read_port "$default_port")
    wss_path="$(gen_random_path)"

    cat >"$dir/server.json" <<EOF
{
  "listen": ":$port",
  "transport": {
    "type": "wss",
    "path": "/$wss_path"
  },
  "pool": {
    "size": 16,
    "max": 64
  }
}
EOF

    local svc="/etc/systemd/system/$(get_service_name "$id").service"
    cat >"$svc" <<EOF
[Unit]
Description=NodePass Server $id
After=network.target

[Service]
WorkingDirectory=$dir
ExecStart=$BIN_PATH server -c $dir/server.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$(get_service_name "$id")" >/dev/null 2>&1 || true
    systemctl restart "$(get_service_name "$id")"

    print_info "创建服务端隧道成功：ID=$id"
    print_info "监听端口: $port"
    print_info "WSS 路径: /$wss_path"
}

list_tunnels() {
    echo "ID    端口    路径"
    echo "-------------------------"
    for d in "$SERVER_BASE"/*; do
        [[ -d "$d" ]] || continue
        local id port path
        id=$(basename "$d")
        port=$(grep '"listen"' "$d/server.json" 2>/dev/null | sed -E 's/.*": *"?:([0-9]+)".*/\1/')
        path=$(grep '"path"' "$d/server.json" 2>/dev/null | sed -E 's/.*"path": *"([^"]+)".*/\1/')
        printf "%-5s %-7s %s\n" "$id" "${port:-?}" "${path:-?}"
    done
}

choose_id() {
    local id
    printf "请输入隧道 ID (例如 01): "
    read id
    id=$(clean_input "$id")
    [[ -d "$(get_server_dir "$id")" ]] || { print_error "隧道不存在: $id"; return 1; }
    echo "$id"
}

show_logs() {
    local id svc
    id=$(choose_id) || return
    svc=$(get_service_name "$id")
    journalctl -u "$svc" -f -n 100
}

start_tunnel() {
    local id svc
    id=$(choose_id) || return
    svc=$(get_service_name "$id")
    systemctl start "$svc"
    print_info "已启动隧道 $id"
}

stop_tunnel() {
    local id svc
    id=$(choose_id) || return
    svc=$(get_service_name "$id")
    systemctl stop "$svc"
    print_info "已停止隧道 $id"
}

restart_tunnel() {
    local id svc
    id=$(choose_id) || return
    svc=$(get_service_name "$id")
    systemctl restart "$svc"
    print_info "已重启隧道 $id"
}

show_conf() {
    local id dir
    id=$(choose_id) || return
    dir=$(get_server_dir "$id")
    cat "$dir/server.json"
}

delete_tunnel() {
    local id dir svc unit
    id=$(choose_id) || return
    dir=$(get_server_dir "$id")
    svc=$(get_service_name "$id")
    unit="/etc/systemd/system/$svc.service"

    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "$unit"
    systemctl daemon-reload

    rm -rf "$dir"

    print_info "已彻底删除隧道 $id（服务 + 配置目录）"
}

menu() {
    while true; do
        echo "=============================="
        echo " NodePass 服务端多隧道面板"
        echo " 目录: $BASE_DIR"
        echo "=============================="
        echo "1. 创建新的服务端隧道"
        echo "2. 查看所有隧道"
        echo "3. 查看某个隧道日志"
        echo "4. 删除某个隧道"
        echo "5. 重启某个隧道"
        echo "6. 停止某个隧道"
        echo "7. 启动某个隧道"
        echo "8. 查看某个隧道配置"
        echo "0. 退出"
        echo "=============================="
        printf "请输入选项: "
        read choice
        choice=$(clean_input "$choice")
        case "$choice" in
            1) create_tunnel ;;
            2) list_tunnels ;;
            3) show_logs ;;
            4) delete_tunnel ;;
            5) restart_tunnel ;;
            6) stop_tunnel ;;
            7) start_tunnel ;;
            8) show_conf ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac
    done
}

menu
