#!/bin/bash
# =============================================================
#  CatmiTools 工具面板 v1 · 动态 URL 注册式
# -------------------------------------------------------------
#  方案 B: 主面板只挂一个入口, 加新工具不再改主面板。
#    1) 内置默认工具(可从 GitHub 热更新)
#    2) 本机清单 ~/.config/catmi-tools.list 追加自定义工具
#    3) 交互式"添加 URL → 自动生成新选项"
#
#  由 Ubuntu.sh 主面板单独调用:
#    bash <(curl -fsSL .../catmi-tools.sh)            # 交互式菜单
#    bash <(curl -fsSL .../catmi-tools.sh) add 名称 URL
#    bash <(curl -fsSL .../catmi-tools.sh) list
#    bash <(curl -fsSL .../catmi-tools.sh) rm 名称
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

BOX_W=62
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
TOOLS_LIST="$CONFIG_DIR/catmi-tools.list"

print_info()  { echo -e "${GREEN}[Info]${PLAIN} $1"; }
print_error() { echo -e "${RED}[Error]${PLAIN} $1"; }
print_ok()    { echo -e "${GREEN}[OK]${PLAIN} $1"; }

# ===========================
#   GitHub raw 基础 URL
# ===========================
GH="https://github.com/mi1314cat/One-click-script/raw/refs/heads/main"

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

gradient() {
    local text="$1" out="" i=0 n
    local colors=("\033[38;5;45m" "\033[38;5;51m" "\033[38;5;87m" "\033[38;5;123m" "\033[38;5;159m")
    for ((n = 0; n < ${#text}; n++)); do
        out+="${colors[i]}${text:n:1}${PLAIN}"
        i=$(( (i + 1) % 5 ))
    done
    echo -e "$out"
}

box_top() {
    local t="$1" tw rest l r
    tw=$(disp_width "$t")
    rest=$(( BOX_W - tw - 2 )); (( rest < 0 )) && rest=0
    printf -v l '%*s' $(( rest / 2 )) '';        l=${l// /─}
    printf -v r '%*s' $(( rest - rest / 2 )) ''; r=${r// /─}
    echo -e "${CYAN}┌${l} ${BOLD}${t}${PLAIN}${CYAN} ${r}┐${PLAIN}"
}

box_mid() {
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

menu_v() {
    local a="$1" t="$2" c="$3"
    echo -e "  ${YELLOW}[$a]${PLAIN} ${c}${t}${PLAIN}"
}

# ===========================
#   输入处理
# ===========================
read_choice() {
    local prompt="$1" rc
    printf "${GREEN}%s${PLAIN}" "$prompt" >&2
    if ! read -r rc; then
        printf "\n" >&2
        return 1
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
#   工具清单存储
# ===========================
# 清单文件格式(每行): 名称|URL|描述
# 默认工具清单(远程 GitHub TXT, 可热更新):
REMOTE_LIST="$GH/YX/tools.list"
# 下载超时(秒): 网络不好时快速跳过, 不拖慢面板
REMOTE_TIMEOUT=4
# 远程清单缓存(避免每次进菜单都等超时; 10 分钟自动刷新)
REMOTE_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/catmi-tools-remote.list"
REMOTE_CACHE_TTL=600

# 内置兜底工具(仅当远程清单下载失败时才用; 正常情况以远程 tools.list 为准)
declare -A BUILTIN
BUILTIN[vpswatchdog]="网络看门狗|$GH/A/vpswatchdog.sh|网络状态监控/重启"
BUILTIN[ssh-manager]="SSH 管理器|$GH/A/ssh-manager.sh|多服务器免密管理"

# 读取清单 → 数组(按顺序: 远程默认 + 内置兜底 + 本机自定义)
TOOL_NAMES=()  # 名称
TOOL_URLS=()   # URL
TOOL_DESCS=()  # 描述
TOOL_SRC=()    # remote|builtin|local

load_tools() {
    TOOL_NAMES=(); TOOL_URLS=(); TOOL_DESCS=(); TOOL_SRC=()
    local name url desc key use_remote=false
    # 1) 远程默认清单 (YX/tools.list) — 有缓存直接用, 超 TTL 才重新下载
    local src_file="" cache_age=99999
    if [[ -f "$REMOTE_CACHE" ]]; then
        cache_age=$(( $(date +%s) - $(stat -c %Y "$REMOTE_CACHE" 2>/dev/null || echo 0) ))
    fi
    if [[ -f "$REMOTE_CACHE" && $cache_age -lt $REMOTE_CACHE_TTL ]]; then
        src_file="$REMOTE_CACHE"   # 缓存未过期: 直接读
    else
        local tmp
        tmp=$(mktemp /tmp/catmi-tools-remote.XXXXXX) 2>/dev/null
        if [[ -n "$tmp" ]] && \
           curl -fsSL --connect-timeout 3 -m "$REMOTE_TIMEOUT" -o "$tmp" "$REMOTE_LIST" 2>/dev/null; then
            mkdir -p "$(dirname "$REMOTE_CACHE")" 2>/dev/null
            mv "$tmp" "$REMOTE_CACHE" 2>/dev/null && src_file="$REMOTE_CACHE"
        fi
        rm -f "$tmp" 2>/dev/null
    fi
    if [[ -n "$src_file" && -f "$src_file" ]]; then
        local n=0
        while IFS='|' read -r name url desc; do
            [[ -z "$name" || "$name" == \#* || -z "$url" ]] && continue
            TOOL_NAMES+=("$name"); TOOL_URLS+=("$url"); TOOL_DESCS+=("${desc:-}"); TOOL_SRC+=("remote")
            n=$((n + 1))
        done < "$src_file"
        (( n > 0 )) && use_remote=true
    fi
    # 2) 内置兜底(仅远程清单不可用/为空时)
    if ! $use_remote; then
        for key in "${!BUILTIN[@]}"; do
            IFS='|' read -r name url desc <<< "${BUILTIN[$key]}"
            TOOL_NAMES+=("$name"); TOOL_URLS+=("$url"); TOOL_DESCS+=("$desc"); TOOL_SRC+=("builtin")
        done
    fi
    # 3) 本机自定义清单(总是加载: 用户 add 的工具)(跳过空行/注释)
    if [[ -f "$TOOLS_LIST" ]]; then
        while IFS='|' read -r name url desc; do
            [[ -z "$name" || "$name" == \#* ]] && continue
            [[ -z "$url" ]] && continue
            TOOL_NAMES+=("$name"); TOOL_URLS+=("$url"); TOOL_DESCS+=("${desc:-}"); TOOL_SRC+=("local")
        done < "$TOOLS_LIST"
    fi
}

# ===========================
#   添加工具 (名称 + URL)
# ===========================
add_tool() {
    local name="$1" url="$2"
    [[ -z "$name" || -z "$url" ]] && { print_error "用法: catmi-tools.sh add 名称 URL"; return 1; }
    # URL 安全校验: 只接受 http/https
    if [[ "$url" != http://* && "$url" != https://* ]]; then
        print_error "URL 必须以 http:// 或 https:// 开头, 拒绝添加"
        return 1
    fi
    # 重名检查 (内置 + 本机清单都算)
    load_tools
    local i
    for ((i = 0; i < ${#TOOL_NAMES[@]}; i++)); do
        if [[ "${TOOL_NAMES[$i]}" == "$name" ]]; then
            print_error "已存在同名工具: $name (内置或清单中)"
            return 1
        fi
    done
    mkdir -p "$CONFIG_DIR"
    echo "$name|$url|" >> "$TOOLS_LIST"
    chmod 600 "$TOOLS_LIST" 2>/dev/null || true
    print_ok "已添加工具: $name"
    print_info "URL: $url"
    print_info "已保存到 $TOOLS_LIST, 下次进入菜单自动出现"
    return 0
}

# ===========================
#   删除工具
# ===========================
rm_tool() {
    local name="$1"
    [[ -z "$name" ]] && { print_error "用法: catmi-tools.sh rm 名称"; return 1; }
    if [[ -f "$TOOLS_LIST" ]] && grep -q "^${name}|" "$TOOLS_LIST"; then
        sed -i "/^${name}|/d" "$TOOLS_LIST"
        print_ok "已删除工具: $name"
    else
        print_error "清单中没有: $name (内置工具不可删除)"
    fi
}

# ===========================
#   列出工具
# ===========================
list_tools() {
    load_tools
    local i
    echo -e "${CYAN}========== 工具清单 ==========${PLAIN}"
    for ((i = 0; i < ${#TOOL_NAMES[@]}; i++)); do
        local tag=""
        case "${TOOL_SRC[$i]}" in
            remote)  tag=" ${BLUE}[云端]${PLAIN}" ;;
            builtin) tag=" ${GRAY}[内置]${PLAIN}" ;;
            *)       tag=" ${YELLOW}[自定义]${PLAIN}" ;;
        esac
        echo -e "  ${YELLOW}$((i+1))${PLAIN}. ${GREEN}${TOOL_NAMES[$i]}${PLAIN}${tag}"
        echo -e "     ${CYAN}→${PLAIN} ${TOOL_URLS[$i]}"
        [[ -n "${TOOL_DESCS[$i]}" ]] && echo -e "     ${GRAY}${TOOL_DESCS[$i]}${PLAIN}"
    done
}

# ===========================
#   执行工具 (通过 URL)
# ===========================
run_tool() {
    local idx="$1" url="$2" rc tmp
    [[ -z "$url" ]] && return 1
    print_info "正在获取脚本..."
    tmp=$(mktemp /tmp/catmi-tools.XXXXXX) || { print_error "创建临时文件失败"; return 1; }
    if ! curl -fsSL --connect-timeout 8 -m 90 -o "$tmp" "$url"; then
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
#   交互式添加 (输入 URL)
# ===========================
interactive_add() {
    echo
    box_top "添加新工具"
    echo -e "  ${GRAY}输入工具名称和 URL, 保存后自动出现在菜单。${PLAIN}"
    box_bot
    echo
    local name url
    printf "${GREEN}  工具名称: ${PLAIN}"
    read -r name || return 1
    printf "${GREEN}  URL (https://...): ${PLAIN}"
    read -r url || return 1
    if add_tool "$name" "$url"; then
        echo
        print_ok "菜单已更新, 返回后即可看到新工具"
    fi
    pause_return
}

# ===========================
#   主菜单
# ===========================
draw_main_menu() {
    load_tools
    local i n
    clear
    echo -e "${GREEN}"
    cat << 'EOF'
                        |\__/,|   (\
EOF
    echo -e "${GREEN}                      _.|o o  |_   ) )${PLAIN}     $(gradient 'CatmiTools')"
    cat << 'EOF'
        -------------(((---(((-------------------
EOF
    echo -e "${PLAIN}"

    box_top "工具列表"
    if [[ ${#TOOL_NAMES[@]} -gt 0 ]]; then
        for ((i = 0; i < ${#TOOL_NAMES[@]}; i++)); do
            n=$((i + 1))
            local desc="${TOOL_DESCS[$i]}"
            if [[ -n "$desc" ]]; then
                menu_v "$n" "${TOOL_NAMES[$i]} - ${desc}" "$GREEN"
            else
                menu_v "$n" "${TOOL_NAMES[$i]}" "$GREEN"
            fi
        done
    else
        echo -e "  ${GRAY}(暂无工具)${PLAIN}"
    fi
    box_mid
    menu_v "9" "添加新工具 (输入 URL)"      "$YELLOW"
    menu_v "10" "删除工具"                   "$YELLOW"
    menu_v "11" "查看工具清单"               "$YELLOW"
    menu_v "0" "返回主面板"                  "$RED"
    box_bot
    echo
}

main_menu() {
    local choice rc
    while true; do
        draw_main_menu
        choice="$(read_choice "  请选择操作 (0-11): ")"; rc=$?
        [[ $rc -gt 128 ]] && continue   # 信号中断
        [[ $rc -ne 0 ]] && return 0     # Ctrl+D 返回
        choice="${choice//[[:space:]]/}"

        case "$choice" in
            0) return 0 ;;
            9) interactive_add ;;
            10) interactive_rm ;;
            11) list_tools; pause_return ;;
            *)
                # 动态数字 → 工具索引
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    local idx=$((choice - 1))
                    if (( idx >= 0 && idx < ${#TOOL_NAMES[@]} )); then
                        run_tool "$idx" "${TOOL_URLS[$idx]}"
                        pause_return
                    else
                        invalid_input
                    fi
                else
                    invalid_input
                fi
                ;;
        esac
    done
}

interactive_rm() {
    load_tools
    local i choice name
    echo
    box_top "删除工具"
    local n=1
    for ((i = 0; i < ${#TOOL_NAMES[@]}; i++)); do
        [[ "${TOOL_SRC[$i]}" == "local" ]] || continue
        echo -e "  ${YELLOW}${n}${PLAIN}. ${GREEN}${TOOL_NAMES[$i]}${PLAIN}"
        n=$((n + 1))
    done
    if (( n == 1 )); then
        echo -e "  ${GRAY}(没有自定义工具可删)${PLAIN}"
        box_bot
        pause_return
        return
    fi
    echo -e "  ${YELLOW}0${PLAIN}. 取消"
    box_bot
    echo
    choice="$(read_choice "  选择要删除的工具编号: ")"
    local idx=0 found=-1 cnt=0
    for ((i = 0; i < ${#TOOL_NAMES[@]}; i++)); do
        [[ "${TOOL_SRC[$i]}" == "local" ]] || continue
        cnt=$((cnt + 1))
        if [[ "$choice" == "$cnt" ]]; then found=$i; break; fi
    done
    if (( found >= 0 )); then
        local nm="${TOOL_NAMES[$found]}"
        echo
        printf "${YELLOW}  确认删除工具 '$nm'? (y/N): ${PLAIN}"
        local c; read -r c
        [[ "${c,,}" == "y" ]] && rm_tool "$nm" || print_info "已取消"
    else
        print_info "已取消"
    fi
    pause_return
}

# ===========================
#   入口分发
# ===========================
cmd="${1:-}"
case "$cmd" in
    "")   main_menu ;;
    add)  shift; add_tool "$1" "$2" ;;
    rm)   shift; rm_tool "$1" ;;
    list) list_tools ;;
    -h|--help|help)
        echo "用法:"
        echo "  catmi-tools.sh              交互式菜单"
        echo "  catmi-tools.sh add 名称 URL 添加工具"
        echo "  catmi-tools.sh rm 名称      删除工具"
        echo "  catmi-tools.sh list         列出所有工具"
        ;;
    *)    print_error "未知命令: $cmd (help 查看用法)"; exit 1 ;;
esac