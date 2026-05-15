#!/usr/bin/env bash
set -uo pipefail

# =========================================================
# VPS 网络状态看门狗 (生产级稳定版 - 修复版)
# 修复：DNS 误判、REBOOT_DELAY、单调时钟、状态锁、网关可达性、智能恢复链
# =========================================================

BASE_DIR="/root/vps-watchdog"
mkdir -p "$BASE_DIR"

SCRIPT_PATH="$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")"

CONFIG_FILE="${BASE_DIR}/watchdog.conf"
STATE_FILE="${BASE_DIR}/watchdog.state"
LOG_FILE="${BASE_DIR}/watchdog.log"
LOCK_FILE="/var/run/vps-watchdog.lock"
PID_FILE="/var/run/vps-watchdog.pid"

LOG_MAX_SIZE=$((1 * 1024 * 1024))
LOG_BACKUPS=2

# ---------- 默认配置 ----------
default_config() {
    cat > "$CONFIG_FILE" <<'EOF'
CHECK_INTERVAL=30
FAIL_THRESHOLD=3
COOLDOWN_AFTER_RECOVER=300
COOLDOWN_AFTER_REBOOT=900
PING_TARGET="8.8.8.8"
CURL_TARGETS="https://cloudflare.com https://google.com"
CURL_TIMEOUT=5
WAIT_AFTER_PROXY=5
WAIT_AFTER_NETWORK=10
WAIT_AFTER_CONNTRACK=8
VERIFY_RETRIES=3
VERIFY_INTERVAL=2
MIN_INTERVAL_RESTART_PROXY=60
MIN_INTERVAL_RESTART_NETWORK=300
MIN_INTERVAL_CLEAN_CONNTRACK=120
PROXY_SERVICES="gost xray sing-box"
NETWORK_MANAGER="auto"
CONNTRACK_CRIT_PERCENT=95
CONNTRACK_WARN_PERCENT=80
MAX_CONSECUTIVE_FAILURES=5
REBOOT_DELAY=15
EOF
}
[[ -f "$CONFIG_FILE" ]] || default_config

# 加载配置
load_config() {
    sed -i 's/\r$//' "$CONFIG_FILE" 2>/dev/null || true
    source "$CONFIG_FILE" 2>/dev/null || true
    CHECK_INTERVAL=${CHECK_INTERVAL:-30}
    FAIL_THRESHOLD=${FAIL_THRESHOLD:-3}
    COOLDOWN_AFTER_RECOVER=${COOLDOWN_AFTER_RECOVER:-300}
    COOLDOWN_AFTER_REBOOT=${COOLDOWN_AFTER_REBOOT:-900}
    PING_TARGET=${PING_TARGET:-8.8.8.8}
    CURL_TARGETS=${CURL_TARGETS:-https://cloudflare.com https://google.com}
    CURL_TIMEOUT=${CURL_TIMEOUT:-5}
    WAIT_AFTER_PROXY=${WAIT_AFTER_PROXY:-5}
    WAIT_AFTER_NETWORK=${WAIT_AFTER_NETWORK:-10}
    WAIT_AFTER_CONNTRACK=${WAIT_AFTER_CONNTRACK:-8}
    VERIFY_RETRIES=${VERIFY_RETRIES:-3}
    VERIFY_INTERVAL=${VERIFY_INTERVAL:-2}
    MIN_INTERVAL_RESTART_PROXY=${MIN_INTERVAL_RESTART_PROXY:-60}
    MIN_INTERVAL_RESTART_NETWORK=${MIN_INTERVAL_RESTART_NETWORK:-300}
    MIN_INTERVAL_CLEAN_CONNTRACK=${MIN_INTERVAL_CLEAN_CONNTRACK:-120}
    PROXY_SERVICES=${PROXY_SERVICES:-gost xray sing-box}
    NETWORK_MANAGER=${NETWORK_MANAGER:-auto}
    CONNTRACK_CRIT_PERCENT=${CONNTRACK_CRIT_PERCENT:-95}
    CONNTRACK_WARN_PERCENT=${CONNTRACK_WARN_PERCENT:-80}
    MAX_CONSECUTIVE_FAILURES=${MAX_CONSECUTIVE_FAILURES:-5}
    REBOOT_DELAY=${REBOOT_DELAY:-15}
}
load_config

# 状态持久化变量
FAIL_COUNT=0
LAST_RECOVER_TIME=0
LAST_REBOOT_TIME=0
CONSECUTIVE_FAILURES=0
LAST_PROXY_RESTART=0
LAST_NETWORK_RESTART=0
LAST_CONNTRACK_CLEAN=0

# 带锁的状态读写
save_state() {
    (
        flock -x 200
        cat > "$STATE_FILE" <<EOF
FAIL_COUNT=${FAIL_COUNT}
LAST_RECOVER_TIME=${LAST_RECOVER_TIME}
LAST_REBOOT_TIME=${LAST_REBOOT_TIME}
CONSECUTIVE_FAILURES=${CONSECUTIVE_FAILURES}
LAST_PROXY_RESTART=${LAST_PROXY_RESTART}
LAST_NETWORK_RESTART=${LAST_NETWORK_RESTART}
LAST_CONNTRACK_CLEAN=${LAST_CONNTRACK_CLEAN}
EOF
    ) 200>"${STATE_FILE}.lock"
}

load_state() {
    (
        flock -s 200
        [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" 2>/dev/null || true
    ) 200>"${STATE_FILE}.lock"
}
load_state

# ---------- 日志（安全轮转）----------
rotate_log() {
    [[ ! -f "$LOG_FILE" ]] && return
    local size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    [[ $size -lt $LOG_MAX_SIZE ]] && return
    [[ -f "${LOG_FILE}.${LOG_BACKUPS}" ]] && rm -f "${LOG_FILE}.${LOG_BACKUPS}"
    for ((i=LOG_BACKUPS-1; i>=1; i--)); do
        [[ -f "${LOG_FILE}.$i" ]] && mv -f "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))"
    done
    mv -f "$LOG_FILE" "${LOG_FILE}.1"
    touch "$LOG_FILE"
}

log() {
    rotate_log
    local msg="[$(date '+%F %T')] $*"
    if [[ "${WATCHDOG_DAEMON:-0}" == "1" ]]; then
        echo "$msg" >> "$LOG_FILE"
    else
        echo "$msg" | tee -a "$LOG_FILE"
    fi
}

# ---------- 单调时钟（秒）----------
monotonic_sec() {
    awk '{print int($1)}' /proc/uptime 2>/dev/null || echo $(date +%s)
}

# ---------- 独立检测 ----------
# DNS 检测：如果目标是 IP 地址，直接返回成功；否则解析域名
check_dns() {
    local target="google.com"
    # 如果 PING_TARGET 是 IP，不需要 DNS，直接返回 0
    if [[ "$PING_TARGET" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    if command -v getent >/dev/null 2>&1; then
        getent ahosts "$target" 2>/dev/null | grep -q '^[0-9]\{1,3\}\.' && return 0
    fi
    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$target" 8.8.8.8 2>/dev/null | grep -q 'Address: [0-9]' && return 0
        nslookup "$target" 1.1.1.1 2>/dev/null | grep -q 'Address: [0-9]' && return 0
    fi
    ping -c 1 -W 2 "$PING_TARGET" >/dev/null 2>&1
}

check_ping() {
    ping -c 1 -W 2 "$PING_TARGET" >/dev/null 2>&1
}

check_curl() {
    for url in $CURL_TARGETS; do
        curl -4 --connect-timeout "$CURL_TIMEOUT" -m "$CURL_TIMEOUT" -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -qE '^[23]' && return 0
    done
    return 1
}

# 默认路由 + 网关可达性检测
check_default_route() {
    local route=$(ip -4 route show default 2>/dev/null | head -1)
    [[ -z "$route" ]] && return 1
    local dev=$(echo "$route" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    [[ -z "$dev" || ! -d "/sys/class/net/$dev" ]] && return 1
    local gateway=$(echo "$route" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
    if [[ -n "$gateway" ]]; then
        # 测试网关可达性（ARP 或 ping）
        arping -c 1 -W 1 -I "$dev" "$gateway" >/dev/null 2>&1 || ping -c 1 -W 1 "$gateway" >/dev/null 2>&1 || return 1
    fi
    return 0
}

check_conntrack() {
    [[ ! -f /proc/sys/net/netfilter/nf_conntrack_count ]] && return 0
    local cnt=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
    local max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 1)
    local pct=$((cnt * 100 / max))
    [[ $pct -ge $CONNTRACK_CRIT_PERCENT ]] && return 2
    [[ $pct -ge $CONNTRACK_WARN_PERCENT ]] && return 1
    return 0
}

REASON=""
run_checks() {
    local fail=""
    local ct=$(check_conntrack; echo $?)
    [[ $ct -eq 2 ]] && fail="conntrack_critical"
    [[ $ct -eq 1 ]] && log "WARN: conntrack usage high"

    if ! check_dns; then fail="dns_failure"
    elif ! check_ping; then fail="ping_failure"
    elif ! check_curl; then fail="curl_failure"
    elif ! check_default_route; then fail="default_route_missing"
    fi

    if [[ -n "$fail" ]]; then
        REASON="$fail"
        return 1
    fi
    return 0
}

# ---------- 恢复后验证（渐进等待）----------
verify_network_stable() {
    for ((i=1; i<=VERIFY_RETRIES; i++)); do
        sleep "$VERIFY_INTERVAL"
        if check_dns && check_ping && check_curl && check_default_route; then
            log "验证成功 (第${i}次)"
            return 0
        fi
        log "验证第${i}次失败"
    done
    return 1
}

# ---------- 分级恢复（带节流和智能分支）----------
# 一级：重启代理
recover_restart_proxy() {
    local now=$(monotonic_sec)
    (( now - LAST_PROXY_RESTART < MIN_INTERVAL_RESTART_PROXY )) && { log "代理重启节流"; return 1; }
    log "一级恢复：重启代理服务"
    sleep 2
    local fail=0
    for svc in $PROXY_SERVICES; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl restart "$svc" 2>/dev/null || fail=1
        else
            systemctl start "$svc" 2>/dev/null || fail=1
        fi
    done
    [[ $fail -eq 0 ]] && LAST_PROXY_RESTART=$now && save_state
    sleep "$WAIT_AFTER_PROXY"
    verify_network_stable && return 0
    return 1
}

# 二级：安全重启网络
safe_restart_network() {
    local m=$NETWORK_MANAGER
    [[ "$m" == "auto" ]] && {
        systemctl is-active systemd-networkd >/dev/null 2>&1 && m="systemd-networkd"
        systemctl is-active NetworkManager >/dev/null 2>&1 && m="NetworkManager"
        systemctl is-active networking >/dev/null 2>&1 && m="networking"
        [[ -z "$m" ]] && m="none"
    }
    case $m in
        systemd-networkd) systemctl restart systemd-networkd ;;
        NetworkManager) systemctl restart NetworkManager ;;
        networking)
            local iface=$(ip route show default | awk '{print $5}' | head -1)
            if [[ -n "$iface" ]] && command -v ifdown >/dev/null; then
                ifdown "$iface" 2>/dev/null; sleep 2; ifup "$iface" 2>/dev/null
            else
                systemctl restart networking 2>/dev/null
            fi ;;
        none) return 1 ;;
    esac
    return 0
}

recover_restart_network() {
    local now=$(monotonic_sec)
    (( now - LAST_NETWORK_RESTART < MIN_INTERVAL_RESTART_NETWORK )) && { log "网络重启节流"; return 1; }
    log "二级恢复：重启网络管理"
    sleep 2
    safe_restart_network
    LAST_NETWORK_RESTART=$now; save_state
    sleep "$WAIT_AFTER_NETWORK"
    verify_network_stable && return 0
    return 1
}

# 三级：清理 conntrack
recover_clean_conntrack() {
    local now=$(monotonic_sec)
    (( now - LAST_CONNTRACK_CLEAN < MIN_INTERVAL_CLEAN_CONNTRACK )) && { log "conntrack清理节流"; return 1; }
    log "三级恢复：清理 conntrack"
    sleep 2
    if command -v conntrack >/dev/null; then
        conntrack -F 2>/dev/null
        LAST_CONNTRACK_CLEAN=$now; save_state
    else
        log "conntrack 未安装，跳过"
        return 1
    fi
    sleep "$WAIT_AFTER_CONNTRACK"
    verify_network_stable && return 0
    return 1
}

# 四级：重启系统
recover_reboot() {
    local now=$(monotonic_sec)
    (( LAST_REBOOT_TIME != 0 && now - LAST_REBOOT_TIME < COOLDOWN_AFTER_REBOOT )) && { log "重启冷却中"; return 1; }
    log "四级恢复：重启 VPS"
    sleep "$REBOOT_DELAY"
    LAST_REBOOT_TIME=$now; save_state
    nohup bash -c "sleep 2; reboot" >/dev/null 2>&1 &
    exit 0
}

# 智能恢复调度：根据故障原因选择最优先的恢复动作
perform_recovery() {
    log "开始恢复 (连续失败 ${FAIL_COUNT}/${FAIL_THRESHOLD}, 原因: ${REASON})"
    # 记录诊断
    {
        echo "=== 诊断 ==="
        ip -4 route show default 2>/dev/null | head -1
        ss -s 2>/dev/null | head -3
        [[ -f /proc/sys/net/netfilter/nf_conntrack_count ]] && {
            cnt=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
            max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
            echo "conntrack: ${cnt:-?}/${max:-?}"
        }
    } >> "$LOG_FILE"

    local recovered=0

    # 根据故障原因智能选择恢复路径
    case "$REASON" in
        conntrack_critical)
            # conntrack 过载优先清理
            recover_clean_conntrack && recovered=1 ;;
        dns_failure|curl_failure|ping_failure)
            # 代理问题优先
            recover_restart_proxy && recovered=1 ;;
        default_route_missing)
            # 路由丢失优先重启网络
            recover_restart_network && recovered=1 ;;
        *)
            # 未知原因按传统顺序
            recover_restart_proxy && recovered=1
            ;;
    esac

    if [[ $recovered -eq 0 ]]; then
        # 尝试剩余恢复动作（按优先级）
        recover_restart_network && recovered=1
    fi
    if [[ $recovered -eq 0 ]]; then
        recover_clean_conntrack && recovered=1
    fi
    if [[ $recovered -eq 0 ]]; then
        recover_reboot   # 内部可能退出或返回1
        recovered=1      # 重启分支会 exit，这里仅占位
    fi

    if [[ $recovered -eq 1 ]]; then
        FAIL_COUNT=0; CONSECUTIVE_FAILURES=0; LAST_RECOVER_TIME=$(monotonic_sec); save_state
        log "恢复成功"
        return 0
    else
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES+1)); save_state
        [[ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]] && log "达到最大失败次数，停止自动恢复" && sleep 600
        return 1
    fi
}

# ---------- 守护进程主循环（单调时钟）----------
watchdog_loop() {
    export WATCHDOG_DAEMON=1
    log "看门狗启动 PID $$"
    local last_check=$(monotonic_sec)
    while true; do
        local now=$(monotonic_sec)
        if (( now - last_check >= CHECK_INTERVAL )); then
            local cooldown=$((COOLDOWN_AFTER_RECOVER - (now - LAST_RECOVER_TIME)))
            if (( LAST_RECOVER_TIME > 0 && cooldown > 0 )); then
                log "恢复冷却 ${cooldown}s"
                last_check=$now
                sleep $((cooldown < CHECK_INTERVAL ? cooldown : CHECK_INTERVAL))
                continue
            fi
            if run_checks; then
                if (( FAIL_COUNT != 0 )); then
                    FAIL_COUNT=0; CONSECUTIVE_FAILURES=0; LAST_RECOVER_TIME=$now; save_state
                    log "网络恢复"
                fi
            else
                FAIL_COUNT=$((FAIL_COUNT+1))
                log "检测失败 (${REASON}) ${FAIL_COUNT}/${FAIL_THRESHOLD}"
                (( FAIL_COUNT >= FAIL_THRESHOLD )) && perform_recovery
            fi
            last_check=$now
        fi
        # 动态睡眠，最大 10 秒
        local sleep_time=$((CHECK_INTERVAL - (now - last_check)))
        if (( sleep_time > 10 )); then
            sleep_time=10
        elif (( sleep_time <= 0 )); then
            sleep_time=1
        fi
        sleep "$sleep_time"
    done
}

# ================= 管理函数 =================
is_running() { [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }
stop_watchdog() {
    if ! is_running; then echo "未运行"; return; fi
    local pid=$(cat "$PID_FILE")
    echo "停止 $pid"
    kill "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE" "$LOCK_FILE"; echo "已停止"
}
start_watchdog() {
    is_running && { echo "已在运行"; return; }
    load_config
    nohup bash "$SCRIPT_PATH" run >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"; sleep 1
    is_running && echo "启动成功 PID $(cat $PID_FILE)" || echo "启动失败"
}
restart_watchdog() { stop_watchdog; start_watchdog; }

config_panel() {
    while true; do
        clear; echo "==== 配置 ===="
        echo "1.检测间隔 ${CHECK_INTERVAL}  2.失败阈值 ${FAIL_THRESHOLD}  3.恢复冷却 ${COOLDOWN_AFTER_RECOVER}"
        echo "4.重启冷却 ${COOLDOWN_AFTER_REBOOT}  5.Ping目标 ${PING_TARGET}  6.Curl目标 ${CURL_TARGETS}"
        echo "7.代理服务 ${PROXY_SERVICES}  8.网络管理器 ${NETWORK_MANAGER}  9.conntrack临界% ${CONNTRACK_CRIT_PERCENT}"
        echo "10.最大失败 ${MAX_CONSECUTIVE_FAILURES}  11.重启延迟 ${REBOOT_DELAY}  12.应用并重启  0.返回"
        read -p "选择: " n
        case $n in
            1) read -p "新值: " v; [[ -n "$v" ]] && CHECK_INTERVAL=$v ;;
            2) read -p "新值: " v; [[ -n "$v" ]] && FAIL_THRESHOLD=$v ;;
            3) read -p "新值: " v; [[ -n "$v" ]] && COOLDOWN_AFTER_RECOVER=$v ;;
            4) read -p "新值: " v; [[ -n "$v" ]] && COOLDOWN_AFTER_REBOOT=$v ;;
            5) read -p "新值: " v; [[ -n "$v" ]] && PING_TARGET="$v" ;;
            6) read -p "新值: " v; [[ -n "$v" ]] && CURL_TARGETS="$v" ;;
            7) read -p "新值: " v; [[ -n "$v" ]] && PROXY_SERVICES="$v" ;;
            8) read -p "新值(auto/systemd-networkd/NetworkManager/networking/none): " v; [[ -n "$v" ]] && NETWORK_MANAGER="$v" ;;
            9) read -p "新值: " v; [[ -n "$v" ]] && CONNTRACK_CRIT_PERCENT=$v ;;
            10) read -p "新值: " v; [[ -n "$v" ]] && MAX_CONSECUTIVE_FAILURES=$v ;;
            11) read -p "新值(秒): " v; [[ -n "$v" ]] && REBOOT_DELAY=$v ;;
            12) save_config; restart_watchdog ;;
            0) break ;;
        esac
        save_config; load_config
    done
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
CHECK_INTERVAL=${CHECK_INTERVAL}
FAIL_THRESHOLD=${FAIL_THRESHOLD}
COOLDOWN_AFTER_RECOVER=${COOLDOWN_AFTER_RECOVER}
COOLDOWN_AFTER_REBOOT=${COOLDOWN_AFTER_REBOOT}
PING_TARGET="${PING_TARGET}"
CURL_TARGETS="${CURL_TARGETS}"
CURL_TIMEOUT=${CURL_TIMEOUT}
WAIT_AFTER_PROXY=${WAIT_AFTER_PROXY}
WAIT_AFTER_NETWORK=${WAIT_AFTER_NETWORK}
WAIT_AFTER_CONNTRACK=${WAIT_AFTER_CONNTRACK}
VERIFY_RETRIES=${VERIFY_RETRIES}
VERIFY_INTERVAL=${VERIFY_INTERVAL}
MIN_INTERVAL_RESTART_PROXY=${MIN_INTERVAL_RESTART_PROXY}
MIN_INTERVAL_RESTART_NETWORK=${MIN_INTERVAL_RESTART_NETWORK}
MIN_INTERVAL_CLEAN_CONNTRACK=${MIN_INTERVAL_CLEAN_CONNTRACK}
PROXY_SERVICES="${PROXY_SERVICES}"
NETWORK_MANAGER="${NETWORK_MANAGER}"
CONNTRACK_CRIT_PERCENT=${CONNTRACK_CRIT_PERCENT}
CONNTRACK_WARN_PERCENT=${CONNTRACK_WARN_PERCENT}
MAX_CONSECUTIVE_FAILURES=${MAX_CONSECUTIVE_FAILURES}
REBOOT_DELAY=${REBOOT_DELAY}
EOF
}

install_systemd() {
    cat > /etc/systemd/system/vps-watchdog.service <<EOF
[Unit]
Description=VPS Network Watchdog
After=network.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH run
Restart=always
RestartSec=10
StartLimitBurst=3
StartLimitIntervalSec=60
User=root
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable vps-watchdog
    echo "已安装 systemd 服务"
}

delete_watchdog() {
    stop_watchdog
    systemctl disable vps-watchdog 2>/dev/null
    rm -f /etc/systemd/system/vps-watchdog.service
    systemctl daemon-reload
    rm -rf "$BASE_DIR" "$LOCK_FILE" "$PID_FILE" "${STATE_FILE}.lock"
    echo "已删除"
}

main_menu() {
    while true; do
        clear; echo "==== VPS 网络看门狗 ===="
        is_running && echo "状态: 运行中 (PID $(cat $PID_FILE 2>/dev/null))" || echo "状态: 未运行"
        echo "1.启动 2.停止 3.重启 4.查看日志 5.修改配置 6.安装系统服务 7.删除 0.退出"
        read -p "选择: " n
        case $n in
            1) start_watchdog ;;
            2) stop_watchdog ;;
            3) restart_watchdog ;;
            4) tail -f "$LOG_FILE" ;;
            5) config_panel ;;
            6) install_systemd ;;
            7) delete_watchdog; exit 0 ;;
            0) exit 0 ;;
        esac
    done
}

if [[ "${1:-}" == "run" ]]; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || { echo "已有实例运行"; exit 0; }
    trap 'rm -f "$PID_FILE" "$LOCK_FILE"' EXIT
    watchdog_loop
else
    main_menu
fi
