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

# 打印带颜色的消息
print_info() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}
# 分割线
line() {
    echo -e "${BLUE}──────────────────────────────────────────────────────────────${PLAIN}"
}

# ===========================
#   动态加载动画（可选）
# ===========================
loading() {
    frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    for i in {1..12}; do
        printf "\r${CYAN}加载中 ${frames[i % 10]}${PLAIN}"
        sleep 0.08
    done
    printf "\r${PLAIN}"
}

loading

clear

# ===========================
#   ASCII LOGO
# ===========================
echo -e "${GREEN}"
cat << "EOF"
                       |\__/,|   (\\
                     _.|o o  |_   ) )
       -------------(((---(((-------------------
EOF
echo -e "${PLAIN}"

gradient "                         catmi - 系统信息面板 v2"
line

# ===========================
#   自动采集系统信息
# ===========================
HOSTNAME_SHOW=$(hostname)
OS_VERSION=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
KERNEL_VERSION=$(uname -r)
ARCH=$(uname -m)

CPU_MODEL=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^ //')
CPU_CORES=$(grep -c ^processor /proc/cpuinfo)
CPU_FREQ="$(awk -F: '/cpu MHz/ {printf "%.1f GHz", $2/1000; exit}' /proc/cpuinfo)"

CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print 100-$8"%"}')
LOAD_AVG=$(awk '{print $1", "$2", "$3}' /proc/loadavg)

TCP_CONN=$(ss -tn | grep -c ESTAB)
UDP_CONN=$(ss -un | wc -l)

MEM_USED=$(free -m | awk '/Mem/ {printf "%.2fM", $3}')
MEM_TOTAL=$(free -m | awk '/Mem/ {printf "%.2fM", $2}')
MEM_PERCENT=$(free | awk '/Mem/ {printf "%.2f%%", $3/$2*100}')

SWAP_USED=$(free -m | awk '/Swap/ {printf "%.0fM", $3}')
SWAP_TOTAL=$(free -m | awk '/Swap/ {printf "%.0fM", $2}')

DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
DISK_PERCENT=$(df -h / | awk 'NR==2 {print $5}')



# ===========================
#   服务检测（安全版）
# ===========================

service_exists() {
    systemctl list-unit-files | grep -q "^$1.service"
}

check_service_exists() {
    if service_exists "$1"; then
        echo -e "${GREEN}已安装${PLAIN}"
    else
        echo -e "${RED}未安装${PLAIN}"
    fi
}

check_service_running() {
    if service_exists "$1"; then
        if systemctl is-active --quiet "$1"; then
            echo -e "${GREEN}运行中${PLAIN}"
        else
            echo -e "${RED}未运行${PLAIN}"
        fi
    else
        echo -e "${RED}未安装${PLAIN}"
    fi
}

check_service_enabled() {
    if service_exists "$1"; then
        if systemctl is-enabled --quiet "$1"; then
            echo -e "${GREEN}已启用${PLAIN}"
        else
            echo -e "${YELLOW}未启用${PLAIN}"
        fi
    else
        echo -e "${RED}未安装${PLAIN}"
    fi
}

# ===========================
#   Xray 自动识别
# ===========================
detect_xray_service() {
    for svc in xrayls xray xray-core; do
        if service_exists "$svc"; then
            echo "$svc"
            return
        fi
    done
    echo ""
}

xray_svc=$(detect_xray_service)

if [[ -n "$xray_svc" ]]; then
    xray_installed="${GREEN}已安装${PLAIN}"
    xray_running=$(check_service_running "$xray_svc")
    xray_enabled=$(check_service_enabled "$xray_svc")
else
    xray_installed="${RED}未安装${PLAIN}"
    xray_running="${RED}未运行${PLAIN}"
    xray_enabled="${YELLOW}未启用${PLAIN}"
fi

# ===========================
#   Mihomo 自动识别
# ===========================
detect_mihomo_service() {
    for svc in mihomo mihomo-core clash; do
        if service_exists "$svc"; then
            echo "$svc"
            return
        fi
    done
    echo ""
}

mihomo_svc=$(detect_mihomo_service)

if [[ -n "$mihomo_svc" ]]; then
    mihomo_installed="${GREEN}已安装${PLAIN}"
    mihomo_running=$(check_service_running "$mihomo_svc")
    mihomo_enabled=$(check_service_enabled "$mihomo_svc")
else
    mihomo_installed="${RED}未安装${PLAIN}"
    mihomo_running="${RED}未运行${PLAIN}"
    mihomo_enabled="${YELLOW}未启用${PLAIN}"
fi


# 渐变标题函数
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






# 创建面板函数
main_menu() {
    clear

    # 颜色
    GREEN="\033[32m"
    YELLOW="\033[33m"
    BLUE="\033[36m"
    CYAN="\033[96m"
    MAGENTA="\033[35m"
    PLAIN="\033[0m"
    BOLD="\033[1m"

    
    # 顶部 ASCII LOGO
    echo -e "${GREEN}"
    cat << "EOF"
                       |\__/,|   (\\
                     _.|o o  |_   ) )
       -------------(((---(((-------------------
EOF
    echo -e "${PLAIN}"

    gradient "                         Catmiup 面板 v2"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────${PLAIN}"
    # ===========================
#   输出信息（Box-drawing）
# ===========================
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

echo -e "  Docker:         $(check_service_exists docker) | 状态: $(check_service_running docker)"
echo -e "  Nginx:          $(check_service_exists nginx)  | 状态: $(check_service_running nginx)"
echo -e "  Caddy:          $(check_service_exists caddy)  | 状态: $(check_service_running caddy)"

echo -e "${CYAN}├──────────────────────────────────────────────────────────────┤${PLAIN}"

echo -e "  UFW:            $(check_service_exists ufw)"
echo -e "  nftables:       $(check_service_exists nftables)"
echo -e "  Fail2ban:       $(check_service_exists fail2ban) | 状态: $(check_service_running fail2ban)"

echo -e "${CYAN}├──────────────────────────────────────────────────────────────┤${PLAIN}"

echo -e "  Xray:           ${xray_installed} | 状态: ${xray_running} | 启动: ${xray_enabled}"
echo -e "  Hysteria2:      $(check_service_exists hysteria-server) | 状态: $(check_service_running hysteria-server) | 启动: $(check_service_enabled hysteria-server)"
echo -e "  Sing-box:       $(check_service_exists sing-box) | 状态: $(check_service_running sing-box) | 启动: $(check_service_enabled sing-box)"
echo -e "  Mihomo:         ${mihomo_installed} | 状态: ${mihomo_running} | 启动: ${mihomo_enabled}"

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
        6) bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/mihomo-au.sh) ;;
        7) bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/ssl.sh) ;;
        8) web_service_menu ;;
        9) fail_menu ;;
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
    print_info "检查并安装基础依赖..."
    apt update 
    apt upgrade -y
    apt install ufw -y
    apt install -y curl socat git cron openssl gzip nano sudo wget xxd
  
    print_info "基础依赖安装完成。"
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}
# 安装工具函数
install_toolbox() {
    print_info "开始安装 Kejilion 工具箱..."
    curl -sS -O https://raw.githubusercontent.com/kejilion/sh/main/kejilion.sh || { echo "工具箱下载失败"; return; }
    chmod +x kejilion.sh && ./kejilion.sh
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

install_hysteria() {
    print_info "开始安装 Hysteria2..."
    bash <(curl -fsSL https://github.com/mi1314cat/hysteria2-core/raw/refs/heads/main/hy2-panel.sh) || { echo "Hysteria2 安装失败"; return; }
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}
get_web_status() {
    # 检测 Nginx
    nginx_status=$(systemctl is-active nginx 2>/dev/null || echo "inactive")
    if [[ "$nginx_status" == "active" ]]; then
        nginx_status_text="${GREEN}运行中${PLAIN}"
    else
        nginx_status_text="${RED}未运行${PLAIN}"
    fi

    # 检测 Caddy
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



install_warp() {
    echo "开始安装 warp..."
    
    
    echo "选择 Sing-box 安装源:"
    echo "0) 返回主菜单"
    echo "1) 使用 warp "
    echo "2) 使用 warp-go"
    echo "3) 使用 勇warp"
    read -p "请输入选项 [0-3]: " wchoice

    case $wchoice in
        0)
            print_info "已选择返回主菜单..."
            main_menu
            return
            ;;
        1)
            print_info "开始安装 warp ..."
            wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh; sed -i "s#WIREGUARD_GO_ENABLE=0#WIREGUARD_GO_ENABLE=1#g" menu.sh; bash menu.sh
            ;;
        2)
            print_info "开始安装 warp-go ..."
            wget -N https://gitlab.com/fscarmen/warp/-/raw/main/warp-go.sh && bash warp-go.sh [option] [lisence]

            ;;
        3)
            print_info "开始安装 勇warp ..."
            bash <(wget -qO- https://raw.githubusercontent.com/yonggekkk/warp-yg/main/CFwarp.sh)
            ;;    
         
        *)
            print_error "无效的选项，返回主菜单..."
            main_menu
            return
            ;;
    esac

    read -p "安装完成，按回车返回主菜单..."
    main_menu
  
}

install_singbox() {
    echo "选择 Sing-box 安装源:"
    echo "0) 返回主菜单"
    echo "1) 使用 catmi 2 "
    echo "2) 使用 catmising-box 6"
    echo "3) 使用 catmising-box 4"
    echo "4) 使用 sb "
    read -p "请输入选项 [0-4]: " choice

    case $choice in
        0)
            print_info "已选择返回主菜单..."
            main_menu
            return
            ;;
        1)
            print_info "开始安装 Sing-box ..."
            bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh) || { print_error "Sing-box 安装失败"; return; }
            ;;
        2)
            print_info "开始安装 Sing-box ..."
            bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/singbox.sh) || { print_error "Sing-box 安装失败"; return; }
            ;;
        3)
            print_info "开始安装 Sing-box ..."
            bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/nsb.sh) || { print_error "Sing-box 安装失败"; return; }
            ;;    
        4)
            print_info "开始安装 Sing-box ..."
            bash <(wget -qO- https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh) || { print_error "Sing-box 安装失败"; return; }
            ;;    
        *)
            print_error "无效的选项，返回主菜单..."
            main_menu
            return
            ;;
    esac

    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

install_xray() {
    while true; do
        # 获取服务状态
        xrayls_server_status=$(systemctl is-active xrayls.service)

        # 生成状态文本
        xrayls_server_status_text=$(
            if [[ "$xrayls_server_status" == "active" ]]; then
                printf "${GREEN}启动${PLAIN}"
            else
                printf "${RED}未启动${PLAIN}"
            fi
        )

        echo "请选择脚本操作："
        echo -e "\e[92m"
        echo "================================================="
        echo "         xrayls 服务状态: ${xrayls_server_status_text}"
        echo "================================================="
        echo -e "\e[0m"
        echo "0) 返回主菜单"
        echo "1) 安装 xray"
        echo "2) 更新 xray-core"
        echo "3) 重启 xray 服务"
        echo "4) 查看 xray 动态日志"
        read -p "请输入选项: " vchoice

        case $vchoice in
            0)
                print_info "返回主菜单..."
                return   # 退出子菜单，回到 main_menu
                ;;

            1)
                print_info "安装 xray..."
                bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/xary-core/raw/refs/heads/main/xray-panel.sh) \
                    || print_error "脚本安装失败"
                ;;

            2)
                print_info "更新 xray-core..."
                bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/upxray.sh) \
                    || print_error "更新失败"
                ;;

            3)
                print_info "正在重启 xray 服务..."
                systemctl restart xrayls
                systemctl status xrayls --no-pager
                ;;

            4)
                echo -e "${GREEN}请选择要查看的日志：${PLAIN}"
                echo "1) access.log"
                echo "2) error.log"
                read -rp "请输入选项: " LOG_CHOICE

                case "$LOG_CHOICE" in
                    1)
                        print_info "实时查看 access.log (Ctrl+C 退出)..."
                        tail -f /root/catmi/xray/log/access.log
                        ;;
                    2)
                        print_info "实时查看 error.log (Ctrl+C 退出)..."
                        tail -f /root/catmi/xray/log/error.log
                        ;;
                    *)
                        print_error "无效选项"
                        ;;
                esac
                ;;

            *)
                print_error "无效的选项，请重新选择。"
                ;;
        esac

        # 每次操作后暂停一下，再刷新子菜单
        read -p "操作完成，按回车返回 xray 子菜单..."
    done
}
fail_menu() {

echo "选择 Sing-box 安装源:"
    echo "0) 返回主菜单"
    echo "1) 使用 ufw "
    echo "2) 使用 nftables"
    echo "3) 使用 fail2ban"
    
    read -p "请输入选项 [0-3]: " choice

    case $choice in
        0)
            print_info "已选择返回主菜单..."
            main_menu
            return
            ;;
        1)
            print_info "开始安装 ufw..."
            bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/ufw.sh) || { print_error "ufw 安装失败"; return; }
            ;;
        2)
            print_info "开始安装 nftables ..."
            bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/nftables.sh) || { print_error "nftables 安装失败"; return; }
            ;;
        3)
            print_info "开始安装 fail2ban  ..."
            bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/fail2ban.sh) || { print_error "fail2ban 安装失败"; return; }
            ;;    
         
        *)
            print_error "无效的选项，返回主菜单..."
            main_menu
            return
            ;;
    esac

    read -p "安装完成，按回车返回主菜单..."
    main_menu




}
catmi-xx() {
    print_info "========== 配置文件 =========="

    for file in \
        /root/catmi/hy2/config.yaml \
        /root/catmi/xray/clash-meta.yaml \
        /root/catmi/mihomo/clash-meta.yaml \
        /root/catmi/singbox/clash-meta.yaml
    do
        echo "------ $file ------"
        if [ -f "$file" ]; then
            cat "$file"
        else
            echo "[未找到] $file"
        fi
        echo
    done

    echo "*********************************"
    print_info "========== V2Ray 文件 =========="

    for file in \
        /root/catmi/singbox/v2ray.txt \
        /root/catmi/mihomo/v2ray.txt \
        /root/catmi/xray/v2ray.txt
    do
        echo "------ $file ------"
        if [ -f "$file" ]; then
            cat "$file"
        else
            echo "[未找到] $file"
        fi
        echo
    done

    echo "*********************************"
    print_info "========== xhttp.json =========="

    file=/root/catmi/xray/xhttp.json
    echo "------ $file ------"
    if [ -f "$file" ]; then
        cat "$file"
    else
        echo "[未找到] $file"
    fi

    echo
    read -p "安装完成，按回车返回主菜单..."
    main_menu
}

exit_program() {
    print_info "退出面板 Catmiup 面板！"
    clear
    exit 0
}

# 快捷方式设置函数
create_shortcut() {
    local shortcut_path="/usr/local/bin/catmiup"
    echo "创建快捷方式：${shortcut_path}"
    echo 'bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/Ubuntu.sh)' > "$shortcut_path"
    chmod +x "$shortcut_path"
    print_info "快捷方式创建成功！直接运行 'catmiup' 启动面板。"
}

# 主函数
main() {
    
    create_shortcut
    main_menu
}

main
