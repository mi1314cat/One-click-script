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
BIN_PATH="$BASE_DIR/nodepass"
CONF_DIR="$BASE_DIR/server"
SYSTEMD_DIR="/etc/systemd/system"
REPO="NodePassProject/nodepass"
SERVICE_PREFIX="nodepass-server"

mkdir -p "$BASE_DIR" "$CONF_DIR"

clean_input() { echo "$1" | tr -d '\000-\037'; }

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
        printf "请输入监听端口 (默认: %s): " "$default" >&2
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
# 安装 NodePass
# ================================
detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) print_error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

get_latest_version() {
    local tag
    tag=$(curl -s -H "User-Agent: NodePass-Manager" "https://api.github.com/repos/${REPO}/releases/latest" | jq -r '.tag_name')
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
    local arch tag version url tmpdir
    arch=$(detect_arch)
    version=$(get_latest_version)
    tag="v${version}"
    url="https://github.com/${REPO}/releases/download/${tag}/nodepass_${version}_linux_${arch}.tar.gz"
    tmpdir=$(mktemp -d)
    if ! curl -L --fail -H "User-Agent: NodePass-Manager" "$url" -o "$tmpdir/nodepass.tar.gz"; then
        print_error "下载失败"
        rm -rf "$tmpdir"
        exit 1
    fi
    tar -xzf "$tmpdir/nodepass.tar.gz" -C "$tmpdir"
    mv "$tmpdir/nodepass" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -rf "$tmpdir"
    print_ok "NodePass 安装完成，版本: $version"
}

# ================================
# 隧道 ID
# ================================
next_id() {
    local n
    n=$(ls "$CONF_DIR"/server-*.env 2>/dev/null | wc -l)
    echo $((n + 1))
}

# ================================
# 选择传输协议
# ================================
choose_protocol() {
    echo "请选择传输协议：" >&2
    echo "1) ws   - 明文 WebSocket (路径固定为 /)" >&2
    echo "2) wss  - 加密 WebSocket (需要 TLS 证书)" >&2
    echo "3) tcp  - 原始 TCP" >&2
    printf "选择 (默认 1): " >&2
    read c
    c=$(clean_input "$c")
    case "$c" in
        2) echo "wss" ;;
        3) echo "tcp" ;;
        *) echo "ws" ;;
    esac
}

# ================================
# 生成自签名证书（用于 wss）
# ================================
gen_cert() {
    local dir="$1"
    mkdir -p "$dir/tls"
    local cert="$dir/tls/server.crt"
    local key="$dir/tls/server.key"
    if [[ -f "$cert" && -f "$key" ]]; then
        print_info "复用已有证书"
    else
        print_info "生成自签名证书（有效期 10 年）..."
        openssl req -x509 -newkey rsa:4096 -nodes \
            -keyout "$key" -out "$cert" \
            -days 3650 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
        chmod 600 "$key"
        chmod 644 "$cert"
    fi
    echo "$cert:$key"
}

# ================================
# 输入后端目标地址
# ================================
input_target() {
    local default_addr="127.0.0.1"
    local default_port="8080"
    printf "请输入后端目标地址 (默认: %s): " "$default_addr" >&2
    read addr
    addr=$(clean_input "$addr")
    [[ -z "$addr" ]] && addr="$default_addr"
    printf "请输入后端目标端口 (默认: %s): " "$default_port" >&2
    read port
    port=$(clean_input "$port")
    [[ -z "$port" ]] && port="$default_port"
    echo "$addr:$port"
}

# ================================
# 列出隧道
# ================================
list_tunnels() {
    print_title "NodePass 服务端隧道列表"
    echo -e "${CYAN}编号 | 监听端口 | 协议 | 后端目标 | systemd${RESET}" >&2
    echo "--------------------------------------------------------------" >&2
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        source "$f"
        svc="${SERVICE_PREFIX}-$(printf "%02d" "$num").service"
        echo -e "${GREEN}$num${RESET}) 端口: ${YELLOW}$PORT${RESET} | 协议: ${BLUE}$PROTOCOL${RESET} | 目标: ${MAGENTA}$TARGET${RESET} | $svc" >&2
    done
    echo "--------------------------------------------------------------" >&2
    print_warn "NodePass 不支持自定义 WebSocket 路径（固定为 /），也不支持认证。请确保使用防火墙或 Argo Tunnel 进行访问控制。"
}

# ================================
# 创建隧道
# ================================
add_tunnel() {
    install_nodepass
    print_title "新增 NodePass 服务端隧道"

    # 监听端口
    default_port=$(random_free_port)
    port=$(safe_read_port "$default_port")

    # 传输协议
    protocol=$(choose_protocol)

    # 后端目标
    target=$(input_target)

    # TLS 处理
    tls_opts=""
    if [[ "$protocol" == "wss" ]]; then
        cert_pair=$(gen_cert "$CONF_DIR")
        cert_file="${cert_pair%:*}"
        key_file="${cert_pair#*:}"
        tls_opts="-tls 2 -crt $cert_file -key $key_file"
    else
        tls_opts="-tls 0"
    fi

    # pool 类型: ws/wss => pool=2, tcp => pool=0
    if [[ "$protocol" == "tcp" ]]; then
        pool=0
    else
        pool=2
    fi

    # 监听地址固定为 0.0.0.0（允许外部访问，可自行修改）
    listen_addr="0.0.0.0"

    id=$(next_id)
    id2=$(printf "%02d" "$id")
    conf="$CONF_DIR/server-$id2.env"
    svc="${SERVICE_PREFIX}-$id2.service"

    cat > "$conf" <<EOF
ID=$id
PORT=$port
PROTOCOL=$protocol
POOL=$pool
TARGET=$target
LISTEN_ADDR=$listen_addr
TLS_OPTIONS="$tls_opts"
EOF

    # 构建 systemd 执行命令
    # 注意：NodePass 不支持 -tunnel-path，路径固定为 /
    cmd="$BIN_PATH server -tunnel-addr $listen_addr -tunnel-port $port -pool $pool $tls_opts -target-addr ${target%:*} -target-port ${target#*:}"

    cat > "$SYSTEMD_DIR/$svc" <<EOF
[Unit]
Description=NodePass Server Tunnel $id ($protocol)
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
    systemctl enable --now "$svc"

    print_ok "NodePass 隧道创建成功"
    echo -e "编号: $id"
    echo -e "监听地址: $listen_addr:$port"
    echo -e "协议: $protocol"
    echo -e "后端目标: $target"
    echo -e "systemd 服务: $svc"
    echo ""
    print_info "客户端连接示例（使用 gost）："
    echo "  gost -L rtcp://:本地端口/127.0.0.1:${port} -F \"relay+ws://你的域名:端口?path=/\""
    echo "  若使用 wss 协议，则 -F \"relay+wss://...\""
}

# ================================
# 查看状态
# ================================
status_tunnels() {
    print_title "隧道运行状态"
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        svc="${SERVICE_PREFIX}-$(printf "%02d" "$num").service"
        if systemctl is-active --quiet "$svc"; then
            st="${GREEN}运行中${RESET}"
        else
            st="${RED}未运行${RESET}"
        fi
        echo -e "隧道 ${CYAN}$num${RESET} -> $svc : $st"
    done
}

# ================================
# 查看日志
# ================================
view_logs() {
    list_tunnels
    printf "请输入要查看日志的编号: "
    read num
    num=$(clean_input "$num")
    id2=$(printf "%02d" "$num")
    svc="${SERVICE_PREFIX}-$id2.service"
    if [ ! -f "$SYSTEMD_DIR/$svc" ]; then
        print_error "服务不存在"
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
    printf "请输入要删除的编号: "
    read num
    num=$(clean_input "$num")
    id2=$(printf "%02d" "$num")
    conf="$CONF_DIR/server-$id2.env"
    svc="${SERVICE_PREFIX}-$id2.service"
    if [ ! -f "$conf" ]; then
        print_error "配置不存在"
        return
    fi
    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "$conf"
    rm -f "$SYSTEMD_DIR/$svc"
    systemctl daemon-reload
    print_ok "已删除隧道 $num"
}

# ================================
# 删除全部
# ================================
delete_all() {
    print_title "删除所有隧道"
    read -p "确认删除所有隧道？(yes/no): " ans
    ans=$(clean_input "$ans")
    [ "$ans" != "yes" ] && { print_info "已取消"; return; }
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        svc="${SERVICE_PREFIX}-$(printf "%02d" "$num").service"
        systemctl disable --now "$svc" 2>/dev/null || true
        rm -f "$SYSTEMD_DIR/$svc"
        rm -f "$f"
    done
    systemctl daemon-reload
    print_ok "已删除所有隧道"
}

# ================================
# 更新 NodePass
# ================================
update_nodepass() {
    print_info "正在更新 NodePass ..."
    install_nodepass true
    # 重启所有隧道
    for f in "$CONF_DIR"/server-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        svc="${SERVICE_PREFIX}-$(printf "%02d" "$num").service"
        if systemctl is-active --quiet "$svc"; then
            systemctl restart "$svc"
            print_info "已重启隧道 $num"
        fi
    done
    print_ok "更新完成"
}

# ================================
# 主菜单
# ================================
menu() {
    while true; do
        print_title "NodePass 服务端管理面板"
        echo "1) 查看隧道列表"
        echo "2) 新增隧道"
        echo "3) 查看隧道状态"
        echo "4) 查看隧道日志"
        echo "5) 删除某个隧道"
        echo "6) 删除所有隧道"
        echo "7) 更新 NodePass"
        echo "0) 退出"
        printf "请选择: "
        read c
        c=$(clean_input "$c")
        case "$c" in
            1) list_tunnels;   printf "按回车继续..."; read ;;
            2) add_tunnel;     printf "按回车继续..."; read ;;
            3) status_tunnels; printf "按回车继续..."; read ;;
            4) view_logs;      printf "按回车继续..."; read ;;
            5) delete_tunnel;  printf "按回车继续..."; read ;;
            6) delete_all;     printf "按回车继续..."; read ;;
            7) update_nodepass; printf "按回车继续..."; read ;;
            0) exit 0 ;;
            *) print_error "无效选项"; printf "按回车继续..."; read ;;
        esac
    done
}

# 安装 jq 如果缺失（用于解析版本）
if ! command -v jq &>/dev/null; then
    print_info "安装 jq ..."
    apt update && apt install -y jq
fi

menu
