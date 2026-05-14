#!/bin/bash
# ===========================
#   Color & Style
# ===========================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
MAGENTA="\033[35m"
CYAN="\033[96m"
PLAIN="\033[0m"
BOLD="\033[1m"

line() { echo -e "${BLUE}──────────────────────────────────────────────────────────────${PLAIN}"; }

# ===========================
#   渐变标题（轻量不卡顿）
# ===========================
gradient() {
    text="$1"
    colors=("\033[38;5;45m" "\033[38;5;51m" "\033[38;5;87m" "\033[38;5;123m" "\033[38;5;159m")
    out=""
    i=0
    for ((n=0; n<${#text}; n++)); do
        out+="${colors[i]}${text:n:1}${PLAIN}"
        ((i=(i+1)%5))
    done
    echo -e "$out"
}

# ===========================
#   加载动画（优化版 0.2 秒）
# ===========================
loading() {
    bar=""
    for i in {1..20}; do
        bar="${bar}█"
        printf "\r\033[38;5;87m加载中 [%-20s]\033[0m" "$bar"
        sleep 0.015   # 更快
    done
    printf "\r\033[K"
}

# ===========================
#   系统信息（一次采集）
# ===========================
HOSTNAME_SHOW=$(hostname)
OS_VERSION=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
KERNEL_VERSION=$(uname -r)
ARCH=$(uname -m)

CPU_MODEL=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^ //')
CPU_CORES=$(grep -c ^processor /proc/cpuinfo)
CPU_FREQ="$(awk -F: '/cpu MHz/ {printf "%.1f GHz", $2/1000; exit}' /proc/cpuinfo)"

CPU_USAGE=$(awk -v FS=" " '/cpu /{printf "%.1f%%", 100 - ($5*100/($2+$3+$4+$5))}' /proc/stat)
LOAD_AVG=$(awk '{print $1", "$2", "$3}' /proc/loadavg)

TCP_CONN=$(grep -c '^ *[0-9]' /proc/net/tcp)
UDP_CONN=$(grep -c '^ *[0-9]' /proc/net/udp)

MEM_USED=$(free -m | awk '/Mem/ {printf "%.2fM", $3}')
MEM_TOTAL=$(free -m | awk '/Mem/ {printf "%.2fM", $2}')
MEM_PERCENT=$(free | awk '/Mem/ {printf "%.2f%%", $3/$2*100}')

SWAP_USED=$(free -m | awk '/Swap/ {printf "%.0fM", $3}')
SWAP_TOTAL=$(free -m | awk '/Swap/ {printf "%.0fM", $2}')

DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
DISK_PERCENT=$(df -h / | awk 'NR==2 {print $5}')

# ===========================
#   服务检测（精准版）
# ===========================
service_exists() {
    systemctl list-unit-files | grep -qw "$1.service"
}

svc_state() {
    if service_exists "$1"; then
        echo -e "${GREEN}已安装${PLAIN}"
    else
        echo -e "${RED}未安装${PLAIN}"
    fi
}

svc_running() {
    if systemctl is-active --quiet "$1"; then
        echo -e "${GREEN}运行中${PLAIN}"
    else
        echo -e "${RED}未运行${PLAIN}"
    fi
}

svc_enabled() {
    if systemctl is-enabled --quiet "$1"; then
        echo -e "${GREEN}已启用${PLAIN}"
    else
        echo -e "${YELLOW}未启用${PLAIN}"
    fi
}

# ===========================
#   UFW（特殊处理）
# ===========================
check_ufw() {
    if command -v ufw >/dev/null 2>&1; then
        ufw_installed="${GREEN}已安装${PLAIN}"
        if ufw status | grep -q "Status: active"; then
            ufw_running="${GREEN}运行中${PLAIN}"
        else
            ufw_running="${RED}未运行${PLAIN}"
        fi
        if systemctl is-enabled --quiet ufw; then
            ufw_enabled="${GREEN}已启用${PLAIN}"
        else
            ufw_enabled="${YELLOW}未启用${PLAIN}"
        fi
    else
        ufw_installed="${RED}未安装${PLAIN}"
        ufw_running="${RED}未运行${PLAIN}"
        ufw_enabled="${YELLOW}未启用${PLAIN}"
    fi
}

# ===========================
#   nftables（精准）
# ===========================
check_nft() {
    if command -v nft >/dev/null 2>&1; then
        nft_installed="${GREEN}已安装${PLAIN}"
        nft_running=$(svc_running nftables)
        nft_enabled=$(svc_enabled nftables)
    else
        nft_installed="${RED}未安装${PLAIN}"
        nft_running="${RED}未运行${PLAIN}"
        nft_enabled="${YELLOW}未启用${PLAIN}"
    fi
}

# ===========================
#   Xray / Mihomo 自动识别
# ===========================
detect_xray_service() {
    for svc in xrayls xray xray-core; do
        if systemctl list-unit-files | grep -qw "$svc.service"; then
            echo "$svc"
            return
        fi
    done
    echo ""
}

detect_mihomo_service() {
    for svc in mihomo mihomo-core clash; do
        if systemctl list-unit-files | grep -qw "$svc.service"; then
            echo "$svc"
            return
        fi
    done
    echo ""
}

# ===========================
#   刷新服务状态
# ===========================
refresh_services() {
    SYSTEMCTL_ACTIVE=$(systemctl list-units --type=service --no-pager)
    SYSTEMCTL_ENABLED=$(systemctl list-unit-files --type=service --no-pager)

    normalize() {
        echo "$1" | sed 's/-/_/g'
    }

    check_svc_fast() {
        local svc="$1"
        local var=$(normalize "$svc")
        if echo "$SYSTEMCTL_ENABLED" | grep -qw "${svc}.service"; then
            eval "${var}_installed=\"${GREEN}已安装${PLAIN}\""
        else
            eval "${var}_installed=\"${RED}未安装${PLAIN}\""
        fi
        if echo "$SYSTEMCTL_ACTIVE" | grep -qw "${svc}.service"; then
            eval "${var}_running=\"${GREEN}运行中${PLAIN}\""
        else
            eval "${var}_running=\"${RED}未运行${PLAIN}\""
        fi
        if echo "$SYSTEMCTL_ENABLED" | grep -qw "${svc}.service"; then
            eval "${var}_enabled=\"${GREEN}已启用${PLAIN}\""
        else
            eval "${var}_enabled=\"${YELLOW}未启用${PLAIN}\""
        fi
    }

    check_svc_fast docker
    check_svc_fast nginx
    check_svc_fast caddy
    check_svc_fast fail2ban
    check_svc_fast sing-box
    check_svc_fast hysteria-server

    check_ufw
    check_nft

    xray_svc=$(detect_xray_service)
    if [[ -n "$xray_svc" ]]; then
        xray_installed="${GREEN}已安装${PLAIN}"
        xray_running=$(echo "$SYSTEMCTL_ACTIVE" | grep -qw "${xray_svc}.service" && echo -e "${GREEN}运行中${PLAIN}" || echo -e "${RED}未运行${PLAIN}")
        xray_enabled=$(echo "$SYSTEMCTL_ENABLED" | grep -qw "${xray_svc}.service" && echo -e "${GREEN}已启用${PLAIN}" || echo -e "${YELLOW}未启用${PLAIN}")
    else
        xray_installed="${RED}未安装${PLAIN}"
        xray_running="${RED}未运行${PLAIN}"
        xray_enabled="${YELLOW}未启用${PLAIN}"
    fi

    mihomo_svc=$(detect_mihomo_service)
    if [[ -n "$mihomo_svc" ]]; then
        mihomo_installed="${GREEN}已安装${PLAIN}"
        mihomo_running=$(echo "$SYSTEMCTL_ACTIVE" | grep -qw "${mihomo_svc}.service" && echo -e "${GREEN}运行中${PLAIN}" || echo -e "${RED}未运行${PLAIN}")
        mihomo_enabled=$(echo "$SYSTEMCTL_ENABLED" | grep -qw "${mihomo_svc}.service" && echo -e "${GREEN}已启用${PLAIN}" || echo -e "${YELLOW}未启用${PLAIN}")
    else
        mihomo_installed="${RED}未安装${PLAIN}"
        mihomo_running="${RED}未运行${PLAIN}"
        mihomo_enabled="${YELLOW}未启用${PLAIN}"
    fi
}

# ===========================
#   主菜单（极速版）
# ===========================
main_menu() {
    clear
    echo -e "${GREEN}"
    cat << "EOF"
                        |\__/,|   (\
                      _.|o o  |_   ) )
        -------------(((---(((-------------------
EOF
    echo -e "${PLAIN}"

    gradient "                         Catmiup 面板 v3"
    line
    echo -e "${CYAN}┌────────────────────────── 系统信息 ─────────────────────────┐${PLAIN}"
    echo -e "  主机名:        ${GREEN}${HOSTNAME_SHOW}${PLAIN}"
    echo -e "  系统版本:      ${GREEN}${OS_VERSION}${PLAIN}"
    echo -e "  Linux版本:     ${GREEN}${KERNEL_VERSION}${PLAIN}"
    echo -e "${CYAN}├──────────────────────────────────────────────────────────────┤${PLAIN}"
    echo -e "  CPU架构:       ${GREEN}${ARCH}${PLAIN}"
    echo -e "  CPU型号:       ${GREEN}${CPU_MODEL}${PLAIN}"
    echo -e "  CPU核心数:     ${GREEN}${CPU_CORES}${PLAIN}"
    echo -e "  CPU频率:       ${GREEN}${CPU_FREQ}${PLAIN}"
    echo -e "${CYAN}├──────────────────────────────────────────────────────────────┤${PLAIN}"
    echo -e "  CPU占用:       ${GREEN}${CPU_USAGE}${PLAIN}"
    echo -e "  系统负载:      ${GREEN}${LOAD_AVG}${PLAIN}"
    echo -e "  TCP|UDP连接数: ${GREEN}${TCP_CONN}|${UDP_CONN}${PLAIN}"
    echo -e "  物理内存:      ${GREEN}${MEM_USED}/${MEM_TOTAL} (${MEM_PERCENT})${PLAIN}"
    echo -e "  虚拟内存:      ${GREEN}${SWAP_USED}/${SWAP_TOTAL}${PLAIN}"
    echo -e "  硬盘占用:      ${GREEN}${DISK_USED}/${DISK_TOTAL} (${DISK_PERCENT})${PLAIN}"
    echo -e "${CYAN}├────────────────────────── 服务状态 ─────────────────────────┤${PLAIN}"

    echo -e "  Docker:         ${docker_installed} | 状态: ${docker_running}"
    echo -e "  Nginx:          ${nginx_installed}  | 状态: ${nginx_running}"
    echo -e "  Caddy:          ${caddy_installed}  | 状态: ${caddy_running}"
    echo -e "${CYAN}├──────────────────────────────────────────────────────────────┤${PLAIN}"

    echo -e "  UFW:            ${ufw_installed} | 状态: ${ufw_running} | 启动: ${ufw_enabled}"
    echo -e "  nftables:       ${nft_installed} | 状态: ${nft_running} | 启动: ${nft_enabled}"
    echo -e "  Fail2ban:       ${fail2ban_installed} | 状态: ${fail2ban_running}"
    echo -e "${CYAN}├──────────────────────────────────────────────────────────────┤${PLAIN}"

    echo -e "  Xray:           ${xray_installed} | 状态: ${xray_running} | 启动: ${xray_enabled}"
    echo -e "  Mihomo:         ${mihomo_installed} | 状态: ${mihomo_running} | 启动: ${mihomo_enabled}"
    echo -e "  Sing-box:       ${sing_box_installed} | 状态: ${sing_box_running} | 启动: ${sing_box_enabled}"
    echo -e "  Hysteria2:      ${hysteria_server_installed} | 状态: ${hysteria_server_running} | 启动: ${hysteria_server_enabled}"
    echo -e "${CYAN}└──────────────────────────────────────────────────────────────┘${PLAIN}"

    # 菜单主体（Box-drawing 风格）
    echo -e "${CYAN}┌────────────────────────── 功能菜单 ─────────────────────────┐${PLAIN}"
    echo -e "  ${YELLOW}00${PLAIN}) 安装基础依赖"
    echo -e "  ${YELLOW}1 ${PLAIN}) 安装 Kejilion 工具箱"
    echo -e "  ${YELLOW}2 ${PLAIN}) 安装 Hysteria2"
    echo -e "  ${YELLOW}3 ${PLAIN}) 安装 warp"
    echo -e "  ${YELLOW}4 ${PLAIN}) 安装 Sing-box"
    echo -e "  ${YELLOW}5 ${PLAIN}) 安装 xray"
    echo -e "  ${YELLOW}6 ${PLAIN}) 安装 mihomo"
    echo -e "  ${YELLOW}7 ${PLAIN}) 申请 SSL 证书"
    echo -e "  ${YELLOW}8 ${PLAIN}) Web 服务"
    echo -e "  ${YELLOW}9 ${PLAIN}) 防火墙"
    echo -e "  ${YELLOW}10${PLAIN}) 安装 Argo"
    echo -e "  ${YELLOW}11${PLAIN}) 安装 Gost"
    echo -e "  ${YELLOW}99${PLAIN}) 节点信息"
    echo -e "  ${YELLOW}0 ${PLAIN}) 退出面板"
    echo -e "${CYAN}└──────────────────────────────────────────────────────────────┘${PLAIN}"
    echo
    echo -ne "${GREEN}请选择操作: ${PLAIN}"
    read choice

    case $choice in
        00) initialize_dependencies ;;
        1) install_toolbox ;;
        2) install_hysteria ;;
        3) install_warp ;;
        4) install_singbox ;;
        5) install_xray ;;
        6) bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/ts.sh) ;;
        7) bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/ssl.sh) ;;
        8) web_service_menu ;;
        9) fail_menu ;;
        10) select_argo_script ;;
        11) install_gost ;;
        99) catmi-xx ;;
        0) exit_program ;;
        *)
            echo -e "${RED}无效选项，请重新选择。${PLAIN}"
            read -p "按回车返回主菜单..."
            main_menu
            ;;
    esac
}

# 基础依赖检查和安装
initialize_dependencies() {
    echo -e "${CYAN}检查并安装基础依赖...${PLAIN}"
    apt update
    apt upgrade -y
    apt install ufw -y
    apt install uuid-runtime -y
    apt install -y curl socat git cron openssl gzip nano sudo wget xxd
    echo -e "${GREEN}基础依赖安装完成。${PLAIN}"
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

# 安装工具函数
install_toolbox() {
    echo -e "${CYAN}开始安装 Kejilion 工具箱...${PLAIN}"
    curl -sS -O https://raw.githubusercontent.com/kejilion/sh/main/kejilion.sh || { echo "工具箱下载失败"; return; }
    chmod +x kejilion.sh && ./kejilion.sh
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

install_hysteria() {
    echo -e "${CYAN}开始安装 Hysteria2...${PLAIN}"
    bash <(curl -fsSL https://github.com/mi1314cat/hysteria2-core/raw/refs/heads/main/hy2-panel.sh) || { echo "Hysteria2 安装失败"; return; }
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

select_argo_script() {
    echo "=============================="
    echo "  Argo 脚本选择菜单"
    echo "=============================="
    echo "1) URL Argo 脚本"
    echo "2) Token Panel 脚本"
    echo "3) argo加速 "
    echo "4) argo看门狗"   
    echo "0) 退出"
    echo "=============================="
    read -rp "请选择要运行的脚本: " choice

    case "$choice" in
        1)
            bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/argo/urlargo.sh)
            ;;
        2)
            bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/argo/token_panel.sh)
            ;;
        3)
            bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/argo/xcf2.sh)
            ;;
        4)
            bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/argo/argoxcfWatchdog.sh)
            ;;
        0)
            echo "已退出"
            return 0
            ;;
        *)
            echo "无效选择，请重新输入"
            select_argo_script
            ;;
    esac
}

install_gost() {
    echo -e "${CYAN}开始安装 Gost...${PLAIN}"
    bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/gost/Xgost_panel.sh) || { echo "Gost 安装失败"; return; }
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

get_web_status() {
    nginx_status=$(systemctl is-active nginx 2>/dev/null || echo "inactive")
    if [[ "$nginx_status" == "active" ]]; then
        nginx_status_text="${GREEN}运行中${PLAIN}"
    else
        nginx_status_text="${RED}未运行${PLAIN}"
    fi
    caddy_status=$(systemctl is-active caddy 2>/dev/null || echo "inactive")
    if [[ "$caddy_status" == "active" ]]; then
        caddy_status_text="${GREEN}运行中${PLAIN}"
    else
        caddy_status_text="${RED}未运行${PLAIN}"
    fi
}

web_service_menu() {
    clear
    get_web_status
    echo "====== Web 服务面板 ======"
    echo -e "Nginx 状态：$nginx_status_text"
    echo -e "Caddy 状态：$caddy_status_text"
    echo "--------------------------"
    echo "1) 重启 Nginx"
    echo "2) 重启 Caddy"
    echo "3) Reload Nginx"
    echo "4) Reload Caddy"
    echo "5) 卸载 Web 服务"
    echo "0) 返回主菜单"
    echo "=========================="
    read -p "请选择: " choice

    case "$choice" in
        1) restart_nginx ;;
        2) restart_caddy ;;
        3) reload_nginx ;;
        4) reload_caddy ;;
        5) uninstall_menu ;;
        0) main_menu ;;
        *) echo "无效选择"; sleep 1; web_service_menu ;;
    esac
}

restart_nginx() {
    systemctl restart nginx
    echo -e "${GREEN}Nginx 已重启${PLAIN}"
    sleep 1
    web_service_menu
}

restart_caddy() {
    systemctl restart caddy
    echo -e "${GREEN}Caddy 已重启${PLAIN}"
    sleep 1
    web_service_menu
}

reload_nginx() {
    systemctl reload nginx
    echo -e "${GREEN}Nginx 配置已重新加载${PLAIN}"
    sleep 1
    web_service_menu
}

reload_caddy() {
    systemctl reload caddy
    echo -e "${GREEN}Caddy 配置已重新加载${PLAIN}"
    sleep 1
    web_service_menu
}

uninstall_menu() {
    clear
    get_web_status
    echo "====== 卸载 Web 服务 ======"
    echo -e "Nginx 状态：$nginx_status_text"
    echo -e "Caddy 状态：$caddy_status_text"
    echo "---------------------------"
    echo "1) 卸载 Nginx"
    echo "2) 卸载 Caddy"
    echo "0) 返回上级菜单"
    echo "==========================="
    read -p "请选择: " choice

    case "$choice" in
        1) u_nginx ;;
        2) u_caddy ;;
        0) web_service_menu ;;
        *) echo "无效选择"; sleep 1; uninstall_menu ;;
    esac
}

u_nginx() {
    echo "=== 停止并卸载 Nginx ==="
    systemctl stop nginx 2>/dev/null
    systemctl disable nginx 2>/dev/null
    apt purge -y nginx nginx-common nginx-full
    apt autoremove -y
    echo "Nginx 已卸载完成"
    read -p "按回车返回..."
    uninstall_menu
}

u_caddy() {
    echo "=== 停止并卸载 Caddy ==="
    systemctl stop caddy 2>/dev/null
    systemctl disable caddy 2>/dev/null
    apt purge -y caddy
    apt autoremove -y
    echo "=== 删除 Caddy 配置与数据目录 ==="
    rm -rf /etc/caddy
    rm -rf /var/lib/caddy
    rm -rf /var/www/html
    echo "=== 删除 Caddy APT 仓库源 ==="
    rm -f /etc/apt/sources.list.d/caddy-stable.list
    rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    apt update -y
    echo "Caddy 已卸载完成"
    read -p "按回车返回..."
    uninstall_menu
}

install_warp() {
    echo "开始安装 warp..."
    echo "选择 Warp 安装源:"
    echo "0) 返回主菜单"
    echo "1) 官方 warp 脚本"
    echo "2) warp-go"
    echo "3) 勇哥 warp"
    read -p "请输入选项 [0-3]: " wchoice

    case $wchoice in
        0) main_menu; return ;;
        1) wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh; sed -i "s#WIREGUARD_GO_ENABLE=0#WIREGUARD_GO_ENABLE=1#g" menu.sh; bash menu.sh ;;
        2) wget -N https://gitlab.com/fscarmen/warp/-/raw/main/warp-go.sh && bash warp-go.sh ;;
        3) bash <(wget -qO- https://raw.githubusercontent.com/yonggekkk/warp-yg/main/CFwarp.sh) ;;
        *) echo "无效选项，返回主菜单"; main_menu; return ;;
    esac

    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

install_singbox() {
    echo "选择 Sing-box 安装源:"
    echo "0) 返回主菜单"
    echo "1) 使用 catmi 2"
    echo "2) 使用 catmising-box 6"
    echo "3) 使用 catmising-box 4"
    echo "4) 使用 sb (fscarmen)"
    read -p "请输入选项 [0-4]: " choice

    case $choice in
        0) main_menu; return ;;
        1) bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh) ;;
        2) bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/singbox.sh) ;;
        3) bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/nsb.sh) ;;
        4) bash <(wget -qO- https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh) ;;
        *) echo "无效选项，返回主菜单"; main_menu; return ;;
    esac

    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

install_xray() {
    while true; do
        xrayls_server_status=$(systemctl is-active xrayls 2>/dev/null || echo "inactive")
        if [[ "$xrayls_server_status" == "active" ]]; then
            xray_status_text="${GREEN}运行中${PLAIN}"
        else
            xray_status_text="${RED}未运行${PLAIN}"
        fi
        clear
        echo "====== Xray 管理 ======"
        echo -e "服务状态: ${xray_status_text}"
        echo "--------------------------------"
        echo "0) 返回主菜单"
        echo "1) 安装 / 重装 xray"
        echo "2) 更新 xray-core"
        echo "3) 重启 xray 服务"
        echo "4) 查看日志"
        echo "========================"
        read -p "请选择: " vchoice

        case $vchoice in
            0) main_menu; return ;;
            1) bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/xary-core/raw/refs/heads/main/xray-panel.sh) ;;
            2) bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/unused/xray_install.sh); systemctl daemon-reload; systemctl enable xrayls; systemctl restart xrayls ;;
            3) systemctl restart xrayls; systemctl status xrayls --no-pager ;;
            4) echo "1) access.log  2) error.log"; read log_choice; case $log_choice in 1) tail -f /root/catmi/xray/log/access.log;; 2) tail -f /root/catmi/xray/log/error.log;; *) echo "无效";; esac ;;
            *) echo "无效选项" ;;
        esac
        read -p "操作完成，按回车继续..."
    done
}

fail_menu() {
    echo "选择防火墙/安全工具:"
    echo "0) 返回主菜单"
    echo "1) 安装 UFW"
    echo "2) 安装 nftables"
    echo "3) 安装 Fail2ban"
    read -p "请输入选项 [0-3]: " choice

    case $choice in
        0) main_menu; return ;;
        1) bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/ufw.sh) ;;
        2) bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/nftables.sh) ;;
        3) bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/fail2ban.sh) ;;
        *) echo "无效选项"; main_menu; return ;;
    esac
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

cat_out_files() {
    local dir="$1"
    [[ -d "$dir" ]] || { echo "[Info] 目录不存在: $dir"; return 0; }
    local found=0
    for ext in txt yaml yml json conf; do
        local files=("$dir"/*."$ext")
        if ls "$dir"/*."$ext" >/dev/null 2>&1; then
            echo "====== ${ext^^} 文件内容 ======"
            for file in "${files[@]}"; do
                [ -f "$file" ] || continue
                echo ">>> 文件：$(basename "$file")"
                cat "$file"
                echo
                found=1
            done
        fi
    done
    [ "$found" = 0 ] && echo "[Info] 目录内无可显示文件"
}

show_file() {
    local file="$1"
    echo "------ $file ------"
    if [ -f "$file" ]; then
        cat "$file"
    else
        echo "[未找到] $file"
    fi
    echo
}

catmi-xx() {
    clear
    echo -e "${CYAN}========== 配置文件 ==========${PLAIN}\n"
    for file in /root/catmi/hy2/config.yaml /root/catmi/mihomo/clash-meta.yaml /root/catmi/singbox/clash-meta.yaml; do
        show_file "$file"
    done
    echo "------ /root/catmi/xray/out ------"
    cat_out_files /root/catmi/xray/out
    echo
    echo "*********************************"
    echo -e "${CYAN}========== V2Ray 文件 ==========${PLAIN}\n"
    for file in /root/catmi/singbox/v2ray.txt /root/catmi/mihomo/v2ray.txt /root/catmi/xray/v2ray.txt; do
        show_file "$file"
    done
    echo "*********************************"
    echo -e "${CYAN}========== xhttp.json ==========${PLAIN}\n"
    show_file /root/catmi/xray/xhttp.json
    echo
    read -p "按回车返回主菜单..."
    main_menu
}

exit_program() {
    echo -e "${CYAN}退出面板 Catmiup 面板！${PLAIN}"
    clear
    exit 0
}

# 快捷方式设置函数
create_shortcut() {
    local shortcut_path="/usr/local/bin/catmiup"
    

    echo "创建快捷方式：${shortcut_path}"

    
    curl -fsSL -o "$shortcut_path" \
        https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/Ubuntu.sh

    chmod +x "$shortcut_path"

    


    echo -e "${GREEN}快捷方式创建成功！直接运行 'catmiup' 启动面板。${PLAIN}"
}


# 主函数
main() {
    loading
    refresh_services
    create_shortcut
    main_menu
}

main
