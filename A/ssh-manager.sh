#!/usr/bin/env bash
# =============================================================================
#  ssh-manager.sh — 通用 SSH 服务器免密管理脚本
# -----------------------------------------------------------------------------
#  功能:
#    1. 首次运行自动检测/生成 SSH 密钥（ed25519 优先，绝不覆盖已有密钥）
#    2. 服务器配置与脚本分离：一个服务器一个配置文件 (servers/<名称>.conf)
#    3. 一键部署 SSH 公钥实现免密登录（优先 ssh-copy-id，缺失时内置部署）
#    4. 自动维护 ~/.ssh/config（只修改 SSH-MANAGER 标记区，不影响用户原有配置）
#    5. 支持上传/下载（rsync 优先，scp 备用）、远程执行、交互式登录
#    6. 支持 IPv4 / IPv6 / 域名，支持自定义端口，支持多服务器
#    7. 菜单模式 + 命令行模式双入口
#
#  安全设计:
#    · 默认不保存任何密码；部署公钥时交互式输入，用完即弃
#    · 若明确选择保存密码，配置文件权限自动设为 600 并给出警告
#    · 只追加、不覆盖目标 authorized_keys；重复公钥自动去重
#    · 不删除、不覆盖用户现有的任何 SSH 密钥
#    · 主机密钥使用 accept-new 校验（旧版 OpenSSH 有降级处理）
#    · 私钥权限强制 600，~/.ssh 权限 700，ssh config 权限 600
#
#  用法:
#    ./ssh-manager.sh              交互式菜单
#    ./ssh-manager.sh help         查看全部命令
# =============================================================================

set -uo pipefail
# 说明: 故意不使用 set -e —— 本脚本需要主动捕获 ssh/scp/rsync 等命令的
#       预期失败并转换为友好的中文提示，统一通过返回值判断，避免误退出。

# -----------------------------------------------------------------------------
# 全局变量
# -----------------------------------------------------------------------------
# 解析脚本真实路径（兼容软链接安装到 /usr/local/bin 的情况）
SCRIPT_PATH="${BASH_SOURCE[0]}"
if [ -L "$SCRIPT_PATH" ]; then
    SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SERVERS_DIR="${SSH_MANAGER_SERVERS_DIR:-$SCRIPT_DIR/servers}"

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
BEGIN_MARK="# >>> SSH-MANAGER BEGIN >>>"
END_MARK="# <<< SSH-MANAGER END <<<"

# 本地密钥信息（由 ensure_local_key 确定）
KEY_TYPE=""          # ed25519 / rsa / ecdsa / dsa
PRIVATE_KEY=""
PUB_KEY=""

# 当前服务器配置（由 load_server / parse_server_conf 填充）
NAME="" HOST="" PORT="" USER="" PASSWORD="" IDENTITY=""

# 主机密钥校验选项（按 OpenSSH 版本自动选择）
HK_OPTS=""

# -----------------------------------------------------------------------------
# 基础工具函数
# -----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# ---- 终端美化: ANSI 颜色 ----
# 自动检测: 管道/重定向输出时自动关闭颜色（日志干净）；设置 NO_COLOR=1 可强制关闭
setup_colors() {
    C_RESET="" C_BOLD="" C_DIM=""
    C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_MAGENTA=""
    if { [ -t 1 ] || [ -t 2 ]; } && [ -z "${NO_COLOR:-}" ]; then
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_RED=$'\033[31m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_CYAN=$'\033[36m'
        C_MAGENTA=$'\033[35m'
    fi
}

err()  { echo "${C_RED}❌${C_RESET} $*" >&2; }
warn() { echo "${C_YELLOW}⚠️${C_RESET} $*" >&2; }
ok()   { echo "${C_GREEN}✅${C_RESET} $*"; }
info() { echo "${C_CYAN}ℹ️${C_RESET} $*"; }

die() { err "$*"; exit 1; }

# 确认（默认否）
confirm() {
    local msg="${1:-确定继续吗?}" ans
    read -r -p "$msg [y/N]: " ans || return 1
    case "$ans" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# 确认（默认是）
confirm_default_yes() {
    local msg="${1:-确定继续吗?}" ans
    read -r -p "$msg [Y/n]: " ans || return 1
    case "$ans" in
        n|N|no|NO|No) return 1 ;;
        *) return 0 ;;
    esac
}

# -----------------------------------------------------------------------------
# 依赖检测与安装提示
# -----------------------------------------------------------------------------
install_hint() {
    # 根据发行版给出安装命令提示（支持 apt/dnf/yum/apk/pacman）
    local tool="$1"
    if have apt-get; then
        case "$tool" in
            ssh|ssh-keygen|scp|ssh-copy-id) echo "sudo apt-get install -y openssh-client" ;;
            sshpass)                        echo "sudo apt-get install -y sshpass" ;;
            rsync)                          echo "sudo apt-get install -y rsync" ;;
        esac
    elif have dnf; then
        case "$tool" in
            ssh|ssh-keygen|scp|ssh-copy-id) echo "sudo dnf install -y openssh-clients" ;;
            sshpass)                        echo "sudo dnf install -y sshpass" ;;
            rsync)                          echo "sudo dnf install -y rsync" ;;
        esac
    elif have yum; then
        case "$tool" in
            ssh|ssh-keygen|scp|ssh-copy-id) echo "sudo yum install -y openssh-clients" ;;
            sshpass)                        echo "sudo yum install -y sshpass" ;;
            rsync)                          echo "sudo yum install -y rsync" ;;
        esac
    elif have apk; then
        case "$tool" in
            ssh|ssh-keygen|scp|ssh-copy-id) echo "apk add --no-cache openssh-client" ;;
            sshpass)                        echo "apk add --no-cache sshpass" ;;
            rsync)                          echo "apk add --no-cache rsync" ;;
        esac
    elif have pacman; then
        case "$tool" in
            ssh|ssh-keygen|scp|ssh-copy-id) echo "sudo pacman -S --noconfirm openssh" ;;
            sshpass)                        echo "sudo pacman -S --noconfirm sshpass" ;;
            rsync)                          echo "sudo pacman -S --noconfirm rsync" ;;
        esac
    else
        echo "$tool（请使用你的发行版的包管理器安装）"
    fi
}

check_deps() {
    # 必要依赖缺失时给出安装提示并退出；可选依赖只提示
    local missing=0
    if ! have ssh; then
        err "缺少 ssh 客户端。安装: $(install_hint ssh)"
        missing=1
    fi
    if ! have ssh-keygen; then
        err "缺少 ssh-keygen。安装: $(install_hint ssh-keygen)"
        missing=1
    fi
    [ "$missing" -eq 1 ] && die "请先安装缺少的依赖后重试。"

    have scp         || warn "未检测到 scp，上传/下载功能将不可用。安装: $(install_hint scp)"
    have ssh-copy-id || info "未检测到 ssh-copy-id，将使用内置方式部署公钥（效果相同，无需安装）。"
    have rsync       || info "未检测到 rsync，上传/下载将使用 scp 替代（rsync 更高效，建议安装: $(install_hint rsync)）"
    have sshpass     || info "未检测到 sshpass，部署公钥时将交互式提示输入密码（默认安全行为，无需安装）。"
}

# -----------------------------------------------------------------------------
# SSH 密钥管理（生成/复用，绝不覆盖已有密钥）
# -----------------------------------------------------------------------------
ensure_local_key() {
    mkdir -p "$SSH_DIR" || die "无法创建目录 $SSH_DIR"
    chmod 700 "$SSH_DIR" 2>/dev/null || true

    # 优先使用 ed25519，其次复用任意已有私钥，都不存在才生成
    if [ -f "$SSH_DIR/id_ed25519" ]; then
        KEY_TYPE="ed25519"
    elif [ -f "$SSH_DIR/id_rsa" ]; then
        KEY_TYPE="rsa"
    elif [ -f "$SSH_DIR/id_ecdsa" ]; then
        KEY_TYPE="ecdsa"
    elif [ -f "$SSH_DIR/id_dsa" ]; then
        KEY_TYPE="dsa"
    else
        info "未检测到现有 SSH 密钥，正在生成 ed25519 密钥对（空口令）..."
        ssh-keygen -q -t ed25519 -N "" \
            -C "$(whoami 2>/dev/null || echo user)@$(hostname 2>/dev/null || echo host)-ssh-manager" \
            -f "$SSH_DIR/id_ed25519" \
            || die "SSH 密钥生成失败（请检查 ssh-keygen 是否可用）"
        KEY_TYPE="ed25519"
        ok "已生成新密钥对: $SSH_DIR/id_ed25519"
    fi

    PRIVATE_KEY="$SSH_DIR/id_$KEY_TYPE"
    PUB_KEY="$PRIVATE_KEY.pub"
    [ -f "$PRIVATE_KEY" ] || die "私钥文件不存在: $PRIVATE_KEY"
    [ -f "$PUB_KEY" ]     || die "公钥文件不存在: $PUB_KEY"

    # 修正权限: 私钥 600，公钥 644（仅当权限更宽松时收紧）
    chmod 600 "$PRIVATE_KEY" 2>/dev/null || warn "无法设置私钥权限: $PRIVATE_KEY"
    chmod 644 "$PUB_KEY" 2>/dev/null || true
    info "使用本地密钥: $PRIVATE_KEY"
}

# -----------------------------------------------------------------------------
# IPv4 / IPv6 / 域名 处理
# -----------------------------------------------------------------------------
is_ipv6_addr() { case "${1:-}" in *:*) return 0 ;; *) return 1 ;; esac; }

# ssh 命令行中的主机部分: IPv6 需要中括号  [2001:db8::1]
ssh_host_part() {
    if is_ipv6_addr "$1"; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}

# 完整的 user@host 目标（IPv6 自动加中括号）
ssh_target() { printf '%s@%s' "$1" "$(ssh_host_part "$2")"; }

# ssh config 中 HostName 行: IPv6 不需要中括号
config_host_name() { printf '%s' "$1"; }

# 主机密钥校验选项: 新版 OpenSSH 用 accept-new（自动记录新主机密钥，
# 同时防止密钥被篡改）；旧版（如 CentOS 7 的 7.4）降级为兼容模式并警告。
detect_hostkey_opt() {
    if ssh -G -F /dev/null -o StrictHostKeyChecking=accept-new 127.0.0.1 >/dev/null 2>&1; then
        HK_OPTS="-o StrictHostKeyChecking=accept-new"
    else
        warn "当前 OpenSSH 版本较旧，不支持 accept-new 选项，脚本自动操作用兼容模式"
        HK_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
    fi
}

# -----------------------------------------------------------------------------
# 服务器配置读取与校验
# -----------------------------------------------------------------------------
server_conf_path() { printf '%s/%s.conf' "$SERVERS_DIR" "$1"; }

valid_name() {
    # 名称只能包含字母/数字/下划线/连字符，且不能以 - 开头（保证别名与文件名安全）
    case "${1:-}" in
        ""|*[!A-Za-z0-9_-]*|"-"*) return 1 ;;
    esac
    return 0
}

# 解析单个配置文件并填充全局变量。
# 与 load_server 的区别: 解析失败时返回 1 而不是退出（供批量场景容错使用）。
parse_server_conf() {
    local conf="${1:-}"
    NAME="" HOST="" PORT="" USER="" PASSWORD="" IDENTITY=""

    # shellcheck disable=SC1090  # 动态加载用户配置文件，路径无法静态确定
    if ! source "$conf" 2>/dev/null; then
        err "无法读取配置文件: $conf"
        return 1
    fi

    NAME="${NAME:-}"
    HOST="${HOST:-}"
    PORT="${PORT:-22}"
    USER="${USER:-root}"

    # 去掉地址两侧可能存在的方括号 [2001:db8::1] -> 2001:db8::1
    HOST="${HOST#\[}"
    HOST="${HOST%\]}"

    [ -n "$HOST" ] || { err "配置文件 $conf 缺少 HOST（服务器地址）"; return 1; }
    [ -n "$NAME" ] || { err "配置文件 $conf 缺少 NAME（服务器名称）"; return 1; }

    case "$PORT" in
        ''|*[!0-9]*) err "配置文件 $conf 的 PORT 不是有效数字: '$PORT'"; return 1 ;;
    esac
    PORT=$((10#$PORT))   # 归一化: 去除前导零（如 0022 -> 22），避免八进制歧义
    if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        err "配置文件 $conf 的 PORT 超出范围 (1-65535): $PORT"
        return 1
    fi

    # 私钥路径: 默认使用本地默认密钥；支持配置覆盖；展开 ~ 前缀
    IDENTITY="${IDENTITY:-$PRIVATE_KEY}"
    IDENTITY="${IDENTITY/#\~/$HOME}"
    if [ -n "$IDENTITY" ] && [ ! -f "$IDENTITY" ]; then
        warn "配置的私钥文件不存在: $IDENTITY（将可能导致登录失败）"
    fi
    return 0
}

# 按名称加载服务器配置，失败时直接报错退出
load_server() {
    local name="${1:-}"
    [ -n "$name" ] || die "请指定服务器名称"
    local conf
    conf="$(server_conf_path "$name")"
    [ -f "$conf" ] || die "找不到服务器 '$name' 的配置文件（$conf）。请先执行: ./ssh-manager.sh add"

    parse_server_conf "$conf" || die "服务器 '$name' 配置无效，请执行: ./ssh-manager.sh edit $name 修正"

    if [ "$NAME" != "$name" ]; then
        warn "注意: $conf 中 NAME='$NAME' 与文件名 '$name' 不一致，将使用 '$NAME' 作为连接别名"
    fi
}

# -----------------------------------------------------------------------------
# ~/.ssh/config 自动维护（只修改 SSH-MANAGER 标记区，不影响用户原有配置）
# -----------------------------------------------------------------------------
update_ssh_config() {
    [ -d "$SERVERS_DIR" ] || return 0
    mkdir -p "$SSH_DIR" || die "无法创建目录 $SSH_DIR"
    chmod 700 "$SSH_DIR" 2>/dev/null || true

    # ---- 构建新的管理区内容 ----
    # 注意: 在子 shell 中解析配置，避免污染调用方的全局变量
    #       （否则 update_ssh_config 之后 NAME/HOST 等会变成最后一个服务器的值）
    local block="" seen="" conf count=0 vals v_name v_host v_port v_user v_identity
    block="$BEGIN_MARK"$'\n'"# 本区域由 ssh-manager.sh 自动维护，请勿手动编辑"$'\n'

    for conf in "$SERVERS_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        if ! vals="$(parse_server_conf "$conf" && printf '%s\t%s\t%s\t%s\t%s' "$NAME" "$HOST" "$PORT" "$USER" "$IDENTITY")"; then
            warn "跳过无法解析的服务器配置: $conf"
            continue
        fi
        IFS=$'\t' read -r v_name v_host v_port v_user v_identity <<< "$vals"
        # 名称去重（避免生成重复的 Host 块）
        case " $seen " in
            *" $v_name "*) warn "服务器名称 '$v_name' 重复，已跳过: $conf"; continue ;;
        esac
        seen="$seen $v_name"

        block+="Host $v_name"$'\n'
        block+="    HostName $(config_host_name "$v_host")"$'\n'
        block+="    User $v_user"$'\n'
        block+="    Port $v_port"$'\n'
        block+="    IdentityFile $v_identity"$'\n'
        block+="    IdentitiesOnly yes"$'\n'
        block+=$'\n'
        count=$((count + 1))
    done
    block+="$END_MARK"

    # 没有任何服务器且 config 尚不存在时，不创建空文件（避免多余触碰用户环境）
    if [ "$count" -eq 0 ] && [ ! -f "$SSH_CONFIG" ]; then
        return 0
    fi

    # ---- 安全清理旧管理区 ----
    if [ -f "$SSH_CONFIG" ] && grep -qF "$BEGIN_MARK" "$SSH_CONFIG"; then
        if ! grep -qF "$END_MARK" "$SSH_CONFIG"; then
            warn "$SSH_CONFIG 中的管理区缺少结束标记，为避免误删用户配置，本次不自动修改"
            warn "请手动检查该文件，修复后重试（或删除管理区内容）"
            return 1
        fi
        sed -i "/^${BEGIN_MARK}$/,/^${END_MARK}$/d" "$SSH_CONFIG"
    fi

    # ---- 写入: 管理区置顶 + 用户原有内容（保证我们的 Host 配置优先生效）----
    # 用户原有内容过滤空行，避免多次更新后累积大量空行
    local tmp
    tmp="$SSH_CONFIG.tmp.$$"
    {
        printf '%s\n\n' "$block"
        [ -f "$SSH_CONFIG" ] && grep -v '^[[:space:]]*$' "$SSH_CONFIG" || true
    } > "$tmp" && mv "$tmp" "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
}

# -----------------------------------------------------------------------------
# SSH 操作辅助
# -----------------------------------------------------------------------------
# 带密码执行命令: 若配置了密码且安装了 sshpass，则通过环境变量自动输入
# （sshpass -e 用环境变量传密码，避免密码出现在进程列表 ps 中）
run_with_pass() {
    if [ -n "${PASSWORD:-}" ] && have sshpass; then
        SSHPASS="$PASSWORD" sshpass -e "$@"
    else
        "$@"
    fi
}

# 探测远程路径是否为目录（用于 rsync 下载时决定是否加尾斜杠，
# 统一"目标路径 = 最终位置"的语义，避免出现 目录/目录 嵌套）
remote_is_dir() {
    local name="$1" path="$2" q
    q="$(printf '%q' "$path")"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$name" "test -d $q" >/dev/null 2>&1
}

# 将 ssh 命令的输出/退出码转换为用户能看懂的中文错误提示
interpret_ssh_error() {
    local rc="${1:-255}" out="${2:-}" name="${3:-}"
    case "$out" in
        *"Permission denied"*)
            err "认证失败：用户名或密码错误，或公钥尚未部署到目标服务器。"
            [ -n "$name" ] && err "提示: 请执行 ./ssh-manager.sh key $name 部署公钥（需要目标服务器密码）。"
            ;;
        *"Connection refused"*)
            err "连接被拒绝：目标端口未开放或 SSH 服务未运行，也可能是防火墙拦截。"
            ;;
        *"Connection timed out"*)
            err "连接超时：无法到达目标服务器，请检查网络、防火墙和地址是否正确。"
            ;;
        *"No route to host"*)
            err "网络不可达：没有到目标主机的路由，请检查网络配置。"
            ;;
        *"Could not resolve hostname"*|*"Name or service not known"*|*"Temporary failure in name resolution"*)
            err "无法解析主机名：请检查服务器地址（IP/域名）是否正确。"
            ;;
        *"Host key verification failed"*|*"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
            err "主机密钥验证失败：目标服务器的主机密钥已变化（系统重装或被中间人攻击）。"
            err "如需继续，请先清除旧记录: ssh-keygen -R <目标地址>，然后重试。"
            ;;
        *"kex_exchange_identification"*)
            err "连接被关闭：目标服务器可能限制了并发连接，或 fail2ban 临时封禁了你的 IP。"
            ;;
        *"Too many authentication failures"*)
            err "认证尝试次数过多：请检查 ~/.ssh/config 中 IdentityFile 与 IdentitiesOnly 配置。"
            ;;
        *"Connection reset by peer"*)
            err "连接被重置：目标服务器主动断开，可能是防火墙或 fail2ban 导致。"
            ;;
        "")
            err "SSH 操作失败（退出码 $rc），无详细错误输出。"
            err "常见原因: 网络不通、防火墙拦截、目标未运行 SSH 服务。"
            ;;
        *)
            err "SSH 操作失败（退出码 $rc）。"
            err "详细信息: $out"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# 命令实现: 服务器管理
# -----------------------------------------------------------------------------
cmd_list() {
    local conf count=0
    echo
    echo "${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
    echo "${C_BOLD}${C_CYAN}║  📋 服务器列表                                          ║${C_RESET}"
    echo "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"
    echo "${C_DIM}  配置目录: $SERVERS_DIR${C_RESET}"
    echo
    printf "${C_BOLD}%-18s %-28s %-7s %-12s %s${C_RESET}\n" "名称" "地址" "端口" "用户" "配置文件"
    printf "${C_DIM}%-18s %-28s %-7s %-12s %s${C_RESET}\n" "────" "────" "────" "────" "────────"
    if [ -d "$SERVERS_DIR" ]; then
        for conf in "$SERVERS_DIR"/*.conf; do
            [ -f "$conf" ] || continue
            if ! parse_server_conf "$conf"; then
                warn "无法解析: $conf"
                continue
            fi
            printf "${C_GREEN}%-18s${C_RESET} %-28s %-7s %-12s %s\n" "$NAME" "$HOST" "$PORT" "$USER" "$(basename "$conf")"
            count=$((count + 1))
        done
    fi
    echo
    if [ "$count" -eq 0 ]; then
        info "服务器列表为空。请执行 ${C_BOLD}./ssh-manager.sh add${C_RESET} 添加第一台服务器。"
    else
        ok "共 $count 台服务器。连接示例: ${C_BOLD}ssh $NAME${C_RESET}"
    fi
}

cmd_add() {
    local name host port user conf

    # ---- 收集信息 ----
    while :; do
        read -r -p "服务器名称（例如 HK-01，仅限字母/数字/下划线/连字符）: " name || die "输入被取消"
        if valid_name "$name"; then break; fi
        err "名称无效：只能包含字母、数字、下划线、连字符，且不能以 - 开头"
    done
    conf="$(server_conf_path "$name")"
    [ -f "$conf" ] && die "服务器 '$name' 已存在（$conf）。如需修改请执行: ./ssh-manager.sh edit $name"

    while :; do
        read -r -p "服务器地址（IP / 域名 / IPv6，例如 1.2.3.4）: " host || die "输入被取消"
        [ -n "$host" ] && break
        err "服务器地址不能为空"
    done

    read -r -p "SSH 端口（默认 22）: " port || port=""
    port="${port:-22}"
    case "$port" in
        ''|*[!0-9]*) die "端口必须是数字: '$port'" ;;
    esac
    port=$((10#$port))
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "端口超出范围 (1-65535): $port"

    read -r -p "SSH 用户名（默认 root）: " user || user=""
    user="${user:-root}"

    # ---- 写入配置文件（%q 保证特殊字符可安全回读） ----
    mkdir -p "$SERVERS_DIR" 2>/dev/null || die "无法创建服务器配置目录: $SERVERS_DIR"
    chmod 700 "$SERVERS_DIR" 2>/dev/null || true
    {
        echo "# ============================================"
        echo "# SSH 服务器配置: $name"
        echo "# 本文件由 ssh-manager.sh 生成，可手动编辑"
        echo "# 可用字段:"
        echo "#   NAME     服务器名称（连接别名，需唯一）"
        echo "#   HOST     服务器 IP / 域名 / IPv6 地址"
        echo "#   PORT     SSH 端口（默认 22）"
        echo "#   USER     SSH 用户名（默认 root）"
        echo "#   PASSWORD SSH 密码（强烈不建议保存！仅用于公钥部署）"
        echo "#   IDENTITY 指定使用的私钥路径（默认自动选择）"
        echo "# ============================================"
        printf 'NAME=%q\n' "$name"
        printf 'HOST=%q\n' "$host"
        printf 'PORT=%q\n' "$port"
        printf 'USER=%q\n' "$user"
    } > "$conf"
    chmod 600 "$conf"
    ok "已创建服务器配置: $conf"

    # ---- 可选: 保存密码（默认不保存） ----
    if confirm "是否将 SSH 密码保存到配置文件？（强烈不建议，仅当服务器不支持公钥登录时才需要）"; then
        local pw1 pw2
        read -r -s -p "请输入 $name 的 SSH 密码: " pw1; echo
        read -r -s -p "请再次输入密码确认: " pw2; echo
        if [ -n "$pw1" ] && [ "$pw1" = "$pw2" ]; then
            {
                echo
                echo "# 注意: 明文密码存在安全风险！部署公钥成功后脚本会自动提示删除。"
                printf 'PASSWORD=%q\n' "$pw1"
            } >> "$conf"
            chmod 600 "$conf"
            warn "密码已保存到 $conf（权限 600）。建议尽快执行: ./ssh-manager.sh key $name 完成免密后删除密码"
            have sshpass || warn "提示: 当前未安装 sshpass，保存的密码无法被脚本自动使用（安装: $(install_hint sshpass)）"
        else
            warn "两次输入不一致或密码为空，未保存密码（推荐，更安全）"
        fi
    fi

    update_ssh_config
    ok "已同步 ~/.ssh/config，现在可以直接: ssh $name"

    if confirm "是否现在部署 SSH 公钥（免密登录配置）？"; then
        cmd_key "$name"
    fi
}

cmd_remove() {
    local name="${1:-}" conf host
    [ -n "$name" ] || die "用法: ./ssh-manager.sh remove <名称>"
    conf="$(server_conf_path "$name")"
    [ -f "$conf" ] || die "找不到服务器 '$name' 的配置文件（$conf）"

    parse_server_conf "$conf" || true
    info "即将删除服务器: $name ($HOST:$PORT, 用户 $USER)"
    confirm "确定要删除吗？" || { info "已取消删除"; return 0; }

    rm -f "$conf"
    ok "已删除配置文件: $conf"
    update_ssh_config
    ok "已同步 ~/.ssh/config"

    if confirm "是否同时从 ~/.ssh/known_hosts 中移除该服务器记录？"; then
        host="${HOST:-}"
        if [ -n "$host" ]; then
            if is_ipv6_addr "$host"; then
                ssh-keygen -R "[$host]" >/dev/null 2>&1 || true
            else
                ssh-keygen -R "$host" >/dev/null 2>&1 || true
            fi
            ok "已移除 known_hosts 中的记录"
        fi
    fi
}

cmd_edit() {
    local name="${1:-}" conf editor
    [ -n "$name" ] || die "用法: ./ssh-manager.sh edit <名称>"
    conf="$(server_conf_path "$name")"
    [ -f "$conf" ] || die "找不到服务器 '$name' 的配置文件（$conf）"

    editor="${EDITOR:-}"
    if [ -z "$editor" ]; then
        for e in vim vi nano; do
            if have "$e"; then editor="$e"; break; fi
        done
    fi
    [ -n "$editor" ] || editor="vi"

    info "正在用 $editor 编辑: $conf（保存后将自动校验并同步 ~/.ssh/config）"
    $editor "$conf" || die "编辑器异常退出"

    if parse_server_conf "$conf"; then
        ok "配置校验通过"
        update_ssh_config
        ok "已同步 ~/.ssh/config"
    else
        err "配置无效，请重新编辑修正: $conf"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 命令实现: 公钥部署与连接测试
# -----------------------------------------------------------------------------
cmd_key() {
    local name="${1:-}"
    [ -n "$name" ] || die "用法: ./ssh-manager.sh key <名称>"

    load_server "$name"
    ensure_local_key
    [ -f "$PUB_KEY" ] || die "找不到本地公钥文件: $PUB_KEY"
    update_ssh_config

    local target out rc pub remote_cmd had_password=0
    target="$(ssh_target "$USER" "$HOST")"
    [ -n "${PASSWORD:-}" ] && had_password=1

    # 未保存密码时: 有 sshpass 则读取一次密码复用；没有则直接让 ssh 交互式提示（最安全）
    if [ -z "${PASSWORD:-}" ] && have sshpass; then
        read -r -s -p "请输入 $NAME 的 SSH 密码（用于首次部署公钥）: " PASSWORD; echo
        [ -n "$PASSWORD" ] || { err "密码不能为空，已取消"; return 1; }
    fi

    info "目标: $target:$PORT"
    info "本地公钥: $PUB_KEY"

    # ---- 部署公钥 ----
    if have ssh-copy-id; then
        info "检测到 ssh-copy-id，使用 ssh-copy-id 部署..."
        out="$(run_with_pass ssh-copy-id $HK_OPTS -i "$PUB_KEY" -p "$PORT" -o ConnectTimeout=15 "$target" 2>&1)"
        rc=$?
    else
        info "未检测到 ssh-copy-id，使用内置方式部署（自动创建 ~/.ssh 并追加公钥，重复公钥自动去重）..."
        pub="$(cat "$PUB_KEY" 2>/dev/null)" || { err "无法读取公钥文件: $PUB_KEY"; return 1; }
        # 远端执行: 建目录 -> 公钥去重追加 -> 收紧权限（只追加，绝不覆盖）
        remote_cmd="umask 077 && mkdir -p ~/.ssh && chmod 700 ~/.ssh && { grep -qxF '$pub' ~/.ssh/authorized_keys 2>/dev/null || printf '%s\n' '$pub' >> ~/.ssh/authorized_keys; } && chmod 600 ~/.ssh/authorized_keys"
        out="$(run_with_pass ssh $HK_OPTS -p "$PORT" -o ConnectTimeout=15 "$target" "$remote_cmd" 2>&1)"
        rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
        err "公钥部署失败（退出码 $rc）"
        interpret_ssh_error "$rc" "$out" "$name"
        return 1
    fi
    ok "公钥已写入目标服务器: $target"

    # ---- 验证免密登录（BatchMode: 禁止密码提示，确保是纯密钥认证） ----
    info "正在验证免密登录..."
    out="$(ssh -o BatchMode=yes $HK_OPTS -p "$PORT" -o ConnectTimeout=15 "$target" 'echo KEYLOGIN_OK' 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "免密登录验证通过！现在可以直接: ssh $name"
    else
        err "公钥已写入，但免密登录验证失败（退出码 $rc）"
        interpret_ssh_error "$rc" "$out" "$name"
        return 1
    fi

    # ---- 部署成功: 询问是否删除配置中的明文密码 ----
    if [ "$had_password" -eq 1 ]; then
        if confirm_default_yes "公钥已部署成功，是否删除配置文件中的明文密码？"; then
            sed -i '/^[[:space:]]*PASSWORD=/d' "$(server_conf_path "$name")"
            ok "已从配置文件中删除 PASSWORD 行"
        else
            warn "已保留 PASSWORD（存在安全风险，建议尽快手动删除）"
        fi
    fi
}

cmd_checkkey() {
    local name="${1:-}" out rc
    [ -n "$name" ] || die "用法: ./ssh-manager.sh checkkey <名称>"
    load_server "$name"
    update_ssh_config

    info "正在测试 $name 的免密登录（纯密钥认证）..."
    out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 $HK_OPTS "$name" 'echo KEYLOGIN_OK' 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "$name 免密登录正常"
    else
        err "$name 免密登录失败（退出码 $rc）"
        interpret_ssh_error "$rc" "$out" "$name"
        err "提示: 请先执行 ./ssh-manager.sh key $name 部署公钥"
        return 1
    fi
}

cmd_test() {
    local name="${1:-}" out rc
    [ -n "$name" ] || die "用法: ./ssh-manager.sh test <名称>"
    load_server "$name"
    update_ssh_config

    info "正在测试连接 $name ($HOST:$PORT) ..."
    out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 $HK_OPTS "$name" 'echo CONNECT_OK; whoami; hostname' 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "连接成功: $name"
        echo "$out"
    else
        err "连接测试失败（退出码 $rc）"
        interpret_ssh_error "$rc" "$out" "$name"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 命令实现: 日常操作
# -----------------------------------------------------------------------------
cmd_ssh() {
    local name="${1:-}"
    [ -n "$name" ] || die "用法: ./ssh-manager.sh ssh <名称>"
    load_server "$name"
    update_ssh_config

    info "正在连接 $name（退出远程 shell 后返回）..."
    ssh -o ConnectTimeout=10 "$name"
    local rc=$?
    [ "$rc" -ne 0 ] && err "SSH 会话结束（退出码 $rc）"
    return "$rc"
}

cmd_exec() {
    local name="${1:-}" cmd
    [ -n "$name" ] || die "用法: ./ssh-manager.sh exec <名称> \"远程命令\""
    if [ $# -ge 2 ]; then shift; fi
    cmd="$*"
    [ -n "$cmd" ] || die "请提供要执行的远程命令，例如: ./ssh-manager.sh exec $name \"df -h\""

    load_server "$name"
    update_ssh_config
    run_with_pass ssh -o ConnectTimeout=10 "$name" "$cmd"
    local rc=$?
    return "$rc"
}

cmd_upload() {
    local name="${1:-}" src="${2:-}" dst="${3:-}" rsrc flag rc=0
    if [ -z "$name" ] || [ -z "$src" ] || [ -z "$dst" ]; then
        die "用法: ./ssh-manager.sh upload <名称> <本地路径> <远程路径>"
    fi
    [ -e "$src" ] || die "本地路径不存在: $src"
    load_server "$name"
    update_ssh_config

    if have rsync; then
        info "使用 rsync 上传（增量、高效）..."
        # 目录源加尾斜杠: 目标路径 = 最终位置（与 scp 语义一致，避免嵌套）
        rsrc="$src"
        [ -d "$src" ] && rsrc="${src%/}/"
        run_with_pass rsync -avz -e "ssh -o ConnectTimeout=10" "$rsrc" "$name:$dst"
        rc=$?
    else
        have scp || die "未找到 scp 命令，请安装: $(install_hint scp)"
        info "未检测到 rsync，改用 scp 上传..."
        flag=""
        [ -d "$src" ] && flag="-r"
        run_with_pass scp $flag -o ConnectTimeout=10 "$src" "$name:$dst"
        rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
        ok "上传完成: $src -> $name:$dst"
    else
        err "上传失败（退出码 $rc）"
        err "提示: 检查网络/用户名/远程路径权限；如尚未免密，请先执行 ./ssh-manager.sh key $name"
    fi
    return "$rc"
}

cmd_download() {
    local name="${1:-}" src="${2:-}" dst="${3:-}" rsrc rc=0
    if [ -z "$name" ] || [ -z "$src" ] || [ -z "$dst" ]; then
        die "用法: ./ssh-manager.sh download <名称> <远程路径> <本地路径>"
    fi
    load_server "$name"
    update_ssh_config

    if have rsync; then
        info "使用 rsync 下载（增量、高效）..."
        # 远程是目录时源加尾斜杠: 目标路径 = 最终位置（与 scp 语义一致，避免嵌套）
        rsrc="$src"
        if remote_is_dir "$name" "$src"; then
            rsrc="${src%/}/"
            info "远程路径是目录，将同步目录内容到: $dst"
        fi
        run_with_pass rsync -avz -e "ssh -o ConnectTimeout=10" "$name:$rsrc" "$dst"
        rc=$?
    else
        have scp || die "未找到 scp 命令，请安装: $(install_hint scp)"
        info "未检测到 rsync，改用 scp 下载..."
        run_with_pass scp -r -o ConnectTimeout=10 "$name:$src" "$dst"
        rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
        ok "下载完成: $name:$src -> $dst"
    else
        err "下载失败（退出码 $rc）"
        err "提示: 检查网络/用户名/远程路径权限；如尚未免密，请先执行 ./ssh-manager.sh key $name"
    fi
    return "$rc"
}

cmd_config() {
    update_ssh_config || { err "SSH 配置同步失败"; return 1; }
    ok "已同步 SSH 配置: $SSH_CONFIG"
    echo
    echo "${C_BOLD}${C_CYAN}┌── SSH-MANAGER 管理区 ─────────────────────────────┐${C_RESET}"
    if [ -f "$SSH_CONFIG" ]; then
        sed -n "/^${BEGIN_MARK}$/,/^${END_MARK}$/p" "$SSH_CONFIG" | sed "s/^/  /" || true
    fi
    echo "${C_BOLD}${C_CYAN}└──────────────────────────────────────────────────┘${C_RESET}"
    echo "${C_DIM}  提示: 此区域由脚本自动维护，手动修改会在下次同步时被覆盖${C_RESET}"
}

cmd_install() {
    local src="$SCRIPT_DIR/ssh-manager.sh" dst="/usr/local/bin/ssh-manager"
    [ -f "$src" ] || die "找不到脚本本身: $src"
    chmod +x "$src"
    if [ -w /usr/local/bin ]; then
        ln -sf "$src" "$dst"
    elif have sudo; then
        sudo ln -sf "$src" "$dst" || die "安装失败"
    else
        die "需要 root 权限写入 /usr/local/bin（请用 sudo 执行安装）"
    fi
    ok "已安装: $dst -> $src"
    info "现在可以直接使用: ssh-manager <命令>"
}

cmd_help() {
    echo
    echo "${C_BOLD}${C_CYAN}╔════════════════════════════════════════════════════════════╗${C_RESET}"
    echo "${C_BOLD}${C_CYAN}║  ssh-manager.sh — 通用 SSH 服务器免密管理工具             ║${C_RESET}"
    echo "${C_BOLD}${C_CYAN}╚════════════════════════════════════════════════════════════╝${C_RESET}"
    cat <<'EOF'

用法:
  ./ssh-manager.sh                进入交互式菜单
  ./ssh-manager.sh <命令> [参数]  命令行模式

命令:
  list                           列出所有服务器
  add                            交互式添加服务器
  edit <名称>                    修改服务器配置（打开编辑器）
  remove <名称>                  删除服务器
  key <名称>                     部署 SSH 公钥（免密配置，首次需输入目标服务器密码）
  checkkey <名称>                测试免密登录是否生效
  test <名称>                    测试 SSH 连接
  ssh <名称>                     登录服务器（交互式 shell）
  exec <名称> "<命令>"           远程执行命令，如: ./ssh-manager.sh exec HK-01 "df -h"
  upload <名称> <本地> <远程>    上传文件/目录，如: ./ssh-manager.sh upload HK-01 ./a.txt /root/a.txt
  download <名称> <远程> <本地>  下载文件/目录，如: ./ssh-manager.sh download HK-01 /root/a.txt ./a.txt
  config                         重新生成 ~/.ssh/config（只更新管理区）
  install                        安装到 /usr/local/bin（之后可直接用 ssh-manager）
  help                           显示本帮助

说明:
  · 服务器配置存放在 ./servers/<名称>.conf，可直接手动编辑，无需硬编码
  · 首次运行自动生成 ~/.ssh/id_ed25519 密钥（已有密钥则直接复用，绝不覆盖）
  · 部署公钥后，直接执行: ssh <名称> 即可免密登录
  · 支持 IPv4 / IPv6 / 域名，支持自定义端口
  · 密码默认不写入任何文件；部署公钥成功后自动提示删除已保存的密码
  · 终端支持颜色自动开启；设置 NO_COLOR=1 或管道输出时自动使用纯文本
EOF
}

# -----------------------------------------------------------------------------
# 交互式菜单
# -----------------------------------------------------------------------------
menu() {
    local choice _name _src _dst _cmd _f count=0
    while true; do
        # 统计当前服务器数量（用于菜单顶部状态行）
        count=0
        if [ -d "$SERVERS_DIR" ]; then
            for _f in "$SERVERS_DIR"/*.conf; do
                [ -f "$_f" ] && count=$((count + 1))
            done
        fi

        echo
        echo "${C_BOLD}${C_CYAN}╔══════════════════════════════════════════╗${C_RESET}"
        echo "${C_BOLD}${C_CYAN}║      🔐  SSH 服务器管理器                ║${C_RESET}"
        echo "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════╝${C_RESET}"
        echo "${C_DIM}   服务器 ${count} 台    本地密钥: ${KEY_TYPE:-无}    输入 0 退出${C_RESET}"
        echo
        echo "  ${C_BOLD}${C_GREEN}── 服务器管理 ──${C_RESET}"
        echo "  ${C_GREEN}1${C_RESET}. 服务器列表"
        echo "  ${C_GREEN}2${C_RESET}. 添加服务器"
        echo "  ${C_GREEN}3${C_RESET}. 修改服务器"
        echo "  ${C_GREEN}4${C_RESET}. 删除服务器"
        echo
        echo "  ${C_BOLD}${C_GREEN}── 免密与连接 ──${C_RESET}"
        echo "  ${C_GREEN}5${C_RESET}. 部署 SSH 公钥（免密配置）"
        echo "  ${C_GREEN}6${C_RESET}. 测试免密登录"
        echo "  ${C_GREEN}7${C_RESET}. 测试连接"
        echo "  ${C_GREEN}8${C_RESET}. SSH 登录"
        echo
        echo "  ${C_BOLD}${C_GREEN}── 文件与命令 ──${C_RESET}"
        echo "  ${C_GREEN}9${C_RESET}. 上传文件"
        echo "  ${C_GREEN}10${C_RESET}. 下载文件"
        echo "  ${C_GREEN}11${C_RESET}. 执行远程命令"
        echo
        echo "  ${C_BOLD}${C_MAGENTA}── 其他 ──${C_RESET}"
        echo "  ${C_GREEN}12${C_RESET}. 重新生成 SSH 配置"
        echo "  ${C_GREEN}13${C_RESET}. 帮助"
        echo "  ${C_RED}0${C_RESET}. 退出"
        echo "${C_BOLD}${C_CYAN}────────────────────────────────────────${C_RESET}"
        read -r -p "${C_BOLD}请选择 [0-13]: ${C_RESET}" choice || break

        case "$choice" in
            1) cmd_list ;;
            2) cmd_add ;;
            3) read -r -p "服务器名称: " _name || break
               cmd_edit "${_name:-}" ;;
            4) read -r -p "服务器名称: " _name || break
               cmd_remove "${_name:-}" ;;
            5) read -r -p "服务器名称: " _name || break
               cmd_key "${_name:-}" ;;
            6) read -r -p "服务器名称: " _name || break
               cmd_checkkey "${_name:-}" ;;
            7) read -r -p "服务器名称: " _name || break
               cmd_test "${_name:-}" ;;
            8) read -r -p "服务器名称: " _name || break
               cmd_ssh "${_name:-}" ;;
            9) read -r -p "服务器名称: " _name || break
               read -r -p "本地路径: " _src || break
               read -r -p "远程路径: " _dst || break
               cmd_upload "${_name:-}" "${_src:-}" "${_dst:-}" ;;
            10) read -r -p "服务器名称: " _name || break
                read -r -p "远程路径: " _src || break
                read -r -p "本地路径: " _dst || break
                cmd_download "${_name:-}" "${_src:-}" "${_dst:-}" ;;
            11) read -r -p "服务器名称: " _name || break
                read -r -p "远程命令: " _cmd || break
                cmd_exec "${_name:-}" "${_cmd:-}" ;;
            12) cmd_config ;;
            13) cmd_help ;;
            0) echo "再见 👋"; break ;;
            *) warn "无效选择: $choice" ;;
        esac

        if [ "$choice" != "0" ]; then
            read -r -p "按回车键继续..." _ || break
        fi
    done
}

# -----------------------------------------------------------------------------
# 命令分发
# -----------------------------------------------------------------------------
dispatch() {
    local cmd="${1:-}"
    case "$cmd" in
        list)                       cmd_list ;;
        add)                        cmd_add ;;
        edit)                       cmd_edit "${2:-}" ;;
        remove|rm|del|delete)       cmd_remove "${2:-}" ;;
        key|deploy)                 cmd_key "${2:-}" ;;
        checkkey|check-key)         cmd_checkkey "${2:-}" ;;
        test)                       cmd_test "${2:-}" ;;
        ssh|login)                  cmd_ssh "${2:-}" ;;
        exec|run)                   shift; cmd_exec "$@" ;;
        upload|put)                 shift; cmd_upload "$@" ;;
        download|get)               shift; cmd_download "$@" ;;
        config|sync)                cmd_config ;;
        install)                    cmd_install ;;
        help|-h|--help)             cmd_help ;;
        *)
            err "未知命令: $cmd"
            cmd_help
            exit 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# 入口
# -----------------------------------------------------------------------------
main() {
    setup_colors       # 0. 初始化终端颜色（管道/NO_COLOR 时自动禁用）
    check_deps          # 1. 依赖检查（缺失给安装提示）
    detect_hostkey_opt  # 2. 按 OpenSSH 版本选择主机密钥校验方式
    ensure_local_key    # 3. 确保本地密钥存在（不存在则生成，绝不覆盖已有）
    mkdir -p "$SERVERS_DIR" 2>/dev/null || warn "无法创建服务器配置目录: $SERVERS_DIR"
    update_ssh_config   # 4. 同步 ~/.ssh/config（只修改管理区）

    if [ $# -eq 0 ]; then
        menu
    else
        dispatch "$@"
    fi
}

main "$@"
