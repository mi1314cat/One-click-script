#!/bin/bash

BASE=/root/catmi/super-watchdog
SCRIPT=$BASE/super-watchdog.sh
CTL=$BASE/super-watchdogctl
STATE=$BASE/super-watchdog.state
LOG=$BASE/super-watchdog.log
SERVICE=/etc/systemd/system/super-watchdog.service
TIMER=/etc/systemd/system/super-watchdog.timer

echo "Installing Super Watchdog into $BASE ..."
mkdir -p $BASE

##############################################
# 主程序：super-watchdog.sh
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

get_main_iface() {
    ip route | awk '/default/ {print $5}'
}

check_nic() {
    IFACE=$(get_main_iface)
    [ -z "$IFACE" ] && return 1
    ip link show "$IFACE" | grep -q "state UP"
}

check_ip() {
    ip -4 addr show "$(get_main_iface)" | grep -q "inet "
}

check_route() {
    ip route show default >/dev/null 2>&1
}

check_gateway() {
    GW=$(ip route | awk '/default/ {print $3}')
    ping -c 2 -W 1 "$GW" >/dev/null 2>&1
}

check_dns() {
    getent hosts cloudflare.com >/dev/null 2>&1 || resolvectl query cloudflare.com >/dev/null 2>&1
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

check_conntrack() {
    command -v conntrack >/dev/null 2>&1 || return 0
    CT=$(conntrack -C 2>/dev/null)
    [ "$CT" -lt 500000 ]
}

check_exit_broken() {
    ! check_ping_multi && ! check_tcp443 && ! check_http204
}

run_checks() {
    log "Running full system health check..."

    check_nic || return 1
    check_ip || return 1
    check_route || return 1
    check_gateway || return 1

    check_dns || log "DNS failed (repair only)"
    check_conntrack || log "Conntrack abnormal (not fatal)"

    check_exit_broken && return 1

    return 0
}

if run_checks; then
    log "All checks passed → FAIL=0, REBOOT_COUNT=0"
    FAIL=0
    REBOOT_COUNT=0
    echo "FAIL=$FAIL" > "$STATE_FILE"
    echo "REBOOT_COUNT=$REBOOT_COUNT" >> "$STATE_FILE"
    exit 0
fi

FAIL=$((FAIL+1))
log "Health check failed → FAIL=$FAIL"

echo "FAIL=$FAIL" > "$STATE_FILE"
echo "REBOOT_COUNT=$REBOOT_COUNT" >> "$STATE_FILE"

if [ "$FAIL" -eq 1 ]; then
    log "FAIL=1 → Restarting DNS"
    systemctl restart systemd-resolved 2>/dev/null
    systemctl restart resolvconf 2>/dev/null
fi

if [ "$FAIL" -eq 2 ]; then
    log "FAIL=2 → Restarting network services"
    systemctl restart networking 2>/dev/null
    systemctl restart systemd-networkd 2>/dev/null
    systemctl restart NetworkManager 2>/dev/null
fi

if [ "$FAIL" -eq 3 ]; then
    log "FAIL=3 → Waiting for next cycle"
fi

if [ "$FAIL" -eq 4 ]; then
    log "FAIL=4 → Rechecking next cycle"
fi

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
# 控制面板：单次刷新 + 操作后刷新 + 实时日志 + 退出选项
##############################################
cat > $CTL << 'EOF'
#!/bin/bash

BASE=/root/catmi/super-watchdog
STATE_FILE=$BASE/super-watchdog.state
LOG_FILE=$BASE/super-watchdog.log
SERVICE=super-watchdog.timer

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
    ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1 && echo "正常" && return
    echo "出口故障（Ping/TCP/HTTP 全失败）"
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
    echo "  0. 退出面板"
    echo "========================================="
}

panel_loop() {
    while true; do
        draw_panel
        echo -n "请输入操作编号："
        read key

        case "$key" in
            1)
                systemctl start $SERVICE
                ;;
            2)
                systemctl stop $SERVICE
                ;;
            3)
                systemctl restart $SERVICE
                ;;
            4)
                clear
                tail -n 200 "$LOG_FILE"
                echo ""
                echo "按任意键返回面板..."
                read -n 1
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
# systemd service + timer
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

systemctl daemon-reload
systemctl enable --now super-watchdog.timer

echo "Installation complete."
echo "Launching panel..."
sleep 1

bash $CTL
