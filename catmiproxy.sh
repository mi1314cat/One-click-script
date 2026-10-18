#!/bin/bash
# =============================================================
#  Catmiproxy 内核管理面板 v2 · 独立脚本
# -------------------------------------------------------------
#  四内核 + 公共分享服务, 一个入口全部搞定:
#    1) Xray      -> mi1314cat/xray--core        install.sh server
#                    (xHTTP 四模式 / 上下行分离 / ECH / ML-KEM / ML-DSA)
#    2) Mihomo    -> mi1314cat/mihomo--core      install.sh server
#                    (24 种生成器: xhttp+REALITY / anytls / tuic / snell ...)
#    3) Sing-box  -> mi1314cat/sing-box-core     install.sh
#                    (9 协议, 含 AnyTLS+REALITY)
#    4) Hysteria2 -> mi1314cat/hysteria2-core    hy2-panel.sh
#    公) 分享服务 -> mi1314cat/Share-Service      install.sh
#                    (X / M / SB 三家共用的 token/TTL 服务)
#
#  由主面板或一键命令调用:
#    bash <(curl -fsSL .../catmiproxy.sh)            # 总菜单
#    bash <(curl -fsSL .../catmiproxy.sh) xray       # 直达 Xray
#    bash <(curl -fsSL .../catmiproxy.sh) mihomo     # 直达 Mihomo
#    bash <(curl -fsSL .../catmiproxy.sh) singbox    # 直达 Sing-box
#    bash <(curl -fsSL .../catmiproxy.sh) hysteria   # 直达 Hysteria2
#    bash <(curl -fsSL .../catmiproxy.sh) share      # 直达公共分享服务
#  本文件必须保持 LF(Unix) 换行符。
# -------------------------------------------------------------
#  v2 变更:
#    [仓库] X 从旧的 xary-core 换到 **mi1314cat/xray--core**
#           (旧仓库里的 unused/xray_install.sh 早已不存在, 点了必然 404)
#    [入口] X 直接调用 install.sh server / --status / server update ——
#           这是新仓库官方入口, 安装/更新/状态各走各的参数, 不再靠"先跑面板再猜"。
#    [取码] 三个镜像轮试 (github raw -> ghproxy -> jsdelivr), 单源不通不再卡死。
#    [新增] 公共分享服务 (proxy-share-service) 的状态 / 安装 / 重启入口 ——
#           X/M/SB 的分享链接都存它, 它挂了三个项目一起发不出链接。
#    [文案] 四内核的能力描述按当前版本重写 (原来写的还是两年期的形态)。
#    [保留] 服务状态用 stat 单位文件判断 (v1 修过的 timeout 竞态不再回退)。
# =============================================================

# 仅在系统支持时启用 UTF-8 locale(保证中文按 2 列宽度对齐)
if locale -a 2>/dev/null | grep -qi 'C.utf8'; then
    export LC_ALL=C.UTF-8
fi

# 交互保障: 有些面板/包装脚本会把 stdin 关掉或重定向, 菜单会立刻 EOF 退出,
# 看起来像"点了没反应"。脚本以**文件**方式运行时, 直接改从 /dev/tty 读;
# 管道方式 (curl ... | bash) 不能动 fd0 —— 那会把 bash 正在读的脚本流截断,
# 所以只对"脚本是普通文件"这一种安全情形生效。
if [[ ! -t 0 && -f "${BASH_SOURCE[0]:-}" && -r /dev/tty ]]; then
    exec </dev/tty 2>/dev/null || true
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
print_warn()  { echo -e "${YELLOW}[Warn]${PLAIN} $1"; }

# ===========================
#   仓库与入口 (唯一真源)
# ===========================
REPO_XRAY="mi1314cat/xray--core"
REPO_MIHOMO="mi1314cat/mihomo--core"
REPO_SB="mi1314cat/sing-box-core"
REPO_HY="mi1314cat/hysteria2-core"
REPO_SHARE="mi1314cat/Share-Service"

# 各项目的安装目录 / 版本文件 (存在就显示, 不存在不影响)
VER_FILE_XRAY="/root/catmi/xray/.panel/VERSION"
VER_FILE_MIHOMO="/root/catmi/mihomo/src/VERSION"
VER_FILE_SB="/root/catmi/sing-box/src/VERSION"
VER_FILE_HY="/root/catmi/hysteria2-core/VERSION"

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
        echo -e "  ${CYAN}$(pad_disp "$1" 10)${PLAIN} ${GREEN}${v1}${PLAIN}  ${CYAN}${3}${PLAIN}  ${GREEN}${4}${PLAIN}"
    else
        echo -e "  ${CYAN}$(pad_disp "$1" 10)${PLAIN} ${GREEN}${2}${PLAIN}"
    fi
}

svc_rows() {  # $1=服务名 $2=显示名
    local svc="$1" name="$2" st en
    st=$(service_state "$svc")
    if [[ "$st" == "未安装" ]]; then
        info2 "$name" "$st"
        return
    fi
    en=$(service_enabled "$svc")
    info2 "$name" "$st" "自启" "${en:-未启用}"
}

menu_v() {  # 竖排单列菜单: [编号] 标题 (标题用分类色)
    local n="$1" t="$2" c="${3:-$GREEN}"
    printf "   ${YELLOW}[%s]${PLAIN} ${c}%s${PLAIN}\n" "$n" "$t"
}

# ===========================
#   输入
# ===========================
read_choice() {
    # ★ 提示必须打到 stderr，答案从 stdout 输出 —— 因为调用方一律写成
    #   choice=$(read_choice "..."): 如果提示和答案都走 stdout，提示会被
    #   命令替换吃掉 (终端上根本看不到"请选择")，而 choice 变成提示文字，
    #   于是任何输入都匹配不上 case → 菜单只重画、永远出不去。
    #   真机实测: 公共分享服务菜单就是这样"卡住、无法选择"的。
    local prompt="$1" c
    printf "%s" "$prompt" >&2
    read -r c
    local rc=$?
    printf '%s' "$c"
    return $rc
}

invalid_input() { print_error "无效选择"; sleep 1; }

pause_return() {
    echo
    printf "${GRAY}按回车键返回...${PLAIN}"
    read -r _ || true
}

# ===========================
#   服务状态收集
# ===========================
UNIT_DIRS=(
    /etc/systemd/system
    /run/systemd/system
    /usr/local/lib/systemd/system
    /usr/lib/systemd/system
    /lib/systemd/system
)

# 判断服务是否已安装 —— 只看单位文件在不在。
# 不用 systemctl list-unit-files: 遍历解析全部 unit 在小内存 VPS 上要 1.2~1.5s,
# 极易被超时砍掉并静默退化成"全部未安装"; stat 只要 1ms。
unit_exists() {
    local d
    for d in "${UNIT_DIRS[@]}"; do
        [[ -e "$d/$1.service" ]] && return 0
    done
    return 1
}

build_service_status() {
    local svc
    XRAY_SVC=""; MIHOMO_SVC=""; HY2_SVC=""; SB_SVC=""; SHARE_SVC=""
    for svc in xrayls xray xray-core; do
        unit_exists "$svc" && { XRAY_SVC="$svc"; break; }
    done
    for svc in mihomo mihomo-core clash; do
        unit_exists "$svc" && { MIHOMO_SVC="$svc"; break; }
    done
    for svc in hysteria-server hysteria2 hysteria hy2; do
        unit_exists "$svc" && { HY2_SVC="$svc"; break; }
    done
    local d hy_ins=0 hy_bare_ok=0
    hy_ins=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -c '^hysteria-server@.*\.service')
    if [[ -n "$HY2_SVC" ]]; then
        systemctl is-active --quiet "${HY2_SVC}.service" 2>/dev/null && hy_bare_ok=1
    else
        for d in "${UNIT_DIRS[@]}"; do
            if [[ -e "$d/hysteria-server@.service" ]]; then HY2_SVC="hysteria-server@"; break; fi
        done
    fi
    if [[ "$hy_ins" -gt 0 ]] && (( ! hy_bare_ok )); then
        HY2_SVC="hysteria-server@"
    fi
    for svc in sing-box singbox sb; do
        unit_exists "$svc" && { SB_SVC="$svc"; break; }
    done
    for svc in proxy-share-service proxy-share; do
        unit_exists "$svc" && { SHARE_SVC="$svc"; break; }
    done
}

service_state() {
    local svc="$1"
    if [[ -z "$svc" ]]; then
        echo "未安装"; return
    fi
    if [[ "$svc" == hysteria-server@ ]]; then
        local n
        n=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -c '^hysteria-server@.*\.service')
        (( n > 0 )) && { echo "运行中(${n}节点)"; return; }
        echo "未运行"; return
    fi
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        echo "运行中"
    else
        echo "未运行"
    fi
}

service_enabled() {
    local svc="$1"
    if [[ "$svc" == hysteria-server@ ]]; then echo ""; return; fi
    systemctl is-enabled --quiet "${svc}.service" 2>/dev/null && echo "已启用" || echo ""
}

# 分享服务端口: 它可能因端口回避而不是 9443 (与各面板同一套取法)
share_port() {
    local p=""
    [[ -r /run/proxy-share-service/port ]] && read -r p < /run/proxy-share-service/port 2>/dev/null
    if [[ ! "$p" =~ ^[0-9]+$ && -r /etc/proxy-share-service/env ]]; then
        p=$(sed -n 's/^SHARE_PORT=//p' /etc/proxy-share-service/env 2>/dev/null | head -1 | tr -d '"')
    fi
    [[ "$p" =~ ^[0-9]+$ ]] || p=9443
    printf '%s' "$p"
}

share_health_ok() {
    local port; port=$(share_port)
    curl -fsS --max-time 4 "http://127.0.0.1:${port}/api/v1/health" 2>/dev/null | grep -q '"status"' 2>/dev/null
}

# 项目版本 (存在才显示)
pkg_version() {
    local f="$1"
    [[ -r "$f" ]] || return 0
    head -1 "$f" 2>/dev/null | tr -d '[:space:]'
}

# ===========================
#   远程取码: 三个镜像轮试
# ===========================
remote_urls() {  # <repo> <path>
    local repo="$1" path="$2"
    printf '%s\n' "https://github.com/${repo}/raw/refs/heads/main/${path}"
    printf '%s\n' "https://ghproxy.net/https://raw.githubusercontent.com/${repo}/main/${path}"
    printf '%s\n' "https://fastly.jsdelivr.net/gh/${repo}@main/${path}"
}

# 下载并返回临时文件路径 (stdout), 失败返回非 0
fetch_remote() {  # <repo> <path>
    local repo="$1" path="$2" tmp url
    tmp=$(mktemp /tmp/catmi-remote.XXXXXX) || { print_error "创建临时文件失败"; return 1; }
    while IFS= read -r url; do
        if curl -fsSL --connect-timeout 6 -m 120 -o "$tmp" "$url" 2>/dev/null \
           && [[ -s "$tmp" ]] && [[ "$(head -c 2 "$tmp")" == "#!" ]]; then
            printf '%s' "$tmp"
            return 0
        fi
    done < <(remote_urls "$repo" "$path")
    rm -f "$tmp"
    print_error "三个源都取不到: ${repo}/${path}"
    return 1
}

# 下载并执行
run_project() {  # <repo> <path> [参数...]
    local repo="$1" path="$2"; shift 2
    local tmp rc
    print_info "正在获取 ${repo}/${path}"
    tmp=$(fetch_remote "$repo" "$path") || return 1
    print_info "开始执行: ${path}${*:+ $*}"
    bash "$tmp" "$@"
    rc=$?
    rm -f "$tmp"
    return $rc
}

# ===========================
#   各项目的动作 (入口只在这里, 菜单只调它)
# ===========================
xray_open()     { run_project "$REPO_XRAY" install.sh server; }
xray_update()   { run_project "$REPO_XRAY" install.sh server update; }
xray_status()   { run_project "$REPO_XRAY" install.sh --status; }

mihomo_open()   { run_project "$REPO_MIHOMO" install.sh server; }
# M 的 install.sh 进面板前会自己比对版本并更新, 所以"更新"= 再进一次
mihomo_update() { run_project "$REPO_MIHOMO" install.sh server; }

sb_open()       { run_project "$REPO_SB" install.sh; }

hy_open()       { run_project "$REPO_HY" hy2-panel.sh; }

share_install() { run_project "$REPO_SHARE" install.sh; }

show_log() {  # <service>
    local svc="$1"
    if [[ -z "$svc" ]]; then print_error "服务未安装"; return 1; fi
    print_info "最近 120 行日志 (Ctrl+C 退出)"
    journalctl -u "${svc}.service" -n 120 --no-pager 2>/dev/null || print_error "读不到日志 (journalctl 不可用?)"
    return 0
}

restart_svc() {  # <service>
    local svc="$1"
    if [[ -z "$svc" ]]; then print_error "服务未安装"; return 1; fi
    systemctl restart "${svc}.service" 2>/dev/null
    systemctl status "${svc}.service" --no-pager 2>/dev/null | head -12 || true
    return 0
}

# ---------- 一键三内核: 仓库与路径 ----------
REPO_X="mi1314cat/xray--core"
REPO_M="mi1314cat/mihomo--core"
REPO_SB="mi1314cat/sing-box-core"
RAW_X="https://raw.githubusercontent.com/${REPO_X}/main"
RAW_M="https://raw.githubusercontent.com/${REPO_M}/main"
RAW_SB="https://raw.githubusercontent.com/${REPO_SB}/main"
ROOT_X="${XRAY_ROOT:-/root/catmi/xray}"
ROOT_M="${MIHOMO_ROOT:-/root/catmi/mihomo}"
ROOT_SB="${SB_ROOT:-/root/catmi/sing-box}"
# 供 ca_main 里的日志函数使用 (与面板配色一致)
C="\033[36m"; G="\033[32m"; Y="\033[33m"; RR="\033[31m"; D="\033[90m"; N="\033[0m"
HOST=""
ONLY="x,m,sb"; DOMAIN=""; CRT=""; KEY=""
NO_CDN=0; FORCE=0; DRY=0
SB_CERT_MODE="real"; M_CERT_MODE="real"

# 一键三内核用的日志/范围辅助 (与面板风格一致)
say()  { printf "  ${C}[--]${N} %s\n" "$*"; }
ok()   { printf "  ${G}[OK]${N} %s\n" "$*"; }
warn() { printf "  ${Y}[!]${N} %s\n" "$*"; }
err()  { printf "  ${RR}[X]${N} %s\n" "$*"; }
title(){ printf "\n  ${C}══ %s ══${N}\n" "$*"; }
want_x()  { [[ "$ONLY" == *",x,"* || "$ONLY" == *",x" ]]; }
want_m()  { [[ "$ONLY" == *",m,"* || "$ONLY" == *",m" ]]; }
want_sb() { [[ "$ONLY" == *",sb,"* || "$ONLY" == *",sb" ]]; }

# ---------- 远程取码 (三镜像) ----------
fetch_to() {  # <repo> <path> <dst>
    local repo="$1" path="$2" dst="$3" u
    for u in \
        "https://github.com/${repo}/raw/refs/heads/main/${path}" \
        "https://ghproxy.net/https://raw.githubusercontent.com/${repo}/main/${path}" \
        "https://fastly.jsdelivr.net/gh/${repo}@main/${path}" ; do
        if curl -fsSL --connect-timeout 6 -m 180 -o "$dst" "$u" 2>/dev/null \
           && [[ -s "$dst" ]] && [[ "$(head -c 2 "$dst")" == "#!" ]]; then
            return 0
        fi
    done
    return 1
}

# ---------- 状态检测 ----------
x_ready()  { [[ -x "$ROOT_X/xrayls" ]]; }
m_ready()  { [[ -x "$ROOT_M/mihomo" ]]; }
sb_ready() { [[ -x "$ROOT_SB/sing-box" ]]; }

# 已有节点数 —— 全协议是"加节点"不是"重置", 重复跑只会越堆越多。
# 默认已有节点就跳过, 想再来一批用 --force。
x_nodes()  { ls "$ROOT_X"/conf/*.json 2>/dev/null | grep -v '00-base' | wc -l; }
m_nodes()  { ls "$ROOT_M"/conf/config.d/*.yaml 2>/dev/null | wc -l; }
sb_nodes() { ls "$ROOT_SB"/config/*.json 2>/dev/null | grep -v '/00-' | wc -l; }

# ---------- 分享服务 (按 provider 取最新) ----------
share_admin_token() {
    local f=/etc/proxy-share-service/admin.token
    [[ -r "$f" ]] && tr -d '\n' < "$f"
}
share_port() {
    local p=""
    [[ -r /run/proxy-share-service/port ]] && read -r p < /run/proxy-share-service/port 2>/dev/null
    [[ "$p" =~ ^[0-9]+$ ]] || p=$(sed -n 's/^SHARE_PORT=//p' /etc/proxy-share-service/env 2>/dev/null | head -1 | tr -d '"')
    [[ "$p" =~ ^[0-9]+$ ]] || p=9443
    printf '%s' "$p"
}
share_latest() {  # <provider> → "token<TAB>created_at" (最新一条)
    local prov="$1" tok port
    tok=$(share_admin_token); port=$(share_port)
    [[ -n "$tok" ]] || return 1
    curl -fsS --max-time 6 -H "Authorization: Bearer $tok" \
        "http://127.0.0.1:${port}/api/v1/shares?provider=${prov}" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
recs = d if isinstance(d, list) else (d.get("shares") or [])
recs = [r for r in recs if r.get("token")]
if not recs:
    raise SystemExit(1)
live = [r for r in recs
        if r.get("state", "active") == "active" and r.get("enabled", True)
        and (int(r.get("max_uses") or 0) == 0
             or int(r.get("used_count") or 0) < int(r.get("max_uses") or 0))
        and (int(r.get("expires_at") or 0) == 0
             or int(r.get("expires_at") or 0) > __import__("time").time())]
recs_live = [r for r in recs if (int(r.get("max_uses") or 0) == 0
             or int(r.get("used_count") or 0) < int(r.get("max_uses") or 0))]
r = max(live or recs_live or recs, key=lambda x: x.get("created_at") or 0)
print("%s\t%s" % (r["token"], r.get("created_at") or 0))'
}

share_best() {  # <provider> → "token<TAB>bytes"  (活跃记录里内容最全的那条)
    local prov="$1" tok port
    tok=$(share_admin_token); port=$(share_port)
    [[ -n "$tok" ]] || return 1
    curl -fsS --max-time 8 -H "Authorization: Bearer $tok" \
        "http://127.0.0.1:${port}/api/v1/shares?provider=${prov}" 2>/dev/null | python3 -c '
import json, sys, time
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
recs = d if isinstance(d, list) else (d.get("shares") or [])
now = time.time()
def live(r):
    if r.get("state", "active") != "active" or not r.get("enabled", True):
        return False
    mu = int(r.get("max_uses") or 0); uc = int(r.get("used_count") or 0)
    ea = int(r.get("expires_at") or 0)
    return (mu == 0 or uc < mu) and (ea == 0 or ea > now)
recs = [r for r in recs if r.get("token") and live(r)]
if not recs:
    raise SystemExit(1)
# 内容最全的那条 = 节点最多 (订阅 > 单节点); 同大小取最新
r = max(recs, key=lambda x: (int(x.get("content_bytes") or 0), x.get("created_at") or 0))
print("%s\t%d" % (r["token"], int(r.get("content_bytes") or 0)))'
}

public_host() {
    local ip=""
    [[ -n "$HOST" ]] && { printf '%s' "$HOST"; return; }
    local f
    for f in "$ROOT_X/install_info.env" "$ROOT_M/install_info.env" "$ROOT_SB/install_info.env"; do
        [[ -r "$f" ]] || continue
        ip=$(sed -n 's/^link_ip=["'\'']*\([^"'\'']*\).*/\1/p' "$f" | head -1)
        [[ -n "$ip" ]] && { printf '%s' "$ip"; return; }
    done
    curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || true
}

print_share() {  # <label> <provider>
    local label="$1" prov="$2" line tok port host
    line=$(share_latest "$prov") || { printf '  %-8s %s\n' "$label" "（暂无分享记录）"; return; }
    tok=${line%%$'\t'*}; port=$(share_port); host=$(public_host)
    printf '  %-8s %s\n' "$label" "http://${host:-<本机IP>}:${port}/share/${tok}"
}

# ---------- 安装 ----------
install_x() {
    local tmp; tmp=$(mktemp /tmp/xray_install.XXXXXX) || return 1
    say "取 X 内核安装器 ..."
    fetch_to "$REPO_X" "bin/xray_install.sh" "$tmp" || { err "取不到 bin/xray_install.sh"; rm -f "$tmp"; return 1; }
    say "安装 / 更新 Xray 内核 (bin/xray_install.sh)"
    bash "$tmp" </dev/null
    local rc=$?; rm -f "$tmp"
    (( rc == 0 )) && x_ready && ok "X 内核就绪: $ROOT_X/xrayls" || err "X 内核安装失败"
    return $rc
}

install_m() {
    local tmp; tmp=$(mktemp /tmp/mihomo_install.XXXXXX) || return 1
    say "取 M 安装脚本 ..."
    fetch_to "$REPO_M" "install.sh" "$tmp" || { err "取不到 M install.sh"; rm -f "$tmp"; return 1; }
    say "安装 M (install.sh server, 非交互)"
    bash "$tmp" server </dev/null
    local rc=$?; rm -f "$tmp"
    (( rc == 0 )) && m_ready && ok "M 内核就绪: $ROOT_M/mihomo" || err "M 安装失败"
    return $rc
}

install_sb() {
    local tmp; tmp=$(mktemp /tmp/sb_install.XXXXXX) || return 1
    say "取 SB 安装脚本 ..."
    fetch_to "$REPO_SB" "install.sh" "$tmp" || { err "取不到 SB install.sh"; rm -f "$tmp"; return 1; }
    say "安装 SB (install.sh server, 非交互)"
    bash "$tmp" server </dev/null
    local rc=$?; rm -f "$tmp"
    (( rc == 0 )) && sb_ready && ok "SB 内核就绪: $ROOT_SB/sing-box" || err "SB 安装失败"
    return $rc
}

# ---------- 全协议 ----------
run_x() {
    # ★ 必须跑**整包解出来的仓库**: batch.sh 的分离那一段要 source
    #   conf/lib/preset.sh, 证书自检要 lib/cert.sh。只下 conf/batch.sh 到 /tmp
    #   时这些兄弟文件都不在 —— 实测症状是"分离模式表读不到, 跳过 xHTTP
    #   上下行分离"(4 个协议照常生成, 看起来像成功, 实际少了一整类节点)。
    local dir; dir=$(mktemp -d /tmp/xray_repo.XXXXXX) || return 1
    local u
    say "取 X 仓库整包 ..."
    for u in \
        "https://codeload.github.com/${REPO_X}/tar.gz/refs/heads/main" \
        "https://ghproxy.net/https://github.com/${REPO_X}/archive/refs/heads/main.tar.gz" \
        "https://gh-proxy.com/https://github.com/${REPO_X}/archive/refs/heads/main.tar.gz" ; do
        if curl -fsSL --connect-timeout 6 -m 180 -o "$dir/repo.tgz" "$u" 2>/dev/null \
           && tar -tzf "$dir/repo.tgz" >/dev/null 2>&1; then
            break
        fi
    done
    if ! tar -xzf "$dir/repo.tgz" -C "$dir" 2>/dev/null; then
        err "X 仓库整包解压失败"; rm -rf "$dir"; return 1
    fi
    local root; root=$(find "$dir" -maxdepth 1 -mindepth 1 -type d | head -1)
    if [[ ! -f "$root/conf/batch.sh" || ! -f "$root/conf/lib/preset.sh" ]]; then
        err "X 仓库整包不完整 (缺 conf/batch.sh 或 conf/lib/preset.sh)"; rm -rf "$dir"; return 1
    fi
    say "X 全协议 (conf/batch.sh --auto)$([[ -n $DOMAIN ]] && echo "  域名: $DOMAIN")"
    XRAY_RAW="$RAW_X" XRAY_BASE="$ROOT_X" X_BATCH_DOMAIN="$DOMAIN" X_BATCH_LOG_DIR="${LOGDIR:-/tmp}" \
        timeout "${BATCH_TIMEOUT:-1500}" bash "$root/conf/batch.sh" --auto </dev/null
    local rc=$?; rm -rf "$dir"
    (( rc == 0 )) && ok "X 全协议完成" || err "X 全协议失败 (rc=$rc, 详见 ${LOGDIR:-/tmp})"
    return $rc
}

run_m() {
    local tmpdir; tmpdir=$(mktemp -d /tmp/mihomo_repo.XXXXXX) || return 1
    say "取 M 仓库文件 (仅 conf/ 与 share/ 需要的部分由 all.sh 自取)"
    # M 的 all.sh 依赖同仓库的 lib/env.sh 等, 但它自己会按相对路径找;
    # 现场安装过的机器直接用 $ROOT_M/src/conf/all.sh 即可。
    if [[ -x "$ROOT_M/src/conf/all.sh" || -f "$ROOT_M/src/conf/all.sh" ]]; then
        say "M 全协议 ($ROOT_M/src/conf/all.sh --quick)"
        local cargs=(--quick)
        (( FORCE )) && cargs=(--quick --force)
        local envs=(ALL_CERT_MODE="${M_CERT_MODE:-real}")
        (( NO_CDN )) || envs+=(CDN_DOMAIN="$DOMAIN")
        env "${envs[@]}" timeout "${BATCH_TIMEOUT:-1500}" \
            bash "$ROOT_M/src/conf/all.sh" "${cargs[@]}" </dev/null
        local rc=$?
        (( rc == 0 )) && ok "M 全协议完成" || err "M 全协议失败 (rc=$rc)"
        rm -rf "$tmpdir"; return $rc
    fi
    err "M 未安装到 $ROOT_M (先安装再跑全协议)"
    rm -rf "$tmpdir"; return 1
}

run_sb() {
    # SB 的 batch.sh 只有菜单, 没有 --quick 之类的参数:
    #   1) 用 **管道喂 "2"** 选「全协议快速生成」—— 喂 /dev/null 时菜单会连报
    #      "无效选项" 直到它自己的空读守卫退出, 而退出码仍是 0 (实测: 屏幕
    #      上一片报错, 汇总却写"完成", 一个节点都没生成)。
    #   2) SB_NONINTERACTIVE=1 让"端口范围"那一步不提问 (随机区间)。
    #   3) 必须跑**已安装**的那一份: 它按 dirname($0)/../conf/lib.sh 找依赖。
    if [[ ! -r "$ROOT_SB/conf/batch.sh" ]]; then
        err "SB 未安装到 $ROOT_SB (先安装再跑全协议)"
        return 1
    fi
    say "SB 全协议 ($ROOT_SB/conf/batch.sh, 快速生成)"
    local -a sbenv=(SB_BATCH_QUICK=1 SB_NONINTERACTIVE=1 SB_NO_RELOAD=1)
    (( FORCE )) && sbenv+=(SB_BATCH_OVERWRITE=1)   # --force: 覆盖已存在节点
    printf '2\n' | env "${sbenv[@]}" \
    SB_BATCH_CERT="${SB_CERT_MODE:-real}" \
    SB_BATCH_CERT_CRT="${CRT:-}" SB_BATCH_CERT_KEY="${KEY:-}" SB_BATCH_CERT_DOMAIN="${DOMAIN:-}" \
        timeout "${BATCH_TIMEOUT:-1500}" bash "$ROOT_SB/conf/batch.sh"
    local rc=$?
    (( rc == 0 )) && ok "SB 全协议完成" || err "SB 全协议失败 (rc=$rc)"
    return $rc
}

# ---------- 节点命名: 旗帜 + 内核默认值(X/M/SB) + 协议形态 ----------
# 用户约定: 默认值就是内核标识; 自定义时三个内核用同一个前缀 (如 RN/HK)。
#   自定义 "RN"  → 🇺🇸 RN-vless… / 🇺🇸 RN-AnyTLS… / 🇺🇸 RN-anytls…
#   不自定义     → 🇺🇸 X-… / 🇺🇸 M-… / 🇺🇸 SB-…
ca_apply_names() {
    local p="${CATMI_PREFIX:-}"
    p="${p//[[:space:]]/}"
    if [[ -n "$p" ]]; then
        export XRAY_SERVER_NAME="$p"
        export M_TAG_PREFIX="${p}-"
        export SB_SERVER_NAME="$p"
    else
        export XRAY_SERVER_NAME="X"
        export M_TAG_PREFIX="M-"
        export SB_SERVER_NAME="SB"
    fi
    printf '  节点名前缀: %s (X=%s, M=%s, SB=%s)\n' \
        "${p:-默认}" "$XRAY_SERVER_NAME" "$M_TAG_PREFIX" "$SB_SERVER_NAME"
}

ca_main() {
    title "三内核全协议"
    printf "  模式: %s\n" "$([[ $DRY == 1 ]] && echo 预演 || echo 执行)"
    printf "  范围: %s\n" "${ONLY//,/ }"
    [[ -n "$DOMAIN" ]] && printf "  域名: %s\n" "$DOMAIN"
    (( NO_CDN )) && printf "  CDN : %s\n" "跳过"

    # 1) 检测 + 安装
    title "1/3 安装检测"
    local x_ok=0 m_ok=0 sb_ok=0
    want_x && { x_ready && { ok "X 已安装: $ROOT_X ($(x_nodes) 个节点)"; x_ok=1; } || warn "X 未安装"; }
    want_m && { m_ready && { ok "M 已安装: $ROOT_M ($(m_nodes) 个节点)"; m_ok=1; } || warn "M 未安装"; }
    want_sb && { sb_ready && { ok "SB 已安装: $ROOT_SB ($(sb_nodes) 个节点)"; sb_ok=1; } || warn "SB 未安装"; }

    if (( DRY )); then
        title "预演: 将执行"
        want_x  && ! ((x_ok))  && say "安装 X: bin/xray_install.sh"
        want_m  && ! ((m_ok))  && say "安装 M: install.sh server"
        want_sb && ! ((sb_ok)) && say "安装 SB: install.sh server"
        want_x  && say "X 全协议: conf/batch.sh --auto (X_BATCH_DOMAIN=${DOMAIN:-未设})"
        want_m  && say "M 全协议: src/conf/all.sh --quick (CDN_DOMAIN=${DOMAIN:-未设})"
        want_sb && say "SB 全协议: conf/batch.sh (菜单 2 快速生成 + SB_NONINTERACTIVE=1)"
        title "现有分享 (按 provider)"
        print_share "Xray" xray
        print_share "Mihomo" mihomo
        print_share "Sing-box" sing-box
        return 0
    fi

    local fail=0 rc=0
    if want_x; then ((x_ok)) || { install_x || fail=$((fail+1)); }; fi
    if want_m; then ((m_ok)) || { install_m || fail=$((fail+1)); }; fi
    if want_sb; then ((sb_ok)) || { install_sb || fail=$((fail+1)); }; fi

    # 2) 全协议
    title "2/3 全协议生成"
    local n
    local before after
    if want_x; then
        n=$(x_nodes)
        if (( n > 0 )) && (( ! FORCE )); then
            warn "X 已有 $n 个节点, 跳过 (要再来一批加 --force)"
        else
            before=$n; run_x; rc=$?; after=$(x_nodes)
            (( rc == 0 && after > before )) || { (( rc == 0 )) && err "X 跑完了但节点数没变 (仍是 $after)"; fail=$((fail+1)); }
        fi
    fi
    if want_m; then
        n=$(m_nodes)
        if (( n > 0 )) && (( ! FORCE )); then
            warn "M 已有 $n 个节点, 跳过 (要再来一批加 --force)"
        else
            before=$n; run_m; rc=$?; after=$(m_nodes)
            (( rc == 0 && after > before )) || { (( rc == 0 )) && err "M 跑完了但节点数没变 (仍是 $after)"; fail=$((fail+1)); }
        fi
    fi
    if want_sb; then
        n=$(sb_nodes)
        if (( n > 0 )) && (( ! FORCE )); then
            warn "SB 已有 $n 个节点, 跳过 (要再来一批加 --force)"
        else
            before=$n; run_sb; rc=$?; after=$(sb_nodes)
            (( rc == 0 && after > before )) || { (( rc == 0 )) && err "SB 跑完了但节点数没变 (仍是 $after)"; fail=$((fail+1)); }
        fi
    fi

    # 3) 分享链接 (按内核区分)
    title "3/3 分享链接"
    want_x  && print_share "Xray" xray
    want_m  && print_share "Mihomo" mihomo
    want_sb && print_share "Sing-box" sing-box

    echo
    if (( fail )); then err "有 $fail 个步骤失败（上面有原因；每项目日志见 /tmp）"; return 1; fi
    ok "三个内核全协议完成"

    # 一条总链接: 方便客户端只复制一次
    echo
    title "一条总链接 (客户端一键导入)"
    local b; b=$(ca_bundle_create) && printf '  %s\n' "$b" \
        || warn "总链接没生成 (可稍后在服务端菜单 6 重跑, 或用三条单独链接)"
    return 0
}


# ===========================================================
#   6) 一键三内核全协议 (统一输入, 依次执行)
# ===========================================================
# 交互设计: 只问一次, 之后 X → M → SB 全自动, 中间不再问任何东西。
#   · 每个问题都给默认值, 直接回车即可
#   · 支持"预演": 只报告会执行什么, 不动任何文件
#   · 已有节点默认跳过 (全协议是"加节点", 重复跑只会越堆越多)
ca_guess_domain() {
    local f d=""
    # 1) 项目 install_info.env 里记的域名 (M/SB/X 都可能有)
    for f in "$ROOT_X/install_info.env" "$ROOT_M/install_info.env" "$ROOT_SB/install_info.env"; do
        [[ -r "$f" ]] || continue
        d=$(sed -n 's/^domain=["'\'']*\([^"'\'']*\).*/\1/p' "$f" | head -1)
        [[ -n "$d" ]] && { printf '%s' "$d"; return; }
    done
    # 2) 证书文件名里的域名 (xxx_cert.pem / cert-xxx.crt)
    for f in /root/catmi/certs/*_cert.pem /root/catmi/certs/cert-*.crt; do
        [[ -r "$f" ]] || continue
        d=$(basename "$f"); d=${d%_cert.pem}; d=${d#cert-}; d=${d%.crt}
        [[ "$d" == *.* ]] && { printf '%s' "$d"; return; }
    done
}

ca_nodes_of() {  # x|m|sb
    case "$1" in
        x) x_nodes ;; m) m_nodes ;; sb) sb_nodes ;;
    esac
}

all_wizard() {
    local scope dom def_dom cert_mode crt key cdn dry confirm
    build_service_status
    clear 2>/dev/null || true
    box_top "一键三内核全协议"
    info2 "Xray" "$(service_state "$XRAY_SVC")  $(ca_nodes_of x) 节点"
    info2 "Mihomo" "$(service_state "$MIHOMO_SVC")  $(ca_nodes_of m) 节点"
    info2 "Sing-box" "$(service_state "$SB_SVC")  $(ca_nodes_of sb) 节点"
    info2 "分享服务" "$(service_state "$SHARE_SVC")"
    box_mid
    echo -e "  ${GRAY}一次输入, 之后三个项目依次自动执行, 中间不再提问${PLAIN}"
    box_bot
    echo

    local pfx
    printf "  ${CYAN}1) 范围${PLAIN} [1=全部 2=仅X 3=仅M 4=仅SB] (默认 1): "
    read -r scope || return 0
    case "${scope:-1}" in
        2) ONLY="x" ;; 3) ONLY="m" ;; 4) ONLY="sb" ;; *) ONLY="x,m,sb" ;;
    esac
    ONLY=",$(printf '%s' "$ONLY" | tr '[:upper:]' '[:lower:]' | tr -s ' ,' ',')"

    printf "  ${CYAN}2) 节点名前缀${PLAIN} (回车=按内核默认 X/M/SB, 自定义如 RN/HK): "
    read -r pfx || return 0
    CATMI_PREFIX="${pfx// /}"

    def_dom=$(ca_guess_domain)
    printf "  ${CYAN}3) 域名${PLAIN} (回车=%s): " "${def_dom:-不设置}"
    read -r dom || return 0
    DOMAIN="${dom:-$def_dom}"

    printf "  ${CYAN}4) 证书${PLAIN} [1=自动检测 2=手动给路径 3=自签(仅 M/SB)] (默认 1): "
    read -r cert_mode || return 0
    CRT=""; KEY=""; SB_CERT_MODE="real"; M_CERT_MODE="real"
    case "${cert_mode:-1}" in
        2)
            printf "    证书 fullchain 路径: "; read -r crt || return 0
            printf "    私钥路径: "; read -r key || return 0
            CRT="$crt"; KEY="$key"
            ;;
        3) SB_CERT_MODE="self"; M_CERT_MODE="self" ;;
    esac

    printf "  ${CYAN}5) 生成 CDN 档${PLAIN}? [y/N] (默认 N, 第一次建议 N): "
    read -r cdn || return 0
    [[ "${cdn:-n}" == [yY]* ]] && NO_CDN=0 || NO_CDN=1

    printf "  ${CYAN}6) 预演只报告${PLAIN}? [y/N] (默认 N): "
    read -r dry || return 0
    [[ "${dry:-n}" == [yY]* ]] && DRY=1 || DRY=0

    printf "  ${CYAN}7) 已有节点也重建${PLAIN}? [y/N] (默认 N, 会新增一轮节点): "
    read -r force || return 0
    [[ "${force:-n}" == [yY]* ]] && FORCE=1 || FORCE=0
    echo
    printf "  ${CYAN}将执行${PLAIN}: 范围=%s  前缀=%s  域名=%s  证书=%s  CDN=%s  模式=%s\n" \
        "${ONLY//,/ }" "${CATMI_PREFIX:-默认 X/M/SB}" "${DOMAIN:-未设}" "${crt:-自动检测}" \
        "$([[ $NO_CDN == 1 ]] && echo 跳过 || echo 生成)" \
        "$([[ $DRY == 1 ]] && echo 预演 || echo 执行)$([[ $FORCE == 1 ]] && echo ", 覆盖重建")"
    printf "  ${GRAY}回车开始 / n 取消${PLAIN}: "
    read -r confirm || return 0
    [[ "${confirm:-}" == [nN]* ]] && { info "已取消"; return 0; }

    ca_main
    pause_return
}

# ===========================
#   主菜单
# ===========================
draw_main_menu() {
    clear 2>/dev/null || true
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
    svc_rows "$XRAY_SVC" "Xray"
    svc_rows "$MIHOMO_SVC" "Mihomo"
    svc_rows "$SB_SVC" "Sing-box"
    svc_rows "$HY2_SVC" "Hysteria2"
    box_mid "公共分享服务"
    if [[ -n "$SHARE_SVC" ]]; then
        local hp; hp=$(share_port)
        if share_health_ok; then
            info2 "状态" "运行中" "端口" "$hp"
        else
            info2 "状态" "未运行/异常" "端口" "$hp"
        fi
    else
        info2 "状态" "未安装 (任一面板发分享时会自动装)"
    fi
    box_bot

    box_top "功能菜单"
    box_mid "服务端"
    menu_v "1" "Xray       - xHTTP 四模式 / 上下行分离 / ECH / 后量子"  "$GREEN"
    menu_v "2" "Mihomo     - 24 种生成器: xhttp+REALITY / anytls / tuic"  "$GREEN"
    menu_v "3" "Sing-box   - 9 协议, 含 AnyTLS+REALITY"                 "$GREEN"
    menu_v "4" "Hysteria2  - QUIC 高速传输 (独立项目)"                  "$GREEN"
    menu_v "5" "公共分享服务 - 状态 / 安装 / 重启 (X/M/SB 共用)"       "$BLUE"
    menu_v "6" "一键三内核全协议 - 统一输入, 依次生成 X + M + SB"     "$MAGENTA"
    box_mid "客户端"
    menu_v "7" "客户端一键导入 - 一条总链接, 自动分给 X/M/SB 客户端"   "$MAGENTA"
    box_mid
    menu_v "0" "返回主面板"                                            "$RED"
    box_bot

    echo
    echo -ne "${GREEN}  请选择操作: ${PLAIN}"
}

# ===========================
#   通用子菜单头部/尾部
# ===========================
sub_header() {  # <标题> <版本值> <服务名>
    local title="$1" ver="${2:-}" svc="$3"
    box_top "$title"
    info2 "状态" "$(service_state "$svc")" "版本" "${ver:-未知}"
    box_mid
}

sub_footer() {
    menu_v "0" "返回上一级" "$RED"
    box_bot
    echo
}

# ===========================
#   1) Xray
# ===========================
xray_menu() {
    local choice rc
    while true; do
        clear 2>/dev/null || true
        sub_header "Xray 管理" "$(pkg_version "$VER_FILE_XRAY")" "$XRAY_SVC"
        menu_v "1" "打开服务端面板 (安装 / 进入)"
        menu_v "2" "更新面板与内核"
        menu_v "3" "查看状态 (install.sh --status)"
        menu_v "4" "重启 xrayls"
        menu_v "5" "查看日志"
        sub_footer
        choice=$(read_choice "  请选择 [0-5]: ")
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"
        case $choice in
            0) return 0 ;;
            1) xray_open; pause_return ;;
            2) xray_update; pause_return ;;
            3) xray_status; pause_return ;;
            4) restart_svc "${XRAY_SVC:-xrayls}"; pause_return ;;
            5) show_log "${XRAY_SVC:-xrayls}"; pause_return ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   2) Mihomo
# ===========================
mihomo_menu() {
    local choice rc
    while true; do
        clear 2>/dev/null || true
        sub_header "Mihomo 管理" "$(pkg_version "$VER_FILE_MIHOMO")" "$MIHOMO_SVC"
        menu_v "1" "打开面板 (安装 / 进入面板)"
        menu_v "2" "检查并更新 (重新进入即自动比对版本)"
        menu_v "3" "查看状态"
        menu_v "4" "重启 mihomo"
        menu_v "5" "查看日志"
        sub_footer
        choice=$(read_choice "  请选择 [0-5]: ")
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"
        case $choice in
            0) return 0 ;;
            1) mihomo_open; pause_return ;;
            2) mihomo_update; pause_return ;;
            3) systemctl status "${MIHOMO_SVC:-mihomo}.service" --no-pager 2>/dev/null | head -24 || true; pause_return ;;
            4) restart_svc "${MIHOMO_SVC:-mihomo}"; pause_return ;;
            5) show_log "${MIHOMO_SVC:-mihomo}"; pause_return ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   3) Sing-box
# ===========================
singbox_menu() {
    local choice rc
    while true; do
        clear 2>/dev/null || true
        sub_header "Sing-box 管理" "$(pkg_version "$VER_FILE_SB")" "$SB_SVC"
        menu_v "1" "打开面板 (安装 / 进入面板)"
        menu_v "2" "查看状态"
        menu_v "3" "重启 sing-box"
        menu_v "4" "查看日志"
        sub_footer
        choice=$(read_choice "  请选择 [0-4]: ")
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"
        case $choice in
            0) return 0 ;;
            1) sb_open; pause_return ;;
            2) systemctl status "${SB_SVC:-sing-box}.service" --no-pager 2>/dev/null | head -24 || true; pause_return ;;
            3) restart_svc "${SB_SVC:-sing-box}"; pause_return ;;
            4) show_log "${SB_SVC:-sing-box}"; pause_return ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   4) Hysteria2
# ===========================
hysteria_menu() {
    local choice rc
    while true; do
        clear 2>/dev/null || true
        sub_header "Hysteria2 管理" "$(pkg_version "$VER_FILE_HY")" "$HY2_SVC"
        menu_v "1" "打开面板 (hy2-panel.sh)"
        menu_v "2" "查看状态"
        menu_v "3" "重启 hysteria2"
        menu_v "4" "查看日志"
        sub_footer
        choice=$(read_choice "  请选择 [0-4]: ")
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"
        case $choice in
            0) return 0 ;;
            1) hy_open; pause_return ;;
            2) systemctl status "${HY2_SVC:-hysteria2}.service" --no-pager 2>/dev/null | head -24 || true; pause_return ;;
            3) restart_svc "${HY2_SVC:-hysteria2}"; pause_return ;;
            4) show_log "${HY2_SVC:-hysteria2}"; pause_return ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   5) 公共分享服务
# ===========================
share_menu() {
    local choice rc port
    while true; do
        clear 2>/dev/null || true
        port=$(share_port)
        box_top "公共分享服务"
        info2 "服务" "$(service_state "$SHARE_SVC")" "端口" "$port"
        if share_health_ok; then
            info2 "健康检查" "OK" "地址" "127.0.0.1:${port}"
        else
            info2 "健康检查" "失败/未运行"
        fi
        box_mid
        echo -e "  ${GRAY}X / Mihomo / Sing-box 三家共用它存 token / TTL / 拉取次数${PLAIN}"
        box_mid
        menu_v "1" "查看状态 (systemctl + health 原始返回)"
        menu_v "2" "安装 / 修复 (Share-Service install.sh)"
        menu_v "3" "重启服务"
        sub_footer
        choice=$(read_choice "  请选择 [0-3]: ")
        rc=$?
        if (( rc > 128 )); then continue; fi
        if (( rc != 0 )); then return 0; fi
        choice="${choice//[[:space:]]/}"
        case $choice in
            0) return 0 ;;
            1)
                systemctl status "${SHARE_SVC:-proxy-share-service}.service" --no-pager 2>/dev/null | head -16 || true
                echo
                print_info "health:"
                curl -fsS --max-time 4 "http://127.0.0.1:${port}/api/v1/health" 2>/dev/null | head -c 600 || print_warn "取不到 health (服务没跑?)"
                echo
                pause_return
                ;;
            2) share_install; pause_return ;;
            3) restart_svc "${SHARE_SVC:-proxy-share-service}"; pause_return ;;
            *) invalid_input ;;
        esac
    done
}

# ---------- 总链接 (bundle): 一条 URL 装三家 ----------
# 公共分享服务的 record 允许任意 provider; 这里用 provider=catmi + type=file
# 存一份 JSON: {"version":1,"links":{"xray":...,"mihomo":...,"sing-box":...}}
# 客户端拿到这一条, 就能自动分发给三个项目的客户端。
# 每次生成总链接前先**新发三条**一次性链接 —— 用户明确要求分享次数=1
# (防节点泄露)。旧链接被上一次导入用掉后就该失效, 不能复用。
# 次数可用 CATMI_SHARE_USES 覆盖 (0=不限)。
ca_bundle_mint() {
    local uses="${CATMI_SHARE_USES:-1}"
    [[ "$uses" =~ ^[0-9]+$ ]] || uses=1
    # X: 自动模式 + 显式次数/永久
    SHARE_AUTO=1 SHARE_AUTO_MAX_USES="$uses" SHARE_AUTO_TTL_HOURS=0 \
        timeout 150 bash /root/conf/share.sh create --all >/dev/null 2>&1 || true
    # M: share.sh auto <tag> <次数> <小时>
    timeout 150 bash /root/catmi/mihomo/src/share/share.sh auto all "$uses" 0 >/dev/null 2>&1 || true
    # SB: create-all <次数> <小时>
    timeout 150 bash /root/catmi/sing-box/conf/share.sh create-all "$uses" 0 >/dev/null 2>&1 || true
}

ca_bundle_create() {
    local tok port host x m sb
    tok=$(share_admin_token); port=$(share_port); host=$(public_host)
    [[ -n "$tok" ]] || { warn "找不到分享服务 admin token, 不生成总链接"; return 1; }
    [[ "${CATMI_BUNDLE_REUSE:-0}" == "1" ]] || ca_bundle_mint
    x=$(share_best xray)   && x="http://${host}:${port}/share/${x%%$'\t'*}"
    m=$(share_best mihomo) && m="http://${host}:${port}/share/${m%%$'\t'*}"
    sb=$(share_best sing-box) && sb="http://${host}:${port}/share/${sb%%$'\t'*}"
    # SB 的分享可能被用掉/删掉: 直接从它自己的节点表重建一条不限次数的
    if [[ -z "$sb" && -r /root/catmi/sing-box/conf/share.sh ]]; then
        info "SB 没有可用分享, 用它的节点表重建一条 ..."
        bash /root/catmi/sing-box/conf/share.sh create-all 0 0 >/dev/null 2>&1 || true
        sb=$(share_best sing-box) && sb="http://${host}:${port}/share/${sb%%$'\t'*}"
    fi
    [[ -n "$x$m$sb" ]] || { warn "三家里没有任何分享记录, 不生成总链接"; return 1; }
    [[ -n "$x" ]]  || warn "Xray 没有可用分享, 总链接里不含 X"
    [[ -n "$m" ]]  || warn "Mihomo 没有可用分享, 总链接里不含 M"
    [[ -n "$sb" ]] || warn "Sing-box 没有可用分享, 总链接里不含 SB"
    local body
    body=$(python3 - "$x" "$m" "$sb" <<'PYX'
import json, sys
x, m, sb = sys.argv[1], sys.argv[2], sys.argv[3]
links = {k: v for k, v in (("xray", x), ("mihomo", m), ("sing-box", sb)) if v}
print(json.dumps({"provider": "catmi", "type": "file",
                  "content": json.dumps({"version": 1, "links": links}),
                  "content_type": "application/json",
                  "ttl": 0, "max_uses": 0,
                  "meta": {"name": "catmi-bundle"}}))
PYX
)
    local res
    res=$(curl -s --max-time 8 -X POST -H "Authorization: Bearer $tok" \
          -H 'Content-Type: application/json' --data "$body" \
          "http://127.0.0.1:${port}/api/v1/shares" 2>/dev/null) || true
    local bt
    bt=$(printf '%s' "$res" | python3 -c 'import json,sys;print((json.load(sys.stdin) or {}).get("token",""))' 2>/dev/null)
    [[ -n "$bt" ]] || { warn "总链接生成失败"; return 1; }
    printf '  %s\n' "http://${host}:${port}/share/${bt}"
    return 0
}

# ---------- 客户端: 一条总链接分发给三个客户端 ----------
cl_x_import()  { command -v xbd >/dev/null 2>&1 || { err "X 客户端未安装 (xbd)"; return 1; }
                 timeout 180 xbd sub "$1" </dev/null; }
cl_m_import()  {
    local c="${MIHOMO_CLIENT_ROOT:-/root/catmi/mihomo-client}/src/client.sh"
    [[ -r "$c" ]] || { err "M 客户端未安装 ($c)"; return 1; }
    # 名字交给调度器, 其余交互一律走默认 (EOF) —— 用户只粘贴一次链接。
    # 默认组名/前缀 = M (与服务器节点名 M-… 幂等, 不会叠成 M-M-…)
    CLIENT_SUB_NAME="${2:-M}" timeout 240 bash "$c" sub "$1" </dev/null
}
cl_sb_import() {
    command -v sb-client >/dev/null 2>&1 || { err "SB 客户端未安装 (sb-client)"; return 1; }
    # 默认前缀 SB-: 服务端节点名已是 SB-…, to_sb.py 会幂等跳过
    SB_SUBS_PREFIX="${2:-SB-}" timeout 180 sb-client add "$1" </dev/null
}

cl_import_bundle() {  # <bundle-url> [前缀]
    local url="$1" prefix="${2:-}" tmp
    tmp=$(mktemp /tmp/catmi-bundle.XXXXXX) || return 1
    say "拉取总链接 ..."
    if ! curl -fsSL --max-time 15 "$url" -o "$tmp"; then
        err "总链接拉取失败: $url"; rm -f "$tmp"; return 1
    fi
    local x m sb
    eval "$(python3 - "$tmp" <<'PYX'
import json, sys, shlex
d = json.load(open(sys.argv[1], encoding="utf-8"))
l = (d.get("links") if isinstance(d, dict) else None) or {}
for k, v in (("x", l.get("xray")), ("m", l.get("mihomo")), ("sb", l.get("sing-box"))):
    if v:
        print("CA_%s=%s" % (k.upper(), shlex.quote(v)))
PYX
)"
    rm -f "$tmp"
    local fail=0
    if [[ -n "${CA_X:-}" ]]; then
        say "→ X 客户端"; cl_x_import "$CA_X" && ok "X 客户端导入完成" || { err "X 客户端导入失败"; fail=$((fail+1)); }
    fi
    if [[ -n "${CA_M:-}" ]]; then
        say "→ Mihomo 客户端"; cl_m_import "$CA_M" "${prefix:-M}" && ok "M 客户端导入完成" || { err "M 客户端导入失败"; fail=$((fail+1)); }
    fi
    if [[ -n "${CA_SB:-}" ]]; then
        local sbf; if [[ -n "$prefix" ]]; then sbf="${prefix}-"; else sbf="SB-"; fi
        say "→ Sing-box 客户端"; cl_sb_import "$CA_SB" "$sbf" && ok "SB 客户端导入完成" || { err "SB 客户端导入失败"; fail=$((fail+1)); }
    fi
    (( fail == 0 )) && ok "三个客户端都已导入" || warn "有 $fail 个客户端导入失败（上面有原因）"
    return $(( fail > 0 ))
}

cl_client_menu() {
    local c
    while true; do
        clear 2>/dev/null || true
        box_top "客户端一键导入"
        info2 "X 客户端"  "$(command -v xbd >/dev/null 2>&1 && echo 已安装 || echo 未安装)"
        info2 "M 客户端"  "$([[ -r /root/catmi/mihomo-client/src/client.sh ]] && echo 已安装 || echo 未安装)"
        info2 "SB 客户端" "$(command -v sb-client >/dev/null 2>&1 && echo 已安装 || echo 未安装)"
        box_mid
        echo -e "  ${GRAY}一条总链接里带三条（X/M/SB），这里自动分发给各自的客户端${PLAIN}"
        box_mid
        menu_v "1" "粘贴总链接导入 (服务端菜单 6 跑完会给)"
        menu_v "2" "分别粘贴三条链接导入"
        menu_v "3" "安装 / 更新客户端 (X / M / SB)"
        menu_v "4" "打开客户端面板"
        menu_v "0" "返回"
        box_bot
        echo
        printf "  请选择 [0-4]: "; read -r c || return 0
        case "${c//[[:space:]]/}" in
            0|"") return 0 ;;
            1)
                local u p
                printf "  总链接: "; read -r u || return 0
                [[ -n "$u" ]] || { invalid_input; continue; }
                printf "  自定义名称前缀 (回车=按内核默认 X/M/SB): "; read -r p || p=""
                cl_import_bundle "$u" "${p// /}"
                pause_return ;;
            2)
                local x m sb
                printf "  X 链接 (回车跳过): "; read -r x || x=""
                printf "  M 链接 (回车跳过): "; read -r m || m=""
                printf "  SB 链接 (回车跳过): "; read -r sb || sb=""
                [[ -n "$x" ]] && { say "→ X"; cl_x_import "$x" || err "X 导入失败"; }
                [[ -n "$m" ]] && { say "→ M"; cl_m_import "$m" || err "M 导入失败"; }
                [[ -n "$sb" ]] && { say "→ SB"; cl_sb_import "$sb" "SB-" || err "SB 导入失败"; }
                pause_return ;;
            3)
                run_project "$REPO_X" install.sh client
                pause_return ;;
            4)
                echo -e "  ${YELLOW}1${PLAIN}) xbd menu    ${YELLOW}2${PLAIN}) M 客户端面板    ${YELLOW}3${PLAIN}) sb-client"
                printf "  选: "; local k; read -r k || k=""
                case "$k" in
                    1) command -v xbd >/dev/null && xbd menu ;;
                    2) [[ -r /root/catmi/mihomo-client/src/client.sh ]] && bash /root/catmi/mihomo-client/src/client.sh ;;
                    3) command -v sb-client >/dev/null && sb-client ;;
                esac
                pause_return ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   主菜单循环
# ===========================
main_menu() {
    local choice rc
    while true; do
        build_service_status   # 每轮重绘都重新检测: 装完内核返回即时正确
        draw_main_menu
        read -r choice
        rc=$?
        if (( rc > 128 )); then echo; continue; fi
        if (( rc != 0 )); then exit 0; fi
        choice="${choice//[[:space:]]/}"
        case $choice in
            1|01) xray_menu ;;
            2|02) mihomo_menu ;;
            3|03) singbox_menu ;;
            4|04) hysteria_menu ;;
            5|05) share_menu ;;
            6|06) all_wizard ;;
            7|07) cl_client_menu ;;
            0) exit 0 ;;
            *) invalid_input ;;
        esac
    done
}

# ===========================
#   入口: 参数直达
#   (无参数) / xray / mihomo / singbox / hysteria / share
# ===========================
build_service_status

case "${1:-}" in
    xray|X|01)      xray_menu ;;
    mihomo|M|02)    mihomo_menu ;;
    singbox|sb|03)  singbox_menu ;;
    hysteria|hy|04) hysteria_menu ;;
    share|05)       share_menu ;;
    all|06)         all_wizard ;;
    client|07)
        if [[ -n "${2:-}" ]]; then cl_import_bundle "$2" "${3:-catmi}"; else cl_client_menu; fi ;;
    bundle)         ca_bundle_create || exit 1 ;;
    status)         draw_main_menu ;;
    *)              main_menu ;;
esac
