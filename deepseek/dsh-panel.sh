#!/bin/bash
# =============================================================
#  DSH 管理面板 · DeepSeek Harness 一键安装/服务管理
# -------------------------------------------------------------
#  三种运行形态(自动识别):
#   1) Windows(Git Bash) → WSL 引导菜单: 安装 WSL+Ubuntu、
#      重启 WSL、把本面板送进 WSL 运行
#   2) WSL(Ubuntu)       → DSH 管理面板(与 3 相同)
#   3) 普通 Linux 服务器 → DSH 管理面板
#
#  面板功能: 安装 / 启动 / 停止 / 重启 / 更新 / 修改端口 /
#            插件管理(搜索等) / 运行日志 / 工作区设置
#  长运行: 有 systemd 用 systemd 开机自启; 没有则 nohup 后台
#
#  依赖: bash + curl(安装阶段) · 面板本体零依赖
#  注意: 本文件必须保持 LF(Unix) 换行符
# =============================================================

if locale -a 2>/dev/null | grep -qi 'C.utf8'; then
    export LC_ALL=C.UTF-8
fi

# ===========================
#   运行环境识别
# ===========================
MODE_HOST="linux"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) MODE_HOST="windows" ;;
    *)
        if grep -qi microsoft /proc/version 2>/dev/null; then
            MODE_HOST="wsl"
        fi
        ;;
esac
# 测试/调试钩子: DSH_PANEL_HOST=linux|wsl|windows 可强制环境形态
[[ -n "${DSH_PANEL_HOST:-}" ]] && MODE_HOST="$DSH_PANEL_HOST"

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

print_info()  { echo -e "${GREEN}[Info]${PLAIN} $1"; }
print_error() { echo -e "${RED}[Error]${PLAIN} $1"; }
print_warn()  { echo -e "${YELLOW}[Warn]${PLAIN} $1"; }

line() { echo -e "${BLUE}──────────────────────────────────────────────────────────────${PLAIN}"; }

# ===========================
#   通用交互
# ===========================
invalid_input() {
    print_error "无效选项,请重新选择。"
    sleep 0.8
}

pause_return() {
    echo
    echo -ne "${GRAY}按回车返回菜单...${PLAIN}"
    read -r _ || true
    echo
}

read_choice() {  # $1=提示语 $2=变量名
    echo -ne "${GREEN}${1}${PLAIN}"
    read -r "$2"
}

# 运行一条命令; 若被 Ctrl+C 中断(130) 让调用方立即返回
step() {
    "$@"
    local rc=$?
    (( rc == 130 )) && return 130
    return 0
}

# ===========================
#   边框绘制(中文按 2 列对齐)
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

menu_row() {  # 双列菜单: $1=编号1 $2=标题1 $3=编号2 $4=标题2
    local c1 n1 n2
    c1=$(pad_disp "$2" 26)
    n1=$(printf '%-2s' "$1")
    if [[ -n "${3:-}" ]]; then
        n2=$(printf '%-2s' "$3")
        echo -e "  ${YELLOW}${n1}${PLAIN}) ${c1}  ${YELLOW}${n2}${PLAIN}) ${4}"
    else
        echo -e "  ${YELLOW}${n1}${PLAIN}) ${c1}"
    fi
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

loading() {
    local bar="" i
    for i in {1..16}; do
        bar="${bar}█"
        printf "\r\033[38;5;87m加载中 [%-16s]\033[0m" "$bar"
        sleep 0.02
    done
    printf "\r\033[K"
}

# ===========================
#   面板配置
# ===========================
PANEL_DIR="$HOME/.dsh-panel"
CONF_FILE="$PANEL_DIR/config"
PID_FILE="$PANEL_DIR/dsh-web.pid"
LOG_FILE="$PANEL_DIR/dsh-web.log"
SVC_NAME="dsh-web"

# DSH 插件 profile 位置 (与官方一致: $DSH_HOME/profiles/web)
DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
WEB_PROFILE_DIR="$DSH_HOME_DIR/profiles/web"
WEB_MANIFEST="$WEB_PROFILE_DIR/package.json"
PLUGIN_OUT="$PANEL_DIR/last-plugin-install.log"

PORT="3080"
WORKSPACE=""

load_config() {
    mkdir -p "$PANEL_DIR"
    if [[ -f "$CONF_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
    fi
    [[ ! "$PORT" =~ ^[0-9]+$ ]] && PORT="3080"
    if [[ -z "$WORKSPACE" ]]; then
        WORKSPACE="$HOME/dsh-workspace"
        save_config
    fi
}

save_config() {
    mkdir -p "$PANEL_DIR"
    cat > "$CONF_FILE" <<EOF
PORT="$PORT"
WORKSPACE="$WORKSPACE"
EOF
}

SUDO=""
init_sudo() {
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
    fi
}

# ===========================
#   DSH 状态探测
# ===========================
use_systemd() { [[ -d /run/systemd/system ]]; }
in_wsl()      { [[ "$MODE_HOST" == "wsl" ]]; }

dsh_installed() { command -v dsh >/dev/null 2>&1; }

dsh_version() { dsh --version 2>/dev/null | head -n 1; }

node_major() { node -v 2>/dev/null | grep -oE '[0-9]+' | head -n 1; }

nohup_pid_alive() {
    [[ -f "$PID_FILE" ]] || return 1
    local p
    p=$(cat "$PID_FILE" 2>/dev/null)
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null
}

svc_active() { systemctl is-active --quiet "$SVC_NAME" 2>/dev/null; }

is_running() {
    if use_systemd; then svc_active; else nohup_pid_alive; fi
}

port_listening() {
    command -v ss >/dev/null 2>&1 || return 2
    ss -ltn 2>/dev/null | grep -q ":${PORT}[[:space:]]"
}

running_pid() {
    if use_systemd; then
        systemctl show -p MainPID --value "$SVC_NAME" 2>/dev/null
    else
        cat "$PID_FILE" 2>/dev/null
    fi
}

# ===========================
#   systemd 服务单元
# ===========================
write_unit() {
    local dsh_bin
    dsh_bin=$(command -v dsh)
    mkdir -p "$WORKSPACE"
    $SUDO tee "/etc/systemd/system/${SVC_NAME}.service" >/dev/null <<EOF
[Unit]
Description=DeepSeek Harness Web UI (managed by dsh-panel)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$WORKSPACE
ExecStart=$dsh_bin web --port $PORT
Restart=on-failure
RestartSec=3
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload
}

# ===========================
#   启动 / 停止 / 重启
# ===========================
do_start() {
    if ! dsh_installed; then
        print_error "尚未安装 DSH, 请先执行「安装 DSH」。"
        return 1
    fi
    if is_running; then
        print_warn "DSH 已在运行中 (PID $(running_pid))。"
        return 0
    fi
    mkdir -p "$WORKSPACE"
    if use_systemd; then
        write_unit
        $SUDO systemctl enable "$SVC_NAME" >/dev/null 2>&1
        $SUDO systemctl restart "$SVC_NAME"
        sleep 1
        if svc_active; then
            print_info "DSH 已启动 (systemd, PID $(running_pid)) → http://127.0.0.1:${PORT}"
        else
            print_error "启动失败, 请查看日志: journalctl -u ${SVC_NAME} -n 30"
            return 1
        fi
    else
        print_info "当前无 systemd, 使用 nohup 后台运行 (不会开机自启)。"
        (
            cd "$WORKSPACE" || exit 1
            nohup dsh web --port "$PORT" >>"$LOG_FILE" 2>&1 &
            echo $! > "$PID_FILE"
        )
        sleep 2
        if nohup_pid_alive; then
            print_info "DSH 已启动 (nohup, PID $(cat "$PID_FILE")) → http://127.0.0.1:${PORT}"
        else
            print_error "启动失败, 请查看日志: 面板菜单 8) 运行日志"
            return 1
        fi
    fi
}

do_stop() {
    if ! is_running; then
        print_warn "DSH 未在运行。"
        return 0
    fi
    if use_systemd; then
        $SUDO systemctl stop "$SVC_NAME"
        print_info "DSH 已停止 (systemd)。"
    else
        local p
        p=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$p" ]]; then
            kill "$p" 2>/dev/null
            local i
            for i in 1 2 3 4 5; do
                kill -0 "$p" 2>/dev/null || break
                sleep 1
            done
            kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
        fi
        rm -f "$PID_FILE"
        print_info "DSH 已停止 (nohup)。"
    fi
}

do_restart() {
    do_stop || return 1
    sleep 1
    do_start
}

# ===========================
#   安装 / 更新
# ===========================
install_dsh() {
    init_sudo
    print_info "① 检查基础工具 (curl / git)..."
    if ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            step $SUDO apt-get update -y || return 130
            step $SUDO apt-get install -y curl git ca-certificates || return 130
        else
            print_warn "系统没有 apt-get, 请手动安装 curl 和 git 后重试。"
            return 1
        fi
    fi

    print_info "② 检查 Node.js (需要 v20+)..."
    local nm
    nm=$(node_major)
    if [[ -z "$nm" || "$nm" -lt 20 ]]; then
        print_info "Node.js 缺失或版本过低(当前: ${nm:-无}), 通过 NodeSource 安装 Node 22 LTS..."
        if ! command -v apt-get >/dev/null 2>&1; then
            print_error "非 apt 系统请手动安装 Node.js 20+ 后重试: https://nodejs.org"
            return 1
        fi
        step curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO bash - || return 130
        step $SUDO apt-get install -y nodejs || return 130
        nm=$(node_major)
        [[ -z "$nm" || "$nm" -lt 20 ]] && { print_error "Node.js 安装失败"; return 1; }
    else
        print_info "Node.js v${nm} 已满足要求。"
    fi

    print_info "③ 安装 pnpm (插件管理需要)..."
    if ! command -v pnpm >/dev/null 2>&1; then
        step npm install -g pnpm || return 130
    fi

    print_info "④ 安装 DeepSeek Harness (@deepseek-ai/dsh)..."
    if ! step npm install -g @deepseek-ai/dsh; then
        print_error "DSH 安装失败, 请检查网络后重试。"
        return 1
    fi

    mkdir -p "$WORKSPACE"
    print_info "⑤ 验证安装..."
    if dsh_installed; then
        print_info "安装成功: $(dsh_version)"
        print_info "下一步: 菜单 2) 启动, 然后浏览器打开 http://127.0.0.1:${PORT}"
        if [[ -z "${DSH_PANEL_TEST:-}" && ( $EUID -eq 0 || -w /usr/local/bin ) ]]; then
            cp -f "${BASH_SOURCE[0]}" /usr/local/bin/dshp 2>/dev/null && \
                chmod +x /usr/local/bin/dshp 2>/dev/null && \
                print_info "已创建快捷命令: 任意位置输入 dshp 即可打开本面板"
        fi
    else
        print_error "安装后未找到 dsh 命令, 请检查 npm 全局 bin 目录。"
        return 1
    fi
}

update_dsh() {
    if ! command -v npm >/dev/null 2>&1; then
        print_error "未找到 npm, 请先安装 DSH。"
        return 1
    fi
    local before after
    before=$(dsh_version)
    print_info "正在更新 @deepseek-ai/dsh 到最新版..."
    if ! step npm install -g @deepseek-ai/dsh@latest; then
        print_error "更新失败, 请检查网络。"
        return 1
    fi
    after=$(dsh_version)
    print_info "更新完成: ${before:-旧版} → ${after:-最新版}"
    if is_running; then
        print_info "检测到服务正在运行, 自动重启以应用新版本..."
        do_restart
    fi
}

# ===========================
#   端口 / 工作区
# ===========================
change_port() {
    local new
    read_choice "请输入新端口 [1024-65535]: " new
    new="${new//[[:space:]]/}"
    if ! [[ "$new" =~ ^[0-9]+$ ]] || (( new < 1024 || new > 65535 )); then
        print_error "端口必须是 1024-65535 之间的数字。"
        return 1
    fi
    if (( new == PORT )); then
        print_warn "新端口与当前端口相同。"
        return 0
    fi
    if port_listening 2>/dev/null; then
        print_error "端口 $new 已被其他程序占用, 请换一个。"
        return 1
    fi
    PORT="$new"
    save_config
    print_info "端口已保存为 $PORT。"
    if is_running; then
        print_info "服务正在运行, 自动重启以应用新端口..."
        do_restart
    else
        print_info "下次启动时生效。"
    fi
}

change_workspace() {
    local new
    read_choice "请输入工作区目录 (Agent 的工作目录): " new
    new="${new%/}"
    if [[ -z "$new" ]]; then
        print_error "路径不能为空。"
        return 1
    fi
    if [[ ! -d "$new" ]]; then
        print_warn "目录不存在, 是否创建? 直接回车=创建, 输入 n=取消"
        read_choice "确认: " yn
        [[ "$yn" == n* ]] && { print_info "已取消。"; return 0; }
        mkdir -p "$new" || { print_error "创建失败"; return 1; }
    fi
    WORKSPACE="$new"
    save_config
    print_info "工作区已设置为 $WORKSPACE"
    if is_running; then
        print_info "服务正在运行, 自动重启以应用新工作区..."
        do_restart
    fi
}

# ===========================
#   插件管理
# ===========================
PLUGIN_LIST=(
    "@anysearch/anysearch-dsh|AnySearch 实时搜索(推荐, 免费额度)"
    "github:zhu1090093659/dsh-web-ui|dsh-web-ui 界面增强"
    "github:DDDMUC/dsh-free-search|dsh-free-search 免费多引擎搜索"
)

plugin_guard() {
    if ! dsh_installed; then
        print_error "尚未安装 DSH, 请先执行「安装 DSH」。"
        return 1
    fi
    return 0
}

# ---- 插件注册状态校验 (读取 $DSH_HOME/profiles/web/package.json) ----
profile_state() {  # 输出两行: BUNDLES:逗号列表 / DEPS:逗号列表
    node -e '
const fs = require("fs");
let b = [], d = [];
try {
    const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    b = ((m.dsh || {}).profile || {}).bundles || [];
    d = Object.keys(m.dependencies || {});
} catch (e) {}
process.stdout.write("BUNDLES:" + b.join(",") + "\nDEPS:" + d.join(",") + "\n");
' "$WEB_MANIFEST" 2>/dev/null
}

bundle_has() {  # $1=逗号列表 $2=包名 → 在列表中?
    [[ ",$1," == *",$2,"* ]]
}

spec_pkg_guess() {  # github:user/repo#ref → repo (作为 pnpm 构建白名单 key 的兜底)
    local s="$1"
    if [[ "$s" == github:* ]]; then
        s="${s##*/}"
        s="${s%%#*}"
        s="${s%.git}"
    fi
    printf '%s' "$s"
}

allow_build_add() {  # $1=包名 → 写入 profile 的 pnpm-workspace.yaml allowBuilds
    local f="$WEB_PROFILE_DIR/pnpm-workspace.yaml"
    mkdir -p "$WEB_PROFILE_DIR"
    if [[ -f "$f" ]] && grep -qE '^[[:space:]]*allowBuilds[[:space:]]*:' "$f"; then
        if ! grep -qE "^[[:space:]]*-[[:space:]]*${1}[[:space:]]*$" "$f"; then
            awk -v key="$1" '
                { print }
                /^[[:space:]]*allowBuilds[[:space:]]*:/ && !done { print "  - " key; done=1 }
            ' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
        fi
    else
        printf '\nallowBuilds:\n  - %s\n' "$1" >> "$f"
    fi
}

fix_build_block() {  # $1=安装输出文件 $2=包spec → rc0=已写入白名单
    local keys="" k added=0 line
    # ① pnpm "Ignored build scripts: a, b" 字样
    while IFS= read -r line; do
        line="${line#*:}"
        line="${line//,/ }"
        line="${line//\"/}"
        line="${line#.}"
        for k in $line; do
            k="${k%%(*}"
            [[ " $keys " == *" $k "* ]] || keys="$keys $k"
        done
    done < <(grep -oE 'Ignored build scripts?:[^.]+' "$1" 2>/dev/null)
    # ② prepare/build script of <name> 字样
    while IFS= read -r k; do
        k="${k##* }"; k="${k//\"/}"
        [[ " $keys " == *" $k "* ]] || keys="$keys $k"
    done < <(grep -oE '(prepare|build) script of [^ ,.]+' "$1" 2>/dev/null | awk '{print $NF}')
    # ③ 兜底: 用包 spec 推导
    k=$(spec_pkg_guess "$2")
    [[ " $keys " == *" $k "* ]] || keys="$keys $k"

    for k in $keys; do
        case "$k" in ''|*[!A-Za-z0-9@/._-]*) continue ;; esac
        allow_build_add "$k"
        print_info "已将 $k 加入 pnpm 构建白名单 (allowBuilds)"
        added=1
    done
    return $(( 1 - added ))
}

plugin_add() {  # $1=包spec — 安装 + 自动处理构建拦截 + 校验真实注册
    plugin_guard || return 1
    local pkg="$1" state before_b before_d rc nb nd dep new_dep="" ok=1
    print_info "安装插件: $pkg"
    print_info "完整安装输出已保存到: $PLUGIN_OUT"

    state=$(profile_state)
    before_b="${state%%$'\n'*}"; before_b="${before_b#BUNDLES:}"
    before_d="${state#*$'\n'}";  before_d="${before_d#DEPS:}"

    run_plugin_add() {
        set -o pipefail
        dsh plugin --profile web add "$pkg" 2>&1 | tee "$PLUGIN_OUT"
        rc=$?
        set +o pipefail
    }
    run_plugin_add

    if (( rc != 0 )); then
        print_warn "安装命令失败(退出码 $rc), 检测 pnpm 构建脚本拦截并自动处理..."
        if fix_build_block "$PLUGIN_OUT" "$pkg"; then
            print_info "白名单已更新, 重试安装..."
            run_plugin_add
        fi
    fi

    # ---- 校验: 新依赖是否真的进入了 dsh.profile.bundles ----
    state=$(profile_state)
    nb="${state%%$'\n'*}"; nb="${nb#BUNDLES:}"
    nd="${state#*$'\n'}";  nd="${nd#DEPS:}"

    for dep in ${nd//,/ }; do
        [[ ",$before_d," == *",$dep,"* ]] && continue
        new_dep="$dep"
        if bundle_has "$nb" "$dep"; then
            print_info "✔ $dep 已注册进加载层 (dsh.profile.bundles)"
        else
            print_warn "✘ $dep 已安装, 但未声明 dsh.bundle — 它不是 DSH 插件, 不会被加载"
            ok=0
        fi
    done

    if (( rc != 0 )); then
        print_error "插件安装失败, 请查看上方输出。"
        print_error "若提示 allowBuilds: 手动编辑 $WEB_PROFILE_DIR/pnpm-workspace.yaml 后重试。"
        return 1
    fi

    if [[ -z "$new_dep" ]]; then
        if [[ -n "$nb" ]]; then
            print_info "未检测到新依赖 (可能此前已安装)。当前已注册插件: ${nb//,/、}"
        else
            print_warn "未检测到任何已注册插件, 请确认包名是否为 DSH 插件 (需声明 dsh.bundle)。"
        fi
        return 0
    fi

    if (( ok )); then
        print_info "插件安装并注册成功。"
        if is_running; then
            print_info "检测到服务正在运行, 自动重启以加载新插件..."
            do_restart
        else
            print_info "下次启动 DSH 时自动加载。"
        fi
    fi
    return 0
}

plugin_remove() {  # 移除 + 校验加载层确实缩小
    plugin_guard || return 1
    local name state before_b after_b rc
    read_choice "请输入要移除的插件包名: " name
    [[ -z "$name" ]] && { print_info "已取消。"; return 0; }
    state=$(profile_state)
    before_b="${state%%$'\n'*}"; before_b="${before_b#BUNDLES:}"

    set -o pipefail
    dsh plugin --profile web remove "$name" 2>&1 | tee "$PLUGIN_OUT"
    rc=$?
    set +o pipefail
    if (( rc != 0 )); then
        print_error "移除失败, 请查看输出。"
        return 1
    fi

    state=$(profile_state)
    after_b="${state%%$'\n'*}"; after_b="${after_b#BUNDLES:}"
    if [[ "$before_b" != "$after_b" ]]; then
        print_info "已移除并更新加载层。当前插件: ${after_b:-无}"
        if is_running; then
            print_info "检测到服务正在运行, 自动重启以生效..."
            do_restart
        fi
    else
        print_info "移除完成 (该包此前不在加载层, 或仅是普通依赖)。"
    fi
    return 0
}

plugin_menu() {
    local choice rc i name desc
    while true; do
        clear
        box_top "插件管理 (profile: web)"
        echo -e "  ${YELLOW}1${PLAIN}) 已安装插件列表"
        echo -e "  ${YELLOW}2${PLAIN}) 安装推荐插件"
        echo -e "  ${YELLOW}3${PLAIN}) 安装自定义插件 (npm包 / github:user/repo)"
        echo -e "  ${YELLOW}4${PLAIN}) 移除插件"
        echo -e "  ${YELLOW}5${PLAIN}) 更新全部插件"
        echo -e "  ${YELLOW}0${PLAIN}) 返回主菜单"
        box_bot
        echo
        read_choice "  请选择 [0-5]: " choice
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"

        case "$choice" in
            1)
                plugin_guard || { pause_return; continue; }
                dsh plugin --profile web list 2>&1
                pause_return
                ;;
            2)
                echo
                for i in "${!PLUGIN_LIST[@]}"; do
                    name="${PLUGIN_LIST[$i]%%|*}"
                    desc="${PLUGIN_LIST[$i]#*|}"
                    echo -e "  ${YELLOW}$((i + 1))${PLAIN}) ${desc}  ${GRAY}(${name})${PLAIN}"
                done
                echo
                read_choice "  请选择要安装的插件 [1-${#PLUGIN_LIST[@]}], 0=返回: " choice
                case "$choice" in
                    1|2|3)
                        name="${PLUGIN_LIST[$((choice - 1))]%%|*}"
                        plugin_add "$name"
                        ;;
                    0) : ;;
                    *) invalid_input ;;
                esac
                pause_return
                ;;
            3)
                read_choice "插件包名 (如 @scope/pkg 或 github:user/repo): " name
                [[ -n "$name" ]] && plugin_add "$name"
                pause_return
                ;;
            4)
                plugin_remove
                pause_return
                ;;
            5)
                plugin_guard || { pause_return; continue; }
                step dsh plugin --profile web update && print_info "插件更新完成。"
                pause_return
                ;;
            0) return 0 ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   日志
# ===========================
view_log() {
    if use_systemd; then
        print_info "查看 journalctl 日志 (Ctrl+C 停止)"
        journalctl -u "$SVC_NAME" -n 50 -f 2>/dev/null || \
            print_error "journalctl 不可用"
    else
        if [[ -f "$LOG_FILE" ]]; then
            print_info "查看 $LOG_FILE (Ctrl+C 停止)"
            tail -n 50 "$LOG_FILE"
            echo -e "${GRAY}--- 持续跟踪: tail -f $LOG_FILE ---${PLAIN}"
        else
            print_warn "暂无日志文件 (服务可能从未启动过)。"
        fi
    fi
    return 0
}

# ===========================
#   WSL: 开启 systemd
# ===========================
enable_wsl_systemd() {
    if ! in_wsl; then
        print_warn "本选项仅在 WSL 环境中可用。"
        return 1
    fi
    if use_systemd; then
        print_info "systemd 已启用, 无需操作。"
        return 0
    fi
    init_sudo
    local conf="/etc/wsl.conf"
    if [[ -f "$conf" ]] && grep -qE '^\s*systemd\s*=' "$conf"; then
        $SUDO sed -i -E 's/^\s*systemd\s*=.*/systemd=true/' "$conf"
    elif [[ -f "$conf" ]] && grep -qE '^\s*\[boot\]' "$conf"; then
        $SUDO sed -i '/^\s*\[boot\]\s*$/a systemd=true' "$conf"
    else
        printf '\n[boot]\nsystemd=true\n' | $SUDO tee -a "$conf" >/dev/null
    fi
    print_info "已写入 /etc/wsl.conf (boot.systemd=true)。"
    print_warn "需要完全重启 WSL 才能生效:"
    echo -e "  1. 回到 ${YELLOW}Windows 的面板菜单${PLAIN} (Git Bash 中运行本脚本)"
    echo -e "  2. 选择「重启 WSL」, 然后重新进入 WSL 打开本面板"
    return 0
}

# ===========================
#   主菜单绘制
# ===========================
info_row() {  # $1=标签 $2=内容
    echo -e "  ${CYAN}$(pad_disp "$1" 10)${PLAIN}  ${GREEN}${2}${PLAIN}"
}

draw_main_menu() {
    clear
    echo -e "${GREEN}"
    cat << 'EOF'
        .--.
       |o_o |
       |:_/ |    DeepSeek Harness 管理面板
      //   \ \
     (|     | )
    /'\_   _/`\
    \___)=(___/
EOF
    echo -e "${PLAIN}"
    gradient "        DSH Panel · 一键安装 · 长运行 · 插件管理"
    line

    box_top "运行状态"
    if ! dsh_installed; then
        info_row "安装状态" "${RED}未安装${PLAIN}  ${GRAY}(先执行菜单 1 安装)${PLAIN}"
    elif is_running; then
        info_row "运行状态" "${GREEN}● 运行中${PLAIN}  ${GRAY}PID ${PLAIN}${GREEN}$(running_pid)${PLAIN}"
    else
        info_row "运行状态" "${YELLOW}○ 已停止${PLAIN}"
    fi
    info_row "端口/地址" "${PORT}  →  http://127.0.0.1:${PORT}"
    info_row "Node版本" "$(node -v 2>/dev/null || echo "未安装")"
    info_row "DSH版本"  "$(dsh_installed && dsh_version || echo "未安装")"
    if use_systemd; then
        info_row "运行方式" "systemd ${GRAY}(开机自启)${PLAIN}"
    else
        info_row "运行方式" "nohup 后台 ${GRAY}$(in_wsl && echo "可在菜单 20 开启 systemd")${PLAIN}"
    fi
    info_row "工作区"   "$WORKSPACE"
    box_bot

    box_top "功能菜单"
    menu_row "1" "◆ 安装 DSH"       "6" "◆ 修改端口"
    menu_row "2" "◆ 启动"           "7" "◆ 插件管理"
    menu_row "3" "◆ 停止"           "8" "◆ 运行日志"
    menu_row "4" "◆ 重启"           "9" "◆ 工作区设置"
    menu_row "5" "◆ 更新 DSH"
    if in_wsl && ! use_systemd; then
        menu_row "20" "◆ 开启 systemd"
    fi
    menu_row "0" "◆ 退出面板"
    box_bot

    if [[ "$MODE_HOST" == "linux" ]]; then
        echo
        echo -e "  ${GRAY}提示: 服务器默认只监听 127.0.0.1, 远程访问请用 SSH 隧道:${PLAIN}"
        echo -e "  ${GRAY}ssh -L ${PORT}:127.0.0.1:${PORT} user@服务器IP${PLAIN}"
    fi
    echo
    echo -ne "${GREEN}  请选择操作: ${PLAIN}"
}

main_menu() {
    local choice rc need_refresh=1
    while true; do
        draw_main_menu
        need_refresh=0

        read -r choice
        rc=$?
        if (( rc > 128 )); then echo; continue; fi
        if (( rc != 0 )); then exit_program; fi
        choice="${choice//[[:space:]]/}"

        case "$choice" in
            1)  install_dsh; pause_return; need_refresh=1 ;;
            2)  do_start; pause_return; need_refresh=1 ;;
            3)  do_stop; pause_return; need_refresh=1 ;;
            4)  do_restart; pause_return; need_refresh=1 ;;
            5)  update_dsh; pause_return; need_refresh=1 ;;
            6)  change_port; pause_return; need_refresh=1 ;;
            7)  plugin_menu; need_refresh=1 ;;
            8)  view_log; pause_return ;;
            9)  change_workspace; pause_return; need_refresh=1 ;;
            20) enable_wsl_systemd; pause_return; need_refresh=1 ;;
            0)  exit_program ;;
            *)  invalid_input ;;
        esac
    done
}

# ===========================
#   Windows 引导菜单 (Git Bash)
# ===========================
wsl_exe() { command -v wsl.exe >/dev/null 2>&1 || return 1; }

wsl_installed() {
    wsl_exe || return 1
    wsl.exe --status >/dev/null 2>&1
}

ubuntu_distro() {  # 输出第一个 ubuntu 发行版名, 无则空
    wsl.exe -l -q 2>/dev/null | tr -d '\0\r' | grep -im1 '^ubuntu' || true
}

show_wsl_status() {
    echo
    if ! wsl_exe; then
        print_error "未检测到 wsl.exe (WSL 未安装)。"
        return 0
    fi
    echo -e "${CYAN}--- wsl --status ---${PLAIN}"
    wsl.exe --status 2>/dev/null | tr -d '\0'
    echo
    echo -e "${CYAN}--- 已安装发行版 ---${PLAIN}"
    wsl.exe -l -v 2>/dev/null | tr -d '\0'
    echo
    local d
    d=$(ubuntu_distro)
    if [[ -n "$d" ]]; then
        print_info "已找到 Ubuntu 发行版: $d → 可用菜单 4 在其中运行 DSH 面板。"
    else
        print_warn "尚未安装 Ubuntu 发行版, 请用菜单 1 安装。"
    fi
    return 0
}

install_wsl_flow() {
    if ! wsl_exe; then
        print_warn "系统还没有 wsl.exe, 将通过 wsl --install 一并安装 WSL 内核与 Ubuntu。"
    fi
    print_warn "即将弹出 UAC 管理员授权窗口 (wsl --install -d Ubuntu), 请在弹窗中点「是」。"
    read_choice "确认继续? 直接回车=继续, n=取消: " yn
    [[ "$yn" == n* ]] && { print_info "已取消。"; return 0; }
    powershell.exe -NoProfile -Command "Start-Process wsl.exe -Verb RunAs -ArgumentList '--install','-d','Ubuntu'" 2>/dev/null
    print_info "已发起安装, 请在弹出的安装窗口中等待完成 (需要联网下载)。"
    print_warn "如果提示需要重启系统: 重启电脑后重新运行本脚本, 再用菜单 2 检查状态。"
    print_info "安装完成后用菜单 2 检查, 然后用菜单 4 进入 WSL 运行 DSH 面板。"
    return 0
}

restart_wsl() {
    wsl_exe || { print_error "wsl.exe 不存在, 先安装 WSL。"; return 1; }
    print_warn "将关闭所有 WSL 实例 (运行中的服务会停止)。"
    read_choice "确认重启 WSL? 直接回车=确认, n=取消: " yn
    [[ "$yn" == n* ]] && { print_info "已取消。"; return 0; }
    wsl.exe --shutdown 2>/dev/null
    print_info "WSL 已关闭, 任意 WSL 操作会自动冷启动 (systemd 配置随之生效)。"
    return 0
}

run_panel_in_wsl() {
    wsl_exe || { print_error "wsl.exe 不存在, 先安装 WSL。"; return 1; }
    local d
    d=$(ubuntu_distro)
    if [[ -z "$d" ]]; then
        print_error "未安装 Ubuntu 发行版, 请先用菜单 1 安装。"
        return 1
    fi
    local self wslpath_
    self=$(cygpath -m "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")
    wslpath_=$(echo "$self" | sed -E 's#^([A-Za-z]):/#/mnt/\L\1/#')
    if [[ "$wslpath_" == "$self" ]]; then
        wslpath_=$(echo "$self" | sed -E 's#^/([A-Za-z])/#/mnt/\L\1/#')
    fi
    [[ -f "$self" ]] || { print_error "找不到本脚本文件: $self"; return 1; }
    print_info "在 WSL ($d) 中启动 DSH 管理面板: $wslpath_"
    print_info "首次进入 Ubuntu 会要求创建用户名和密码, 设置一次即可。"
    MSYS_NO_PATHCONV=1 wsl.exe -d "$d" -e bash -lc "bash '$wslpath_'"
    print_info "已从 WSL 返回。"
    return 0
}

manual_wsl_guide() {
    clear
    box_top "手动安装指引 (老系统)"
    echo -e "  以${YELLOW}管理员身份${PLAIN}打开 PowerShell, 依次执行:"
    echo
    echo -e "  ${GREEN}dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart${PLAIN}"
    echo -e "  ${GREEN}dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart${PLAIN}"
    echo -e "  ${GREEN}wsl --set-default-version 2${PLAIN}"
    echo -e "  ${GREEN}wsl --install -d Ubuntu${PLAIN}"
    echo
    echo -e "  完成后${YELLOW}重启电脑${PLAIN}, 首次进入 Ubuntu 设置用户名密码。"
    box_bot
    echo
    pause_return
}

windows_menu() {
    local choice rc
    while true; do
        clear
        echo -e "${GREEN}"
        cat << 'EOF'
        .--.
       |o_o |    DSH for WSL · Windows 引导
       |:_/ |
      //   \ \
     (|     | )
    /'\_   _/`\
    \___)=(___/
EOF
        echo -e "${PLAIN}"
        gradient "        第一步装 WSL · 第二步入 Ubuntu · 第三步跑面板"
        line
        box_top "引导菜单 (当前: Windows)"
        echo -e "  ${YELLOW}1${PLAIN}) 一键安装 WSL + Ubuntu  ${GRAY}(UAC 提权, 需联网)${PLAIN}"
        echo -e "  ${YELLOW}2${PLAIN}) 检查 WSL / Ubuntu 状态"
        echo -e "  ${YELLOW}3${PLAIN}) 重启 WSL  ${GRAY}(wsl --shutdown)${PLAIN}"
        echo -e "  ${YELLOW}4${PLAIN}) 在 WSL(Ubuntu) 中打开 DSH 管理面板"
        echo -e "  ${YELLOW}5${PLAIN}) 手动安装指引 (老系统备用)"
        echo -e "  ${YELLOW}0${PLAIN}) 退出"
        box_bot
        echo
        read_choice "  请选择 [0-5]: " choice
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then exit 0; fi
        choice="${choice//[[:space:]]/}"

        case "$choice" in
            1) clear; install_wsl_flow; pause_return ;;
            2) clear; show_wsl_status; pause_return ;;
            3) clear; restart_wsl; pause_return ;;
            4) clear; run_panel_in_wsl; pause_return ;;
            5) manual_wsl_guide ;;
            0) exit 0 ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   退出 / 中断
# ===========================
exit_program() {
    clear
    echo -e "${CYAN}感谢使用 DSH 管理面板, 再见!${PLAIN}"
    exit 0
}

on_interrupt() {
    echo
    print_info "已中断当前操作, 正在返回菜单..."
}

# ===========================
#   主函数
# ===========================
main() {
    trap on_interrupt INT
    loading
    if [[ "$MODE_HOST" == "windows" ]]; then
        windows_menu
    else
        load_config
        init_sudo
        main_menu
    fi
}

main
