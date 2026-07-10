#!/bin/bash

BASE=/root/catmi/super-watchdog
SCRIPT=$BASE/super-watchdog.sh
CTL=$BASE/super-watchdogctl
STATE=$BASE/super-watchdog.state
LOG=$BASE/super-watchdog.log
SERVICE=/etc/systemd/system/super-watchdog.service
TIMER=/etc/systemd/system/super-watchdog.timer
LOGROTATE=/etc/logrotate.d/super-watchdog

echo "Installing Super Watchdog into $BASE ..."
mkdir -p $BASE

##############################################
# 主程序：super-watchdog.sh（出口真实检测，网关失败不致命）
##############################################
cat > $SCRIPT << 'EOF'
#!/bin/bash

BASE=/root/catmi/super-watchdog
LOG=$BASE/super-watchdog.log
STATE_FILE=$BASE/super-watchdog.state

if [ ! -f "$STATE_FILE" ]; then
    echo "FAIL=0" > "$STATE_FILE"
    echo "REBOOT_COUNT=0" >> "$STATE_FILE"
fi

source "$STATE_FILE"

log() {
    echo "$(date '+%F %T') - $1" >> $LOG
}

check_ping_multi() {
    for ip in 1.1.1.1 8.8.8.8 9.9.9.9; do
        ping -c 2 -W 1 "$ip" >/dev/null 2>&1 && return 0
    done
    return 1
}

check_tcp443() {
    timeout 2 bash -c "</dev/tcp/1.1.1.1/443" >/dev/null 2>&1
}

check_http204() {
    curl -m 3 -s -o /dev/null https://cp.cloudflare.com/generate_204 && return 0
    curl -m 3 -s -o /dev/null https://connectivitycheck.gstatic.com/generate_204 && return 0
    return 1
}

run_checks() {
    log "Running full system health check..."

    # 出口完全断判定：ping + TCP 443 + HTTP 204 全部失败
    check_ping_multi || return 1
    check_tcp443 || return 1
    check_http204 || return 1

    return 0
}

# 网络恢复
if run_checks; then
    log "All checks passed → FAIL=0, REBOOT_COUNT=0"
    FAIL=0
    REBOOT_COUNT=0
    echo "FAIL=$FAIL" > "$STATE_FILE"
    echo "REBOOT_COUNT=$REBOOT_COUNT" >> "$STATE_FILE"
    exit 0
fi

# 网络失败
FAIL=$((FAIL+1))
log "Health check failed → FAIL=$FAIL"

echo "FAIL=$FAIL" > "$STATE_FILE"
echo "REBOOT_COUNT=$REBOOT_COUNT" >> "$STATE_FILE"

# FAIL≥5 → 重启 VPS
if [ "$FAIL" -ge 5 ]; then
    log "FAIL>=5 → reboot -f"
    sync
    REBOOT_COUNT=$((REBOOT_COUNT+1))
    echo "FAIL=0" > "$STATE_FILE"
    echo "REBOOT_COUNT=$REBOOT_COUNT" >> "$STATE_FILE"

    if [ "$REBOOT_COUNT" -ge 3 ]; then
        log "REBOOT_COUNT >= 3 → watchdog disabled"
        systemctl stop super-watchdog.timer
        exit 0
    fi

    reboot -f
fi
EOF

chmod +x $SCRIPT

##############################################
# 控制面板：可修改检查间隔 + 日志保留天数 + 清空日志
##############################################
cat > $CTL << 'EOF'
#!/bin/bash

BASE=/root/catmi/super-watchdog
STATE_FILE=$BASE/super-watchdog.state
LOG_FILE=$BASE/super-watchdog.log
SERVICE=super-watchdog.timer
TIMER_FILE=/etc/systemd/system/super-watchdog.timer
LOGROTATE=/etc/logrotate.d/super-watchdog

load_state() {
    source "$STATE_FILE" 2>/dev/null
    FAIL=${FAIL:-0}
    REBOOT_COUNT=${REBOOT_COUNT:-0}
}

is_running() {
    systemctl is-active --quiet $SERVICE
}

get_next_run_time() {
    NEXT=$(systemctl list-timers --all | grep super-watchdog | awk '{print $5" "$6}')
    echo "${NEXT:-未知}"
}

get_network_status() {
    for ip in 1.1.1.1 8.8.8.8 9.9.9.9; do
        ping -c 1 -W 1 "$ip" >/dev/null 2>&1 && echo "正常" && return
    done

    timeout 2 bash -c "</dev/tcp/1.1.1.1/443" >/dev/null 2>&1 && echo "正常" && return

    curl -m 3 -s -o /dev/null https://cp.cloudflare.com/generate_204 && echo "正常" && return
    curl -m 3 -s -o /dev/null https://connectivitycheck.gstatic.com/generate_204 && echo "正常" && return

    echo "出口故障（Ping/TCP/HTTP 全失败）"
}

change_interval() {
    clear
    echo "选择新的检查间隔："
    echo "1) 1 秒"
    echo "2) 10 秒"
    echo "3) 30 秒"
    echo "4) 1 分钟"
    echo "5) 5 分钟"
    echo "0) 返回面板"
    echo -n "请输入编号："
    read opt

    case "$opt" in
        1) SEC="1" ;;
        2) SEC="10" ;;
        3) SEC="30" ;;
        4) SEC="60" ;;
        5) SEC="300" ;;
        0) return ;;
        *) echo "无效选项"; sleep 1; return ;;
    esac

    cat > $TIMER_FILE << EOF2
[Unit]
Description=Run super watchdog every interval

[Timer]
OnBootSec=30
OnUnitActiveSec=$SEC

[Install]
WantedBy=timers.target
EOF2

    systemctl daemon-reload
    systemctl restart super-watchdog.timer

    echo "检查间隔已更新为：$SEC 秒"
    sleep 1
}

change_log_days() {
    clear
    echo "选择日志保留天数："
    echo "1) 1 天"
    echo "2) 3 天"
    echo "3) 7 天"
    echo "4) 14 天"
    echo "5) 30 天"
    echo "0) 返回面板"
    echo -n "请输入编号："
    read opt

    case "$opt" in
        1) DAYS=1 ;;
        2) DAYS=3 ;;
        3) DAYS=7 ;;
        4) DAYS=14 ;;
        5) DAYS=30 ;;
        0) return ;;
        *) echo "无效选项"; sleep 1; return ;;
    esac

    cat > $LOGROTATE << EOF3
/root/catmi/super-watchdog/super-watchdog.log {
    daily
    rotate $DAYS
    compress
    missingok
    notifempty
}
EOF3

    echo "日志保留天数已更新为：$DAYS 天"
    sleep 1
}

draw_panel() {
    clear
    load_state

    echo "========================================="
    if is_running; then
        echo "状态：🟢 运行中"
    else
        echo "状态：🔴 未运行"
    fi

    echo "下次执行时间：$(get_next_run_time)"
    echo "连续重启失败次数：$REBOOT_COUNT 次 (上限 3)"
    echo "当前 FAIL：$FAIL"
    echo "当前网络状态：$(get_network_status)"
    echo "========================================="

    echo "实时日志（最近 10 行）："
    echo "-----------------------------------------"
    tail -n 10 "$LOG_FILE"
    echo "-----------------------------------------"

    echo "操作："
    echo "  1. 启动 watchdog"
    echo "  2. 停止 watchdog"
    echo "  3. 重启 watchdog"
    echo "  4. 查看完整日志"
    echo "  5. 修改检查间隔"
    echo "  6. 修改日志保留天数"
    echo "  7. 清空日志"
    echo "  0. 退出面板"
    echo "========================================="
}

panel_loop() {
    while true; do
        draw_panel
        echo -n "请输入操作编号："
        read key

        case "$key" in
            1) systemctl start $SERVICE ;;
            2) systemctl stop $SERVICE ;;
            3) systemctl restart $SERVICE ;;
            4)
                clear
                tail -n 200 "$LOG_FILE"
                echo ""
                echo "按任意键返回面板..."
                read -n 1
                ;;
            5) change_interval ;;
            6) change_log_days ;;
            7)
                echo "" > "$LOG_FILE"
                echo "日志已清空"
                sleep 1
                ;;
            0)
                clear
                echo "退出面板"
                exit 0
                ;;
            *)
                echo "无效选项"
                sleep 1
                ;;
        esac
    done
}

panel_loop
EOF

chmod +x $CTL

##############################################
# systemd service + timer（默认 1 分钟）
##############################################
cat > $SERVICE << EOF
[Unit]
Description=Super Smart Network Watchdog

[Service]
Type=oneshot
ExecStart=$SCRIPT
EOF

cat > $TIMER << EOF
[Unit]
Description=Run super watchdog every minute

[Timer]
OnBootSec=30
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
EOF

##############################################
# 默认日志轮转（保留 7 天）
##############################################
cat > $LOGROTATE << EOF
/root/catmi/super-watchdog/super-watchdog.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
}
EOF

systemctl daemon-reload
systemctl enable --now super-watchdog.timer

echo "Installation complete."
echo "Launching panel..."
sleep 1

bash $CTL
