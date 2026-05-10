#!/usr/bin/env bash
# Fail2ban 完全管理面板 (增强版)
# 适配：UFW / nftables
# 需要 root 权限
# 功能：环境检测、服务管理、Jail管理、高级安全策略、日志分析、实时监控、一键恢复

set -o pipefail

#######################################
# 基础 UI & 工具函数
#######################################

# 颜色
COLOR_RESET="\033[0m"
COLOR_BLUE1="\033[38;5;33m"
COLOR_BLUE2="\033[38;5;39m"
COLOR_BLUE3="\033[38;5;45m"
COLOR_CYAN="\033[36m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_RED="\033[31m"
COLOR_GRAY="\033[90m"
COLOR_WHITE="\033[37m"

print_info() {
    echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET} $*"
}

print_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"
}

print_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*"
}

print_title_bar() {
    local text="$1"
    local width=70
    local pad_len=$(( (width - ${#text}) / 2 ))
    local pad=""
    for _ in $(seq 1 $pad_len); do pad="${pad} "; done
    echo -e "${COLOR_BLUE1}======================================================================${COLOR_RESET}"
    echo -e "${COLOR_BLUE2}${pad}${text}${COLOR_RESET}"
    echo -e "${COLOR_BLUE3}======================================================================${COLOR_RESET}"
}

clear_screen() {
    command -v clear >/dev/null 2>&1 && clear || printf "\n\n"
}

pause() {
    echo
    read -rp "按回车键继续..." _
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "请以 root 身份运行此脚本。"
        exit 1
    fi
}

banner() {
    echo -e "${COLOR_YELLOW}${COLOR_GREEN}╔════════════════════════════════════════════════╗"
    echo -e "${COLOR_GREEN}║                      CATMI                   ║"
    echo -e "${COLOR_GREEN}╚════════════════════════════════════════════════╝${COLOR_CYAN}"
    echo -e "                       ${COLOR_GREEN}|\\__/,|   (\\\\${COLOR_CYAN}"
    echo -e "                     ${COLOR_GREEN}_.|o o  |_   ) )${COLOR_CYAN}"
    echo -e "       ${COLOR_GREEN}-------------(((---(((-------------------${COLOR_CYAN}"
}

#######################################
# 全局变量 (运行时刷新)
#######################################
F2B_STATUS="未知"
F2B_JAIL_COUNT=0
F2B_BAN_COUNT=0
F2B_JAIL_LIST=""

FAIL2BAN_BIN=""
FIREWALL_BACKEND="unknown"   # ufw / nftables / unknown
SSH_PORT="22"
SSHD_CONFIG="/etc/ssh/sshd_config"

#######################################
# 环境检测
#######################################
detect_fail2ban() {
    if command -v fail2ban-client >/dev/null 2>&1; then
        FAIL2BAN_BIN="$(command -v fail2ban-client)"
        return 0
    fi
    FAIL2BAN_BIN=""
    return 1
}

detect_firewall_backend() {
    if command -v nft >/dev/null 2>&1; then
        FIREWALL_BACKEND="nftables"
        return 0
    fi
    if command -v ufw >/dev/null 2>&1; then
        FIREWALL_BACKEND="ufw"
        return 0
    fi
    FIREWALL_BACKEND="unknown"
    return 1
}

detect_ssh_port() {
    # 从 sshd_config 读取端口，若未找到则默认 22
    if [[ -f "$SSHD_CONFIG" ]]; then
        local port
        port=$(grep -E "^Port\s+" "$SSHD_CONFIG" | awk '{print $2}' | head -1)
        if [[ -n "$port" ]]; then
            SSH_PORT="$port"
            return 0
        fi
    fi
    SSH_PORT="22"
    return 0
}

get_fail2ban_runtime_info() {
    detect_fail2ban
    if [[ -z "$FAIL2BAN_BIN" ]]; then
        F2B_STATUS="未安装"
        F2B_JAIL_COUNT=0
        F2B_BAN_COUNT=0
        F2B_JAIL_LIST=""
        return
    fi

    local svc_status
    svc_status=$(systemctl is-active fail2ban 2>/dev/null)

    case "$svc_status" in
        active)   F2B_STATUS="active (运行中)" ;;
        inactive) F2B_STATUS="inactive (未运行)" ;;
        failed)   F2B_STATUS="failed (失败)" ;;
        *)        F2B_STATUS="未知" ;;
    esac

    local jails
    jails=$(fail2ban-client status 2>/dev/null | awk -F': ' '/Jail list:/ {print $2}' | tr ',' ' ' | xargs)
    F2B_JAIL_LIST="$jails"

    if [[ -n "$jails" ]]; then
        F2B_JAIL_COUNT=$(echo "$jails" | wc -w)
    else
        F2B_JAIL_COUNT=0
    fi

    local total=0
    if [[ -n "$jails" ]]; then
        for j in $jails; do
            local c
            c=$(fail2ban-client status "$j" 2>/dev/null | awk -F': ' '/Currently banned:/ {print $2}')
            total=$((total + c))
        done
    fi
    F2B_BAN_COUNT=$total
}

detect_log_path() {
    # 返回系统中主要的 fail2ban 日志路径，若都不存在返回空
    if [[ -f /var/log/fail2ban.log ]]; then
        echo "/var/log/fail2ban.log"
    elif [[ -f /var/log/fail2ban/fail2ban.log ]]; then
        echo "/var/log/fail2ban/fail2ban.log"
    else
        echo ""
    fi
}

show_environment_status() {
    detect_fail2ban
    detect_firewall_backend
    detect_ssh_port
    local log_path
    log_path=$(detect_log_path)

    echo -e "${COLOR_CYAN}当前环境检测结果：${COLOR_RESET}"
    if [[ -n "$FAIL2BAN_BIN" ]]; then
        echo -e "  - Fail2ban：${COLOR_GREEN}已安装${COLOR_RESET} (${FAIL2BAN_BIN})"
    else
        echo -e "  - Fail2ban：${COLOR_RED}未安装${COLOR_RESET}"
    fi

    case "$FIREWALL_BACKEND" in
        ufw)
            echo -e "  - 防火墙：${COLOR_GREEN}UFW${COLOR_RESET}"
            ;;
        nftables)
            echo -e "  - 防火墙：${COLOR_GREEN}nftables${COLOR_RESET}"
            ;;
        *)
            echo -e "  - 防火墙：${COLOR_RED}未检测到 UFW 或 nftables${COLOR_RESET}"
            ;;
    esac

    echo -e "  - SSH 端口：${COLOR_GREEN}${SSH_PORT}${COLOR_RESET}"
    if [[ -n "$log_path" ]]; then
        echo -e "  - Fail2ban 日志：${COLOR_GREEN}${log_path}${COLOR_RESET}"
    else
        echo -e "  - Fail2ban 日志：${COLOR_RED}未找到${COLOR_RESET}"
    fi
}

#######################################
# Fail2ban 安装 / 卸载
#######################################

install_fail2ban() {
    detect_fail2ban
    if [[ -n "$FAIL2BAN_BIN" ]]; then
        print_info "Fail2ban 已安装，无需重复安装。"
        return
    fi

    print_title_bar "安装 Fail2ban"
    echo -e "${COLOR_GRAY}将使用系统包管理器安装 fail2ban...${COLOR_RESET}"

    if command -v apt >/dev/null 2>&1; then
        apt update && apt install -y fail2ban
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y fail2ban
    elif command -v yum >/dev/null 2>&1; then
        yum install -y fail2ban
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y fail2ban
    else
        print_error "未找到支持的包管理器，请手动安装 Fail2ban。"
        return
    fi

    if detect_fail2ban; then
        print_info "Fail2ban 安装成功。"
        systemctl enable fail2ban >/dev/null 2>&1 || true
        systemctl start fail2ban >/dev/null 2>&1 || true
    else
        print_error "Fail2ban 安装失败，请检查。"
    fi
}

uninstall_fail2ban() {
    detect_fail2ban
    if [[ -z "$FAIL2BAN_BIN" ]]; then
        print_warn "Fail2ban 未安装，无需删除。"
        return
    fi

    print_title_bar "删除 Fail2ban"
    read -rp "确认要卸载 Fail2ban 并删除配置文件？(yes/NO): " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "已取消卸载。"
        return
    fi

    systemctl stop fail2ban >/dev/null 2>&1 || true
    systemctl disable fail2ban >/dev/null 2>&1 || true

    if command -v apt >/dev/null 2>&1; then
        apt remove -y fail2ban
        apt purge -y fail2ban
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y fail2ban
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y fail2ban
    elif command -v zypper >/dev/null 2>&1; then
        zypper remove -y fail2ban
    else
        print_error "未找到支持的包管理器，请手动卸载 Fail2ban。"
        return
    fi

    rm -rf /etc/fail2ban 2>/dev/null || true

    print_info "Fail2ban 已卸载。"
}

#######################################
# Fail2ban 基本操作
#######################################

fail2ban_status() {
    print_title_bar "Fail2ban 状态"
    if ! detect_fail2ban; then
        print_error "Fail2ban 未安装。"
        return
    fi

    systemctl status fail2ban --no-pager
}

fail2ban_restart() {
    print_title_bar "重启 Fail2ban 服务"
    if ! detect_fail2ban; then
        print_error "Fail2ban 未安装。"
        return
    fi

    systemctl restart fail2ban
    if [[ $? -eq 0 ]]; then
        print_info "Fail2ban 已重启。"
    else
        print_error "Fail2ban 重启失败，请检查日志。"
    fi
}

fail2ban_start() {
    if ! detect_fail2ban; then print_error "Fail2ban 未安装."; return; fi
    systemctl start fail2ban && print_info "Fail2ban 已启动。" || print_error "启动失败。"
}

fail2ban_stop() {
    if ! detect_fail2ban; then print_error "Fail2ban 未安装."; return; fi
    systemctl stop fail2ban && print_info "Fail2ban 已停止。" || print_error "停止失败。"
}

fail2ban_show_logs() {
    print_title_bar "Fail2ban 日志 (tail -n 50)"
    local log_file
    log_file=$(detect_log_path)

    if [[ -z "$log_file" ]]; then
        print_error "未找到 Fail2ban 日志文件。"
        return
    fi

    tail -n 50 "$log_file"
}

fail2ban_list_jails() {
    fail2ban-client status 2>/dev/null | awk -F': ' '/Jail list:/ {print $2}' | tr ',' ' ' | xargs
}

fail2ban_ban_ip() {
    print_title_bar "禁封 IP"
    if ! detect_fail2ban; then print_error "Fail2ban 未安装."; return; fi

    local jails ip
    jails=$(fail2ban_list_jails)
    if [[ -z "$jails" ]]; then
        print_warn "当前没有启用的 jail。"
        return
    fi

    echo "当前可用 jail："
    echo "  $jails"
    read -rp "请输入要操作的 jail 名称（留空取消）: " jail
    [[ -z "$jail" ]] && { print_info "已取消。"; return; }

    read -rp "请输入要封禁的 IP（留空取消）: " ip
    [[ -z "$ip" ]] && { print_info "已取消。"; return; }

    fail2ban-client set "$jail" banip "$ip"
    if [[ $? -eq 0 ]]; then
        print_info "已在 jail [$jail] 中封禁 IP：$ip"
    else
        print_error "封禁失败，请检查 jail 名称和 IP。"
    fi
}

fail2ban_unban_ip() {
    print_title_bar "解封 IP"
    if ! detect_fail2ban; then print_error "Fail2ban 未安装."; return; fi

    local jails ip
    jails=$(fail2ban_list_jails)
    if [[ -z "$jails" ]]; then
        print_warn "当前没有启用的 jail。"
        return
    fi

    echo "当前可用 jail："
    echo "  $jails"
    read -rp "请输入要操作的 jail 名称（留空取消）: " jail
    [[ -z "$jail" ]] && { print_info "已取消。"; return; }

    read -rp "请输入要解封的 IP（留空取消）: " ip
    [[ -z "$ip" ]] && { print_info "已取消。"; return; }

    fail2ban-client set "$jail" unbanip "$ip"
    if [[ $? -eq 0 ]]; then
        print_info "已在 jail [$jail] 中解封 IP：$ip"
    else
        print_error "解封失败，请检查 jail 名称和 IP。"
    fi
}

#######################################
# Jail 管理模块
#######################################

# 解析所有 jail 名称 (包括禁用的)
get_all_jail_names() {
    local conf_file="/etc/fail2ban/jail.conf"
    if [[ -f "$conf_file" ]]; then
        grep -E '^\s*\[[^]]+\]' "$conf_file" | tr -d '[' | tr -d ']' | grep -v '^\(DEFAULT\|INCLUDES\)' | sort -u
    else
        # 如果无 jail.conf 则尝试使用 fail2ban-client 查询
        fail2ban-client status 2>/dev/null | awk '/Jail list:/ {print $3}' | tr ',' ' '
    fi
}

# 判断指定 jail 是否启用 (通过检查 jail.local 中是否有 enabled = true)
is_jail_enabled() {
    local jail="$1"
    local file="/etc/fail2ban/jail.local"
    if [[ ! -f "$file" ]]; then
        return 1  # 未启用
    fi
    # 提取 jail 段落，检查 enabled 值
    awk -v jail="$jail" '
        BEGIN { found=0; enabled=0; }
        /^[[:space:]]*\[/ {
            gsub(/[[:space:]]*/, "")
            if ($0 == "["jail"]") { found=1; next }
            else { found=0 }
        }
        found && /^[[:space:]]*enabled[[:space:]]*=/ {
            val=$0
            gsub(/^[[:space:]]*enabled[[:space:]]*=[[:space:]]*/, "", val)
            gsub(/[[:space:]]*$/, "", val)
            if (val == "true" || val == "1" || val == "yes") enabled=1
            exit
        }
        END { exit (enabled ? 0 : 1) }
    ' "$file"
    return $?
}

# 切换 jail 启用/禁用状态
toggle_jail() {
    local jail="$1"
    local file="/etc/fail2ban/jail.local"
    mkdir -p /etc/fail2ban
    if [[ ! -f "$file" ]]; then
        echo "[DEFAULT]" > "$file"
    fi

    if is_jail_enabled "$jail"; then
        # 当前启用 -> 禁用
        print_info "正在禁用 jail: $jail"
        # 查找是否已有该 jail 段落，若有则修改 enabled 值，否则添加段落
        if grep -qE "^\s*\[${jail}\]" "$file"; then
            # 段落存在，修改 enabled 行
            sed -i "/^\s*\[${jail}\]/,/^\s*\[/ s/^\s*enabled\s*=.*/enabled = false/" "$file"
        else
            # 添加段落
            echo "" >> "$file"
            echo "[$jail]" >> "$file"
            echo "enabled = false" >> "$file"
        fi
    else
        print_info "正在启用 jail: $jail"
        if grep -qE "^\s*\[${jail}\]" "$file"; then
            sed -i "/^\s*\[${jail}\]/,/^\s*\[/ s/^\s*enabled\s*=.*/enabled = true/" "$file"
        else
            echo "" >> "$file"
            echo "[$jail]" >> "$file"
            echo "enabled = true" >> "$file"
        fi
    fi

    # 重启 Fail2ban 使生效
    systemctl restart fail2ban 2>/dev/null
    if [[ $? -eq 0 ]]; then
        print_info "Fail2ban 已重启，修改已生效。"
    else
        print_warn "Fail2ban 重启失败，请手动检查。"
    fi
}

jail_management_menu() {
    while true; do
        clear_screen
        print_title_bar "Jail 管理"
        if ! detect_fail2ban; then
            print_error "Fail2ban 未安装。"
            pause
            return
        fi

        local all_jails
        all_jails=$(get_all_jail_names)
        if [[ -z "$all_jails" ]]; then
            print_warn "未找到任何 jail 定义。"
            pause
            return
        fi

        echo "当前所有可用的 Jail："
        local idx=1
        declare -A JAIL_MAP
        for j in $all_jails; do
            local status="禁用"
            if is_jail_enabled "$j"; then
                status="${COLOR_GREEN}启用${COLOR_RESET}"
            else
                status="${COLOR_GRAY}禁用${COLOR_RESET}"
            fi
            echo -e "  ${idx}) $j  [$status]"
            JAIL_MAP["$idx"]="$j"
            idx=$((idx+1))
        done
        echo "  r) 重新加载列表"
        echo "  b) 返回主菜单"
        echo
        read -rp "请输入序号切换启用/禁用 (例如: 1)，或选择 b/r: " choice

        case "$choice" in
            b|B) break ;;
            r|R) continue ;;
            *)
                if [[ -n "${JAIL_MAP[$choice]}" ]]; then
                    toggle_jail "${JAIL_MAP[$choice]}"
                    pause
                else
                    print_error "无效选择。"
                    pause
                fi
                ;;
        esac
    done
}

# 查看指定 jail 的详细信息 (封禁 IP 列表)
view_jail_details() {
    if ! detect_fail2ban; then print_error "Fail2ban 未安装."; return; fi

    local jails ip jail
    jails=$(fail2ban_list_jails)
    if [[ -z "$jails" ]]; then
        print_warn "当前没有启用的 jail。"
        return
    fi

    echo "启用的 jail："
    echo "  $jails"
    read -rp "请输入要查看的 jail 名称（留空取消）: " jail
    [[ -z "$jail" ]] && { print_info "已取消。"; return; }

    echo -e "${COLOR_CYAN}------ Jail: $jail 详细信息 ------${COLOR_RESET}"
    fail2ban-client status "$jail" 2>/dev/null || print_error "无法获取 jail 信息。"
    pause
}

#######################################
# 高级安全策略配置
#######################################

edit_default_config() {
    local file="/etc/fail2ban/jail.local"
    if [[ ! -f "$file" ]]; then
        mkdir -p /etc/fail2ban
        echo "[DEFAULT]" > "$file"
    fi

    # 确保有 [DEFAULT] 段落
    if ! grep -qE '^\s*\[DEFAULT\]' "$file"; then
        sed -i '1i [DEFAULT]' "$file"
    fi

    print_title_bar "高级安全策略配置"
    echo "当前 [DEFAULT] 配置："
    grep -E '^\s*(bantime|findtime|maxretry|bantime\.increment|bantime\.factor|bantime\.maxtime|banaction)\s*=' "$file" 2>/dev/null || echo "(尚未设置)"
    echo
    echo "可配置参数说明："
    echo "  bantime          封禁时长 (例如: 600, 1h, 1d)"
    echo "  findtime         检测时间窗口 (例如: 600)"
    echo "  maxretry         最大重试次数"
    echo "  bantime.increment 递增封禁开关 (true/false)"
    echo "  bantime.maxtime 最大封禁时长 (例如: 1w)"
    echo "  bantime.factor   递增因子 (例如: 2)"
    echo "  还有其他 jail 专属参数..."
    echo
    read -rp "是否直接编辑 jail.local 文件？(需要 vi 或 nano) [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if command -v nano >/dev/null 2>&1; then
            nano "$file"
        elif command -v vi >/dev/null 2>&1; then
            vi "$file"
        else
            print_error "未找到编辑器 (vi/nano)。"
            return
        fi
        print_info "配置已更新。建议重启 Fail2ban 使其生效。"
        read -rp "是否现在重启 Fail2ban？[y/N]: " restart
        if [[ "$restart" =~ ^[Yy]$ ]]; then
            systemctl restart fail2ban && print_info "已重启。" || print_error "重启失败。"
        fi
    else
        print_info "取消编辑。"
    fi
}

# 一键设置推荐配置
quick_recommended_config() {
    print_title_bar "推荐安全配置"
    echo "将应用以下推荐参数到 [DEFAULT] (bantime=1h, findtime=600, maxretry=5, bantime.increment=true)"
    echo "并启用 recidive jail (需要手动确保 jail.conf 中存在 recidive 定义)。"
    read -rp "确认应用推荐配置？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消。"
        return
    fi

    local file="/etc/fail2ban/jail.local"
    mkdir -p /etc/fail2ban
    if [[ ! -f "$file" ]]; then
        echo "[DEFAULT]" > "$file"
    fi

    # 删除旧的 DEFAULT 段落中的这几个参数 (保留其他)
    sed -i '/^\[DEFAULT\]/,/^\[/ {
        /^bantime\s*=/d
        /^findtime\s*=/d
        /^maxretry\s*=/d
        /^bantime\.increment\s*=/d
        /^bantime\.maxtime\s*=/d
    }' "$file"

    # 在 DEFAULT 段落后添加
    sed -i '/^\[DEFAULT\]/a bantime = 1h\nfindtime = 600\nmaxretry = 5\nbantime.increment = true\nbantime.maxtime = 1w' "$file"

    # 尝试启用 recidive jail
    if ! grep -qE '^\s*\[recidive\]' "$file"; then
        cat >> "$file" << 'EOF'

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime  = 1w
findtime = 1d
maxretry = 3
EOF
    else
        sed -i '/^\s*\[recidive\]/,/^\s*\[/ s/^\s*enabled\s*=.*/enabled = true/' "$file"
    fi

    print_info "推荐配置已写入。"
    systemctl restart fail2ban && print_info "Fail2ban 已重启。" || print_error "重启失败，请检查配置。"
}

#######################################
# 防火墙后端选择
#######################################

ensure_jail_local() {
    if [[ ! -f /etc/fail2ban/jail.local ]]; then
        mkdir -p /etc/fail2ban
        touch /etc/fail2ban/jail.local
        echo "[DEFAULT]" >> /etc/fail2ban/jail.local
    fi
}

set_fail2ban_backend() {
    print_title_bar "选择 Fail2ban 防火墙后端"

    if ! detect_fail2ban; then
        print_error "Fail2ban 未安装。"
        return
    fi

    detect_firewall_backend

    echo "检测到的防火墙：$FIREWALL_BACKEND"
    echo
    echo "1) 使用 UFW 封禁"
    echo "2) 使用 nftables 封禁"
    echo "3) 取消"
    echo
    read -rp "请选择 [1-3]: " choice

    local banaction=""
    case "$choice" in
        1)
            if ! command -v ufw >/dev/null 2>&1; then
                print_error "未检测到 UFW，无法选择。"
                return
            fi
            banaction="ufw"
            ;;
        2)
            if ! command -v nft >/dev/null 2>&1; then
                print_error "未检测到 nftables，无法选择。"
                return
            fi
            banaction="nftables-multiport"
            ;;
        3)
            print_info "已取消。"
            return
            ;;
        *)
            print_error "无效选择。"
            return
            ;;
    esac

    ensure_jail_local

    if grep -qE '^\s*banaction\s*=' /etc/fail2ban/jail.local; then
        sed -i "s/^\s*banaction\s*=.*/banaction = ${banaction}/" /etc/fail2ban/jail.local
    else
        if ! grep -qE '^\s*\[DEFAULT\]' /etc/fail2ban/jail.local; then
            echo "[DEFAULT]" >> /etc/fail2ban/jail.local
        fi
        echo "banaction = ${banaction}" >> /etc/fail2ban/jail.local
    fi

    print_info "已将 Fail2ban 封禁后端设置为：${banaction}"
    systemctl restart fail2ban >/dev/null 2>&1 || print_warn "Fail2ban 重启失败，请手动检查。"
}

#######################################
# 实时攻击监控
#######################################

live_monitor() {
    print_title_bar "实时攻击监控 (每 5 秒刷新，Ctrl+C 退出)"
    if ! detect_fail2ban; then print_error "Fail2ban 未安装."; return; fi

    trap 'echo -e "\n监控已停止。"; return' INT

    while true; do
        clear_screen
        get_fail2ban_runtime_info
        echo -e "${COLOR_BLUE2}"
        echo "=========================================="
        echo "        Fail2ban 实时监控面板"
        echo "=========================================="
        echo -e "${COLOR_RESET}"
        echo "服务状态 : $F2B_STATUS"
        echo "Jail 数  : $F2B_JAIL_COUNT  ($F2B_JAIL_LIST)"
        echo "封禁总数: $F2B_BAN_COUNT"
        echo "------------------------------------------"
        if [[ -n "$F2B_JAIL_LIST" ]]; then
            echo "当前各 Jail 封禁数："
            for j in $F2B_JAIL_LIST; do
                local c
                c=$(fail2ban-client status "$j" 2>/dev/null | awk -F': ' '/Currently banned:/ {print $2}')
                echo "  $j : $c"
            done
        fi
        echo "------------------------------------------"
        echo -e "最近攻击日志 (最后 5 行):${COLOR_GRAY}"
        local log_path
        log_path=$(detect_log_path)
        if [[ -n "$log_path" ]]; then
            tail -n 5 "$log_path" 2>/dev/null
        else
            echo "无日志。"
        fi
        echo -e "${COLOR_RESET}"
        sleep 5
    done
}

#######################################
# 日志分析模块
#######################################

log_analysis() {
    print_title_bar "Fail2ban 日志分析"
    local log_path
    log_path=$(detect_log_path)
    if [[ -z "$log_path" ]]; then
        print_error "未找到 Fail2ban 日志文件。"
        return
    fi

    echo "分析日志文件：$log_path"
    echo

    # 统计攻击 IP 次数 (提取找到的 IP)
    local tmpfile
    tmpfile=$(mktemp)
    grep -E '^\d{4}-\d{2}-\d{2}.*Ban\s+' "$log_path" 2>/dev/null | awk '{print $NF}' | sort | uniq -c | sort -nr > "$tmpfile"
    local ban_count
    ban_count=$(wc -l < "$tmpfile")

    echo "1) 封禁历史 (按次数排序，最多展示前20)"
    if [[ $ban_count -gt 0 ]]; then
        head -20 "$tmpfile"
    else
        echo "  无封禁记录。"
    fi
    echo

    # 统计国家？因为无 geoip 工具，可跳过或提示安装
    if command -v geoiplookup >/dev/null 2>&1; then
        echo "2) 攻击来源国家/地区 (基于 geoiplookup)"
        while read -r count ip; do
            local country
            country=$(geoiplookup "$ip" 2>/dev/null | awk -F': ' '{print $2}' | head -1)
            echo "  $count 次 - $ip -> ${country:-未知}"
        done < <(head -20 "$tmpfile")
    else
        echo "2) 攻击来源国家需安装 geoip-bin 工具。"
    fi
    echo

    # 攻击频率（按小时统计）
    echo "3) 攻击频率 (按天统计)"
    grep -E '^\d{4}-\d{2}-\d{2}.*Ban' "$log_path" | awk '{print $1}' | sort | uniq -c | sort -k2 > "$tmpfile.daily"
    cat "$tmpfile.daily"
    echo

    rm -f "$tmpfile" "$tmpfile.daily"
    pause
}

#######################################
# 一键恢复默认配置
#######################################

restore_default_config() {
    print_title_bar "恢复默认 Fail2ban 配置"
    if [[ ! -f /etc/fail2ban/jail.conf ]]; then
        print_warn "未找到 /etc/fail2ban/jail.conf，无法恢复。"
        return
    fi

    read -rp "此操作将备份当前 jail.local 并恢复为默认配置 (基于 jail.conf)。是否继续？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消。"
        return
    fi

    local backup="/etc/fail2ban/jail.local.bak.$(date +%s)"
    if [[ -f /etc/fail2ban/jail.local ]]; then
        cp /etc/fail2ban/jail.local "$backup"
        print_info "已备份当前配置至：$backup"
    fi

    # 生成默认 jail.local (注释掉所有配置，仅留几个必须项)
    cat > /etc/fail2ban/jail.local << 'EOF'
# 默认配置，清空所有自定义设定
[DEFAULT]
# 使用系统默认的后端，保持与 jail.conf 一致
# 若需要，可在此处覆盖
EOF

    print_info "jail.local 已重置为默认。"
    systemctl restart fail2ban && print_info "Fail2ban 已重启。" || print_warn "重启失败，请检查日志。"
}

#######################################
# 主菜单
#######################################

main_menu() {
    while true; do
        clear_screen
        print_title_bar "Fail2ban 完全管理面板"
        banner
        get_fail2ban_runtime_info

        echo -e "${COLOR_CYAN}Fail2ban 运行状况：${COLOR_RESET}"
        echo -e "  - 服务状态：${COLOR_GREEN}${F2B_STATUS}${COLOR_RESET}"
        echo -e "  - 启用的 jail 数量：${COLOR_BLUE2}${F2B_JAIL_COUNT}${COLOR_RESET}"
        [[ $F2B_JAIL_COUNT -gt 0 ]] && echo -e "    jail 列表：${COLOR_GRAY}${F2B_JAIL_LIST}${COLOR_RESET}"
        echo -e "  - 当前被封禁的 IP 总数：${COLOR_BLUE3}${F2B_BAN_COUNT}${COLOR_RESET}"
        echo

        show_environment_status
        echo

        echo -e "${COLOR_BLUE1}主菜单${COLOR_RESET}"
        echo "1) 安装 Fail2ban"
        echo "2) Fail2ban 服务操作 (启动/停止/重启/状态)"
        echo "3) Jail 管理 (启用/禁用/查看详情)"
        echo "4) 禁封 / 解封 IP"
        echo "5) 查看 Fail2ban 日志"
        echo "6) 高级安全策略配置"
        echo "7) 防火墙后端选择 (UFW / nftables)"
        echo "8) 实时攻击监控"
        echo "9) 日志分析"
        echo "10) 一键恢复默认配置"
        echo "11) 删除 Fail2ban"
        echo "12) 退出"
        echo

        read -rp "请选择 [1-12]: " opt
        case "$opt" in
            1) install_fail2ban; pause ;;
            2) service_submenu; pause ;;
            3) jail_management_menu; pause ;;
            4) ban_unban_submenu; pause ;;
            5) fail2ban_show_logs; pause ;;
            6) advanced_config_submenu; pause ;;
            7) set_fail2ban_backend; pause ;;
            8) live_monitor; pause ;;
            9) log_analysis; pause ;;
            10) restore_default_config; pause ;;
            11) uninstall_fail2ban; pause ;;
            12) print_info "已退出。"; exit 0 ;;
            *) print_error "无效选择。"; pause ;;
        esac
    done
}

service_submenu() {
    while true; do
        clear_screen
        print_title_bar "服务操作"
        echo "1) 启动 Fail2ban"
        echo "2) 停止 Fail2ban"
        echo "3) 重启 Fail2ban"
        echo "4) 查看状态"
        echo "5) 返回主菜单"
        read -rp "选择: " sopt
        case "$sopt" in
            1) fail2ban_start; pause ;;
            2) fail2ban_stop; pause ;;
            3) fail2ban_restart; pause ;;
            4) fail2ban_status; pause ;;
            5) break ;;
            *) print_error "无效选择。"; pause ;;
        esac
    done
}

ban_unban_submenu() {
    while true; do
        clear_screen
        print_title_bar "IP 封禁 / 解封"
        echo "1) 手动封禁 IP"
        echo "2) 手动解封 IP"
        echo "3) 查看 Jail 详细信息 (包含封禁列表)"
        echo "4) 返回主菜单"
        read -rp "选择: " bopt
        case "$bopt" in
            1) fail2ban_ban_ip; pause ;;
            2) fail2ban_unban_ip; pause ;;
            3) view_jail_details; pause ;;
            4) break ;;
            *) print_error "无效选择。"; pause ;;
        esac
    done
}

advanced_config_submenu() {
    while true; do
        clear_screen
        print_title_bar "高级安全策略"
        echo "1) 查看/手动编辑 jail.local"
        echo "2) 应用推荐安全配置"
        echo "3) 返回主菜单"
        read -rp "选择: " aopt
        case "$aopt" in
            1) edit_default_config; pause ;;
            2) quick_recommended_config; pause ;;
            3) break ;;
            *) print_error "无效选择。"; pause ;;
        esac
    done
}

#######################################
# 入口
#######################################
require_root
main_menu
