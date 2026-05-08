#!/usr/bin/env bash
set -euo pipefail

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

readonly BASE_DIR="/root/catmi/nodepass"
readonly BIN_PATH="$BASE_DIR/nodepass"
readonly CONF_DIR="$BASE_DIR/server"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly REPO="NodePassProject/nodepass"
readonly SERVICE_PREFIX="nodepass-server"

mkdir -p "$BASE_DIR" "$CONF_DIR"

check_deps() {
    local missing=()
    for prog in curl jq openssl ss; do
        if ! command -v "$prog" &>/dev/null; then
            missing+=("$prog")
        fi
    done
    [[ ${#missing[@]} -eq 0 ]] && return
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

clean_input() { tr -d '\000-\037' <<< "$1"; }
port_in_use() { ss -tuln | awk '{print $5}' | grep -qE "(:|])$1$"; }
random_port() { shuf -i 10000-60000 -n 1; }

random_free_port() {
    for _ in {1..20}; do
        local port
        port=$(random_port)
        if ! port_in_use "$port"; then
            echo "$port"
            return
        fi
    done
    print_error "未找到空闲端口"
    exit 1
}

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
        printf "监听端口 (默认: %s): " "$default" >&2
        read -r input
        input=$(clean_input "$input")
        port="${input:-$default}"
        [[ "$port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; continue; }
        (( port >= 1 && port <= 65535 )) || { print_error "端口范围 1-65535"; continue; }
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
    local force="${1:-false}"
    [[ -x "$BIN_PATH" && "$force" != "true" ]] && return
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
    print_ok "NodePass 已更新至 v${version}"
}

next_id() {
    local max=0 num
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        num=$((10#$num))
        ((num > max)) && max=$num
    done
    printf "%02d" $((max + 1))
}

choose_protocol() {
    print_info "选择传输协议:"
    echo "  1) ws  - WebSocket (pool=2)" >&2
    echo "  2) h2  - HTTP/2 gRPC (pool=3)" >&2
    echo "  3) tcp - 原始 TCP (pool=0)" >&2
    printf "选项 (默认 1): " >&2
    read -r choice
    choice=$(clean_input "$choice")
    case "$choice" in
        2) echo "h2" ;;
        3) echo "tcp" ;;
        *) echo "ws" ;;
    esac
}

generate_tunnel_key() { openssl rand -base64 32; }

add_tunnel() {
    install_nodepass
    print_title "新增 NodePass 服务端隧道"

    local listen_addr
    listen_addr=$(safe_read "监听地址（Nginx 转发目标）" "127.0.0.1")

    local default_port
    default_port=$(random_free_port)
    local port
    port=$(safe_read_port "$default_port")

    local protocol
    protocol=$(choose_protocol)

    # 路径（自动生成默认值）
    local path=""
    if [[ "$protocol" != "tcp" ]]; then
        print_info "路径长度需 ≥16 字符，按回车自动生成随机路径" >&2
        while true; do
            printf "隧道路径 (默认自动生成): " >&2
            read -r input
            input=$(clean_input "$input")
            if [[ -z "$input" ]]; then
                path="/$(openssl rand -hex 12)"   # 25 字符
                print_info "已生成随机路径: ${path}" >&2
                break
            else
                path="$input"
                [[ "$path" != /* ]] && path="/$path"
                if [[ ${#path} -ge 16 ]]; then
                    break
                else
                    print_error "路径长度不能少于 16 字符"
                fi
            fi
        done
    fi

    local target
    target=$(safe_read "后端目标地址:端口" "127.0.0.1:8080")

    # 隧道密钥
    print_info "隧道密钥设置"
    echo "  [1] 自动生成安全密钥（推荐）" >&2
    echo "  [2] 手动输入密钥" >&2
    printf "请选择 (默认 1): " >&2
    read -r key_choice
    key_choice=$(clean_input "$key_choice")
    local tunnel_key
    if [[ "$key_choice" == "2" ]]; then
        while true; do
            tunnel_key=$(safe_read "请输入隧道密钥（至少 16 字符）" "")
            [[ ${#tunnel_key} -ge 16 ]] && break
            print_error "密钥过短，至少 16 字符"
        done
    else
        tunnel_key=$(generate_tunnel_key)
        print_ok "已生成随机密钥: ${YELLOW}$tunnel_key${RESET}"
    fi

    local pool
    case "$protocol" in
        ws)  pool=2 ;;
        h2)  pool=3 ;;
        tcp) pool=0 ;;
    esac

    local tls_opts="-tls 0"

    local id id2 conf svc_name
    id=$(next_id)
    id2=$(printf "%02d" "$id")
    conf="$CONF_DIR/server-${id2}.env"
    svc_name="${SERVICE_PREFIX}-${id2}.service"

    cat > "$conf" <<EOF
ID=$id
PROTOCOL=$protocol
POOL=$pool
LISTEN_ADDR=$listen_addr
PORT=$port
PATH=$path
TARGET=$target
TUNNEL_KEY=$tunnel_key
TLS_OPTIONS=$tls_opts
EOF

    local path_opt=""
    [[ -n "$path" ]] && path_opt="-tunnel-path $path"

    local cmd="$BIN_PATH server \
  -tunnel-addr $listen_addr \
  -tunnel-port $port \
  -pool $pool \
  $tls_opts \
  $path_opt \
  -target-addr ${target%:*} \
  -target-port ${target#*:} \
  -key \"$tunnel_key\""

    cat > "$SYSTEMD_DIR/$svc_name" <<EOF
[Unit]
Description=NodePass Server Tunnel $id (${protocol}${path:+ }$path)
After=network.target

[Service]
Type=simple
ExecStart=$cmd
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$svc_name"

    print_ok "隧道 $id 创建成功"
    echo -e "  监听地址:   ${YELLOW}$listen_addr:$port${RESET}"
    echo -e "  协议:       ${CYAN}$protocol${RESET}"
    [[ -n "$path" ]] && echo -e "  路径:       ${CYAN}$path${RESET}"
    echo -e "  后端目标:   ${MAGENTA}$target${RESET}"
    echo -e "  隧道密钥:   ${GREEN}$tunnel_key${RESET}  ← 请记下此密钥，客户端连接时必需"
    echo -e "  systemd 服务: ${CYAN}$svc_name${RESET}"
    echo
    print_warn "密钥需通过安全渠道发送给客户端管理员！"
}

list_tunnels() {
    print_title "隧道列表"
    local found=0
    printf "${GREEN}%-4s %-6s %-6s %-16s %-20s${RESET}\n" "ID" "端口" "协议" "路径" "服务名"
    echo "---------------------------------------------------------------"
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        found=1
        source "$f"
        local svc="${SERVICE_PREFIX}-$(printf "%02d" "$ID").service"
        printf "%-4s %-6s %-6s %-16s %s\n" "$ID" "$PORT" "$PROTOCOL" "${PATH:--}" "$svc"
    done
    [[ $found -eq 0 ]] && print_warn "暂无隧道"
}

status_tunnels() {
    print_title "运行状态"
    local found=0
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        source "$f"
        local svc="${SERVICE_PREFIX}-$(printf "%02d" "$ID").service"
        if systemctl is-active --quiet "$svc"; then
            echo -e "隧道 ${GREEN}$ID${RESET} → ${YELLOW}运行中${RESET}"
        else
            echo -e "隧道 ${RED}$ID${RESET} → ${RED}未运行${RESET}"
        fi
        found=1
    done
    [[ $found -eq 0 ]] && print_warn "暂无隧道"
}

view_logs() {
    local num
    num=$(safe_read "输入隧道编号" "")
    [[ -z "$num" ]] && return
    local id2 svc
    id2=$(printf "%02d" "$((10#$num))")
    svc="${SERVICE_PREFIX}-${id2}.service"
    if [[ ! -f "$SYSTEMD_DIR/$svc" ]]; then
        print_error "服务不存在"
        return
    fi
    journalctl -u "$svc" -f -n 100
}

delete_tunnel() {
    local num
    num=$(safe_read "输入要删除的隧道编号" "")
    [[ -z "$num" ]] && return
    local id2 conf svc
    id2=$(printf "%02d" "$((10#$num))")
    conf="$CONF_DIR/server-${id2}.env"
    svc="${SERVICE_PREFIX}-${id2}.service"
    if [[ ! -f "$conf" ]]; then print_error "隧道不存在"; return; fi
    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "$conf" "$SYSTEMD_DIR/$svc"
    systemctl daemon-reload
    print_ok "已删除隧道 $num"
}

delete_all() {
    print_title "删除所有隧道"
    local confirm
    confirm=$(safe_read "输入 yes 确认" "no")
    [[ "$confirm" != "yes" ]] && { print_info "已取消"; return; }
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        local num id2 svc
        num=$(basename "$f" .env | cut -d'-' -f2)
        id2=$(printf "%02d" "$((10#$num))")
        svc="${SERVICE_PREFIX}-${id2}.service"
        systemctl disable --now "$svc" 2>/dev/null || true
        rm -f "$f" "$SYSTEMD_DIR/$svc"
    done
    systemctl daemon-reload
    print_ok "已删除全部隧道"
}

update_nodepass() {
    install_nodepass true
    local restarted=0
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        source "$f"
        local svc="${SERVICE_PREFIX}-$(printf "%02d" "$ID").service"
        if systemctl is-active --quiet "$svc"; then
            systemctl restart "$svc"
            ((restarted++))
        fi
    done
    print_ok "更新完成，已重启 $restarted 个隧道"
}

main_menu() {
    while true; do
        print_title "NodePass 服务端管理 (Nginx 后置)"
        echo "  1) 查看隧道列表" >&2
        echo "  2) 新增隧道" >&2
        echo "  3) 查看运行状态" >&2
        echo "  4) 查看隧道日志" >&2
        echo "  5) 删除单个隧道" >&2
        echo "  6) 删除全部隧道" >&2
        echo "  7) 更新 NodePass" >&2
        echo "  0) 退出" >&2
        echo
        local choice
        read -rp "请输入选项: " choice
        choice=$(clean_input "$choice")
        case "$choice" in
            1) list_tunnels ;;
            2) add_tunnel ;;
            3) status_tunnels ;;
            4) view_logs ;;
            5) delete_tunnel ;;
            6) delete_all ;;
            7) update_nodepass ;;
            0) print_info "再见"; exit 0 ;;
            *) print_error "无效选项" ;;
        esac
        echo
        read -rp "按回车键继续..." _
    done
}

check_deps
main_menu
