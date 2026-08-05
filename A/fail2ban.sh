#!/usr/bin/env bash
# ============================================================================
#  Fail2ban 全功能管理面板 - 优化版
#  优化要点:
#    1. 强制探测运行 jail (无视 fail2ban-client status 空列表)
#    2. 双层状态: 检测层(failed) + 拦截层(banned), 一眼定位"为什么不封"
#    3. 新增「拦截链路自检」: 真实封禁测试 IP 验证防火墙规则是否写入
#    4. 修复 bash 正则 (?:...) 不兼容的 bug
#    5. 统一彩色输出 (print_info 风格) + 表格化排版
#    6. 自动识别 SSH 端口, 避免非标端口漏检测
# ============================================================================
set -o pipefail

[[ $EUID -ne 0 ]] && { echo -e " \033[31m[FAIL]\033[0m 请以 root 身份运行"; exit 1; }

### ---------- 颜色与输出 (print_info 风格) ----------
PLAIN='\033[0m'
GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'
CYAN='\033[36m';  BLUE='\033[34m';   BOLD='\033[1m'; DIM='\033[2m'

print_info()   { echo -e " ${GREEN}[INFO]${PLAIN}  $1"; }
print_ok()     { echo -e " ${GREEN}[ OK ]${PLAIN}  $1"; }
print_warn()   { echo -e " ${YELLOW}[WARN]${PLAIN}  $1"; }
print_error()  { echo -e " ${RED}[FAIL]${PLAIN}  $1"; }
print_step()   { echo -e " ${BLUE}[ >> ]${PLAIN}  $1"; }

print_title_bar() {
    local text="$1"
    echo -e "${CYAN}${BOLD}┌─────────────────────────────────────────────┐${PLAIN}"
    printf "${CYAN}${BOLD}│${PLAIN} %-43s ${CYAN}${BOLD}│${PLAIN}\n" "$text"
    echo -e "${CYAN}${BOLD}└─────────────────────────────────────────────┘${PLAIN}"
}

clear_screen() { command -v clear >/dev/null 2>&1 && clear || printf "\n\n"; }
pause()        { echo; read -rp "  按回车键继续... " _; }

banner() {
    echo -e "${GREEN}╔═══════════════════════════════════════════════╗${PLAIN}"
    echo -e "${GREEN}║            Fail2ban 控制面板                  ║${PLAIN}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════╝${PLAIN}"
    echo -e "      ${GREEN}|\\__/,|   (\\\\${PLAIN}"
    echo -e "      ${GREEN}_.|o o  |_   ) )${PLAIN}"
    echo -e "${GREEN}-------------(((---(((-------------------${PLAIN}"
}

### ---------- 全局变量 ----------
FAIL2BAN_BIN=""
FIREWALL_BACKEND="unknown"
SSH_LOGFILE=""
F2B_LOGFILE=""
F2B_JAIL_ORDER=""                 # 有序 jail 列表 (空格分隔)
F2B_JAIL_COUNT=0
F2B_BAN_TOTAL=0
FAILED_JAILS=()
declare -A F2B_CUR_FAIL F2B_TOT_FAIL F2B_CUR_BAN F2B_TOT_BAN F2B_BANLIST

### ---------- 环境检测 ----------
detect_fail2ban() {
    if command -v fail2ban-client >/dev/null 2>&1; then
        FAIL2BAN_BIN="$(command -v fail2ban-client)"; return 0
    fi
    FAIL2BAN_BIN=""; return 1
}

detect_firewall_backend() {
    FIREWALL_BACKEND="unknown"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        FIREWALL_BACKEND="ufw"
    elif command -v nft >/dev/null 2>&1; then
        FIREWALL_BACKEND="nftables"
    fi
}

detect_log_paths() {
    F2B_LOGFILE=""; SSH_LOGFILE=""
    [[ -f /var/log/fail2ban.log ]] && F2B_LOGFILE="/var/log/fail2ban.log"
    [[ -z "$F2B_LOGFILE" && -f /var/log/fail2ban/fail2ban.log ]] && F2B_LOGFILE="/var/log/fail2ban/fail2ban.log"
    [[ -f /var/log/auth.log ]] && SSH_LOGFILE="/var/log/auth.log"
    [[ -z "$SSH_LOGFILE" && -f /var/log/secure ]] && SSH_LOGFILE="/var/log/secure"
}

get_ssh_port() {
    local p
    p=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
    echo "${p:-22}"
}

get_active_firewall_services() {
    local svcs=()
    systemctl is-active nftables.service &>/dev/null && svcs+=("nftables.service")
    systemctl is-active ufw.service &>/dev/null && svcs+=("ufw.service")
    echo "${svcs[@]}"
}

### ---------- INI 读写 (crudini 优先, 无则 awk 降级) ----------
INI_GET() { # file section key default
    local file="$1" section="$2" key="$3" def="$4" val
    if command -v crudini >/dev/null 2>&1; then
        val=$(crudini --get "$file" "$section" "$key" 2>/dev/null)
    else
        val=$(awk -v s="[$section]" -v k="$key" '
            BEGIN{in_s=0; found=0}
            /^[[:space:]]*\[/ { in_s=($0 ~ s) }
            in_s && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
                sub(/^[^=]*=[[:space:]]*/, ""); gsub(/[[:space:]]+$/, ""); print; found=1; exit
            }
            END{ exit (found?0:1) }
        ' "$file" 2>/dev/null)
    fi
    echo "${val:-$def}"
}

INI_SET() { # file section key value
    local file="$1" section="$2" key="$3" value="$4"
    if command -v crudini >/dev/null 2>&1; then
        crudini --set "$file" "$section" "$key" "$value"
    elif [[ -f "$file" ]]; then
        cp "$file" "$file.tmp"
        awk -v sec="[$section]" -v k="$key" -v v="$value" '
            BEGIN{in_s=0; done=0}
            {
                if ($0 ~ /^[[:space:]]*\[/) { in_s = ($0 ~ sec) }
                if (in_s && !done && $0 ~ "^[[:space:]]*" k "[[:space:]]*=") { print k " = " v; done=1; next }
                print
            }
            END{ if (!done) print sec "\n" k " = " v }
        ' "$file.tmp" > "$file"
        rm -f "$file.tmp"
    else
        print_warn "未安装 crudini 且配置文件不存在, 跳过写入"
    fi
}

### ---------- 状态刷新 (强制探测 + 双层数据) ----------
refresh_status() {
    F2B_JAIL_ORDER=""; F2B_JAIL_COUNT=0; F2B_BAN_TOTAL=0; FAILED_JAILS=()
    F2B_CUR_FAIL=(); F2B_TOT_FAIL=(); F2B_CUR_BAN=(); F2B_TOT_BAN=(); F2B_BANLIST=()

    detect_fail2ban || return
    systemctl is-active fail2ban &>/dev/null || return

    local raw jail_list out j cur_fail tot_fail cur_ban tot_ban banlist
    raw=$("$FAIL2BAN_BIN" status 2>&1)
    jail_list=$(echo "$raw" | awk -F': ' '/Jail list:/{print $2}' | tr ',' ' ' | xargs)

    # 空列表 → 直接探测常见 jail
    if [[ -z "$jail_list" ]]; then
        print_warn "fail2ban-client status 返回空列表, 正在直接探测可能运行的 jail..."
        local candidates=("sshd" "recidive" "postfix" "dovecot" "nginx-http-auth" "apache-auth")
        for j in "${candidates[@]}"; do
            "$FAIL2BAN_BIN" status "$j" &>/dev/null && jail_list="${jail_list}${jail_list:+ }$j"
        done
        [[ -n "$jail_list" ]] && print_info "直接探测发现运行中的 jail: $jail_list"
    fi

    for j in $jail_list; do
        out=$("$FAIL2BAN_BIN" status "$j" 2>/dev/null) || continue
        cur_fail=$(awk '/Currently failed/{print $NF; exit}' <<<"$out")
        tot_fail=$(awk '/Total failed/{print $NF; exit}'     <<<"$out")
        cur_ban=$(awk '/Currently banned/{print $NF; exit}'  <<<"$out")
        tot_ban=$(awk '/Total banned/{print $NF; exit}'      <<<"$out")
        [[ "$cur_fail" =~ ^[0-9]+$ ]] || cur_fail=0
        [[ "$tot_fail" =~ ^[0-9]+$ ]] || tot_fail=0
        [[ "$cur_ban"  =~ ^[0-9]+$ ]] || cur_ban=0
        [[ "$tot_ban"  =~ ^[0-9]+$ ]] || tot_ban=0
        banlist=$(awk '/Banned IP list:/{f=1; next} f && NF{gsub(/[[:space:]]+/," "); printf "%s ", $0}' <<<"$out" \
                  | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | tr '\n' ' ' | xargs)

        F2B_CUR_FAIL[$j]=$cur_fail; F2B_TOT_FAIL[$j]=$tot_fail
        F2B_CUR_BAN[$j]=$cur_ban;   F2B_TOT_BAN[$j]=$tot_ban
        F2B_BANLIST[$j]="$banlist"
        F2B_JAIL_ORDER="${F2B_JAIL_ORDER}${F2B_JAIL_ORDER:+ }$j"
        ((F2B_JAIL_COUNT++))
        ((F2B_BAN_TOTAL+=tot_ban))
    done

    [[ $F2B_JAIL_COUNT -eq 0 ]] && extract_jail_failures
}

### ---------- 状态表格 ----------
status_table() {
    printf "${BOLD}%-14s %10s %12s %12s %12s${PLAIN}\n" "Jail" "最近失败" "累计失败" "当前封禁" "累计封禁"
    printf "${DIM}%-14s %10s %12s %12s %12s${PLAIN}\n" "──────" "────" "────" "────" "────"
    local j
    for j in $F2B_JAIL_ORDER; do
        printf "%-14s %10s %12s %12s %12s\n" \
            "$j" \
            "${F2B_CUR_FAIL[$j]:-0}" \
            "${F2B_TOT_FAIL[$j]:-0}" \
            "${F2B_CUR_BAN[$j]:-0}" \
            "${F2B_TOT_BAN[$j]:-0}"
    done
}

### ---------- 提取启动失败原因 (修复 (?:...) 正则 bug) ----------
extract_jail_failures() {
    FAILED_JAILS=()
    local errors=""
    if [[ -n "$F2B_LOGFILE" && -f "$F2B_LOGFILE" ]]; then
        errors=$(grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} fail2ban\.' "$F2B_LOGFILE" 2>/dev/null | grep -E 'ERROR|WARNING' | tail -40)
    else
        errors=$(journalctl -u fail2ban --since "2 minutes ago" --no-pager 2>/dev/null | grep -E 'ERROR|WARNING')
    fi
    local line jail_name reason
    while IFS= read -r line; do
        [[ "$line" == *"already banned"* ]] && continue
        jail_name=""
        if [[ "$line" =~ jail[[:space:]]*['\"]([^'\"]+)['\"] ]]; then
            jail_name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ while[[:space:]](reading|configuring)[[:space:]]jail[[:space:]]*'([^']+)' ]]; then
            jail_name="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ (sshd|recidive|postfix|dovecot|nginx-http-auth) ]]; then
            jail_name="${BASH_REMATCH[1]}"
        fi
        [[ -z "$jail_name" ]] && continue
        reason=""
        [[ "$line" == *'No file(s) found for logpath'* ]] && reason="日志文件不存在 (logpath missing)"
        [[ "$line" == *'filter not found'* ]]            && reason="filter 文件缺失"
        [[ "$line" == *'action not found'* ]]            && reason="action 文件缺失"
        [[ "$line" == *'Unable to read action'* ]]       && reason="banaction 不可用"
        if [[ -z "$reason" && "$line" == *ERROR* ]]; then
            reason=$(echo "$line" | sed -E 's/^.*ERROR[[:space:]]+//' | cut -c1-120)
        fi
        [[ -n "$reason" ]] && FAILED_JAILS+=("$jail_name: $reason")
    done <<< "$errors"
    mapfile -t FAILED_JAILS < <(printf '%s\n' "${FAILED_JAILS[@]}" | sort -u)
}

### ---------- 重启并精准诊断 ----------
restart_and_diagnose() {
    print_step "重启 Fail2ban 服务..."
    systemctl restart fail2ban
    sleep 8
    refresh_status
    if [[ $F2B_JAIL_COUNT -gt 0 ]]; then
        print_ok "已检测到 ${F2B_JAIL_COUNT} 个运行的 jail, 累计封禁 ${F2B_BAN_TOTAL} 个 IP"
        echo
        status_table
        return 0
    elif [[ ${#FAILED_JAILS[@]} -gt 0 ]]; then
        print_error "Jail 启动失败, 原因如下:"
        for fail in "${FAILED_JAILS[@]}"; do echo -e "   ${RED}✗ $fail${PLAIN}"; done
        return 1
    else
        print_warn "未能自动提取到明确错误, 请手动检查日志:"
        echo "----------------------------------------"
        if [[ -n "$F2B_LOGFILE" && -f "$F2B_LOGFILE" ]]; then tail -30 "$F2B_LOGFILE"
        else journalctl -u fail2ban -n 40 --no-pager; fi
        echo "----------------------------------------"
        return 1
    fi
}

### ---------- 拦截链路自检 (为什么没拦截?) ----------
diag_blocking() {
    print_title_bar "拦截链路自检"
    refresh_status

    if [[ $F2B_JAIL_COUNT -eq 0 ]]; then
        print_error "没有检测到运行中的 jail, 请先执行『一键诊断+修复』(菜单 16)"
        return 1
    fi

    echo
    print_step "① 检测层检查 (是否读到失败记录)"
    local j tot_fail cur_fail tot_ban
    for j in $F2B_JAIL_ORDER; do
        cur_fail=${F2B_CUR_FAIL[$j]:-0}; tot_fail=${F2B_TOT_FAIL[$j]:-0}; tot_ban=${F2B_TOT_BAN[$j]:-0}
        printf "   ${CYAN}%-12s${PLAIN} 最近失败=%-6s 累计失败=%-8s 累计封禁=%s\n" "$j" "$cur_fail" "$tot_fail" "$tot_ban"
        if [[ "$tot_fail" -gt 0 ]]; then
            print_ok "$j 检测层正常 (读到了失败记录)"
        else
            print_warn "$j 从未读到失败记录 → 检查 logpath / SSH端口(=$(get_ssh_port)) / 是否被 journald 接管"
        fi
        if [[ "$tot_ban" -gt 0 ]]; then
            print_ok "$j 拦截层正常 (有封禁记录)"
        else
            print_warn "$j 拦截层无记录"
        fi
    done

    echo
    print_step "② 日志路径检查"
    echo -e "   SSH 日志:   ${SSH_LOGFILE:-未找到(可能走 journald)}"
    echo -e "   F2B 日志:   ${F2B_LOGFILE:-未找到}"
    if [[ -n "$SSH_LOGFILE" && ! -f "$SSH_LOGFILE" ]]; then
        print_warn "SSH 日志文件不存在, 建议使用 systemd 后端 (fix_ssh_logpath 会处理)"
    fi

    echo
    print_step "③ 真实写入测试规则 (封禁测试 IP 192.0.2.1, 10 秒后自动解封)"
    local test_ip="192.0.2.1"
    local test_jail
    test_jail=$(echo "$F2B_JAIL_ORDER" | awk '{print $1}')
    if "$FAIL2BAN_BIN" set "$test_jail" banip "$test_ip" >/dev/null 2>&1; then
        print_ok "fail2ban 层已封禁 $test_ip @ $test_jail"
        sleep 1
        case "$FIREWALL_BACKEND" in
            nftables)
                if nft list ruleset 2>/dev/null | grep -q "$test_ip"; then
                    print_ok "nftables 规则已写入 → 拦截链路正常 ✔"
                else
                    print_error "nftables 中找不到 $test_ip → banaction 与后端不匹配"
                fi ;;
            ufw)
                if ufw status 2>/dev/null | grep -q "$test_ip"; then
                    print_ok "ufw 规则已写入 → 拦截链路正常 ✔"
                else
                    print_error "ufw 中找不到 $test_ip → banaction 未生效"
                fi ;;
            *)
                print_warn "无法自动验证防火墙后端 ($FIREWALL_BACKEND), 请手动检查" ;;
        esac
        "$FAIL2BAN_BIN" set "$test_jail" unbanip "$test_ip" >/dev/null 2>&1
        print_ok "测试 IP 已解封"
    else
        print_error "封禁测试 IP 失败, fail2ban 命令返回错误"
    fi

    echo
    print_info "结论: ①检测层有记录+③规则写入成功 → 说明没拦截只是『没攻击/未触发阈值』; 否则按提示修复"
}

### ---------- 环境自动修复 ----------
fix_ssh_logpath() {
    if [[ -n "$SSH_LOGFILE" && -f "$SSH_LOGFILE" ]]; then return 0; fi
    print_warn "未找到传统 SSH 日志文件 (${SSH_LOGFILE:-/var/log/auth.log})"
    if grep -qE '^[[:space:]]*backend[[:space:]]*=[[:space:]]*systemd' /etc/fail2ban/jail.local 2>/dev/null; then
        print_info "已配置 systemd 后端, 无需日志文件"; return 0
    fi
    print_info "将后端切换至 systemd (从 journal 读取 SSH 登录信息)"
    if [[ -f /etc/fail2ban/jail.local ]]; then
        INI_SET /etc/fail2ban/jail.local DEFAULT backend systemd
    else
        mkdir -p /etc/fail2ban
        echo -e "[DEFAULT]\nbackend = systemd" > /etc/fail2ban/jail.local
    fi
    SSH_LOGFILE="journald"
}

fix_banaction() {
    local current_action
    current_action=$(INI_GET /etc/fail2ban/jail.local DEFAULT banaction "nftables-multiport")
    if [[ -f "/etc/fail2ban/action.d/${current_action}.conf" ]]; then return 0; fi
    print_warn "banaction '${current_action}' 配置文件不存在"
    local candidates=("ufw" "nftables-multiport" "iptables-multiport" "firewallcmd-ipset")
    for cand in "${candidates[@]}"; do
        if [[ -f "/etc/fail2ban/action.d/${cand}.conf" ]]; then
            print_info "切换 banaction 至 ${cand}"
            INI_SET /etc/fail2ban/jail.local DEFAULT banaction "$cand"
            return 0
        fi
    done
    print_error "未找到任何可用的 banaction, 请安装 fail2ban 完整包"
    return 1
}

fix_recidive_log() {
    if [[ ! -f /var/log/fail2ban.log ]]; then
        touch /var/log/fail2ban.log && chown root:root /var/log/fail2ban.log && chmod 644 /var/log/fail2ban.log
        print_info "已创建 /var/log/fail2ban.log"
    fi
}

auto_diagnose_and_fix() {
    print_title_bar "环境自动诊断与修复"
    detect_log_paths
    fix_ssh_logpath
    fix_banaction
    fix_recidive_log

    if [[ ! -f /etc/fail2ban/filter.d/sshd.conf ]]; then
        print_warn "sshd filter 缺失, 尝试恢复"
        if [[ -f /usr/share/fail2ban/filter.d/sshd.conf ]]; then
            cp /usr/share/fail2ban/filter.d/sshd.conf /etc/fail2ban/filter.d/
            print_info "已恢复 sshd filter"
        else
            print_error "sshd filter 完全丢失, 请重装 fail2ban"
        fi
    fi

    restart_and_diagnose
    if [[ $? -eq 0 ]]; then print_ok "修复成功, 所有 jail 正常工作"
    else print_error "仍有 jail 启动失败, 请根据上述原因手动处理"; fi
    pause
}

### ---------- 应用推荐配置 ----------
apply_recommended() {
    print_title_bar "应用推荐安全配置"
    detect_log_paths
    fix_ssh_logpath
    fix_banaction
    fix_recidive_log

    local ba ssh_port
    if [[ "$FIREWALL_BACKEND" == "ufw" ]]; then
        ba="ufw"
    else
        ba="nftables-multiport"
        [[ ! -f /etc/fail2ban/action.d/nftables-multiport.conf ]] && ba="iptables-multiport"
    fi
    ssh_port=$(get_ssh_port)
    print_info "检测到 SSH 端口: ${ssh_port}"

    local f2b_log="${F2B_LOGFILE:-/var/log/fail2ban.log}"
    local ssh_log="${SSH_LOGFILE:-/var/log/auth.log}"
    [[ "$SSH_LOGFILE" == "journald" || -z "$SSH_LOGFILE" ]] && ssh_log=""

    mkdir -p /etc/fail2ban
    local backup_file="/etc/fail2ban/jail.local.bak.$(date +%s)"
    [[ -f /etc/fail2ban/jail.local ]] && cp /etc/fail2ban/jail.local "$backup_file"

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 1h
findtime = 600
maxretry = 5
bantime.increment = true
bantime.maxtime = 1w
banaction = ${ba}
backend = auto
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = ${ssh_port}
EOF
    [[ -n "$ssh_log" ]] && echo "logpath = ${ssh_log}" >> /etc/fail2ban/jail.local
    cat >> /etc/fail2ban/jail.local << EOF

[recidive]
enabled = true
logpath = ${f2b_log}
banaction = %(banaction_allports)s
bantime  = 1w
findtime = 1d
maxretry = 3
EOF

    print_ok "推荐配置已写入 (旧配置备份于 $backup_file)"
    restart_and_diagnose
}

### ---------- 安装 ----------
install_fail2ban() {
    detect_fail2ban && { print_info "Fail2ban 已安装。"; return; }
    print_title_bar "安装 Fail2ban"
    if command -v apt &>/dev/null; then apt update && apt install -y fail2ban crudini
    elif command -v dnf &>/dev/null; then dnf install -y fail2ban crudini
    elif command -v yum &>/dev/null; then yum install -y fail2ban crudini
    elif command -v zypper &>/dev/null; then zypper install -y fail2ban crudini
    else print_error "不支持的包管理器"; return; fi
    systemctl enable fail2ban --now
    print_info "安装完成, 正在应用推荐配置..."
    auto_diagnose_and_fix
}

### ---------- 运维功能 ----------
select_jail() {
    refresh_status
    if [[ $F2B_JAIL_COUNT -eq 0 ]]; then
        print_warn "当前无可用 jail"; return 1
    fi
    local names=($F2B_JAIL_ORDER) input idx
    echo "可用 jail:"
    for i in "${!names[@]}"; do echo "   $((i+1))) ${names[$i]}"; done
    read -rp "  请输入 jail 名称或序号: " input
    [[ -z "$input" ]] && return 1
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        idx=$((input-1))
        if [[ $idx -ge 0 && $idx -lt ${#names[@]} ]]; then SELECTED_JAIL="${names[$idx]}"
        else print_error "无效序号"; return 1; fi
    else
        SELECTED_JAIL="$input"
        [[ " $F2B_JAIL_ORDER " == *" $SELECTED_JAIL "* ]] || { print_error "jail '$SELECTED_JAIL' 不存在"; return 1; }
    fi
    return 0
}

ban_ip() {
    select_jail || return
    local ip
    read -rp "  输入 IP: " ip
    [[ -z "$ip" ]] && return
    if "$FAIL2BAN_BIN" set "$SELECTED_JAIL" banip "$ip" >/dev/null 2>&1; then
        print_ok "已封禁 $ip @ $SELECTED_JAIL"
        case "$FIREWALL_BACKEND" in
            nftables) nft list ruleset 2>/dev/null | grep -q "$ip" && print_ok "nftables 规则已写入" || print_warn "nftables 未找到规则, 请检查 banaction" ;;
            ufw)      ufw status 2>/dev/null | grep -q "$ip" && print_ok "ufw 规则已写入" || print_warn "ufw 未找到规则, 请检查 banaction" ;;
        esac
    else
        print_error "封禁失败"
    fi
}

unban_ip() {
    select_jail || return
    local ip
    read -rp "  输入 IP: " ip
    [[ -z "$ip" ]] && return
    "$FAIL2BAN_BIN" set "$SELECTED_JAIL" unbanip "$ip" >/dev/null 2>&1 && print_ok "已解封 $ip" || print_error "解封失败"
}

get_all_jails() {
    local f
    for f in /etc/fail2ban/jail.local /etc/fail2ban/jail.d/*.local /etc/fail2ban/jail.conf; do
        [[ -f "$f" ]] && awk -F'[][]' '/^[[:space:]]*\[.*\]/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); if ($2!="" && $2!="DEFAULT" && $2!="INCLUDES") print $2}' "$f"
    done | sort -u
}

jail_toggle() {
    local jail="$1"
    local enabled
    enabled=$(INI_GET /etc/fail2ban/jail.local "$jail" enabled "false")
    if [[ "$enabled" == "true" ]]; then
        INI_SET /etc/fail2ban/jail.local "$jail" enabled "false"; print_info "已禁用 $jail"
    else
        INI_SET /etc/fail2ban/jail.local "$jail" enabled "true";  print_info "已启用 $jail"
    fi
    restart_and_diagnose
}

jail_management_menu() {
    while true; do
        clear_screen
        print_title_bar "Jail 管理"
        detect_fail2ban || { print_error "Fail2ban 未安装"; pause; return; }
        local all_jails
        all_jails=$(get_all_jails)
        [[ -z "$all_jails" ]] && { print_warn "未找到 jail 定义"; pause; return; }
        echo "所有 Jail (序号切换启用状态):"
        local i=1 j status
        declare -A jmap
        for j in $all_jails; do
            status="禁用"
            [[ $(INI_GET /etc/fail2ban/jail.local "$j" enabled "false") == "true" ]] && status="${GREEN}启用${PLAIN}"
            echo -e "   $i) $j [${status}]"
            jmap[$i]="$j"; ((i++))
        done
        echo "   b) 返回"
        read -rp "  选择: " c
        [[ "$c" == "b" ]] && break
        if [[ -n "${jmap[$c]}" ]]; then jail_toggle "${jmap[$c]}"; pause
        else print_error "无效选择"; pause; fi
    done
}

live_monitor() {
    trap 'echo -e "\n监控结束"; return' INT
    while true; do
        clear_screen
        print_title_bar "Fail2ban 实时监控 (Ctrl+C 退出)"
        refresh_status
        if [[ $F2B_JAIL_COUNT -gt 0 ]]; then status_table
        else echo -e "   ${YELLOW}无运行中的 jail${PLAIN}"; fi
        echo
        echo -e "${BOLD}最近事件:${PLAIN}"
        if [[ -n "$F2B_LOGFILE" && -f "$F2B_LOGFILE" ]]; then tail -6 "$F2B_LOGFILE" 2>/dev/null
        else journalctl -u fail2ban -n 6 --no-pager 2>/dev/null; fi
        sleep 5
    done
}

log_analysis() {
    if [[ ! -f "$F2B_LOGFILE" ]]; then print_error "日志文件不存在"; return; fi
    print_title_bar "日志分析"
    echo -e "${BOLD}1) 封禁次数最多的 IP (前20):${PLAIN}"
    grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$F2B_LOGFILE" | sort | uniq -c | sort -nr | head -20
    echo
    echo -e "${BOLD}2) 按天统计攻击次数:${PLAIN}"
    grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' "$F2B_LOGFILE" | sort | uniq -c
    if command -v geoiplookup &>/dev/null; then
        echo
        echo -e "${BOLD}3) 攻击来源国家 (基于 GeoIP):${PLAIN}"
        grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$F2B_LOGFILE" | sort -u | head -20 | while read ip; do
            echo "   $ip: $(geoiplookup "$ip" | awk -F': ' '{print $2}')"
        done
    fi
}

restore_default() {
    read -rp "  将清空所有自定义配置(备份到 .bak), 继续? (y/N): " c
    [[ ! "$c" =~ ^[Yy] ]] && return
    local backup="/etc/fail2ban/jail.local.bak.$(date +%s)"
    cp /etc/fail2ban/jail.local "$backup" 2>/dev/null
    cat > /etc/fail2ban/jail.local <<< "[DEFAULT]"
    print_info "已恢复默认, 重启验证..."
    restart_and_diagnose
}

view_jail_details() {
    select_jail || return
    "$FAIL2BAN_BIN" status "$SELECTED_JAIL" 2>&1
}

fix_boot_order() {
    local svcs=($(get_active_firewall_services))
    mkdir -p /etc/systemd/system/fail2ban.service.d
    cat > /etc/systemd/system/fail2ban.service.d/override.conf << EOF
[Unit]
After=network.target ${svcs[@]}
Wants=${svcs[@]}
[Service]
ExecStartPre=/bin/sleep 3
EOF
    systemctl daemon-reload
    print_info "已设置延迟启动, 立即重启验证..."
    restart_and_diagnose
}

### ---------- 主菜单 ----------
main_menu() {
    while true; do
        clear_screen
        print_title_bar "Fail2ban 完全管理面板"
        banner
        refresh_status
        detect_firewall_backend
        detect_log_paths

        echo
        echo -e "${BOLD}${CYAN}系统状态${PLAIN}"
        if ! systemctl is-active fail2ban &>/dev/null; then
            echo -e "   ${RED}● fail2ban 服务未运行${PLAIN}"
        else
            echo -e "   ${GREEN}● fail2ban 运行中${PLAIN}   防火墙: ${CYAN}${FIREWALL_BACKEND}${PLAIN}   SSH端口: ${CYAN}$(get_ssh_port)${PLAIN}"
            echo
            if [[ $F2B_JAIL_COUNT -gt 0 ]]; then
                status_table
                local j
                for j in $F2B_JAIL_ORDER; do
                    if [[ -n "${F2B_BANLIST[$j]}" ]]; then
                        echo
                        echo -e "   ${YELLOW}${BOLD}${j} 封禁 IP:${PLAIN} ${F2B_BANLIST[$j]}"
                    fi
                done
            else
                echo -e "   ${YELLOW}⚠ 未检测到运行中的 jail${PLAIN}"
                if [[ ${#FAILED_JAILS[@]} -gt 0 ]]; then
                    echo -e "   ${RED}启动失败:${PLAIN}"
                    for fail in "${FAILED_JAILS[@]}"; do echo -e "     ${RED}✗ $fail${PLAIN}"; done
                fi
            fi
        fi
        echo
        echo -e "   ${DIM}SSH日志: ${SSH_LOGFILE:-未找到}    F2B日志: ${F2B_LOGFILE:-未找到}${PLAIN}"
        echo
        echo "  1) 安装 Fail2ban"
        echo "  2) 应用推荐安全配置"
        echo "  3) 重启 Fail2ban + 自动诊断"
        echo -e "  4) ${YELLOW}拦截链路自检 (为什么没拦截?)${PLAIN}"
        echo "  5) 手动封禁 IP"
        echo "  6) 手动解封 IP"
        echo "  7) Jail 管理 (启用/禁用)"
        echo "  8) 查看 Jail 详情 (含封禁 IP 列表)"
        echo "  9) 查看 Fail2ban 日志 (tail -50)"
        echo " 10) 实时攻击监控"
        echo " 11) 日志分析"
        echo " 12) 手动编辑 jail.local"
        echo " 13) 切换防火墙后端"
        echo " 14) 恢复默认配置"
        echo " 15) 永久修复开机丢失 Jail"
        echo " 16) 一键诊断+自动修复环境"
        echo " 17) 卸载 Fail2ban"
        echo "  0) 退出"
        read -rp "  请选择: " opt
        case "$opt" in
            1) install_fail2ban; pause ;;
            2) apply_recommended; pause ;;
            3) restart_and_diagnose; pause ;;
            4) diag_blocking; pause ;;
            5) ban_ip; pause ;;
            6) unban_ip; pause ;;
            7) jail_management_menu; pause ;;
            8) view_jail_details; pause ;;
            9) [[ -f "$F2B_LOGFILE" ]] && tail -50 "$F2B_LOGFILE" || journalctl -u fail2ban -n 50 --no-pager; pause ;;
           10) live_monitor ;;
           11) log_analysis; pause ;;
           12) nano /etc/fail2ban/jail.local; restart_and_diagnose; pause ;;
           13) echo "当前后端: $FIREWALL_BACKEND"; echo "可选: ufw / nftables-multiport / iptables-multiport"
               read -rp "  输入: " newba
               [[ -n "$newba" ]] && { INI_SET /etc/fail2ban/jail.local DEFAULT banaction "$newba"; restart_and_diagnose; }; pause ;;
           14) restore_default; pause ;;
           15) fix_boot_order; pause ;;
           16) auto_diagnose_and_fix; pause ;;
           17) read -rp "  确认卸载? (yes/NO): " c
               if [[ "$c" == "yes" ]]; then
                   systemctl stop fail2ban; systemctl disable fail2ban
                   apt purge -y fail2ban 2>/dev/null || dnf remove -y fail2ban 2>/dev/null || true
                   rm -rf /etc/fail2ban
                   print_info "已卸载"
               fi; pause ;;
            0) exit 0 ;;
            *) print_error "无效选项"; pause ;;
        esac
    done
}

main_menu
