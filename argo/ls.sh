#!/usr/bin/env bash
set -uo pipefail

# =========================================================
#  Argo 临时隧道无交互部署脚本 (内置三层恢复 Watchdog)
#  用法: bash deploy_tunnel.sh [端口]
#  默认端口: 8080 (优先读取 catmi.env 中的 lsargo_port)
# =========================================================

# ---------- 路径定义 ----------
BASE_DIR="/root/catmi/argo_temp"
BIN="$BASE_DIR/cloudflared"
TEMP_LOG="$BASE_DIR/temp.log"
SD_FILE="$BASE_DIR/SD_domain.txt"
WATCHDOG_PID_FILE="$BASE_DIR/watchdog.pid"
WATCHDOG_LOG="$BASE_DIR/watchdog.log"
WATCHDOG_STATE="$BASE_DIR/watchdog.state"
LOCK_FILE="/var/run/argo-temp-watchdog.lock"

DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

mkdir -p "$BASE_DIR"

# ---------- 工具函数 ----------
log() {
    echo "[$(date '+%F %T')] $1" | tee -a "$BASE_DIR/deploy.log"
}

update_env() {
    local env_file="$1" key="$2" value="$3"
    [[ -n "$env_file" && -n "$key" ]] || return 1
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1

    mkdir -p "$(dirname "$env_file")"
    [[ -f "$env_file" ]] || touch "$env_file"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\$}"

    local tmp_file
    tmp_file=$(mktemp "$(dirname "$env_file")/.env.tmp.XXXXXX")
    awk -v k="$key" 'index($0, k"=") != 1' "$env_file" > "$tmp_file"
    printf '%s="%s"\n' "$key" "$value" >> "$tmp_file"
    mv "$tmp_file" "$env_file"
}

# ---------- 读取本地端口 ----------
LOCAL_PORT=8080
if [[ -f "$CATMIENV_FILE" ]]; then
    # 简单读取端口（避免引入复杂的 load_env 依赖）
    port_line=$(grep -E '^lsargo_port=' "$CATMIENV_FILE" 2>/dev/null | tail -n1)
    if [[ -n "$port_line" ]]; then
        LOCAL_PORT=$(echo "$port_line" | sed -E 's/^lsargo_port="?([0-9]+)"?/\1/')
    fi
fi
# 允许命令行传入端口
if [[ -n "${1:-}" ]]; then
    if [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); then
        LOCAL_PORT="$1"
    else
        echo "错误：端口无效，必须为1-65535的数字" >&2
        exit 1
    fi
fi
log "使用本地端口: $LOCAL_PORT"

# ---------- 安装 cloudflared ----------
install_cloudflared() {
    if [[ -x "$BIN" ]] && "$BIN" --version >/dev/null 2>&1; then
        return 0
    fi
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)     CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        aarch64)    CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
        armv7l|armhf) CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
        *) echo "不支持的架构: $arch"; exit 1 ;;
    esac
    log "下载 cloudflared ..."
    wget -qO "$BIN" "$CFD_URL" || { log "下载失败"; exit 1; }
    chmod +x "$BIN"
}

install_cloudflared

# ---------- 启动隧道（带429重试，返回0并将域名写入文件）----------
start_tunnel_with_retry() {
    local port="$1"
    local max_retries=5
    local retry_delay=15
    local attempt=1
    local tmp_log="$BASE_DIR/start_temp.log"

    while (( attempt <= max_retries )); do
        log "启动隧道尝试 $attempt/$max_retries (端口 $port)"
        rm -f "$tmp_log"
        nohup "$BIN" tunnel --url "http://localhost:$port" --no-autoupdate --config /dev/null \
            > "$tmp_log" 2>&1 &
        local pid=$!
        sleep 3

        if ! kill -0 "$pid" 2>/dev/null; then
            if grep -q "429 Too Many Requests" "$tmp_log" 2>/dev/null; then
                log "触发 429 限流，等待 ${retry_delay}s"
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2))
                attempt=$((attempt + 1))
                continue
            else
                log "启动失败（非429），错误日志："
                tail -n 20 "$tmp_log" | tee -a "$BASE_DIR/deploy.log"
                return 1
            fi
        fi

        # 提取域名
        local url=""
        for i in {1..30}; do
            url=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$tmp_log" | head -n1)
            [[ -n "$url" ]] && break
            sleep 0.5
        done

        if [[ -n "$url" ]]; then
            kill "$pid" 2>/dev/null || true
            # 保存域名到文件和环境变量
            local domain="${url#https://}"
            echo "$domain" > "$SD_FILE"
            update_env "$CATMIENV_FILE" SD_domain "$domain"
            log "临时隧道创建成功: $url"
            return 0
        else
            kill "$pid" 2>/dev/null || true
            if grep -q "429 Too Many Requests" "$tmp_log" 2>/dev/null; then
                log "域名未返回且429，等待 ${retry_delay}s"
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2))
                attempt=$((attempt + 1))
                continue
            else
                log "启动后未提取到域名，日志："
                tail -n 20 "$tmp_log" | tee -a "$BASE_DIR/deploy.log"
                return 1
            fi
        fi
    done

    log "重试耗尽，隧道启动失败"
    return 1
}

# ---------- 生成三层恢复 Watchdog 守护进程函数 ----------
generate_watchdog_script() {
    cat > "$BASE_DIR/watchdog_daemon.sh" <<'DAEMON_EOF'
#!/usr/bin/env bash
set -uo pipefail

# 三层恢复 Watchdog 守护进程 (无交互)
BASE_DIR="/root/catmi/argo_temp"
BIN="$BASE_DIR/cloudflared"
TEMP_LOG="$BASE_DIR/temp.log"
SD_FILE="$BASE_DIR/SD_domain.txt"
CATMIENV_FILE="/root/catmi/catmi.env"

STATE_FILE="$BASE_DIR/watchdog.state"
LOCK_FILE="/var/run/argo-temp-watchdog.lock"
PID_FILE="$BASE_DIR/watchdog.pid"
LOG_FILE="$BASE_DIR/watchdog.log"

# 配置 (可通过配置文件覆盖)
CHECK_INTERVAL=30
FAIL_THRESHOLD=3
TIMEOUT=5
RESTART_DELAY=5
RESTART_CHECK_DELAY=20
FIRST_BACKOFF=1800
SECOND_BACKOFF=21600
RECOVERY_COOLDOWN=300
MAX_RESTART_ATTEMPTS=3
LOCAL_PORT=8080

# 加载端口
if [[ -f "$CATMIENV_FILE" ]]; then
    port_line=$(grep -E '^lsargo_port=' "$CATMIENV_FILE" 2>/dev/null | tail -n1)
    if [[ -n "$port_line" ]]; then
        LOCAL_PORT=$(echo "$port_line" | sed -E 's/^lsargo_port="?([0-9]+)"?/\1/')
    fi
fi

# 状态变量
FAIL_COUNT=0
BACKOFF_STAGE=0
LAST_RECOVER=0
BACKOFF_START_TIME=0
BACKOFF_DELAY=0
CONSECUTIVE_FAILURES=0

# 加载持久化状态
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE" 2>/dev/null || true

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

log() {
    echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
}

# 健康检查
check_health() {
    local domain
    domain=$(cat "$SD_FILE" 2>/dev/null || true)
    if [[ -z "$domain" ]]; then
        return 1
    fi
    local code
    code=$(curl -o /dev/null -s -w "%{http_code}" --max-time "$TIMEOUT" "https://$domain" 2>/dev/null || echo "000")
    [[ "$code" =~ ^(200|301|302|404|502)$ ]]
}

# 停止隧道进程
stop_tunnel() {
    if [[ -f "$BASE_DIR/tunnel.pid" ]]; then
        kill $(cat "$BASE_DIR/tunnel.pid") 2>/dev/null || true
        rm -f "$BASE_DIR/tunnel.pid"
    fi
    pkill -f "cloudflared tunnel --url http://localhost:$LOCAL_PORT" 2>/dev/null || true
    sleep 1
}

# 启动隧道并记录PID
start_tunnel() {
    nohup "$BIN" tunnel --url "http://localhost:$LOCAL_PORT" --no-autoupdate --config /dev/null \
        > "$TEMP_LOG" 2>&1 &
    echo $! > "$BASE_DIR/tunnel.pid"
}

# 重建隧道（获取新域名）
rebuild_tunnel() {
    log "重建隧道..."
    stop_tunnel
    rm -f "$TEMP_LOG"
    local max_retries=5 retry_delay=15
    for ((attempt=1; attempt<=max_retries; attempt++)); do
        start_tunnel
        sleep 3
        local url=""
        for i in {1..30}; do
            url=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TEMP_LOG" | head -n1)
            [[ -n "$url" ]] && break
            sleep 0.5
        done
        if [[ -n "$url" ]]; then
            local domain="${url#https://}"
            echo "$domain" > "$SD_FILE"
            # 更新 catmi.env
            local tmp_file=$(mktemp)
            awk -v k="SD_domain" 'index($0, k"=") != 1' "$CATMIENV_FILE" > "$tmp_file"
            printf '%s="%s"\n' "SD_domain" "$domain" >> "$tmp_file"
            mv "$tmp_file" "$CATMIENV_FILE"
            log "新域名: $url"
            return 0
        else
            stop_tunnel
            if grep -q "429 Too Many Requests" "$TEMP_LOG" 2>/dev/null; then
                log "429限流，等待 ${retry_delay}s"
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2))
            else
                log "未获取域名且非429"
                return 1
            fi
        fi
    done
    log "重建失败（重试耗尽）"
    return 1
}

# 退避阶段
enter_backoff() {
    BACKOFF_DELAY=$(( BACKOFF_STAGE == 0 ? FIRST_BACKOFF : SECOND_BACKOFF ))
    BACKOFF_STAGE=$(( BACKOFF_STAGE == 0 ? 1 : 2 ))
    BACKOFF_START_TIME=$(date +%s)
    save_state
    log "进入退避 ${BACKOFF_DELAY}s (阶段${BACKOFF_STAGE})"
    local end=$(( BACKOFF_START_TIME + BACKOFF_DELAY ))
    while (( $(date +%s) < end )); do
        if check_health; then
            log "退避期间恢复"
            break
        fi
        sleep $(( CHECK_INTERVAL < (end - $(date +%s)) ? CHECK_INTERVAL : (end - $(date +%s)) ))
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

# ---------- 主循环 ----------
main_loop() {
    log "Watchdog 启动 (PID $$)"
    local next_check=$(date +%s)
    while true; do
        local now=$(date +%s)
        if (( now >= next_check )); then
            # 冷却检查
            if (( now - LAST_RECOVER < RECOVERY_COOLDOWN )); then
                sleep 10
                next_check=$(( $(date +%s) + CHECK_INTERVAL ))
                continue
            fi

            if check_health; then
                FAIL_COUNT=0
                (( BACKOFF_STAGE > 0 )) && { BACKOFF_STAGE=0; CONSECUTIVE_FAILURES=0; LAST_RECOVER=$(date +%s); log "恢复健康"; }
                save_state
            else
                FAIL_COUNT=$(( FAIL_COUNT + 1 ))
                log "检查失败 (${FAIL_COUNT}/${FAIL_THRESHOLD})"
                if (( FAIL_COUNT >= FAIL_THRESHOLD )); then
                    log "尝试重启隧道进程"
                    stop_tunnel
                    sleep "$RESTART_DELAY"
                    start_tunnel
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

# 防重入启动
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date)] watchdog 已在运行" >> "$LOG_FILE"
    exit 0
fi
trap 'rm -f "$PID_FILE" "$LOCK_FILE"' EXIT
echo $$ > "$PID_FILE"
main_loop
DAEMON_EOF
    chmod +x "$BASE_DIR/watchdog_daemon.sh"
}

# ---------- 停止旧的 systemd 服务及旧 watchdog ----------
cleanup_old() {
    # 禁用并停止可能存在的 systemd 服务
    systemctl stop argo-temp 2>/dev/null || true
    systemctl disable argo-temp 2>/dev/null || true

    # 停止旧的 watchdog 进程
    if [[ -f "$WATCHDOG_PID_FILE" ]]; then
        kill $(cat "$WATCHDOG_PID_FILE") 2>/dev/null || true
        rm -f "$WATCHDOG_PID_FILE"
    fi
    # 清理残留隧道进程（按端口）
    pkill -f "cloudflared tunnel --url http://localhost:$LOCAL_PORT" 2>/dev/null || true
    sleep 1
}

# ---------- 主流程 ----------
cleanup_old
install_cloudflared
generate_watchdog_script

# 启动隧道并获取域名
if ! start_tunnel_with_retry "$LOCAL_PORT"; then
    log "隧道启动失败，退出"
    exit 1
fi

# 启动后台 watchdog 守护进程
log "启动 Watchdog 守护进程..."
nohup "$BASE_DIR/watchdog_daemon.sh" >> "$WATCHDOG_LOG" 2>&1 &
WATCHDOG_PID=$!
echo "$WATCHDOG_PID" > "$WATCHDOG_PID_FILE"

# 验证域名
DOMAIN=$(cat "$SD_FILE" 2>/dev/null || echo "")
if [[ -n "$DOMAIN" ]]; then
    log "部署完成，域名: https://$DOMAIN"
else
    log "警告：未能读取到域名"
fi

echo "临时隧道部署完成！"
echo "端口: $LOCAL_PORT"
echo "域名: https://$DOMAIN"
echo "Watchdog PID: $WATCHDOG_PID"
