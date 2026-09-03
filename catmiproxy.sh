#!/bin/bash
# =============================================================
#  Catmiproxy 内核管理面板 v1 · 独立脚本
# -------------------------------------------------------------
#  从 Ubuntu.sh (Catmiup 面板 v3) 摘出的 4 内核单独管理:
#    1) mihomo      -> mi1314cat/mihomo--core   ts.sh
#    2) xray        -> mi1314cat/xary-core      xray-panel.sh
#    3) sing-box    -> mi1314cat/sing-box-core  install/singbox/nsb
#                     + fscarmen/sing-box 第三方
#    4) hysteria2   -> mi1314cat/hysteria2-core hy2-panel.sh
#
#  由 Ubuntu.sh 主面板单独调用:
#    bash <(curl -fsSL .../catmiproxy.sh)            # 四内核总菜单
#    bash <(curl -fsSL .../catmiproxy.sh) mihomo    # 直达子菜单
#  本文件必须保持 LF(Unix) 换行符。
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

# ===========================
#   宽度计算 / 对齐工具
# ===========================
disp_width() {
    local s="$1" w=0 i ch
    for ((i = 0; i < ${#s}; i++)); do
        ch="${s:i:1}"
        if [[ "$ch" == [[:ascii:]] ]]; then w=$((w + 1)); else w=$((w + 2)); fi
    done
    printf '%s' "$w"
}

pad_disp() {
    local w n p
    w=$(disp_width "$1")
    n=$(( $2 - w )); (( n < 0 )) && n=0
    printf -v p '%*s' "$n" ''
    printf '%s%s' "$1" "$p"
}

dash_line() {
    local out="" i
    for ((i = 0; i < $1; i++)); do out+="─"; done
    printf '%s' "$out"
}

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
#   UI 组件 (对齐 Catmiup 面板)
# ===========================
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

info2() {  # 双列信息: $1=标签 $2=内容 $3=标签2(可空) $4=内容2
    if [[ -n "${3:-}" ]]; then
        local v1
        v1=$(pad_disp "$2" 24)
        echo -e "  ${CYAN}$(pad_disp "$1" 7)${PLAIN} ${GREEN}${v1}${PLAIN}  ${CYAN}${3}${PLAIN}  ${GREEN}${4}${PLAIN}"
    else
        echo -e "  ${CYAN}$(pad_disp "$1" 7)${PLAIN} ${GREEN}${2}${PLAIN}"
    fi
}

svc_entry() {  # $1=名称 $2=安装状态 $3=运行状态 $4=自启状态(可空)
    local n dot state mark
    n=$(pad_disp "$1" 16)
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

menu_v() {  # 竖排单列菜单: [编号] 标题 (标题用分类色, 清爽对齐)
    local a="$1" t="$2" c="$3"
    echo -e "  ${YELLOW}[$a]${PLAIN} ${c}${t}${PLAIN}"
}

# ===========================
#   Ctrl+C / EOF 安全处理
# ===========================
read_choice() {
    local prompt="$1" rc
    printf "${GREEN}%s${PLAIN}" "$prompt" >&2
    if ! read -r rc; then
        printf "\n" >&2
        return 1   # EOF / Ctrl+D → 调用方按 rc!=0 处理(退出或返回上级)
    fi
    printf "%s\n" "$rc"
    return 0
}

invalid_input() {
    print_error "无效选项,请重新选择。"
    sleep 0.8
}

pause_return() {
    echo
    read -r -p "  按回车返回菜单..." _ 2>/dev/null || true
}

# ===========================
#   服务状态收集
# ===========================
build_service_status() {
    local SYSTEMCTL_ENABLED
    # 超时保护: systemctl 卡死时 1.5s 内放弃, 菜单仍可用
    SYSTEMCTL_ENABLED="$(timeout 1.5 systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1, $2}')"
    SYSTEMCTL_ENABLED="${SYSTEMCTL_ENABLED:-}"

    local svc
    XRAY_SVC=""; MIHOMO_SVC=""; HY2_SVC=""; SB_SVC=""
    for svc in xrayls xray xray-core; do
        echo "$SYSTEMCTL_ENABLED" | grep -qw "${svc}.service" && { XRAY_SVC="$svc"; break; }
    done
    for svc in mihomo mihomo-core clash; do
        echo "$SYSTEMCTL_ENABLED" | grep -qw "${svc}.service" && { MIHOMO_SVC="$svc"; break; }
    done
    for svc in hysteria-server hysteria2 hysteria hy2; do
        echo "$SYSTEMCTL_ENABLED" | grep -qw "${svc}.service" && { HY2_SVC="$svc"; break; }
    done
    for svc in sing-box singbox sb; do
        echo "$SYSTEMCTL_ENABLED" | grep -qw "${svc}.service" && { SB_SVC="$svc"; break; }
    done
}

service_state() {  # 返回: 已安装+运行 / 已安装+未运行 / 未安装
    local svc="$1" is_active
    if [[ -z "$svc" ]]; then
        echo "未安装"; return
    fi
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        echo "运行中"
    else
        echo "未运行"
    fi
}

service_enabled() {  # 返回: 已启用 / 空
    local svc="$1"
    systemctl is-enabled --quiet "${svc}.service" 2>/dev/null && echo "已启用" || echo ""
}

svc_state_row() {  # $1=左服务 $2=右服务, 生成 svc_row 参数
    local left="$1" right="$2"
    if [[ -n "$left" ]]; then
        SVC_LEFT_ARGS=("$left" "已安装" "$(service_state "$left")" "$(service_enabled "$left")")
    else
        SVC_LEFT_ARGS=("$left" "未安装" "" "")
    fi
    if [[ -n "$right" ]]; then
        SVC_RIGHT_ARGS=("$right" "已安装" "$(service_state "$right")" "$(service_enabled "$right")")
    else
        SVC_RIGHT_ARGS=("$right" "未安装" "" "")
    fi
    svc_row "${SVC_LEFT_ARGS[@]}" "${SVC_RIGHT_ARGS[@]}"
}

# ===========================
#   run_remote: 下载并执行远程脚本
# ===========================
run_remote() {
    local url="$1" tmp rc
    print_info "正在获取脚本..."
    tmp=$(mktemp /tmp/catmi-proxy.XXXXXX) || { print_error "创建临时文件失败"; return 1; }
    if ! curl -fsSL --connect-timeout 8 -m 120 -o "$tmp" "$url"; then
        print_error "脚本下载失败,请检查网络: $url"
        rm -f "$tmp"
        return 1
    fi
    print_info "开始执行: $url"
    bash "$tmp"
    rc=$?
    rm -f "$tmp"
    return $rc
}

# ===========================
#   主菜单绘制 (小猫 + 服务状态 + 功能)
# ===========================
draw_main_menu() {
    clear
    echo -e "${GREEN}"
    cat << 'EOF'
                        |\__/,|   (\
EOF
    echo -e "${GREEN}                      _.|o o  |_   ) )${PLAIN}     $(gradient 'Catmiproxy')"
    cat << 'EOF'
        -------------(((---(((-------------------
EOF
    echo -e "${PLAIN}"

    box_top "内核状态"
    svc_state_row "$XRAY_SVC" "$SB_SVC"
    svc_state_row "$MIHOMO_SVC" "$HY2_SVC"
    box_bot

    box_top "功能菜单"
    menu_v "1" "Mihomo     - Xray ECH / ML-KEM"      "$GREEN"
    menu_v "2" "Xray       - VLESS XHTTP/WS"         "$GREEN"
    menu_v "3" "Sing-box   - 多协议内核"             "$GREEN"
    menu_v "4" "Hysteria2  - QUIC 高速传输"          "$GREEN"
    box_mid
    menu_v "0" "返回主面板"                           "$RED"
    box_bot

    echo
    echo -ne "${GREEN}  请选择操作: ${PLAIN}"
}

# ===========================
#   1) Mihomo 管理
# ===========================
mihomo_menu() {
    local choice rc
    while true; do
        clear
        box_top "Mihomo 管理"
        info2 "状态" "$(service_state "$MIHOMO_SVC")"
        box_mid
        echo -e "  ${YELLOW}1${PLAIN}) 打开 mihomo 管理面板 (ts.sh)"
        echo -e "  ${YELLOW}2${PLAIN}) 重启 mihomo 服务"
        echo -e "  ${YELLOW}3${PLAIN}) 查看运行状态"
        echo -e "  ${YELLOW}0${PLAIN}) 返回"
        box_bot
        echo
        choice=$(read_choice "  请选择 [0-3]: ")
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"

        case $choice in
            0) return 0 ;;
            1)
                run_remote "https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/mihomo--core/raw/refs/heads/main/ts.sh"
                pause_return
                ;;
            2)
                systemctl restart "${MIHOMO_SVC:-mihomo}.service" 2>/dev/null
                systemctl status "${MIHOMO_SVC:-mihomo}.service" --no-pager 2>/dev/null || true
                pause_return
                ;;
            3)
                systemctl status "${MIHOMO_SVC:-mihomo}.service" --no-pager 2>/dev/null || true
                pause_return
                ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   2) Xray 管理
# ===========================
view_log() {
    if [[ -f "$1" ]]; then
        print_info "查看 $1 (按 Ctrl+C 停止)"
        tail -f "$1"
    else
        print_error "日志文件不存在: $1"
    fi
    return 0
}

xray_menu() {
    local choice rc log_choice
    while true; do
        clear
        box_top "Xray 管理"
        info2 "状态" "$(service_state "$XRAY_SVC")"
        box_mid
        echo -e "  ${YELLOW}1${PLAIN}) 安装 / 重装 xray"
        echo -e "  ${YELLOW}2${PLAIN}) 更新 xray-core"
        echo -e "  ${YELLOW}3${PLAIN}) 重启 xray 服务"
        echo -e "  ${YELLOW}4${PLAIN}) 查看日志"
        echo -e "  ${YELLOW}0${PLAIN}) 返回"
        box_bot
        echo
        choice=$(read_choice "  请选择 [0-4]: ")
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"

        case $choice in
            0) return 0 ;;
            1)
                run_remote "https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/xary-core/raw/refs/heads/main/xray-panel.sh"
                [[ -n "$XRAY_SVC" ]] && systemctl restart "${XRAY_SVC}.service" 2>/dev/null
                pause_return
                ;;
            2)
                run_remote "https://github.com/mi1314cat/xary-core/raw/refs/heads/main/unused/xray_install.sh"
                systemctl daemon-reload 2>/dev/null
                systemctl enable xrayls 2>/dev/null
                systemctl restart xrayls 2>/dev/null
                print_info "xray-core 更新流程执行完毕"
                pause_return
                ;;
            3)
                systemctl restart "${XRAY_SVC:-xrayls}.service" 2>/dev/null
                systemctl status "${XRAY_SVC:-xrayls}.service" --no-pager 2>/dev/null || true
                pause_return
                ;;
            4)
                echo -e "  ${YELLOW}1${PLAIN}) access.log    ${YELLOW}2${PLAIN}) error.log"
                log_choice=""
                printf "${GREEN}  请选择日志: ${PLAIN}"
                read -r log_choice || true
                case "$log_choice" in
                    1) view_log "/root/catmi/xray/log/access.log" ;;
                    2) view_log "/root/catmi/xray/log/error.log" ;;
                    *) invalid_input ;;
                esac
                ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   3) Sing-box 管理
# ===========================
singbox_menu() {
    local choice rc
    while true; do
        clear
        box_top "Sing-box 管理"
        info2 "状态" "$(service_state "$SB_SVC")"
        box_mid
        echo -e "  ${YELLOW}1${PLAIN}) 使用 catmi 2"
        echo -e "  ${YELLOW}2${PLAIN}) 使用 catmising-box 6"
        echo -e "  ${YELLOW}3${PLAIN}) 使用 catmising-box 4"
        echo -e "  ${YELLOW}4${PLAIN}) 使用 sb (fscarmen 第三方)"
        echo -e "  ${YELLOW}0${PLAIN}) 返回"
        box_bot
        echo
        choice=$(read_choice "  请选择 [0-4]: ")
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"

        case $choice in
            0) return 0 ;;
            1) run_remote "https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh"; pause_return ;;
            2) run_remote "https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/singbox.sh"; pause_return ;;
            3) run_remote "https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/nsb.sh"; pause_return ;;
            4) run_remote "https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh"; pause_return ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   4) Hysteria2 管理
# ===========================
hysteria_menu() {
    local choice rc
    while true; do
        clear
        box_top "Hysteria2 管理"
        info2 "状态" "$(service_state "$HY2_SVC")"
        box_mid
        echo -e "  ${YELLOW}1${PLAIN}) 打开 hysteria2 管理面板 (hy2-panel.sh)"
        echo -e "  ${YELLOW}2${PLAIN}) 重启 hysteria2 服务"
        echo -e "  ${YELLOW}3${PLAIN}) 查看运行状态"
        echo -e "  ${YELLOW}0${PLAIN}) 返回"
        box_bot
        echo
        choice=$(read_choice "  请选择 [0-3]: ")
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"

        case $choice in
            0) return 0 ;;
            1)
                run_remote "https://github.com/mi1314cat/hysteria2-core/raw/refs/heads/main/hy2-panel.sh"
                pause_return
                ;;
            2)
                systemctl restart "${HY2_SVC:-hysteria2}.service" 2>/dev/null
                systemctl status "${HY2_SVC:-hysteria2}.service" --no-pager 2>/dev/null || true
                pause_return
                ;;
            3)
                systemctl status "${HY2_SVC:-hysteria2}.service" --no-pager 2>/dev/null || true
                pause_return
                ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   主菜单(循环)
# ===========================
main_menu() {
    local choice rc
    build_service_status
    while true; do
        draw_main_menu
        read -r choice
        rc=$?
        if (( rc > 128 )); then echo; continue; fi   # Ctrl+C 中断 → 重绘
        if (( rc != 0 )); then exit 0; fi            # EOF/Ctrl+D → 安全退出
        choice="${choice//[[:space:]]/}"

        case $choice in
            1|01) mihomo_menu ;;
            2|02) xray_menu ;;
            3|03) singbox_menu ;;
            4|04) hysteria_menu ;;
            0) exit 0 ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   入口: 支持参数直达子菜单
#   无参数          → 总菜单 (小猫+状态)
#   catmiproxy.sh mihomo   → 直达 Mihomo
#   catmiproxy.sh xray     → 直达 Xray
#   catmiproxy.sh singbox  → 直达 Sing-box
#   catmiproxy.sh hysteria → 直达 Hysteria2
# ===========================
build_service_status

case "${1:-}" in
    mihomo)   mihomo_menu ;;
    xray)     xray_menu ;;
    singbox)  singbox_menu ;;
    hysteria) hysteria_menu ;;
    *)        main_menu ;;
esac
