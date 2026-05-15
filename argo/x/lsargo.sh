#!/usr/bin/env bash
set -uo pipefail

# =========================================================
#  Argo Temp Tunnel Manager + Watchdog 集成版
#  特性：
#   - 多临时隧道管理（创建/删除/日志查看）
#   - 每个隧道独立 Watchdog 守护进程
#   - 三层恢复：服务重启 → 隧道重建 → 指数退避
#   - Watchdog 子菜单（启停/日志/参数修改/重置）
#   - 所有操作均自动关联隧道生命周期
# =========================================================

# ---------- 颜色定义 ----------
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

# ---------- 基础路径 ----------
BASE_DIR="/root/catmi/argo_temp"
BIN="$BASE_DIR/cloudflared"
TUNNELS_DIR="$BASE_DIR/tunnels"
WATCHDOG_CORE="$BASE_DIR/watchdog_core.sh"

mkdir -p "$TUNNELS_DIR"

# ---------- 工具函数 ----------
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

# ---------- 下载 cloudflared ----------
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

# ---------- 隧道编号生成 ----------
next_id() {
    local n
    n=$(ls -d "$TUNNELS_DIR"/*/ 2>/dev/null | wc -l)
    echo $((n + 1))
}

# =========================================================
#  Watchdog 核心脚本生成（每个隧道独立守护进程）
# =========================================================
generate_watchdog_core() {
    if [[ -f "$WATCHDOG_CORE" ]]; then
        return 0
    fi
    cat > "$WATCHDOG_CORE" <<'WATCHDOG_CORE_EOF'
#!/usr/bin/env bash
set -uo pipefail

# Watchdog Core - 由临时隧道管理器调用
# 用法: watchdog_core.sh {start|stop|restart|status|log|config|reset} --tunnel-dir <目录>

# ---------- 参数解析 ----------
ACTION=""
TUNNEL_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        start|stop|restart|status|log|config|reset)
            ACTION="$1"
            ;;
        --tunnel-dir)
            TUNNEL_DIR="$2"
            shift
            ;;
        *)
            ;;
    esac
    shift
done

if [[ -z "$TUNNEL_DIR" || ! -d "$TUNNEL_DIR" ]]; then
    echo "错误：未指定有效的隧道目录" >&2
    exit 1
fi

# ---------- 文件路径 ----------
CONFIG_FILE="$TUNNEL_DIR/watchdog.conf"
STATE_FILE="$TUNNEL_DIR/watchdog.state"
LOG_FILE="$TUNNEL_DIR/watchdog.log"
LOCK_FILE="/var/run/argo-watchdog-$(basename $TUNNEL_DIR).lock"
PID_FILE="/var/run/argo-watchdog-$(basename $TUNNEL_DIR).pid"

# 日志轮转
LOG_MAX_SIZE=$((1 * 1024 * 1024))
LOG_BACKUPS=2

# ---------- 默认配置 ----------
default_config() {
    cat > "$CONFIG_FILE" <<'CFG_EOF'
CHECK_METHOD="http"
HTTP_CHECK_URL="http://127.0.0.1:${LOCAL_PORT}"
CHECK_PORT=${LOCAL_PORT}
CHECK_INTERVAL=30
FAIL_THRESHOLD=3
TIMEOUT=3
RESTART_DELAY=5
RESTART_CHECK_DELAY=20
FIRST_BACKOFF=1800
SECOND_BACKOFF=21600
RECOVERY_COOLDOWN=300
MAX_RESTART_ATTEMPTS=3
CFG_EOF
    # 替换模板中的变量
    source "$TUNNEL_DIR/tunnel.env"
    sed -i "s/\${LOCAL_PORT}/$PORT/g" "$CONFIG_FILE"
}

[[ -f "$CONFIG_FILE" ]] || default_config

load_config() {
    sed -i 's/\r$//' "$CONFIG_FILE"
    source "$CONFIG_FILE" 2>/dev/null || true
    CHECK_METHOD="${CHECK_METHOD:-http}"
    HTTP_CHECK_URL="${HTTP_CHECK_URL:-http://127.0.0.1:8080}"
    CHECK_PORT="${CHECK_PORT:-8080}"
    CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
    FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
    TIMEOUT="${TIMEOUT:-3}"
    RESTART_DELAY="${RESTART_DELAY:-5}"
    RESTART_CHECK_DELAY="${RESTART_CHECK_DELAY:-20}"
    FIRST_BACKOFF="${FIRST_BACKOFF:-1800}"
    SECOND_BACKOFF="${SECOND_BACKOFF:-21600}"
    RECOVERY_COOLDOWN="${RECOVERY_COOLDOWN:-300}"
    MAX_RESTART_ATTEMPTS="${MAX_RESTART_ATTEMPTS:-3}"
}

save_config() {
    cat > "$CONFIG_FILE" <<CFG_EOF2
CHECK_METHOD="${CHECK_METHOD}"
HTTP_CHECK_URL="${HTTP_CHECK_URL}"
CHECK_PORT=${CHECK_PORT}
CHECK_INTERVAL=${CHECK_INTERVAL}
FAIL_THRESHOLD=${FAIL_THRESHOLD}
TIMEOUT=${TIMEOUT}
RESTART_DELAY=${RESTART_DELAY}
RESTART_CHECK_DELAY=${RESTART_CHECK_DELAY}
FIRST_BACKOFF=${FIRST_BACKOFF}
SECOND_BACKOFF=${SECOND_BACKOFF}
RECOVERY_COOLDOWN=${RECOVERY_COOLDOWN}
MAX_RESTART_ATTEMPTS=${MAX_RESTART_ATTEMPTS}
CFG_EOF2
}

# ---------- 状态持久化 ----------
FAIL_COUNT=0; BACKOFF_STAGE=0; LAST_RECOVER=0; BACKOFF_START_TIME=0; BACKOFF_DELAY=0; CONSECUTIVE_FAILURES=0

load_state() { [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" 2>/dev/null || true; }
save_state() {
    cat > "$STATE_FILE" <<STATE_EOF
FAIL_COUNT=${FAIL_COUNT}
BACKOFF_STAGE=${BACKOFF_STAGE}
LAST_RECOVER=${LAST_RECOVER}
BACKOFF_START_TIME=${BACKOFF_START_TIME}
BACKOFF_DELAY=${BACKOFF_DELAY}
CONSECUTIVE_FAILURES=${CONSECUTIVE_FAILURES}
STATE_EOF
}

load_config
load_state

# ---------- 日志轮转 ----------
log() {
    if [[ -f "$LOG_FILE" ]]; then
        local fsize=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ "$fsize" -ge "$LOG_MAX_SIZE" ]]; then
            for ((i=LOG_BACKUPS; i>=1; i--)); do
                mv -f "${LOG_FILE}.$((i-1))" "${LOG_FILE}.${i}" 2>/dev/null
            done
            mv -f "$LOG_FILE" "${LOG_FILE}.1"
            touch "$LOG_FILE"
        fi
    fi
    local msg="[$(date '+%F %T')] $*"
    echo "$msg" >> "$LOG_FILE"
}

# ---------- 健康检查 ----------
check_health() {
    if [[ "$CHECK_METHOD" == "port" ]]; then
        timeout "${TIMEOUT}" bash -c "</dev/tcp/127.0.0.1/${CHECK_PORT}" 2>/dev/null
    elif [[ "$CHECK_METHOD" == "http" ]]; then
        local code
        code=$(curl -o /dev/null -s -w "%{http_code}" --max-time "${TIMEOUT}" "$HTTP_CHECK_URL" 2>/dev/null || echo "000")
        [[ "$code" =~ ^(200|301|302|404|502)$ ]]
    else
        return 1
    fi
}

# ---------- 隧道重建 ----------
rebuild_tunnel() {
    log "重建临时隧道..."
    source "$TUNNEL_DIR/tunnel.env"
    local port="$PORT"
    local cfd_bin="$CFD_BIN"

    # 停止旧进程
    if [[ -f "$TUNNEL_DIR/tunnel.pid" ]]; then
        kill $(cat "$TUNNEL_DIR/tunnel.pid") 2>/dev/null || true
        rm -f "$TUNNEL_DIR/tunnel.pid"
    fi
    pkill -f "cloudflared tunnel --url http://localhost:$port" 2>/dev/null || true

    local max_retries=5
    local retry_delay=15
    local attempt=1
    local temp_log="$TUNNEL_DIR/rebuild_temp.log"

    while (( attempt <= max_retries )); do
        rm -f "$temp_log"
        nohup "$cfd_bin" tunnel --url "http://localhost:$port" --no-autoupdate --config /dev/null \
            > "$temp_log" 2>&1 &
        local pid=$!
        echo "$pid" > "$TUNNEL_DIR/tunnel.pid"
        sleep 3

        if ! kill -0 "$pid" 2>/dev/null; then
            if grep -q "429 Too Many Requests" "$temp_log"; then
                log "429 限流，等待 ${retry_delay}s 重试"
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2))
                attempt=$((attempt + 1))
                continue
            else
                log "启动失败（非429）"
                return 1
            fi
        fi

        local url=""
        for i in {1..30}; do
            url=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$temp_log" | head -n1)
            [[ -n "$url" ]] && break
            sleep 0.5
        done

        if [[ -n "$url" ]]; then
            kill "$pid" 2>/dev/null || true
            local domain="${url#https://}"
            echo "$domain" > "$TUNNEL_DIR/SD_domain.txt"
            # 更新 env
            sed -i "/^URL=/d" "$TUNNEL_DIR/tunnel.env"
            echo "URL=$url" >> "$TUNNEL_DIR/tunnel.env"
            log "新域名: $url"
            return 0
        else
            kill "$pid" 2>/dev/null || true
            if grep -q "429 Too Many Requests" "$temp_log"; then
                log "域名未返回且429，等待"
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2))
                attempt=$((attempt + 1))
                continue
            else
                log "未提取到域名且非429"
                return 1
            fi
        fi
    done
    log "重建失败（重试耗尽）"
    return 1
}

# ---------- 退避 ----------
enter_backoff() {
    BACKOFF_DELAY=$(( BACKOFF_STAGE == 0 ? FIRST_BACKOFF : SECOND_BACKOFF ))
    BACKOFF_STAGE=$(( BACKOFF_STAGE == 0 ? 1 : 2 ))
    BACKOFF_START_TIME=$(date +%s)
    save_state
    log "进入退避 ${BACKOFF_DELAY}s (阶段 ${BACKOFF_STAGE})"
    local end=$(( BACKOFF_START_TIME + BACKOFF_DELAY ))
    while (( $(date +%s) < end )); do
        check_health && { log "退避期间恢复"; break; }
        local remain=$(( end - $(date +%s) ))
        sleep $(( remain > CHECK_INTERVAL ? CHECK_INTERVAL : remain ))
    done
    if check_health; then
        FAIL_COUNT=0; CONSECUTIVE_FAILURES=0; BACKOFF_STAGE=0; LAST_RECOVER=$(date +%s)
    else
        log "退避结束，尝试重建"
        if rebuild_tunnel; then
            FAIL_COUNT=0; CONSECUTIVE_FAILURES=0; BACKOFF_STAGE=0; LAST_RECOVER=$(date +%s)
        else
            CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
        fi
    fi
    save_state
}

# ---------- 守护进程主循环 ----------
watchdog_loop() {
    log "Watchdog 守护启动 (PID $$)"
    local next_check=$(date +%s)
    while true; do
        local now=$(date +%s)
        if (( now >= next_check )); then
            if (( now - LAST_RECOVER < RECOVERY_COOLDOWN )); then
                sleep 10
                next_check=$(( $(date +%s) + CHECK_INTERVAL ))
                continue
            fi

            if check_health; then
                FAIL_COUNT=0
                (( BACKOFF_STAGE > 0 )) && { BACKOFF_STAGE=0; CONSECUTIVE_FAILURES=0; LAST_RECOVER=$(date +%s); log "已恢复"; }
                save_state
            else
                FAIL_COUNT=$(( FAIL_COUNT + 1 ))
                log "检查失败 (${FAIL_COUNT}/${FAIL_THRESHOLD})"
                if (( FAIL_COUNT >= FAIL_THRESHOLD )); then
                    log "尝试重启服务"
                    sleep "$RESTART_DELAY"
                    # 仅重启 cloudflared 进程（通过kill旧进程后本 watchdog 会自动重建，但这里简单重启 systemd 服务如有）
                    if [[ -f "$TUNNEL_DIR/tunnel.pid" ]]; then
                        kill $(cat "$TUNNEL_DIR/tunnel.pid") 2>/dev/null || true
                    fi
                    sleep "$RESTART_CHECK_DELAY"
                    if check_health; then
                        log "重启后恢复"
                        FAIL_COUNT=0; LAST_RECOVER=$(date +%s)
                    else
                        log "重启后仍失败"
                        CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
                        if (( CONSECUTIVE_FAILURES >= MAX_RESTART_ATTEMPTS )); then
                            enter_backoff
                        fi
                    fi
                    save_state
                fi
            fi
            next_check=$(( $(date +%s) + CHECK_INTERVAL ))
        fi
        local sleep_time=$(( next_check - $(date +%s) ))
        (( sleep_time > 0 )) && sleep "$sleep_time"
    done
}

# ---------- 进程管理 ----------
is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if [[ -n "$pid" && -d "/proc/$pid" ]]; then
            return 0
        else
            rm -f "$PID_FILE" "$LOCK_FILE"
        fi
    fi
    return 1
}

start_watchdog() {
    if is_running; then
        echo "watchdog 已在运行" >&2
        return 1
    fi
    load_config
    nohup bash "$0" run --tunnel-dir "$TUNNEL_DIR" >> "$LOG_FILE" 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$PID_FILE"
    echo "watchdog 启动成功 (PID $new_pid)"
}

stop_watchdog() {
    if ! is_running; then
        echo "watchdog 未运行"
        return
    fi
    local pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null || true
    for i in {1..6}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.5
    done
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE" "$LOCK_FILE"
    echo "watchdog 已停止"
}

# ---------- 入口分发 ----------
case "${1:-}" in
    run)
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            echo "[$(date)] watchdog 已在运行" >> "$LOG_FILE"
            exit 0
        fi
        trap 'rm -f "$PID_FILE" "$LOCK_FILE"' EXIT
        watchdog_loop
        ;;
    start)   start_watchdog ;;
    stop)    stop_watchdog ;;
    restart) stop_watchdog; start_watchdog ;;
    status)  if is_running; then echo "运行中"; else echo "未运行"; fi ;;
    log)     tail -n 50 "$LOG_FILE" ;;
    config)  echo "当前配置："; cat "$CONFIG_FILE" ;;
    reset)   echo "重置失败计数器"; FAIL_COUNT=0; CONSECUTIVE_FAILURES=0; save_state ;;
    *)       echo "用法: $0 {start|stop|restart|status|log|config|reset} --tunnel-dir <目录>" ;;
esac
WATCHDOG_CORE_EOF
    chmod +x "$WATCHDOG_CORE"
}

# =========================================================
#  原有隧道操作函数（已适配 watchdog）
# =========================================================

# 列出所有隧道（含 Watchdog 状态）
list_tunnels() {
    print_title "临时隧道列表（自动保活）"
    echo -e "${CYAN}编号 | 本地端口 | 域名 | 隧道状态 | Watchdog 状态${RESET}" >&2
    echo "--------------------------------------------------------------------------------" >&2
    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local num=$(basename "$dir")
        local env_file="$dir/tunnel.env"
        if [[ -f "$env_file" ]]; then
            source "$env_file"
            local port="${PORT:-?}"
            local url="${URL:-未获取}"

            # 隧道进程状态
            local tunnel_pid_file="$dir/tunnel.pid"
            local tunnel_status="${RED}离线${RESET}"
            if [[ -f "$tunnel_pid_file" ]] && kill -0 $(cat "$tunnel_pid_file") 2>/dev/null; then
                tunnel_status="${GREEN}在线${RESET}"
            fi

            # Watchdog 状态
            local wd_pid_file="/var/run/argo-watchdog-${num}.pid"
            local wd_status="${RED}未运行${RESET}"
            if [[ -f "$wd_pid_file" ]] && kill -0 $(cat "$wd_pid_file") 2>/dev/null; then
                wd_status="${GREEN}运行中${RESET}"
            fi

            echo -e "${GREEN}$num${RESET}) 端口: ${YELLOW}$port${RESET} | 域名: ${MAGENTA}$url${RESET} | 隧道: $tunnel_status | Watchdog: $wd_status" >&2
        fi
    done
    echo "--------------------------------------------------------------------------------" >&2
}

# 停止隧道（内部，不输出菜单）
stop_tunnel_internal() {
    local tunnel_dir="$1"
    local num=$(basename "$tunnel_dir")
    # 先停 Watchdog
    "$WATCHDOG_CORE" stop --tunnel-dir "$tunnel_dir" >/dev/null 2>&1 || true
    # 再停隧道进程
    if [[ -f "$tunnel_dir/tunnel.pid" ]]; then
        kill $(cat "$tunnel_dir/tunnel.pid") 2>/dev/null || true
        rm -f "$tunnel_dir/tunnel.pid"
    fi
    # 精确清理残留
    source "$tunnel_dir/tunnel.env" 2>/dev/null
    if [[ -n "${PORT:-}" ]]; then
        pkill -f "cloudflared tunnel --url http://localhost:$PORT" 2>/dev/null || true
    fi
}

# 新增隧道
add_tunnel() {
    install_cloudflared
    generate_watchdog_core
    print_title "新增临时隧道"
    local default_port="8080"
    printf "本地端口（默认 %s）: " "$default_port" >&2
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

    # 写入基本配置
    cat > "$tunnel_dir/tunnel.env" <<EOF
ID=$id
PORT=$port
URL=
EOF

    # 启动隧道（含 429 重试，并写入域名）
    print_info "启动临时隧道..."
    local max_retries=5
    local retry_delay=15
    local success=0
    local log_file="$tunnel_dir/cloudflared.log"
    for ((attempt=1; attempt<=max_retries; attempt++)); do
        rm -f "$log_file" "$tunnel_dir/tunnel.pid"
        nohup "$BIN" tunnel --url "http://localhost:$port" --no-autoupdate --config /dev/null \
            > "$log_file" 2>&1 &
        local pid=$!
        echo "$pid" > "$tunnel_dir/tunnel.pid"
        sleep 3

        if ! kill -0 "$pid" 2>/dev/null; then
            if grep -q "429 Too Many Requests" "$log_file"; then
                print_warn "429 限流，等待 ${retry_delay}s..."
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2))
                continue
            else
                print_error "隧道启动失败"
                return 1
            fi
        fi

        local url=""
        for i in {1..30}; do
            url=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$log_file" | head -n1)
            [[ -n "$url" ]] && break
            sleep 0.5
        done

        if [[ -n "$url" ]]; then
            kill "$pid" 2>/dev/null || true
            echo "$url" > "$tunnel_dir/SD_domain.txt"
            sed -i "/^URL=/d" "$tunnel_dir/tunnel.env"
            echo "URL=$url" >> "$tunnel_dir/tunnel.env"
            success=1
            break
        else
            kill "$pid" 2>/dev/null || true
            if grep -q "429 Too Many Requests" "$log_file"; then
                print_warn "未获取域名且429..."
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2))
                continue
            else
                print_error "未提取到域名"
                return 1
            fi
        fi
    done

    if [[ $success -eq 0 ]]; then
        print_error "隧道创建失败（重试耗尽）"
        rm -rf "$tunnel_dir"
        return 1
    fi

    # 自动启动 Watchdog
    "$WATCHDOG_CORE" start --tunnel-dir "$tunnel_dir" >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        print_ok "Watchdog 已自动启动"
    else
        print_warn "Watchdog 启动失败，请手动检查"
    fi

    source "$tunnel_dir/tunnel.env"
    print_ok "临时隧道创建成功"
    echo -e "编号: ${GREEN}$id2${RESET}"
    echo -e "端口: ${YELLOW}$port${RESET}"
    echo -e "域名: ${CYAN}${URL}${RESET}"
}

# 查看日志
view_logs() {
    list_tunnels
    printf "输入隧道编号: " >&2
    read num
    num=$(normalize_id "$num")
    local dir="$TUNNELS_DIR/$num"
    if [[ ! -d "$dir" ]]; then
        print_error "隧道不存在"
        return
    fi
    local log="$dir/cloudflared.log"
    if [[ -f "$log" ]]; then
        tail -n 50 "$log"
    else
        print_error "日志文件不存在"
    fi
}

# 停止隧道
stop_tunnel() {
    list_tunnels
    printf "输入要停止的隧道编号: " >&2
    read num
    num=$(normalize_id "$num")
    local dir="$TUNNELS_DIR/$num"
    if [[ ! -d "$dir" ]]; then
        print_error "隧道不存在"
        return
    fi
    stop_tunnel_internal "$dir"
    print_ok "已停止临时隧道 $num"
}

# 启动（重建）隧道
start_tunnel() {
    list_tunnels
    printf "输入要启动的隧道编号: " >&2
    read num
    num=$(normalize_id "$num")
    local dir="$TUNNELS_DIR/$num"
    if [[ ! -d "$dir" ]]; then
        print_error "隧道不存在"
        return
    fi
    source "$dir/tunnel.env"
    local port="${PORT:-}"
    if [[ -z "$port" ]]; then
        print_error "配置异常，请删除重建"
        return
    fi
    print_warn "重新创建将生成新域名，确认？(y/N)"
    read ans
    ans=$(clean_input "$ans")
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        return
    fi
    stop_tunnel_internal "$dir"   # 停旧进程和 watchdog
    # 重新启动隧道
    local max_retries=5
    local retry_delay=15
    local success=0
    local log="$dir/cloudflared.log"
    for ((attempt=1; attempt<=max_retries; attempt++)); do
        rm -f "$log" "$dir/tunnel.pid"
        nohup "$BIN" tunnel --url "http://localhost:$port" --no-autoupdate --config /dev/null \
            > "$log" 2>&1 &
        local pid=$!
        echo "$pid" > "$dir/tunnel.pid"
        sleep 3
        # 检查进程存活和域名提取（省略详细，与 add_tunnel 类似）
        local url=""
        for i in {1..30}; do
            url=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$log" | head -n1)
            [[ -n "$url" ]] && break
            sleep 0.5
        done
        if [[ -n "$url" ]]; then
            kill "$pid" 2>/dev/null || true
            echo "$url" > "$dir/SD_domain.txt"
            sed -i "/^URL=/d" "$dir/tunnel.env"
            echo "URL=$url" >> "$dir/tunnel.env"
            success=1
            break
        fi
        kill "$pid" 2>/dev/null || true
        if grep -q "429 Too Many Requests" "$log"; then
            print_warn "429 限流，等待..."
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))
        else
            print_error "启动失败"
            return 1
        fi
    done
    if [[ $success -eq 1 ]]; then
        # 重新启动 Watchdog
        "$WATCHDOG_CORE" start --tunnel-dir "$dir" >/dev/null 2>&1
        source "$dir/tunnel.env"
        print_ok "隧道已重建，新域名: ${URL}"
    else
        print_error "重建失败"
    fi
}

# 删除单个隧道
delete_tunnel() {
    list_tunnels
    printf "输入要删除的隧道编号: " >&2
    read num
    num=$(normalize_id "$num")
    local dir="$TUNNELS_DIR/$num"
    if [[ ! -d "$dir" ]]; then
        print_error "隧道不存在"
        return
    fi
    stop_tunnel_internal "$dir"
    rm -rf "$dir"
    print_ok "已删除隧道 $num"
}

# 删除所有隧道
delete_all_tunnels() {
    print_title "删除所有临时隧道"
    read -p "确认删除所有隧道？(yes/no): " ans
    ans=$(clean_input "$ans")
    [[ "$ans" != "yes" ]] && { print_info "已取消"; return; }
    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        stop_tunnel_internal "$dir"
        rm -rf "$dir"
    done
    print_ok "已删除所有隧道"
}

# =========================================================
#  Watchdog 管理子菜单
# =========================================================
watchdog_menu() {
    generate_watchdog_core
    while true; do
        print_title "Watchdog 管理"
        list_tunnels
        echo ""
        echo " 1) 启动某个 Watchdog"
        echo " 2) 停止某个 Watchdog"
        echo " 3) 重启某个 Watchdog"
        echo " 4) 查看 Watchdog 日志"
        echo " 5) 查看 Watchdog 配置"
        echo " 6) 重置失败计数器"
        echo " 0) 返回主菜单"
        printf "请选择: " >&2
        read wd_choice
        case "$wd_choice" in
            1|2|3|4|5|6)
                printf "输入隧道编号: " >&2
                read num
                num=$(normalize_id "$num")
                local dir="$TUNNELS_DIR/$num"
                if [[ ! -d "$dir" ]]; then
                    print_error "隧道不存在"
                    continue
                fi
                case "$wd_choice" in
                    1) "$WATCHDOG_CORE" start --tunnel-dir "$dir" ;;
                    2) "$WATCHDOG_CORE" stop --tunnel-dir "$dir" ;;
                    3) "$WATCHDOG_CORE" restart --tunnel-dir "$dir" ;;
                    4) "$WATCHDOG_CORE" log --tunnel-dir "$dir" ;;
                    5) "$WATCHDOG_CORE" config --tunnel-dir "$dir" ;;
                    6) "$WATCHDOG_CORE" reset --tunnel-dir "$dir" ;;
                esac
                printf "按回车继续..." >&2; read ;;
            0) break ;;
            *) print_error "无效选项"; sleep 1 ;;
        esac
    done
}

# =========================================================
#  彻底清理
# =========================================================
purge_everything() {
    print_title "⚠ 彻底删除脚本及所有文件 ⚠"
    echo -e "${RED}将停止所有隧道/ Watchdog 并删除工作目录${RESET}"
    read -p "确认请输入 yes: " ans
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
    rm -rf "$BASE_DIR"
    SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
    rm -f "$SCRIPT_PATH"
    echo -e "${GREEN}彻底清理完成！${RESET}"
    exit 0
}

# =========================================================
#  主菜单
# =========================================================
main_menu() {
    generate_watchdog_core
    while true; do
        print_title "临时隧道管理器 (多开 + Watchdog)"
        echo "1) 查看隧道列表"
        echo "2) 新增临时隧道"
        echo "3) 停止某个隧道"
        echo "4) 启动（重建）某个隧道"
        echo "5) 查看隧道日志"
        echo "6) 删除某个隧道"
        echo "7) 删除所有隧道"
        echo "8) Watchdog 管理"
        echo "9) 彻底删除脚本及所有文件"
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
            8) watchdog_menu ;;
            9) purge_everything ;;
            0) exit 0 ;;
            *) print_error "无效选项"; printf "按回车继续..." >&2; read ;;
        esac
    done
}

# 入口
main_menu
