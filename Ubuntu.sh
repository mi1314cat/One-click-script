#!/bin/bash
# =============================================================
#  Catmiup 面板 v3 · 优化版
# -------------------------------------------------------------
#  本次优化内容:
#   1) 菜单/子菜单统一交互逻辑:
#      - 无效输入: 只提示错误并立即重绘菜单(不再卡住,
#        不再要求多按一次回车, 按 0 返回不会再被"吃掉")
#      - 每个子菜单固定用 0 返回上级
#   2) Ctrl+C: 只中断当前操作并回到菜单; Ctrl+D/EOF: 安全退出
#   3) 主面板新增 IPv4 / IPv6 显示(NAT 内网自动附带公网出口 IP)
#   4) docker 探测加超时保护, 守护进程卡死不再拖住菜单
#   5) 界面美化: 分区标题边框自动对齐、双列功能菜单、统一排版
#
#  注意: 本文件必须保持 LF(Unix) 换行符,
#        请勿用 Windows 记事本编辑后保存上传。
# =============================================================

# 仅在系统支持时启用 UTF-8 locale(保证中文按 2 列宽度对齐)
if locale -a 2>/dev/null | grep -qi 'C.utf8'; then
    export LC_ALL=C.UTF-8
fi

# ===========================
#   Color & Style
# ===========================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
MAGENTA="\033[35m"
CYAN="\033[96m"
GRAY="\033[90m"
PLAIN="\033[0m"
BOLD="\033[1m"

BOX_W=62   # 面板内容区宽度(不含左右边框字符)

print_info()  { echo -e "${GREEN}[Info]${PLAIN} $1"; }
print_error() { echo -e "${RED}[Error]${PLAIN} $1"; }

line() { echo -e "${BLUE}──────────────────────────────────────────────────────────────${PLAIN}"; }

# ===========================
#   通用交互(所有菜单统一使用)
# ===========================
# 无效输入: 提示后由菜单循环立即重绘, 不做额外等待
invalid_input() {
    print_error "无效选项,请重新选择。"
    sleep 0.8
}

# 操作结束后的统一返回等待
pause_return() {
    echo
    echo -ne "${GRAY}按回车返回菜单...${PLAIN}"
    read -r _ || true
    echo
}

# 带颜色提示的统一读取: $1=提示语 $2=变量名
# 返回码: 0=正常; 128+信号=被 Ctrl+C 等中断; 其他=EOF/Ctrl+D
read_choice() {
    echo -ne "${GREEN}${1}${PLAIN}"
    read -r "$2"
}

# ===========================
#   边框绘制(按显示宽度自动对齐, 中文按 2 列计算)
# ===========================
disp_width() {
    local s="$1" w=0 i ch
    for ((i = 0; i < ${#s}; i++)); do
        ch="${s:i:1}"
        if [[ "$ch" == [[:ascii:]] ]]; then w=$((w + 1)); else w=$((w + 2)); fi
    done
    printf '%s' "$w"
}

# 把文本用空格补齐到指定显示宽度
pad_disp() {
    local w n p
    w=$(disp_width "$1")
    n=$(( $2 - w )); (( n < 0 )) && n=0
    printf -v p '%*s' "$n" ''
    printf '%s%s' "$1" "$p"
}

# 重复 n 个横线字符
dash_line() {
    local out="" i
    for ((i = 0; i < $1; i++)); do out+="─"; done
    printf '%s' "$out"
}

box_top() {  # ┌──── 标题 ────┐
    local t="$1" tw rest l r
    tw=$(disp_width "$t")
    rest=$(( BOX_W - tw - 2 )); (( rest < 0 )) && rest=0
    printf -v l '%*s' $(( rest / 2 )) '';        l=${l// /─}
    printf -v r '%*s' $(( rest - rest / 2 )) ''; r=${r// /─}
    echo -e "${CYAN}┌${l} ${BOLD}${t}${PLAIN}${CYAN} ${r}┐${PLAIN}"
}

box_mid() {  # ├──── 标题(可选) ────┤
    local t="${1:-}" tw rest l r
    if [[ -z "$t" ]]; then
        echo -e "${CYAN}├$(dash_line "$BOX_W")┤${PLAIN}"
        return
    fi
    tw=$(disp_width "$t")
    rest=$(( BOX_W - tw - 2 )); (( rest < 0 )) && rest=0
    printf -v l '%*s' $(( rest / 2 )) '';        l=${l// /─}
    printf -v r '%*s' $(( rest - rest / 2 )) ''; r=${r// /─}
    echo -e "${CYAN}├${l} ${GRAY}${t}${PLAIN}${CYAN} ${r}┤${PLAIN}"
}

box_bot() { echo -e "${CYAN}└$(dash_line "$BOX_W")┘${PLAIN}"; }

# 兼容旧命名
menu_header() { box_top "$1"; }
menu_footer() { box_bot; }

# ===========================
#   渐变标题(轻量不卡顿)
# ===========================
gradient() {
    local text="$1" out="" i=0 n
    local colors=("\033[38;5;45m" "\033[38;5;51m" "\033[38;5;87m" "\033[38;5;123m" "\033[38;5;159m")
    for ((n = 0; n < ${#text}; n++)); do
        out+="${colors[i]}${text:n:1}${PLAIN}"
        i=$(( (i + 1) % 5 ))
    done
    echo -e "$out"
}

# ===========================
#   加载动画
# ===========================
loading() {
    local bar="" i
    for i in {1..20}; do
        bar="${bar}█"
        printf "\r\033[38;5;87m加载中 [%-20s]\033[0m" "$bar"
        sleep 0.015
    done
    printf "\r\033[K"
}

# ===========================
#   面板 URL 与快捷方式路径
# ===========================
PANEL_URL="https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/Ubuntu.sh"
SHORTCUT_PATH="/usr/local/bin/catmiup"

# ===========================
#   系统信息采集(返回主菜单时刷新, 输错不重复采集)
# ===========================
collect_system_info() {
    HOSTNAME_SHOW=$(hostname)
    OS_VERSION=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    KERNEL_VERSION=$(uname -r)
    ARCH=$(uname -m)

    CPU_MODEL=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ //')
    [[ -z "$CPU_MODEL" ]] && CPU_MODEL="未知"
    CPU_CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
    [[ -z "$CPU_CORES" ]] && CPU_CORES="?"
    CPU_FREQ="$(awk -F: '/cpu MHz/ {printf "%.1f GHz", $2/1000; exit}' /proc/cpuinfo 2>/dev/null)"
    [[ -z "$CPU_FREQ" ]] && CPU_FREQ="未知"

    # CPU 占用: 两次采样 /proc/stat 求差值(0.5s 窗口), 显示实时占用而非开机均值
    local s1 s2
    s1=$(awk '/^cpu /{printf "%.0f %.0f", $2+$3+$4+$5+$6+$7+$8, $5+$6; exit}' /proc/stat 2>/dev/null)
    sleep 0.5
    s2=$(awk '/^cpu /{printf "%.0f %.0f", $2+$3+$4+$5+$6+$7+$8, $5+$6; exit}' /proc/stat 2>/dev/null)
    CPU_USAGE=$(awk -v a="$s1" -v b="$s2" 'BEGIN{split(a,x," ");split(b,y," ");dt=y[1]-x[1];di=y[2]-x[2];if(dt<=0)print "未知";else printf "%.1f%%", 100-di*100/dt}')
    LOAD_AVG=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)
    [[ -z "$LOAD_AVG" ]] && LOAD_AVG="未知"
    LOAD_1M=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    [[ -z "$LOAD_1M" ]] && LOAD_1M="-"

    TCP_CONN=$(grep -c '^ *[0-9]' /proc/net/tcp 2>/dev/null)
    UDP_CONN=$(grep -c '^ *[0-9]' /proc/net/udp 2>/dev/null)
    [[ -z "$TCP_CONN" ]] && TCP_CONN=0
    [[ -z "$UDP_CONN" ]] && UDP_CONN=0

    MEM_USED=$(free -m | awk '/Mem/ {printf "%.0fM", $3}')
    MEM_TOTAL=$(free -m | awk '/Mem/ {printf "%.0fM", $2}')
    MEM_PERCENT=$(free | awk '/Mem/ {printf "%.1f%%", $3/$2*100}')

    SWAP_USED=$(free -m | awk '/Swap/ {printf "%.0fM", $3}')
    SWAP_TOTAL=$(free -m | awk '/Swap/ {printf "%.0fM", $2}')

    DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
    DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
    DISK_PERCENT=$(df -h / | awk 'NR==2 {print $5}')
}

# ===========================
#   IP 检测(IPv4 / IPv6)
#   优先取默认路由出口地址(真实出口 IP);
#   IPv4 若是内网地址(NAT VPS)会尝试获取公网出口 IP;
#   最后用外部服务兜底, 全部带超时, 断网也不会卡住菜单。
# ===========================
detect_ips() {
    IPV4_SHOW=""
    IPV6_SHOW=""

    # --- IPv4 ---
    IPV4_SHOW=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
    if [[ -z "$IPV4_SHOW" ]]; then
        IPV4_SHOW=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1)
    fi
    case "$IPV4_SHOW" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|127.*|169.254.*)
            local pub
            pub=$(curl -4 -s --max-time 3 https://api.ip.sb/ip 2>/dev/null \
                || curl -4 -s --max-time 3 https://ifconfig.me 2>/dev/null)
            [[ -n "$pub" ]] && IPV4_SHOW="${pub} (内网 ${IPV4_SHOW})"
            ;;
    esac

    # --- IPv6 ---
    IPV6_SHOW=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | sed -n 's/.* src \([0-9a-fA-F:]*\).*/\1/p')
    if [[ -z "$IPV6_SHOW" ]]; then
        IPV6_SHOW=$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1)
    fi
    if [[ -z "$IPV6_SHOW" ]]; then
        IPV6_SHOW=$(curl -6 -s --max-time 3 https://api.ip.sb/ip 2>/dev/null)
    fi

    [[ -z "$IPV4_SHOW" ]] && IPV4_SHOW="未检测到"
    [[ -z "$IPV6_SHOW" ]] && IPV6_SHOW="未检测到"
    return 0
}

# ===========================
#   UFW / nftables 检测
# ===========================
check_ufw() {
    if command -v ufw >/dev/null 2>&1 || command -v iptables >/dev/null 2>&1; then
        ufw_installed="${GREEN}已安装${PLAIN}"
        # 真实状态: 规则是否在 kernel 生效 (优化脚本直载规则, systemd 服务可能 inactive)
        # ufw 正常 / ufw 规则已在 iptables / 面板 nft 规则已加载 → 均视为运行中
        local ufw_status
        ufw_status="$(ufw status 2>/dev/null | grep -q "Status: active" && echo active)"
        if [[ "$ufw_status" == "active" ]] || \
           iptables -S 2>/dev/null | grep -qE '^-A|ufw' || \
           nft list table inet filter 2>/dev/null | grep -qE 'ct state|comment "ufw|"ufw' ; then
            ufw_running="${GREEN}运行中${PLAIN}"
        else
            ufw_running="${YELLOW}未运行${PLAIN}"
        fi
        if systemctl is-enabled --quiet ufw 2>/dev/null || \
           [[ "$ufw_status" == "active" ]]; then
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

check_nft() {
    if command -v nft >/dev/null 2>&1; then
        nft_installed="${GREEN}已安装${PLAIN}"
        # 真实状态: 优化脚本核心是 nftables-ufw-panel.service (RemainAfterExit, active=exited 即规则已加载)
        if systemctl is-active --quiet nftables 2>/dev/null || \
           systemctl is-active --quiet nftables-ufw-panel.service 2>/dev/null || \
           nft list ruleset 2>/dev/null | grep -qE 'polkadot|ufw-panel|ct state'; then
            nft_running="${GREEN}运行中${PLAIN}"
        else
            nft_running="${YELLOW}未运行${PLAIN}"
        fi
        # enabled/static/indirect 都视为开机自启
        case "$(systemctl is-enabled nftables 2>/dev/null)" in
            enabled|static|indirect) nft_enabled="${GREEN}已启用${PLAIN}" ;;
            *) nft_enabled="${YELLOW}未启用${PLAIN}" ;;
        esac
    else
        nft_installed="${RED}未安装${PLAIN}"
        nft_running="${RED}未运行${PLAIN}"
        nft_enabled="${YELLOW}未启用${PLAIN}"
    fi
}

# ===========================
#   Xray / Mihomo 自动识别(使用已缓存的服务列表, 不再重复调用 systemctl)
# ===========================
detect_xray_service() {
    local svc
    for svc in xrayls xray xray-core; do
        if echo "$SYSTEMCTL_ENABLED" | grep -qw "${svc}.service"; then
            echo "$svc"
            return 0
        fi
    done
    echo ""
}

detect_mihomo_service() {
    local svc
    for svc in mihomo mihomo-core clash; do
        if echo "$SYSTEMCTL_ENABLED" | grep -qw "${svc}.service"; then
            echo "$svc"
            return 0
        fi
    done
    echo ""
}

# ===========================
#   刷新服务状态(带超时保护)
# ===========================
refresh_services() {
    SYSTEMCTL_ACTIVE=$(timeout 5 systemctl list-units --type=service --no-pager 2>/dev/null)
    SYSTEMCTL_ENABLED=$(timeout 5 systemctl list-unit-files --type=service --no-pager 2>/dev/null)

    check_svc_fast() {
        local svc="$1" var enabled=0 active=0
        var="${svc//-/_}"
        # 自启: 只认 STATE 列为 enabled/static/indirect 的行(排除 disabled)
        echo "$SYSTEMCTL_ENABLED" | grep -Eq "^[[:space:]]*${svc}\.service[[:space:]]+(enabled|static|indirect)" && enabled=1
        # 运行: 只认 loaded active 的行(排除 failed/activating)
        echo "$SYSTEMCTL_ACTIVE"  | grep -Eq "^[[:space:]]*${svc}\.service[[:space:]]+loaded[[:space:]]+active" && active=1
        if (( enabled == 1 )); then
            printf -v "${var}_installed" '%s' "${GREEN}已安装${PLAIN}"
            printf -v "${var}_enabled"   '%s' "${GREEN}已启用${PLAIN}"
        else
            printf -v "${var}_installed" '%s' "${RED}未安装${PLAIN}"
            printf -v "${var}_enabled"   '%s' "${YELLOW}未启用${PLAIN}"
        fi
        if (( active == 1 )); then
            printf -v "${var}_running" '%s' "${GREEN}运行中${PLAIN}"
        else
            printf -v "${var}_running" '%s' "${RED}未运行${PLAIN}"
        fi
    }

    check_svc_fast docker
    check_svc_fast nginx
    check_svc_fast caddy
    check_svc_fast fail2ban
    check_svc_fast sing-box
    check_svc_fast hysteria-server

    # --- Docker 容器补充检测(systemd 未识别时) ---
    # timeout 5: docker 守护进程卡死时最多等 5 秒, 不再无限拖住菜单
    local docker_lines="" st
    if command -v docker >/dev/null 2>&1; then
        docker_lines=$(timeout 5 docker ps -a --format '{{.Names}}|{{.State}}' 2>/dev/null)
    fi

    docker_state_for() {
        local match
        match=$(echo "$docker_lines" | grep -i "$1")
        if [[ -z "$match" ]]; then
            echo "none"
        elif echo "$match" | grep -qi '|running'; then
            echo "running"
        else
            echo "stopped"
        fi
    }

    st=$(docker_state_for nginx)
    case "$st" in
        running) nginx_installed="${GREEN}已安装(Docker)${PLAIN}"; nginx_running="${GREEN}运行中${PLAIN}" ;;
        stopped) nginx_installed="${GREEN}已安装(Docker)${PLAIN}"; nginx_running="${RED}未运行${PLAIN}" ;;
    esac

    st=$(docker_state_for caddy)
    case "$st" in
        running) caddy_installed="${GREEN}已安装(Docker)${PLAIN}"; caddy_running="${GREEN}运行中${PLAIN}" ;;
        stopped) caddy_installed="${GREEN}已安装(Docker)${PLAIN}"; caddy_running="${RED}未运行${PLAIN}" ;;
    esac

    check_ufw
    check_nft

    xray_svc=$(detect_xray_service)
    if [[ -n "$xray_svc" ]]; then
        xray_installed="${GREEN}已安装${PLAIN}"
        if echo "$SYSTEMCTL_ACTIVE" | grep -Eq "^[[:space:]]*${xray_svc}\.service[[:space:]]+loaded[[:space:]]+active"; then
            xray_running="${GREEN}运行中${PLAIN}"
        else
            xray_running="${RED}未运行${PLAIN}"
        fi
        if echo "$SYSTEMCTL_ENABLED" | grep -Eq "^[[:space:]]*${xray_svc}\.service[[:space:]]+(enabled|static|indirect)"; then
            xray_enabled="${GREEN}已启用${PLAIN}"
        else
            xray_enabled="${YELLOW}未启用${PLAIN}"
        fi
    else
        xray_installed="${RED}未安装${PLAIN}"
        xray_running="${RED}未运行${PLAIN}"
        xray_enabled="${YELLOW}未启用${PLAIN}"
    fi

    mihomo_svc=$(detect_mihomo_service)
    if [[ -n "$mihomo_svc" ]]; then
        mihomo_installed="${GREEN}已安装${PLAIN}"
        if echo "$SYSTEMCTL_ACTIVE" | grep -Eq "^[[:space:]]*${mihomo_svc}\.service[[:space:]]+loaded[[:space:]]+active"; then
            mihomo_running="${GREEN}运行中${PLAIN}"
        else
            mihomo_running="${RED}未运行${PLAIN}"
        fi
        if echo "$SYSTEMCTL_ENABLED" | grep -Eq "^[[:space:]]*${mihomo_svc}\.service[[:space:]]+(enabled|static|indirect)"; then
            mihomo_enabled="${GREEN}已启用${PLAIN}"
        else
            mihomo_enabled="${YELLOW}未启用${PLAIN}"
        fi
    else
        mihomo_installed="${RED}未安装${PLAIN}"
        mihomo_running="${RED}未运行${PLAIN}"
        mihomo_enabled="${YELLOW}未启用${PLAIN}"
    fi
    return 0
}

# ===========================
#   主菜单绘制(紧凑版)
# ===========================
info2() {  # 双列信息: $1=标签 $2=内容 $3=标签2(可空) $4=内容2
    if [[ -n "${3:-}" ]]; then
        local v1
        v1=$(pad_disp "$2" 24)
        echo -e "  ${CYAN}$(pad_disp "$1" 7)${PLAIN} ${GREEN}${v1}${PLAIN}  ${CYAN}${3}${PLAIN}  ${GREEN}${4}${PLAIN}"
    else
        echo -e "  ${CYAN}$(pad_disp "$1" 7)${PLAIN} ${GREEN}${2}${PLAIN}"
    fi
}

# 服务状态条目(定宽, 便于左右两列对齐):
#   已安装未运行 → 黄○  未安装 → 红○  运行中 → 绿●  开机自启 → 追加 绿✓
# 输出存入全局 SVC_ENTRY, 总宽恒为 22 列
svc_entry() {  # $1=名称 $2=安装状态 $3=运行状态 $4=自启状态(可空)
    local n dot state mark
    n=$(pad_disp "$1" 10)
    if [[ "$2" == *未安装* ]]; then
        dot="${RED}○";    state="${RED}未安装"; mark="  ${PLAIN}"
    elif [[ "$3" == *运行中* ]]; then
        dot="${GREEN}●";  state="${GREEN}运行中"
        if [[ -n "${4:-}" && "$4" == *已启用* ]]; then
            mark=" ${GREEN}✓${PLAIN}"
        else
            mark="  ${PLAIN}"
        fi
    else
        dot="${YELLOW}○"; state="${YELLOW}未运行"; mark="  ${PLAIN}"
    fi
    SVC_ENTRY="${n} ${dot} ${state}${mark}"
}

svc_row() {  # 双列服务: $1-4 左列(名称/安装/运行/自启)  $5-8 右列
    local e1 e2
    svc_entry "$1" "$2" "$3" "${4:-}"; e1="$SVC_ENTRY"
    svc_entry "$5" "$6" "$7" "${8:-}"; e2="$SVC_ENTRY"
    echo -e "  ${e1}    ${e2}"
}

menu3() {  # 三列菜单: [编号] 标题 (编号黄色, 标题分类色, 空标题列自动省略)
    local a1="$1" t1="$2" c1="$3" a2="$4" t2="$5" c2="$6" a3="$7" t3="$8" c3="$9"
    local parts=() n
    if [[ -n "$t1" ]]; then parts+=("$(pad_disp "$a1 $t1" 15)"); fi
    if [[ -n "$t2" ]]; then parts+=("$(pad_disp "$a2 $t2" 15)"); fi
    if [[ -n "$t3" ]]; then parts+=("$a3 $t3"); fi
    local out="  " i
    for ((i = 0; i < ${#parts[@]}; i++)); do
        [[ $i -gt 0 ]] && out+="  "
        local num title
        num="${parts[i]%% *}"; title="${parts[i]#* }"
        local col="$GREEN"
        case "$num" in "$a1") col="$c1";; "$a2") col="$c2";; "$a3") col="$c3";; esac
        out+="${YELLOW}[${num}]${PLAIN} ${col}${title}${PLAIN}"
    done
    echo -e "$out"
}

draw_main_menu() {
    clear
    echo -e "${GREEN}"
    cat << 'EOF'
                        |\__/,|   (\
EOF
    echo -e "${GREEN}                      _.|o o  |_   ) )${PLAIN}     $(gradient 'Catmiup 面板 v3')"
    cat << 'EOF'
        -------------(((---(((-------------------
EOF
    echo -e "${PLAIN}"

    box_top "系统信息"
    info2 "主机名" "$HOSTNAME_SHOW"
    info2 "系统"   "$OS_VERSION"
    info2 "内核"   "$KERNEL_VERSION"
    info2 "IPv4"   "$IPV4_SHOW"
    info2 "IPv6"   "$IPV6_SHOW"
    box_mid "硬件资源"
    info2 "CPU"    "$CPU_MODEL"
    info2 ""       "${ARCH} · ${CPU_CORES} 核 · ${CPU_FREQ} · 占用 ${CPU_USAGE} · 负载 ${LOAD_1M}"
    info2 "内存"   "${MEM_USED} / ${MEM_TOTAL} (${MEM_PERCENT})" "Swap" "${SWAP_USED} / ${SWAP_TOTAL}"
    info2 "硬盘"   "${DISK_USED} / ${DISK_TOTAL} (${DISK_PERCENT})" "连接" "TCP ${TCP_CONN} | UDP ${UDP_CONN}"
    box_mid "服务状态"
    svc_row "Docker" "$docker_installed" "$docker_running" "" \
            "UFW"       "$ufw_installed"             "$ufw_running"             "$ufw_enabled"
    svc_row "Nginx" "$nginx_installed" "$nginx_running" "" \
            "nftables"  "$nft_installed"             "$nft_running"             "$nft_enabled"
    svc_row "Caddy" "$caddy_installed" "$caddy_running" "" \
            "Fail2ban"  "$fail2ban_installed"        "$fail2ban_running"        ""
    box_bot

    box_top "功能菜单"
    echo
    menu3 "00" "更新脚本"       "$YELLOW"
    box_mid
    menu3 "01" "安装基础依赖"   "$CYAN"    "02" "内核管理"       "$GREEN"   "03" "Kejilion工具箱" "$CYAN"
    menu3 "04" "warp"           "$GREEN"   "05" "申请 SSL 证书"  "$MAGENTA" "06" "Web 服务"      "$MAGENTA"
    menu3 "07" "防火墙"          "$MAGENTA" "08" "安装 Argo"     "$CYAN"    "09" "安装 Gost"    "$CYAN"
    menu3 "10" "VPS 实用工具"   "$CYAN"    "99" "节点信息"       "$YELLOW"
    box_mid
    echo -e "  ${YELLOW}[0]${PLAIN} ${RED}退出面板${PLAIN}"
    box_bot

    echo
    echo -ne "${GREEN}  请选择操作: ${PLAIN}"
}

# ===========================
#   主菜单(循环)
#   - 输错立即重绘(不重复探测服务, 秒回)
#   - Ctrl+C 重绘; Ctrl+D/EOF 安全退出
# ===========================
main_menu() {
    local choice rc need_refresh=1
    while true; do
        if (( need_refresh == 1 )); then
            collect_system_info
            refresh_services
            detect_ips
            need_refresh=0
        fi
        draw_main_menu

        read -r choice
        rc=$?
        if (( rc > 128 )); then echo; continue; fi   # 被 Ctrl+C 中断 → 重绘
        if (( rc != 0 )); then exit_program; fi       # EOF/Ctrl+D → 安全退出
        choice="${choice//[[:space:]]/}"

        case "$choice" in
            00) update_panel ;;
            1|01)  initialize_dependencies; pause_return; need_refresh=1 ;;
            2|02)  run_catmiproxy;      pause_return; need_refresh=1 ;;
            3|03)  install_toolbox;  pause_return; need_refresh=1 ;;
            4|04)  install_warp;     need_refresh=1 ;;
            5|05)  run_remote "https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/ssl.sh"; pause_return; need_refresh=1 ;;
            6|06)  web_service_menu; need_refresh=1 ;;
            7|07)  fail_menu;        need_refresh=1 ;;
            8|08)  select_argo_script; need_refresh=1 ;;
            9|09)  install_gost;     pause_return; need_refresh=1 ;;
            10) vps_tools_menu;   need_refresh=1 ;;
            11) vps_tools_menu;   need_refresh=1 ;;
            12) vps_tools_menu;   need_refresh=1 ;;
            88) update_panel ;;
            99) catmi-xx ;;
            0)  exit_program ;;
            *)  invalid_input ;;
        esac
    done
}

# ===========================
#   远程脚本统一执行器
#   先下载到临时文件再运行: 下载失败会明确报错,
#   不再出现 curl 失败后"静默成功"的情况。
# ===========================
run_remote() {
    local url="$1" tmp rc
    print_info "正在获取脚本..."
    tmp=$(mktemp /tmp/catmi-panel.XXXXXX) || { print_error "创建临时文件失败"; return 1; }
    if ! curl -fsSL --connect-timeout 8 -m 60 -o "$tmp" "$url"; then
        print_error "脚本下载失败,请检查网络: $url"
        rm -f "$tmp"
        return 1
    fi
    bash "$tmp"
    rc=$?
    rm -f "$tmp"
    return $rc
}

# ===========================
#   调用 4 内核独立面板 catmiproxy
#   参数: mihomo | xray | singbox | hysteria (可空=总菜单)
# ===========================
run_catmiproxy() {
    local arg="${1:-}"
    print_info "正在获取 catmiproxy 内核面板..."
    if [[ -n "$arg" ]]; then
        bash <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/catmiproxy.sh") "$arg"
    else
        bash <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/catmiproxy.sh")
    fi
}

# 运行一条系统命令; 若被 Ctrl+C 中断(退出码 130), 立即中止整个操作
# 用法: step 命令 参数... || return 130
step() {
    "$@"
    local rc=$?
    (( rc == 130 )) && return 130
    return 0
}

# 基础依赖检查和安装
initialize_dependencies() {
    print_info "检查并安装基础依赖..."
    step apt update -y || return 130
    step apt upgrade -y || return 130
    step apt install -y ufw uuid-runtime || return 130
    step apt install -y curl socat git cron openssl gzip nano sudo wget xxd || return 130
    print_info "基础依赖安装完成。"
}

# 安装工具函数
install_toolbox()   { run_remote "https://raw.githubusercontent.com/kejilion/sh/main/kejilion.sh"; }
install_gost()      { run_remote "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/gost/Xgost_panel.sh"; }

# ===========================
#   Argo 脚本选择(循环版, 0 返回主菜单)
# ===========================
select_argo_script() {
    local choice rc
    while true; do
        clear
        box_top "Argo 脚本选择"
        echo -e "  ${YELLOW}1${PLAIN}) URL Argo 脚本"
        echo -e "  ${YELLOW}2${PLAIN}) Token Panel 脚本"
        echo -e "  ${YELLOW}3${PLAIN}) Argo 加速"
        echo -e "  ${YELLOW}4${PLAIN}) Argo 看门狗"
        echo -e "  ${YELLOW}0${PLAIN}) 返回主菜单"
        box_bot
        echo
        read_choice "  请选择 [0-4]: " choice
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"

        case "$choice" in
            1) run_remote "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/argo/urlargo.sh"; pause_return ;;
            2) run_remote "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/argo/token_panel.sh"; pause_return ;;
            3) run_remote "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/argo/xcf2.sh"; pause_return ;;
            4) run_remote "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/argo/argoxcfWatchdog.sh"; pause_return ;;
            0) return 0 ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   Web 服务状态
# ===========================
get_web_status() {
    if [[ "$(systemctl is-active nginx 2>/dev/null)" == "active" ]]; then
        nginx_status_text="${GREEN}运行中${PLAIN}"
    else
        nginx_status_text="${RED}未运行${PLAIN}"
    fi
    if [[ "$(systemctl is-active caddy 2>/dev/null)" == "active" ]]; then
        caddy_status_text="${GREEN}运行中${PLAIN}"
    else
        caddy_status_text="${RED}未运行${PLAIN}"
    fi
    return 0
}

# ===========================
#   Web 服务面板(循环版, 0 返回主菜单)
# ===========================
web_service_menu() {
    local choice rc
    while true; do
        clear
        get_web_status
        box_top "Web 服务面板"
        echo -e "  ${CYAN}$(pad_disp "Nginx" 11)${PLAIN}运行 $nginx_status_text"
        echo -e "  ${CYAN}$(pad_disp "Caddy" 11)${PLAIN}运行 $caddy_status_text"
        box_mid
        echo -e "  ${YELLOW}1${PLAIN}) 重启 Nginx      ${YELLOW}2${PLAIN}) 重启 Caddy"
        echo -e "  ${YELLOW}3${PLAIN}) Reload Nginx    ${YELLOW}4${PLAIN}) Reload Caddy"
        echo -e "  ${YELLOW}5${PLAIN}) 卸载 Web 服务"
        echo -e "  ${YELLOW}0${PLAIN}) 返回主菜单"
        box_bot
        echo
        read_choice "  请选择 [0-5]: " choice
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"

        case "$choice" in
            1) restart_nginx; pause_return ;;
            2) restart_caddy; pause_return ;;
            3) reload_nginx;  pause_return ;;
            4) reload_caddy;  pause_return ;;
            5) uninstall_menu ;;
            0) return 0 ;;
            *) invalid_input ;;
        esac
    done
}

restart_nginx() {
    if systemctl restart nginx 2>/dev/null; then
        print_info "Nginx 已重启"
    else
        print_error "Nginx 重启失败(可能未安装)"
    fi
}

restart_caddy() {
    if systemctl restart caddy 2>/dev/null; then
        print_info "Caddy 已重启"
    else
        print_error "Caddy 重启失败(可能未安装)"
    fi
}

reload_nginx() {
    if systemctl reload nginx 2>/dev/null; then
        print_info "Nginx 配置已重新加载"
    else
        print_error "Nginx Reload 失败(可能未安装或未运行)"
    fi
}

reload_caddy() {
    if systemctl reload caddy 2>/dev/null; then
        print_info "Caddy 配置已重新加载"
    else
        print_error "Caddy Reload 失败(可能未安装或未运行)"
    fi
}

# ===========================
#   卸载 Web 服务(循环版, 0 返回上级)
# ===========================
uninstall_menu() {
    local choice rc
    while true; do
        clear
        get_web_status
        box_top "卸载 Web 服务"
        echo -e "  ${CYAN}$(pad_disp "Nginx" 11)${PLAIN}运行 $nginx_status_text"
        echo -e "  ${CYAN}$(pad_disp "Caddy" 11)${PLAIN}运行 $caddy_status_text"
        box_mid
        echo -e "  ${YELLOW}1${PLAIN}) 卸载 Nginx"
        echo -e "  ${YELLOW}2${PLAIN}) 卸载 Caddy"
        echo -e "  ${YELLOW}0${PLAIN}) 返回上级菜单"
        box_bot
        echo
        read_choice "  请选择 [0-2]: " choice
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"

        case "$choice" in
            1) u_nginx; pause_return ;;
            2) u_caddy; pause_return ;;
            0) return 0 ;;
            *) invalid_input ;;
        esac
    done
}

u_nginx() {
    print_info "停止并卸载 Nginx..."
    step systemctl stop nginx 2>/dev/null || return 130
    step systemctl disable nginx 2>/dev/null || return 130
    step apt purge -y nginx nginx-common nginx-full || return 130
    step apt autoremove -y || return 130
    print_info "Nginx 已卸载完成"
}

u_caddy() {
    print_info "停止并卸载 Caddy..."
    step systemctl stop caddy 2>/dev/null || return 130
    step systemctl disable caddy 2>/dev/null || return 130
    step apt purge -y caddy || return 130
    step apt autoremove -y || return 130
    print_info "删除 Caddy 配置与数据目录..."
    step rm -rf /etc/caddy || return 130
    step rm -rf /var/lib/caddy || return 130
    print_info "删除 Caddy APT 仓库源..."
    step rm -f /etc/apt/sources.list.d/caddy-stable.list || return 130
    step rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg || return 130
    step apt update -y || return 130
    print_info "Caddy 已卸载完成"
}

# ===========================
#   安装 Warp(循环版, 0 返回主菜单)
# ===========================
install_warp() {
    local wchoice rc
    while true; do
        clear
        box_top "安装 Warp"
        echo -e "  ${YELLOW}1${PLAIN}) 官方 warp 脚本"
        echo -e "  ${YELLOW}2${PLAIN}) warp-go"
        echo -e "  ${YELLOW}3${PLAIN}) 勇哥 warp"
        echo -e "  ${YELLOW}0${PLAIN}) 返回主菜单"
        box_bot
        echo
        read_choice "  请输入选项 [0-3]: " wchoice
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        wchoice="${wchoice//[[:space:]]/}"

        case $wchoice in
            0) return 0 ;;
            1)
                print_info "下载 warp 官方脚本..."
                if wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh; then
                    sed -i "s#WIREGUARD_GO_ENABLE=0#WIREGUARD_GO_ENABLE=1#g" menu.sh
                    bash menu.sh
                elif (( $? == 130 )); then
                    print_info "已取消下载"
                else
                    print_error "下载失败,请检查网络"
                fi
                pause_return
                ;;
            2)
                print_info "下载 warp-go 脚本..."
                if wget -N https://gitlab.com/fscarmen/warp/-/raw/main/warp-go.sh; then
                    bash warp-go.sh
                elif (( $? == 130 )); then
                    print_info "已取消下载"
                else
                    print_error "下载失败,请检查网络"
                fi
                pause_return
                ;;
            3) run_remote "https://raw.githubusercontent.com/yonggekkk/warp-yg/main/CFwarp.sh"; pause_return ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   安装 Sing-box(循环版, 0 返回主菜单)
# ===========================


# 查看日志(Ctrl+C 停止后自动回到菜单, 不会退出面板)
view_log() {
    if [[ -f "$1" ]]; then
        print_info "查看 $1 (按 Ctrl+C 停止)"
        tail -f "$1"
    else
        print_error "日志文件不存在: $1"
    fi
    return 0
}

# ===========================
#   Xray 管理(循环版, 0 返回主菜单)
# ===========================


# ===========================
#   防火墙 / 安全工具(循环版, 0 返回主菜单)
# ===========================
fail_menu() {
    local choice rc
    while true; do
        clear
        box_top "防火墙 / 安全工具"
        echo -e "  ${YELLOW}1${PLAIN}) 安装 UFW"
        echo -e "  ${YELLOW}2${PLAIN}) 安装 nftables"
        echo -e "  ${YELLOW}3${PLAIN}) 安装 Fail2ban"
        echo -e "  ${YELLOW}0${PLAIN}) 返回主菜单"
        box_bot
        echo
        read_choice "  请输入选项 [0-3]: " choice
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"

        case $choice in
            0) return 0 ;;
            1) run_remote "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/ufw.sh"; pause_return ;;
            2) run_remote "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/nftables.sh"; pause_return ;;
            3) run_remote "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/fail2ban.sh"; pause_return ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   VPS 实用工具(循环版, 0 返回主菜单)
# ===========================
vps_tools_menu() {
    local choice rc
    while true; do
        clear
        box_top "VPS 实用工具"
        echo -e "  ${YELLOW}1${PLAIN}) 网络看门狗 (VPS Watchdog)"
        echo -e "  ${YELLOW}0${PLAIN}) 返回主菜单"
        box_bot
        echo
        read_choice "  请选择 [0-1]: " choice
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"

        case "$choice" in
            1)
                run_remote "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/vpswatchdog.sh"
                pause_return
                ;;
            0) return 0 ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   更新面板(同步 GitHub 最新版到本地快捷方式)
# ===========================
update_panel() {
    clear
    print_info "正在下载面板最新版本..."
    local tmp
    tmp=$(mktemp /tmp/catmiup-new.XXXXXX) || { print_error "创建临时文件失败"; pause_return; return 0; }
    if curl -fsSL --connect-timeout 8 -m 120 -o "$tmp" "$PANEL_URL"; then
        chmod +x "$tmp"
        # 先下载到临时文件再整体替换, 避免半截下载损坏正在运行的面板文件
        if mv -f "$tmp" "$SHORTCUT_PATH"; then
            print_info "面板更新成功,正在启动最新版本..."
            sleep 1
            exec bash "$SHORTCUT_PATH"
        else
            print_error "面板更新失败: 无法写入 $SHORTCUT_PATH (请用 sudo 运行)"
            rm -f "$tmp"
            pause_return
        fi
    else
        print_error "面板更新失败,请检查网络后重试"
        rm -f "$tmp"
        pause_return
    fi
}

cat_out_files() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        echo -e "${GRAY}[Info] 目录不存在: $dir${PLAIN}"
        return 0
    fi
    local ext file found=0
    for ext in txt yaml yml json conf; do
        for file in "$dir"/*."$ext"; do
            [[ -f "$file" ]] || continue
            echo "====== ${ext^^} 文件内容 ======"
            echo ">>> 文件: $(basename "$file")"
            cat "$file"
            echo
            found=1
        done
    done
    if (( found == 0 )); then
        echo -e "${GRAY}[Info] 目录内无可显示文件${PLAIN}"
    fi
    return 0
}

show_file() {
    echo -e "${CYAN}------ $1 ------${PLAIN}"
    if [[ -f "$1" ]]; then
        cat "$1"
    else
        echo -e "${GRAY}[未找到] $1${PLAIN}"
    fi
    echo
    return 0
}

# ===========================
#   节点信息(美化版)
# ===========================
catmi-xx() {
    clear
    box_top "节点信息"
    local file
    for file in /root/catmi/hy2/config.yaml /root/catmi/mihomo/clash-meta.yaml /root/catmi/singbox/clash-meta.yaml; do
        show_file "$file"
    done
    echo "------ /root/catmi/xray/out ------"
    cat_out_files /root/catmi/xray/out
    echo
    box_top "V2Ray 文件"
    for file in /root/catmi/singbox/v2ray.txt /root/catmi/mihomo/v2ray.txt /root/catmi/xray/v2ray.txt; do
        show_file "$file"
    done
    echo
    box_top "xhttp.json"
    show_file /root/catmi/xray/xhttp.json
    pause_return
}

# ===========================
#   退出
# ===========================
exit_program() {
    clear
    echo -e "${CYAN}感谢使用 Catmiup 面板,再见!${PLAIN}"
    exit 0
}

# Ctrl+C 统一处理: 只中断当前操作, 回到菜单, 不退出面板
on_interrupt() {
    echo
    print_info "已中断当前操作, 正在返回菜单..."
}

# ===========================
#   快捷方式(已存在则跳过; 更新请用菜单 88)
#   本地文件直接运行时会优先把"当前脚本"安装为快捷方式
# ===========================
create_shortcut() {
    if [[ -x "$SHORTCUT_PATH" ]]; then
        print_info "快捷方式已存在: $SHORTCUT_PATH (更新请用菜单 88)"
        return 0
    fi
    local self="${BASH_SOURCE[0]}"
    if [[ -f "$self" && ! "$self" -ef "$SHORTCUT_PATH" ]]; then
        print_info "使用当前脚本创建快捷方式: $SHORTCUT_PATH"
        if cp -f "$self" "$SHORTCUT_PATH" 2>/dev/null && chmod +x "$SHORTCUT_PATH" 2>/dev/null; then
            print_info "创建成功! 以后直接运行 'catmiup' 启动面板。"
        else
            print_error "创建失败, 请用 sudo 重新运行本脚本。"
        fi
        return 0
    fi
    print_info "正在从网络下载面板..."
    local tmp
    tmp=$(mktemp /tmp/catmiup-new.XXXXXX) || { print_error "创建临时文件失败"; return 0; }
    if curl -fsSL --connect-timeout 8 -m 120 -o "$tmp" "$PANEL_URL"; then
        chmod +x "$tmp"
        if mv -f "$tmp" "$SHORTCUT_PATH"; then
            print_info "创建成功! 以后直接运行 'catmiup' 启动面板。"
        else
            print_error "创建失败: 无法写入 $SHORTCUT_PATH (请用 sudo 重新运行本脚本)。"
            rm -f "$tmp"
        fi
    else
        print_error "快捷方式创建失败, 请检查网络。"
        rm -f "$tmp"
    fi
    return 0
}

# ===========================
#   主函数
# ===========================
main() {
    # 通过 `curl ... | bash` 方式启动时 stdin 是脚本流,
    # 把交互输入切换到真实终端, 避免菜单读到脚本内容
    if [[ ! -t 0 && -r /dev/tty ]]; then
        exec 0</dev/tty
    fi
    trap on_interrupt INT
    loading
    create_shortcut
    main_menu
}

main
