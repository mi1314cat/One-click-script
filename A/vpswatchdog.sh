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

# 初始化状态文件
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

# 网络恢复 → 清零所有计数
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

# 修复流程
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

    # 连续 3 次重启仍失败 → 停止 watchdog
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
# 控制面板：super-watchdogctl
##############################################
cat > $CTL << 'EOF'
#!/bin/bash

BASE=/root/catmi/super-watchdog
STATE_FILE=$BASE/super-watchdog.state
LOG=$BASE/super-watchdog.log

case "$1" in
    status)
        echo "===== Watchdog Status ====="
        systemctl is-active super-watchdog.timer
        echo
        cat "$STATE_FILE"
        ;;
    start)
        systemctl start super-watchdog.timer
        echo "Watchdog started."
        ;;
    stop)
        systemctl stop super-watchdog.timer
        echo "Watchdog stopped."
        ;;
    restart)
        systemctl restart super-watchdog.timer
        echo "Watchdog restarted."
        ;;
    log)
        tail -n 50 "$LOG"
        ;;
    *)
        echo "Usage: super-watchdogctl {status|start|stop|restart|log}"
        ;;
esac
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
echo "Use: $CTL status"
echo "Use: $CTL log"
