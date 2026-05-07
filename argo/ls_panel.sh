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
print_warn()  { echo -e "${YELLOW}[提醒]${RESET} $1" >&2; }

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
BASE_DIR="/root/catmi/argo_temp"
BIN="$BASE_DIR/cloudflared"
TUNNELS_DIR="$BASE_DIR/tunnels"
mkdir -p "$TUNNELS_DIR"

# ================================
# 工具函数
# ================================
clean_input() {
    echo "$1" | tr -d '\000-\037'
}

check_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

normalize_id() {
    local id="$1"
    id=$(clean_input "$id")
    if [[ "$id" =~ ^[0-9]+$ ]]; then
        printf "%02d" "$id"
    else
        echo "$id"
    fi
}

# ================================
# 下载 cloudflared
# ================================
install_cloudflared() {
    if [[ -x "$BIN" ]] && "$BIN" --version >/dev/null 2>&1; then
        return
    fi
    print_info "未检测到 cloudflared，正在下载最新版..."
    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)     CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        aarch64)    CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
        armv7l|armhf) CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
        *) print_error "不支持的架构: $ARCH"; exit 1 ;;
    esac
    wget -qO "$BIN" "$CFD_URL" || { print_error "下载失败"; exit 1; }
    chmod +x "$BIN"
    print_ok "cloudflared 安装完成"
}

# 获取下一个隧道编号
next_id() {
    local n
    n=$(ls -d "$TUNNELS_DIR"/*/ 2>/dev/null | wc -l)
    echo $((n + 1))
}

# ================================
# 列出所有隧道（含状态）
# ================================
list_tunnels() {
    print_title "临时隧道列表（自动保活）"
    echo -e "${CYAN}编号 | 本地端口 | 域名 | 隧道状态 | 监控状态${RESET}" >&2
    echo "----------------------------------------------------------------------------------------" >&2
    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local num=$(basename "$dir")
        local env_file="$dir/tunnel.env"
        if [[ -f "$env_file" ]]; then
            source "$env_file"
            local port="${PORT:-?}"
            local url="${URL:-未获取}"

            # 检查主进程
            local tunnel_pid_file="$dir/tunnel.pid"
            local tunnel_status="${RED}离线${RESET}"
            if [[ -f "$tunnel_pid_file" ]] && kill -0 $(cat "$tunnel_pid_file") 2>/dev/null; then
                tunnel_status="${GREEN}在线${RESET}"
            fi

            # 检查监控进程
            local monitor_pid_file="$dir/monitor.pid"
            local monitor_status="${RED}未运行${RESET}"
            if [[ -f "$monitor_pid_file" ]] && kill -0 $(cat "$monitor_pid_file") 2>/dev/null; then
                monitor_status="${GREEN}运行中${RESET}"
            fi

            echo -e "${GREEN}$num${RESET}) 端口: ${YELLOW}$port${RESET} | 域名: ${MAGENTA}$url${RESET} | 隧道: $tunnel_status | 监控: $monitor_status" >&2
        fi
    done
    echo "----------------------------------------------------------------------------------------" >&2
}

# ================================
# 启动单个隧道（含 429 限流自动重试 + 指数退避）
# ================================
start_single_tunnel() {
    local tunnel_dir="$1"
    local port="$2"
    local log_file="$tunnel_dir/cloudflared.log"
    local pid_file="$tunnel_dir/tunnel.pid"
    local max_retries=5
    local retry_delay=15   # 初始等待秒数

    rm -f "$log_file" "$pid_file"

    for attempt in $(seq 1 $max_retries); do
        # 启动隧道
        nohup $BIN tunnel --url "http://localhost:$port" --no-autoupdate --config /dev/null \
            > "$log_file" 2>&1 &
        local pid=$!
        echo "$pid" > "$pid_file"
        sleep 3

        # 检查进程是否还活着
        if ! kill -0 "$pid" 2>/dev/null; then
            # 进程已退出，检查日志中是否有 429 错误
            if grep -q "429 Too Many Requests" "$log_file" 2>/dev/null; then
                print_warn "触发 Cloudflare 限流 (429)，等待 ${retry_delay} 秒后重试 (第 $attempt 次)..."
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2))   # 指数退避
                continue
            else
                # 其他错误
                cat "$log_file" >&2
                return 1
            fi
        fi

        # 提取域名
        local url=""
        for i in {1..30}; do
            url=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$log_file" | head -n 1)
            [[ -n "$url" ]] && break
            sleep 0.5
        done

        if [[ -n "$url" ]]; then
            sed -i "/^URL=/d" "$tunnel_dir/tunnel.env" 2>/dev/null || true
            echo "URL=$url" >> "$tunnel_dir/tunnel.env"
            return 0
        else
            # 未获取到域名，可能也是被限流导致
            if grep -q "429 Too Many Requests" "$log_file" 2>/dev/null; then
                print_warn "创建成功但未返回域名（可能限流），等待 ${retry_delay} 秒后重试..."
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2))
                continue
            else
                print_error "未能从日志中提取域名"
                cat "$log_file" >&2
                return 1
            fi
        fi
    done

    print_error "经过 $max_retries 次重试仍失败，请稍后再试或改用固定隧道。"
    return 1
}

# ================================
# 启动保活监控（修复版：精确匹配端口，无全局pkill）
# ================================
start_monitor() {
    local tunnel_dir="$1"
    local port="$2"
    local monitor_script="$tunnel_dir/monitor.sh"
    local monitor_pid_file="$tunnel_dir/monitor.pid"
    local monitor_log="$tunnel_dir/monitor.log"

    # 停止旧的监控
    if [[ -f "$monitor_pid_file" ]]; then
        kill $(cat "$monitor_pid_file") 2>/dev/null || true
        rm -f "$monitor_pid_file"
    fi

    cat > "$monitor_script" <<'MONITOR_EOF'
#!/usr/bin/env bash
TUNNEL_DIR="$1"
PORT="$2"
BIN="$3"

FAIL_COUNT=0
MAX_FAIL=3
CHECK_INTERVAL=60

restart_tunnel() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') 执行重启隧道..." >> "$TUNNEL_DIR/monitor.log"

    # 1) 通过 PID 文件精确停止旧进程
    if [[ -f "$TUNNEL_DIR/tunnel.pid" ]]; then
        local old_pid=$(cat "$TUNNEL_DIR/tunnel.pid")
        if kill -0 "$old_pid" 2>/dev/null; then
            kill "$old_pid" 2>/dev/null || true
            sleep 1
        fi
        rm -f "$TUNNEL_DIR/tunnel.pid"
    fi

    # 2) 额外清理：仅杀匹配当前端口的 cloudflared 进程（避免误杀其他隧道）
    pkill -f "cloudflared tunnel --url http://localhost:$PORT" 2>/dev/null || true

    rm -f "$TUNNEL_DIR/cloudflared.log"

    # 3) 启动新隧道
    nohup $BIN tunnel --url "http://localhost:$PORT" --no-autoupdate --config /dev/null \
        > "$TUNNEL_DIR/cloudflared.log" 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$TUNNEL_DIR/tunnel.pid"

    sleep 2
    local new_url=""
    for i in {1..25}; do
        new_url=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TUNNEL_DIR/cloudflared.log" | head -n 1)
        [[ -n "$new_url" ]] && break
        sleep 0.4
    done

    if [[ -n "$new_url" ]]; then
        sed -i "/^URL=/d" "$TUNNEL_DIR/tunnel.env" 2>/dev/null || true
        echo "URL=$new_url" >> "$TUNNEL_DIR/tunnel.env"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 新域名: $new_url" >> "$TUNNEL_DIR/monitor.log"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 重启后未能获取域名！" >> "$TUNNEL_DIR/monitor.log"
    fi
    FAIL_COUNT=0
}

while true; do
    sleep $CHECK_INTERVAL

    if [[ -f "$TUNNEL_DIR/tunnel.env" ]]; then
        source "$TUNNEL_DIR/tunnel.env"
    fi
    local url="${URL:-}"

    # 检查主进程
    local pid_file="$TUNNEL_DIR/tunnel.pid"
    if [[ ! -f "$pid_file" ]] || ! kill -0 $(cat "$pid_file") 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 主进程消失，重启..." >> "$TUNNEL_DIR/monitor.log"
        restart_tunnel
        continue
    fi

    # 健康检查
    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" =~ ^(200|301|302|404|502)$ ]]; then
        FAIL_COUNT=0
        echo "$(date '+%Y-%m-%d %H:%M:%S') 健康检查通过 ($HTTP_CODE)" >> "$TUNNEL_DIR/monitor.log"
    else
        ((FAIL_COUNT++))
        echo "$(date '+%Y-%m-%d %H:%M:%S') 健康检查失败 ($HTTP_CODE)，连续: $FAIL_COUNT/$MAX_FAIL" >> "$TUNNEL_DIR/monitor.log"
        if (( FAIL_COUNT >= MAX_FAIL )); then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 连续失败达 $MAX_FAIL 次，重启隧道..." >> "$TUNNEL_DIR/monitor.log"
            restart_tunnel
        fi
    fi
done
MONITOR_EOF

    chmod +x "$monitor_script"
    nohup "$monitor_script" "$tunnel_dir" "$port" "$BIN" >> "$monitor_log" 2>&1 &
    echo $! > "$monitor_pid_file"
}

# ================================
# 内部停止函数（不输出菜单，仅清理进程）
# ================================
stop_tunnel_internal() {
    local tunnel_dir="$1"
    # 停止监控
    if [[ -f "$tunnel_dir/monitor.pid" ]]; then
        kill $(cat "$tunnel_dir/monitor.pid") 2>/dev/null || true
        rm -f "$tunnel_dir/monitor.pid"
    fi
    # 停止隧道进程
    if [[ -f "$tunnel_dir/tunnel.pid" ]]; then
        kill $(cat "$tunnel_dir/tunnel.pid") 2>/dev/null || true
        rm -f "$tunnel_dir/tunnel.pid"
    fi
    # 精确清理可能残留的进程（按端口）
    local port=$(grep -oP 'PORT=\K\d+' "$tunnel_dir/tunnel.env" 2>/dev/null || echo "")
    if [[ -n "$port" ]]; then
        pkill -f "cloudflared tunnel --url http://localhost:$port" 2>/dev/null || true
    fi
}

# ================================
# 新增临时隧道
# ================================
add_tunnel() {
    install_cloudflared
    print_title "新增临时隧道"

    echo -e "${YELLOW}请输入要暴露的本地端口${RESET}" >&2
    local default_port="8080"
    local port
    printf "端口（默认 %s）: " "$default_port" >&2
    read port
    port=$(clean_input "${port:-$default_port}")
    if ! check_port "$port"; then
        print_error "端口无效（1-65535）"
        return 1
    fi

    local id=$(next_id)
    local id2=$(printf "%02d" "$id")
    local tunnel_dir="$TUNNELS_DIR/$id2"
    mkdir -p "$tunnel_dir"

    cat > "$tunnel_dir/tunnel.env" <<EOF
ID=$id
PORT=$port
URL=
EOF

    if ! start_single_tunnel "$tunnel_dir" "$port"; then
        print_error "隧道启动失败"
        rm -rf "$tunnel_dir"
        return 1
    fi

    source "$tunnel_dir/tunnel.env"
    if [[ -z "${URL}" ]]; then
        print_error "未能获取域名"
        rm -rf "$tunnel_dir"
        return 1
    fi

    start_monitor "$tunnel_dir" "$port"
    print_ok "临时隧道创建成功"
    echo -e "编号: ${GREEN}$id2${RESET}"
    echo -e "本地端口: ${YELLOW}$port${RESET}"
    echo -e "域名: ${CYAN}${URL}${RESET}"
    echo -e "监控状态: ${GREEN}已启用${RESET}"
}

# ================================
# 查看某个隧道日志
# ================================
view_logs() {
    list_tunnels
    printf "请输入要查看日志的隧道编号: " >&2
    read num
    num=$(normalize_id "$num")
    local tunnel_dir="$TUNNELS_DIR/$num"
    if [[ ! -d "$tunnel_dir" ]]; then
        print_error "隧道不存在: $num"
        return
    fi
    local log_file="$tunnel_dir/cloudflared.log"
    if [[ -f "$log_file" ]]; then
        print_info "显示临时隧道 $num 最近 50 行日志"
        tail -n 50 "$log_file"
    else
        print_error "日志文件不存在"
    fi
}

# ================================
# 停止某个隧道（菜单调用）
# ================================
stop_tunnel() {
    list_tunnels
    printf "请输入要停止的隧道编号: " >&2
    read num
    num=$(normalize_id "$num")
    local tunnel_dir="$TUNNELS_DIR/$num"
    if [[ ! -d "$tunnel_dir" ]]; then
        print_error "隧道不存在: $num"
        return
    fi
    stop_tunnel_internal "$tunnel_dir"
    print_ok "已停止临时隧道 $num"
}

# ================================
# 启动（重新创建）某个隧道
# ================================
start_tunnel() {
    list_tunnels
    printf "请输入要启动（重新创建）的隧道编号: " >&2
    read num
    num=$(normalize_id "$num")
    local tunnel_dir="$TUNNELS_DIR/$num"
    if [[ ! -d "$tunnel_dir" ]]; then
        print_error "隧道不存在: $num"
        return
    fi

    source "$tunnel_dir/tunnel.env"
    local port="${PORT}"
    if [[ -z "$port" ]]; then
        print_error "配置中无端口信息，请删除后重新创建"
        return
    fi

    print_warn "重新创建将生成全新域名，确认继续？(y/N): "
    read ans
    ans=$(clean_input "$ans")
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        print_info "已取消"
        return
    fi

    # 完全清理旧进程
    stop_tunnel_internal "$tunnel_dir"

    # 重新启动
    if ! start_single_tunnel "$tunnel_dir" "$port"; then
        print_error "启动失败"
        return 1
    fi

    start_monitor "$tunnel_dir" "$port"

    source "$tunnel_dir/tunnel.env"
    echo -e "新域名: ${CYAN}${URL}${RESET}"
    print_ok "隧道已重新启动"
}

# ================================
# 删除单个隧道
# ================================
delete_tunnel() {
    list_tunnels
    printf "请输入要删除的隧道编号: " >&2
    read num
    num=$(normalize_id "$num")
    local tunnel_dir="$TUNNELS_DIR/$num"
    if [[ ! -d "$tunnel_dir" ]]; then
        print_error "隧道不存在: $num"
        return
    fi
    stop_tunnel_internal "$tunnel_dir"
    rm -rf "$tunnel_dir"
    print_ok "已删除临时隧道 $num"
}

# ================================
# 删除所有隧道
# ================================
delete_all_tunnels() {
    print_title "删除所有临时隧道"
    read -p "确认删除所有临时隧道？(yes/no): " ans
    ans=$(clean_input "$ans")
    [[ "$ans" != "yes" ]] && { print_info "已取消"; return; }

    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        stop_tunnel_internal "$dir"
        rm -rf "$dir"
    done
    print_ok "已删除所有临时隧道"
}

# ================================
# 彻底删除脚本及所有文件
# ================================
purge_everything() {
    print_title "⚠ 彻底删除临时隧道脚本及所有文件 ⚠"
    echo -e "${RED}将执行：${RESET}"
    echo "  - 停止所有临时隧道及监控"
    echo "  - 删除工作目录 $BASE_DIR"
    echo "  - 删除脚本自身"
    echo ""
    read -p "确认彻底删除？请输入 yes 继续: " ans
    ans=$(clean_input "$ans")
    if [[ "$ans" != "yes" ]]; then
        print_info "已取消"
        return
    fi

    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        stop_tunnel_internal "$dir"
        rm -rf "$dir"
    done

    print_info "删除工作目录 $BASE_DIR ..."
    rm -rf "$BASE_DIR"

    SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
    print_info "删除脚本 $SCRIPT_PATH ..."
    rm -f "$SCRIPT_PATH"

    echo -e "${GREEN}彻底清理完成！${RESET}"
    exit 0
}

# ================================
# 主菜单
# ================================
menu() {
    while true; do
        print_title "临时隧道管理 (多开 + 自动保活) - 限流修复版"
        echo "1) 查看隧道列表"
        echo "2) 新增临时隧道"
        echo "3) 停止某个隧道"
        echo "4) 启动（重新创建）某个隧道"
        echo "5) 查看某个隧道日志"
        echo "6) 删除某个隧道"
        echo "7) 删除所有隧道"
        echo "8) 彻底删除脚本及所有文件"
        echo "0) 退出"

        printf "请选择: " >&2
        read c
        c=$(clean_input "$c")

        case "$c" in
            1) list_tunnels;      printf "按回车继续..." >&2; read ;;
            2) add_tunnel;        printf "按回车继续..." >&2; read ;;
            3) stop_tunnel;       printf "按回车继续..." >&2; read ;;
            4) start_tunnel;      printf "按回车继续..." >&2; read ;;
            5) view_logs;         printf "按回车继续..." >&2; read ;;
            6) delete_tunnel;     printf "按回车继续..." >&2; read ;;
            7) delete_all_tunnels; printf "按回车继续..." >&2; read ;;
            8) purge_everything;  ;;
            0) exit 0 ;;
            *) print_error "无效选项"; printf "按回车继续..." >&2; read ;;
        esac
    done
}

menu
