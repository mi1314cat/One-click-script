#!/usr/bin/env bash
set -euo pipefail

# ================================
# 彩色与基础函数
# ================================
readonly RED='\e[31m'
readonly GREEN='\e[32m'
readonly YELLOW='\e[33m'
readonly CYAN='\e[36m'
readonly MAGENTA='\e[35m'
readonly BOLD='\e[1m'
readonly RESET='\e[0m'

print_info()  { echo -e "${CYAN}[信息]${RESET} $*" >&2; }
print_ok()    { echo -e "${GREEN}[OK]${RESET}   $*" >&2; }
print_error() { echo -e "${RED}[错误]${RESET} $*" >&2; }
print_warn()  { echo -e "${YELLOW}[注意]${RESET} $*" >&2; }

print_title() {
    echo -e "${MAGENTA}${BOLD}" >&2
    echo "╔══════════════════════════════════════════════╗" >&2
    printf "║ %-42s ║\n" "$1" >&2
    echo "╚══════════════════════════════════════════════╝" >&2
    echo -e "${RESET}" >&2
}

# ================================
# 路径定义
# ================================
readonly BASE_DIR="/root/catmi/nodepass"
readonly BIN_PATH="$BASE_DIR/nodepass"
readonly CLIENT_BASE="$BASE_DIR/client"
readonly LOG_DIR="$BASE_DIR/logs"
readonly REPO="NodePassProject/nodepass"
readonly SERVICE_PREFIX="nodepass-client"

mkdir -p "$BASE_DIR" "$CLIENT_BASE" "$LOG_DIR"

# ================================
# 依赖检查
# ================================
check_deps() {
    local missing=()
    for prog in curl jq openssl ss; do
        if ! command -v "$prog" &>/dev/null; then
            missing+=("$prog")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        return
    fi
    print_warn "缺少依赖: ${missing[*]}，正在安装..."
    if command -v apt &>/dev/null; then
        apt update -qq && apt install -y -qq "${missing[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y -q "${missing[@]}"
    else
        print_error "请手动安装: ${missing[*]}"
        exit 1
    fi
    for prog in "${missing[@]}"; do
        if ! command -v "$prog" &>/dev/null; then
            print_error "安装 $prog 失败"
            exit 1
        fi
    done
    print_ok "依赖已就绪"
}

# ================================
# 辅助函数
# ================================
clean_input() { tr -d '\000-\037' <<< "$1"; }

port_in_use() { ss -tuln | awk '{print $5}' | grep -qE "(:|])$1$"; }

safe_read() {
    local prompt="$1" default="$2" input
    printf "%s (默认: %s): " "$prompt" "$default" >&2
    read -r input
    input=$(clean_input "${input:-$default}")
    echo "$input"
}

safe_read_port() {
    local default="$1" input port
    while true; do
        printf "本地监听端口 (默认: %s): " "$default" >&2
        read -r input
        input=$(clean_input "$input")
        port="${input:-$default}"
        if [[ ! "$port" =~ ^[0-9]+$ ]]; then
            print_error "端口必须是数字"
            continue
        fi
        if (( port < 1 || port > 65535 )); then
            print_error "端口范围 1-65535"
            continue
        fi
        if port_in_use "$port"; then
            print_error "端口已占用"
            printf "选择操作: [1] 强制使用 [2] 自动寻找空闲端口 [3] 重新输入]: " >&2
            read -r choice
            choice=$(clean_input "$choice")
            case "$choice" in
                1) echo "$port"; return ;;
                2) while port_in_use "$port"; do ((port++)); done; print_info "自动选择: $port"; echo "$port"; return ;;
                3) continue ;;
                *) print_error "无效" ;;
            esac
        fi
        echo "$port"
        return
    done
}

# ================================
# NodePass 安装
# ================================
detect_arch() {
    case "$(uname -m)" in
        x86_64)      echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) print_error "不支持的架构"; exit 1 ;;
    esac
}

get_latest_version() {
    local tag
    tag=$(curl -fsSL -H "User-Agent: NP-Manager" "https://api.github.com/repos/${REPO}/releases/latest" \
        | jq -r '.tag_name')
    [[ -z "$tag" || "$tag" == "null" ]] && { print_error "无法获取最新版本"; exit 1; }
    echo "${tag#v}"
}

install_nodepass() {
    if [[ -x "$BIN_PATH" ]]; then return; fi
    print_info "下载 NodePass ..."
    local arch version url tmpdir
    arch=$(detect_arch)
    version=$(get_latest_version)
    url="https://github.com/${REPO}/releases/download/v${version}/nodepass_${version}_linux_${arch}.tar.gz"
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    curl -fsSL -o "$tmpdir/nodepass.tar.gz" "$url" || { print_error "下载失败"; exit 1; }
    tar -xzf "$tmpdir/nodepass.tar.gz" -C "$tmpdir"
    [[ -f "$tmpdir/nodepass" ]] || { print_error "压缩包无效"; exit 1; }
    mv -f "$tmpdir/nodepass" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    print_ok "NodePass 安装完成"
}

# ================================
# 隧道 ID
# ================================
next_id() {
    local max=0 num
    for d in "$CLIENT_BASE"/*; do
        [[ -d "$d" ]] || continue
        num=$(basename "$d")
        [[ "$num" =~ ^[0-9]+$ ]] || continue
        num=$((10#$num))
        ((num > max)) && max=$num
    done
    printf "%02d" $((max + 1))
}

get_client_dir() { echo "$CLIENT_BASE/$1"; }
get_service_name() { echo "${SERVICE_PREFIX}-$1"; }

# ================================
# 创建客户端隧道
# ================================
create_tunnel() {
    install_nodepass

    local id argo_domain tunnel_key local_port
    local enable_ws=false enable_h2=false ws_path="" h2_path="" mux_streams=2

    id=$(next_id)
    local dir
    dir=$(get_client_dir "$id")
    mkdir -p "$dir"

    print_title "新建客户端隧道"

    # Argo 域名
    while true; do
        argo_domain=$(safe_read "Argo 域名（例如 tunnel.example.com）" "")
        [[ -n "$argo_domain" ]] && break
        print_error "域名不能为空"
    done

    # 隧道密钥（必须与服务端一致）
    print_warn "请输入服务端对应隧道的密钥（服务端创建时会输出）"
    while true; do
        tunnel_key=$(safe_read "隧道密钥" "")
        if [[ ${#tunnel_key} -lt 16 ]]; then
            print_error "密钥长度至少 16 字符"
        else
            break
        fi
    done

    # 协议选择
    echo
    print_info "选择要启用的协议（至少选一个）"
    printf "启用 WebSocket (WS) ? [y/N]: " >&2
    read -r ans
    [[ "$(clean_input "$ans")" =~ ^[yY]$ ]] && enable_ws=true

    printf "启用 HTTP/2 (H2)   ? [y/N]: " >&2
    read -r ans
    [[ "$(clean_input "$ans")" =~ ^[yY]$ ]] && enable_h2=true

    if ! $enable_ws && ! $enable_h2; then
        print_error "至少需要启用一种协议"
        return
    fi

    # 路径（长度≥16）
    if $enable_ws; then
        while true; do
            ws_path=$(safe_read "WS 路径（例如 /ws_xxxxxxxxxxxxxxx）" "/")
            [[ ${#ws_path} -ge 16 ]] && break
            print_error "路径长度至少 16 字符"
        done
        [[ "$ws_path" != /* ]] && ws_path="/$ws_path"
    fi

    if $enable_h2; then
        while true; do
            h2_path=$(safe_read "H2 路径（例如 /h2_xxxxxxxxxxxxxxx）" "/")
            [[ ${#h2_path} -ge 16 ]] && break
            print_error "路径长度至少 16 字符"
        done
        [[ "$h2_path" != /* ]] && h2_path="/$h2_path"
    fi

    # 本地监听端口
    local_port=$(safe_read_port "8888")

    # MUX 流数
    while true; do
        mux_streams=$(safe_read "多路复用流数 (1-8)" "2")
        if [[ "$mux_streams" =~ ^[1-8]$ ]]; then
            break
        else
            print_error "请输入 1~8 之间的数字"
        fi
    done

    # 构建 JSON
    local connects="["
    local first=true

    if $enable_ws; then
        $first || connects+=","
        first=false
        connects+="
    {
      \"address\": \"${tunnel_key}@${argo_domain}:443\",
      \"protocol\": \"ws\",
      \"tls\": true,
      \"path\": \"${ws_path}\",
      \"mux\": {
        \"enable\": true,
        \"streams\": ${mux_streams}
      }
    }"
    fi

    if $enable_h2; then
        $first || connects+=","
        connects+="
    {
      \"address\": \"${tunnel_key}@${argo_domain}:443\",
      \"protocol\": \"h2\",
      \"tls\": true,
      \"path\": \"${h2_path}\",
      \"mux\": {
        \"enable\": true,
        \"streams\": ${mux_streams}
      }
    }"
    fi

    connects+="
  ]"

    cat > "$dir/client.json" <<EOF
{
  "transport": {
    "type": "tcp",
    "listen": "127.0.0.1:${local_port}"
  },
  "connect": ${connects}
}
EOF

    # systemd 服务
    local svc_name svc_path
    svc_name=$(get_service_name "$id")
    svc_path="/etc/systemd/system/${svc_name}.service"

    cat > "$svc_path" <<EOF
[Unit]
Description=NodePass Client Tunnel $id
After=network.target

[Service]
WorkingDirectory=$dir
ExecStart=$BIN_PATH client -c $dir/client.json
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$svc_name"

    print_ok "客户端隧道 $id 创建成功"
    echo -e "  本地监听: 127.0.0.1:${local_port}"
    echo -e "  密钥:     ${GREEN}${tunnel_key}${RESET}"
    $enable_ws && echo -e "  WS 路径:  ${ws_path} (wss://${argo_domain}${ws_path})"
    $enable_h2 && echo -e "  H2 路径:  ${h2_path} (https://${argo_domain}${h2_path})"
    echo -e "  MUX 流:   ${mux_streams}"
}

# ================================
# 隧道列表
# ================================
list_tunnels() {
    print_title "客户端隧道列表"
    local found=0
    printf "${GREEN}%-4s %-6s %-24s %-20s %-10s${RESET}\n" "ID" "端口" "域名" "协议" "状态"
    echo "-----------------------------------------------------------------------------"
    for d in "$CLIENT_BASE"/*; do
        [[ -d "$d" ]] || continue
        local id
        id=$(basename "$d")
        local conf="$d/client.json"
        local port domain protocols

        port=$(jq -r '.transport.listen' "$conf" | cut -d: -f2)

        local addr
        addr=$(jq -r '.connect[0].address // ""' "$conf")
        domain="${addr#*@}"
        domain="${domain%%:*}"

        protocols=""
        while IFS='|' read -r proto path; do
            [[ -n "$protocols" ]] && protocols+=", "
            protocols+="${proto^^}${path:0:8}..."
        done < <(jq -r '.connect[] | "\(.protocol)|\(.path // "")"' "$conf")

        local svc
        svc=$(get_service_name "$id")
        local status
        if systemctl is-active --quiet "$svc"; then
            status="${GREEN}运行中${RESET}"
        else
            status="${RED}停止${RESET}"
        fi

        printf "%-4s %-6s %-24s %-20s %b\n" "$id" "$port" "$domain" "$protocols" "$status"
        found=1
    done
    [[ $found -eq 0 ]] && print_warn "暂无隧道"
}

# ================================
# 隧道选择器
# ================================
choose_id() {
    list_tunnels
    local id
    id=$(safe_read "输入隧道 ID" "")
    [[ -z "$id" ]] && { print_error "ID 不能为空"; return 1; }
    local dir
    dir=$(get_client_dir "$id")
    [[ -d "$dir" ]] || { print_error "隧道不存在"; return 1; }
    local svc
    svc=$(get_service_name "$id")
    if systemctl is-active --quiet "$svc"; then
        print_ok "隧道 $id 状态：运行中"
    else
        print_warn "隧道 $id 状态：已停止"
    fi
    echo "$id"
}

# ================================
# 操作函数
# ================================
show_logs() {
    local id
    id=$(choose_id) || return
    journalctl -u "$(get_service_name "$id")" -f -n 100
}

start_tunnel() {
    local id
    id=$(choose_id) || return
    systemctl start "$(get_service_name "$id")"
    print_ok "已启动隧道 $id"
}

stop_tunnel() {
    local id
    id=$(choose_id) || return
    systemctl stop "$(get_service_name "$id")"
    print_ok "已停止隧道 $id"
}

restart_tunnel() {
    local id
    id=$(choose_id) || return
    systemctl restart "$(get_service_name "$id")"
    print_ok "已重启隧道 $id"
}

show_conf() {
    local id
    id=$(choose_id) || return
    cat "$(get_client_dir "$id")/client.json"
}

delete_tunnel() {
    local id
    id=$(choose_id) || return
    local dir svc
    dir=$(get_client_dir "$id")
    svc=$(get_service_name "$id")

    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
    systemctl daemon-reload
    rm -rf "$dir"
    print_ok "已删除隧道 $id"
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "NodePass 客户端管理"
        echo "  1) 创建新隧道" >&2
        echo "  2) 隧道列表" >&2
        echo "  3) 查看日志" >&2
        echo "  4) 删除隧道" >&2
        echo "  5) 重启隧道" >&2
        echo "  6) 停止隧道" >&2
        echo "  7) 启动隧道" >&2
        echo "  8) 查看配置" >&2
        echo "  0) 退出" >&2
        echo
        local choice
        read -rp "请输入选项: " choice
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
            0) print_info "再见"; exit 0 ;;
            *) print_error "无效选项" ;;
        esac
        echo
        read -rp "按回车键继续..." _
    done
}

# ================================
# 启动
# ================================
check_deps
main_menu
