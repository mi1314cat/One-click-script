#!/usr/bin/env bash
# ============================================================
#  Fail2ban 全功能管理面板 - 终极版（强制探测运行 jail）
#  特性：无视 status 空列表，直接探测已知 jail
# ============================================================
set -o pipefail

### ---------- 基础 UI ----------
COLOR_RESET="\033[0m"
COLOR_BLUE1="\033[38;5;33m"
COLOR_BLUE2="\033[38;5;39m"
COLOR_BLUE3="\033[38;5;45m"
COLOR_CYAN="\033[36m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_RED="\033[31m"
COLOR_GRAY="\033[90m"

print_info()    { echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET} $*"; }
print_warn()    { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
print_error()   { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*"; }
print_title_bar() {
    local text="$1"
    echo -e "${COLOR_BLUE1}======================================================================${COLOR_RESET}"
    echo -e "${COLOR_BLUE2}                    ${text}${COLOR_RESET}"
    echo -e "${COLOR_BLUE3}======================================================================${COLOR_RESET}"
}
clear_screen() { command -v clear >/dev/null 2>&1 && clear || printf "\n\n"; }
pause() { echo; read -rp "按回车键继续..." _; }
require_root() { [[ $EUID -ne 0 ]] && { print_error "请以 root 身份运行"; exit 1; }; }
banner() {
    echo -e "${COLOR_GREEN}╔════════════════════════════════════════════════╗"
    echo -e "${COLOR_GREEN}║                      CATMI                   ║"
    echo -e "${COLOR_GREEN}╚════════════════════════════════════════════════╝${COLOR_CYAN}"
    echo -e "                       ${COLOR_GREEN}|\\__/,|   (\\\\${COLOR_CYAN}"
    echo -e "                     ${COLOR_GREEN}_.|o o  |_   ) )${COLOR_CYAN}"
    echo -e "       ${COLOR_GREEN}-------------(((---(((-------------------${COLOR_CYAN}"
}

### ---------- 全局环境 ----------
FAIL2BAN_BIN=""
FIREWALL_BACKEND="unknown"
SSH_LOGFILE=""
F2B_LOGFILE=""
FAILED_JAILS=()          # 存储 "jail: 具体错误"
declare -A F2B_JAIL_STATUS

### ---------- 环境检测 ----------
detect_fail2ban() {
    if command -v fail2ban-client >/dev/null 2>&1; then
        FAIL2BAN_BIN="$(command -v fail2ban-client)"
        return 0
    fi
    FAIL2BAN_BIN=""
    return 1
}

detect_firewall_backend() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
        FIREWALL_BACKEND="ufw"
    elif command -v nft >/dev/null 2>&1; then
        FIREWALL_BACKEND="nftables"
    else
        FIREWALL_BACKEND="unknown"
    fi
}

detect_log_paths() {
    if [[ -f /var/log/fail2ban.log ]]; then
        F2B_LOGFILE="/var/log/fail2ban.log"
    elif [[ -f /var/log/fail2ban/fail2ban.log ]]; then
        F2B_LOGFILE="/var/log/fail2ban/fail2ban.log"
    else
        F2B_LOGFILE=""
    fi

    if [[ -f /var/log/auth.log ]]; then
        SSH_LOGFILE="/var/log/auth.log"
    elif [[ -f /var/log/secure ]]; then
        SSH_LOGFILE="/var/log/secure"
    else
        SSH_LOGFILE=""
    fi
}

get_active_firewall_services() {
    local svcs=()
    systemctl is-active nftables.service &>/dev/null && svcs+=("nftables.service")
    systemctl is-active ufw.service &>/dev/null && svcs+=("ufw.service")
    echo "${svcs[@]}"
}

### ---------- INI 读写 ----------
if command -v crudini >/dev/null 2>&1; then
    INI_GET() { crudini --get "$1" "$2" "$3" 2>/dev/null; }
    INI_SET() { crudini --set "$1" "$2" "$3" "$4" 2>/dev/null; }
else
    INI_GET() {
        awk -v section="$2" -v key="$3" -v def="$4" '
            BEGIN { found=0; val=def }
            /^[[:space:]]*\[/ { in_section=($0 ~ "\\[" section "\\]") }
            in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
                sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", ""); gsub(/[[:space:]]*$/, ""); val=$0; found=1; exit
            }
            END { print val; exit (found ? 0 : 1) }
        ' "$1"
    }
    INI_SET() { echo "警告: 未安装 crudini，配置修改受限" >&2; return 1; }
fi

### ---------- 精准提取启动失败原因 ----------
extract_jail_failures() {
    FAILED_JAILS=()
    local errors=""
    if [[ -n "$F2B_LOGFILE" && -f "$F2B_LOGFILE" ]]; then
        errors=$(grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} fail2ban\.' "$F2B_LOGFILE" | grep -E 'ERROR|WARNING' | tail -40)
    else
        errors=$(journalctl -u fail2ban --since "2 minutes ago" --no-pager | grep -E 'ERROR|WARNING')
    fi

    local jail_name=""
    while IFS= read -r line; do
        [[ "$line" =~ already\ banned ]] && continue

        if [[ "$line" =~ jail[[:space:]]*[\'\"]([^\'\"]+)[\'\"] ]]; then
            jail_name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ while\ (?:reading|configuring)\ jail\ \'([^\']+)\' ]]; then
            jail_name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ (sshd|recidive|postfix|dovecot|nginx-http-auth) ]]; then
            jail_name="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$jail_name" ]]; then
            local reason=""
            if [[ "$line" =~ 'No file(s) found for logpath' ]]; then
                reason="日志文件不存在 (logpath missing)"
            elif [[ "$line" =~ 'filter not found' ]]; then
                reason="filter 文件缺失"
            elif [[ "$line" =~ 'action not found' ]]; then
                reason="action 文件缺失"
            elif [[ "$line" =~ 'Unable to read action' ]]; then
                reason="banaction 不可用"
            elif [[ "$line" =~ ERROR ]]; then
                reason=$(echo "$line" | sed -E 's/^.*ERROR[[:space:]]+//' | cut -c1-120)
            else
                continue
            fi
            FAILED_JAILS+=("$jail_name: $reason")
        fi
    done <<< "$errors"

    if [[ ${#FAILED_JAILS[@]} -gt 0 ]]; then
        mapfile -t FAILED_JAILS < <(printf "%s\n" "${FAILED_JAILS[@]}" | sort -u)
    fi
}

### ---------- 状态刷新（强制探测实际运行的 jail）----------
refresh_status() {
    unset F2B_JAIL_STATUS
    declare -gA F2B_JAIL_STATUS
    F2B_JAIL_COUNT=0
    F2B_BAN_TOTAL=0
    FAILED_JAILS=()

    detect_fail2ban || return
    if ! systemctl is-active fail2ban &>/dev/null; then
        return
    fi

    # 方法1：从 status 获取 jail 列表
    local raw jail_list
    raw=$("$FAIL2BAN_BIN" status 2>&1)
    jail_list=$(echo "$raw" | awk -F': ' '/Jail list:/ {print $2}' | tr ',' ' ' | xargs)

    # 如果获取不到任何 jail，尝试直接探测常见 jail
    if [[ -z "$jail_list" ]]; then
        print_warn "fail2ban-client status 返回空列表，正在直接探测可能运行的 jail..."
        # 常见 jail 列表
        local candidate_jails=("sshd" "recidive" "postfix" "dovecot" "nginx-http-auth" "apache-auth")
        local found_jails=()
        for jail in "${candidate_jails[@]}"; do
            if "$FAIL2BAN_BIN" status "$jail" &>/dev/null; then
                found_jails+=("$jail")
            fi
        done
        if [[ ${#found_jails[@]} -gt 0 ]]; then
            jail_list="${found_jails[*]}"
            print_info "通过直接探测发现运行中的 jail: $jail_list"
        fi
    fi

    if [[ -n "$jail_list" ]]; then
        for jail in $jail_list; do
            local status_output banned
            status_output=$("$FAIL2BAN_BIN" status "$jail" 2>/dev/null)
            if [[ $? -eq 0 ]]; then
                # 提取 "Currently banned:" 后的数字
                banned=$(echo "$status_output" | grep -i "Currently banned" | awk '{print $NF}')
                [[ "$banned" =~ ^[0-9]+$ ]] || banned=0
                F2B_JAIL_STATUS["$jail"]=$banned
                ((F2B_JAIL_COUNT++))
                ((F2B_BAN_TOTAL+=banned))
            fi
        done
    fi

    # 如果还是没有 jail，尝试提取失败原因
    if [[ $F2B_JAIL_COUNT -eq 0 ]]; then
        extract_jail_failures
    fi
}

### ---------- 重启并精准诊断 ----------
restart_and_diagnose() {
    print_info "重启 Fail2ban 服务..."
    systemctl restart fail2ban
    sleep 8

    refresh_status

    if [[ $F2B_JAIL_COUNT -gt 0 ]]; then
        print_info "已检测到 ${F2B_JAIL_COUNT} 个运行的 jail，总封禁 ${F2B_BAN_TOTAL} 个 IP"
        return 0
    elif [[ ${#FAILED_JAILS[@]} -gt 0 ]]; then
        print_error "Jail 启动失败，原因如下："
        for fail in "${FAILED_JAILS[@]}"; do
            echo -e "  ${COLOR_RED}✗ ${fail}${COLOR_RESET}"
        done
        return 1
    else
        print_warn "未能自动提取到明确错误，请手动检查日志："
        echo "----------------------------------------"
        if [[ -n "$F2B_LOGFILE" && -f "$F2B_LOGFILE" ]]; then
            tail -30 "$F2B_LOGFILE"
        else
            journalctl -u fail2ban -n 40 --no-pager
        fi
        echo "----------------------------------------"
        return 1
    fi
}

### ---------- 环境自动修复 ----------
fix_ssh_logpath() {
    if [[ -n "$SSH_LOGFILE" && -f "$SSH_LOGFILE" ]]; then
        return 0
    fi
    print_warn "未找到传统 SSH 日志文件 (${SSH_LOGFILE:-/var/log/auth.log})"
    if grep -q "^backend = systemd" /etc/fail2ban/jail.local 2>/dev/null; then
        print_info "已配置 systemd 后端，无需日志文件"
        return 0
    fi
    print_info "将后端切换至 systemd (从 journal 读取 SSH 登录信息)"
    if [[ -f /etc/fail2ban/jail.local ]]; then
        crudini --set /etc/fail2ban/jail.local DEFAULT backend systemd 2>/dev/null ||
        echo -e "\n[DEFAULT]\nbackend = systemd" >> /etc/fail2ban/jail.local
    else
        echo -e "[DEFAULT]\nbackend = systemd" > /etc/fail2ban/jail.local
    fi
    SSH_LOGFILE="journald"
}

fix_banaction() {
    local current_action
    current_action=$(INI_GET /etc/fail2ban/jail.local DEFAULT banaction)
    [[ -z "$current_action" ]] && current_action="nftables-multiport"
    if [[ -f "/etc/fail2ban/action.d/${current_action}.conf" ]]; then
        return 0
    fi
    print_warn "banaction '${current_action}' 配置文件不存在"
    local candidates=("ufw" "nftables-multiport" "iptables-multiport" "firewallcmd-ipset")
    for cand in "${candidates[@]}"; do
        if [[ -f "/etc/fail2ban/action.d/${cand}.conf" ]]; then
            print_info "切换 banaction 至 ${cand}"
            INI_SET /etc/fail2ban/jail.local DEFAULT banaction "$cand"
            return 0
        fi
    done
    print_error "未找到任何可用的 banaction，请安装 fail2ban 完整包"
    return 1
}

fix_recidive_log() {
    if [[ ! -f /var/log/fail2ban.log ]]; then
        touch /var/log/fail2ban.log
        chown root:root /var/log/fail2ban.log
        chmod 644 /var/log/fail2ban.log
        print_info "已创建 /var/log/fail2ban.log"
    fi
}

auto_diagnose_and_fix() {
    print_title_bar "环境自动诊断与修复"
    fix_ssh_logpath
    fix_banaction
    fix_recidive_log

    if [[ ! -f /etc/fail2ban/filter.d/sshd.conf ]]; then
        print_warn "sshd filter 缺失，尝试恢复"
        if [[ -f /usr/share/fail2ban/filter.d/sshd.conf ]]; then
            cp /usr/share/fail2ban/filter.d/sshd.conf /etc/fail2ban/filter.d/
            print_info "已恢复 sshd filter"
        else
            print_error "sshd filter 完全丢失，请重装 fail2ban"
        fi
    fi

    restart_and_diagnose
    if [[ $? -eq 0 ]]; then
        print_info "修复成功，所有 jail 正常工作"
    else
        print_error "仍有 jail 启动失败，请根据上述原因手动处理"
    fi
    pause
}

### ---------- 应用推荐配置 ----------
apply_recommended() {
    detect_log_paths
    fix_ssh_logpath
    fix_banaction
    fix_recidive_log

    local ba
    if [[ "$FIREWALL_BACKEND" == "ufw" ]]; then
        ba="ufw"
    else
        ba="nftables-multiport"
        [[ ! -f /etc/fail2ban/action.d/nftables-multiport.conf ]] && ba="iptables-multiport"
    fi

    local f2b_log="${F2B_LOGFILE:-/var/log/fail2ban.log}"
    local ssh_log="${SSH_LOGFILE:-/var/log/auth.log}"
    if [[ "$SSH_LOGFILE" == "journald" ]] || [[ -z "$SSH_LOGFILE" ]]; then
        ssh_log=""
    fi

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

[sshd]
enabled = true
port    = ssh
EOF
    if [[ -n "$ssh_log" ]]; then
        echo "logpath = ${ssh_log}" >> /etc/fail2ban/jail.local
    fi

    cat >> /etc/fail2ban/jail.local << EOF

[recidive]
enabled = true
logpath = ${f2b_log}
banaction = %(banaction_allports)s
bantime  = 1w
findtime = 1d
maxretry = 3
EOF

    print_info "推荐配置已写入（旧配置备份于 $backup_file）"
    restart_and_diagnose
}

### ---------- 安装 ----------
install_fail2ban() {
    detect_fail2ban && { print_info "Fail2ban 已安装。"; return; }
    print_title_bar "安装 Fail2ban"
    if command -v apt &>/dev/null; then
        apt update && apt install -y fail2ban crudini
    elif command -v dnf &>/dev/null; then
        dnf install -y fail2ban crudini
    elif command -v yum &>/dev/null; then
        yum install -y fail2ban crudini
    elif command -v zypper &>/dev/null; then
        zypper install -y fail2ban crudini
    else
        print_error "不支持的包管理器"; return
    fi
    systemctl enable fail2ban --now
    print_info "安装完成，正在应用推荐配置..."
    auto_diagnose_and_fix
}

### ---------- 运维功能（改进交互）----------
ban_ip() {
    refresh_status
    if [[ $F2B_JAIL_COUNT -eq 0 ]]; then
        print_warn "当前无可用 jail"
        return
    fi

    local jail_names=("${!F2B_JAIL_STATUS[@]}")
    echo "可用 jail："
    for i in "${!jail_names[@]}"; do
        echo "  $((i+1))) ${jail_names[$i]}"
    done
    read -rp "请输入 jail 名称或序号: " input
    [[ -z "$input" ]] && return

    if [[ "$input" =~ ^[0-9]+$ ]]; then
        local idx=$((input-1))
        if [[ $idx -ge 0 && $idx -lt ${#jail_names[@]} ]]; then
            jail="${jail_names[$idx]}"
        else
            print_error "无效序号"
            return
        fi
    else
        jail="$input"
        if [[ ! " ${jail_names[*]} " =~ " ${jail} " ]]; then
            print_error "jail '$jail' 不存在"
            return
        fi
    fi

    read -rp "输入 IP: " ip
    [[ -z "$ip" ]] && return
    "$FAIL2BAN_BIN" set "$jail" banip "$ip" && print_info "已封禁 $ip" || print_error "封禁失败"
}

unban_ip() {
    refresh_status
    if [[ $F2B_JAIL_COUNT -eq 0 ]]; then
        print_warn "当前无可用 jail"
        return
    fi

    local jail_names=("${!F2B_JAIL_STATUS[@]}")
    echo "可用 jail："
    for i in "${!jail_names[@]}"; do
        echo "  $((i+1))) ${jail_names[$i]}"
    done
    read -rp "请输入 jail 名称或序号: " input
    [[ -z "$input" ]] && return

    if [[ "$input" =~ ^[0-9]+$ ]]; then
        local idx=$((input-1))
        if [[ $idx -ge 0 && $idx -lt ${#jail_names[@]} ]]; then
            jail="${jail_names[$idx]}"
        else
            print_error "无效序号"
            return
        fi
    else
        jail="$input"
        if [[ ! " ${jail_names[*]} " =~ " ${jail} " ]]; then
            print_error "jail '$jail' 不存在"
            return
        fi
    fi

    read -rp "输入 IP: " ip
    [[ -z "$ip" ]] && return
    "$FAIL2BAN_BIN" set "$jail" unbanip "$ip" && print_info "已解封 $ip" || print_error "解封失败"
}

jail_toggle() {
    local jail="$1"
    local enabled=$(INI_GET /etc/fail2ban/jail.local "$jail" enabled)
    if [[ "$enabled" == "true" ]]; then
        INI_SET /etc/fail2ban/jail.local "$jail" enabled "false"
        print_info "已禁用 $jail"
    else
        INI_SET /etc/fail2ban/jail.local "$jail" enabled "true"
        print_info "已启用 $jail"
    fi
    restart_and_diagnose
}

jail_management_menu() {
    while true; do
        clear_screen
        print_title_bar "Jail 管理"
        detect_fail2ban || { print_error "Fail2ban 未安装"; pause; return; }
        local all_jails=$(awk -F'[][]' '/^[[:space:]]*\[.*\]/{print $2}' /etc/fail2ban/jail.conf 2>/dev/null | grep -vE 'DEFAULT|INCLUDES')
        [[ -z "$all_jails" ]] && { print_warn "未找到 jail 定义"; pause; return; }
        echo "所有 Jail (序号切换启用状态)："
        local i=1
        declare -A jmap
        for j in $all_jails; do
            local status="禁用"
            [[ $(INI_GET /etc/fail2ban/jail.local "$j" enabled) == "true" ]] && status="${COLOR_GREEN}启用${COLOR_RESET}"
            echo -e "  $i) $j [$status]"
            jmap[$i]="$j"
            ((i++))
        done
        echo "  b) 返回"
        read -rp "选择: " c
        [[ "$c" == "b" ]] && break
        if [[ -n "${jmap[$c]}" ]]; then
            jail_toggle "${jmap[$c]}"
            pause
        else
            print_error "无效选择"; pause
        fi
    done
}

live_monitor() {
    trap 'echo -e "\n监控结束"; return' INT
    while true; do
        clear
        refresh_status
        echo -e "${COLOR_BLUE2}=========================================="
        echo "        Fail2ban 实时监控面板"
        echo -e "==========================================${COLOR_RESET}"
        echo "服务: $(systemctl is-active fail2ban)"
        echo "Jail 数量: $F2B_JAIL_COUNT  总封禁: $F2B_BAN_TOTAL"
        for j in "${!F2B_JAIL_STATUS[@]}"; do
            echo "  $j: ${F2B_JAIL_STATUS[$j]}"
        done
        if [[ ${#FAILED_JAILS[@]} -gt 0 ]]; then
            echo -e "${COLOR_RED}启动失败的 Jail:${COLOR_RESET}"
            for fail in "${FAILED_JAILS[@]}"; do echo "  $fail"; done
        fi
        echo "------------------------------------------"
        echo "最近攻击日志 (5行):"
        if [[ -n "$F2B_LOGFILE" && -f "$F2B_LOGFILE" ]]; then
            tail -5 "$F2B_LOGFILE" 2>/dev/null
        else
            journalctl -u fail2ban -n 5 --no-pager
        fi
        sleep 5
    done
}

log_analysis() {
    [[ ! -f "$F2B_LOGFILE" ]] && { print_error "日志文件不存在"; return; }
    print_title_bar "日志分析"
    echo "1) 封禁次数最多的 IP (前20):"
    grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$F2B_LOGFILE" | sort | uniq -c | sort -nr | head -20
    echo
    echo "2) 按天统计攻击次数:"
    grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' "$F2B_LOGFILE" | sort | uniq -c
    if command -v geoiplookup &>/dev/null; then
        echo "3) 攻击来源国家 (基于 GeoIP):"
        grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$F2B_LOGFILE" | sort -u | head -20 | while read ip; do
            echo "$ip: $(geoiplookup "$ip" | awk -F': ' '{print $2}')"
        done
    fi
}

restore_default() {
    read -rp "将清空所有自定义配置（备份到 .bak），继续？(y/N): " c
    [[ ! "$c" =~ ^[Yy] ]] && return
    local backup="/etc/fail2ban/jail.local.bak.$(date +%s)"
    cp /etc/fail2ban/jail.local "$backup" 2>/dev/null
    cat > /etc/fail2ban/jail.local <<< "[DEFAULT]"
    print_info "已恢复默认，重启验证..."
    restart_and_diagnose
}

view_jail_details() {
    refresh_status
    if [[ $F2B_JAIL_COUNT -eq 0 ]]; then
        print_warn "无活跃 jail"
        return
    fi

    local jail_names=("${!F2B_JAIL_STATUS[@]}")
    echo "活跃 jail："
    for i in "${!jail_names[@]}"; do
        echo "  $((i+1))) ${jail_names[$i]}"
    done
    read -rp "请输入 jail 名称或序号: " input
    [[ -z "$input" ]] && return

    if [[ "$input" =~ ^[0-9]+$ ]]; then
        local idx=$((input-1))
        if [[ $idx -ge 0 && $idx -lt ${#jail_names[@]} ]]; then
            jail="${jail_names[$idx]}"
        else
            print_error "无效序号"
            return
        fi
    else
        jail="$input"
        if [[ ! " ${jail_names[*]} " =~ " ${jail} " ]]; then
            print_error "jail '$jail' 不存在"
            return
        fi
    fi

    "$FAIL2BAN_BIN" status "$jail" 2>&1
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
    print_info "已设置延迟启动，立即重启验证..."
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

        echo -e "${COLOR_CYAN}当前状态：${COLOR_RESET}"
        if ! systemctl is-active fail2ban &>/dev/null; then
            echo -e "  ${COLOR_RED}Fail2ban 服务未运行${COLOR_RESET}"
        else
            echo "  服务: active  防火墙: $FIREWALL_BACKEND"
            echo "  Jail 数量: $F2B_JAIL_COUNT  总封禁 IP: $F2B_BAN_TOTAL"
            for j in "${!F2B_JAIL_STATUS[@]}"; do
                echo "    $j: ${F2B_JAIL_STATUS[$j]}"
            done
            if [[ ${#FAILED_JAILS[@]} -gt 0 ]]; then
                echo -e "${COLOR_RED}  ⚠️ 检测到启动失败的 jail:${COLOR_RESET}"
                for fail in "${FAILED_JAILS[@]}"; do
                    echo -e "    ${COLOR_RED}✗ $fail${COLOR_RESET}"
                done
            fi
        fi
        echo
        echo "环境: SSH日志=${SSH_LOGFILE:-未找到}  F2B日志=${F2B_LOGFILE:-未找到}"
        echo

        echo " 1) 安装 Fail2ban"
        echo " 2) 应用推荐安全配置"
        echo " 3) 重启 Fail2ban + 自动诊断"
        echo " 4) 手动封禁 IP"
        echo " 5) 手动解封 IP"
        echo " 6) Jail 管理 (启用/禁用)"
        echo " 7) 查看 Jail 详情"
        echo " 8) 查看 Fail2ban 日志 (tail -50)"
        echo " 9) 实时攻击监控"
        echo "10) 日志分析"
        echo "11) 手动编辑 jail.local"
        echo "12) 切换防火墙后端"
        echo "13) 恢复默认配置"
        echo "14) 永久修复开机丢失 Jail"
        echo "15) 卸载 Fail2ban"
        echo "16) 一键诊断+自动修复环境"
        echo " 0) 退出"
        read -rp "请选择: " opt
        case "$opt" in
            1) install_fail2ban; pause ;;
            2) apply_recommended; pause ;;
            3) restart_and_diagnose; pause ;;
            4) ban_ip; pause ;;
            5) unban_ip; pause ;;
            6) jail_management_menu; pause ;;
            7) view_jail_details; pause ;;
            8) [[ -f "$F2B_LOGFILE" ]] && tail -50 "$F2B_LOGFILE" || journalctl -u fail2ban -n 50 --no-pager; pause ;;
            9) live_monitor ;;
           10) log_analysis; pause ;;
           11) nano /etc/fail2ban/jail.local; restart_and_diagnose; pause ;;
           12) echo "当前后端: $FIREWALL_BACKEND"; echo "可选: ufw / nftables-multiport / iptables-multiport"; read -rp "输入: " newba; [[ -n "$newba" ]] && { INI_SET /etc/fail2ban/jail.local DEFAULT banaction "$newba"; restart_and_diagnose; }; pause ;;
           13) restore_default; pause ;;
           14) fix_boot_order; pause ;;
           15)
                read -rp "确认卸载? (yes/NO): " c
                if [[ "$c" == "yes" ]]; then
                    systemctl stop fail2ban; systemctl disable fail2ban
                    apt purge -y fail2ban 2>/dev/null || dnf remove -y fail2ban 2>/dev/null || true
                    rm -rf /etc/fail2ban
                    print_info "已卸载"
                fi; pause ;;
           16) auto_diagnose_and_fix; pause ;;
            0) exit 0 ;;
            *) print_error "无效选项"; pause ;;
        esac
    done
}

require_root
main_menu
