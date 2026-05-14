#!/usr/bin/env bash
set -uo pipefail

BASE_DIR="/root/catmi/watchdog"
mkdir -p "$BASE_DIR"

SCRIPT_PATH="$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")"

CONFIG_FILE="${BASE_DIR}/watchdog.conf"
STATE_FILE="${BASE_DIR}/watchdog.state"
LOG_FILE="${BASE_DIR}/watchdog.log"
LOCK_FILE="/var/run/cfd-watchdog.lock"

# ---------- 默认配置 ----------
default_config() {
    cat > "$CONFIG_FILE" <<'EOF'
CHECK_HOST="127.0.0.1"
CHECK_INTERVAL=30
FAIL_THRESHOLD=3
TCP_TIMEOUT=3
CFD_RESTART_DELAY=15
ARGO_RESTART_DELAY=10
RESTART_CHECK_DELAY=20
FIRST_BACKOFF=1800
SECOND_BACKOFF=21600
RECOVERY_COOLDOWN=300
CFD_SERVICE="catmi-cfd.service"
ARGO_SERVICE="argo-file.service"
MAX_RESTART_ATTEMPTS=5
EOF
}
[[ -f "$CONFIG_FILE" ]] || default_config

# 加载配置到全局变量
load_config() {
    sed -i 's/\r$//' "$CONFIG_FILE" 2>/dev/null || true
    source "$CONFIG_FILE" 2>/dev/null || true
    CHECK_HOST="${CHECK_HOST:-127.0.0.1}"
    CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
    FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
    TCP_TIMEOUT="${TCP_TIMEOUT:-3}"
    CFD_RESTART_DELAY="${CFD_RESTART_DELAY:-15}"
    ARGO_RESTART_DELAY="${ARGO_RESTART_DELAY:-10}"
    RESTART_CHECK_DELAY="${RESTART_CHECK_DELAY:-20}"
    FIRST_BACKOFF="${FIRST_BACKOFF:-1800}"
    SECOND_BACKOFF="${SECOND_BACKOFF:-21600}"
    RECOVERY_COOLDOWN="${RECOVERY_COOLDOWN:-300}"
    CFD_SERVICE="${CFD_SERVICE:-catmi-cfd.service}"
    ARGO_SERVICE="${ARGO_SERVICE:-argo-file.service}"
    MAX_RESTART_ATTEMPTS="${MAX_RESTART_ATTEMPTS:-5}"
}
load_config

# 保存当前变量到配置文件（完整重写）
save_config() {
    cat > "$CONFIG_FILE" <<EOF
CHECK_HOST="${CHECK_HOST}"
CHECK_INTERVAL=${CHECK_INTERVAL}
FAIL_THRESHOLD=${FAIL_THRESHOLD}
TCP_TIMEOUT=${TCP_TIMEOUT}
CFD_RESTART_DELAY=${CFD_RESTART_DELAY}
ARGO_RESTART_DELAY=${ARGO_RESTART_DELAY}
RESTART_CHECK_DELAY=${RESTART_CHECK_DELAY}
FIRST_BACKOFF=${FIRST_BACKOFF}
SECOND_BACKOFF=${SECOND_BACKOFF}
RECOVERY_COOLDOWN=${RECOVERY_COOLDOWN}
CFD_SERVICE="${CFD_SERVICE}"
ARGO_SERVICE="${ARGO_SERVICE}"
MAX_RESTART_ATTEMPTS=${MAX_RESTART_ATTEMPTS}
EOF
}

# ---------- 状态持久化 ----------
FAIL_COUNT=0; BACKOFF_STAGE=0; LAST_RECOVER=0; BACKOFF_START_TIME=0; BACKOFF_DELAY=0; CONSECUTIVE_FAILURES=0
load_state() { [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" 2>/dev/null || true; return 0; }
save_state() { cat > "$STATE_FILE" <<EOF
FAIL_COUNT=${FAIL_COUNT}
BACKOFF_STAGE=${BACKOFF_STAGE}
LAST_RECOVER=${LAST_RECOVER}
BACKOFF_START_TIME=${BACKOFF_START_TIME}
BACKOFF_DELAY=${BACKOFF_DELAY}
CONSECUTIVE_FAILURES=${CONSECUTIVE_FAILURES}
EOF
}
load_state

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

# ================= 检测 =================
check_port() { timeout "${TCP_TIMEOUT}" bash -c "</dev/tcp/${CHECK_HOST}/${1}" 2>/dev/null; }
get_gost_ports() { ss -lntp 2>/dev/null | grep gost | awk '{print $4}' | grep -Ev '^(127\.0\.0\.1|localhost|::1):' | awk -F: '{print $NF}' | sort -u; }
check_all_ports() {
    local ok=0 failed=""; local ports; ports=$(get_gost_ports)
    [[ -z "$ports" ]] && { log "NO GOST PORTS"; return 1; }
    for p in $ports; do check_port "$p" && ok=1 || failed="$failed $p"; done
    if [[ $ok -eq 1 ]]; then log "PORT CHECK OK"; return 0; else log "PORT FAIL ($failed)"; return 1; fi
}

restart_services() {
    log "RESTARTING OVERLAY"
    sleep "${CFD_RESTART_DELAY}"; systemctl restart "${CFD_SERVICE}" 2>/dev/null || log "WARN: ${CFD_SERVICE}"
    sleep "${ARGO_RESTART_DELAY}"; systemctl restart "${ARGO_SERVICE}" 2>/dev/null || log "WARN: ${ARGO_SERVICE}"
    LAST_RECOVER=$(date +%s)
}

enter_backoff() {
    BACKOFF_DELAY=$(( BACKOFF_STAGE == 0 ? FIRST_BACKOFF : SECOND_BACKOFF ))
    BACKOFF_STAGE=$(( BACKOFF_STAGE == 0 ? 1 : 2 ))
    BACKOFF_START_TIME=$(date +%s); save_state
    log "BACKOFF ${BACKOFF_DELAY}s (stage ${BACKOFF_STAGE})"
    local end=$(( BACKOFF_START_TIME + BACKOFF_DELAY ))
    while (( $(date +%s) < end )); do
        check_all_ports && { log "BACKOFF RECOVERED"; break; }
        sleep "$(( (end - $(date +%s)) < CHECK_INTERVAL ? (end - $(date +%s)) : CHECK_INTERVAL ))"
    done
    if check_all_ports; then
        FAIL_COUNT=0; BACKOFF_STAGE=0; CONSECUTIVE_FAILURES=0; LAST_RECOVER=$(date +%s)
    else
        CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
    fi
    save_state
}

watchdog_loop() {
    log "DAEMON STARTED"
    log "CONFIG: INTERVAL=${CHECK_INTERVAL}s THRESHOLD=${FAIL_THRESHOLD} CHECK_DELAY=${RESTART_CHECK_DELAY}s MAX_ATTEMPTS=${MAX_RESTART_ATTEMPTS}"
    while true; do
        now=$(date +%s)
        if (( now - LAST_RECOVER < RECOVERY_COOLDOWN )); then
            log "COOLDOWN $(( RECOVERY_COOLDOWN - (now - LAST_RECOVER) ))s"; sleep 10; continue
        fi
        if check_all_ports; then
            FAIL_COUNT=0; BACKOFF_STAGE=0; CONSECUTIVE_FAILURES=0; save_state
        else
            FAIL_COUNT=$(( FAIL_COUNT + 1 ))
            log "FAIL COUNT ${FAIL_COUNT}/${FAIL_THRESHOLD}"
            if (( FAIL_COUNT >= FAIL_THRESHOLD )); then
                if (( CONSECUTIVE_FAILURES >= MAX_RESTART_ATTEMPTS )); then
                    log "MAX ATTEMPTS, STOPPING"; sleep 600; continue
                fi
                restart_services; sleep "${RESTART_CHECK_DELAY}"
                if check_all_ports; then
                    log "RECOVER SUCCESS"; FAIL_COUNT=0; BACKOFF_STAGE=0; CONSECUTIVE_FAILURES=0; LAST_RECOVER=$(date +%s)
                else
                    log "RECOVER FAILED"; CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 )); enter_backoff
                fi
                save_state
            fi
        fi
        sleep "${CHECK_INTERVAL}"
    done
}

# ================= 管理器 =================
force_stop() { pkill -f "bash.*${0##*/} run" 2>/dev/null || true; sleep 0.5; rm -f /var/run/cfd-watchdog.pid "$LOCK_FILE"; }
is_running() { pgrep -f "bash.*${0##*/} run" &>/dev/null; }

get_next_restart_time() {
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" 2>/dev/null || true
    if [[ "${BACKOFF_STAGE:-0}" -gt 0 && "${BACKOFF_START_TIME:-0}" -gt 0 ]]; then
        local end=$(( BACKOFF_START_TIME + BACKOFF_DELAY ))
        (( end > $(date +%s) )) && { date -d "@$end" '+%F %T' 2>/dev/null || echo "约 $((end - $(date +%s))) 秒后"; return; }
    fi
    echo "无"
}

start_watchdog() {
    force_stop; load_config
    echo "🚀 启动 watchdog..."; nohup bash "$SCRIPT_PATH" run >> "$LOG_FILE" 2>&1 &
    sleep 0.5; is_running && echo "✅ 已启动" || echo "❌ 启动失败"
}

stop_watchdog() { force_stop; echo "✅ 已停止"; sleep 0.5; }
restart_watchdog() { stop_watchdog; start_watchdog; }

# ---------- 参数修改（修改即保存，直接改变量）----------
config_panel() {
    while true; do
        clear
        echo "=============================="
        echo "      参数修改"
        echo "=============================="
        echo " 1) 检查间隔         = ${CHECK_INTERVAL} 秒"
        echo " 2) 失败阈值         = ${FAIL_THRESHOLD} 次"
        echo " 3) 连接超时         = ${TCP_TIMEOUT} 秒"
        echo " 4) CFD 重启延迟     = ${CFD_RESTART_DELAY} 秒"
        echo " 5) ARGO 重启延迟    = ${ARGO_RESTART_DELAY} 秒"
        echo " 6) 重启后检测等待   = ${RESTART_CHECK_DELAY} 秒"
        echo " 7) 首次退避时间     = ${FIRST_BACKOFF} 秒"
        echo " 8) 二次退避时间     = ${SECOND_BACKOFF} 秒"
        echo " 9) 恢复冷却时间     = ${RECOVERY_COOLDOWN} 秒"
        echo "10) 最大重启尝试次数 = ${MAX_RESTART_ATTEMPTS}"
        echo "----------------------------------"
        echo "11) 应用参数并重启 watchdog"
        echo " 0) 返回主菜单"
        read -rp "请选择: " num
        case "$num" in
            1) read -rp "新值: " v; [[ -n "$v" ]] && { CHECK_INTERVAL="$v"; save_config; echo "已设为 ${CHECK_INTERVAL}"; }; sleep 0.5 ;;
            2) read -rp "新值: " v; [[ -n "$v" ]] && { FAIL_THRESHOLD="$v"; save_config; echo "已设为 ${FAIL_THRESHOLD}"; }; sleep 0.5 ;;
            3) read -rp "新值: " v; [[ -n "$v" ]] && { TCP_TIMEOUT="$v"; save_config; echo "已设为 ${TCP_TIMEOUT}"; }; sleep 0.5 ;;
            4) read -rp "新值: " v; [[ -n "$v" ]] && { CFD_RESTART_DELAY="$v"; save_config; echo "已设为 ${CFD_RESTART_DELAY}"; }; sleep 0.5 ;;
            5) read -rp "新值: " v; [[ -n "$v" ]] && { ARGO_RESTART_DELAY="$v"; save_config; echo "已设为 ${ARGO_RESTART_DELAY}"; }; sleep 0.5 ;;
            6) read -rp "新值: " v; [[ -n "$v" ]] && { RESTART_CHECK_DELAY="$v"; save_config; echo "已设为 ${RESTART_CHECK_DELAY}"; }; sleep 0.5 ;;
            7) read -rp "新值: " v; [[ -n "$v" ]] && { FIRST_BACKOFF="$v"; save_config; echo "已设为 ${FIRST_BACKOFF}"; }; sleep 0.5 ;;
            8) read -rp "新值: " v; [[ -n "$v" ]] && { SECOND_BACKOFF="$v"; save_config; echo "已设为 ${SECOND_BACKOFF}"; }; sleep 0.5 ;;
            9) read -rp "新值: " v; [[ -n "$v" ]] && { RECOVERY_COOLDOWN="$v"; save_config; echo "已设为 ${RECOVERY_COOLDOWN}"; }; sleep 0.5 ;;
            10) read -rp "新值: " v; [[ -n "$v" ]] && { MAX_RESTART_ATTEMPTS="$v"; save_config; echo "已设为 ${MAX_RESTART_ATTEMPTS}"; }; sleep 0.5 ;;
            11) restart_watchdog ;;
            0) break ;;
            *) echo "无效选项"; sleep 0.5 ;;
        esac
    done
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo "========================================="
        echo "     CFD Overlay Watchdog 管理器"
        echo "========================================="
        if is_running; then
            echo "状态：🟢 运行中"
            echo "下次自动重启时间：$(get_next_restart_time)"
            echo "连续重启失败次数：$(source "$STATE_FILE" 2>/dev/null; echo ${CONSECUTIVE_FAILURES:-0}) 次 (上限 ${MAX_RESTART_ATTEMPTS})"
        else
            echo "状态：🔴 未运行"
        fi
        echo
        echo " 1) 启动 watchdog"
        echo " 2) 停止 watchdog"
        echo " 3) 重启 watchdog"
        echo " 4) 查看实时日志"
        echo " 5) 查看最近 50 行日志"
        echo " 6) 修改参数"
        echo " 7) 安装为系统服务"
        echo " 8) 删除 watchdog"
        echo " 9) 清空连续失败次数"
        echo " 0) 退出"
        read -rp "请选择: " num
        case "$num" in
            1) start_watchdog ;;
            2) stop_watchdog ;;
            3) restart_watchdog ;;
            4) tail -f "$LOG_FILE" ;;
            5) tail -n 50 "$LOG_FILE"; read -rp "按回车返回..." ;;
            6) config_panel ;;
            7) install_systemd ;;
            8) delete_watchdog ;;
            9) sed -i 's/^CONSECUTIVE_FAILURES=.*/CONSECUTIVE_FAILURES=0/' "$STATE_FILE"; echo "已清空"; sleep 0.5 ;;
            0) exit 0 ;;
            *) echo "无效选项"; sleep 0.5 ;;
        esac
    done
}

# 安装服务（略，保持原样）
install_systemd() {
    cat > /etc/systemd/system/cfd-watchdog.service <<EOF
[Unit]
Description=CFD Overlay Watchdog
After=network.target
[Service]
Type=simple
ExecStart=$SCRIPT_PATH run
Restart=no
User=root
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable cfd-watchdog
    echo "✅ 已安装系统服务"; sleep 0.5
}

delete_watchdog() {
    stop_watchdog
    rm -rf "$BASE_DIR" /var/run/cfd-watchdog.pid "$LOCK_FILE" /etc/systemd/system/cfd-watchdog.service
    systemctl daemon-reload
    echo "✅ 已删除"; sleep 0.5
}

# 入口
if [[ "${1:-}" == "run" ]]; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || { echo "[$(date)] watchdog already running"; exit 0; }
    trap 'rm -f /var/run/cfd-watchdog.pid "$LOCK_FILE"' EXIT
    watchdog_loop
else
    main_menu
fi
