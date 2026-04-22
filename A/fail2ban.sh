#!/usr/bin/env bash
# Fail2ban 完全管理面板
# 适配：UFW / nftables
# 需要 root 权限

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

#######################################
# 环境检测
#######################################

FAIL2BAN_BIN=""
FIREWALL_BACKEND=""   # ufw / nftables / unknown

detect_fail2ban() {
    if command -v fail2ban-client >/dev/null 2>&1; then
        FAIL2BAN_BIN="$(command -v fail2ban-client)"
        return 0
    fi
    FAIL2BAN_BIN=""
    return 1
}

detect_firewall_backend() {
    # 优先检测 nftables
    if command -v nft >/dev/null 2>&1; then
        FIREWALL_BACKEND="nftables"
        return 0
    fi
    # 再检测 UFW
    if command -v ufw >/dev/null 2>&1; then
        FIREWALL_BACKEND="ufw"
        return 0
    fi
    FIREWALL_BACKEND="unknown"
    return 1
}

show_environment_status() {
    detect_fail2ban
    detect_firewall_backend

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

fail2ban_show_logs() {
    print_title_bar "Fail2ban 日志 (tail -n 50)"
    local log_file=""

    # 常见日志路径
    if [[ -f /var/log/fail2ban.log ]]; then
        log_file="/var/log/fail2ban.log"
    elif [[ -f /var/log/fail2ban/fail2ban.log ]]; then
        log_file="/var/log/fail2ban/fail2ban.log"
    else
        print_error "未找到 Fail2ban 日志文件。"
        return
    fi

    tail -n 50 "$log_file"
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

    # 服务状态
    local svc_status
    svc_status=$(systemctl is-active fail2ban 2>/dev/null)

    case "$svc_status" in
        active)   F2B_STATUS="active (运行中)" ;;
        inactive) F2B_STATUS="inactive (未运行)" ;;
        failed)   F2B_STATUS="failed (失败)" ;;
        *)        F2B_STATUS="未知" ;;
    esac

    # jail 列表
    local jails
    jails=$(fail2ban-client status 2>/dev/null | awk -F': ' '/Jail list:/ {print $2}' | tr ',' ' ' | xargs)
    F2B_JAIL_LIST="$jails"

    # jail 数量
    if [[ -n "$jails" ]]; then
        F2B_JAIL_COUNT=$(echo "$jails" | wc -w)
    else
        F2B_JAIL_COUNT=0
    fi

    # ban 数量
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

#######################################
# Fail2ban 封禁 / 解封 IP
#######################################

fail2ban_list_jails() {
    fail2ban-client status 2>/dev/null | awk -F': ' '/Jail list:/ {print $2}' | tr ',' ' ' | xargs
}

fail2ban_ban_ip() {
    print_title_bar "禁封 IP"
    if ! detect_fail2ban; then
        print_error "Fail2ban 未安装。"
        return
    fi

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
    if ! detect_fail2ban; then
        print_error "Fail2ban 未安装。"
        return
    fi

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
# Fail2ban 防火墙后端选择 (UFW / nftables)
#######################################

ensure_jail_local() {
    # 确保 /etc/fail2ban/jail.local 存在
    if [[ ! -f /etc/fail2ban/jail.local ]]; then
        mkdir -p /etc/fail2ban
        touch /etc/fail2ban/jail.local
        echo "[DEFAULT]" > /etc/fail2ban/jail.local
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
            # Fail2ban 默认 nftables 动作名称通常为 nftables-multiport
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

    # 修改 /etc/fail2ban/jail.local 中的 banaction
    if grep -qE '^\s*banaction\s*=' /etc/fail2ban/jail.local; then
        sed -i "s/^\s*banaction\s*=.*/banaction = ${banaction}/" /etc/fail2ban/jail.local
    else
        # 确保在 [DEFAULT] 段落中追加
        if ! grep -q "^

\[DEFAULT\]

" /etc/fail2ban/jail.local; then
            echo "[DEFAULT]" >> /etc/fail2ban/jail.local
        fi
        echo "banaction = ${banaction}" >> /etc/fail2ban/jail.local
    fi

    print_info "已将 Fail2ban 封禁后端设置为：${banaction}"
    print_info "重启 Fail2ban 以生效。"
    systemctl restart fail2ban >/dev/null 2>&1 || print_warn "Fail2ban 重启失败，请手动检查。"
}
banneer() {
  echo -e "${BOLD}${GRAD1}╔════════════════════════════════════════════════╗"
  echo -e "${GRAD2}║                      CATMI                   ║"
  echo -e "${GRAD3}╚════════════════════════════════════════════════╝${RESET}"

  echo -e "                       ${CYAN}|\\__/,|   (\\\\${RESET}"
  echo -e "                     ${CYAN}_.|o o  |_   ) )${RESET}"
  echo -e "       ${CYAN}-------------(((---(((-------------------${RESET}"
}
#######################################
# 主菜单
#######################################

main_menu() {
    while true; do
        clear_screen
        print_title_bar "Fail2ban 完全管理面板"
        banneer
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
        echo "2) 查看 Fail2ban 状态"
        echo "3) 禁封 IP"
        echo "4) 解封 IP"
        echo "5) 查看 Fail2ban 日志"
        echo "6) 重启 Fail2ban 服务"
        echo "7) 选择 Fail2ban 使用 UFW 或 nftables 封禁"
        echo "8) 删除 Fail2ban"
        echo "9) 退出"
        echo

        read -rp "请选择 [1-9]: " opt
        case "$opt" in
            1) install_fail2ban; pause ;;
            2) fail2ban_status; pause ;;
            3) fail2ban_ban_ip; pause ;;
            4) fail2ban_unban_ip; pause ;;
            5) fail2ban_show_logs; pause ;;
            6) fail2ban_restart; pause ;;
            7) set_fail2ban_backend; pause ;;
            8) uninstall_fail2ban; pause ;;
            9) print_info "已退出。"; exit 0 ;;
            *) print_error "无效选择。"; pause ;;
        esac
    done
}

#######################################
# 入口
#######################################

require_root
main_menu
