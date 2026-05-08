#!/usr/bin/env bash
set -euo pipefail

# ================================
# 颜色（仅用于 stderr UI）
# ================================
if [ -t 2 ]; then
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[34m')"
  MAGENTA="$(printf '\033[35m')"
  CYAN="$(printf '\033[36m')"
  BOLD="$(printf '\033[1m')"
  RESET="$(printf '\033[0m')"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; BOLD=""; RESET=""
fi

print_info()  { printf '%s[信息]%s %s\n' "$CYAN" "$RESET" "$*" >&2; }
print_ok()    { printf '%s[OK]%s   %s\n' "$GREEN" "$RESET" "$*" >&2; }
print_error() { printf '%s[错误]%s %s\n' "$RED" "$RESET" "$*" >&2; }
print_warn()  { printf '%s[注意]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }

print_title() {
    printf '%s%s\n' "$MAGENTA" "$BOLD" >&2
    printf '╔══════════════════════════════════════════════╗\n' >&2
    printf '║ %s ║\n' "$1" >&2
    printf '╚══════════════════════════════════════════════╝\n' >&2
    printf '%s\n' "$RESET" >&2
}

# ================================
# 常量
# ================================
BASE_DIR="/root/catmi/nodepass"
CLIENT_DIR="$BASE_DIR/client"
BIN_PATH="$BASE_DIR/nodepass"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_PREFIX="nodepass-client"

mkdir -p "$CLIENT_DIR"

clean_input() { tr -d '\000-\037' <<<"$1"; }

# ================================
# 输入工具
# ================================
_read_line() {
    local var
    if [ -t 0 ] && [ -r /dev/tty ]; then
        IFS= read -r var </dev/tty || var=""
    else
        IFS= read -r var || var=""
    fi
    printf '%s\n' "$var"
}

prompt_read() {
    local prompt="$1" default="$2" input
    printf '%s (默认: %s): ' "$prompt" "$default" >&2
    input=$(_read_line)
    input="${input:-$default}"
    input=$(clean_input "$input")
    printf '%s\n' "$input"
}

prompt_read_port() {
    local label="$1" default="$2" input port
    while :; do
        printf '%s (默认: %s): ' "$label" "$default" >&2
        input=$(_read_line)
        input="${input:-$default}"
        input=$(clean_input "$input")
        port="$input"
        if ! printf '%s' "$port" | grep -Eq '^[0-9]+$'; then
            print_error "端口必须是数字"
            continue
        fi
        if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            print_error "端口范围错误"
            continue
        fi
        printf '%s\n' "$port"
        return
    done
}

menu_read() {
    local prompt="$1" input
    printf '%s' "$prompt" >&2
    input=$(_read_line)
    printf '%s\n' "$input"
}

# ================================
# 自动编号
# ================================
next_id() {
    local max=0 num d
    for d in "$CLIENT_DIR"/*; do
        [ -d "$d" ] || continue
        num=$(basename "$d")
        printf '%s\n' "$num" | grep -Eq '^[0-9]+$' || continue
        num=$((10#$num))
        [ "$num" -gt "$max" ] && max="$num"
    done
    printf '%02d\n' $((max + 1))
}

# ================================
# env 解析
# ================================
parse_env_file() {
    local envfile="$1" line key val
    ID=""
    TARGET_IP="127.0.0.1"
    TARGET_PORT=""
    PASSWORD=""
    SERVER_DOMAIN=""
    SERVER_PORT="443"

    [ -f "$envfile" ] || return 0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf '%s' "$line" | grep -Eq '^[[:space:]]*#' && continue
        if printf '%s\n' "$line" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*='; then
            key=${line%%=*}
            val=${line#*=}
            val=${val#\"}; val=${val%\"}
            val=${val#\'}; val=${val%\'}
            case "$key" in
                ID) ID="$val" ;;
                TARGET_IP) TARGET_IP="$val" ;;
                TARGET_PORT) TARGET_PORT="$val" ;;
                PASSWORD) PASSWORD="$val" ;;
                SERVER_DOMAIN) SERVER_DOMAIN="$val" ;;
                SERVER_PORT) SERVER_PORT="$val" ;;
            esac
        fi
    done <"$envfile"
}

# ================================
# run.sh（无 mux）
# ================================
write_run_script() {
    local dir="$1"
    local run="$dir/run.sh"
    cat >"$run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$BASE_DIR/client.env"
BIN_PATH="/root/catmi/nodepass/nodepass"

parse_env_file() {
    local envfile="$1" line key val
    ID=""
    TARGET_IP="127.0.0.1"
    TARGET_PORT=""
    PASSWORD=""
    SERVER_DOMAIN=""
    SERVER_PORT="443"

    [ -f "$envfile" ] || return 0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf '%s' "$line" | grep -Eq '^[[:space:]]*#' && continue
        if printf '%s\n' "$line" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*='; then
            key=${line%%=*}
            val=${line#*=}
            val=${val#\"}; val=${val%\"}
            val=${val#\'}; val=${val%\'}
            case "$key" in
                ID) ID="$val" ;;
                TARGET_IP) TARGET_IP="$val" ;;
                TARGET_PORT) TARGET_PORT="$val" ;;
                PASSWORD) PASSWORD="$val" ;;
                SERVER_DOMAIN) SERVER_DOMAIN="$val" ;;
                SERVER_PORT) SERVER_PORT="$val" ;;
            esac
        fi
    done <"$envfile"
}

if [ ! -x "$BIN_PATH" ]; then
    printf '[错误] NodePass 二进制不存在或不可执行: %s\n' "$BIN_PATH" >&2
    exit 1
fi

parse_env_file "$ENV_FILE"

if [ -z "${TARGET_PORT:-}" ] || [ -z "${SERVER_DOMAIN:-}" ] || [ -z "${PASSWORD:-}" ]; then
    printf '[错误] 配置不完整，无法启动隧道\n' >&2
    exit 1
fi

exec "$BIN_PATH" client \
    -tunnel-addr "$SERVER_DOMAIN" \
    -tunnel-port "$SERVER_PORT" \
    -password "$PASSWORD" \
    -target-addr "$TARGET_IP" \
    -target-port "$TARGET_PORT"
EOF
    chmod +x "$run"
}

# ================================
# 创建隧道（v1 版）
# ================================
create_tunnel() {
    print_title "新增 NodePass 客户端隧道"

    if [ ! -x "$BIN_PATH" ]; then
        print_error "NodePass 二进制不存在: $BIN_PATH"
        return 1
    fi

    local id dir SERVER_DOMAIN SERVER_PORT PASSWORD TARGET_IP TARGET_PORT svc svcfile envfile

    id=$(next_id)
    dir="$CLIENT_DIR/$id"
    mkdir -p "$dir"

    SERVER_DOMAIN=$(prompt_read "服务端域名（Argo 域名）" "your.domain.com")
    SERVER_PORT=$(prompt_read_port "服务端端口" "443")
    PASSWORD=$(prompt_read "密码（留空自动生成）" "")
    if [ -z "$PASSWORD" ]; then
        PASSWORD=$(openssl rand -base64 16)
        print_info "未输入密码，已自动生成: $PASSWORD"
    fi

    TARGET_IP=$(prompt_read "本地后端 IP" "127.0.0.1")
    TARGET_PORT=$(prompt_read_port "本地后端端口" "10000")

    envfile="$dir/client.env"
    cat >"$envfile" <<EOF
ID=$id
TARGET_IP=$TARGET_IP
TARGET_PORT=$TARGET_PORT
PASSWORD=$PASSWORD
SERVER_DOMAIN=$SERVER_DOMAIN
SERVER_PORT=$SERVER_PORT
EOF

    write_run_script "$dir"

    svc="${SERVICE_PREFIX}-${id}.service"
    svcfile="$SYSTEMD_DIR/$svc"

    cat >"$svcfile" <<EOF
[Unit]
Description=NodePass Client Tunnel $id
After=network.target

[Service]
WorkingDirectory=$dir
ExecStart=$dir/run.sh
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$svc"

    print_ok "隧道创建成功"
}

# ================================
# 列表
# ================================
list_tunnels() {
    print_title "当前 NodePass 隧道列表"
    printf '%s编号 | 后端 | 密码 | 状态 | systemd 名称%s\n' "$CYAN" "$RESET" >&2
    printf '%s\n' "--------------------------------------------------------------------------------------------------------" >&2

    local any=0 d id envfile svc st

    for d in "$CLIENT_DIR"/*; do
        [ -d "$d" ] || continue
        any=1
        id=$(basename "$d")
        envfile="$d/client.env"

        parse_env_file "$envfile"

        svc="${SERVICE_PREFIX}-${id}.service"
        if systemctl is-active --quiet "$svc"; then
            st="${GREEN}运行中${RESET}"
        else
            st="${RED}未运行${RESET}"
        fi

        printf '%s%s%s) 后端: %s%s:%s%s | 密码: %s%s%s | 状态: %s | 服务: %s%s%s\n' \
            "$GREEN" "$id" "$RESET" \
            "$BLUE" "$TARGET_IP" "$TARGET_PORT" "$RESET" \
            "$CYAN" "$PASSWORD" "$RESET" \
            "$st" \
            "$CYAN" "$svc" "$RESET" >&2
    done

    [ "$any" -eq 0 ] && print_warn "暂无客户端隧道"
}

# ================================
# 状态
# ================================
status_tunnels() {
    print_title "隧道运行状态"
    local any=0 d id svc st
    for d in "$CLIENT_DIR"/*; do
        [ -d "$d" ] || continue
        any=1
        id=$(basename "$d")
        svc="${SERVICE_PREFIX}-${id}.service"
        if systemctl is-active --quiet "$svc"; then
            st="${GREEN}运行中${RESET}"
        else
            st="${RED}未运行${RESET}"
        fi
        printf '隧道 %s%s%s -> %s : %s\n' "$CYAN" "$id" "$RESET" "$svc" "$st" >&2
    done
    [ "$any" -eq 0 ] && print_warn "暂无客户端隧道"
}

# ================================
# 选择隧道
# ================================
choose_id() {
    while :; do
        list_tunnels
        printf '\n' >&2
        local raw id
        raw=$(prompt_read "请输入隧道 ID（例如 01）" "")
        if [ -z "$raw" ]; then
            print_error "隧道 ID 不能为空"
            continue
        fi
        if printf '%s\n' "$raw" | grep -Eq '^[0-9]+$'; then
            id=$(printf '%02d\n' "$raw")
        else
            id="$raw"
        fi
        if [ ! -d "$CLIENT_DIR/$id" ]; then
            print_error "隧道不存在: $id"
            continue
        fi
        printf '%s\n' "$id"
        return 0
    done
}

# ================================
# 日志 / 启停 / 删除
# ================================
show_logs() {
    local id svc
    id=$(choose_id)
    svc="${SERVICE_PREFIX}-${id}.service"
    print_info "显示 $svc 最近 50 行日志（Ctrl+C 退出）"
    journalctl -u "$svc" -n 50 -f
}

start_tunnel() {
    local id svc
    id=$(choose_id)
    svc="${SERVICE_PREFIX}-${id}.service"
    systemctl start "$svc"
    print_ok "已启动隧道 $id"
}

stop_tunnel() {
    local id svc
    id=$(choose_id)
    svc="${SERVICE_PREFIX}-${id}.service"
    systemctl stop "$svc"
    print_ok "已停止隧道 $id"
}

restart_tunnel() {
    local id svc
    id=$(choose_id)
    svc="${SERVICE_PREFIX}-${id}.service"
    systemctl restart "$svc"
    print_ok "已重启隧道 $id"
}

delete_tunnel() {
    local id svc svcfile dir
    id=$(choose_id)
    svc="${SERVICE_PREFIX}-${id}.service"
    svcfile="$SYSTEMD_DIR/$svc"
    dir="$CLIENT_DIR/$id"

    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "$svcfile"
    rm -rf "$dir"
    systemctl daemon-reload
    print_ok "已删除隧道 $id"
}

delete_all() {
    print_warn "确认删除所有客户端隧道？(yes/no)"
    local ans
    ans=$(_read_line)
    ans=$(clean_input "$ans")
    if [ "$ans" != "yes" ]; then
        print_info "已取消"
        return
    fi

    local d id svc svcfile
    for d in "$CLIENT_DIR"/*; do
        [ -d "$d" ] || continue
        id=$(basename "$d")
        svc="${SERVICE_PREFIX}-${id}.service"
        svcfile="$SYSTEMD_DIR/$svc"
        systemctl disable --now "$svc" 2>/dev/null || true
        rm -f "$svcfile"
        rm -rf "$d"
    done
    systemctl daemon-reload
    print_ok "已删除所有客户端隧道"
}

# ================================
# 主菜单
# ================================
main_menu() {
    while :; do
        print_title "NodePass v1 客户端管理（最终稳定版）"
        printf '  1) 查看隧道列表\n' >&2
        printf '  2) 新增隧道\n' >&2
        printf '  3) 查看隧道运行状态\n' >&2
        printf '  4) 查看某个隧道日志\n' >&2
        printf '  5) 停止某个隧道\n' >&2
        printf '  6) 启动某个隧道\n' >&2
        printf '  7) 重启某个隧道\n' >&2
        printf '  8) 删除某个隧道\n' >&2
        printf '  9) 删除所有隧道\n' >&2
        printf '  0) 退出\n\n' >&2

        local c
        c=$(menu_read "请选择: ")
        case "$c" in
            1) list_tunnels ;;
            2) create_tunnel ;;
            3) status_tunnels ;;
            4) show_logs ;;
            5) stop_tunnel ;;
            6) start_tunnel ;;
            7) restart_tunnel ;;
            8) delete_tunnel ;;
            9) delete_all ;;
            0) print_info "再见"; exit 0 ;;
            *) print_error "无效选项" ;;
        esac
        printf '\n' >&2
        menu_read "按回车继续..."
    done
}

trap 'printf "\n" >&2; print_info "已中断，退出"; exit 1' INT

main_menu
