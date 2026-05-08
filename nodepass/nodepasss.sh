#!/usr/bin/env bash
set -euo pipefail

# ================================
# 颜色与基础输出
# ================================
readonly RED='\e[31m'
readonly GREEN='\e[32m'
readonly YELLOW='\e[33m'
readonly CYAN='\e[36m'
readonly MAGENTA='\e[35m'
readonly BOLD='\e[1m'
readonly RESET='\e[0m'

print_info()  { echo -e "${CYAN}[Info]${RESET} $*" >&2; }
print_ok()    { echo -e "${GREEN}[OK]${RESET}  $*" >&2; }
print_error() { echo -e "${RED}[Error]${RESET} $*" >&2; }
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
readonly CONF_DIR="$BASE_DIR/server"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly REPO="NodePassProject/nodepass"
readonly SERVICE_PREFIX="nodepass-server"

mkdir -p "$BASE_DIR" "$CONF_DIR"

# ================================
# 依赖检查
# ================================
check_deps() {
    local missing=()
    for prog in curl jq ss; do
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
    # 再次核实
    for prog in "${missing[@]}"; do
        if ! command -v "$prog" &>/dev/null; then
            print_error "安装 $prog 失败"
            exit 1
        fi
    done
    print_ok "依赖已就绪"
}

# ================================
# 工具函数
# ================================
clean_input() {
    tr -d '\000-\037' <<< "$1"
}

port_in_use() {
    ss -tuln | awk '{print $5}' | grep -qE "(:|])$1$"
}

random_port() {
    shuf -i 10000-60000 -n 1
}

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
            continue
        fi
        echo "$port"
        return
    done
}

# ================================
# NodePass 安装/更新
# ================================
detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) print_error "不支持的架构"; exit 1 ;;
    esac
}

get_latest_version() {
    local tag
    tag=$(curl -fsSL -H "User-Agent: NP-Manager" \
        "https://api.github.com/repos/${REPO}/releases/latest" \
        | jq -r '.tag_name')
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        print_error "无法获取最新版本"
        exit 1
    fi
    echo "${tag#v}"
}

install_nodepass() {
    local force="${1:-false}"
    if [[ -x "$BIN_PATH" && "$force" != "true" ]]; then
        return
    fi
    print_info "正在下载 NodePass ..."
    local arch version url tmpdir
    arch=$(detect_arch)
    version=$(get_latest_version)
    url="https://github.com/${REPO}/releases/download/v${version}/nodepass_${version}_linux_${arch}.tar.gz"
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    if ! curl -fsSL -o "$tmpdir/nodepass.tar.gz" "$url"; then
        print_error "下载失败"
        exit 1
    fi
    tar -xzf "$tmpdir/nodepass.tar.gz" -C "$tmpdir"
    if [[ ! -f "$tmpdir/nodepass" ]]; then
        print_error "压缩包损坏"
        exit 1
    fi
    mv -f "$tmpdir/nodepass" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    print_ok "NodePass 已安装/更新至 v${version}"
}

# ================================
# 隧道 ID 管理
# ================================
next_id() {
    local max=0 num
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        num=$((10#$num))   # 避免八进制
        [[ $num -gt $max ]] && max=$num
    done
    echo $((max + 1))
}

# ================================
# 协议选择 (ws / h2 / tcp)
# ================================
choose_protocol() {
    print_info "选择协议类型:"
    echo "  1) ws   - WebSocket (pool=2)" >&2
    echo "  2) h2   - HTTP/2 gRPC   (pool=3)" >&2
    echo "  3) tcp  - 原始 TCP      (pool=0)" >&2
    printf "选项 (默认 1): " >&2
    read -r c
    c=$(clean_input "$c")
    case "$c" in
        2) echo "h2" ;;
        3) echo "tcp" ;;
        *) echo "ws" ;;
    esac
}

# ================================
# 新增隧道
# ================================
add_tunnel() {
    install_nodepass

    print_title "新增 NodePass 隧道（Nginx 后置，无需证书）"

    local listen_addr="0.0.0.0"
    local alt_addr
    alt_addr=$(safe_read "监听地址（Nginx 转发目标）" "$listen_addr")
    listen_addr="$alt_addr"

    local default_port
    default_port=$(random_free_port)
    local port
    port=$(safe_read_port "$default_port")

    local protocol
    protocol=$(choose_protocol)

    local path=""
    if [[ "$protocol" != "tcp" ]]; then
        path=$(safe_read "隧道路径（以 / 开头）" "/")
        # 确保以 / 开头
        [[ "$path" != /* ]] && path="/$path"
    fi

    local target
    target=$(safe_read "后端目标地址:端口（如 127.0.0.1:3000）" "127.0.0.1:8080")

    # 计算 pool 数值
    local pool
    case "$protocol" in
        ws)  pool=2 ;;
        h2)  pool=3 ;;
        tcp) pool=0 ;;
    esac

    # 由于在 Nginx 后，始终使用 -tls 0（明文）
    local tls_opts="-tls 0"

    local id id2 conf svc_name cmd
    id=$(next_id)
    id2=$(printf "%02d" "$id")
    conf="$CONF_DIR/server-${id2}.env"
    svc_name="${SERVICE_PREFIX}-${id2}.service"

    # 保存环境配置
    cat > "$conf" <<EOF
ID=$id
PROTOCOL=$protocol
POOL=$pool
LISTEN_ADDR=$listen_addr
PORT=$port
PATH=$path
TARGET=$target
TLS_OPTIONS=$tls_opts
EOF

    # 构建命令（路径仅在 ws/h2 时附加）
    local path_opt=""
    if [[ -n "$path" ]]; then
        path_opt="-tunnel-path $path"
    fi

    cmd="$BIN_PATH server \\
  -tunnel-addr $listen_addr \\
  -tunnel-port $port \\
  -pool $pool \\
  $tls_opts \\
  $path_opt \\
  -target-addr ${target%:*} \\
  -target-port ${target#*:}"

    # 写入 systemd 服务
    cat > "$SYSTEMD_DIR/$svc_name" <<EOF
[Unit]
Description=NodePass Tunnel $id ($protocol ${path:-})
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

    print_ok "隧道创建成功"
    echo -e "编号:     ${GREEN}$id${RESET}"
    echo -e "协议:     ${BLUE}$protocol${RESET}"
    echo -e "监听:     ${YELLOW}$listen_addr:$port${RESET}"
    [[ -n "$path" ]] && echo -e "路径:     ${CYAN}$path${RESET}"
    echo -e "后端:     ${MAGENTA}$target${RESET}"
    echo -e "服务名:   ${CYAN}$svc_name${RESET}"
    echo
    print_info "客户端连接示例（假设密钥为 mykey，Nginx 域名 example.com）:"
    if [[ "$protocol" == "tcp" ]]; then
        echo "  nodepass client -remote-addr mykey@example.com:$port -pool 0 -local-addr 0.0.0.0:本地端口"
    else
        echo "  nodepass client -remote-addr mykey@example.com:443 -pool $pool -local-addr 0.0.0.0:本地端口 -tunnel-path $path"
        echo "  （Nginx 需配置将 wss/h2 流量转发至 $listen_addr:$port$path）"
    fi
}

# ================================
# 隧道列表
# ================================
list_tunnels() {
    print_title "隧道列表"
    local found=0
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        found=1
        # shellcheck disable=SC1090
        source "$f"
        local svc="${SERVICE_PREFIX}-$(printf "%02d" "$ID").service"
        printf "${GREEN}%3s${RESET} | %-6s | %-4s | %-22s | %s\n" \
            "$ID" "$PORT" "$PROTOCOL" "${PATH:--}" "$svc" >&2
    done
    [[ $found -eq 0 ]] && print_warn "暂无隧道"
}

# ================================
# 状态查看
# ================================
status_tunnels() {
    print_title "运行状态"
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        # shellcheck disable=SC1090
        source "$f"
        local svc="${SERVICE_PREFIX}-$(printf "%02d" "$ID").service"
        if systemctl is-active --quiet "$svc"; then
            echo -e "隧道 ${GREEN}$ID${RESET} (${CYAN}$PROTOCOL${RESET}) → ${YELLOW}运行中${RESET}"
        else
            echo -e "隧道 ${RED}$ID${RESET} (${CYAN}$PROTOCOL${RESET}) → ${RED}未运行${RESET}"
        fi
    done
}

# ================================
# 查看日志
# ================================
view_logs() {
    list_tunnels
    local num
    num=$(safe_read "输入隧道编号" "")
    [[ -z "$num" ]] && { print_error "编号不能为空"; return; }
    local id2
    id2=$(printf "%02d" "$((10#$num))")
    local svc="${SERVICE_PREFIX}-${id2}.service"
    if [[ ! -f "$SYSTEMD_DIR/$svc" ]]; then
        print_error "服务不存在"
        return
    fi
    print_info "最近 50 行日志:"
    journalctl -u "$svc" -n 50 --no-pager
}

# ================================
# 删除单个隧道
# ================================
delete_tunnel() {
    list_tunnels
    local num
    num=$(safe_read "输入要删除的隧道编号" "")
    [[ -z "$num" ]] && { print_error "编号不能为空"; return; }
    local id2
    id2=$(printf "%02d" "$((10#$num))")
    local conf="$CONF_DIR/server-${id2}.env"
    local svc="${SERVICE_PREFIX}-${id2}.service"
    if [[ ! -f "$conf" ]]; then
        print_error "隧道不存在"
        return
    fi
    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "$conf" "$SYSTEMD_DIR/$svc"
    systemctl daemon-reload
    print_ok "已删除隧道 $num"
}

# ================================
# 删除全部隧道
# ================================
delete_all() {
    print_title "⚠️  删除所有隧道"
    local ans
    ans=$(safe_read "确认删除？输入 yes 继续" "no")
    if [[ "$ans" != "yes" ]]; then
        print_info "取消"
        return
    fi
    for conf in "$CONF_DIR"/server-*.env; do
        [[ -f "$conf" ]] || continue
        local num
        num=$(basename "$conf" .env | cut -d'-' -f2)
        local svc="${SERVICE_PREFIX}-$(printf "%02d" "$((10#$num))").service"
        systemctl disable --now "$svc" 2>/dev/null || true
        rm -f "$conf" "$SYSTEMD_DIR/$svc"
    done
    systemctl daemon-reload
    print_ok "已删除全部隧道"
}

# ================================
# 更新 NodePass
# ================================
update_nodepass() {
    install_nodepass true
    local restarted=0
    for conf in "$CONF_DIR"/server-*.env; do
        [[ -f "$conf" ]] || continue
        # shellcheck disable=SC1090
        source "$conf"
        local svc="${SERVICE_PREFIX}-$(printf "%02d" "$ID").service"
        if systemctl is-active --quiet "$svc"; then
            systemctl restart "$svc" && ((restarted++))
        fi
    done
    print_ok "更新完成，已重启 $restarted 个隧道"
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "NodePass 管理面板 (Nginx 后置)"
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

# ================================
# 入口
# ================================
check_deps
main_menu
