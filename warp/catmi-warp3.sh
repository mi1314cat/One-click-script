#!/usr/bin/env bash
# ============================================================
# catmi-warp v3 — 最终生产版 (Final)
#
#   V1/V2 → 只读基线 (docs/V2-AUDIT.md), 本文件为 V3 独立实现
#
# 定位: 服务器【默认出口】的 WARP/Native 策略分流器
# 核心原则 (V3 存在的意义):
#   内核/程序明确指定的出站 (fwmark / bind interface / 专用 UID)
#       ↓ 优先保留, catmi-warp 永不覆盖
#   没有其他出站策略的默认出口流量
#       ↓ catmi-warp 按域名规则接管
#   WARP ⇄ Native
#
# 关键实现: mangle CATMI3-OUT 首条规则 `-m mark ! --mark 0 -j RETURN`
#   — 已打标流量原样放行 (Xray sockopt.mark / Mihomo routing-mark / connmark)
#   — bind-interface 的 socket 由内核 bound-socket 路由语义天然保护
#
# 不做: Web UI / DNS 平台 / 代理内核出站管理器 / 修改他方配置 / 全局默认路由
#
# 相对 V2 的关键变化:
#   * fwmark: RETURN 保护 (V2 无条件覆盖 → 重点修复)
#   * start/stop: 来源感知, 只动当前来源; 外部管理器默认不可强停
#   * resolv.conf: symlink 感知 (识别/记录/还原链接形态)
#   * doctor: 结构化 + PASS/WARN/FAIL + Compatibility + doctor outbound
#   * test-priority: 出站优先级实测 (SO_MARK / bind / 无标 三路)
#   * 运行时资源与 V2 正交 (mark 0x3 / 表 cw3-253 / ipset cw3-* / BASE3)
#
# 传承的 V1 实测教训:#   * 内核 disable_ipv6=1 时 WG conf 只写 v4
# ============================================================

# ---------- 路径与常量 ----------
BASE="${CATMI_WARP_HOME:-/etc/catmi/warp3}"
RUNTIME="$BASE/runtime"; STATE="$BASE/state"; BACKUPS="$BASE/backups"
GEN="$BASE/generated"; OUTDIR="$GEN/outbound"; LOGDIR="$BASE/logs"
CONFDIR="$BASE/config"; RULES="$CONFDIR/rules.conf"; MAIN_CONF="$CONFDIR/main.conf"
GEN_DNS_REAL="$GEN/dnsmasq-catmi-warp3.conf"
GEN_DNS_LINK="/etc/dnsmasq.d/catmi-warp3.conf"
RESOLV="/etc/resolv.conf"
RESOLV_STATE="$STATE/resolv.state"
APPLIED_FLAG="$STATE/applied"
KA_TS="$STATE/.ka-ts"
ACCOUNT_JSON="$STATE/account.json"

MARK="3"                       # fwmark 0x3 (与 V2 的 0x2 正交; main.conf 可覆盖)
IMARK="4"                      # fwmark 0x4 = 入站回程标记: 入站连接(he/eth0)的回包走 main,
                               # 源=入站接口地址 — 防止 UDP 通配 socket 回包被 C 规则抓进 WARP 源漂移
TABLE_NAME="cw3"               # 表名 (253) — 与 V2 的 catmi-warp(250) 正交
TABLE_ID="253"
UPSTREAMS="1.1.1.1 8.8.8.8"
FORWARD="0"                    # forward 模式: 0=OFF(默认) 1=ON
DEFAULT_OUTBOUND="native"      # [兼容] 旧版单键: 读入旧配置时映射为 V4=V6 同值
DEFAULT_OUTBOUND_V4="native"   # IPv4 默认出口: native=普通 v4 走原生 | warp=普通 v4 走 WARP
DEFAULT_OUTBOUND_V6="native"   # IPv6 默认出口: native=普通 v6 走原生 | warp=普通 v6 走 WARP
                               # v6=warp 即"补栈": 机器没有 v6 上游也能通过 WARP 获得 v6 出口
SKIP_UIDS=""                   # 可选: 专用用户跑代理时的 UID 排除清单 (空=不启用)
EXCLUDE_SETS=""                # 可选: 额外"绝不接管"目标 ipset 名
NATIVE_IPS=""                  # 可选: 固定 IP 的 native 豁免 (空格分隔 v4/v6) — 永不进 WARP,
                               # 走原生出口。用途: 链式上游/hy2 上游等 MTU 敏感直连服务
                               # (QUIC 包 > WARP 隧道 MTU 1280 时会被 EMSGSIZE 卡死)
AUTO_CHAIN_EXEMPT="1"          # 自动扫描代理内核 outbound 的上游 IP 并入原生豁免 (1=开)
                               # 换节点/加出站后重启一次即可生效; 想只用手工 NATIVE_IPS 就设 0
RT_ANCHOR="100"                # fwmark 规则优先级 — 实测教训: 必须极小

CF_PEER_PUB="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
CF_ENDPOINT="engage.cloudflareclient.com:2408"
CF_API_REG="https://api.cloudflareclient.com/v0a2158/reg"
CF_API_VER="a-6.10-2158"
VERSION="3.0.0"
DEFAULT_UPDATE_URL="${CATMI_WARP_URL:-}"

IFACE=""                       # detect_iface 结果
SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo /usr/local/bin/catmi-warp3)"

# ---------- 输出 ----------
R="\033[31m"; G="\033[32m"; Y="\033[33m"; M="\033[35m"; C="\033[36m"; B="\033[1m"; N="\033[0m"
info() { echo -e "  ${M}[Info]${N} $*" >&2; }
ok()   { echo -e "  ${G}[OK]${N} $*" >&2; }
warn() { echo -e "  ${Y}[WARN]${N} $*" >&2; }
err()  { echo -e "  ${R}[ERR]${N} $*" >&2; }
die()  { err "$*"; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "请用 root 运行"; }

log_op() { # log_op <op> <result>
    mkdir -p "$LOGDIR" 2>/dev/null
    printf '%s | %-10s | %s\n' "$(date '+%F %T')" "$1" "$2" >> "$LOGDIR/op-$(date +%Y%m).log" 2>/dev/null
}

# flock 互斥 (§10.6: 防多实例同时操作)
# 注意: exec 的持久重定向 — 2>/dev/null 必须限定在花括号组内, 否则永久吞掉 fd2
acquire_lock() {
    mkdir -p "$RUNTIME" 2>/dev/null
    { exec 9>>"$RUNTIME/lock"; } 2>/dev/null || return 0
    if ! flock -n 9 2>/dev/null; then
        # flock 随进程退出自动释放 ⇒ 锁还在 = 一定有个**活着的**实例 (最常见的是
        # 卡在交互确认上的 default/newip/endpoint; 见 confirm_or_abort 注释)。
        err "另一个 catmi-warp 实例正在执行变更操作 (flock: $RUNTIME/lock)"
        err "查持有者: ps -eo pid,etime,args | grep -F catmi-warp3 | grep -v grep"
        err "注意: 直接删除锁文件**不会**释放已被持有的锁 (锁在 inode 上), 只能结束那个进程"
        return 1
    fi
    return 0
}

# ---------- 包管理 ----------
# ---------- rt_tables 词典 (Debian 13 兼容) ----------
# iproute2 用 /etc/iproute2/rt_tables 把**表名**映射成表号。Debian 13 (iproute2 >= 6.7)
# 把默认配置从 /usr/lib 挪到了 /usr/share, 6.15 上 /etc/iproute2 这个目录整个不存在:
# `>> /etc/iproute2/rt_tables` 直接 "No such file or directory" -> 表名 cw3 注册不上 ->
# 后面所有 `ip rule ... lookup cw3` 报 invalid table ID -> apply 全线回滚 (2026-09-15 事故)。
# iproute2 自己的查找顺序是 /etc 优先、/usr/share 兜底, 所以补一份到 /etc 即可。
ensure_rt_tables() {
    [[ ${EUID:-0} -eq 0 ]] || return 0
    [[ -s /etc/iproute2/rt_tables ]] && return 0
    mkdir -p /etc/iproute2 2>/dev/null
    local c src=""
    for c in /usr/share/iproute2/rt_tables /usr/lib/iproute2/rt_tables; do
        [[ -s "$c" ]] && { src="$c"; break; }
    done
    if [[ -n "$src" ]]; then
        cp -f "$src" /etc/iproute2/rt_tables 2>/dev/null
    else
        printf '255\tlocal\n254\tmain\n253\tdefault\n0\tunspec\n' > /etc/iproute2/rt_tables 2>/dev/null
    fi
    chmod 644 /etc/iproute2/rt_tables 2>/dev/null
    [[ -s /etc/iproute2/rt_tables ]]
}

# 注册本模块的表名 -> 表号。
#  ① 写失败必须**硬失败**: 否则留下一串 invalid table ID 和"半生效"的现场, 比直接回滚难查得多。
#  ② 必须避开保留表号 255 local / 254 main / **253 default** / 0 unspec。
#     stock 文件里 253 是 default 的号, 若写成 "253 cw3", default 与 cw3 会指向同一张表 ——
#     内核最后那条 `32767: from all lookup default` 就变成查我们的 WARP 表。
#     实测指纹: `ip rule show` 把它显示成 "lookup cw3", 且 `ip route show table default`
#     能列出 WARP 路由 (旧版在 Debian/Ubuntu 上一直是这样, 只是没人注意)。
#     表号只影响注册与显示 —— 运行期一律按名字引用, 所以换号不会打断已有部署。
register_rt_table() {
    ensure_rt_tables || { err "无法创建 /etc/iproute2/rt_tables (权限/只读挂载?)"; return 1; }
    local cur
    cur=$(awk -v n="$TABLE_NAME" '$2==n {print $1; exit}' /etc/iproute2/rt_tables 2>/dev/null)
    if [[ -n "$cur" ]]; then
        TABLE_ID="$cur"          # 已注册过: 以文件为准 (兼容历史机器上手工写的表号)
        return 0
    fi
    local used tid="$TABLE_ID"
    used=" $(awk '{print $1}' /etc/iproute2/rt_tables 2>/dev/null | tr '\n' ' ') "
    while [[ "$used" == *" $tid "* || "$tid" == "0" || "$tid" == "253" || "$tid" == "254" || "$tid" == "255" ]]; do
        (( tid-- ))
        (( tid < 64 )) && { err "找不到空闲路由表号 (检查 /etc/iproute2/rt_tables)"; return 1; }
    done
    if ! echo "$tid $TABLE_NAME" >> /etc/iproute2/rt_tables 2>/dev/null; then
        err "注册路由表名 $TABLE_NAME 失败 (/etc/iproute2/rt_tables 不可写?) — 分流无法部署"
        return 1
    fi
    TABLE_ID="$tid"
    info "路由表名 $TABLE_NAME 已注册 (表号 $tid)"
    return 0
}

# ---------- 包管理 ----------
pkg_install() {
    command -v "$1" >/dev/null 2>&1 && return 0
    local pkgs="$*"
    info "安装依赖: $pkgs"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1; apt-get install -y $pkgs >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then dnf install -y $pkgs >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then yum install -y $pkgs >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then apk add $pkgs >/dev/null 2>&1
    fi
}

ensure_deps() {
    # 这份清单 = 「全新机器上 apply 到底依赖什么」。原实现漏了 curl (脚本里 38 处调用)
    # 与 ping (v6 补栈自检 / endpoint 采样), 少任何一个都会让 apply 在**半途**失败或静默降级。
    command -v ipset >/dev/null 2>&1 || pkg_install ipset
    command -v dig >/dev/null 2>&1 || { pkg_install dnsutils; command -v dig >/dev/null 2>&1 || pkg_install bind-utils; }
    command -v python3 >/dev/null 2>&1 || pkg_install python3
    command -v iptables >/dev/null 2>&1 || pkg_install iptables
    command -v curl >/dev/null 2>&1 || pkg_install curl
    command -v ping >/dev/null 2>&1 || { pkg_install iputils-ping; command -v ping >/dev/null 2>&1 || pkg_install iputils; }
    # dnsmasq 是 apply 的硬依赖 (步骤 2 无条件执行), 原实现只检查不安装 ——
    # 没有 dnsmasq 的机器 apply 必然失败在 "dnsmasq 启动失败", 而工具明明能自己装 (实测 CCS)
    command -v dnsmasq >/dev/null 2>&1 || pkg_install dnsmasq
    # 硬闸门: 缺任何一个都会让 apply 半途失败, 不如在这里说清楚
    command -v ipset >/dev/null 2>&1 || { err "ipset 不可用"; return 1; }
    command -v dnsmasq >/dev/null 2>&1 || { err "dnsmasq 不可用 (域名分流需要它写 ipset)"; return 1; }
    command -v dig >/dev/null 2>&1 || { err "dig 不可用 (dnsutils/bind-utils)"; return 1; }
    command -v curl >/dev/null 2>&1 || { err "curl 不可用 (出口探测/健康检查依赖它)"; return 1; }
    command -v iptables >/dev/null 2>&1 || { err "iptables 不可用"; return 1; }
    # ip6tables 只告警不拦: 单栈 v4 机器上仍可以正常工作
    command -v ip6tables >/dev/null 2>&1 || warn "ip6tables 不可用 — v6 面规则将无法部署 (装 iptables 包)"
    # ping 只告警: 缺它只是少一个自检手段, 不该拦住部署
    command -v ping >/dev/null 2>&1 || warn "ping 不可用 — v6 补栈自检与 endpoint 采样会降级"
    return 0
}

# 内核版本比较 —— WireGuard 自 5.6 才进主线。原来三处都写 `uname -r | cut -d. -f1`(只比 major),
# 于是 5.4 被判成 "≥5.6 (内置)": armbian legacy / rockchip 正是 5.4, 上机就假绿放行。
kernel_ge() { # kernel_ge <major> <minor> [版本串, 默认 uname -r]
    local v="${3:-$(uname -r)}" maj min
    maj=$(cut -d. -f1 <<<"$v"); min=$(cut -d. -f2 <<<"$v")
    [[ "$maj" =~ ^[0-9]+$ ]] || return 1
    [[ "$min" =~ ^[0-9]+$ ]] || min=0
    (( maj > $1 )) || { (( maj == $1 )) && (( min >= $2 )); }
}

# ipset 是否存在 —— `ipset list <名>` 偶发失败(并发/内核忙)不等于"集合不存在",
# 直接当判据会让 doctor 报假红 (实测 17 次 doctor 里 2 次非预期 FAIL)。重试 3 次再下结论。
ipset_exists() {
    local i
    for i in 1 2 3; do
        ipset list -n "$1" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 1
}

# ---------- 目录与配置 ----------
init_dirs() {
    mkdir -p "$RUNTIME" "$STATE" "$BACKUPS" "$GEN" "$OUTDIR" "$LOGDIR" "$CONFDIR" 2>/dev/null
    if [[ ! -f "$MAIN_CONF" ]]; then
        cat > "$MAIN_CONF" <<EOF
# catmi-warp3 main config (v3)
MARK=$MARK
TABLE_NAME=$TABLE_NAME
TABLE_ID=$TABLE_ID
UPSTREAMS="$UPSTREAMS"
FORWARD=$FORWARD
SKIP_UIDS="$SKIP_UIDS"
EXCLUDE_SETS="$EXCLUDE_SETS"
DEFAULT_OUTBOUND_V4=$DEFAULT_OUTBOUND_V4
DEFAULT_OUTBOUND_V6=$DEFAULT_OUTBOUND_V6
EOF
    fi
    # 加载用户配置覆盖默认 (只取认得的 KEY; 剥值首尾引号 — 否则
    # UPSTREAMS="1.1.1.1 8.8.8.8" 会把引号字面读进值, 污染 dnsmasq conf)
    if [[ -s "$MAIN_CONF" ]]; then
        local k v
        while IFS='=' read -r k v; do
            v="${v%\"}"; v="${v#\"}"
            case "$k" in
                MARK) MARK="$v" ;;
                TABLE_NAME) TABLE_NAME="$v" ;;
                TABLE_ID) TABLE_ID="$v" ;;
                UPSTREAMS) UPSTREAMS="$v" ;;
                FORWARD) FORWARD="$v" ;;
                SKIP_UIDS) SKIP_UIDS="$v" ;;
                DEFAULT_OUTBOUND_V4) DEFAULT_OUTBOUND_V4="$v" ;;
                DEFAULT_OUTBOUND_V6) DEFAULT_OUTBOUND_V6="$v" ;;
                DEFAULT_OUTBOUND) [[ "$v" == "warp" ]] && { DEFAULT_OUTBOUND_V4="warp"; DEFAULT_OUTBOUND_V6="warp"; } ;;
                EXCLUDE_SETS) EXCLUDE_SETS="$v" ;;
                NATIVE_IPS) NATIVE_IPS="$v" ;;
                AUTO_CHAIN_EXEMPT) AUTO_CHAIN_EXEMPT="$v" ;;
            esac
        done < <(grep -vE '^\s*#|^\s*$' "$MAIN_CONF")
    fi
    [[ -f "$RULES" ]] || printf '# domain|action|enabled|note\n' > "$RULES"
}

# V2 → V3 迁移: 规则【只读】导入 (V2 原件与数据零改动; 幂等)
migrate_v2() {
    [[ -f "$STATE/v2-imported" ]] && return 0
    local v2rules="${CATMI_V2_HOME:-/etc/catmi/warp}/config/rules.conf"
    [[ -s "$v2rules" ]] || return 0
    if [[ "$(rule_list 2>/dev/null | wc -l)" -ne 0 ]]; then
        info "V2 规则导入: 跳过 (V3 已有规则, 不覆盖)"
        return 0
    fi
    # 逐行校验后再落盘。原实现有两个缺陷:
    #  ① `grep ... >> "$RULES" 2>/dev/null` 不判返回码, 紧接着**无条件** touch 幂等标记:
    #     盘满/只读/写一半时只进了一部分却打印 [OK], 标记又已写 → 剩余规则**永久不再导入**
    #     (实测: 20k tmpfs + 114KB V2 文件 → 只进 589/4001 条; 腾空后重跑静默跳过)
    #  ② 导入完全绕过 valid_domain/action 白名单, 非法行会进 dnsmasq 配置让 apply 失败
    local line d a en note
    local -a keep=(); local bad=0
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        IFS='|' read -r d a en note <<<"$line"
        d="${d,,}"
        if [[ "$a" != "warp" && "$a" != "native" ]] || ! valid_domain "$d"; then
            bad=$(( bad + 1 )); continue
        fi
        keep+=("$d|$a|${en:-1}|$note")
    done < "$v2rules"
    if (( ${#keep[@]} == 0 )); then
        err "V2 规则导入: 0 条可用 (跳过非法行 $bad 条) — 未写标记, 修正 V2 文件后可重试"
        return 1
    fi
    # 复用 rules_atomic 的 tmp+mv 语义: 写失败绝不写"已导入"标记
    cp -f "$RULES" "$RUNTIME/rules.tmp" 2>/dev/null \
        || { err "V2 规则导入失败: 无法创建临时文件 ($RUNTIME/rules.tmp)"; return 1; }
    if ! printf '%s\n' "${keep[@]}" >> "$RUNTIME/rules.tmp" 2>/dev/null || ! rules_atomic; then
        rm -f "$RUNTIME/rules.tmp" 2>/dev/null
        err "V2 规则导入失败 (磁盘满 / 只读挂载?) — rules.conf 未改动, 未写标记"
        return 1
    fi
    touch "$STATE/v2-imported" 2>/dev/null \
        || { err "写导入标记失败 — 下次启动会重新尝试 (无副作用)"; return 1; }
    ok "V2 规则只读导入: $(rule_list | wc -l) 条 (V2 原件未动, 跳过非法行 $bad 条)"
    log_op "migrate" "v2 rules imported (read-only)"
    return 0
}

# ============================================================
# WARP 环境识别 (V1 传承: 只读识别, 兼容四种来源)
# ============================================================
detect_iface() {
    IFACE=""
    local i
    for i in warp CloudflareWARP WARP wgcf; do
        if ip -o link show "$i" >/dev/null 2>&1; then IFACE="$i"; break; fi
    done
    [[ -n "$IFACE" ]]
}

warp_source() { # 识别 WARP 来源 (§4: 上层接口统一)
    case "$IFACE" in
        warp)
            if [[ -f /etc/wireguard/warp.conf ]] && grep -q 'Table = off' /etc/wireguard/warp.conf 2>/dev/null; then
                echo "catmi-warp 自研 (内核 WG, Table=off)"
            else
                echo "fscarmen wg-quick (内核 WG)"
            fi ;;
        WARP)      echo "fscarmen warp-go (用户态回退)" ;;
        CloudflareWARP) echo "warp-cli (CloudflareWARP)" ;;
        wgcf)      echo "wgcf (内核 WG)" ;;
        *)         echo "未知" ;;
    esac
}

find_cred_files() {
    printf '%s\n' \
        /etc/wireguard/warp.conf \
        /etc/wireguard/warp-account.conf \
        /opt/warp-go/warp.conf \
        /opt/warp-go/singbox.json \
        /opt/warp-go/wgcf.conf 2>/dev/null | while read -r f; do [[ -s "$f" ]] && echo "$f"; done
}

# 凭据解析 (V1 传承: wgcf.conf 优先; base64 '=' 前缀剥离; 多行 Address; singbox 兜底)
parse_creds() {
    PRIVKEY=""; ADDR4=""; ADDR6=""; PEER_PUB=""; ENDPOINT="$CF_ENDPOINT"; RESERVED=""; WARP_MTU=""
    local f src=""
    for f in ${CATMI_CRED_FILE:+$CATMI_CRED_FILE} /opt/warp-go/wgcf.conf /etc/wireguard/warp.conf /opt/warp-go/warp.conf /etc/wireguard/warp-account.conf; do
        if [[ -s "$f" ]] && grep -q 'PrivateKey' "$f"; then src="$f"; break; fi
    done
    CRED_SRC="$src"   # 唯一真源: 本模块实际用来拉起 WARP 的那个凭据文件
    if [[ -n "$src" ]]; then
        strip_val() { sed -n "s/^$1[ ]*=[ ]*//p" "$2" 2>/dev/null | head -1 | tr -d '\r'; }
        PRIVKEY=$(strip_val 'PrivateKey' "$src")
        local a
        a=$(grep -E '^Address[ ]*=' "$src" 2>/dev/null | sed 's/^Address[ ]*=[ ]*//' | tr -d '\r' | tr ',' '\n' | tr -d ' ')
        ADDR4=$(grep -E '^[0-9]+\.' <<<"$a" | head -1)
        ADDR6=$(grep -E ':' <<<"$a" | head -1)
        PEER_PUB=$(strip_val 'PublicKey' "$src")
        local ep; ep=$(strip_val 'Endpoint' "$src")
        [[ -n "$ep" ]] && ENDPOINT="$ep"
        RESERVED=$(strip_val 'Reserved' "$src" | tr -d ' ')
        local mtu_c; mtu_c=$(strip_val 'MTU' "$src"); [[ -n "$mtu_c" ]] && WARP_MTU="$mtu_c"
    else
        if [[ -s /opt/warp-go/singbox.json ]] && command -v python3 >/dev/null 2>&1; then
            eval "$(python3 - <<'PY'
import json
d=json.load(open('/opt/warp-go/singbox.json'))
ep=(d.get('endpoints') or [{}])[0]
print(f"PRIVKEY_JSON={ep.get('private_key','')!r}")
for a in (ep.get('address') or []):
    if ':' in a: print(f"ADDR6_JSON={a!r}")
    else: print(f"ADDR4_JSON={a!r}")
p=((ep.get('peers') or [{}])[0])
print(f"PEER_JSON={p.get('public_key','')!r}")
print(f"RESERVED_JSON={','.join(str(x) for x in (p.get('reserved') or []))!r}")
svr=p.get('address','engage.cloudflareclient.com'); port=p.get('port',2408)
print(f"EP_JSON={svr+':'+str(port)!r}")
PY
)" 2>/dev/null
            PRIVKEY="${PRIVKEY_JSON:-}"; ADDR4="${ADDR4_JSON:-}"; ADDR6="${ADDR6_JSON:-}"
            PEER_PUB="${PEER_JSON:-}"; RESERVED="${RESERVED_JSON:-}"; ENDPOINT="${EP_JSON:-$CF_ENDPOINT}"
        fi
    fi
    if [[ -z "$RESERVED" && -s /opt/warp-go/singbox.json ]] && command -v python3 >/dev/null 2>&1; then
        RESERVED=$(python3 -c "import json;d=json.load(open('/opt/warp-go/singbox.json'));print(','.join(str(x) for x in (d.get('endpoints',[{}])[0].get('peers',[{}])[0].get('reserved') or [])))" 2>/dev/null)
        if [[ -z "$ADDR4" ]]; then
            eval "$(python3 - <<'PY'
import json
ep=json.load(open('/opt/warp-go/singbox.json')).get('endpoints',[{}])[0]
for a in (ep.get('address') or []):
    if ':' in a: print(f"ADDR6={a!r}")
    else: print(f"ADDR4={a!r}")
PY
)" 2>/dev/null
        fi
    fi
    if [[ -n "$RESERVED" && "$RESERVED" != *","* && "$RESERVED" =~ ^[A-Za-z0-9+/=]{4}$ ]]; then
        command -v python3 >/dev/null 2>&1 && RESERVED=$(python3 -c "import base64;print(','.join(str(b) for b in base64.b64decode('$RESERVED')))" 2>/dev/null)
    fi
    # MTU: **实际接口值优先** —— conf 里的可能是遗留旧值 (fscarmen 的 wgcf.conf 写 1420,
    # 而契约要求 1280)。用旧值会让 doctor 报出被明令禁止的 1420, 还会被 gen_outbound
    # 写进生成的出站片段; 用户据此把 warp.conf "修正" 成 1420 就会复现
    # "小包通、满载丢" 的故障 (v3 实测缺陷)
    local _live_mtu
    _live_mtu=$(cat "/sys/class/net/${IFACE:-warp}/mtu" 2>/dev/null)
    [[ "$_live_mtu" =~ ^[0-9]+$ ]] && WARP_MTU="$_live_mtu"
    [[ -z "$PEER_PUB" ]] && PEER_PUB="$CF_PEER_PUB"
    [[ -n "$PRIVKEY" ]]
}

# fscarmen global 模式检测 (安全红线: main 默认路由被 WARP 接管则拒绝分流)
check_not_global() {
    local def4 def6
    def4=$(ip -4 route show default 2>/dev/null | head -1)
    def6=$(ip -6 route show default 2>/dev/null | head -1)
    if grep -qE 'dev (warp|CloudflareWARP|WARP|wgcf)\b' <<<"$def4$def6"; then
        err "检测到默认路由已指向 WARP (global 模式): ${def4:-$def6}"
        err "请先切回 non-global (fscarmen: warp g), 否则分流无意义且互相干扰。"
        return 1
    fi
    return 0
}

# ============================================================
# 健康检查与诊断 (§5 核心: 启动失败 ≠ 账号失效)
# ============================================================
# 握手健康: 内核 WG 可查 wg show; 用户态接口用 egress trace 兜底
health_check() {
    detect_iface || return 1
    local hs
    hs=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')
    if [[ -n "$hs" && "$hs" != "0" ]]; then
        local age=$(( $(date +%s) - hs ))
        if (( age < 180 )); then
            HANDSHAKE_AGE=$age
            return 0
        fi
        warn "WARP 握手年龄 ${age}s (>180s, 隧道可能不活跃)"
        # 老握手不代表坏 — 再用 egress 复核
    fi
    if timeout 8 curl -s -4 --interface "$IFACE" https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q 'warp=on'; then
        HANDSHAKE_AGE="${HANDSHAKE_AGE:-n/a}"
        return 0
    fi
    return 1
}

# 诊断分类器 (§5 八类): 收集事实 → 输出结论与建议; 不修改任何状态
diagnose() {
    local findings=()
    local conf="/etc/wireguard/warp.conf"
    # ① 配置损坏
    if [[ -s "$conf" ]]; then
        if ! grep -q 'PrivateKey' "$conf" || ! grep -q 'Address' "$conf" || ! grep -q 'PublicKey' "$conf"; then
            findings+=("① 配置损坏: $conf 缺少 PrivateKey/Address/PublicKey 关键键")
        fi
    else
        findings+=("① 配置文件不存在: $conf")
    fi
    # ② 服务未启动
    local svc=""
    for s in wg-quick@warp warp-go warp-svc; do
        systemctl is-active "$s" >/dev/null 2>&1 && { svc="$s"; break; }
    done
    detect_iface || findings+=("② 服务/接口: 当前无 WARP 接口 (active 服务: ${svc:-无})")
    # ③ WireGuard 不可用
    if ! modprobe wireguard 2>/dev/null && ! grep -qw wireguard /proc/modules 2>/dev/null \
       && ! kernel_ge 5 6; then
        findings+=("③ WireGuard 不可用: 内核 $(uname -r) 无模块且 <5.6 → 需用户态方案 (fscarmen warp-go)")
    fi
    # ④ 网络不可达
    if ! timeout 4 bash -c 'echo > /dev/tcp/1.1.1.1/443' 2>/dev/null; then
        findings+=("④ 网络不可达: TCP 1.1.1.1:443 连不通 (出网问题)")
    fi
    # ⑥ DNS 问题
    if ! getent hosts engage.cloudflareclient.com >/dev/null 2>&1 \
       && ! python3 -c "import socket;socket.gethostbyname('engage.cloudflareclient.com')" 2>/dev/null; then
        findings+=("⑥ DNS 问题: engage.cloudflareclient.com 解析失败 → 先修系统 DNS")
    fi
    # ⑧ 账号失效 (仅 account.json 存在时查)
    if [[ -s "$ACCOUNT_JSON" ]] && command -v python3 >/dev/null 2>&1; then
        local id tok code
        id=$(python3 -c "import json;print(json.load(open('$ACCOUNT_JSON')).get('id',''))" 2>/dev/null)
        tok=$(python3 -c "import json;print(json.load(open('$ACCOUNT_JSON')).get('token',''))" 2>/dev/null)
        if [[ -n "$id" && -n "$tok" ]]; then
            code=$(timeout 10 curl -s -o /dev/null -w '%{http_code}' "$CF_API_REG/$id" \
                -H 'User-Agent: okhttp/3.12.1' -H "CF-Client-Version: $CF_API_VER" \
                -H "Authorization: Bearer $tok" 2>/dev/null)
            case "$code" in
                200) : ;;
                404|403) findings+=("⑧ 账号失效: Cloudflare 返回 HTTP $code → 唯一此类需重注册 (install --force-register)") ;;
                "") findings+=("⑧ 账号查询超时 (网络问题, 不下结论)") ;;
                *) findings+=("⑧ 账号查询 HTTP $code (异常但非失效确认)") ;;
            esac
        fi
    fi
    # ⑤/⑦ 握手与 MTU (接口存在才查)
    if detect_iface; then
        local hs
        hs=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')
        if [[ -n "$hs" && "$hs" != "0" ]]; then
            local age=$(( $(date +%s) - hs ))
            if (( age < 180 )); then
                if ! timeout 8 curl -s -4 --interface "$IFACE" https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q 'warp=on'; then
                    findings+=("⑦ MTU 问题: 握手正常但 egress 不通 → 建议将 $conf 的 MTU 降到 1280 后重启")
                fi
            else
                findings+=("⑤ Endpoint 不可达嫌疑: 握手年龄 ${age}s (UDP 可能被过滤; 也可能是空闲期, 用 egress 复核)")
            fi
        elif [[ -n "$hs" ]]; then
            findings+=("⑤ Endpoint 不可达: 从无握手记录 → UDP $CF_ENDPOINT 疑似被过滤")
        fi
    fi
    # 输出
    if ((${#findings[@]} == 0)); then
        ok "诊断: 未发现明确故障点 (健康检查刚失败, 可能是瞬时抖动 — 稍后重试 start)"
    else
        err "诊断结果:"
        local f
        for f in "${findings[@]}"; do echo "    $f" >&2; done
        err "处理建议: 按上述编号处理; 仅当明确确认 ⑧账号失效/配置损坏且需重建时才执行:"
        echo "    catmi-warp install --force-register  (将创建新 WARP 账号, 出口 IP 会变)" >&2
    fi
    ((${#findings[@]} > 0)) && return 1 || return 0
}

# ============================================================
# WARP 安装 (来源 D: 自研, 借鉴 wgcf/fscarmen 注册逻辑)
# ============================================================
register_warp() {
    command -v wg >/dev/null 2>&1 || pkg_install wireguard-tools
    command -v wg >/dev/null 2>&1 || { err "wireguard-tools 安装失败"; return 1; }
    if ! modprobe wireguard 2>/dev/null && ! grep -qw wireguard /proc/modules 2>/dev/null \
       && ! kernel_ge 5 6; then
        err "内核 $(uname -r) 无 WireGuard 模块 — 建议用 fscarmen warp-go (用户态)"; return 1
    fi
    info "正在注册新 WARP 账号 (api.cloudflareclient.com)..."
    local priv pub resp
    priv=$(wg genkey) || { err "密钥生成失败"; return 1; }
    pub=$(wg pubkey <<<"$priv") || { err "公钥派生失败"; return 1; }
    resp=$(timeout 20 curl -s -X POST "$CF_API_REG" \
        -H 'User-Agent: okhttp/3.12.1' -H "CF-Client-Version: $CF_API_VER" \
        -H 'Content-Type: application/json' \
        -d '{"key":"'"$pub"'","install_id":"","fcm_token":"","tos":"2022-07-11T23:11:33.966Z","model":"PC","locale":"en_US"}')
    if ! grep -q '"config"' <<<"$resp"; then
        err "注册失败: $(head -c 200 <<<"$resp")"
        log_op "register" "FAILED: $(head -c 80 <<<"$resp")"
        return 1   # 注册失败 = 零落盘 (§18)
    fi
    echo "$resp" > "$ACCOUNT_JSON"
    eval "$(python3 - <<PY
import json, base64
d = json.load(open('$ACCOUNT_JSON'))
cfg = d['config']
print(f"W_ADDR4={cfg['interface']['addresses'].get('v4','')!r}")
print(f"W_ADDR6={cfg['interface']['addresses'].get('v6','')!r}")
print(f"W_RESERVED={','.join(str(b) for b in base64.b64decode(cfg['client_id']))!r}")
print(f"W_PEER={cfg['peers'][0]['public_key']!r}")
PY
)" 2>/dev/null || { err "注册响应解析失败"; return 1; }

    # conf: Table=off (路由由本模块管); 无 DNS 行; 内核禁 v6 时单栈
    local addr_line="Address = ${W_ADDR4}/32"
    if [[ -n "$W_ADDR6" && "$DEFAULT_OUTBOUND_V6" == "warp" ]] || { [[ -n "$W_ADDR6" ]] && has_v6; }; then
        addr_line+=", ${W_ADDR6}/128"
    fi
    # 覆盖前备份 —— 原来无条件截断 /etc/wireguard/warp.conf, 旧凭据直接消失(不可恢复)。
    # 下面 511 行的防误覆盖只在接口**正在运行**时生效; 接口没起而 conf 还在时会被静默覆盖。
    if [[ -s /etc/wireguard/warp.conf ]]; then
        local _cbak="$BACKUPS/warp.conf.pre-register-$(date +%Y%m%d-%H%M%S)"
        cp -a /etc/wireguard/warp.conf "$_cbak" 2>/dev/null \
            && info "旧 WARP 配置已备份: $_cbak" \
            || { err "备份 /etc/wireguard/warp.conf 失败 — 中止注册 (避免旧凭据丢失)"; return 1; }
    fi
    # /etc/wireguard **不一定存在**: 实测 CCS 装了 wireguard-tools 却没有这个目录
    # (旧配置被删掉了)。原代码直接 `cat > /etc/wireguard/warp.conf` —— 目录不存在时
    # 重定向就失败、什么都不写, 接着 enable --now 也失败, 用户看到的是
    # "接口 warp 未创建 — 进入诊断" 这种指错方向的诊断。
    if ! mkdir -p /etc/wireguard 2>/dev/null || [[ ! -d /etc/wireguard ]]; then
        err "无法创建 /etc/wireguard (权限 / 只读挂载?) — 中止注册"; return 1
    fi
    chmod 700 /etc/wireguard 2>/dev/null
    cat > /etc/wireguard/warp.conf <<EOF
[Interface]
PrivateKey = $priv
$addr_line
MTU = 1280
Table = off

[Peer]
PublicKey = ${W_PEER:-$CF_PEER_PUB}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $CF_ENDPOINT
PersistentKeepalive = 25
EOF
    # 写完必须核实: 路径异常/磁盘满时重定向可能"成功"却没内容 (半套配置最难查)
    if [[ ! -s /etc/wireguard/warp.conf ]]; then
        err "写入 /etc/wireguard/warp.conf 失败 (空文件) — 中止, 避免留下半套配置"; return 1
    fi
    chmod 600 /etc/wireguard/warp.conf
    # 单元可能停在 failed 残留状态 (实测 CCS: 3 周前的失败) —— 先清干净再启用
    systemctl reset-failed wg-quick@warp 2>/dev/null
    systemctl enable --now wg-quick@warp >/dev/null 2>&1
    sleep 1
    if ! ip -o link show warp >/dev/null 2>&1; then
        warn "接口 warp 未创建 — 进入诊断"
        diagnose
        return 1   # 注册成功但启动失败: account.json + conf 一致保留 (可复用, 非半套配置)
    fi
    ok "WARP 内核接口就绪: warp (${W_ADDR4}, reserved=$W_RESERVED)"
    log_op "register" "OK (reserved=$W_RESERVED)"
}

already_installed() {
    if detect_iface; then echo "接口($IFACE)"; return 0; fi
    if [[ -n "$(find_cred_files)" ]]; then echo "凭据"; return 0; fi
    if systemctl is-active wg-quick@warp >/dev/null 2>&1 || systemctl is-active warp-go >/dev/null 2>&1; then
        echo "服务"; return 0
    fi
    if pgrep -f 'wireguard-go|warp-svc' >/dev/null 2>&1; then echo "进程"; return 0; fi
    echo "无"; return 1
}

install_warp() {
    need_root
    local force="${FORCE_REGISTER:-0}"
    acquire_lock || return 1
    init_dirs; migrate_v2 || warn "V2 规则导入未完成 (不影响本次安装, 详见上)"
    local st; st=$(already_installed)
    case "$st" in
        接口*)
            ok "检测到 WARP 已运行 ($st) — 复用, 不重复安装"
            if health_check; then
                ok "健康检查: 通过 (握手 ${HANDSHAKE_AGE:-n/a})"
                gen_outbound || true
                # 复用路径原来**直接 return 0**, 从不装开机单元 —— 已有 WARP (fscarmen/wgcf/手装)
                # 的机器跑完 install 后既无 restore 也无 keepalive: 重启后分流静默不回。
                install_units || { err "开机单元安装失败 — 重启后**不会**自动恢复分流"; return 1; }
                info "下一步: 'catmi-warp apply --yes' 启用域名分流"
                return 0
            fi
            warn "接口存在但健康检查未通过 — 诊断如下 (不会自动重注册):"
            diagnose
            return 1
            ;;
        凭据|服务|进程)
            info "发现已有凭据/服务但接口未起 — 先尝试复用启动..."
            systemctl start wg-quick@warp >/dev/null 2>&1
            systemctl start warp-go >/dev/null 2>&1
            sleep 2
            if detect_iface && health_check; then
                ok "现有环境启动成功 — 复用 (接口: $IFACE)"
                gen_outbound || true
                install_units || { err "开机单元安装失败 — 重启后**不会**自动恢复分流"; return 1; }
                return 0
            fi
            warn "现有环境无法拉起/不健康 — 诊断如下:"
            diagnose
            if [[ "$force" != "1" ]]; then
                err "按 §5 原则: 启动失败 ≠ 账号失效, 已停止。"
                err "若诊断确认需重建: catmi-warp install --force-register"
                return 1
            fi
            warn "--force-register: 用户明确要求重新注册"
            ;;
    esac
    # 全新注册 (或 --force-register)
    if [[ "$force" == "1" ]] && detect_iface; then
        err "已有运行中的 WARP 接口 ($IFACE) — 先 'catmi-warp stop' 并移除旧凭据再重注册, 防止误覆盖"
        return 1
    fi
    # 注册流程本身要用 python3 (解析 CF 响应) 和 curl —— 而 ensure_deps 原来只在 apply 里调,
    # 于是全新机器 (Debian 精简镜像默认没有 python3) 会被下面的体检直接拦下,
    # 明明工具自己装得动。这里先把这两件事办了。
    command -v python3 >/dev/null 2>&1 || pkg_install python3
    command -v curl >/dev/null 2>&1 || pkg_install curl
    command -v check_env >/dev/null 2>&1  # no-op guard
    if ! check_env >/dev/null 2>&1; then
        warn "环境体检未通过, 详见: catmi-warp check"
        return 1
    fi
    if register_warp; then
        gen_outbound || true
        install_units || { err "开机单元安装失败 — 重启后**不会**自动恢复分流 (WARP 本体已就绪)"; return 1; }
        ok "安装完成 — 'catmi-warp3 status' 看出口 / 'catmi-warp3 apply --yes' 启用分流"
        log_op "install" "OK fresh register"
        return 0
    fi
    err "安装失败 (诊断见上) — 备选 (用户态回退, v6 受限): fscarmen warp-go: bash <(curl -sSL https://gitlab.com/fscarmen/warp/-/raw/main/warp-go.sh) n"
    log_op "install" "FAILED"
    return 1
}

start_warp() {
    if detect_iface; then
        ok "WARP 已在运行 ($IFACE, $(warp_source)) — 无需启动"
        return 0
    fi
    # 来源感知: 只启动与现有凭据对应的【一个】服务 (绝不再逐一尝试多个实现)
    # 优先级: 内核 WG (性能/双栈 v6 完整) > warp-go (用户态回退; v6 受限)
    if [[ -s /etc/wireguard/warp.conf ]]; then
        systemctl start wg-quick@warp >/dev/null 2>&1
        sleep 1
        detect_iface && { ok "wg-quick@warp 已启动 (接口 $IFACE)"; return 0; }
        err "wg-quick@warp 启动失败 — catmi-warp3 install 看诊断"
    fi
    if [[ -s /opt/warp-go/warp.conf || -s /opt/warp-go/wgcf.conf || -f /lib/systemd/system/warp-go.service ]]; then
        systemctl start warp-go >/dev/null 2>&1
        sleep 1
        detect_iface && { ok "warp-go 已启动 (接口 $IFACE, 用户态回退)"; return 0; }
        err "warp-go 启动失败 (journalctl -u warp-go -n 5)"
        return 1
    fi
    err "未找到 WARP 凭据/服务 — catmi-warp3 install 或 fscarmen 安装"
    return 1
}

stop_warp() {
    local force="${FORCE_STOP:-0}"
    detect_iface || { warn "无运行中的 WARP"; return 0; }
    local src unit mgr=""
    src=$(warp_source)
    case "$IFACE" in
        warp)
            unit="wg-quick@warp"
            if grep -q 'Table = off' /etc/wireguard/warp.conf 2>/dev/null; then
                mgr="catmi-warp 自研"
            else
                mgr="外部 (fscarmen warp-go)"
            fi ;;
        WARP)           unit="warp-go";       mgr="外部 (fscarmen warp-go)" ;;
        CloudflareWARP) unit="warp-svc";      mgr="外部 (warp-cli)" ;;
        wgcf)           unit="wg-quick@wgcf"; mgr="外部 (wgcf)" ;;
        *)              unit="" ;;
    esac
    if [[ -z "$unit" ]]; then
        err "无法定位 $IFACE 对应的服务单元 — 不盲停 (接口保留)"
        return 1
    fi
    # 外部管理器提供的 WARP 默认不停 — 显式确认或 --force 才允许
    if [[ "$mgr" == 外部* && "$force" != "1" ]]; then
        echo "⚠ 当前 WARP 由外部管理器提供: $src ($mgr)" >&2
        echo "  停止可能影响外部管理器状态 (fscarmen 菜单/开机自启)" >&2
        printf "  确认停止? (y/N): " >&2
        local yn; read -r yn </dev/tty 2>/dev/null || yn=""
        case "${yn,,}" in
            y|yes) : ;;
            *) ok "已取消停止 (确认路径: catmi-warp3 stop --force)"; return 0 ;;
        esac
    fi
    if systemctl stop "$unit" 2>/dev/null; then
        ok "$unit 已停止 ($mgr)"
    else
        warn "$unit 停止失败/未运行"
    fi
    return 0
}

# ============================================================
# 出站片段 (§15/§16# 出站片段 (§15/§16: 只提供能力, 不做路由管理器)
# ============================================================
gen_outbound() {
    parse_creds || { err "未找到 WARP 凭据 (先安装 WARP)"; return 1; }
    local mtu="${WARP_MTU:-1280}"
    local ep_host="${ENDPOINT%%:*}" ep_port="${ENDPOINT##*:}"
    local res_json="null" res_yaml="null"
    if [[ -n "$RESERVED" ]]; then
        res_json="[$(echo "$RESERVED" | awk -F, '{for(i=1;i<=NF;i++){printf "%s%s",(i>1?",":""),$i}}')]"
        res_yaml="[$(echo "$RESERVED" | awk -F, '{for(i=1;i<=NF;i++){printf "%s%s",(i>1?", ":""),$i}}')]"
    fi
    {
        echo '{'
        echo '  "protocol": "wireguard",'
        echo '  "tag": "catmi-warp",'
        echo '  "settings": {'
        echo "    \"secretKey\": \"$PRIVKEY\","
        local addrs="\"$ADDR4\""; [[ -n "$ADDR6" ]] && addrs="$addrs, \"$ADDR6\""
        echo "    \"address\": [$addrs],"
        echo '    "peers": [{'
        echo "      \"publicKey\": \"$PEER_PUB\","
        echo "      \"endpoint\": \"$ENDPOINT\","
        echo '      "allowedIPs": ["0.0.0.0/0", "::/0"]'
        echo '    }],'
        echo "    \"mtu\": $mtu"
        [[ -n "$RESERVED" ]] && echo "    ,\"reserved\": $res_json"
        echo '  }'
        echo '}'
    } > "$OUTDIR/xray-warp-outbound.json"
    {
        echo "- name: catmi-warp"
        echo "  type: wireguard"
        echo "  server: $ep_host"
        echo "  port: $ep_port"
        [[ -n "$ADDR4" ]] && echo "  ip: ${ADDR4%%/*}"
        [[ -n "$ADDR6" ]] && echo "  ipv6: ${ADDR6%%/*}"
        echo "  private-key: $PRIVKEY"
        echo "  public-key: $PEER_PUB"
        echo "  allowed-ips: ['0.0.0.0/0', '::/0']"
        echo "  mtu: $mtu"
        echo "  udp: true"
        [[ -n "$RESERVED" ]] && echo "  reserved: $res_yaml"
    } > "$OUTDIR/mihomo-warp-proxy.yaml"
    {
        echo '{'
        echo '  "endpoints": [{'
        echo '    "type": "wireguard",'
        echo '    "tag": "catmi-warp",'
        echo "    \"mtu\": $mtu,"
        local saddr="\"$ADDR4\""; [[ -n "$ADDR6" ]] && saddr="$saddr, \"$ADDR6\""
        echo "    \"address\": [$saddr],"
        echo "    \"private_key\": \"$PRIVKEY\","
        echo '    "peers": [{'
        echo "      \"address\": \"$ep_host\","
        echo "      \"port\": $ep_port,"
        echo "      \"public_key\": \"$PEER_PUB\","
        echo '      "allowed_ips": ["0.0.0.0/0", "::/0"]'
        [[ -n "$RESERVED" ]] && echo "      ,\"reserved\": $res_json"
        echo '    }]'
        echo '  }]'
        echo '}'
    } > "$OUTDIR/singbox-warp-outbound.json"
    ok "outbound 片段已生成 (generated/outbound/):"
    echo "    Xray    : $OUTDIR/xray-warp-outbound.json    (outbounds[] 并入)" >&2
    echo "    mihomo  : $OUTDIR/mihomo-warp-proxy.yaml   (proxies[] 并入)" >&2
    echo "    sing-box: $OUTDIR/singbox-warp-outbound.json  (endpoints[] 并入)" >&2
}

socks5_status() {
    local p
    p=$(ss -nltp 2>/dev/null | grep -E 'warp-svc|wireproxy' | grep -oE '127\.0\.0\.1:[0-9]+' | head -1)
    [[ -n "$p" ]] && echo "${p##*:}" || echo ""
}

# ============================================================
# 规则管理 (config/rules.conf: domain|action|enabled|note)
# ============================================================
valid_domain() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; }

# 原子写规则文件 (§17: 临时文件放 runtime/)
# 写失败必须让调用方知道 —— 原来是 `mv -f ... 2>/dev/null`, 返回值没人查,
# 磁盘满/只读挂载时会打印 [OK] 而实际一个字都没写 (实测 EROFS 复现, exit 0)。
rules_atomic() {
    if ! mv -f "$RUNTIME/rules.tmp" "$RULES" 2>/dev/null; then
        err "规则写入失败 (磁盘满 / 只读挂载?) — 改动**未生效**"
        rm -f "$RUNTIME/rules.tmp" 2>/dev/null
        return 1
    fi
    return 0
}

# 判断规则是否存在 —— 用 awk 按字段精确比较, 与下面修改/删除**同一套语义**。
# 反面教材: 原来这里用 `grep -E "^$d\|"`(正则) 判存在、用 awk 字符串相等做修改,
# 同一个值两套语义 → `del "zzz|youtube.com"` 会真的删掉 youtube.com。
rule_exists() { awk -F'|' -v d="$1" '$1==d{f=1} END{exit !f}' "$RULES" 2>/dev/null; }

rule_add() {
    init_dirs
    local d="${1,,}" a="$2"
    valid_domain "$d" || { err "无效域名: $d"; return 1; }
    { [[ "$a" == "warp" ]] || [[ "$a" == "native" ]]; } || { err "action 必须是 warp|native"; return 1; }
    grep -vE "^${d}\|" "$RULES" > "$RUNTIME/rules.tmp" 2>/dev/null
    echo "$d|$a|1|" >> "$RUNTIME/rules.tmp"
    rules_atomic
    ok "规则已保存: $d → $a (apply/warm 后生效)"
}
rule_set_enabled() {
    init_dirs
    local d="${1,,}" e="$2"
    valid_domain "$d" || { err "无效域名: $d"; return 1; }
    rule_exists "$d" || { err "规则不存在: $d"; return 1; }
    awk -F'|' -v d="$d" -v e="$e" 'BEGIN{OFS="|"} $1==d{$3=e} {print}' "$RULES" > "$RUNTIME/rules.tmp" \
        && rules_atomic || return 1
    ok "$d → $([[ "$e" == "1" ]] && echo 启用 || echo 禁用)"
}
rule_del() {
    init_dirs
    local d="${1,,}"
    valid_domain "$d" || { err "无效域名: $d"; return 1; }
    rule_exists "$d" || { err "规则不存在: $d"; return 1; }
    # awk 按字段精确删除 (与 rule_exists 同语义); 原来用 grep -E 会被正则元字符污染
    awk -F'|' -v d="$d" '$1!=d' "$RULES" > "$RUNTIME/rules.tmp" 2>/dev/null \
        && rules_atomic || return 1
    ok "规则已删除: $d"
}
rule_list() { grep -vE '^\s*#|^\s*$' "$RULES" 2>/dev/null; }

# 术语速查 —— 小白最容易被这几个词卡住, help 里原来是零解释
cmd_terms() {
    cat <<'TERMEOF'
catmi-warp3 术语速查
════════════════════════════════════════════════════════════════
WARP         Cloudflare 的加速网络。走它 = 流量从 Cloudflare 的 IP 出去,
             目标网站看到的是 Cloudflare 地址, 不是你的服务器地址。
Native       原生意, 指服务器自己的出口 (eth0 网卡的真实公网 IP)。
             走 Native = 目标网站看到你服务器的真实 IP。

默认出口     没有单独指定出路的流量走哪里。`catmi-warp3 default` 查看/切换:
               dual   双栈    → IPv4 和 IPv6 都走 WARP
               v4     仅 IPv4 → 只有 IPv4 走 WARP (IPv6 走原生)
               v6     仅 IPv6 → 只有 IPv6 走 WARP (没 v6 的机器靠它"补栈")
               native 全原生 → 都不走 WARP (等于关掉分流)

网站规则     给单个域名指定走 WARP 还是 Native:
               catmi-warp3 add openai.com native    → openai 走原生
               catmi-warp3 add google.com warp      → google 走 WARP
               catmi-warp3 list                     → 看我加了哪些
             ⚠ 规则方向**与默认出口相同时不产生额外效果** —— 本来就是那个方向。
               例如默认已是 WARP 时, 再加 warp 规则等于什么都没做。

保存≠应用    add / del / on / off 只改配置; 必须再执行 `apply` 才真正部署到系统。
             改完没生效, 先想想是不是忘了 apply。

出问题先看   catmi-warp3 status   → Stack mode 那行看当前模式
             catmi-warp3 doctor   → 全身体检, 会真连一次网验证出口通不通
             catmi-warp3 test <域名>  → 看某个域名实际从哪个出口出去

Forward      转发流量分流 (默认 OFF)。**普通出口分流不需要开**,
             只有想让"穿过本机转发的流量"也走 WARP 时才开。

入站         别人连进你服务器的流量 (SSH / Nginx / 节点服务)。
             本脚本**永不碰入站**, 不需要为此担心。

NATIVE_IPS   特殊出口豁免表 (在 config/main.conf)。列进去的 IP 永远走原生,
             比如 Xray 的链式上游。**少写一个, 那条出口就会被卷进 WARP。**
             现在默认会**自动扫描**代理内核 outbound 的上游 IP 并并入该豁免
             (config/main.conf 里 AUTO_CHAIN_EXEMPT="0" 可关闭), 所以换节点/加出站后
             只要重启一次 (catmi-warp3 apply --yes) 就自动生效, 不必手工维护。
════════════════════════════════════════════════════════════════
TERMEOF
}

# 手动清理旧快照 —— snapshot() 现在自带保留策略(默认 50), 这个命令给用户一个
# "现在就清一次"的入口, 也方便把历史积累的旧快照一次性收掉。
cmd_cleanup() {
    init_dirs
    local keep="${1:-50}"
    if ! { [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )); }; then
        err "用法: catmi-warp3 cleanup [保留个数, 默认 50]"; return 1
    fi
    local before after
    before=$(ls -1d "$BACKUPS"/*/ 2>/dev/null | wc -l)
    if (( before <= keep )); then
        info "快照只有 $before 个 (上限 $keep), 无需清理"
        return 0
    fi
    ls -1dt "$BACKUPS"/*/ 2>/dev/null | tail -n +$(( keep + 1 )) | while read -r _old; do
        rm -rf "$_old" 2>/dev/null
    done
    after=$(ls -1d "$BACKUPS"/*/ 2>/dev/null | wc -l)
    ok "已清理 $(( before - after )) 个旧快照 (保留最近 $after 个)"
    info "当前占用: $(du -sh "$BACKUPS" 2>/dev/null | cut -f1)"
}

# 快照/备份查看 —— snapshot() 一直在写 $BACKUPS, 但原来**没有任何入口能看到**。
# 出问题时用户至少要知道"系统在改动前存过什么、存在哪", 以及怎么手动退回去。
cmd_snapshots() {
    init_dirs
    echo "改动前的备份 ($BACKUPS):"
    echo
    if [[ ! -d "$BACKUPS" ]] || [[ -z "$(ls -A "$BACKUPS" 2>/dev/null)" ]]; then
        echo "  (还没有备份 — apply / revoke 时才会自动生成)"
        echo
        echo "  想要"一键回到系统默认出口"? → catmi-warp3 revoke  (暂停分流, 规则保留)"
        return 0
    fi
    local d n=0
    for d in $(ls -1t "$BACKUPS" 2>/dev/null | head -15); do
        [[ -d "$BACKUPS/$d" ]] || continue
        n=$((n+1))
        printf '  %-34s %s\n' "$d" "$(stat -c %y "$BACKUPS/$d" 2>/dev/null | cut -d. -f1)"
    done
    echo
    echo "  共 $(ls -1d "$BACKUPS"/*/ 2>/dev/null | wc -l) 个快照, 占用 $(du -sh "$BACKUPS" 2>/dev/null | cut -f1)"
    echo "  自动只保留最近 50 个; 想立刻清: catmi-warp3 cleanup"
    echo "  里面存的是改动前的 ip rule / 路由 / iptables / resolv.conf 现场, 供人工比对。"
    echo
    echo "  想退回系统默认出口 → catmi-warp3 revoke      (暂停分流, 网站规则保留)"
    echo "  想彻底拆掉分流与管理层 → catmi-warp3 uninstall"
}

# 列出全部规则 (含停用) —— 小白 add 完必须能复查自己配了什么
cmd_list() {
    init_dirs
    if [[ ! -s "$RULES" ]] || [[ -z "$(rule_list)" ]]; then
        echo "还没有任何域名规则。"
        echo "  添加: catmi-warp3 add <域名> warp     (该域名走 WARP)"
        echo "        catmi-warp3 add <域名> native   (该域名走服务器原生出口)"
        return 0
    fi
    echo "域名规则 ($RULES):"
    printf '  %-34s %-8s %s\n' "域名" "走向" "状态"
    while IFS='|' read -r dom act en note; do
        [[ -z "$dom" || "$dom" == \#* ]] && continue
        [[ "$en" == "1" ]] && st="启用" || st="停用"
        printf '  %-34s %-8s %s%s\n' "$dom" "$act" "$st" "${note:+   ($note)}"
    done < <(rule_list)
    echo
    echo "  改完记得 apply 才生效: catmi-warp3 apply"
}
rule_count() { # rule_count <action> → 数量
    local n=0 dom act en
    while IFS='|' read -r dom act en _; do
        [[ "$en" == "1" && "$act" == "$1" ]] && ((n++))
    done < <(rule_list)
    echo "$n"
}

# 回显型服务 (test ⑧: 能看到真实出口 IP 的域名)
is_echo_service() {
    case "$1" in
        api.ip.sb|ip.sb|ifconfig.me|ifconfig.co|canhazip.com|ipinfo.io|checkip.amazonaws.com|icanhazip.com|wtfismyip.com) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================
# DNS 检测矩阵 (§10)
# ============================================================
# :53 现状 → echo: dnsmasq|resolved|docker|other|free
detect_dns53() {
    local p53
    p53=$(ss -lnup 2>/dev/null | grep ':53 ' || true)
    if [[ -z "$p53" ]]; then echo free; return; fi
    if grep -q 'dnsmasq' <<<"$p53"; then echo dnsmasq
    elif grep -q 'systemd-resolve' <<<"$p53"; then echo resolved
    elif grep -qE 'docker|containerd' <<<"$p53"; then echo docker
    elif ! grep -q 'users:(' <<<"$p53"; then
        # 非 root (或权限不足) 时 `ss -p` **不输出进程名** → 上面几个 grep 全部落空,
        # 会把正在跑的 dnsmasq 误报成 other (实测)。退回用 systemd 判断谁在提供 :53。
        if systemctl is-active --quiet dnsmasq 2>/dev/null; then echo dnsmasq
        elif systemctl is-active --quiet systemd-resolved 2>/dev/null; then echo resolved
        else echo other; fi
    else echo other; fi
}

# NetworkManager / resolvconf 检测 (可能重写 resolv.conf 的服务)
detect_dns_rewriters() {
    local rewriters=()
    systemctl is-active NetworkManager >/dev/null 2>&1 && rewriters+=("NetworkManager")
    systemctl is-active resolvconf >/dev/null 2>&1 && rewriters+=("resolvconf")
    systemctl is-active systemd-resolved >/dev/null 2>&1 && rewriters+=("systemd-resolved")
    ((${#rewriters[@]} > 0)) && echo "${rewriters[*]}" || echo ""
}

resolv_points_local() { grep -q 'nameserver 127.0.0.1' "$RESOLV" 2>/dev/null; }

# resolv.conf 的 immutable 属性 (VPS 镜像/面板常用 `chattr +i` 防 DHCP 改写 DNS)。
# 带 i 的文件内核直接拒绝写入, 而 shell 的 `> file` 失败**不会**让脚本察觉 ——
# 实测 CCS: state 记了 MANAGED=1、apply 报成功, 文件仍是 1.1.1.1。
resolv_immutable() {
    command -v lsattr >/dev/null 2>&1 || return 1
    lsattr -d "$RESOLV" 2>/dev/null | awk 'NR==1{print $1}' | grep -q 'i'
}

# 临时解除 immutable 并记录「是我们解除的」→ revoke 时自动加回
resolv_unlock() {
    resolv_immutable || return 0
    command -v chattr >/dev/null 2>&1 || return 1
    chattr -i "$RESOLV" 2>/dev/null || return 1
    IMMUTABLE_RESTORE=1
    info "resolv.conf 带 immutable 属性 (VPS 加固) — 已临时解除, 还原时会自动加回"
    return 0
}

# DNS 决策 (纯函数, selftest 可测): 入参 mode resolv_local(0/1) → echo 决策
#   reuse     : 纯复用, 零改动
#   takeover  : 部署 dnsmasq + 切 resolv (备份)
#   reject    : 拒绝接管
dns_decision() {
    local mode="$1" points="$2"
    case "$mode" in
        dnsmasq)  [[ "$points" == "1" ]] && echo reuse || echo takeover ;;
        free)     echo takeover ;;
        resolved) echo takeover ;;
        *)        echo reject ;;
    esac
}

# 生成 dnsmasq conf (generated/ + symlink 到 /etc/dnsmasq.d/)
gen_dnsmasq_conf() {
    {
        echo "# 由 catmi-warp3 v$VERSION 生成 — 域名分流 ipset (重载会覆盖)"
        echo "listen-address=127.0.0.1"
        echo "bind-interfaces"
        echo "no-resolv"
        local s
        for s in $UPSTREAMS; do echo "server=$s"; done
        local dom act en
        # per-family: 只把"例外方向"的域名喂给 dnsmasq (默认方向无需集合)
        #   某协议栈 native 默认 → warp 规则是该栈例外 → cw3-warp4 或 cw3-warp6
        #   某协议栈 warp  默认 → native 规则是该栈例外 → cw3-native4 或 cw3-native6
        # 规则 action 语义跨栈一致: warp=域名走 WARP, native=域名走原生
        while IFS='|' read -r dom act en _; do
            [[ "$en" != "1" ]] && continue
            local s4="" s6=""
            [[ "$act" == "warp"   && "$DEFAULT_OUTBOUND_V4" == "native" ]] && s4="cw3-warp4"
            [[ "$act" == "native" && "$DEFAULT_OUTBOUND_V4" == "warp"   ]] && s4="cw3-native4"
            [[ "$act" == "warp"   && "$DEFAULT_OUTBOUND_V6" == "native" ]] && s6="cw3-warp6"
            [[ "$act" == "native" && "$DEFAULT_OUTBOUND_V6" == "warp"   ]] && s6="cw3-native6"
            local lst=""
            [[ -n "$s4" ]] && lst="$s4"
            [[ -n "$s6" ]] && lst="${lst:+$lst,}$s6"
            [[ -n "$lst" ]] && echo "ipset=/$dom/$lst"
        done < <(rule_list)
    } > "$GEN_DNS_REAL"
    # 生成物必须非空 —— 重定向失败/盘满时是空文件, dnsmasq 会"正常启动"但一条规则都没有
    if [[ ! -s "$GEN_DNS_REAL" ]]; then
        err "生成 dnsmasq 配置失败 ($GEN_DNS_REAL 为空) — 域名规则不会生效"
        return 1
    fi
    # symlink 接入 dnsmasq; 他人文件 → 拒绝; 自家遗留普通文件(如被 sed -i 炸掉的 symlink) → 收回
    if [[ -e "$GEN_DNS_LINK" && ! -L "$GEN_DNS_LINK" ]]; then
        if head -1 "$GEN_DNS_LINK" 2>/dev/null | grep -q 'catmi-warp'; then
            rm -f "$GEN_DNS_LINK"
        else
            err "/etc/dnsmasq.d/catmi-warp.conf 已被其他内容占用 (非本模块文件)"
            return 1
        fi
    fi
    # conf-dir 必须存在 (全新机器上 dnsmasq 刚装完才有 /etc/dnsmasq.d)
    mkdir -p "$(dirname "$GEN_DNS_LINK")" 2>/dev/null
    ln -sfn "$GEN_DNS_REAL" "$GEN_DNS_LINK"
    # ln 失败原先是**静默**的: dnsmasq 拿不到 ipset= 行 ⇒ 域名规则一条都不生效, 而
    # 整个 apply 会显示成功 (dnsmasq 自己跑得好好的)。这里必须回读确认。
    if [[ ! -L "$GEN_DNS_LINK" ]] || \
       [[ "$(readlink -f "$GEN_DNS_LINK" 2>/dev/null)" != "$(readlink -f "$GEN_DNS_REAL" 2>/dev/null)" ]]; then
        err "接入 dnsmasq 失败: $GEN_DNS_LINK 未指向生成的配置 — 域名规则不会生效"
        return 1
    fi
    return 0
}

# 清理生成 conf (symlink 或自家标记的普通文件; 他人的不动)
cleanup_dns_conf() {
    if [[ -L "$GEN_DNS_LINK" ]]; then
        rm -f "$GEN_DNS_LINK"
    elif [[ -f "$GEN_DNS_LINK" ]] && head -1 "$GEN_DNS_LINK" 2>/dev/null | grep -q 'catmi-warp'; then
        rm -f "$GEN_DNS_LINK"
    fi
    rm -f "$GEN_DNS_REAL"
    return 0
}

# 拆除本模块的**全部**系统改动 —— 顺序敏感, 必须整体抽成一个函数。
# 反面教材: 之前只抽出了一个收尾助手 dnsmasq_after_conf_removed(), 两个调用方各自
# 排列其余步骤 → rollback_undo 把 dns_release 放在收尾**之前**, 而 dns_release 的
# DNS 兜底条件是「dnsmasq 已停」(那时它还没停) → 兜底不触发 → 紧接着收尾把 dnsmasq
# 停掉 → resolv.conf 仍指向 127.0.0.1 却没有服务 = 整机 DNS 死。
# 正确顺序: 拆防火墙 → 撤 dnsmasq 配置并收尾 → **最后**还原 resolv.conf。
teardown_all() {
    fw_down_silent
    cleanup_dns_conf
    dnsmasq_after_conf_removed
    dns_release
}

# 撤掉本模块 dnsmasq 配置后的收尾 —— rollback_undo / revoke 都必须走 teardown_all()。
# 为什么不能直接 restart: 撤掉 conf 后 dnsmasq 退回默认配置(绑 *:53), 若 :53 已被
# systemd-resolved (127.0.0.53:53) 占用, 重启会**永久 failed 且无人察觉**, 把整机 DNS 打死。
# 所以必须校验: 起不来就停掉, 至少留下干净的 inactive 而不是 failed。
# (v3 实测缺陷 — 两个调用方各写一遍正是这个 bug 能活下来的原因)
dnsmasq_after_conf_removed() {
    systemctl is-active dnsmasq >/dev/null 2>&1 || return 0
    systemctl restart dnsmasq 2>/dev/null
    if ! systemctl is-active --quiet dnsmasq 2>/dev/null; then
        # 注意: `systemctl stop` **不会**清除失败状态 —— 实测 stop 之后
        # ActiveState 仍是 exit-code / Result=failed, 必须 reset-failed 才干净。
        warn "撤配置后 dnsmasq 起不来 (:53 被 systemd-resolved 占用) — 已停用并清除失败状态"
        systemctl stop dnsmasq 2>/dev/null
        systemctl reset-failed dnsmasq 2>/dev/null
        if systemctl is-active --quiet dnsmasq 2>/dev/null; then
            warn "dnsmasq 仍在运行 (非预期)"
        fi
    fi
    return 0
}

dns_deploy() { # 部署 dnsmasq 配置并确保服务运行 (先写 conf 再启动 — V1 教训 B3)
    gen_dnsmasq_conf || return 1
    if ! systemctl is-active dnsmasq >/dev/null 2>&1; then
        systemctl enable --now dnsmasq >/dev/null 2>&1 \
            || { err "dnsmasq 启动失败 (dnsmasq --test / journalctl -u dnsmasq -n 5)"; return 1; }
    fi
    # RN 实测: reload 不重建 ipset 关联 (必须 restart) — 否则 ipset 永远 0 成员。
    # 但 restart 是「停 + 立即起」, 旧进程偶发未释放 :53 → 校验并重试 (v3 实测竞态)
    local _dtry
    for _dtry in 1 2 3; do
        systemctl restart dnsmasq 2>/dev/null || systemctl reload dnsmasq 2>/dev/null
        sleep 1
        systemctl is-active --quiet dnsmasq 2>/dev/null && break
    done
    # validate: 本地解析必须活
    if ! timeout 5 dig +short @127.0.0.1 cloudflare.com A >/dev/null 2>&1; then
        err "dnsmasq 部署后本地解析仍不通 (127.0.0.1)"
        return 1
    fi
    ok "dnsmasq 运行中 (127.0.0.1:53)"
}

# resolv.conf 接管 (state 驱动; 原件永不覆盖 — 第一个原件才是真原件)
dns_takeover() {
    local now_points; resolv_points_local && now_points=1 || now_points=0
    local rtype="file" ltarget=""
    [[ -L "$RESOLV" ]] && { rtype="symlink"; ltarget=$(readlink -f "$RESOLV" 2>/dev/null); }
    if [[ "$now_points" == "1" ]]; then
        if [[ ! -s "$RESOLV_STATE" ]]; then
            # 已指向 127.0.0.1 但无 state — 补录: 备份当前形态与内容 + 完整 state
            local pre="$BACKUPS/resolv.pre-$(date +%Y%m%d-%H%M%S)"
            cp -fL "$RESOLV" "$pre" 2>/dev/null
            [[ ! -s "$BACKUPS/resolv.orig" ]] && cp -fL "$RESOLV" "$BACKUPS/resolv.orig" 2>/dev/null
            {
                echo "MANAGED=1"; echo "BACKUP=$pre"
                echo "RESOLV_TYPE=$rtype"
                [[ -n "$ltarget" ]] && echo "LINK_TARGET=$ltarget"
                echo "ORIG_SHA=$(sha256sum "$RESOLV" 2>/dev/null | awk '{print $1}')"
                echo "TS=$(date '+%F %T')"
                echo "NOTE=premanaged (resolvconf/dnsmasq 集成或用户自配的 127.0.0.1)"
            } > "$RESOLV_STATE"
            info "resolv.conf 已指向 127.0.0.1 (非本模块所改) — 已补录管理标记与状态备份"
        else
            ok "resolv.conf 已由本模块管理且指向 127.0.0.1"
        fi
        return 0
    fi
    # 需要切换
    if [[ ! -s "$RESOLV_STATE" ]]; then
        local pre="$BACKUPS/resolv.pre-$(date +%Y%m%d-%H%M%S)"
        cp -fL "$RESOLV" "$pre" 2>/dev/null     # -L: symlink 时备份解引内容
        [[ ! -s "$BACKUPS/resolv.orig" ]] && cp -fL "$RESOLV" "$BACKUPS/resolv.orig" 2>/dev/null
        {
            echo "MANAGED=1"; echo "BACKUP=$pre"
            echo "RESOLV_TYPE=$rtype"
            [[ -n "$ltarget" ]] && echo "LINK_TARGET=$ltarget"
            echo "ORIG_SHA=$(sha256sum "$RESOLV" 2>/dev/null | awk '{print $1}')"
            echo "TS=$(date '+%F %T')"
        } > "$RESOLV_STATE"
    fi
    # 接管: 移除链接本身 → 写普通文件 (bash 的 > 重定向会穿透 symlink 写目标文件,
    # 这正是 V2 的隐患; 目标内容已随 pre 备份保留, 链接形态由 state 记录)
    resolv_unlock || { err "$RESOLV 带 immutable 属性且无法解除 (缺 chattr?) — 接管中止"; return 1; }
    if [[ -L "$RESOLV" ]]; then
        rm -f "$RESOLV"
    fi
    { echo "# catmi-warp3 v$VERSION managed — 还原: catmi-warp3 revoke"; echo "nameserver 127.0.0.1"; } > "$RESOLV" 2>/dev/null
    # **必须回读确认**: immutable / 只读挂载 / 被面板托管时, 重定向会静默失败,
    # 而后续 dnsmasq 明明在跑、apply 全绿 —— 只有 doctor 事后报"漂移"能看出来。
    if ! resolv_points_local; then
        err "写入 $RESOLV 失败 — 接管未生效 (immutable 属性? 只读挂载? 被面板托管?)"
        [[ "${IMMUTABLE_RESTORE:-}" == "1" ]] && chattr +i "$RESOLV" 2>/dev/null
        return 1
    fi
    [[ "${IMMUTABLE_RESTORE:-}" == "1" ]] && echo "IMMUTABLE_RESTORE=1" >> "$RESOLV_STATE"
    ok "resolv.conf → 127.0.0.1 (原件已备份; 原形态: $rtype$([[ -n "$ltarget" ]] && echo " → $ltarget"))"
    return 0
}

dns_release() {
    if [[ -s "$RESOLV_STATE" ]]; then
        local bak rtype ltarget orig now
        bak=$(grep -E "^BACKUP=" "$RESOLV_STATE" | cut -d= -f2-)
        rtype=$(grep -E "^RESOLV_TYPE=" "$RESOLV_STATE" | cut -d= -f2-)
        ltarget=$(grep -E "^LINK_TARGET=" "$RESOLV_STATE" | cut -d= -f2-)
        orig=$(grep -E "^ORIG_SHA=" "$RESOLV_STATE" | cut -d= -f2-)
        if [[ "$rtype" == "symlink" && -n "$ltarget" ]]; then
            # 恢复符号链接形态 (链接目标文件未被写过, 内容自洽)
            rm -f "$RESOLV"
            if ln -s "$ltarget" "$RESOLV"; then
                ok "resolv.conf 符号链接已还原 → $ltarget"
            else
                err "符号链接重建失败 — 手动: ln -s $ltarget $RESOLV"
            fi
        elif [[ -s "$bak" ]]; then
            cp -f "$bak" "$RESOLV" && ok "resolv.conf 已按 state 还原 (自 $bak)"
        else
            warn "state 记录的备份不存在, resolv.conf 保持现状 (手动检查 $RESOLV)"
        fi
        # 兜底校验: 若还原后仍指向本地回环且 dnsmasq 已停 → 整机 DNS 死, 写公共 DNS 救场
        # (resolvconf 服务会在还原后重写 resolv.conf, 已多次实测复现)
        if ! systemctl is-active dnsmasq >/dev/null 2>&1 && grep -q "^nameserver 127" "$RESOLV" 2>/dev/null; then
            printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > "$RESOLV" 2>/dev/null                 && ok "resolv.conf 兜底为公共 DNS (检测到本地 DNS 已失效)"
        fi
        # 恢复准确性校验
        if [[ -n "$orig" && "$orig" != "unknown-premanaged" ]]; then
            # 单引号! 原来写 `awk "{print $1}"`: bash 会先把 $1 展开成函数的位置参数
            # (dns_release 无参 → 空) ⇒ awk 程序变成 `{print }` 输出**整行**,
            # 而 orig 只是哈希 ⇒ 比较永远不相等 ⇒ 这条告警**无条件触发**。
            # 后果不是"多一条告警", 而是真被改写时根本分不出来 (V1 当时把它当成了预期行为)。
            now=$(sha256sum "$RESOLV" 2>/dev/null | awk '{print $1}')
            [[ "$now" == "$orig" ]] || warn "resolv.conf SHA 与接管前不一致 (可能被其他服务重写, 请人工确认)"
        fi
        # 接管时若解除过 immutable, 这里必须加回去 —— 否则等于我们**永久**拿掉了
        # 用户 VPS 上的那层加固 (还原 ≠ 只还原内容)
        if grep -q '^IMMUTABLE_RESTORE=1' "$RESOLV_STATE" 2>/dev/null; then
            if command -v chattr >/dev/null 2>&1 && chattr +i "$RESOLV" 2>/dev/null; then
                info "已还原 resolv.conf 的 immutable 属性 (chattr +i)"
            else
                warn "immutable 属性还原失败 — 手动执行: chattr +i $RESOLV"
            fi
        fi
        rm -f "$RESOLV_STATE"
    else
        if resolv_points_local; then
            warn "resolv.conf 指向 127.0.0.1 但无接管记录 — 保持现状 (dnsmasq 已停则请手动改回)"
        fi
    fi
    return 0
}

# 预热: 启用域名# 预热: 启用域名 dig 填 ipset
warm_domains() {
    command -v dig >/dev/null 2>&1 || pkg_install dnsutils
    local dom act en
    while IFS='|' read -r dom act en _; do
        # 预热**全部**已启用规则 —— 原来写成 `act == "warp"`, 把 native 规则整个跳过:
        # 在第一个客户端经本机 dnsmasq 解析该域名之前, 对应的 cw3-native4/6 是空的,
        # 这段时间打到该 IP 的流量 (客户端用 DoH / 代理内核自己远程解析域名) 会走 WARP
        # 而不是原生。dnsmasq 只会把域名填进「按当前栈生成的」那个集合, 多 dig 无副作用。
        [[ "$en" == "1" ]] || continue
        dig +short @127.0.0.1 "$dom" A >/dev/null 2>&1
        # 注意: 本机无 v6 出口时跳过 AAAA — 用 if 而非 [[ ]]&&, 避免短路返回 1 污染函数退出码
        # 判据用 has_v6 (有没有全局 v6 地址), 不用 all.disable_ipv6 (那只是新接口默认值)
        if has_v6; then
            dig +short @127.0.0.1 "$dom" AAAA >/dev/null 2>&1
        fi
    done < <(rule_list)
    return 0
}

# 自愈: 已应用状态下核对 cw3 表路由与 mangle 链是否还在, 缺了就重新应用。
# 为什么必须有: `ip route ... dev <iface>` 是**挂在设备上**的 —— WARP 接口一旦被重建
# (wg-quick restart / wireguard-tools 升级 / 手工重启), 内核会连带删掉 cw3 表里指向
# warp 的默认路由, 而 iptables 规则还在: 标记流量查 cw3 无路由 → 落回 main ⇒
# **默认出口静默变回原生**, 面板上什么异常都看不到 (实测 CCS: restart wg-quick@warp 后
# 两条 cw3 默认路由双双消失, doctor FAIL=3, 出口变回 107.172.232.54)。
# keepalive 定时器每 10 分钟调一次, 所以最坏 10 分钟内自愈; 重启场景由 restore 单元覆盖。
reconcile() {
    init_dirs
    [[ -f "$APPLIED_FLAG" ]] || return 0
    detect_iface >/dev/null 2>&1 || return 0
    local why=""
    iptables -t mangle -S CATMI3-OUT >/dev/null 2>&1 || why="mangle 链丢失"
    [[ -z "$why" ]] && ! ip -4 route show table "$TABLE_NAME" 2>/dev/null | grep -q default && why="cw3 表无 v4 默认路由"
    if [[ -z "$why" && "$DEFAULT_OUTBOUND_V6" == "warp" ]] \
       && ! ip -6 route show table "$TABLE_NAME" 2>/dev/null | grep -q default; then
        why="cw3 表无 v6 默认路由"
    fi
    [[ -z "$why" ]] && return 0
    warn "分流自愈: $why (WARP 接口被重建?) — 自动重新应用"
    ASSUME_YES=1 apply || { err "自愈失败 — 请手动: catmi-warp3 apply --yes"; return 1; }
    ok "分流自愈完成"
    return 0
}

# 四个 ipset 的成员总数 (warm/cmd_warm 的结果核实)
warp_set_total() {
    local t=0 s
    for s in cw3-warp4 cw3-warp6 cw3-native4 cw3-native6; do
        t=$(( t + $(ipset list "$s" 2>/dev/null | grep -cE '^[0-9a-fA-F]') ))
    done
    echo "$t"
}

# 预热并**核实结果** —— 原来无条件打印"规则域名已预热", 而 warm_domains 无论成功失败
# 都 return 0 (dig 的返回值被丢弃), dnsmasq 没起来时四个集合一个成员都不会填也照样报成功。
cmd_warm() {
    local nrule
    nrule=$(awk -F'|' '$3=="1" && $1 !~ /^#/ && NF>1 {c++} END{print c+0}' "$RULES" 2>/dev/null)
    if (( nrule == 0 )); then
        info "没有已启用的规则 — 无需预热 (catmi-warp3 add <域名> warp|native 添加)"
        return 0
    fi
    if ! systemctl is-active --quiet dnsmasq 2>/dev/null; then
        err "dnsmasq 未运行 — 预热不可能生效 (先执行: catmi-warp3 apply)"
        return 1
    fi
    warm_domains
    local n; n=$(warp_set_total)
    if (( n == 0 )); then
        # dnsmasq **只在 cache-miss (真向上游解析) 时才写 ipset**, 命中自己缓存时不写。
        # 所以缓存热的时候 warm 是彻底的空操作 (实测: flush 集合 + 热缓存 dig → 0 条;
        # 清缓存后同一操作 → 2 条)。清一次缓存重试一次, warm 才真的能当自愈手段。
        info "四个集合仍为空 (dnsmasq 缓存命中不写 ipset) — 清缓存后重试一次 ..."
        systemctl reload dnsmasq >/dev/null 2>&1 || pkill -HUP -x dnsmasq 2>/dev/null
        sleep 1
        warm_domains
        n=$(warp_set_total)
    fi
    if (( n > 0 )); then
        ok "预热完成 — 四个集合共 $n 条 (warp4/warp6/native4/native6)"
    else
        warn "预热跑完了但四个集合仍为空 — 解析没写进 ipset, 请查: catmi-warp3 doctor"
    fi
    return 0
}

# ============================================================
# 快照 / 校验 / 回滚 (§18)
# ============================================================
snapshot() { # snapshot <op名> → echo 快照目录
    # 保留策略: 只留最近 KEEP_SNAPSHOTS 个 (默认 50)。
    # 原来**没有任何清理机制** —— 每次 apply/revoke/default 都存一份完整的
    # ip rule / 路由 / iptables / resolv.conf 现场。长期使用会无限增长:
    # 实测 RN 上已累积 330 个目录 / 17MB, 而根分区只有 14G 且已用 68%。
    # 在**创建新快照前**清理最旧的, 保证任何时刻都不超过上限。
    local _keep="${KEEP_SNAPSHOTS:-50}"
    if [[ "$_keep" =~ ^[0-9]+$ ]] && (( _keep > 0 )); then
        ls -1dt "$BACKUPS"/*/ 2>/dev/null | tail -n +$(( _keep + 1 )) | while read -r _old; do
            rm -rf "$_old" 2>/dev/null
        done
    fi
    local s="$BACKUPS/$1-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$s" 2>/dev/null
    ip -4 rule show > "$s/ip-rule4.txt" 2>/dev/null
    ip -6 rule show > "$s/ip-rule6.txt" 2>/dev/null
    ip -4 route show > "$s/ip-route4.txt" 2>/dev/null
    ip -6 route show > "$s/ip-route6.txt" 2>/dev/null
    iptables -t mangle -S > "$s/ipt-mangle4.txt" 2>/dev/null
    ip6tables -t mangle -S > "$s/ipt-mangle6.txt" 2>/dev/null
    iptables -t nat -S > "$s/ipt-nat4.txt" 2>/dev/null
    ip6tables -t nat -S > "$s/ipt-nat6.txt" 2>/dev/null
    ensure_rt_tables; grep 'catmi-warp' /etc/iproute2/rt_tables > "$s/rt_tables.txt" 2>/dev/null
    cp -f "$RESOLV" "$s/resolv.conf" 2>/dev/null
    [[ -s "$RESOLV_STATE" ]] && cp -f "$RESOLV_STATE" "$s/resolv.state" 2>/dev/null
    [[ -s "$GEN_DNS_REAL" ]] && cp -f "$GEN_DNS_REAL" "$s/dnsmasq.conf" 2>/dev/null
    [[ -L "$GEN_DNS_LINK" ]] && readlink -f "$GEN_DNS_LINK" > "$s/dnsmasq.link" 2>/dev/null
    echo "$s"
}

# 回滚 = 精确撤销本模块改动 (不改他人配置; 快照供人工参考)
rollback_undo() {
    info "执行回滚 (撤销本模块全部改动)..."
    teardown_all
    rm -f "$APPLIED_FLAG"
    ok "回滚完成"
    log_op "rollback" "OK"
}

# 分步执行器: 失败即中止 (供 apply 做原子化)
STEP_FAIL=""
run_step() {
    local name="$1"; shift
    info "▸ $name"
    local out
    # 原实现是 `"$@" >/dev/null 2>&1`: 步骤内部的**告警**在成功路径上永远看不到。
    # 实测后果: "v6 补栈自检失败, 已撤回 v6 路由"、"resolv.conf 带 immutable 属性已临时解除"
    # 这类重要提示全被吞掉 —— apply 只打印 4 行步骤名, 用户只能靠事后 doctor 才发现问题。
    # 现在: 成功也透出 WARN/ERR 行; 失败时把完整输出打出来 (原来失败也什么都不显示)。
    if out=$("$@" 2>&1); then
        [[ -n "$out" ]] && grep -E '\[WARN\]|\[ERR\]|△|✗' <<<"$out" | sed 's/^/    /'
        ok "  ✓ $name"
        return 0
    fi
    err "  ✗ $name 失败"
    [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/    /'
    STEP_FAIL="$name"
    return 1
}

# ============================================================
# 防火墙 / 路由 (§8: OUTPUT 常开; PREROUTING/MASQUERADE 仅 forward)
# ============================================================
# 本机是否有可用的 v6 出口 —— 判据是"有没有全局 v6 地址", 而不是
# all.disable_ipv6。后者只是"新接口的默认值": 本机 all=1 但 eth0/he-ipv6 显式=0,
# 有 7 个全局 v6 地址, v6 完全可用。用 all 判定会导致 AAAA 被跳过、
# cw3-native6/warp6 永远空 (v3 实测缺陷)。
has_v6() {
    ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'
}

# ── 链式上游自动豁免 ──────────────────────────────────────────────────
# 场景: 自己的代理出站 (Xray/Mihomo/sing-box 的 out-xx 指向另一台 VPS)。它们**没有**
# mark/bind/sendThrough 声明, 按契约就跟随"默认出口" → 被打标送进 WARP → 远端看到的是
# Cloudflare 的 IP, QUIC/TLS 握手经常直接不通 (实测: hysteria2 出站超时; 关掉本模块立刻恢复)。
# 手工往 NATIVE_IPS 里加 IP, 每换一次节点都要改一遍 —— 所以在 apply / 开机恢复时
# **只读扫描**各内核 outbound 的远端地址, 自动并入原生豁免集合 (永不进 WARP)。
# 只读, 不改他方任何配置; 关闭: config/main.conf 里 AUTO_CHAIN_EXEMPT="0"
chain_exempt_ips() { # [待扫描文件...] 不给参数则扫各内核的常见配置位置
    [[ "${AUTO_CHAIN_EXEMPT:-1}" == "1" ]] || return 0
    local -a files=(); local _explicit=0
    if (( $# > 0 )); then files=("$@"); _explicit=1; fi
    if (( _explicit == 0 )); then
        [[ -n "${_CHAIN_CACHE:-}" ]] && { printf '%s\n' "$_CHAIN_CACHE"; return 0; }
        local f
        for f in /root/catmi/xray/conf/*.json /usr/local/etc/xray/*.json /etc/xray/*.json \
                 /etc/sing-box/*.json /root/catmi/sing-box/*.json \
                 /root/catmi/mihomo/conf/*.yaml /etc/mihomo/*.yaml /etc/hysteria/*.yaml; do
            [[ -s "$f" ]] && files+=("$f")
        done
    fi
    (( ${#files[@]} )) || return 0
    local out
    out=$(
        {
            # JSON: "address"/"server" 的取值 (Xray 的 servers/vnext/hysteria, sing-box 的 outbound)
            # 注意: JSON 的值后面还跟着一个引号, 不能直接用 `$` 锚定裸 IP —— 先取整串再剥壳
            grep -hoE '"(address|server)"[[:space:]]*:[[:space:]]*"[^"]+"' "${files[@]}" 2>/dev/null \
                | sed -E 's/.*:[[:space:]]*"([^"]+)"$/\1/'
            # YAML: server: <值>  (mihomo 的 proxies / hysteria 客户端)
            grep -hoE '^[[:space:]]*server:[[:space:]]*[^[:space:]#]+' "${files[@]}" 2>/dev/null \
                | awk '{print $2}'
        } | while read -r _ip; do
            [[ -n "$_ip" ]] || continue
            # 只收字面 IP (域名形式的出站上游另行处理: 用 `add <域名> native`)
            [[ "$_ip" =~ ^[0-9a-fA-F:.]+$ ]] || continue
            # 私网/回环/链路本地/ULA 另有豁免, 不进这张表 (列表保持干净, 也免得把内网地址当上游)
            case "$_ip" in
                10.*|127.*|169.254.*|192.168.*|100.6[4-9].*|100.[7-9][0-9].*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) continue ;;
                fe80:*|fc*|fd*|::1) continue ;;
            esac
            echo "$_ip"
        done | sort -u | tr '\n' ' '
    )
    out="${out% }"
    (( _explicit == 0 )) && _CHAIN_CACHE="$out"
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return 0
}

fw_up() { # fw_up <iface>
    local ifc="$1"
    parse_creds >/dev/null 2>&1 || true
    if [[ -n "$ADDR6" ]] && ! ip -6 addr show dev "$ifc" 2>/dev/null | grep -qF "${ADDR6%%/*}"; then
        if [[ "$DEFAULT_OUTBOUND_V6" == "warp" ]] || has_v6; then
            sysctl -qw net.ipv6.conf."$ifc".disable_ipv6=0 2>/dev/null
            ip -6 addr add "$ADDR6" dev "$ifc" 2>/dev/null \
                && ok "WARP v6 地址已补配 (${ADDR6%%/*}) — v6 出口就绪" || warn "v6 地址补配失败"
        fi
    fi
    ipset create cw3-warp4 hash:ip family inet  -exist 2>/dev/null
    ipset create cw3-warp6 hash:ip family inet6 -exist 2>/dev/null
    ipset create cw3-native4 hash:ip family inet  -exist 2>/dev/null
    ipset create cw3-native6 hash:ip family inet6 -exist 2>/dev/null
    # OUT 链: 首条规则 = mark 保护 — 已有 mark 的流量一律 RETURN (两模式一致, 永不改)
    #   (Xray sockopt.mark / Mihomo routing-mark / connmark restore / 任何 SO_MARK socket)
    iptables  -t mangle -N CATMI3-OUT 2>/dev/null; iptables  -t mangle -F CATMI3-OUT
    ip6tables -t mangle -N CATMI3-OUT 2>/dev/null; ip6tables -t mangle -F CATMI3-OUT
    # 节点服务(hy2服务端)出站按设计走 WARP — 用户确认的根本目标(2026-09-08 子代理回归确认)。
    # (历史 native 方案的 owner/cgroup 排除块已删除: cgroup --path 需 system.slice/ 前缀否则
    #  Invalid argument 且被静默吞掉; 且其"节点不经WARP"语义与最终需求相反)
    iptables  -t mangle -A CATMI3-OUT -m mark ! --mark 0 -j RETURN
    ip6tables -t mangle -A CATMI3-OUT -m mark ! --mark 0 -j RETURN
    # connmark 方向记忆 (RN 事故教训 2026-09-07, 两次实测校准):
    #   restore: 本模块打过 0x3 的流 → 恢复 mark → 走 WARP (否则后续包被 ESTABLISHED 送回 main → 非对称断流)
    #   ESTABLISHED RETURN: 只命中"无 connmark 的入站流回包" → main 原路 (护 SSH/nginx/HY2)
    iptables  -t mangle -A CATMI3-OUT -j CONNMARK --restore-mark --nfmask 0x3 --ctmask 0x3
    ip6tables -t mangle -A CATMI3-OUT -j CONNMARK --restore-mark --nfmask 0x3 --ctmask 0x3 2>/dev/null
    # 入站回程保护: 入站连接的回包 → packet mark 0x4 → RETURN (不打 0x3), 决策由 fwmark 0x4→main 接管
    iptables  -t mangle -A CATMI3-OUT -m connmark --mark 0x$IMARK/0x$IMARK -j MARK --set-xmark 0x$IMARK
    ip6tables -t mangle -A CATMI3-OUT -m connmark --mark 0x$IMARK/0x$IMARK -j MARK --set-xmark 0x$IMARK 2>/dev/null
    iptables  -t mangle -A CATMI3-OUT -m mark --mark 0x$IMARK/0x$IMARK -j RETURN
    ip6tables -t mangle -A CATMI3-OUT -m mark --mark 0x$IMARK/0x$IMARK -j RETURN 2>/dev/null
    iptables  -t mangle -A CATMI3-OUT -m mark ! --mark 0 -j RETURN
    ip6tables -t mangle -A CATMI3-OUT -m mark ! --mark 0 -j RETURN
    iptables  -t mangle -A CATMI3-OUT -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    ip6tables -t mangle -A CATMI3-OUT -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null
    # 可选: 专用 UID 排除 (config/main.conf SKIP_UIDS, 默认空 = 不启用, 不假设)
    local uid
    for uid in $SKIP_UIDS; do
        iptables  -t mangle -A CATMI3-OUT -m owner --uid-owner "$uid" -j RETURN 2>/dev/null
        ip6tables -t mangle -A CATMI3-OUT -m owner --uid-owner "$uid" -j RETURN 2>/dev/null
    done
    # ===== 私网豁免 (与出口模式无关, 恒定走原生) =====
    # 红线: RFC1918 / Docker 私网 / CGNAT / ULA / link-local **永不进 WARP 分流**。
    # 事故 (2026-09-15 MoonTV): 双栈全 WARP 下 nginx(443) -> 127.0.0.1:8074 -> docker-proxy
    # -> DNAT 172.18.0.3:3000, 目标不是 host LOCAL, 于是被打 mark 0x3 -> 策略路由送进 warp
    # -> Cloudflare 没有 RFC1918 回程 -> 黑盒超时, 所有内网反代网页全挂。
    # 位置: 在**任何 MARK 之前**; 且刻意放在 per-family 分支之外 —— native 模式下若有域名
    # 解析到私网地址, 同样不允许被送进 WARP。
    local _net4 _net6
    for _net4 in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
        iptables  -t mangle -A CATMI3-OUT -d "$_net4" -j RETURN
    done
    for _net6 in fc00::/7 fe80::/10; do
        ip6tables -t mangle -A CATMI3-OUT -d "$_net6" -j RETURN 2>/dev/null
    done
    # ===== per-family 默认方向 (V4/V6 各自 native|warp; 两 family 语义独立) =====
    local ep4="" ep6="" eph="${ENDPOINT%%:*}"
    if [[ -n "$eph" ]]; then
        ep4=$(getent ahostsv4 "$eph" 2>/dev/null | awk '{print $1; exit}')
        ep6=$(getent ahostsv6 "$eph" 2>/dev/null | awk '{print $1; exit}')
    fi
    # ---- IPv4 面 ----
    if [[ "$DEFAULT_OUTBOUND_V4" == "warp" ]]; then
        # 防递归: WARP 封装包(dst=endpoint)必须 RETURN
        [[ -n "$ep4" ]] && iptables -t mangle -A CATMI3-OUT -d "$ep4"/32 -j RETURN 2>/dev/null
        # 本机目标/广播/组播/链路本地 不走 WARP (保护 dnsmasq:53 等本机通信)
        iptables -t mangle -A CATMI3-OUT -m addrtype --dst-type LOCAL     -j RETURN
        iptables -t mangle -A CATMI3-OUT -m addrtype --dst-type BROADCAST -j RETURN
        iptables -t mangle -A CATMI3-OUT -m addrtype --dst-type MULTICAST -j RETURN
        iptables -t mangle -A CATMI3-OUT -d 169.254.0.0/16 -j RETURN
        # Native 例外 → main → Native; 其余无标 = 默认 WARP
        iptables -t mangle -A CATMI3-OUT -m set --match-set cw3-native4 dst -j RETURN
        iptables -t mangle -A CATMI3-OUT -j MARK --set-mark "$MARK"
        iptables -t mangle -A CATMI3-OUT -j CONNMARK --save-mark --nfmask 0x3 --ctmask 0x3
        # bind-interface 保护 (v4)
        local pd4; pd4=$(ip -4 route show default 2>/dev/null | grep -oE 'dev [a-zA-Z0-9_.-]+' | head -1 | awk '{print $2}')
        if [[ -n "$pd4" ]] && ! ip -4 rule show | grep -q "oif $pd4 lookup main"; then
            ip -4 rule add prio 50 oif "$pd4" table main && ok "bind 保护: oif $pd4 → main (prio 50)"
        fi
    else
        iptables -t mangle -A CATMI3-OUT -m set --match-set cw3-warp4 dst -j MARK --set-mark "$MARK"
        iptables -t mangle -A CATMI3-OUT -j CONNMARK --save-mark --nfmask 0x3 --ctmask 0x3
    fi
    # ---- IPv6 面 ----
    if [[ "$DEFAULT_OUTBOUND_V6" == "warp" ]]; then
        # 补栈前置: warp-go (用户态 netstack) 需 AllowedIPs 含 ::/0 才会加密 v6 包
        # (netstack 无 ::/0 路由时, tun 里的 v6 包被直接丢弃 — v4 不受影响)
        local wc="${CATMI_CRED_FILE:-/opt/warp-go/warp.conf}"
        [[ -s "$wc" ]] || wc=$(grep -l 'PrivateKey' /opt/warp-go/warp.conf 2>/dev/null | head -1)
        if [[ -s "$wc" ]] && grep -qE '^#?\s*AllowedIPs' "$wc" && ! grep -E '^AllowedIPs' "$wc" | grep -q '::/0'; then
            sed -i 's/^#\?[[:space:]]*AllowedIPs.*/AllowedIPs = 0.0.0.0\/0,::\/0/' "$wc" \
                && { ok "已启用 warp-go AllowedIPs v6 (补栈需要)"; local wsvc
                    for wsvc in warp-go warp-go.service; do
                        systemctl is-active --quiet "$wsvc" 2>/dev/null && systemctl restart "$wsvc" 2>/dev/null \
                            && ok "已重启 $wsvc 使 v6 生效" && break
                    done; }
        fi
        [[ -n "$ep6" ]] && ip6tables -t mangle -A CATMI3-OUT -d "$ep6"/128 -j RETURN 2>/dev/null
        ip6tables -t mangle -A CATMI3-OUT -m addrtype --dst-type LOCAL     -j RETURN 2>/dev/null
        ip6tables -t mangle -A CATMI3-OUT -m addrtype --dst-type MULTICAST -j RETURN 2>/dev/null
        # 兜底打标在前, native6 豁免在后并**覆盖**成 IMARK —
        # 裸 RETURN 的包 mark=0, 会被「未标 → cw3」前置规则抓回 WARP,
        # 导致 cw3-native6 的 dst 豁免形同虚设 (v3 实测缺陷)
        ip6tables -t mangle -A CATMI3-OUT -j MARK --set-mark "$MARK"
        ip6tables -t mangle -A CATMI3-OUT -m set --match-set cw3-native6 dst -j MARK --set-mark "$IMARK"
        ip6tables -t mangle -A CATMI3-OUT -j CONNMARK --save-mark --nfmask 0x3 --ctmask 0x3 2>/dev/null
        local pd6; pd6=$(ip -6 route show default 2>/dev/null | grep -oE 'dev [a-zA-Z0-9_.-]+' | head -1 | awk '{print $2}')
        if [[ -n "$pd6" ]] && ! ip -6 rule show | grep -q "oif $pd6 lookup main"; then
            ip -6 rule add prio 50 oif "$pd6" table main 2>/dev/null && ok "bind 保护: oif $pd6 → main (v6)"
        fi
    else
        ip6tables -t mangle -A CATMI3-OUT -m set --match-set cw3-warp6 dst -j MARK --set-mark "$MARK"
        ip6tables -t mangle -A CATMI3-OUT -j CONNMARK --save-mark --nfmask 0x3 --ctmask 0x3 2>/dev/null
    fi
    iptables  -t mangle -C OUTPUT -j CATMI3-OUT 2>/dev/null || iptables  -t mangle -A OUTPUT -j CATMI3-OUT
    ip6tables -t mangle -C OUTPUT -j CATMI3-OUT 2>/dev/null || ip6tables -t mangle -A OUTPUT -j CATMI3-OUT
    # FWD 链: 仅 forward=ON; mark 保护同样优先
    if [[ "$FORWARD" == "1" ]]; then
        iptables  -t mangle -N CATMI3-FWD 2>/dev/null; iptables  -t mangle -F CATMI3-FWD
        ip6tables -t mangle -N CATMI3-FWD 2>/dev/null; ip6tables -t mangle -F CATMI3-FWD
        iptables  -t mangle -A CATMI3-FWD -m mark ! --mark 0 -j RETURN
        iptables  -t mangle -A CATMI3-FWD -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
        ip6tables -t mangle -A CATMI3-FWD -m mark ! --mark 0 -j RETURN
        if [[ "$DEFAULT_OUTBOUND_V4" == "warp" ]]; then
            iptables -t mangle -A CATMI3-FWD -m set --match-set cw3-native4 dst -j RETURN
            iptables -t mangle -A CATMI3-FWD -j MARK --set-mark "$MARK"
        else
            iptables -t mangle -A CATMI3-FWD -m set --match-set cw3-warp4 dst -j MARK --set-mark "$MARK"
        fi
        if [[ "$DEFAULT_OUTBOUND_V6" == "warp" ]]; then
            ip6tables -t mangle -A CATMI3-FWD -m set --match-set cw3-native6 dst -j RETURN
            ip6tables -t mangle -A CATMI3-FWD -j MARK --set-mark "$MARK"
        else
            ip6tables -t mangle -A CATMI3-FWD -m set --match-set cw3-warp6 dst -j MARK --set-mark "$MARK"
        fi
        iptables  -t mangle -C PREROUTING -j CATMI3-FWD 2>/dev/null || iptables  -t mangle -A PREROUTING -j CATMI3-FWD
        ip6tables -t mangle -C PREROUTING -j CATMI3-FWD 2>/dev/null || ip6tables -t mangle -A PREROUTING -j CATMI3-FWD
        iptables  -t nat -C POSTROUTING -m mark --mark "$MARK" -j MASQUERADE 2>/dev/null || iptables  -t nat -A POSTROUTING -m mark --mark "$MARK" -j MASQUERADE
        ip6tables -t nat -C POSTROUTING -m mark --mark "$MARK" -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -m mark --mark "$MARK" -j MASQUERADE
        [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] \
            || warn "forward 模式需要 ip_forward=1 (sysctl -w net.ipv4.ip_forward=1) — 本模块不静默修改"
        local pol
        pol=$(iptables -L FORWARD 2>/dev/null | head -1)
        grep -q "policy DROP" <<<"$pol" && warn "filter FORWARD policy=DROP — 转发的分流通路需自行放行"
        ok "forward 模式规则已部署 (PREROUTING + MASQUERADE)"
    fi
    iptables  -t mangle -C POSTROUTING -o "$ifc" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables  -t mangle -A POSTROUTING -o "$ifc" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ip6tables -t mangle -C POSTROUTING -o "$ifc" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || ip6tables -t mangle -A POSTROUTING -o "$ifc" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    # 表名必须先注册进词典, 否则下面每一句 `lookup $TABLE_NAME` 都会报 invalid table ID
    # (Debian 13 默认没有这个文件; 写失败在这里就停, 不留"半生效"现场)
    register_rt_table || return 1
    ip -4 rule show | grep -q "^$RT_ANCHOR:.*fwmark 0x$MARK lookup $TABLE_NAME" || ip -4 rule add prio "$RT_ANCHOR" fwmark "$MARK" table "$TABLE_NAME"
    ip -6 rule show | grep -q "^$RT_ANCHOR:.*fwmark 0x$MARK lookup $TABLE_NAME" || ip -6 rule add prio "$RT_ANCHOR" fwmark "$MARK" table "$TABLE_NAME" 2>/dev/null
    # 入站连接打 connmark 0x4 (仅标记, 不改包): 回包经上面 OUTPUT 检查走 main, 保住入站源地址
    local up4 up6
    up4=$(ip -4 route show default 2>/dev/null | grep -oE 'dev [a-zA-Z0-9_.-]+' | head -1 | awk '{print $2}')
    up6=$(ip -6 route show default 2>/dev/null | grep -oE 'dev [a-zA-Z0-9_.-]+' | head -1 | awk '{print $2}')
    if [[ -n "$up4" ]]; then
        iptables  -t mangle -C INPUT -i "$up4" -j CONNMARK --set-xmark 0x$IMARK/0x$IMARK 2>/dev/null \
            || iptables  -t mangle -I INPUT 1 -i "$up4" -j CONNMARK --set-xmark 0x$IMARK/0x$IMARK
    fi
    if [[ -n "$up6" ]]; then
        ip6tables -t mangle -C INPUT -i "$up6" -j CONNMARK --set-xmark 0x$IMARK/0x$IMARK 2>/dev/null \
            || ip6tables -t mangle -I INPUT 1 -i "$up6" -j CONNMARK --set-xmark 0x$IMARK/0x$IMARK
    fi
    # 例外集合清空: 默认方向切换后, 旧方向的集合成员含义反转 (残留会误触发 MARK/RETURN)
    # 清空后由 dnsmasq 按当前 per-family 方向重填 (apply 的预热步骤)
    local _ips
    for _ips in cw3-warp4 cw3-warp6 cw3-native4 cw3-native6; do
        ipset list "$_ips" >/dev/null 2>&1 && ipset flush "$_ips" 2>/dev/null
    done
    # 固定 IP native 豁免 (NATIVE_IPS + 自动识别的链式上游): 域名 native 规则走 dnsmasq
    # 动态填 set; 固定 IP 在这里静态填 — -exist 幂等, revoke 清空后 apply 重填。
    # 自动识别见 chain_exempt_ips(): 换节点/加出站后只要重启一次 (apply) 就会重扫。
    local _nip _ce
    _ce=$(chain_exempt_ips)
    for _nip in $NATIVE_IPS $_ce; do
        # WARP 自己的 endpoint 不进豁免表 (它在链里已单独 RETURN)
        [[ -n "$ep4" && "$_nip" == "$ep4" ]] && continue
        [[ -n "$ep6" && "$_nip" == "$ep6" ]] && continue
        if [[ "$_nip" == *:* ]]; then
            ipset add cw3-native6 "$_nip" -exist 2>/dev/null
        else
            ipset add cw3-native4 "$_nip" -exist 2>/dev/null
        fi
    done
    # 压制外部全接管 (动态优先级; 细节见 suppress_takeover 函数注释)
    suppress_takeover
    ip -4 route replace default dev "$ifc" table "$TABLE_NAME" 2>/dev/null
    if [[ "$DEFAULT_OUTBOUND_V6" == "warp" ]]; then
        if ip -6 route replace default dev "$ifc" table "$TABLE_NAME" 2>/dev/null; then
            ok "cw3 v6 表默认路由已部署 (v6 出站 → WARP)"
            # 连通性自检: WARP 隧道的 v6 出站真实可用才保留路由 (netstack 不支持 v6 时撤回, 兜底原生)
            local v6ok
            # 自检用 ICMP (无 DNS/connmark 时序干扰): ping CF 的 v6 DNS, 走 wg 加密通道
            # 判据必须是 `== 1`。原来写的是 `[[ -n "$v6ok" ]]`, 而 grep -c 没命中时输出 "0"
            # (非空字符串) ⇒ 恒为真: 自检**永远报通过**, 撤回分支是死代码, 还会打印
            # "v6 补栈连通性 OK (出口 0)" 这种自相矛盾的话 (实测确认)。
            local v6ok=""
            if command -v ping >/dev/null 2>&1; then
                v6ok=$(ping -6 -c1 -W3 -I "$ifc" 2606:4700:4700::1111 2>/dev/null | grep -c '1 received')
                [[ "$v6ok" != "1" ]] && { sleep 3
                    v6ok=$(ping -6 -c1 -W3 -I "$ifc" 2606:4700:4700::1111 2>/dev/null | grep -c '1 received'); }
            fi
            if [[ "$v6ok" == "1" ]]; then
                ok "v6 补栈连通性自检通过 (WARP v6 出站可用)"
            elif [[ -z "$v6ok" ]]; then
                warn "无 ping 命令, 跳过 v6 补栈自检 — 路由已保留, 请用 doctor 复核 v6 出口"
            else
                ip -6 route del default table "$TABLE_NAME" 2>/dev/null
                warn "v6 补栈自检失败 (WARP v6 通道不通) — 已撤回 v6 路由, v6 兜底原生出口 (doctor 会提示)"
            fi
        else
            warn "cw3 v6 表路由失败 — v6 兜底走原生出口 (补栈未就绪)"
        fi
    elif ! has_v6; then
        # 判据必须是"本机到底有没有 v6 地址", **不能**用 all.disable_ipv6 ——
        # 那只是新接口的默认值: RN 实测开机后 all=1 而 eth0/he-ipv6 各有全局地址,
        # 旧写法在这种机器上会跳过建表 → native 模式下规则标了 warp 的域名
        # 在 v6 侧静默走原生 (mark 0x3 查 cw3 表无路由 → 落回 main)。
        info "本机无全局 IPv6 地址 → v6 分流跳过 (v4 不受影响)"
    else
        ip -6 route replace default dev "$ifc" table "$TABLE_NAME" 2>/dev/null \
            || warn "v6 表路由添加失败 — v6 将回退原生出口"
    fi
    ip -4 route show table "$TABLE_NAME" 2>/dev/null | grep -q default || { err "v4 表 $TABLE_NAME 无默认路由"; return 1; }
    return 0
}

fw_down_silent() {
    detect_iface && local ifc="$IFACE" || local ifc="warp"
    iptables  -t mangle -D OUTPUT -j CATMI3-OUT 2>/dev/null
    ip6tables -t mangle -D OUTPUT -j CATMI3-OUT 2>/dev/null
    iptables  -t mangle -D PREROUTING -j CATMI3-FWD 2>/dev/null
    ip6tables -t mangle -D PREROUTING -j CATMI3-FWD 2>/dev/null
    iptables  -t mangle -D POSTROUTING -o "$ifc" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    ip6tables -t mangle -D POSTROUTING -o "$ifc" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    iptables  -t mangle -F CATMI3-OUT 2>/dev/null; iptables  -t mangle -X CATMI3-OUT 2>/dev/null
    ip6tables -t mangle -F CATMI3-OUT 2>/dev/null; ip6tables -t mangle -X CATMI3-OUT 2>/dev/null
    iptables  -t mangle -F CATMI3-FWD 2>/dev/null; iptables  -t mangle -X CATMI3-FWD 2>/dev/null
    ip6tables -t mangle -F CATMI3-FWD 2>/dev/null; ip6tables -t mangle -X CATMI3-FWD 2>/dev/null
    iptables  -t nat -D POSTROUTING -m mark --mark "$MARK" -j MASQUERADE 2>/dev/null
    ip6tables -t nat -D POSTROUTING -m mark --mark "$MARK" -j MASQUERADE 2>/dev/null
    ip -4 rule del fwmark "$MARK" table "$TABLE_NAME" 2>/dev/null
    ip -6 rule del fwmark "$MARK" table "$TABLE_NAME" 2>/dev/null
    # catmi 前置规则 (suppress_takeover 动态加的 oif/fwmark/not 系列) 全量清理, 求完全无痕
    local fd f cmd fd_mk
    fd_mk="$MARK"; [[ "$fd_mk" != 0x* ]] && fd_mk="0x$fd_mk"
    iptables  -t mangle -D INPUT -j CONNMARK --set-xmark 0x$IMARK/0x$IMARK 2>/dev/null
    ip6tables -t mangle -D INPUT -j CONNMARK --set-xmark 0x$IMARK/0x$IMARK 2>/dev/null
    for f in 4 6; do
        if [[ "$f" == "6" ]]; then cmd="ip -6"; else cmd="ip -4"; fi
        while read -r p; do
            [[ -n "$p" ]] && $cmd rule del prio "$p" 2>/dev/null
        done < <($cmd rule show | grep -E "fwmark $fd_mk (table|lookup) $TABLE_NAME|fwmark 0xc350 lookup (main|$TABLE_NAME)|fwmark 0x$IMARK(/[0-9a-fxA-F]+)? (table|lookup) main|oif $IFACE (table|lookup) $TABLE_NAME" | grep -oE '^[0-9]+')
        if [[ "$f" == "6" ]]; then
            # 原生 v6 上游地址段的入站保护规则 (from 段 → main) 也一并清理
            local fd_up fd_a fd_seg
            fd_up=$(ip -6 route show default 2>/dev/null | grep -oE 'dev [a-zA-Z0-9_.-]+' | head -1 | awk '{print $2}')
            if [[ -n "$fd_up" && "$fd_up" != "$ifc" ]]; then
                # awk '{print $2}' 会把 'valid_lft forever' 与接口名行也算进来, 产出
                # 'forever::/64' / 'he-ipv6@NONE:::/64' 这种垃圾段 (不会误删, 但很脏)
                for fd_a in $(ip -6 addr show dev "$fd_up" scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1); do
                    fd_seg="$(cut -d: -f1-4 <<<"$fd_a")::/64"
                    while read -r p; do
                        [[ -n "$p" ]] && $cmd rule del prio "$p" 2>/dev/null
                    done < <($cmd rule show | grep -F "from $fd_seg lookup main" | grep -oE '^[0-9]+')
                done
            fi
        fi
    done
    # warp 默认模式部件: bind 保护规则 + native 例外集合
    ip -4 rule del priority 50 2>/dev/null
    ip -6 rule del priority 50 2>/dev/null
    ip -4 route flush table "$TABLE_NAME" 2>/dev/null
    ip -6 route flush table "$TABLE_NAME" 2>/dev/null
    ipset destroy cw3-warp4 2>/dev/null
    ipset destroy cw3-warp6 2>/dev/null
    ipset destroy cw3-native4 2>/dev/null
    ipset destroy cw3-native6 2>/dev/null
    # 只有确认真的拆干净才清除"已应用"标记 —— 它是 status/doctor/dashboard 判断
    # "是否已部署"的唯一依据 (13 处引用)。拆除失败却把标记删掉, 残留规则会立刻**隐形**。
    if iptables -t mangle -S CATMI3-OUT >/dev/null 2>&1 \
       || ip -4 rule show 2>/dev/null | grep -qE "fwmark 0x[0-9a-f]+ (table|lookup) $TABLE_NAME" \
       || ipset_exists cw3-warp4; then
        warn "拆除未彻底 (仍有 catmi 残留规则) — 保留「已应用」标记, 请重试 revoke / apply"
    else
        rm -f "$APPLIED_FLAG"
    fi
}

# forward 模式开关 (§8: 显式用户操作)
cmd_forward() {
    need_root
    local act="${1,,}"
    { [[ "$act" == "on" ]] || [[ "$act" == "off" ]]; } || { err "用法: catmi-warp3 forward on|off"; return 1; }
    acquire_lock || return 1
    init_dirs
    local snap; snap=$(snapshot "forward-$act")
    local newval=$([[ "$act" == "on" ]] && echo 1 || echo 0)
    if [[ "$newval" == "1" ]]; then
        echo "  ⚠ forward 影响的是【转发流量】(穿本机的流量, 非本机出站),"
        echo "    命中规则的转发包会走 WARP。"
        detect_iface || { err "WARP 接口不存在"; return 1; }
        # 直接加 FWD 部件 (apply 已在跑的话 OUT 部分已在)
        FORWARD=1 fw_up "$IFACE" || { err "forward 部署失败"; return 1; }
    else
        FORWARD=0
        # 拆除 FWD 部件 (无论当前配置)
        iptables  -t mangle -D PREROUTING -j CATMI3-FWD 2>/dev/null
        ip6tables -t mangle -D PREROUTING -j CATMI3-FWD 2>/dev/null
        iptables  -t mangle -F CATMI3-FWD 2>/dev/null; iptables  -t mangle -X CATMI3-FWD 2>/dev/null
        ip6tables -t mangle -F CATMI3-FWD 2>/dev/null; ip6tables -t mangle -X CATMI3-FWD 2>/dev/null
        iptables  -t nat -D POSTROUTING -m mark --mark "$MARK" -j MASQUERADE 2>/dev/null
        ip6tables -t nat -D POSTROUTING -m mark --mark "$MARK" -j MASQUERADE 2>/dev/null
        ok "forward 模式已关闭 (PREROUTING/MASQUERADE 已拆除)"
    fi
    # sed 在键不存在时会静默什么都不做 (老版本配置可能没有 FORWARD= 行) ——
    # 原来直接报"已持久化", 实际可能一个字都没写。键不存在就 append。
    if ! grep -q '^FORWARD=' "$MAIN_CONF" 2>/dev/null; then
        echo "FORWARD=$newval" >> "$MAIN_CONF" 2>/dev/null \
            || { err "写入 config 失败 — forward 只在本次会话生效"; return 1; }
    elif ! sed -i "s/^FORWARD=.*/FORWARD=$newval/" "$MAIN_CONF" 2>/dev/null; then
        err "写入 config 失败 — forward 只在本次会话生效"; return 1
    fi
    grep -q "^FORWARD=$newval" "$MAIN_CONF" 2>/dev/null || { err "config 校验失败 (FORWARD 未写入)"; return 1; }
    FORWARD="$newval"
    ok "forward 模式 = $act (已持久化到 config/main.conf)"
    log_op "forward" "$act"
    [[ -n "$snap" ]]
}

# 动态压制外部全接管 + 前置路由规则:
# fscarmen warp-go (重)启时会注入 "not fwmark 0xc350 lookup 50000" (无标流量→其 WARP 表)
# 和一组 "from <源> lookup main" 保护规则, 且优先级每次动态变化 (实测 32765/39/36/33/31)。
# 内核 WG 的 PostUp 也会注入 from→main。catmi 需要把三类规则压在它们之前:
#   A: oif $IFACE → cw3        (bind WARP 接口 = 显式要求走 WARP; wg-quick/warp-go 共用)
#   B: fwmark $MARK → cw3      (链打标流量; 必须先于 from→main, 否则 reroute 后被 from 规则送回)
#   C: not fwmark 0xc350 → main (未打标流量归原生; 0xc350 是 fscarmen 自用防环 mark, 不受影响)
suppress_takeover() {
    local f cmd need minp fk p mk
    # MARK 可能是 "3" 或 "0x3" (内核 rule show 一律显示 0x 前缀) — 规范化后用于 grep
    mk="$MARK"; [[ "$mk" != 0x* ]] && mk="0x$mk"
    for f in 4 6; do
        if [[ "$f" == "6" ]]; then cmd="ip -6"; else cmd="ip -4"; fi
        # 按内容清理本族全部旧 catmi 前置 (防动态优先级残留堆积)
        while read -r p; do
            [[ -n "$p" ]] && $cmd rule del prio "$p" 2>/dev/null
        done < <($cmd rule show | grep -E "fwmark $mk (table|lookup) $TABLE_NAME|fwmark 0xc350 lookup (main|$TABLE_NAME)|oif $IFACE (table|lookup) $TABLE_NAME" | grep -oE '^[0-9]+')
        # 需要压在谁之前: fscarmen 接管规则 与 from→main 保护规则, 取最小优先级
        need=""
        fk=$($cmd rule show | grep 'fwmark 0xc350 lookup 50000' | grep -oE '^[0-9]+' | head -1)
        [[ -n "$fk" ]] && need="$fk"
        # ⚠ 必须排除**本模块自己上一轮加的原生 v6 上游段规则** (from <seg>/64 lookup main)。
        # 它匹配 'lookup main' 且不含 fwmark/oif, 会被算进 minp → 下一次 need 再减 4 →
        # 每跑一次 apply 就整体下移 4 位, **无下界**。实测连续 apply: 32707→32703→32699,
        # 约 8100 次之后会撞上 50:(入站源保护) / 17:(入站回程) 规则, 破坏入站零影响。
        local _excl=""
        if [[ "$f" == "6" ]]; then
            local _up _a _seg
            _up=$(ip -6 route show default 2>/dev/null | grep -oE 'dev [a-zA-Z0-9_.-]+' | head -1 | awk '{print $2}')
            if [[ -n "$_up" && "$_up" != "$IFACE" ]]; then
                while read -r _a; do
                    [[ -n "$_a" ]] || continue
                    _seg="$(cut -d: -f1-4 <<<"$_a")::/64"
                    _excl="${_excl:+$_excl|}$_seg"
                done < <(ip -6 addr show dev "$_up" scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | sort -u)
            fi
        fi
        if [[ -n "$_excl" ]]; then
            minp=$($cmd rule show | grep 'lookup main' | grep -vE 'fwmark|oif' \
                | grep -vE "from ($_excl) lookup main" | grep -oE '^[0-9]+' | sort -n | head -1)
        else
            minp=$($cmd rule show | grep 'lookup main' | grep -vE 'fwmark|oif' | grep -oE '^[0-9]+' | sort -n | head -1)
        fi
        if [[ -n "$minp" && ( -z "$need" || "$minp" -lt "$need" ) ]]; then need="$minp"; fi
        # 无人需要压制时仍保留 oif 规则 (bind WARP 接口显式走 cw3)
        if [[ -z "$need" ]]; then
            [[ -n "$IFACE" ]] && $cmd rule add prio 27 oif "$IFACE" table "$TABLE_NAME" 2>/dev/null
            continue
        fi
        # C 规则按 v6 默认方向参数化:
        #   V6=warp: 未标 → cw3 (v6 默认走 WARP; 关键: 让决策期就选 warp 接口的合法源地址,
        #            否则 main 选 he 源 → reroute 后源不变 → CF 拒绝非账号源 → v6 超时)
        #   其余:    未标 → main (原生)
        local c_dst="main"
        [[ "$f" == "6" && "$DEFAULT_OUTBOUND_V6" == "warp" ]] && c_dst="$TABLE_NAME"
        # v6: 原生 v6 上游接口 (he-ipv6 等) 的全局地址段 → main, 优先级压在前置 (need-3) 之前。
        # 入站服务回包源是这些地址, 若被 C 规则抓进 WARP, CF 拒收非账号源 → 入站死。
        # 必须在决策期就命中原口; 老版本位置一并清理。
        if [[ "$f" == "6" ]]; then
            local upseg a6 seg6
            upseg=$(ip -6 route show default 2>/dev/null | grep -oE 'dev [a-zA-Z0-9_.-]+' | head -1 | awk '{print $2}')
            if [[ -n "$upseg" && "$upseg" != "$IFACE" ]]; then
                for a6 in $(ip -6 addr show dev "$upseg" scope global 2>/dev/null | awk '{print $2}' | cut -d/ -f1); do
                    seg6="$(cut -d: -f1-4 <<<"$a6")::/64"
                    while read -r p; do
                        [[ -n "$p" ]] && $cmd rule del prio "$p" 2>/dev/null
                    done < <($cmd rule show | grep "from $seg6 lookup main" | grep -oE '^[0-9]+')
                    $cmd rule add prio $((need - 4)) from "$seg6" lookup main 2>/dev/null \
                        && ok "入站保护 (v6): from $seg6 → main (prio $((need-4)), 回包走原口)"
                done
            fi
        fi
        # 入站回程规则 (v4+v6): 回包 mark 0x4 → main — UDP 通配 socket 决策期源未定,
        # from 段规则抓不到, 必须用 mark 兜底; 幂等
        $cmd rule show | grep -qE "fwmark 0x$IMARK (table|lookup) main" \
            || { $cmd rule add prio 17 fwmark 0x$IMARK/0x$IMARK lookup main 2>/dev/null \
            && ok "入站回程 (fam$f): fwmark 0x$IMARK → main @ prio 17"; }
        # 注: 无需额外加 IMARK→main 规则 —— 上面的 prio 17 (fwmark 0x$IMARK → main)
        # 本来就排在「未标 → cw3」兜底之前。这里早期版本曾多加一条 need-2 的规则,
        # 会与「fwmark 0x$MARK → cw3」撞同一优先级导致顺序不确定, 已移除。
        $cmd rule add prio $((need - 3)) oif "$IFACE" table "$TABLE_NAME" 2>/dev/null \
            && $cmd rule add prio $((need - 2)) fwmark "$MARK" table "$TABLE_NAME" 2>/dev/null \
            && $cmd rule add prio $((need - 1)) not fwmark 0xc350 lookup "$c_dst" 2>/dev/null \
            && ok "前置规则 (fam$f): oif/fwmark→cw3 + 未标→$c_dst @ prio $((need-3))~$((need-1)) (< $need)"
    done
}

# Netflix 解锁检测 (title 法, 借鉴 fscarmen unlock_warp; 只读) → "full:US"|"orig:US"|""
nf_check() { # <curl 附加参数>  full=完整解锁(非自制可看) orig=仅原创
    local body
    body=$( { curl $1 -ks -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -SsL --max-time 10 \
                "https://www.netflix.com/title/81280792" 2>/dev/null; \
              curl $1 -ks -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -SsL --max-time 10 \
                "https://www.netflix.com/title/70143836" 2>/dev/null; } | \
        awk 'NR==1{u=1} /og:video/{v=1}
             { if(!r && match($0,/"requestCountry":\{"supportedLocales":\[[^]]+\],"id":"[^"]+"/)){
                 s=substr($0,RSTART,RLENGTH); sub(/.*"id":"*/,"",s); sub(/".*/,"",s); r=s } }
             END { if(!u || r=="") print "error"; else print (v?"full":"orig") ":" r }')
    [[ "$body" == "error" || -z "$body" ]] && return 1
    echo "$body"
}

nf_show() { # <方向名> <curl 附加参数>
    local name="$1" r st rg
    printf '  [%s] ' "$name"
    if r=$(nf_check "$2"); then
        st="${r%%:*}"; rg="${r##*:}"
        if [[ "$st" == "full" ]]; then
            ok "完整解锁 ($rg) — 全部内容可看"
        else
            warn "仅原创解锁 ($rg) — 非自制内容不可看"
        fi
    else
        warn "不可用 (无响应或被风控)"
    fi
}

# [A] 流媒体解锁检测 (只读, 不改任何东西)
cmd_stream() {
    echo "── 流媒体解锁检测 (Netflix, 真实出口实测) ──"
    local pdev; pdev=$(ip -4 route show default 2>/dev/null | grep -oE 'dev [a-zA-Z0-9_.-]+' | head -1 | awk '{print $2}')
    nf_show "Native 出口 (${pdev:-eth0})" "-4 ${pdev:+--interface $pdev}"
    if detect_iface >/dev/null 2>&1; then
        nf_show "WARP 出口 ($IFACE)" "-4 --interface $IFACE"
    else
        info "  [WARP 出口]  WARP 未运行, 跳过"
    fi
    echo ""
    echo "  full = 该地区 Netflix 完整解锁; orig = 只能看 Netflix 自制剧。"
    echo "  说明: 上面两行是**分别绑 eth0(原生) 与 warp(WARP) 实测** ——"
    echo "        看的是两个方向各自能不能解锁, 不代表流量当前走哪边。"
    echo "        加规则前先看哪边更好; 两边相同则加规则不会改善解锁。"
    echo "  (出口 IP 变化后结果可能变化 — 用 newip 换 IP 后可复测)"
}

# [B] WARP Endpoint 优选 (改动: 凭据文件的 Endpoint + 重启 WARP; 不动路由/分流/账号)
cmd_endpoint_opt() {
    need_root; init_dirs   # 扫描/测速都是只读, 不占锁; 真正的互斥段在下面"改之前先备份"处
    parse_creds >/dev/null 2>&1 || { err "未找到 WARP 凭据"; return 1; }
    # 只改 parse_creds **实际选中**的那个凭据文件。原来这里另有一套搜索顺序
    # (还优先 /opt/warp-go/warp.conf), 与 parse_creds 不一致: 可能改了 A 文件而 WARP 读的是 B,
    # 打印"已写入"却毫无效果; 而且会动 fscarmen/wgcf 自己管理的配置 (违反文件头红线)。
    local src="$CRED_SRC"
    [[ -n "$src" && -s "$src" ]] || { err "未找到 WARP 凭据文件 (Endpoint 无处可改)"; return 1; }
    case "$src" in
        "$CATMI_CRED_FILE"|/etc/wireguard/warp.conf) : ;;
        *) err "WARP 由他方工具管理 ($src) — 按红线**不改他方配置**"
           err "请用该工具自己的方式优选 Endpoint; 或改用本模块管理的凭据: catmi-warp3 install --force-register"
           return 1 ;;
    esac
    local curep; curep=$(sed -n 's/^Endpoint[ ]*=[ ]*//p' "$src" | head -1 | tr -d '\r')
    echo "── WARP Endpoint 优选 ──"
    echo "  扫描 CF WARP 入口段, 测 TCP 握手延迟, 选最快者替换。"
    echo "  改动: 仅 $src 的 Endpoint + 重启 WARP; 不动路由/分流/账号。"
    echo "  当前 Endpoint: ${curep:-未知}"
    echo ""
    # 采样: WARP 入口是 UDP(WireGuard), TCP 探测端口不可行 → 以 ICMP 延迟近似排序
    # (同段入口 UDP 服务通常全开; 真实会话质量以重启后的 handshake/keepalive 为准)
    local seg i ip t
    local -a rows=()
    echo "  扫描: 4 个常用段 × 8 个候选 (ICMP 延迟, 32 个) ..."
    for seg in 162.159.192 162.159.193 188.114.96 188.114.97; do
        for i in 1 17 33 65 97 129 193 225; do
            ip="$seg.$i"
            t=$(ping -W1 -c1 "$ip" 2>/dev/null | grep -oE 'time=[0-9.]+' | head -1 | cut -d= -f2)
            [[ -n "$t" ]] && rows+=("$t $ip")
        done
    done
    if (( ${#rows[@]} == 0 )); then
        warn "无响应候选 — 保持现有 Endpoint"; return 1
    fi
    echo ""
    echo "  最快 5 个 (ICMP):"
    printf '%s\n' "${rows[@]}" | sort -n | head -5 | awk '{printf "    %-18s %s ms\n", $2, $1}'
    local best best_t
    best_t=$(printf '%s\n' "${rows[@]}" | sort -n | head -1 | awk '{print $1}')
    local bip; bip=$(printf '%s\n' "${rows[@]}" | sort -n | head -1 | awk '{print $2}')
    local curport="${curep##*:}"; [[ "$curport" =~ ^[0-9]+$ ]] || curport=2408
    best="$bip:$curport"
    echo ""
    echo "  最优: $best (ICMP ${best_t}ms)  当前: ${curep:-未知}"
    local curep_ip; curep_ip=$(timeout 5 dig +short "${curep%%:*}" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    [[ -z "$curep_ip" ]] && curep_ip="${curep%%:*}"
    if [[ "$bip" == "$curep_ip" ]]; then
        info "当前入口 (${curep%%:*} → $curep_ip) 已是最快, 无需修改"; return 0
    fi
    confirm_or_abort "应用 $best 并重启 WARP?" 0 || { echo "  已保持现有 Endpoint" >&2; return 0; }
    acquire_lock || return 1
    # 改之前先备份 —— 原来直接 sed -i, 改坏了没有任何回滚点
    local bak="$BACKUPS/endpoint-$(date +%Y%m%d-%H%M%S).conf"
    if ! cp -a "$src" "$bak" 2>/dev/null || [[ ! -s "$bak" ]]; then
        err "备份 $src 失败 — 中止 (没有回滚点就不改配置)"; return 1
    fi
    if ! sed -i "s|^Endpoint[ ]*=.*|Endpoint = $best|" "$src" 2>/dev/null; then
        err "写入 Endpoint 失败 (备份在 $bak)"; return 1
    fi
    # sed 无匹配也返回 0 —— 必须回读确认, 否则会打印"已写入"而文件根本没变 (假成功闭环)
    local wrote; wrote=$(sed -n 's/^Endpoint[ ]*=[ ]*//p' "$src" | head -1 | tr -d '\r')
    if [[ "$wrote" != "$best" ]]; then
        cp -a "$bak" "$src" 2>/dev/null
        err "写入校验失败: 文件里是 '${wrote:-无}' 而非 '$best' — 已还原 (备份 $bak)"
        return 1
    fi
    ok "Endpoint 已写入: $best (备份: $bak) → 重启 WARP 生效"
    FORCE_STOP=1 stop_warp
    if ! start_warp; then
        # 原来这里失败**没有任何提示**, 且函数最后一条命令是 log_op(必成功) ⇒ 整体退出 0;
        # 而 dual 模式下 cw3 表默认 dev warp 已无可用路由 → 用户以为成功, 实际整机 WARP 方向断网。
        err "新 Endpoint 拉不起 WARP — 正在还原旧配置"
        cp -a "$bak" "$src" 2>/dev/null
        FORCE_STOP=1 stop_warp; start_warp >/dev/null 2>&1 \
            && warn "已还原旧 Endpoint 并重启 WARP (期间出口短暂中断)" \
            || err "还原后 WARP 仍未起来 — 详查: catmi-warp3 doctor / journalctl -u wg-quick@warp"
        return 1
    fi
    health_check >/dev/null 2>&1 && ok "健康检查通过" || warn "健康检查异常 (分流不受影响, 可用 doctor 复查)"
    suppress_takeover
    local eip; eip=$(timeout 8 curl -4 -s --interface "$(detect_iface >/dev/null 2>&1 && echo "$IFACE" || echo warp)" https://ifconfig.me 2>/dev/null)
    [[ -n "$eip" ]] && info "WARP 出口: $eip"
    log_op "endpoint" "$curep→$best"
    return 0
}

# [C] 更换 WARP 出口 IP (重启会话; 分流规则/模式/网站配置全部不变; 需确认)
cmd_newip() {
    need_root; init_dirs   # 探测/打印都是只读; 互斥段从 snapshot 开始
    detect_iface || { err "WARP 未运行"; return 1; }
    local old; old=$(timeout 8 curl -4 -s --interface "$IFACE" https://ifconfig.me 2>/dev/null)
    echo "── 更换 WARP 出口 IP ──"
    echo "  当前 WARP 出口: ${old:-未知}"
    echo "  影响:"
    echo "    - WARP 会话重连, 出口 IP 将变化 (CF 随机分配, 概率抽奖)"
    echo "    - 走 WARP 的分流连接会断开重连; native 方向流量不受影响"
    echo "    - 分流规则 / 出口模式 / 网站配置 全部不变"
    echo "    - 注册类网站建议走 Native (固定原生 IP); WARP 出口是共享 NAT, 风控严"
    confirm_or_abort "更换 WARP 出口 IP (会话重连)?" 0 || return 1
    acquire_lock || return 1
    local snap; snap=$(snapshot "newip")
    FORCE_STOP=1 stop_warp; start_warp || { err "WARP 重启失败"; return 1; }
    sleep 2
    suppress_takeover   # 重启会让外部脚本重新注入接管规则 → 重申压制
    # 外部脚本重启时可能清空 cw3 表 → 补回 (v4 无条件; v6 仅在补栈模式且接口有 v6 时)
    ip -4 route replace default dev "$IFACE" table "$TABLE_NAME" 2>/dev/null \
        && info "cw3 v4 表路由已确保"
    if [[ "$DEFAULT_OUTBOUND_V6" == "warp" ]] && ip -6 addr show dev "$IFACE" 2>/dev/null | grep -q inet6; then
        ip -6 route replace default dev "$IFACE" table "$TABLE_NAME" 2>/dev/null \
            && info "cw3 v6 表路由已确保"
    fi
    local new; new=$(timeout 8 curl -4 -s --interface "$IFACE" https://ifconfig.me 2>/dev/null)
    if [[ -n "$new" && "$new" != "$old" ]]; then
        ok "新出口 IP: $new (原: ${old:-无})"
    elif [[ -n "$new" ]]; then
        warn "出口未变化 ($new) — 可再执行一次"
    else
        err "获取新出口失败 (WARP 可能未连上) — 可用 doctor/start 复查"
        return 1
    fi
    log_op "newip" "${old:-?}→${new:-fail}"
    [[ -n "$snap" ]]
}

# 栈模式名: 当前 WARP 接管哪个协议栈 (面板/菜单/doctor 共用)
stack_mode() { # → "双栈" | "仅 IPv4" | "仅 IPv6" | "无 (全 Native)"
    if [[ "$DEFAULT_OUTBOUND_V4" == "warp" && "$DEFAULT_OUTBOUND_V6" == "warp" ]]; then echo "双栈"
    elif [[ "$DEFAULT_OUTBOUND_V4" == "warp" ]]; then echo "仅 IPv4"
    elif [[ "$DEFAULT_OUTBOUND_V6" == "warp" ]]; then echo "仅 IPv6"
    else echo "无 (全 Native)"; fi
}

# 默认出口模式 (三模式): default v4|v6|dual|native  (warp=旧兼容, 等价 dual)
cmd_default() {
    need_root
    local want="${1,,}"
    if [[ -z "$want" ]]; then
        init_dirs   # 读 config (旧 DEFAULT_OUTBOUND 键映射为双栈)
        echo "默认出口: IPv4=$( [[ "$DEFAULT_OUTBOUND_V4" == "warp" ]] && echo WARP || echo Native )  IPv6=$( [[ "$DEFAULT_OUTBOUND_V6" == "warp" ]] && echo WARP || echo Native )"
        echo "  当前栈模式: $(stack_mode)"
        echo "  (用法: catmi-warp3 default v4|v6|dual|native — 旧写法 warp 等价 dual)"
        return 0
    fi
    local nv4 nv6
    case "$want" in
        v4)          nv4="warp";   nv6="native" ;;
        v6)          nv4="native"; nv6="warp" ;;
        dual|warp)   nv4="warp";   nv6="warp";  want="dual" ;;
        native|off)  nv4="native"; nv6="native"; want="native" ;;
        *) err "用法: catmi-warp3 default v4|v6|dual|native"; return 1 ;;
    esac
    init_dirs; migrate_v2
    # 「模式已经是这个」不等于「已经生效」: revoke 之后 main.conf 里仍写着 dual,
    # 但分流已经拆掉 (cw3 表空、ipset 没了)。原来这里直接 return 0, 用户以为恢复了
    # 其实什么都没发生 (实测 CCS: revoke 后 `default dual` 空转, doctor 直接 FAIL=4)。
    if [[ "$nv4" == "$DEFAULT_OUTBOUND_V4" && "$nv6" == "$DEFAULT_OUTBOUND_V6" ]]; then
        if [[ -f "$APPLIED_FLAG" ]]; then
            info "默认出口已是 $(stack_mode), 无需切换"; return 0
        fi
        info "默认出口模式不变 ($(stack_mode)), 但分流未生效 — 重新应用"
    fi
    local risk="影响:"
    if [[ "$nv4" != "$DEFAULT_OUTBOUND_V4" ]]; then
        if [[ "$nv4" == "warp" ]]; then
            risk="$risk|  [IPv4] 未被其他程序明确指定的普通 v4 出站 → 默认 WARP"
        else
            risk="$risk|  [IPv4] 普通 v4 出站恢复原生出口; warp 规则域名仍走 WARP"
        fi
    fi
    if [[ "$nv6" != "$DEFAULT_OUTBOUND_V6" ]]; then
        if [[ "$nv6" == "warp" ]]; then
            risk="$risk|  [IPv6] 未被其他程序明确指定的普通 v6 出站 → 默认 WARP"
            risk="$risk|  [IPv6] 补栈: 若机器没有 v6 上游, 将通过 WARP 获得 v6 出口"
            risk="$risk|  [IPv6] v6 入站 (如 he-ipv6) 回包走原路, 不受影响 (conntrack 保护)"
        else
            risk="$risk|  [IPv6] 普通 v6 出站恢复原生出口; warp 规则域名的 v6 仍走 WARP"
        fi
    fi
    risk="$risk|不会影响:|  - Xray/Mihomo 明确 outbound (已有 fwmark 永不覆盖, 两栈同保)|  - bind 物理接口的出站 (oif→main 保护, 两栈同保)|  - SSH/Nginx/Hysteria2 等入站 (PREROUTING 默认 OFF)|  - main 默认路由 (绝不替换, 两栈红线)|  - Forward 独立 (默认 OFF)|  - WARP 本体/账号/接口 (不卸载不重注册)"
    echo "⚠ 切换默认出口: $(stack_mode) → $want"
    printf '%s\n' "$risk" | sed 's/^/    /'
    # 确认放在**加锁之前** —— 原来先 acquire_lock 再等 /dev/tty: 无人按键时一直占着 flock,
    # 后续任何操作都只报"另一个实例正在执行变更操作"。非 tty (面板/CI) 时按上游要求继续执行。
    confirm_or_abort "切换默认出口 $(stack_mode) → $want。" 1 || return 1
    acquire_lock || return 1
    local snap; snap=$(snapshot "default-$want")
    local ov4="$DEFAULT_OUTBOUND_V4" ov6="$DEFAULT_OUTBOUND_V6"
    _setcfg_v() { # <key> <val> — 替换或追加 (首次无键时兜底, 防配置与部署漂移)
        if grep -q "^$1=" "$MAIN_CONF" 2>/dev/null; then
            sed -i "s/^$1=.*/$1=$2/" "$MAIN_CONF" || return 1
        else
            echo "$1=$2" >> "$MAIN_CONF"
        fi
    }
    # 旧版单键已由两键取代 — 移除防漂移 (旧脚本回滚时用代码默认 native, 安全)
    sed -i '/^DEFAULT_OUTBOUND=/d' "$MAIN_CONF" 2>/dev/null
    _setcfg_v DEFAULT_OUTBOUND_V4 "$nv4" && _setcfg_v DEFAULT_OUTBOUND_V6 "$nv6" \
        || { err "写入 config 失败"; return 1; }
    DEFAULT_OUTBOUND_V4="$nv4"; DEFAULT_OUTBOUND_V6="$nv6"
    if ASSUME_YES=1 apply; then
        ok "默认出口 = $(stack_mode) (已部署)"
        local e4 e6
        e4=$(timeout 8 curl -s -4 https://ifconfig.me 2>/dev/null)
        e6=$(timeout 8 curl -6 -s https://ifconfig.me 2>/dev/null)
        [[ -n "$e4" ]] && info "v4 普通流量出口: $e4"
        [[ -n "$e6" ]] && info "v6 普通流量出口: $e6"
        log_op "default" "$want"
    else
        err "新配置应用失败 — 配置已回滚"
        _setcfg_v DEFAULT_OUTBOUND_V4 "$ov4"; _setcfg_v DEFAULT_OUTBOUND_V6 "$ov6"
        DEFAULT_OUTBOUND_V4="$ov4"; DEFAULT_OUTBOUND_V6="$ov6"
        # 只回滚**配置文件** ≠ 回到原状: apply 失败时走的是 rollback_undo → teardown_all,
        # 系统里的分流规则**已经被全部拆掉**。此时配置说 dual 而实际全部走原生 ——
        # 光打印"已回滚配置"会让用户以为原模式还在跑。
        # 主动把原模式重新部署一次, 让系统状态与配置真正一致 (= 回到上一个好状态)。
        warn "分流已被拆除, 正在恢复原模式 ($(stack_mode))..."
        if ASSUME_YES=1 apply >/dev/null 2>&1; then
            ok "已恢复到原模式: $(stack_mode) (分流正常)"
        else
            err "恢复原模式也失败了 —— 分流当前**未生效**, 全部走原生"
            err "排查: catmi-warp3 doctor        修好后: catmi-warp3 apply --yes"
        fi
        return 1
    fi
    [[ -n "$snap" ]]
}

# ============================================================
# apply / revoke (原子化: snapshot → 变更 → validate → 失败 rollback)# ============================================================
# apply / revoke (原子化: snapshot → 变更 → validate → 失败 rollback)
# ============================================================
apply() {
    need_root
    local assume_yes="${ASSUME_YES:-0}"
    acquire_lock || return 1
    init_dirs; migrate_v2
    detect_iface || { err "未检测到 WARP 接口 (先: catmi-warp install)"; return 1; }
    check_not_global || return 1
    ensure_deps || return 1
    local snap; snap=$(snapshot "apply")
    log_op "apply" "start (iface=$IFACE, forward=$FORWARD)"

    # 步骤 1: DNS 决策与接管
    local mode points decision
    mode=$(detect_dns53)
    resolv_points_local && points=1 || points=0
    decision=$(dns_decision "$mode" "$points")
    case "$decision" in
        reuse)  ok "DNS: 纯复用现有 dnsmasq (零改动)" ;;
        takeover)
            if [[ "$mode" == "resolved" || "$mode" == "dnsmasq" ]]; then
                if [[ "$assume_yes" != "1" ]]; then
                    local yn
                    printf "  需将 /etc/resolv.conf 指向 127.0.0.1 (dnsmasq 转发上游, ipset 才会填充)\n  原件将备份到 %s/resolv.orig。继续? (y/N): " "$BACKUPS"
                    read -r yn </dev/tty 2>/dev/null || yn=""
                    case "${yn,,}" in y|yes) : ;; *) warn "取消解析切换 — 分流不会生效"; return 1 ;; esac
                fi
            fi
            ;;
        reject)
            err ":53 被非 dnsmasq/resolved 的服务占用 ($mode) — 拒绝接管"
            err "排查: ss -lnup | grep ':53 ' — 确认后停用或调整, 再 apply"
            return 1
            ;;
    esac

    # 步骤 2: dnsmasq 部署
    if ! run_step "dnsmasq 部署与校验" dns_deploy; then
        rollback_undo; err "apply 中止于: $STEP_FAIL (已回滚)"; log_op "apply" "FAILED@dns"; return 1
    fi

    # 步骤 3: resolv 管理 (无条件 — takeover 内部按现状分流:
    #   已指向+无state=补录 / 已指向+state=确认 / 未指向=切换备份;
    # reuse(纯复用)也必须建立管理标记, 否则 revoke 无从解除)
    if ! run_step "resolv.conf 管理 (state 记录)" dns_takeover; then
        rollback_undo; err "apply 中止于: $STEP_FAIL (已回滚)"; log_op "apply" "FAILED@resolv"; return 1
    fi

    # 步骤 4: 防火墙与策略路由
    # 链式上游自动豁免: 在这里打印 —— 步骤内的 info 会被 run_step 吞掉, 看不到就白做了
    if [[ "${AUTO_CHAIN_EXEMPT:-1}" == "1" ]]; then
        local _ce; _ce=$(chain_exempt_ips)
        if [[ -n "$_ce" ]]; then
            info "自动豁免链式上游 (永不进 WARP): $_ce"
        else
            info "链式上游扫描: 未发现字面 IP 形式的出站上游 (代理内核配置里没有)"
        fi
    fi
    if ! run_step "ipset/iptables/策略路由部署" fw_up "$IFACE"; then
        rollback_undo; err "apply 中止于: $STEP_FAIL (已回滚)"; log_op "apply" "FAILED@fw"; return 1
    fi

    # 步骤 5: 规则预热
    if ! run_step "规则域名解析预热" warm_domains; then
        warn "预热失败(非致命) — 稍后 keepalive 会补"
    fi

    touch "$APPLIED_FLAG"
    ok "apply 完成 — 分流已生效 (接口: $IFACE, forward=$FORWARD)"
    log_op "apply" "OK"
    doctor_brief
}

revoke() {
    need_root
    acquire_lock || return 1
    local snap; snap=$(snapshot "revoke")
    info "拆除分流..."
    teardown_all
    ok "revoke 完成 (规则文件 $RULES 保留)"
    log_op "revoke" "OK"
}

# ============================================================
# 状态 / 测试 / 自检 (§11/§12/§13/§14)
# ============================================================
# egress: 经 WARP 接口的出口 (分族)
iface_egress() { # iface_egress <4|6> → echo "IP warp=on loc=xx" | 失败 echo ""
    detect_iface || return 1
    local out
    out=$(timeout 8 curl -s -$1 --interface "$IFACE" https://cloudflare.com/cdn-cgi/trace 2>/dev/null)
    grep -E '^(ip|warp|loc)=' <<<"$out" | tr '\n' ' '
    [[ -n "$out" ]]
}

# 分族探测: echo "OK|unavailable|fallback" + 详情
family_probe() { # family_probe <4|6>
    if [[ "$1" == "6" && "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" == "1" ]]; then
        # 内核全局默认禁 v6, 但 per-interface 可例外 (he-ipv6 隧道 / 内核 WG 的 PostUp 启用)。
        # WARP 接口已被单独启用 v6 且 cw3 表有路由 → WARP 的 v6 通道真实可用:
        detect_iface || { echo "unavailable (无 WARP 接口)"; return 0; }
        if ip -6 addr show "$IFACE" 2>/dev/null | grep -qE 'inet6 (2606:4700|2a09)' \
            && ip -6 route show table "$TABLE_NAME" 2>/dev/null | grep -q default; then
            echo "OK"; return 0
        fi
        # 无 WARP v6 通道时, 如实区分原生上游 (he-ipv6 等):
        local vdv
        vdv=$(ip -6 route show default 2>/dev/null | grep -oE 'dev [a-zA-Z0-9_.-]+' | head -1 | awk '{print $2}')
        if [[ -n "$vdv" ]]; then
            echo "Native($vdv) — WARP 的 v6 通道未通, v6 出站走原生"; return 0
        fi
        echo "unavailable (内核 IPv6 已禁用, 且无原生 v6 上游) → v6 出站不可用"; return 0
    fi
    detect_iface || { echo "unavailable (无 WARP 接口)"; return 0; }
    local pat="inet "; [[ "$1" == "6" ]] && pat="inet6 "
    if ! ip "-$1" addr show "$IFACE" 2>/dev/null | grep -qE "$pat"; then
        echo "unavailable (接口无 v$1 地址) → fallback to native"; return 0
    fi
    if [[ "$1" == "4" ]]; then
        ip -4 route show table "$TABLE_NAME" 2>/dev/null | grep -q default \
            && echo "OK" || echo "unavailable (表 $TABLE_NAME 无路由) → fallback to native"
    else
        ip -6 route show table "$TABLE_NAME" 2>/dev/null | grep -q default \
            && echo "OK" || echo "unavailable (表无路由) → fallback to native"
    fi
}

cmd_status() {
    init_dirs; migrate_v2
    echo "========== catmi-warp =========="
    echo "Version        : v$VERSION"
    echo ""
    echo "WARP"
    if detect_iface; then
        echo "  Source       : $(warp_source)"
        for s in wg-quick@warp warp-go warp-svc; do
            systemctl is-active "$s" >/dev/null 2>&1 && { echo "  Service      : running ($s)"; break; }
        done
        systemctl is-active wg-quick@warp >/dev/null 2>&1 || systemctl is-active warp-go >/dev/null 2>&1 || echo "  Service      : unknown (接口在, 服务未知)"
        echo "  Interface    : $IFACE"
        # 握手
        local hs
        hs=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')
        if [[ -n "$hs" && "$hs" != "0" ]]; then
            echo "  Handshake    : $(( $(date +%s) - hs ))s ago"
        else
            echo "  Handshake    : n/a (用户态接口, 用 egress 判断)"
        fi
        # 分族
        local p4 p6
        p4=$(family_probe 4); p6=$(family_probe 6)
        echo "  IPv4         : $p4"
        [[ "$p4" == OK* ]] && echo "                 (egress $(timeout 8 curl -s -4 --interface "$IFACE" https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -oE 'ip=[^ ]+' | head -1))"
        echo "  IPv6         : $p6"
        parse_creds >/dev/null 2>&1 && echo "  Endpoint     : $ENDPOINT"
    else
        echo "  Source       : 未安装"
        echo "  Service      : stopped"
        echo "  Interface    : 无 (catmi-warp install)"
    fi
    echo ""
    echo "Routing"
    # 当前出口模式 —— 之前只有 `default` 命令能看到, status 里没有。
    # 不给这个值, 小白看到 "WARP: 3" 会以为有 3 个网站单独走 WARP,
    # 而在双栈模式下无标流量本来就全走 WARP, 那 3 条其实是空操作。
    local _v4s _v6s
    [[ "$DEFAULT_OUTBOUND_V4" == "warp" ]] && _v4s=WARP || _v4s=Native
    [[ "$DEFAULT_OUTBOUND_V6" == "warp" ]] && _v6s=WARP || _v6s=Native
    echo "  Stack mode   : $(stack_mode)   (v4→$_v4s / v6→$_v6s)"
    local def4
    def4=$(ip -4 route show default 2>/dev/null | head -1)
    echo "  Native       : main ($(grep -oE 'dev [a-zA-Z0-9_.-]+' <<<"$def4" | awk '{print $2}'))"
    echo "  WARP table   : $TABLE_NAME ($TABLE_ID)"
    ip -4 rule show 2>/dev/null | grep -qE "fwmark 0x$MARK (table|lookup) $TABLE_NAME" \
        && echo "  IPv4 Policy  : OK (fwmark 0x$MARK → $TABLE_NAME)" \
        || echo "  IPv4 Policy  : 未部署"
    # 不能用 all.disable_ipv6 判"内核禁 v6" —— 那只是新接口的默认值, per-interface 可例外。
    # 本机实测 all=1 但 v6 策略路由**确实已部署**, 旧写法报 n/a 与同屏 "IPv6: OK" 自相矛盾。
    ip -6 rule show 2>/dev/null | grep -qE "fwmark 0x$MARK (table|lookup) $TABLE_NAME" \
        && echo "  IPv6 Policy  : OK" || echo "  IPv6 Policy  : 未部署"
    if grep -qE 'dev (warp|CloudflareWARP|WARP|wgcf)\b' <<<"$def4"; then
        echo "  Main default : ⚠ 已被 WARP 接管 (global 模式!)"
    else
        echo "  Main default : 未被替换 ✓"
    fi
    echo ""
    echo "DNS"
    local mode; mode=$(detect_dns53)
    echo "  Mode         : $mode"
    systemctl is-active dnsmasq >/dev/null 2>&1 && echo "  dnsmasq      : running" || echo "  dnsmasq      : not running"
    if resolv_points_local; then
        if [[ -s "$RESOLV_STATE" ]]; then
            # state 里 NOTE 可能写着 premanaged (接管前就指向 127.0.0.1) ——
            # 那种情况不能宣称"本模块所改", dns_takeover() 自己也打印"非本模块所改"
            if grep -q '^NOTE=premanaged' "$RESOLV_STATE" 2>/dev/null; then
                echo "  resolv.conf  : 127.0.0.1 (接管前已指向本地 DNS, 本模块未改)"
            else
                echo "  resolv.conf  : 127.0.0.1 (managed by catmi-warp)"
            fi
        else
            echo "  resolv.conf  : 127.0.0.1 (非本模块所改)"
        fi
    else
        [[ -s "$RESOLV_STATE" ]] && echo "  resolv.conf  : ⚠ 漂移! state 记录在管但未指向 127.0.0.1 (re-apply 修复)" \
            || echo "  resolv.conf  : $(grep -m1 nameserver "$RESOLV" 2>/dev/null | awk '{print $2}')"
    fi
    local rw; rw=$(detect_dns_rewriters)
    [[ -n "$rw" ]] && echo "  重写风险     : $rw (可能改动 resolv.conf)"
    echo ""
    echo "Rules"
    local _dis=0 _d _a _e _
    while IFS='|' read -r _d _a _e _; do
        [[ -n "$_d" && "$_d" != \#* && "$_e" != "1" ]] && _dis=$((_dis+1))
    done < <(rule_list)
    echo "  Total        : $(rule_list | wc -l)  (含停用)"
    echo "  WARP         : $(rule_count warp)"
    echo "  Native       : $(rule_count native)"
    # 停用条数 —— 否则 Total 与分项加不起来, 小白会以为规则丢了
    (( _dis > 0 )) && echo "  停用         : $_dis  (catmi-warp3 on <域名> 重新启用)"
    echo ""
    echo "Forward Mode   : $([[ "$FORWARD" == "1" ]] && echo ON || echo OFF)"
    local s5; s5=$(socks5_status)
    echo "socks5         : ${s5:-未运行 (可用 fscarmen 'warp w' 装 WireProxy)}"
    echo "================================"
    return 0
}

# 真实链路测试 (§12)
cmd_test() {
    init_dirs   # 双模式: DEFAULT_OUTBOUND 来自 config/main.conf (无 load 会永远读到代码默认 native)
    local dom="${1,,}" expect="${2,,}"
    [[ -n "$dom" ]] || { err "用法: catmi-warp3 test <域名> [warp|native]"; return 1; }
    valid_domain "$dom" || { err "无效域名: $dom"; return 1; }
    detect_iface   # ⑥ 接口比对依赖真实 IFACE (缺失会导致 warp 永远误判 FAILED)
    # 期望来源: 显式参数 > 规则文件 > 默认 warp
    local norule=""
    if [[ -z "$expect" ]]; then
        expect=$(awk -F'|' -v d="$dom" '$1==d{print $2; exit}' <(rule_list))
        [[ -z "$expect" ]] && { expect="native"; norule=1; }   # 无规则域名: 系统真实行为按默认出口
    fi
    { [[ "$expect" == "warp" ]] || [[ "$expect" == "native" ]]; } || { err "期望必须是 warp|native"; return 1; }
    # 补栈未生效检测: V6=warp 但 cw3 v6 表无路由 (连通性自检已撤回) → v6 面跳过判定, 不刷 FAILED
    local v6skip=0
    if ! ip -6 route show table "$TABLE_NAME" 2>/dev/null | grep -q default; then
        v6skip=1   # cw3 v6 表无路由 = v6 WARP 路径不存在 (补栈未生效/内核禁用), v6 出站兜底原生
    fi
    # 三模式: 各协议栈的有效期望 = 规则方向 × 该栈默认模式 (无规则域 = 该栈默认方向)
    local e4 e6
    if [[ "$DEFAULT_OUTBOUND_V4" == "warp" ]]; then
        { [[ "$expect" == "native" && -z "$norule" ]]; } && e4="native" || e4="warp"
    else
        [[ "$expect" == "warp" ]] && e4="warp" || e4="native"
    fi
    if [[ "$DEFAULT_OUTBOUND_V6" == "warp" ]]; then
        { [[ "$expect" == "native" && -z "$norule" ]]; } && e6="native" || e6="warp"
    else
        [[ "$expect" == "warp" ]] && e6="warp" || e6="native"
    fi

    echo "------ 真实链路测试: $dom (规则: $([[ -n "$norule" ]] && echo 无 || echo "$expect") → 期望 v4:$e4 v6:$( [[ "$v6skip" == "1" ]] && echo "跳过(补栈未生效)" || echo "$e6" ) ) ------"
    # 澄清: 规则方向与该栈默认出口**相同**时, 这条规则不产生额外效果。
    # 不说清楚的话, 小白会把"默认出口本来就是 WARP"误读成"我加的规则生效了" ——
    # 实测 dual 下 google.com(有 warp 规则) 与 ifconfig.me(无规则) 的输出逐字节同构。
    if [[ -z "$norule" ]]; then
        local _noop=""
        [[ "$expect" == "$DEFAULT_OUTBOUND_V4" ]] && _noop="v4"
        [[ "$expect" == "$DEFAULT_OUTBOUND_V6" ]] && _noop="${_noop:+$_noop, }v6"
        if [[ -n "$_noop" ]]; then
            echo "  ⚠ 注意: 该规则在 ${_noop} 面**不产生额外效果** —— 该栈默认出口本来就是「$expect」。"
            echo "     下面测到的走向来自默认出口, 不能用来证明这条规则生效。"
            echo "     (要验证规则真生效: 切到相反的默认模式再测, 或测反向规则)"
        fi
    fi
    # ① 目标解析: IP 直测 (跳过 DNS) 或域名 (经 dnsmasq → 自动填 ipset)
    local ips4 ips6
    if [[ "$dom" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ips4="$dom"; ips6=""
        echo "① 目标为 IPv4 地址 (跳过 DNS): $ips4"
    elif [[ "$dom" == *:* && "$dom" =~ ^[0-9a-fA-F:]+$ ]]; then
        ips4=""; ips6="$dom"
        echo "① 目标为 IPv6 地址 (跳过 DNS): $ips6"
    else
        ips4=$(timeout 6 dig +short @127.0.0.1 "$dom" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
        # 同上: 用 has_v6 而不是 all.disable_ipv6, 否则 all=1 的机器上 test 只看 v4
        has_v6 \
            && ips6=$(timeout 6 dig +short @127.0.0.1 "$dom" AAAA 2>/dev/null | grep -E ':' | head -1)
        if [[ -z "$ips4" && -z "$ips6" ]]; then
            echo "DNS 解析       : FAILED (dnsmasq 不可达或域名无效)"
            echo "Result        : FAILED"; return 1
        fi
        echo "DNS 解析       : ${ips4:-无v4} ${ips6:+v6:$ips6}"
    fi

    local all_ok=1
    local fam ip hit line dev table result
    for fam in 4 6; do
        # v6 补栈未生效: 跳过 v6 面 (出站兜底原生, 无可验证的 WARP 路径)
        [[ "$fam" == "6" && "$v6skip" == "1" ]] && continue
        [[ "$fam" == "4" && -z "$ips4" ]] && continue
        [[ "$fam" == "6" && -z "$ips6" ]] && continue
        # 本机没有全局 v6 就跳过 v6 腿 —— 判据是 has_v6, 不是 all.disable_ipv6。
        # 原来那行会让 all=1 的机器 (RN 开机后就是这个状态) 整条 v6 腿都不测,
        # 而屏幕上什么提示都没有, 看起来像"v6 也测过了"。
        # 用户显式给 v6 字面量时例外: 他要的就是测这个地址。
        if [[ "$fam" == "6" ]] && ! has_v6 && [[ "$dom" != *:* ]]; then continue; fi
        ip=$([[ "$fam" == "4" ]] && echo "$ips4" || echo "$ips6")
        echo "② 取 IP (v$fam): $ip"
        # ③ ipset — 只验证"例外方向"的集合 (默认方向无集合, 期望 MISS)
        local effp setname="cw3-warp$fam" want_hit=MISS
        [[ "$fam" == "4" ]] && effp="$e4" || effp="$e6"
        local modf; [[ "$fam" == "4" ]] && modf="$DEFAULT_OUTBOUND_V4" || modf="$DEFAULT_OUTBOUND_V6"
        if [[ "$effp" != "$modf" ]]; then
            # 例外方向: 该栈默认与期望不同 → 域名进对应例外集合
            setname="cw3-$( [[ "$effp" == "warp" ]] && echo "warp$fam" || echo "native$fam" )"
            want_hit=HIT
        fi
        hit=MISS
        ipset test "$setname" "$ip" >/dev/null 2>&1 && hit=HIT
        echo "IPv$fam IPSet  : $hit (期望 $want_hit, 集合 $setname)"
        [[ "$hit" != "$want_hit" ]] && all_ok=0
        # ④⑤⑥ 路由决策 (按本协议栈有效期望)
        if [[ "$effp" == "warp" ]]; then
            line=$(ip -"$fam" route get "$ip" mark "$MARK" 2>/dev/null | head -1)
        else
            line=$(ip -"$fam" route get "$ip" 2>/dev/null | head -1)
        fi
        if [[ -z "$line" ]]; then
            echo "IPv$fam Route  : FAILED (route get 无结果)"; all_ok=0; continue
        fi
        dev=$(grep -oE 'dev [a-zA-Z0-9_.-]+' <<<"$line" | awk '{print $2}')
        table=$(grep -oE 'table [a-zA-Z0-9-]+' <<<"$line" | awk '{print $2}')
        [[ -z "$table" ]] && table="main"
        echo "IPv$fam Route  : dev=$dev"
        echo "路由表         : $table (期望 $([[ "$effp" == "warp" ]] && echo "$TABLE_NAME" || echo main))"
        echo "Interface      : $dev (期望 $([[ "$effp" == "warp" ]] && echo "${IFACE:-warp*}" || echo "非 WARP 接口"))"
        if [[ "$effp" == "warp" ]]; then
            [[ "$table" == "$TABLE_NAME" && "$dev" == "${IFACE:-warp}" ]] || all_ok=0
        else
            grep -qE '^(warp|WARP|CloudflareWARP|wgcf)$' <<<"$dev" && all_ok=0
        fi
        # ⑦ 实际建连 (不加 --interface — 走真实内核决策路径)
        local http
        http=$(timeout 10 curl -s -$fam -o /dev/null -w '%{http_code}' --resolve "$dom:443:$ip" "https://$dom/" 2>/dev/null)
        if [[ "$http" =~ ^[1-5] ]]; then
            echo "Connection     : OK (HTTP $http)"
        else
            echo "Connection     : FAILED (http=$http)"; all_ok=0
        fi
        # ⑧ 实际出口
        if is_echo_service "$dom"; then
            local body
            body=$(timeout 10 curl -s -$fam --resolve "$dom:80:$ip" "http://$dom/" 2>/dev/null | tr -d '[:space:]')
            [[ -z "$body" ]] && body=$(timeout 10 curl -s -$fam --resolve "$dom:443:$ip" "https://$dom/" 2>/dev/null | tr -d '[:space:]')
            echo "Exit IP        : $body (回显服务, 真实出口)"
        elif [[ "$dom" == "cloudflare.com" ]]; then
            local t; t=$(timeout 10 curl -s --resolve "cloudflare.com:443:$ip" https://cloudflare.com/cdn-cgi/trace 2>/dev/null)
            echo "Exit IP        : $(grep -oE '^(ip|warp)=[^ ]+' <<<"$t" | tr '\n' ' ')"
        else
            local eg; eg=$(timeout 8 curl -s -"$fam" --interface "$dev" https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -oE 'ip=[^ ]+' | head -1)
            echo "Exit IP        : (iface $dev egress) ${eg:-探测失败} — 非回显域名, 以④路由决策为准"
        fi
    done
    if [[ "$e4" == "native" && "$e6" == "native" && -z "$ips4" && -z "$ips6" ]]; then all_ok=0; fi
    if ((all_ok == 1)); then
        if [[ "$v6skip" == "1" ]]; then
            result="v4:$( [[ "$e4" == "warp" ]] && echo WARP || echo NATIVE ) (v6 面跳过: 补栈未生效, v6 兜底原生)"
        elif [[ "$e4" == "$e6" ]]; then
            result=$([[ "$e4" == "warp" ]] && echo WARP || echo NATIVE)
        else
            result="v4:$( [[ "$e4" == "warp" ]] && echo WARP || echo NATIVE )/v6:$( [[ "$e6" == "warp" ]] && echo WARP || echo NATIVE )"
        fi
    else
        result="FAILED (见上方 ✗ 项)"
    fi
    echo "--------------------------------"
    echo "Result        : $result"
    [[ "$result" == FAILED* ]] && return 1
    return 0
}

# 简版 doctor (apply 尾部)
doctor_brief() {
    detect_iface && ok "✓ WARP 接口: $IFACE" || err "✗ WARP 接口不在"
    grep -qE 'dev (warp|CloudflareWARP|WARP|wgcf)\b' <<<"$(ip -4 route show default 2>/dev/null | head -1)" \
        && err "✗ main 默认路由被替换!" || ok "✓ main 默认路由未动"
    systemctl is-active dnsmasq >/dev/null 2>&1 && ok "✓ dnsmasq 运行" || warn "△ dnsmasq 未运行"
}

# 链路级 doctor (§13)
doctor() {
    init_dirs
    echo "========== catmi-warp3 doctor =========="
    local p=0 w=0 f=0
    # 计数用 $(( )) 赋值 — ((p++)) 在 p=0 时 rc=1 会误触 &&/|| 链 (实测踩坑)
    okline()   { ok "$*"; p=$((p+1)); }
    warnline() { warn "△ $*"; w=$((w+1)); }
    failline() { err "✗ $*"; f=$((f+1)); }

    echo "--- WARP ---"
    if detect_iface; then
        okline "interface: $IFACE ($(warp_source))"
        local hs age
        hs=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')
        # **无条件**做真实 egress 探测: 只看"握手指针非 0"会把"隧道已死但历史指针还在"
        # 报成 OK (实测: 注入 4 小时旧握手 → 旧写法 [OK] + FAIL=0 + exit 0)。
        # 握手年龄只作为补充信息, 不作为通过依据。
        if timeout 8 curl -s -4 --interface "$IFACE" https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q 'warp=on'; then
            if [[ -n "$hs" && "$hs" != "0" ]]; then
                age=$(( $(date +%s) - hs ))
                if (( age < 180 )); then
                    okline "egress 实测通 (handshake ${age}s 前)"
                else
                    warnline "egress 实测通, 但 handshake 已 ${age}s 未更新 (偏旧, 留意)"
                fi
            else
                okline "egress 实测通 (无握手记录, 用户态接口)"
            fi
        else
            failline "WARP 隧道不通 (egress 实测失败)"
        fi
        # MSS clamp: MTU 1280 隧道不做 clamp = "小包通、满载卡" 的经典故障
        iptables -t mangle -S POSTROUTING 2>/dev/null | grep -q 'clamp-mss-to-pmtu' \
            && okline "MSS clamp 规则在位" || failline "MSS clamp 规则缺失 (走 WARP 的大包会卡)"
        systemctl is-active --quiet wg-quick@warp 2>/dev/null \
            && okline "wg-quick@warp 服务 active" || warnline "wg-quick@warp 服务未运行 (重启后不会自动建隧道)" 
        # 配置里的 endpoint 是**主机名**(需 DNS), 实际握手用的是 wg 已解析的对端地址 ——
        # 两者不同, 原来只显示前者, 打不通时看不出真正在连哪。
        local _aep
        _aep=$(wg show "$IFACE" endpoints 2>/dev/null | awk '{print $2}' | head -1)
        parse_creds >/dev/null 2>&1 && [[ -n "$ADDR4" ]] \
            && okline "endpoint: $ENDPOINT (MTU ${WARP_MTU:-1280})${_aep:+ · 实际握手 → $_aep}"
    else
        failline "WARP 接口不存在 (start/install)"
    fi
    # 分族独立报告 (不合并)
    local p4 p6
    p4=$(family_probe 4); p6=$(family_probe 6)
    case "$p4" in OK) okline "IPv4: WARP OK" ;; fallback) warnline "IPv4: WARP FAILED → fallback Native" ;; *) warnline "IPv4: $p4" ;; esac
    # **不能**用 all.disable_ipv6 判"内核禁 v6" —— 那只是"新接口的默认值",
    # per-interface 可以例外。本机实测 all=1 但 warp 接口 =0、v6 通道真实可用
    # (curl -6 cdn-cgi/trace → warp=on), 旧写法会把它误报成"v6 全部 Native",
    # 且与同一次输出里 "双栈 v6→warp" 自相矛盾。直接报 family_probe 的真实结果。
    case "$p6" in OK) okline "IPv6: WARP OK" ;; fallback) warnline "IPv6: WARP FAILED → fallback Native" ;; *) warnline "IPv6: $p6" ;; esac

    echo "--- DNS ---"
    local mode; mode=$(detect_dns53)
    case "$mode" in
        dnsmasq|resolved|free) okline "DNS :53 mode=$mode" ;;
        *) failline "DNS: :53 被 $mode 占用, 分流解析不可靠" ;;
    esac
    systemctl is-active dnsmasq >/dev/null 2>&1 && okline "dnsmasq 运行" || warnline "dnsmasq 未运行 (free 模式正常; 分流模式需要)"
    if [[ -s "$RESOLV_STATE" ]]; then
        if resolv_points_local; then
            okline "resolv.conf 受管且指向 127.0.0.1 ($(grep -E "^RESOLV_TYPE=" "$RESOLV_STATE" | cut -d= -f2-))"
        else
            failline "resolv.conf 漂移: state 在管但未指向 127.0.0.1 (re-apply 修复)"
        fi
    else
        resolv_points_local && warnline "resolv.conf 指向 127.0.0.1 但无 state (非本模块管理)" || okline "resolv.conf 未接管 (自由状态)"
    fi

    echo "--- Routing ---"
    if [[ -f "$APPLIED_FLAG" ]]; then
        ip -4 rule show | grep -qE "fwmark 0x$MARK (table|lookup) $TABLE_NAME" \
            && okline "ip rule fwmark 0x$MARK → $TABLE_NAME 在位" || failline "策略路由规则缺失"
        if ip -4 route show table "$TABLE_NAME" 2>/dev/null | grep -qE 'dev (warp|WARP)'; then
            okline "表 $TABLE_NAME → WARP 接口"
        else
            failline "表 $TABLE_NAME 无有效 WARP 路由"
        fi
        ipset_exists cw3-warp4 && okline "ipset cw3-warp4 ($(ipset list cw3-warp4 2>/dev/null | grep -cE '^[0-9]+\.') 成员)" || failline "ipset cw3-warp4 缺失 (applied 但 ipset 无)"
        ipset_exists cw3-warp6 && okline "ipset cw3-warp6 ($(ipset list cw3-warp6 2>/dev/null | grep -cE '^[0-9a-fA-F]') 成员)" || warnline "ipset cw3-warp6 不存在 (单栈正常)"
        # v6 面策略路由 —— 原来 doctor 在报告里猜 v6, 却从不看 ip -6 rule / cw3 表的 v6 路由
        if [[ "$DEFAULT_OUTBOUND_V6" == "warp" ]]; then
            ip -6 rule show 2>/dev/null | grep -qE "fwmark 0x$MARK (table|lookup) $TABLE_NAME" \
                && okline "ip -6 rule fwmark 0x$MARK → $TABLE_NAME 在位" || failline "v6 策略路由规则缺失 (v6=warp)"
            ip -6 route show table "$TABLE_NAME" 2>/dev/null | grep -q default \
                && okline "表 $TABLE_NAME 有 v6 默认路由" || failline "v6=warp 但 $TABLE_NAME 表无 v6 默认路由!"
        fi
        # 默认出口连通性**实测** —— 结构在位 ≠ 真能出网 (隧道死了而规则还在时, 结构检查全绿)
        local _e4
        _e4=$(timeout 10 curl -4 -s --max-time 8 https://ifconfig.me/ip 2>/dev/null | tr -d ' \n')
        if [[ -n "$_e4" ]]; then
            okline "默认出口连通性: v4 实测通 (出口 $_e4)"
        else
            failline "默认出口连通性: v4 实测失败 (规则在位但出不了网)"
        fi
        if [[ "$DEFAULT_OUTBOUND_V6" == "warp" ]]; then
            local _e6
            _e6=$(timeout 10 curl -6 -s --max-time 8 https://ifconfig.me/ip 2>/dev/null | tr -d ' \n')
            [[ -n "$_e6" ]] && okline "默认出口连通性: v6 实测通 (出口 $_e6)" \
                            || warnline "默认出口连通性: v6 实测失败 (v6=warp 但 v6 出不去)"
        fi
    else
        warnline "分流未部署 (apply 后检查 Routing)"
    fi

    echo "--- Default Outbound ---"
    okline "栈模式: $(stack_mode) (v4→$DEFAULT_OUTBOUND_V4 / v6→$DEFAULT_OUTBOUND_V6)"
    local _ce; _ce=$(chain_exempt_ips)
    [[ -n "$_ce" ]] && okline "链式上游豁免 (自动识别): $_ce" || true
    # v4 面
    if [[ "$DEFAULT_OUTBOUND_V4" == "warp" ]]; then
        if ip -4 route show table "$TABLE_NAME" 2>/dev/null | grep -q default; then
            okline "v4: WARP policy 表存在 ($TABLE_NAME default)"
        else
            failline "v4=warp 但 $TABLE_NAME 表无 v4 默认路由!"
        fi
        ipset_exists cw3-native4 && okline "v4 Native 例外集合就绪 (cw3-native4)" \
            || failline "v4 Native 例外集合缺失 (warp 模式必需)"
    else
        okline "v4: Native 默认 (warp 规则为例外)"
    fi
    # v6 面
    if [[ "$DEFAULT_OUTBOUND_V6" == "warp" ]]; then
        if ip -6 route show table "$TABLE_NAME" 2>/dev/null | grep -q default; then
            okline "v6: WARP policy 表存在 (补栈 v6 出口就绪)"
        else
            warnline "v6 补栈未生效: cw3 v6 表无默认路由 (apply 时连通性自检失败已自动撤回) — v6 出站兜底走原生出口, 不影响服务; 若需 v6 走 WARP 需修复 warp-go 的 v6 通道"
        fi
        ipset_exists cw3-native6 && okline "v6 Native 例外集合就绪 (cw3-native6)" \
            || failline "v6 Native 例外集合缺失 (warp 模式必需)"
    else
        okline "v6: Native 默认 (warp 规则为例外)"
    fi
    # 账号保活可见性 (原来只在 journal 里, 长期放置时账号失效无人知)
    if [[ -s "$ACCOUNT_JSON" ]]; then
        local _kats _kalast _kacode
        _kats=$(cat "$KA_TS" 2>/dev/null || echo 0)
        read -r _kalast _kacode < <(cat "$STATE/ka-last" 2>/dev/null || echo "0 0")
        # 分三种情况, 别把"新装还没到周期"报成故障 ——
        # 原来只要 KA_TS 不存在就无条件 warnline, 实测全新安装 (CCS) 立刻出现
        # "从未成功 (最近一次 HTTP 0)": 那个 0 是 ka-last 缺失时的兜底值, 不是真的 HTTP 码。
        local _acct_age=$(( ( $(date +%s) - $(stat -c %Y "$ACCOUNT_JSON" 2>/dev/null || echo 0) ) / 86400 ))
        if [[ "$_kats" =~ ^[0-9]+$ ]] && (( _kats > 0 )); then
            local _kad=$(( ( $(date +%s) - _kats ) / 86400 ))
            (( _kad <= 8 )) && okline "账号保活: 上次成功 ${_kad} 天前" \
                            || warnline "账号保活: 上次成功 ${_kad} 天前 (>7 天) — 账号可能已失效, 查: catmi-warp3 keepalive"
        elif [[ -n "$_kacode" && "$_kacode" != "0" && "$_kacode" != "200" ]]; then
            warnline "账号保活: 上次尝试 HTTP $_kacode (失败) — 查: catmi-warp3 keepalive"
        elif (( _acct_age > 8 )); then
            warnline "账号保活: 账号已 ${_acct_age} 天但从未成功保活 — 定时器没装? 查: systemctl status catmi-warp3-keepalive.timer"
        fi
    fi

    # 两栈红线
    local mdef4 mdef6
    mdef4=$(ip -4 route show default 2>/dev/null | head -1)
    if grep -qE 'dev (warp|CloudflareWARP|WARP|wgcf)\b' <<<"$mdef4"; then
        failline "main v4 默认路由被 WARP 接管! (安全红线)"
    else
        okline "main v4 默认路由未被替换 (红线)"
    fi
    okline "main v6 默认路由未被触碰 (catmi 从不改 main v6)"
    if [[ "$FORWARD" != "1" ]]; then
        iptables -t mangle -S PREROUTING 2>/dev/null | grep -q CATMI3-FWD \
            && failline "Forward=OFF 但 PREROUTING 仍有 CATMI3-FWD 规则!" \
            || okline "Forward OFF 且 PREROUTING 干净 (入站零影响)"
    fi
    echo "--- Firewall ---"
    if [[ -f "$APPLIED_FLAG" ]]; then
        iptables -t mangle -L OUTPUT 2>/dev/null | grep -q CATMI3-OUT \
            && okline "mangle OUTPUT → CATMI3-OUT 在位" || failline "OUTPUT 跳转缺失 (applied 但规则无)"
        iptables -t mangle -S CATMI3-OUT 2>/dev/null | grep -q "mark ! --mark" \
            && okline "mark 保护 (已标流量 RETURN) 在位" || failline "mark 保护规则缺失 — 显式出站会被覆盖!"
        # fw_up 末尾无条件建 ip6tables OUTPUT 跳转, 所以这里有 v6 就必须核 ——
        # 原来拿 all.disable_ipv6==1 当"没 v6"直接跳过, 于是 all=1 的机器上
        # 这项检查**从来没跑过** (doctor 少一项却不报错: 属于漏检型假绿)。
        if has_v6; then
            ip6tables -t mangle -L OUTPUT 2>/dev/null | grep -q CATMI3-OUT \
                && okline "ip6tables OUTPUT 跳转在位" || failline "ip6tables OUTPUT 跳转缺失"
        fi
    fi
    if [[ "$FORWARD" == "1" ]]; then
        iptables -t mangle -L PREROUTING 2>/dev/null | grep -q CATMI3-FWD \
            && okline "forward ON: PREROUTING + MASQUERADE 在位" || warnline "forward=ON 但 PREROUTING 缺失 (re-apply)"
    else
        iptables -t mangle -L PREROUTING 2>/dev/null | grep -q CATMI3-FWD \
            && failline "forward=OFF 但 PREROUTING 残留 FWD 规则 (revoke 清理)" \
            || okline "PREROUTING 无本模块规则 (默认 OFF, 入站零影响)"
    fi
    grep -qE 'dev (warp|CloudflareWARP|WARP|wgcf)\b' <<<"$(ip -4 route show default 2>/dev/null | head -1)" \
        && failline "main 默认路由被 WARP 接管!! (安全红线)" || okline "main 默认路由未动 (安全红线)"

    echo "--- Rules ---"
    local total; total=$(rule_list | wc -l)
    okline "规则: $total 条 (warp $(rule_count warp) / native $(rule_count native))"
    if [[ -f "$APPLIED_FLAG" ]]; then
        local first_dom
        first_dom=$(awk -F'|' '$3==1 && $2=="warp"{print $1; exit}' <(rule_list))
        if [[ -n "$first_dom" ]]; then
            if cmd_test "$first_dom" >/dev/null 2>&1; then
                okline "样本链路实测: $first_dom → WARP 通"
            else
                failline "样本链路实测失败: $first_dom (catmi-warp3 test $first_dom 看详情)"
            fi
        fi
    fi

    echo "--- Compatibility ---"
    local sig=""
    pgrep -x xray >/dev/null 2>&1 || pgrep -f 'xray' >/dev/null 2>&1 && sig="$sig xray"
    pgrep -f 'mihomo|clash' >/dev/null 2>&1 && sig="$sig mihomo"
    pgrep -f 'hysteria' >/dev/null 2>&1 && sig="$sig hysteria2"
    pgrep -x nginx >/dev/null 2>&1 && sig="$sig nginx"
    systemctl is-active docker >/dev/null 2>&1 && sig="$sig docker"
    systemctl is-active sshd >/dev/null 2>&1 || systemctl is-active ssh >/dev/null 2>&1 && sig="$sig sshd"
    [[ -n "$sig" ]] && okline "检测到共存服务:$sig" || warnline "未检测到常见代理/Web 服务"
    if [[ -f "$APPLIED_FLAG" ]] && ! iptables -t mangle -S CATMI3-OUT 2>/dev/null | grep -q "mark ! --mark"; then
        failline "共存保护: mark-RETURN 规则缺失 → 显式出站有被覆盖风险 (re-apply)"
    else
        okline "共存保护: 已标 fwmark 流量 RETURN (sockopt.mark/routing-mark 不被覆盖)"
    fi
    # 这条是**恒定提示**, 不是检查结果 —— 原来用 warnline 会计入 WARN 计数,
    # 把 Summary 从 PASS 压成 WARN, **稀释真正的告警**。改成不计数的 info。
    # 同时去掉指向 docs/COMPATIBILITY.md 的引用: 脚本是单文件部署, 该文档并不存在。
    info "提示 (不计入告警): root 运行且无 mark/bind 的代理 direct 出站, 内核层无法区分"
    info "  要把它固定走原生: 给它设 routing-mark / sockopt.mark, 或加进 main.conf 的 NATIVE_IPS"

    echo "=========================================="
    echo "Summary: PASS=$p WARN=$w FAIL=$f → $( ((f>0)) && echo FAIL || { ((w>0)) && echo WARN || echo PASS; } )"
    # 供面板显示最近一次真实探测 (时间戳 1h 内有效)
    # 顺带记下**真实出口 IP** —— 面板原来只显示 ● WARP / ● Native 这种推断词,
    # 用户最想知道的"我现在出口 IP 是多少"却要翻三层菜单。这里探测一次缓存起来。
    local _eip4 _eip6
    _eip4=$(timeout 10 curl -4 -s --max-time 8 https://ifconfig.me/ip 2>/dev/null | tr -d ' \n')
    _eip6=$(timeout 10 curl -6 -s --max-time 8 https://ifconfig.me/ip 2>/dev/null | tr -d ' \n')
    { echo "ipv4=$p4"; echo "ipv6=$p6"; echo "egress_ok=$([[ $p4 == OK* ]] && echo 1 || echo 0)"
      echo "ip4=$_eip4"; echo "ip6=$_eip6"; echo "ts=$(date +%s)"; } > "$STATE/ui.state" 2>/dev/null
    ((f == 0)) && return 0
    return 1
}

# SO_MARK 探针: 带 mark 的 TLS 连接 → cloudflare trace 的 warp= 行 (test-priority 核心)
mark_egress_probe() { # mark_egress_probe <ip> <mark>
    python3 - "$1" "${2:-0}" <<'PYEOF'
import socket, ssl, sys
ip = sys.argv[1]; mark = int(sys.argv[2])
try:
    ctx = ssl._create_unverified_context()
    s = socket.socket()
    if mark:
        s.setsockopt(socket.SOL_SOCKET, 36, mark)   # SO_MARK
    s.settimeout(8)
    s.connect((ip, 443))
    w = ctx.wrap_socket(s, server_hostname="cloudflare.com")
    w.send(b"GET /cdn-cgi/trace HTTP/1.1\r\nHost: cloudflare.com\r\nConnection: close\r\n\r\n")
    data = w.recv(4096).decode(errors="replace")
    for line in data.splitlines():
        if line.startswith(("warp=", "ip=")):
            print(line)
except Exception as e:
    print("PROBE_FAIL:", e)
PYEOF
}

# 出站优先级诊断 (§18): 验证"内核明确出站 > catmi-warp 默认接管"
test_priority() {
    init_dirs
    echo "========== 出站优先级诊断 (doctor outbound / test-priority) =========="
    local p=0 w=0 f=0
    # 计数用 $(( )) 赋值 — ((p++)) 在 p=0 时 rc=1 会误触 &&/|| 链 (实测踩坑)
    okline()   { ok "$*"; p=$((p+1)); }
    warnline() { warn "△ $*"; w=$((w+1)); }
    failline() { err "✗ $*"; f=$((f+1)); }
    # ① 防护规则核验
    local rules; rules=$(iptables -t mangle -S CATMI3-OUT 2>/dev/null)
    grep -q '^\-A CATMI3-OUT \-m mark ! \-\-mark' <<<"$rules" \
        && okline "① mark 保护规则在位 (已标流量 RETURN, 永不覆盖)" \
        || { [[ -f "$APPLIED_FLAG" ]] && failline "① CATMI3-OUT 缺 mark-RETURN 保护 — V3 核心规则未部署!" || warnline "① 分流未部署 (apply 后复测)"; }
    # ② 全系统 mark 规则清点 (谁在打标)
    echo "  ② 全系统 mangle 打标规则:"
    iptables -t mangle -S 2>/dev/null | grep -E 'j MARK|--set-mark|--set-xmark' | sed 's/^/      /'
    # ③④⑤ 实测
    local cfip devid
    cfip=$(dig +short @127.0.0.1 cloudflare.com A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    [[ -z "$cfip" ]] && cfip=$(dig +short cloudflare.com A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    devid=$(ip -4 route show default 2>/dev/null | grep -oE 'dev [a-zA-Z0-9_.-]+' | awk '{print $2; exit}')
    if [[ -z "$cfip" ]]; then
        failline "③④⑤ 无法取 CF 边缘 IP (DNS 不可用) — 实测跳过"
    else
        # ③ 已标 socket (SO_MARK=100) → 期望 Native (不被接管)
        local r3; r3=$(mark_egress_probe "$cfip" 100 2>/dev/null | grep -oE '^warp=[a-z]+$' | head -1)
        [[ "$r3" == "warp=off" ]] \
            && okline "③ 已标 socket(mark=100) → Native (未被接管) ✓" \
            || failline "③ 已标 socket 出口异常 ($r3) — mark 保护可能失效!"
        # ④ 绑定接口 → 期望 Native (内核 bound-socket 语义)
        local r4
        r4=$(timeout 8 curl -s --interface "${devid:-eth0}" --resolve "cloudflare.com:443:$cfip" https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -oE '^warp=[a-z]+$' | head -1)
        [[ "$r4" == "warp=off" ]] \
            && okline "④ bind $devid → Native (bound-socket 语义) ✓" \
            || failline "④ bind 流量出口异常 ($r4)"
        # ⑤ 无标普通流量 + ipset 命中 → 期望 WARP (默认接管仍生效)
        if ipset test cw3-warp4 "$cfip" >/dev/null 2>&1; then
            local r5
            r5=$(timeout 8 curl -s --resolve "cloudflare.com:443:$cfip" https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -oE '^warp=[a-z]+$' | head -1)
            # ⑤ 是唯一验证"默认接管真的生效"的断言: 原来只 warnline, 调用方拿到 rc=0,
            # "分流没生效"与"正常"不可区分。已 apply 却出不去 = 真 FAIL。
            [[ "$r5" == "warp=on" ]] \
                && okline "⑤ 无标流量 → WARP ($( [[ "$DEFAULT_OUTBOUND_V4" == "warp" ]] && echo "v4 WARP 默认" || echo "ipset 命中" )生效) ✓" \
                || { [[ -f "$APPLIED_FLAG" ]] \
                       && failline "⑤ 无标流量未走 WARP ($r5) — 分流**未生效**或已被 V2 等接管" \
                       || warnline "⑤ 无标流量未走 WARP ($r5) — 分流未部署 (apply 后复测)"; }
        else
            warnline "⑤ $cfip 不在 cw3-warp4 (先 add cloudflare.com warp + apply 再测)"
        fi
    fi
    # ⑥ 代理内核显式出站信号 (只读检查)
    local sig=""
    for xf in /root/catmi/xray/conf/*.json /usr/local/etc/xray/config.json /etc/xray/config.json; do
        [[ -f "$xf" ]] && grep -l sockopt "$xf" >/dev/null 2>&1 && sig="$sig xray(sockopt)"
    done
    grep -rEls 'routing-mark' /root/catmi/mihomo/conf/*.yaml /etc/mihomo/*.yaml 2>/dev/null | grep -q . && sig="$sig mihomo(routing-mark)"
    [[ -n "$sig" ]] && okline "⑥ 代理内核显式出站信号:$sig" \
        || warnline "⑥ xray/mihomo 未声明显式出站信号 → 其 root 直连流量内核层不可区分, 命中规则域名时会被接管; 要固定走原生请给它设 routing-mark / sockopt.mark, 或加进 main.conf 的 NATIVE_IPS"
    echo "======================================================"
    echo "Summary: PASS=$p WARN=$w FAIL=$f → $( ((f>0)) && echo FAIL || { ((w>0)) && echo WARN || echo PASS; } )"
    ((f == 0)) && return 0
    return 1
}

# 安装前体检 (check_env)
check_env() {
    echo "========== catmi-warp check =========="
    local bad=0
    command -v systemctl >/dev/null 2>&1 && ok "✓ systemd" || { err "✗ 无 systemd"; ((bad++)); }
    command -v curl >/dev/null 2>&1 && ok "✓ curl" || { err "✗ curl"; ((bad++)); }
    command -v python3 >/dev/null 2>&1 && ok "✓ python3" || { err "✗ python3 (注册解析需要)"; ((bad++)); }
    command -v wg >/dev/null 2>&1 && ok "✓ wireguard-tools" || warn "△ wireguard-tools 未装 (安装时自动)"
    # 分流真正依赖的三个命令 —— 原来 check_env 一个都不查, 全缺也照样"✓ 体检通过"
    # (ensure_deps 会在 apply 时自动装, 所以这里只报警不阻断)
    command -v iptables >/dev/null 2>&1 && ok "✓ iptables" || warn "△ iptables 未装 (apply 时 ensure_deps 自动装)"
    command -v ipset >/dev/null 2>&1 && ok "✓ ipset" || warn "△ ipset 未装 (apply 时 ensure_deps 自动装)"
    command -v dig >/dev/null 2>&1 && ok "✓ dig" || warn "△ dig 未装 (apply 时 ensure_deps 自动装)"
    if modprobe wireguard 2>/dev/null || grep -qw wireguard /proc/modules 2>/dev/null; then
        ok "✓ 内核 WireGuard 模块"
    elif kernel_ge 5 6; then
        ok "✓ 内核 $(uname -r) ≥5.6 (内置)"
    else
        err "✗ 内核 $(uname -r) 无 WireGuard"; ((bad++))
    fi
    # 内核能力探测 —— 容器 / OpenVZ / 精简内核上装了 ipset/iptables 也未必能用,
    # 这类问题在 apply 半途炸出来最难查, 前置到体检里 (实测可行的最小探测)
    if command -v ipset >/dev/null 2>&1; then
        if ipset create catmi-probe-test hash:ip -exist 2>/dev/null; then
            ipset destroy catmi-probe-test 2>/dev/null
            ok "✓ ipset 内核模块可用"
        else
            err "✗ ipset 无法创建集合 (内核缺 ip_set/xt_set 模块?)"; ((bad++))
        fi
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -t mangle -L -n >/dev/null 2>&1 \
            && ok "✓ iptables mangle 表可用" \
            || { err "✗ iptables mangle 表不可用 (容器缺 NET_ADMIN / 无 nf_tables?)"; ((bad++)); }
    fi
    local st; st=$(already_installed)
    case "$st" in
        接口*) ok "✓ WARP 本体: 已装 ($st)" ;;
        凭据|服务|进程) warn "△ WARP 本体: $st 在但接口未起 (start / install 诊断)" ;;
        *) warn "△ WARP 本体: 未装 (install 一键装)" ;;
    esac
    if timeout 6 curl -s -o /dev/null https://api.cloudflareclient.com 2>/dev/null; then
        ok "✓ 注册 API 可达"
    else
        warn "△ 注册 API 暂不可达 (已装则不影响)"
    fi
    echo "  分流规则   : $(rule_list 2>/dev/null | wc -l) 条"
    echo "  forward    : $FORWARD"
    ((bad == 0)) && { ok "体检通过"; return 0; }
    err "体检 $bad 项异常"; return 1
}

# ============================================================
# keepalive / 单元 / update / uninstall
# ============================================================
account_keepalive() {
    [[ -s "$ACCOUNT_JSON" ]] || return 0
    local now ts id tok code last_t last_c
    now=$(date +%s); ts=$(cat "$KA_TS" 2>/dev/null || echo 0)
    (( now - ts < 604800 )) && return 0
    # 失败退避 + 结果留痕: 原来失败时每 10 分钟无限重试 (~144 次/天), 且结果只 echo 到 journal,
    # status/doctor 都不读 ⇒ 账号真失效时用户永远看不到 (长期放置最怕的静默失效)。
    read -r last_t last_c < <(cat "$STATE/ka-last" 2>/dev/null || echo "0 0")
    [[ "$last_t" =~ ^[0-9]+$ ]] || last_t=0
    if [[ -n "$last_c" && "$last_c" != "0" && "$last_c" != "200" ]] && (( now - last_t < 3600 )); then
        return 0
    fi
    id=$(python3 -c "import json;print(json.load(open('$ACCOUNT_JSON')).get('id',''))" 2>/dev/null)
    tok=$(python3 -c "import json;print(json.load(open('$ACCOUNT_JSON')).get('token',''))" 2>/dev/null)
    [[ -z "$id" || -z "$tok" ]] && return 0
    code=$(timeout 10 curl -s -o /dev/null -w '%{http_code}' "$CF_API_REG/$id" \
        -H 'User-Agent: okhttp/3.12.1' -H "CF-Client-Version: $CF_API_VER" \
        -H "Authorization: Bearer $tok" 2>/dev/null)
    echo "$now $code" > "$STATE/ka-last" 2>/dev/null
    if [[ "$code" == "200" ]]; then
        date +%s > "$KA_TS"; echo "keepalive: OK ($code)"
    else
        echo "keepalive: HTTP $code (异常 — 已退避 1h 再试; 连续失败说明账号可能已失效)"
    fi
}

install_units() {
    need_root
    # ExecStart 把**安装时**的脚本路径固化进单元文件: 从 /tmp 副本安装后, 单元指向的脚本
    # 重启时早已不存在 → 开机恢复与保活永久失败, 而用户看不到任何提示。这里前置拦掉。
    if [[ ! -x "$SELF_PATH" ]]; then
        err "开机单元要固化的路径不可执行: $SELF_PATH"; return 1
    fi
    case "$SELF_PATH" in
        /tmp/*|/var/tmp/*|/dev/shm/*)
            err "当前脚本在临时目录 ($SELF_PATH) — 固化成开机单元会永久失效"
            err "先落到固定路径再装: install -m 755 \"$SELF_PATH\" /usr/local/bin/catmi-warp3"
            return 1 ;;
    esac
    cat > /lib/systemd/system/catmi-warp3-restore.service <<EOF
[Unit]
Description=catmi-warp3: re-apply WARP site-split after boot (v3)
After=network-online.target warp-go.service wg-quick@warp.service
# Wants 必须显式列出 wg-quick@warp.service —— 只写 After= 只是排序, 不会把它拉进事务。
# 缺了它就有竞态: 本单元先跑而 warp 接口还没建好 → "未检测到 WARP 接口" → 失败。
# (实测同一单元 09-08 failed / 09-11 success, 正是竞态的典型表现)
Wants=network-online.target wg-quick@warp.service

[Service]
Type=oneshot
# 双保险: 再等接口就绪(最多 60s)。Type=oneshot 不能用 Restart=, 所以在这里兜。
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 30); do ip link show warp >/dev/null 2>&1 && exit 0; sleep 2; done; echo "warp 接口 60s 内未就绪"; exit 1'
ExecStart=$SELF_PATH apply --yes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    cat > /lib/systemd/system/catmi-warp3-keepalive.timer <<'EOF'
[Unit]
Description=catmi-warp3: refresh site IPs + weekly account keepalive

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Unit=catmi-warp3-keepalive.service

[Install]
WantedBy=timers.target
EOF
    cat > /lib/systemd/system/catmi-warp3-keepalive.service <<EOF
[Unit]
Description=catmi-warp3: warm ipset + account keepalive

[Service]
Type=oneshot
ExecStart=$SELF_PATH keepalive
EOF
    systemctl daemon-reload
    # enable 失败 = 重启后不会自动恢复分流、保活也不跑 —— 不能报了"已安装"就完事
    if ! systemctl enable catmi-warp3-restore.service catmi-warp3-keepalive.timer >/dev/null 2>&1; then
        err "开机单元 enable 失败 — 重启后**不会**自动恢复分流";
        err "排查: systemctl status catmi-warp3-restore.service"
        return 1
    fi
    systemctl is-enabled --quiet catmi-warp3-restore.service 2>/dev/null \
        || { err "catmi-warp3-restore 未处于 enabled 状态"; return 1; }
    ok "已安装: catmi-warp3-restore (开机恢复) + catmi-warp3-keepalive 定时器 (10min)"
}

update_self() {
    need_root
    local url="${1:-$DEFAULT_UPDATE_URL}"
    [[ -z "$url" ]] && { err "未配置更新源 — catmi-warp update <URL> 或设 CATMI_WARP_URL"; return 1; }
    acquire_lock || return 1
    init_dirs   # 否则 $BACKUPS 不存在时, 下面的备份静默不发生 (回滚点都没有)
    info "拉取 $url ..."
    local tmp="$RUNTIME/catmi-warp.new"
    if ! timeout 30 curl -sL "$url" -o "$tmp" || [[ ! -s "$tmp" ]]; then
        err "下载失败"; rm -f "$tmp"; return 1
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        err "新版本语法校验失败, 放弃更新"; rm -f "$tmp"; return 1
    fi
    local self old new
    self=$(readlink -f "$0" 2>/dev/null || echo /usr/local/bin/catmi-warp3)
    old=$(md5sum "$self" 2>/dev/null | awk '{print $1}')
    new=$(md5sum "$tmp" | awk '{print $1}')
    if [[ "$old" == "$new" ]]; then
        ok "已是最新版 (${new:0:8})"; rm -f "$tmp"; return 0
    fi
    # 备份失败就不更新 —— 没有回滚点的自我更新等于赌命
    if ! cp -f "$self" "$BACKUPS/catmi-warp.old" 2>/dev/null || [[ ! -s "$BACKUPS/catmi-warp.old" ]]; then
        err "备份当前版本失败 ($BACKUPS/catmi-warp.old) — 中止更新"; rm -f "$tmp"; return 1
    fi
    if install -m 755 "$tmp" "$self" && bash "$self" selftest >/dev/null 2>&1; then
        rm -f "$tmp"
        ok "更新完成: ${old:0:8} → ${new:0:8} (旧版: $BACKUPS/catmi-warp.old)"
        log_op "update" "OK $old → $new"
    else
        # 原来 `cp ... && chmod` 失败会静默短路, 却照样打印"回滚" —— 坏脚本留在原位
        if cp -f "$BACKUPS/catmi-warp.old" "$self" 2>/dev/null && chmod 755 "$self" \
           && bash "$self" selftest >/dev/null 2>&1; then
            err "新版 selftest 未通过 — 已回滚到旧版 (${old:0:8})"
        else
            err "新版 selftest 未通过 且 回滚失败! 请手工恢复: cp $BACKUPS/catmi-warp.old $self"
        fi
        rm -f "$tmp"; log_op "update" "FAILED+rollback"
        return 1
    fi
}

uninstall_module() {
    need_root
    acquire_lock || return 1
    echo "卸载 catmi-warp3 v$VERSION 模块..."
    # 拆除失败就**别删自己** —— 否则现场残留 (iptables / ip rule / DNS 半死) 而修复工具已被删除,
    # 用户既看不到残留也修不了。原写法是 `revoke >/dev/null 2>&1` 后照常往下走。
    if ! revoke >/dev/null 2>&1; then
        err "拆除分流失败 — 已中止卸载 (避免留下残留却没有工具可修)"
        err "请先排查: catmi-warp3 doctor    修好后重试: catmi-warp3 uninstall"
        return 1
    fi
    systemctl disable --now catmi-warp3-restore.service catmi-warp3-keepalive.timer catmi-warp3-keepalive.service >/dev/null 2>&1
    rm -f /lib/systemd/system/catmi-warp3-restore.service /lib/systemd/system/catmi-warp3-keepalive.timer /lib/systemd/system/catmi-warp3-keepalive.service
    systemctl daemon-reload
    local self
    self=$(readlink -f "$0" 2>/dev/null || echo /usr/local/bin/catmi-warp3)
    local yn
    printf "  同时停用 WARP 本体 (wg-quick@warp / warp-go, 凭据保留)? (y/N): "
    read -r yn </dev/tty 2>/dev/null || yn=""
    case "${yn,,}" in
        y|yes)
            systemctl disable --now wg-quick@warp >/dev/null 2>&1
            systemctl disable --now warp-go >/dev/null 2>&1
            ok "WARP 本体已停用 (凭据保留, 可随时再启用)"
            ;;
        *) ok "WARP 本体保持运行 (只卸载分流与管理层)" ;;
    esac
    rm -f "$GEN_DNS_LINK" "$GEN_DNS_REAL" "$self"
    ok "模块已卸载 — config/state/backups/logs 保留在 $BASE (rm -rf $BASE 彻底清除)"
    log_op "uninstall" "OK"
}

# ============================================================
# selftest (纯函数级断言)
# ============================================================
selftest() {
    local pass=0 failn=0
    _t() { if eval "$2"; then ((pass++)); else ((failn++)); echo "FAIL: $1" >&2; fi; }
    FAIL() { ((failn++)); echo "FAIL: $1" >&2; }  # 供 'cmd && _t x || FAIL y' 形态, 修复失败被吞假绿

    # 域名与回显服务
    _t "valid domain" 'valid_domain "google.com"'
    _t "invalid domain" '! valid_domain "bad..com"'
    _t "echo svc api.ip.sb" 'is_echo_service "api.ip.sb"'
    _t "echo svc negative" '! is_echo_service "google.com"'

    # 内核版本比较 —— 只看 major 是 V3 审计实测到的假绿 (5.4 被判成 ≥5.6, WG 是 5.6 才进主线)
    _t "kernel_ge 6.19"          'kernel_ge 5 6 "6.19.11-x64v2-xanmod1"'
    _t "kernel_ge 5.6 边界"      'kernel_ge 5 6 "5.6.0-generic"'
    _t "kernel_ge 拒绝 5.5"      '! kernel_ge 5 6 "5.5.9"'
    _t "kernel_ge 拒绝 5.4"      '! kernel_ge 5 6 "5.4.19-rockchip64"'
    _t "kernel_ge 拒绝 4.x"      '! kernel_ge 5 6 "4.19.0"'
    _t "kernel_ge 拒绝非版本串"  '! kernel_ge 5 6 "nonsense"'
    _t "ipset_exists 假名必假"   '! ipset_exists cw3-selftest-nonexistent'

    # 链式上游自动豁免: 只读扫描代理内核 outbound (Xray JSON / Mihomo YAML)
    printf '{"outbounds":[{"settings":{"address":"203.0.113.9","port":1}},{"settings":{"address":"192.168.1.5"}}]}' > "$BASE/chain.json"
    printf 'proxies:\n  - name: x\n    server: 198.51.100.7\n' > "$BASE/chain.yaml"
    _t "chain_exempt: JSON 出站地址" 'chain_exempt_ips "$BASE/chain.json" | grep -q "203.0.113.9"'
    _t "chain_exempt: YAML server"   'chain_exempt_ips "$BASE/chain.yaml" | grep -q "198.51.100.7"'
    _t "chain_exempt: 过滤私网地址"  '! chain_exempt_ips "$BASE/chain.json" | grep -q "192.168.1.5"'
    _t "chain_exempt: 关掉后不返回"  '! AUTO_CHAIN_EXEMPT=0 chain_exempt_ips "$BASE/chain.json" | grep -q "203.0.113.9"'

    # 临时 BASE
    BASE=$(mktemp -d)
    # 被 kill / 超时打断时也要清理 —— 原来只在正常收尾 rm -rf, 中断就永久残留 /tmp/tmp.XXXX
    trap 'rm -rf "$BASE" 2>/dev/null' EXIT
    RUNTIME="$BASE/runtime"; STATE="$BASE/state"; BACKUPS="$BASE/backups"
    GEN="$BASE/generated"; OUTDIR="$GEN/outbound"; LOGDIR="$BASE/logs"
    CONFDIR="$BASE/config"; RULES="$CONFDIR/rules.conf"; MAIN_CONF="$CONFDIR/main.conf"
    GEN_DNS_REAL="$GEN/dnsmasq-catmi-warp.conf"; GEN_DNS_LINK="$GEN/dnsmasq-link"
    RESOLV_STATE="$STATE/resolv.state"; ACCOUNT_JSON="$STATE/account.json"
    init_dirs

    # 规则 CRUD
    rule_add google.com warp >/dev/null 2>&1
    rule_add youtube.com warp >/dev/null 2>&1
    rule_add openai.com native >/dev/null 2>&1
    _t "rules count" '[[ $(rule_list | wc -l) -eq 3 ]]'
    rule_add google.com native >/dev/null 2>&1   # 覆盖
    _t "rule overwrite single" '[[ $(grep -c "^google.com|" "$RULES") -eq 1 ]]'
    _t "rule overwrite native" 'grep -q "^google.com|native|" "$RULES"'
    rule_set_enabled google.com 0 >/dev/null 2>&1
    _t "rule disable" 'grep -q "^google.com|native|0|" "$RULES"'
    _t "rule_count warp" '[[ $(rule_count warp) -eq 1 ]]'   # youtube(warp,1) + google(0禁) → 1
    rule_del openai.com >/dev/null 2>&1
    _t "rule del" '[[ $(rule_list | wc -l) -eq 2 ]]'

    # migrate_v2: V2 审计实测的两个缺陷 —— 非法行原样导入 / 落盘失败只导入一部分却写幂等标记。
    # 后者会让剩余规则**永久**不再导入 (标记已写), 是最难自查的一类静默数据丢失。
    cp -f "$RULES" "$BASE/rules.save"   # 本段会重写规则集, 后面的 dnsmasq 断言还要用上面的规则
    mkdir -p "$BASE/v2/config"
    printf 'good1.com|warp|1|\nbad/domain|warp|1|\nnoact.com|both|1|\ngood2.com|native|1|n\n' > "$BASE/v2/config/rules.conf"
    : > "$RULES"
    CATMI_V2_HOME="$BASE/v2" migrate_v2 >/dev/null 2>&1
    _t "migrate 只导入合法行"     '[[ $(rule_list | wc -l) -eq 2 ]]'
    _t "migrate 拦非法域名"       '! grep -q "bad/domain" "$RULES"'
    _t "migrate 拦非法 action"    '! grep -q "noact.com" "$RULES"'
    _t "migrate 保留 note 字段"   'grep -q "^good2.com|native|1|n$" "$RULES"'
    _t "migrate 成功才写标记"     '[[ -f "$STATE/v2-imported" ]]'
    _t "migrate 幂等"             'CATMI_V2_HOME="$BASE/v2" migrate_v2 >/dev/null 2>&1; [[ $(rule_list | wc -l) -eq 2 ]]'
    # 落盘失败注入: RUNTIME 指向不存在的目录 → cp 必失败 (root 也绕不过"目录不存在")
    rm -f "$STATE/v2-imported"; : > "$RULES"
    local _save_rt="$RUNTIME" _migrc=0; RUNTIME="$BASE/no-such-dir"
    CATMI_V2_HOME="$BASE/v2" migrate_v2 >/dev/null 2>&1 || _migrc=1
    RUNTIME="$_save_rt"
    _t "migrate 落盘失败返回非0"  '[[ $_migrc -eq 1 ]]'
    _t "migrate 落盘失败不写标记" '[[ ! -f "$STATE/v2-imported" ]]'
    _t "migrate 落盘失败不动规则" '[[ $(rule_list | wc -l) -eq 0 ]]'
    cp -f "$BASE/rules.save" "$RULES"; rm -f "$STATE/v2-imported"

    # dnsmasq conf (enabled warp: youtube 1 条)
    gen_dnsmasq_conf >/dev/null 2>&1
    _t "dnsmasq ipset line" 'grep -q "ipset=/youtube.com/cw3-warp4,cw3-warp6" "$GEN_DNS_REAL"'
    _t "dnsmasq ipset count" '[[ $(grep -c "ipset=" "$GEN_DNS_REAL") -eq 1 ]]'
    _t "dnsmasq native excluded" '! grep -q "native" "$GEN_DNS_REAL"'
    _t "dnsmasq conf no quotes" '[[ ! $(<"$GEN_DNS_REAL") == *\"* ]]'   # 引号污染会使 dnsmasq 拒启

    # main.conf 读回 (引号剥离回归 — V2 实测 bug; V3 附加新键读取回归)
    printf 'MARK=3\nUPSTREAMS="9.9.9.9 8.8.4.4"\nFORWARD=1\nSKIP_UIDS="998"\nEXCLUDE_SETS=""\nNATIVE_IPS="107.172.232.54"\n' > "$MAIN_CONF"
    init_dirs
    _t "conf quote strip" '[[ "$UPSTREAMS" == "9.9.9.9 8.8.4.4" ]]'
    _t "conf forward load" '[[ "$FORWARD" == "1" ]]'
    _t "conf mark load" '[[ "$MARK" == "3" ]]'
    # 双模式: gen_dnsmasq_conf 按模式选集合 (native→warp 集; warp→native 集)
    local _gsave="$_gt"
    _gt=0
    rm -f "$BASE/gd.conf" "$BASE/gd.link"
    # gen dns 断言需要确定性规则状态 (前面的 rule_* 测试改写过 google/youtube)
    printf 'google.com|warp|1|selftest\nbaidu.com|native|1|selftest\n' > "$RULES"
    DEFAULT_OUTBOUND_V4="native" DEFAULT_OUTBOUND_V6="native" UPSTREAMS="9.9.9.9" \
        GEN_DNS_REAL="$BASE/gd.conf" GEN_DNS_LINK="$BASE/gd.link" gen_dnsmasq_conf >/dev/null 2>&1
    grep -q "ipset=/google.com/cw3-warp4,cw3-warp6" "$BASE/gd.conf" 2>/dev/null \
        && _t "gen dns 全native" || FAIL "gen dns 全native"
    DEFAULT_OUTBOUND_V4="warp" DEFAULT_OUTBOUND_V6="warp"
    GEN_DNS_REAL="$BASE/gd.conf" GEN_DNS_LINK="$BASE/gd.link" gen_dnsmasq_conf >/dev/null 2>&1
    grep -q "ipset=/baidu.com/cw3-native4,cw3-native6" "$BASE/gd.conf" 2>/dev/null \
        && _t "gen dns 双栈" || FAIL "gen dns 双栈"
    if grep -q "cw3-warp4" "$BASE/gd.conf" 2>/dev/null; then
        FAIL "gen dns 双栈不应输出 warp 集"
    else
        _t "gen dns 双栈排除"
    fi
    DEFAULT_OUTBOUND_V4="native" DEFAULT_OUTBOUND_V6="warp"
    GEN_DNS_REAL="$BASE/gd.conf" GEN_DNS_LINK="$BASE/gd.link" gen_dnsmasq_conf >/dev/null 2>&1
    grep -q "ipset=/google.com/cw3-warp4$" "$BASE/gd.conf" 2>/dev/null \
        && _t "gen dns 仅v6补栈" || FAIL "gen dns 仅v6补栈"
    DEFAULT_OUTBOUND_V4="native" DEFAULT_OUTBOUND_V6="native"
    _gt="$_gsave"
    _t "conf skip_uids load" '[[ "$SKIP_UIDS" == "998" ]]'
    _t "conf native_ips load" '[[ "$NATIVE_IPS" == "107.172.232.54" ]]'

    # DNS 决策矩阵
    _t "dns: dnsmasq+local=reuse" '[[ $(dns_decision dnsmasq 1) == reuse ]]'
    _t "dns: dnsmasq+else=takeover" '[[ $(dns_decision dnsmasq 0) == takeover ]]'
    _t "dns: resolved=takeover" '[[ $(dns_decision resolved 0) == takeover ]]'
    _t "dns: free=takeover" '[[ $(dns_decision free 0) == takeover ]]'
    _t "dns: docker=reject" '[[ $(dns_decision docker 0) == reject ]]'
    _t "dns: other=reject" '[[ $(dns_decision other 1) == reject ]]'

    # 凭据解析 (mock, base64 '=' + 多行 Address)
    cat > "$BASE/mock.conf" <<'EOF'
[Interface]
PrivateKey = ABCdef123mock=
Address = 172.16.0.2/32, fd01:5ca1:ab1e:8a14:4f33:56a4:d159:4b81/128
MTU = 1420
[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = engage.cloudflareclient.com:2408
Reserved = 1,2,3
EOF
    CATMI_CRED_FILE="$BASE/mock.conf"
    parse_creds
    _t "parse privkey trailing =" '[[ "$PRIVKEY" == "ABCdef123mock=" ]]'
    _t "parse addr4" '[[ "$ADDR4" == "172.16.0.2/32" ]]'
    _t "parse addr6" '[[ "$ADDR6" == "fd01:5ca1:ab1e:8a14:4f33:56a4:d159:4b81/128" ]]'
    _t "parse reserved" '[[ "$RESERVED" == "1,2,3" ]]'
    # parse mtu: 解析出 conf 里的 1420; 但若有实际 warp 接口, MTU 以接口为准 (见 parse_creds)
    if [[ -r /sys/class/net/warp/mtu ]]; then
        _t "parse mtu (live iface wins)" '[[ "$WARP_MTU" == "$(cat /sys/class/net/warp/mtu)" ]]'
    else
        # 无实际接口时无从验证"实接口优先" —— 只确认解析出了非空值。
        # 这里**不能**断言 1420: 那是契约明令禁止的值, 固化它等于把 bug 当正确行为
        _t "parse mtu (parsed, non-empty)" '[[ -n "$WARP_MTU" ]]'
    fi

    # outbound 三片段 (mock 凭据)
    gen_outbound >/dev/null 2>&1
    _t "xray json + reserved" 'python3 -c "import json;d=json.load(open(\"$OUTDIR/xray-warp-outbound.json\"));assert d[\"settings\"][\"secretKey\"]==\"ABCdef123mock=\";assert d[\"settings\"][\"reserved\"]==[1,2,3]"'
    _t "mihomo yaml" 'grep -q "private-key: ABCdef123mock=" "$OUTDIR/mihomo-warp-proxy.yaml" && grep -q "reserved: \[1, 2, 3\]" "$OUTDIR/mihomo-warp-proxy.yaml"'
    _t "singbox json" 'python3 -c "import json;d=json.load(open(\"$OUTDIR/singbox-warp-outbound.json\"));assert d[\"endpoints\"][0][\"peers\"][0][\"reserved\"]==[1,2,3]"'

    # 注册响应解析 (mock)
    cat > "$ACCOUNT_JSON" <<'EOF'
{"id":"4f1399f3-3476-4a7a-8ec8-1234567890ab","token":"tok-abc","config":{"client_id":"dHYA","interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700:110:822d:5c1b:1a2b:3c4d:5e6f"}},"peers":[{"public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="}]}}
EOF
    eval "$(python3 - <<PY
import json, base64
d = json.load(open('$ACCOUNT_JSON'))
cfg = d['config']
print(f"W_ADDR4={cfg['interface']['addresses'].get('v4','')!r}")
print(f"W_RESERVED={','.join(str(b) for b in base64.b64decode(cfg['client_id']))!r}")
PY
)" 2>/dev/null
    _t "reg reserved" '[[ "$W_RESERVED" == "116,118,0" ]]'
    _t "reg addr4" '[[ "$W_ADDR4" == "172.16.0.2" ]]'

    # resolv state 写读
    echo "MANAGED=1" > "$RESOLV_STATE"
    echo "BACKUP=$BACKUPS/resolv.orig" >> "$RESOLV_STATE"
    # 原来是 `grep -qE '^BACKUP=' && _t "..." 'true' || _t "..." 'false'` ——
    # 断言的是**字面量** true/false, 同义反复, 没测任何生产代码。改成检查 state 结构完整。
    _t "resolv state 有备份记录" 'grep -qE "^BACKUP=" "$RESOLV_STATE"' ''

    # takeover/release 全周期 (mock RESOLV, 不碰真实文件)
    RESOLV="$BASE/resolv.mock"; echo "nameserver 1.1.1.1" > "$RESOLV"
    rm -f "$RESOLV_STATE" "$BACKUPS/resolv.orig"
    dns_takeover >/dev/null 2>&1
    _t "takeover switched to 127.0.0.1" 'grep -q "nameserver 127.0.0.1" "$RESOLV"'
    _t "takeover backed up orig" 'grep -q "nameserver 1.1.1.1" "$BACKUPS/resolv.orig"'
    _t "takeover state BACKUP path" 'grep -q "BACKUP=$BACKUPS/resolv.pre-" "$RESOLV_STATE"'
    dns_release >/dev/null 2>&1
    _t "release restored orig" 'grep -q "nameserver 1.1.1.1" "$RESOLV"'
    _t "release cleared state" '[[ ! -s "$RESOLV_STATE" ]]'
    # 原件永不覆盖 (再接管不改 orig)
    echo "nameserver 5.5.5.5" > "$RESOLV"
    dns_takeover >/dev/null 2>&1
    _t "orig never overwritten" 'grep -q "nameserver 1.1.1.1" "$BACKUPS/resolv.orig"'
    _t "2nd release restores" 'dns_release >/dev/null 2>&1; grep -q "nameserver 5.5.5.5" "$RESOLV"'

    # V3: symlink 感知 (mock: resolv.conf 为符号链接)
    local sltgt="$BASE/real-resolv.conf"; echo "nameserver 7.7.7.7" > "$sltgt"
    ln -sf "$sltgt" "$RESOLV"
    rm -f "$RESOLV_STATE"
    dns_takeover >/dev/null 2>&1
    _t "symlink detected in state" 'grep -q "RESOLV_TYPE=symlink" "$RESOLV_STATE" && grep -q "LINK_TARGET=$sltgt" "$RESOLV_STATE"'
    _t "symlink replaced by plain file" '[[ ! -L "$RESOLV" ]] && grep -q "nameserver 127.0.0.1" "$RESOLV"'
    dns_release >/dev/null 2>&1
    _t "symlink restored on release" '[[ -L "$RESOLV" ]] && [[ "$(readlink "$RESOLV")" == "$sltgt" ]]'
    _t "symlink target untouched" 'grep -q "nameserver 7.7.7.7" "$sltgt"'
    RESOLV="$BASE/resolv.mock"; echo "nameserver 1.1.1.1" > "$RESOLV"

    # V3: V2 规则只读导入 (V2 原件零改动)
    mkdir -p "$BASE/v2mock/config"
    printf "# v2\nexample.org|warp|1|\nexample.net|native|1|\n" > "$BASE/v2mock/config/rules.conf"
    : > "$RULES"; rm -f "$STATE/v2-imported"
    CATMI_V2_HOME="$BASE/v2mock" migrate_v2 >/dev/null 2>&1
    _t "v2 rules imported" '[[ $(rule_list | wc -l) -eq 2 ]]'
    _t "v2 import idempotent marker" '[[ -f "$STATE/v2-imported" ]]'
    unset CATMI_V2_HOME

    # V3: main.conf 含新键
    _t "main.conf has SKIP_UIDS" 'grep -q "^SKIP_UIDS=" "$MAIN_CONF"'
    _t "main.conf has EXCLUDE_SETS" 'grep -q "^EXCLUDE_SETS=" "$MAIN_CONF"'
    _t "main.conf has NATIVE_IPS" 'grep -q "^NATIVE_IPS=" "$MAIN_CONF"'
    RESOLV="/etc/resolv.conf"

    # ── 状态阶段 (读真实系统状态; 只读不写) ──
    # A3 用故障注入实证: 上面全部是**纯函数级**断言, 对 mangle 顺序 / ip rule / ipset / dnsmasq
    # 全盲 —— 把下面这些故障注入进去, selftest 照样打印 56/56 全绿:
    #   a) native 豁免块顺序改坏  b) ip rule 守卫改永假
    #   c) AAAA 预热改为不做      d) dnsmasq 重试环存活校验删除
    # 这一层专门补上"分流到底有没有真的部署对"。
    local _rh="${CATMI_WARP_HOME:-/etc/catmi/warp3}"
    local _rap="$_rh/state/applied"
    if [[ -f "$_rap" ]]; then
        # 模式必须从**真实 config 文件**读 —— selftest 前面测 gen_dnsmasq_conf 时把
        # DEFAULT_OUTBOUND_V4/V6 改成 "native" 当 mock 且没恢复, 直接判变量会让
        # 下面 v4/v6 的顺序断言**恒被跳过**(静默失效, 等于没写)。
        local _rm4 _rm6
        _rm4=$(grep -E '^DEFAULT_OUTBOUND_V4=' "$_rh/config/main.conf" 2>/dev/null | cut -d= -f2)
        _rm6=$(grep -E '^DEFAULT_OUTBOUND_V6=' "$_rh/config/main.conf" 2>/dev/null | cut -d= -f2)
        # ① ip rule 不允许重复优先级 (重复 → 顺序不确定 → 行为飘忽)
        local _d4 _d6
        _d4=$(ip -4 rule show 2>/dev/null | awk '{print $1}' | sort | uniq -d | tr '\n' ' ')
        _d6=$(ip -6 rule show 2>/dev/null | awk '{print $1}' | sort | uniq -d | tr '\n' ' ')
        _t "state: ip -4 rule 无重复优先级" '[[ -z "$_d4" ]]'
        _t "state: ip -6 rule 无重复优先级" '[[ -z "$_d6" ]]'
        # ② 已标流量保护必须最前 (显式出站不被覆盖的根基)
        _t "state: 已标流量首条即 RETURN" 'iptables -t mangle -S CATMI3-OUT 2>/dev/null | grep "^-A" | head -1 | grep -q "mark ! --mark 0x0 -j RETURN"'
        # ③ 入站零影响: PREROUTING 不得有本模块规则
        _t "state: PREROUTING 无本模块规则" '! iptables -t mangle -S PREROUTING 2>/dev/null | grep -q CATMI3'
        _t "state: v6 PREROUTING 无本模块规则" '! ip6tables -t mangle -S PREROUTING 2>/dev/null | grep -q CATMI3'
        # ④ dnsmasq 必须在跑 (域名分流靠它填 ipset)
        _t "state: dnsmasq 运行中" 'systemctl is-active --quiet dnsmasq'
        # ⑤ v6 默认 warp 时: 兜底 MARK 必须排在 native6 覆盖**之前**, 顺序反了豁免就失效
        if [[ "$_rm6" == "warp" ]]; then
            local _m3 _mn6
            _m3=$(ip6tables -t mangle -S CATMI3-OUT 2>/dev/null | grep -n 'MARK --set-xmark 0x3' | head -1 | cut -d: -f1)
            _mn6=$(ip6tables -t mangle -S CATMI3-OUT 2>/dev/null | grep -n 'match-set cw3-native6 dst -j MARK' | head -1 | cut -d: -f1)
            _t "state: v6 native6 覆盖在兜底 MARK 之后" '[[ -n "$_mn6" && -n "$_m3" && "$_mn6" -gt "$_m3" ]]'
        fi
        # ⑥ v4 默认 warp 时: native4 豁免必须排在兜底打标**之前** (v4 靠 RETURN 实现豁免)
        if [[ "$_rm4" == "warp" ]]; then
            local _r4 _k3
            _r4=$(iptables -t mangle -S CATMI3-OUT 2>/dev/null | grep -n 'match-set cw3-native4 dst -j RETURN' | head -1 | cut -d: -f1)
            _k3=$(iptables -t mangle -S CATMI3-OUT 2>/dev/null | grep -n 'MARK --set-xmark 0x3' | head -1 | cut -d: -f1)
            _t "state: v4 native4 豁免在兜底打标之前" '[[ -n "$_r4" && -n "$_k3" && "$_r4" -lt "$_k3" ]]'
        fi
        # ⑦ cw3 表必须有默认路由 (没有 = 打了标也没处去)
        _t "state: cw3 表有默认路由" 'ip -4 route show table cw3 2>/dev/null | grep -q default'
        # ⑧ ipset 存在性 —— 「分流有没有数据可匹配」是核心状态, 但原来 9 条断言一条都没碰它。
        # V2 实测: `ipset destroy cw3-warp4` 与 `ipset flush cw3-native4` 都是 65/65 全绿,
        # 而后者是真功能故障 (native 例外集合被擦空 → 该走原生的域名实际走 WARP)。
        local _is
        for _is in cw3-warp4 cw3-warp6 cw3-native4 cw3-native6; do
            _t "state: ipset $_is 存在" "ipset list $_is >/dev/null 2>&1"
        done
        # ⑨ 当前模式下"该有条目"的例外集合不能是空的 (只看应存在的那一侧)
        if [[ "$_rm4" == "warp" ]] || [[ "$_rm6" == "warp" ]]; then
            # 判据必须读**真机**的规则文件: $RULES 在 selftest 里指向沙箱, 而下面断言查的是
            # 真机 ipset —— 两套数据源混用会让"机器上没有 native 规则"的正确部署误报 FAIL
            # (RN 2026-09-15 重建后 rules.conf 为空, 就踩到了这个假 FAIL)。
            if awk -F'|' '$2=="native" && $3=="1"{c++} END{exit !(c>0)}' "$_rh/config/rules.conf" 2>/dev/null; then
                _t "state: native 例外集合非空" \
                   '[[ $(ipset list cw3-native4 2>/dev/null | tail -n +9 | wc -l) -gt 0 || $(ipset list cw3-native6 2>/dev/null | tail -n +9 | wc -l) -gt 0 ]]'
            fi
        fi
        if [[ "$_rm4" == "native" ]] || [[ "$_rm6" == "native" ]]; then
            if awk -F'|' '$2=="warp" && $3=="1"{c++} END{exit !(c>0)}' "$_rh/config/rules.conf" 2>/dev/null; then
                _t "state: warp 例外集合非空" \
                   '[[ $(ipset list cw3-warp4 2>/dev/null | tail -n +9 | wc -l) -gt 0 || $(ipset list cw3-warp6 2>/dev/null | tail -n +9 | wc -l) -gt 0 ]]'
            fi
        fi
    else
        # 状态层被跳过时必须说一声 —— 否则 56 项 vs 65 项 无法区分,
        # "全绿"会被误读成"已部署且正确", 实际是"压根没检查"。
        echo "  注: 分流未部署 ($_rap 不存在), 状态阶段已跳过 — 本次只跑了纯函数断言" >&2
    fi

    rm -rf "$BASE"
    echo ""
    if ((failn == 0)); then ok "selftest 全部通过 ($pass 项)"; return 0; fi
    err "selftest 失败 $failn / $pass 项"; return 1
}

# ============================================================
# 菜单
# ============================================================
# ============================================================
# Catmiup 面板 UI — 品牌小猫 + Dashboard + 分组菜单
#   首页零网络请求 (全本地状态读取) · 无色可读 · 80 列适配 · CJK 值不参与右边框对齐
# ============================================================

# --- 终端能力 (每帧调用, 零依赖: tput 可缺省) ---
# 清屏 —— 原脚本 0 个清屏序列(ANSI 里 2J/3J/H 全无), 每次重画都把 ~60 行面板
# **追加**到下面: 24 行 SSH 窗口首屏只看得到下半截, 逛两三个菜单就是"面板瀑布"。
ui_clear() {
    # 非 tty / TERM=dumb 时不发 ANSI (降级模式仍然可读)
    [[ -t 1 && "${TERM:-}" != "dumb" ]] || return 0
    printf '\033[H\033[2J'
}

ui_init() {
    ui_clear
    UI_COLS=${COLUMNS:-$(tput cols 2>/dev/null)}
    [[ "$UI_COLS" =~ ^[0-9]+$ ]] || UI_COLS=80
    ((UI_COLS < 60)) && UI_COLS=60
    UI_COLOR=0
    [[ -t 1 && "${TERM:-}" != "dumb" && -z "${NO_COLOR:-}" ]] && UI_COLOR=1
    [[ "${UI_FORCE_COLOR:-}" == "1" ]] && UI_COLOR=1
    UI_ASCII=0
    [[ "${UI_ASCII_FORCE:-}" == "1" ]] && UI_ASCII=1
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *UTF-8*|*utf8*) : ;;
        *) UI_ASCII=1 ;;
    esac
    if [[ "$UI_ASCII" == "1" ]]; then
        UI_H="-"; UI_V="|"; UI_TL="+"; UI_BL="+"; UI_DEQ="="
        UI_OK="*"; UI_WARN="!"; UI_FAIL="x"; UI_NA="o"; UI_ARROW="->"; UI_RET="[0]"
    else
        UI_H="─"; UI_V="│"; UI_TL="┌"; UI_TR="┐"; UI_BL="└"; UI_BR="┘"; UI_DEQ="═"
        UI_OK="●"; UI_WARN="!"; UI_FAIL="✗"; UI_NA="○"; UI_ARROW="→"; UI_RET="[0]"
    fi
    # 行内颜色变量 (真实 ESC 字符; 交互循环中禁止 stdin 着色器 — $() 会偷吃用户按键)
    if ((UI_COLOR)); then
        KC=$(printf "$C"); KM=$(printf "$M"); KG=$(printf "$G"); KY=$(printf "$Y"); KR=$(printf "$R"); KN=$(printf "$N")
    else
        KC=""; KM=""; KG=""; KY=""; KR=""; KN=""
    fi
}
cl()  { if ((UI_COLOR)); then printf '%b' "${C}$*${N}"; else printf '%s' "$*"; fi; printf '\n'; }
cm()  { if ((UI_COLOR)); then printf '%b' "${M}$*${N}"; else printf '%s' "$*"; fi; }   # 参数级(内联取值)
cg()  { if ((UI_COLOR)); then printf '%b' "${G}$*${N}"; else printf '%s' "$*"; fi; printf '\n'; }
cy()  { if ((UI_COLOR)); then printf '%b' "${Y}$*${N}"; else printf '%s' "$*"; fi; printf '\n'; }
cr()  { if ((UI_COLOR)); then printf '%b' "${R}$*${N}"; else printf '%s' "$*"; fi; printf '\n'; }
# 管道着色器: ... | ui_pc C   (C/G/Y/M/R = 颜色宏名; UI_COLOR=0 时原样输出)
ui_pc() {
    local data col="$1"
    data=$(cat)
    if ((UI_COLOR)); then printf '%b' "${!col}${data}${N}\n"; else printf '%s\n' "$data"; fi
}
# 状态点: 字符本身表义 (● ok / ! warn / ✗ fail / ○ 未知), 颜色只是增强
ui_dot() {
    case "$1" in
        ok)   ((UI_COLOR)) && printf '%b' "${G}${UI_OK}${N}" || printf '%s' "$UI_OK" ;;
        warn) ((UI_COLOR)) && printf '%b' "${Y}${UI_WARN}${N}" || printf '%s' "$UI_WARN" ;;
        fail) ((UI_COLOR)) && printf '%b' "${R}${UI_FAIL}${N}" || printf '%s' "$UI_FAIL" ;;
        *)    printf '%s' "$UI_NA" ;;
    esac
}
ui_dispw() { # 显示宽度: 多字节字符(CJK)计 2 列
    local str="$1" w=0 i ch
    for ((i = 0; i < ${#str}; i++)); do
        ch="${str:i:1}"
        (( $(LC_ALL=C printf '%s' "$ch" | wc -c) > 1 )) && ((w += 2)) || ((w += 1))
    done
    printf '%s' "$w"
}
ui_hline() { local f; printf -v f '%*s' "${1:-60}" ''; printf '  %s
' "${f// /$UI_H}"; }
ui_dline() { local f; printf -v f '%*s' "${1:-60}" ''; printf '  %s
' "${f// /$UI_DEQ}"; }
ui_pause() { printf "  ── 回车返回 ──" >&2; local _; read -t 120 -r _ || true; printf '\n' >&2; }
# 菜单输入: 超时自动退出 (SSH 断线后不留孤儿进程占用 flock; ui_input 超时视为空)
ui_read() { if read -t "${UI_TMO:-900}" -r "$@"; then return 0; else printf '  (输入空闲超时, 自动退出)\n' >&2; exit 0; fi; }
ui_input() { if read -t "${UI_TMO:-900}" -r "$@"; then return 0; else printf '' >&2; return 1; fi; }

# --- 品牌头: 小猫 (heredoc 单引号, 禁 shell 解释) + 标题框 ---
ui_banner() {
    cat <<'CATMUP'
                        |\__/,|   (\
                      _.|o o  |_   ) )
CATMUP
    local title="Catmiup 面板 v$VERSION"
    local disp w=34 pad pad2 fill
    disp=$(ui_dispw "$title")
    pad=$(( (w - disp) / 2 )); ((pad < 1)) && pad=1
    pad2=$(( w - pad - disp ))
    printf -v fill '%*s' "$w" ''
    fill="${fill// /$UI_H}"
    printf '        %s%s%s%s%s\n' "$KC" "$UI_TL" "$fill" "$UI_TR" "$KN"
    printf '        %s%s%*s%s%*s%s%s\n' "$KM" "$UI_V" "$pad" '' "$title" "$pad2" '' "$UI_V" "$KN"
    printf '        %s%s%s%s%s\n' "$KC" "$UI_BL" "$fill" "$UI_BR" "$KN"
}

# --- Dashboard 数据 (全本地: ip/wg/systemctl/iptables/ipset, 零 curl/dig) ---
dash_data() {
    D_ON=0; D_SRC="-"; D_SVC="-"; D_HS="-"; D_MTU="-"; D_EP="-"; D_IFACE="-"
    if detect_iface; then
        D_ON=1; D_IFACE="$IFACE"; D_SRC=$(warp_source)
        local s
        for s in wg-quick@warp warp-go warp-svc; do
            systemctl is-active "$s" >/dev/null 2>&1 && { D_SVC="$s (running)"; break; }
        done
        [[ "$D_SVC" == "-" ]] && D_SVC="unknown"
        local hsv; hsv=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')
        if [[ -n "$hsv" && "$hsv" != "0" ]]; then
            D_HS="$(( $(date +%s) - hsv ))s ago"
        else
            D_HS="用户态 (egress 判定)"
        fi
        # wg show 无 mtu 子命令 — 读实际接口值 (conf 里的可能是遗留旧值, 如 fscarmen 的 1420)
        local wm; wm=$(ip link show "$IFACE" 2>/dev/null | grep -oE 'mtu [0-9]+' | awk '{print $2}')
        [[ -n "$wm" ]] && D_MTU="$wm"
        parse_creds >/dev/null 2>&1 && { D_EP="$ENDPOINT"; [[ "$D_MTU" == "-" ]] && D_MTU="${WARP_MTU:-1280}"; }
    else
        D_SRC="未安装"; D_SVC="stopped"
    fi
    D_P4=$(family_probe 4); D_P6=$(family_probe 6)
    # 显式出站保护状态
    if [[ -f "$APPLIED_FLAG" ]]; then
        iptables -t mangle -S CATMI3-OUT 2>/dev/null | grep -q "mark ! --mark" && D_PROT=ok || D_PROT=fail
    else
        D_PROT=na
    fi
    # 规则统计 (enabled 按 action 分, disabled 单列)
    D_NW=$(awk -F'|' '$3==1 && $2=="warp"' <(rule_list) | wc -l)
    D_NN=$(awk -F'|' '$3==1 && $2=="native"' <(rule_list) | wc -l)
    D_ND=$(awk -F'|' '$3!=1' <(rule_list) | wc -l)
    D_NT=$((D_NW + D_NN + D_ND))
    D_FWD=$([[ "$FORWARD" == "1" ]] && echo ON || echo OFF)
    iptables -t mangle -L PREROUTING 2>/dev/null | grep -q CATMI3-FWD && D_PRE=ON || D_PRE=OFF
    D_APPLIED=$([[ -f "$APPLIED_FLAG" ]] && echo YES || echo NO)
    D_DEF4=$([[ "$DEFAULT_OUTBOUND_V4" == "warp" ]] && echo WARP || echo Native)
    D_DEF6=$([[ "$DEFAULT_OUTBOUND_V6" == "warp" ]] && echo WARP || echo Native)
    D_STK=$(stack_mode)
    D_DNS=$(detect_dns53)
    # 「IP 名单已就绪」不能只看集合**存不存在** —— 集合在但 0 成员时, 分流其实没有数据可匹配
    # (实测出现过 cw3-warp4 0 条却显示绿点)。按当前模式检查"应该有条目"的那个例外集合。
    D_IPSET=na
    if [[ -f "$APPLIED_FLAG" ]]; then
        D_IPSET=ok
        ipset_exists cw3-warp4 || D_IPSET=fail
        if [[ "$D_IPSET" == "ok" ]] \
           && { [[ "$DEFAULT_OUTBOUND_V4" == "warp" ]] || [[ "$DEFAULT_OUTBOUND_V6" == "warp" ]]; } \
           && awk -F'|' '$2=="native" && $3=="1"{c++} END{exit !(c>0)}' "$RULES" 2>/dev/null; then
            # 有 native 规则 + 默认走 WARP → native 例外集合必须有成员, 否则规则匹配不到
            # 必须 tail -n +9 跳过 ipset 的 8 行头部 (Name:/Type:/Number of entries:…),
            # 否则 `grep -cE ':'` 恒等于 8, 守卫永远不触发, 集合 0 成员也显示"已就绪"。
            if [[ $(ipset list cw3-native4 2>/dev/null | tail -n +9 | grep -cE '^[0-9]') -eq 0 ]] \
               && [[ $(ipset list cw3-native6 2>/dev/null | tail -n +9 | grep -cE ':') -eq 0 ]]; then
                D_IPSET=fail
            fi
        fi
    fi
    # 语义检查: 0x3→cw3 规则存在即 ok (规则优先级是动态的, 固定 prio 锚点会误报 MISSING)
    D_RULE=$([[ -f "$APPLIED_FLAG" ]] && { ip -4 rule show 2>/dev/null | grep -qE "fwmark 0x$MARK (table|lookup) cw3" && echo ok || echo fail; } || echo na)
    # 最近一次 egress 探测缓存 (doctor 写入, 1h 内有效); ipv6 值含空格/箭头, 不进 eval
    D_CTS=0
    if [[ -s "$STATE/ui.state" ]]; then
        eval "$(grep -E '^(ipv4|egress_ok|ts|ip4|ip6)=' "$STATE/ui.state" | sed 's/^/D_/')" 2>/dev/null
        D_CTS=${D_ts:-0}
    fi
}

# 分族渲染: family_probe 语义 ${UI_ARROW} 面板语义
dash_fam() { # <probe输出> <族>
    local v="${1%% *}"; local age=""
    # [R] 只重绘、**不重新探测** —— 原来写"按R刷新"是假的。真实探测入口是 [4]→[1] 健康检查。
    if ((D_CTS > 0)); then
        local dt=$(( $(date +%s) - D_CTS ))
        ((dt < 3600)) && age=" (实测于 ${dt}s 前)" || age=" (实测超 1h, 按 [4]→[1] 复测)"
    else
        age=" (未实测, 按 [4]→[1] 健康检查)"
    fi
    case "$v" in
        OK)        printf '%s WARP'   "$(ui_dot ok)" ;;
        fallback)  printf '%s Native' "$(ui_dot warn)" ;;
        Native\(*)
            local dv="${v#Native(}"; dv="${dv%%)*}"
            printf '%s Native(%s)' "$(ui_dot warn)" "$dv" ;;
        *)
            if [[ "$1" == *"禁用"* ]]; then
                printf '%s N/A(内核禁用)' "$(ui_dot warn)"
            else
                printf '%s 不可用' "$(ui_dot fail)"
            fi ;;
    esac
    printf '%s' "$age"
}

dash_render() {
    # 注意: 这里**不能**再调 ui_init —— 一帧里 menu_main 会依次调 dash_render 与 ui_guide,
    # 两个都清屏的话, 仪表盘刚画完就被第二遍清屏擦掉: 用户看到的就是"面板闪一下就没了"
    # (实测复现: 2 帧出现 4 次 ESC[2J, 第 1 屏只有仪表盘、第 2 屏只有菜单)。
    # 清屏改由每帧开头统一做一次 (menu_main 循环第一行)。
    dash_data
    # 框宽必须**跟着终端单调增长**: 原来 UI_COLS>=100 时反而 W=48 (比 84 列的 76 还窄),
    # 宽终端上就出现"框顶比内容短一大截"(实测 120 列时框顶 51 列 vs 内容行 76 列)的破框。
    # 封顶 76 是因为内容区最宽的行就是 76 列。
    local W=$((UI_COLS - 4))
    ((W > 76)) && W=76
    ((W < 40)) && W=40
    echo ""
    ui_banner "$W"
    ui_dline "$((W + 2))"
    echo ""
    cl "  WARP 状态 (Cloudflare 全球加速网络)"; echo ""
    local fill; printf -v fill '%*s' "$W" ''; fill="${fill// /$UI_H}"
    printf '  %s%s%s%s\n' "$KC" "$UI_TL" "$fill" "$KN"
    if ((D_ON == 1)); then
        printf '  %s 连接状态  %s 在线 — 已连上 Cloudflare\n' "$UI_V" "$(ui_dot ok)"
        printf '  %s 实现方式  %s\n' "$UI_V" "$D_SRC"
        printf '  %s 接口/服务 %-10s %s\n' "$UI_V" "$D_IFACE" "$D_SVC"
        printf '  %s 出口 IPv4 %b %s  出口 IPv6 %b %s\n' "$UI_V" "$(dash_fam "$D_P4" 4)" "${D_ip4:+[$D_ip4]}" "$(dash_fam "$D_P6" 6)" "${D_ip6:+[$D_ip6]}"
        printf '  %s 通道心跳  %-14s 越新越健康\n' "$UI_V" "$D_HS"
        printf '  %s 单包上限  %-14s 安全值, 兼容一切网络\n' "$UI_V" "$D_MTU"
        printf '  %s 对接服务器 %s\n' "$UI_V" "${D_EP:--}"
    else
        printf '  %s 连接状态  %s 未运行\n' "$UI_V" "$(ui_dot fail)"
    fi
    printf '  %s%s%s%s\n' "$KC" "$UI_BL" "$fill" "$KN"
    echo ""
    if ((D_ON == 0)); then
        cy "  ${UI_WARN} WARP 未运行 — 下一步: [1] WARP 管理 → 安装/启动"
        echo ""
    fi
    cl "  出口策略 (你的流量走哪里)"; echo ""
    printf '  %s%s%s%s\n' "$KC" "$UI_TL" "$fill" "$KN"
    local d4 d6
    [[ "$D_DEF4" == "WARP" ]] && d4=$(ui_dot ok) || d4=$(ui_dot na)
    [[ "$D_DEF6" == "WARP" ]] && d6=$(ui_dot ok) || d6=$(ui_dot na)
    case "$D_PROT" in
        ok)   printf '  %s 保护模式  %s 已开启 (脚本正在管理出站)\n' "$UI_V" "$(ui_dot ok)" ;;
        fail) printf '  %s 保护模式  %s 有风险! 请按 [6]→[1] 应用分流\n' "$UI_V" "$(ui_dot fail)" ;;
        *)    printf '  %s 保护模式  %s 未部署 — 按 [6]→[1] 应用分流\n' "$UI_V" "$(ui_dot na)" ;;
    esac
    printf '  %s 默认出口  v4 %s %-7s v6 %s %s\n' "$UI_V" "$d4" "$D_DEF4" "$d6" "$D_DEF6"
    printf '  %s 栈模式    %s %s\n' "$UI_V" "$( [[ "$D_STK" == "无 (全 Native)" ]] && echo "$(ui_dot na)" || echo "$(ui_dot ok)" )" "$D_STK"
    printf '  %s 分流规则  走WARP %s 条 / 保持原生 %s 条\n' "$UI_V" "$D_NW" "$D_NN"
    printf '  %s 进站保护  %s (你服务器的入站不受影响)\n' "$UI_V" "$( [[ "$D_PRE" == "OFF" ]] && printf '%s 开启' "$(ui_dot ok)" || printf '%s 关闭' "$(ui_dot warn)" )"
    case "$D_APPLIED" in
        YES) printf '  %s 策略状态  %s 已生效 (改动已应用)\n' "$UI_V" "$(ui_dot ok)" ;;
        NO)  printf '  %s 策略状态  %s 有改动未生效 — 按 [6] 应用\n' "$UI_V" "$(ui_dot warn)" ;;
        *)   printf '  %s 策略状态  %s\n' "$UI_V" "$D_APPLIED" ;;
    esac
    printf '  %s%s%s%s\n' "$KC" "$UI_BL" "$fill" "$KN"
    echo ""
    cl "  系统服务"; echo ""
    printf '  %s%s%s%s\n' "$KC" "$UI_TL" "$fill" "$KN"
    if systemctl is-active dnsmasq >/dev/null 2>&1; then
        printf '  %s DNS 解析  %s dnsmasq 运行中\n' "$UI_V" "$(ui_dot ok)"
    else
        printf '  %s DNS 解析  %s dnsmasq 未运行\n' "$UI_V" "$(ui_dot na)"
    fi
    case "$D_IPSET" in
        ok)   printf '  %s IP 名单   %s 已就绪 (网站分流的数据)\n' "$UI_V" "$(ui_dot ok)" ;;
        fail) printf '  %s IP 名单   %s 未生效 — 按 [6] 应用分流\n' "$UI_V" "$(ui_dot fail)" ;;
        *)    printf '  %s IP 名单   %s 未部署\n' "$UI_V" "$(ui_dot na)" ;;
    esac
    case "$D_RULE" in
        ok)   printf '  %s 路由规则  %s 已生效\n' "$UI_V" "$(ui_dot ok)" ;;
        fail) printf '  %s 路由规则  %s 未生效 — 按 [6] 应用分流\n' "$UI_V" "$(ui_dot fail)" ;;
        *)    printf '  %s 路由规则  %s 未部署\n' "$UI_V" "$(ui_dot na)" ;;
    esac
    printf '  %s%s%s%s\n' "$KC" "$UI_BL" "$fill" "$KN"
    echo ""
    cy "  第一次使用? 三步上手:"
    # 首页的 [6] 是"系统维护", 应用分流在 [6]→[1]; [3] 是 WARP 管理, 网络诊断是 [4]。
    # 原来写反了, 小白照着按会进错页。
    cg "    [1] 装/查 WARP  →  [2] 添加要加速的网站  →  [6]→[1] 应用分流"
    cg "  首页为本地快照(零请求); 实测连通性用 [4] 网络诊断"
    ui_hline "$((W + 2))"
}

# --- 子菜单页头 ---
ui_page() { # <标题>
    ui_init
    echo ""
    cl "  ── $1 ──"
    echo ""
}

# 危险操作确认: 说明"会改什么/影响什么/可否恢复", 输入 YES 确认 (默认取消)
# 交互确认的**统一入口**。原实现直接 `read </dev/tty`:
#   ① 没有 tty 时 (面板 run_remote / CI / ssh 重定向) 立刻失败 -> 用户明明想执行却被"已取消";
#   ② 有 tty 但没人按键时会**一直阻塞**, 而调用它的 default/newip/endpoint 都是**先拿了 flock** 的
#      -> 锁一直被占着 -> 下一次运行只看到"另一个 catmi-warp 实例正在执行变更操作"
#      (2026-09-15 事故的连锁症状: 残留 lock 的真因不是文件没删, 而是有人在等输入)。
# 现在: --yes/ASSUME_YES=1 直接过; 无 tty 时按 $2 (默认 0=拒绝, 1=继续) 决定; 有 tty 才真的问。
confirm_or_abort() { # <提示语> [无 tty 时: 0=拒绝(默认) 1=继续]
    local prompt="$1" ntty="${2:-0}" yn
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        info "已按 --yes / ASSUME_YES=1 跳过确认"
        return 0
    fi
    if ! { true </dev/tty; } 2>/dev/null; then
        if [[ "$ntty" == "1" ]]; then
            info "非交互环境 (无 tty): 跳过确认直接执行 — $prompt"
            return 0
        fi
        err "非交互环境 (无 tty): 这一步需要确认 — 请加 --yes 重跑 (或设 ASSUME_YES=1)"
        return 1
    fi
    printf "  %s 输入 YES 确认 (回车=取消): " "$prompt" >&2
    read -r yn </dev/tty 2>/dev/null || yn=""
    [[ "${yn,,}" == "yes" ]] || { echo "  已取消" >&2; return 1; }
    return 0
}

ui_danger() { # <标题> <说明多行文本, 用 | 分行>
    local title="$1" body="$2" line yn
    echo ""
    cy "  ${UI_WARN} $title"
    printf '%s\n' "${body//|/$'\n'}" | sed 's/^/    /'
    printf "  输入 YES 确认 (回车=取消): " >&2
    read -r yn </dev/tty 2>/dev/null || yn=""
    [[ "${yn,,}" == "yes" ]]
}

# 下一步建议引擎: 基于 dash_data 的状态给出人话指引 (首页与快速设置共用)
ui_guide() {
    # 同样不在这里清屏; dash_data 也复用 dash_render 已取好的结果 (原来是同一帧取两遍)
    
    local tips=()
    if ((D_ON == 0)); then
        tips+=("WARP 未安装或未运行 ${UI_ARROW} [1] 快速设置 ${UI_ARROW} [1] 安装 / 准备 WARP")
    elif [[ -f "$APPLIED_FLAG" ]]; then
        if ((D_NT == 0)); then
            tips+=("分流已应用, 但还没有网站规则 ${UI_ARROW} [1] 快速设置 ${UI_ARROW} [2] 添加网站")
        else
            tips+=("${UI_OK} 配置正常: ${D_STK} (v4 ${D_DEF4}/v6 ${D_DEF6})")
            tips+=("${UI_OK} 分流 ${D_NW} WARP / ${D_NN} Native, Forward ${D_FWD}")
            if [[ "$D_P4" == OK* && "$D_P6" != OK* ]]; then
                tips+=("IPv6 出站走原生通道 (WARP 的 v6 未通) ${UI_ARROW} 见 [4] 网络诊断")
            fi
        fi
    elif ((D_NT > 0)); then
        tips+=("网站规则已保存但尚未应用 ${UI_ARROW} [1] 快速设置 ${UI_ARROW} [5] 应用分流")
    else
        tips+=("WARP 已就绪 ${UI_ARROW} [1] 快速设置 ${UI_ARROW} [2] 添加网站, 再 [5] 应用分流")
    fi
    echo ""
    cl "  下一步建议"
    local t
    for t in "${tips[@]}"; do
        printf '  %s %s\n' "$(cm "$UI_ARROW")" "$t"
    done
}

# 添加网站向导: 域名 ${UI_ARROW} 选择出口 ${UI_ARROW} 保存 ${UI_ARROW} 下一步 (保存≠应用, 必须讲清楚)
ui_add_wizard() { # <默认出口 warp|native|空=询问>
    local want="$1" d a
    printf "  请输入域名 (例: github.com): " >&2
    ui_input d
    [[ -z "$d" ]] && { echo "  已取消 (未输入域名)" >&2; return 1; }
    if [[ -z "$want" ]]; then
        echo ""
        echo "  这个网站应该:"
        echo "    [1] 通过 WARP    使用 WARP 作为出口"
        echo "    [2] 使用 Native  使用服务器原本的网络出口"
        echo "    [0] 取消"
        printf "  选择: " >&2
        ui_read a
        case "$a" in
            1) want="warp" ;;
            2) want="native" ;;
            *) echo "  已取消" >&2; return 1 ;;
        esac
    fi
    echo ""
    rule_add "$d" "$want" || return 1
    echo ""
    cg "  ✓ 已保存: $d ${UI_ARROW} $want"
    echo "  注意: 规则已保存到配置, 但还没有应用到系统。"
    echo "  (保存 = 改配置文件; 应用 = 部署到 Linux 网络; 两者不是一回事)"
    echo ""
    local nx
    printf "  下一步: [1] 立即应用  [2] 继续添加  [0] 返回: " >&2
    ui_read nx
    case "$nx" in
        1) apply; ui_pause ;;
        2) ui_add_wizard "$want" ;;
        *) return 0 ;;
    esac
}

# [1.9] 新手一键配置: 几个问题 → 自动完成 安装+出口模式+网站+应用+测试 (每步先说明)
ui_quicksetup() {
    echo "  ── 新手一键配置 ──"
    echo "  将按顺序: 检查 WARP → 设定出口模式 → 添加网站 → 应用 → 测试。"
    echo "  每一步都会先说明要做什么; 随时可以取消; 已完成的不会重复做。"
    echo ""
    dash_data
    local yn
    # ① WARP
    if ((D_ON == 0)); then
        echo "  [1/5] WARP 未安装。现在安装 (自动复用已有凭据, 不重复注册)。"
        printf "        继续? [Y/n]: " >&2
        ui_read yn; [[ "${yn,,}" == "n" ]] && { echo "  已取消" >&2; return 1; }
        install_warp || return 1
    else
        echo "  [1/5] WARP 已就绪 ($D_IFACE), 跳过安装。"
    fi
    # ② 出口模式
    echo ""
    echo "  [2/5] 普通出站默认走哪? (以后随时在 [8] 出口/补栈模式里改)"
    echo "    [1] 原生 (推荐)     出站保持原样, 只给指定网站走 WARP — 入站最稳"
    echo "    [2] v4 走 WARP      v4 出站走 WARP; v6 (如 he-ipv6 入站) 不动"
    echo "    [3] 双栈全 WARP     v4+v6 都走 WARP (缺栈机器借此补齐出口)"
    echo "    [0] 取消"
    printf "    选择: " >&2
    local m; ui_read m
    case "$m" in
        1) : ;;
        2) echo "        → 切换默认出口: 仅 IPv4"; ASSUME_YES=1 cmd_default v4 || return 1 ;;
        3) echo "        → 切换默认出口: 双栈";    ASSUME_YES=1 cmd_default dual || return 1 ;;
        *) echo "  已取消" >&2; return 1 ;;
    esac
    # ③ 网站
    echo ""
    echo "  [3/5] 要走 WARP 的网站 (例: netflix.com; 每行一个, 回车结束; 跳过=只配出口模式):"
    local d added=0
    while :; do
        printf "    域名 (回车=结束): " >&2
        ui_input d; [[ -z "$d" ]] && break
        if valid_domain "$d" && rule_add "$d" warp; then
            ((added++))
        else
            echo "      无效域名, 已跳过 (示例: netflix.com)" >&2
        fi
    done
    ((added > 0)) || echo "    (未添加网站 — 只配了出口模式; 以后可随时 [2] 添加)"
    # ④ 应用
    echo ""
    echo "  [4/5] 应用分流 (把配置真正部署到系统网络, 这一步才生效)"
    printf "        继续? [Y/n]: " >&2
    ui_read yn
    if [[ "${yn,,}" == "n" ]]; then
        echo "  已暂停: 规则已保存, 以后用 [5] 应用分流即可" >&2; return 0
    fi
    apply || return 1
    # ⑤ 验证
    echo ""
    echo "  [5/5] 快速验证"
    if ((added > 0)); then
        local first; first=$(grep -m1 '|warp|1|' "$RULES" 2>/dev/null | cut -d'|' -f1)
        [[ -n "$first" ]] && { echo "    测试 $first 的真实出口:"; cmd_test "$first" 2>&1 | tail -8; }
    else
        echo "    (没有网站规则, 跳过单站测试 — 可用 [7] 健康检查全面体检)"
    fi
    echo ""
    ok "新手配置完成! 以后: [2] 加网站 → [5] 应用; 出口随时 [8] 改; 疑问用 [7] 体检"
    log_op "quicksetup" "mode=${m:-1} sites=$added"
}

# [1] 快速设置: 状态摘要 + 建议 + 日常七步
menu_quick() {
    while true; do
        ui_init; dash_data
        echo ""
        cl "  ── 快速设置 ──"
    echo "  小白从这里走: 每步有说明, 不会弄坏网络; 功能细节在其余菜单里。"
        echo ""
        cl "  当前状态"
        printf '  WARP       %s %s\n' "$(ui_dot $([[ $D_ON == 1 ]] && echo ok || echo fail))" "$([[ $D_ON == 1 ]] && echo 已安装 || echo 未安装)"
        ((D_ON == 1)) && printf '  接口       %s %s\n' "$(ui_dot ok)" "$D_IFACE"
        ((D_ON == 1)) && printf '  IPv4       %b\n' "$(dash_fam "$D_P4")"
        ((D_ON == 1)) && printf '  IPv6       %b\n' "$(dash_fam "$D_P6")"
        printf '  网站规则   %s 个 (WARP %s / Native %s / 禁用 %s)\n' "$D_NT" "$D_NW" "$D_NN" "$D_ND"
        printf '  分流状态   %s %s\n' "$(ui_dot $([[ -f $APPLIED_FLAG ]] && echo ok || echo na))" "$([[ -f $APPLIED_FLAG ]] && echo 已应用 || echo 未应用)"
        printf '  Forward    %s %s (默认 OFF, 普通出口分流无需开启)\n' "$(ui_dot na)" "$D_FWD"
        # 状态驱动的下一步建议
        local gt=""
        if ((D_ON == 0)); then gt="WARP 未安装 ${UI_ARROW} 建议先 [1] 安装 / 准备 WARP"
        elif [[ ! -f "$APPLIED_FLAG" ]]; then
            if ((D_NT > 0)); then gt="规则已保存未应用 ${UI_ARROW} 建议 [5] 应用分流"
            else gt="建议 [2]/[3] 添加网站, 然后 [5] 应用分流"; fi
        elif ((D_NT == 0)); then gt="建议 [2] 添加网站 ${UI_ARROW} [5] 应用分流"
        elif [[ "$D_P4" != OK* && "$D_P4" != fallback* ]]; then
            gt="这台机器 IPv4 出站不可用 ${UI_ARROW} [8] 出口/补栈模式 可通过 WARP 补一个 IPv4 出口"
        elif [[ "$D_P6" != OK* && "$D_P6" != fallback* && "$D_P6" != *禁用* ]]; then
            gt="这台机器 IPv6 出站不可用 ${UI_ARROW} [8] 出口/补栈模式 可通过 WARP 补一个 IPv6 出口"
        fi
        [[ -n "$gt" ]] && printf '  %s %s\n' "$(cm "$UI_ARROW")" "$gt" || printf '  %s 配置正常, 无需操作 (可 [6] 测试网站验证)\n' "$(cm "$UI_OK")"
        echo ""
        printf '  %s\n' "$(printf '%*s' 60 '' | tr ' ' '-')"
        echo ""
        cl "   [1] 安装 / 准备 WARP     检测并复用或安装 WARP 本体"
        cl "   [2] 添加网站 ${UI_ARROW} WARP      该网站经 WARP 出口访问"
        cl "   [3] 添加网站 ${UI_ARROW} Native    该网站走服务器原本出口"
        cl "   [4] 查看网站规则         列表 + 启用/禁用状态"
        cl "   [5] 应用分流             把规则真正部署到系统"
        cl "   [6] 测试网站             实测某网站的最终出口"
        cl "   [7] 一键健康检查         doctor 全面体检"
        cl "   [8] 出口 / 补栈模式      没有 IPv4/IPv6? 通过 WARP 补一个出口"
        cl "   [9] 新手一键配置 (推荐)  回答几个问题, 自动完成: 装→出口→网站→应用→测试"
        printf '\n   %s 返回\n\n' "$(cm "$UI_RET")"
        printf "  选择: " >&2
        local c d
        ui_read c
        case "$c" in
            1) # 只有**首次安装**才确认: 已装的情况下 install 只是复用, 不该多问一遍;
               # 但首次安装会**直接注册一个新的 Cloudflare 账号**, 必须让用户知道。
               if detect_iface >/dev/null 2>&1; then
                   install_warp
               elif ui_danger "安装 / 准备 WARP (首次安装)" "这会:|  - **注册一个新的 Cloudflare WARP 账号** (出口 IP 由此确定)|  - 安装内核 WireGuard 配置与开机自动恢复单元|不会:|  - 不修改网站分流规则|  - 不替换 main 默认路由 (红线)|  - 不影响入站 (SSH / Nginx / 节点服务)|提示: 已装过 WARP 时不会重复注册, 那时这一步不会询问"; then
                   install_warp
               else
                   echo "  已取消 (未安装 WARP)" >&2
               fi
               ui_pause ;;
            2) ui_add_wizard warp ;;
            3) ui_add_wizard native ;;
            4) menu_sites ;;
            5) apply; ui_pause ;;
            6) printf "  域名或IP [期望 warp|native 可省]: " >&2; ui_input d; cmd_test "$d"; ui_pause ;;
            7) doctor; ui_pause ;;
            8) menu_default ;;
            9) ui_quicksetup; ui_pause ;;
            0) return ;;
        esac
    done
}

# [3] WARP 管理 (带状态头)
menu_warp() {
    while true; do
        ui_init; dash_data
        echo ""
        cl "  ── WARP 管理 ──"
        echo "  功能细节区: 管 WARP 本体 (启停/重启/换IP/重注册); 网站分流在 [1] 快速设置。"
        echo ""
        cl "  当前状态"
        if ((D_ON == 1)); then
            printf '  服务       %s %s\n' "$(ui_dot ok)" "$D_SVC"
            printf '  接口       %s %s\n' "$(ui_dot ok)" "$D_IFACE"
            printf '  IPv4       %b   IPv6      %b\n' "$(dash_fam "$D_P4")" "$(dash_fam "$D_P6")"
            printf '  Endpoint   %-32s MTU  %s\n' "${D_EP:--}" "$D_MTU"
            printf '  Handshake  %s\n' "$D_HS"
        else
            printf '  服务       %s stopped   接口   %s 无\n' "$(ui_dot fail)" "$(ui_dot na)"
            printf '  %s 建议: [5] 安装 WARP (复用已有凭据, 不重注册)\n' "$(cm "$UI_ARROW")"
        fi
        echo ""
        printf '  %s\n' "$(printf '%*s' 60 '' | tr ' ' '-')"
        echo ""
        cl "   [1] 启动 WARP            拉起与当前凭据对应的服务"
        cl "   [2] 停止 WARP            外部管理器(fscarmen)的 WARP 需确认/--force"
        cl "   [3] 重启 WARP            停止 + 启动 + 健康检查"
        cl "   [4] 状态详情             完整 status 输出"
        cl "   [5] 安装 WARP            已装则复用; 不重注册"
        cl "   [6] 重新注册 (危险)      新建 WARP 账号, 出口 IP 会变化"
        cl "   [7] 更换出口 IP          重启会话拿新 IP (轻量, 不动配置)"
        printf '\n   %s 返回\n\n' "$(cm "$UI_RET")"
        printf "  选择: " >&2
        local c; ui_read c
        case "$c" in
            1) start_warp; ui_pause ;;
            2) stop_warp; ui_pause ;;
            3) stop_warp; start_warp; health_check && ok "健康检查通过" || { warn "健康检查失败:"; diagnose; }; ui_pause ;;
            4) cmd_status; ui_pause ;;
            5) install_warp; ui_pause ;;
            6) menu_register; ui_pause ;;
            7) cmd_newip; ui_pause ;;
            0) return ;;
        esac
    done
}

# [2] 网站分流 (表格 + enabled 图例 + 向导添加)
menu_sites() {
    while true; do
        ui_init; dash_data
        echo ""
        cl "  ── 网站分流 ──"
        echo "  功能细节区: 每条规则定一个域名走 WARP 还是原生; 保存≠应用 (需 [5])。"
        echo ""
        if [[ "$D_DEF4" == "WARP" || "$D_DEF6" == "WARP" ]]; then
            echo "  当前默认出口: 栈模式 $(stack_mode) (v4→$D_DEF4 / v6→$D_DEF6)"
            echo "  规则含义: warp=该域名走 WARP; native=该域名走原生 (跨 v4/v6 一致)"
            echo "  在 WARP 默认的栈上: warp 规则即默认方向(无需集合), native 才是例外。"
        else
            echo "  当前默认出口: 全 Native — 普通未指定流量走原生"
            echo "  这里加的是 WARP 例外: warp 走 WARP; native 已是默认, 无额外作用"
        fi
        echo ""
        cl "  网站分流规则"
        printf '    %-28s %-10s %s\n' "DOMAIN" "出口" "状态"
        printf '    %s\n' "$(printf '%*s' 48 '' | tr ' ' '-')"
        local n=0 dom act en
        while IFS='|' read -r dom act en _; do
            ((n++))
            printf '    %-28s %-10s %s %s\n' "$dom" "$act" "$(ui_dot $([[ "$en" == 1 ]] && echo ok || echo na))" "$([[ "$en" == 1 ]] && echo 启用 || echo 禁用)"
        done < <(rule_list)
        [[ $n -eq 0 ]] && printf '    (规则为空 — 用 [1] 添加 WARP / [2] 添加 Native)\n'
        echo ""
        printf '  %s 启用 = 规则参与分流    %s 禁用 = 规则保留, 暂不参与分流\n' "$UI_OK" "$UI_NA"
        echo "  保存(add) ≠ 应用(apply): 保存只写配置; 应用才部署到系统网络。"
        echo ""
        cl "   [1] 添加 WARP            向导: 输域名, 保存后可选立即应用"
        cl "   [2] 添加 Native          向导: 同上, 出口为服务器原生"
        cl "   [3] 启用 / 禁用          保留规则, 暂停参与分流"
        cl "   [4] 删除规则             从配置中移除"
        cl "   [5] 测试网站             实测最终出口 (真实连接)"
        cl "   [6] 应用分流             把当前规则部署到系统"
        printf '\n   %s 返回\n\n' "$(cm "$UI_RET")"
        printf "  选择: " >&2
        local c d m
        ui_read c
        case "$c" in
            1) ui_add_wizard warp ;;
            2) ui_add_wizard native ;;
            3) printf "  域名 + [1=启用 2=禁用] (空格分隔): " >&2; ui_input d m
               case "$m" in 1) rule_set_enabled "$d" 1 ;; 2) rule_set_enabled "$d" 0 ;; *) echo "  无效选择 (1/2)" >&2 ;; esac
               ui_pause ;;
            4) printf "  域名: " >&2; ui_input d
               if ui_danger "删除规则" "将删除规则: $d|影响: 该域名的分流条目从配置移除|不影响: 其他规则 / WARP 本体 / 系统路由"; then
                   rule_del "$d"
               else
                   echo "  已取消" >&2
               fi
               ui_pause ;;
            5) printf "  域名 [期望 warp|native 可省]: " >&2; ui_input d; cmd_test "$d"; ui_pause ;;
            6) apply; ui_pause ;;
            0) return ;;
        esac
    done
}

# [4] 网络诊断 (只检查不修改, 每项说明)
menu_diag() {
    while true; do
        ui_page "网络诊断 (只检查, 不修改配置)"
        cl "   [1] 健康检查 (doctor)"
        echo "       检查 WARP / DNS / 路由 / 分流 / 兼容性, 给出 PASS/WARN/FAIL。"
        cl "   [2] 安装前体检 (check)"
        echo "       检查系统是否满足运行条件 (内核/DNS 占用/现有 WARP)。"
        cl "   [3] 网站实际测试 (test)"
        echo "       实测指定网站最终从哪个出口访问 (真实连接)。"
        cl "   [4] 出站优先级测试 (test-priority)"
        echo "       验证 Xray/Mihomo 等明确出站不会被 catmi-warp 抢走。"
        printf '\n   %s 返回\n\n' "$(cm "$UI_RET")"
        printf "  选择: " >&2
        local c d
        ui_read c
        case "$c" in
            1) doctor; ui_pause ;;
            2) check_env; ui_pause ;;
            3) printf "  域名 [期望 warp|native 可省]: " >&2; ui_input d; cmd_test "$d"; ui_pause ;;
            4) test_priority; ui_pause ;;
            0) return ;;
        esac
    done
}

# [5] 高级设置 (Forward / Outbound / SOCKS5 / 出站优先级)
menu_adv() {
    while true; do
        ui_init; dash_data
        echo ""
        cl "  ── 高级设置 ──"
        echo "  功能细节区: 进阶与自定义项 (默认值已是最稳配置, 改前有说明)。"
        echo ""
        printf '  Forward    %s %s   (转发流量分流; 默认 OFF, 普通出口分流无需开启)\n' "$(ui_dot na)" "$D_FWD"
        printf '  Outbound   ● 可用 (生成 xray/mihomo/sing-box 的 WARP 出站片段)\n'
        local s5; s5=$(socks5_status 2>/dev/null)
        [[ -n "$s5" ]] && printf '  SOCKS5     %s 运行中 127.0.0.1:%s\n' "$(ui_dot ok)" "$s5" || printf '  SOCKS5     %s 未运行 (可选 WireProxy, 普通分流无需)\n' "$(ui_dot na)"
        echo ""
        cl "   [1] Forward 开关"
        echo "       让'经过本机转发的流量'也参与 WARP 分流 (影响 PREROUTING/FORWARD)。"
        echo "       注意: 不是服务器自身出站; 普通服务器出口分流保持 OFF。"
        cl "   [2] WARP Outbound 片段"
        echo "       生成 Xray/Mihomo/sing-box 用的 WARP 出站配置片段。"
        echo "       注意: 这不是'开启系统分流'; 用系统分流则无需此项。"
        cl "   [3] SOCKS5 (形态B) 状态"
        echo "       检测本地 WARP SOCKS5 出口 (供代理内核用)。高级用法。"
        cl "   [4] 出站优先级测试"
        echo "       实测: 已打标 / 绑定接口 / 无标 三类流量的出口归属。"
        cl "   [5] 默认出口模式"
        echo "       查看/切换: ${D_STK} (v4 ${D_DEF4}/v6 ${D_DEF6}) — 含补栈模式。"
        cl "   [6] 流媒体解锁检测"
        echo "       实测 Native/WARP 两方向的 Netflix 解锁 (只读, 不改任何东西)。"
        cl "   [7] WARP Endpoint 优选"
        echo "       扫描 CF 入口段测速选最快, 改后重启 WARP (分流不受影响)。"
        cl "   [8] 更换出口 IP"
        echo "       重启 WARP 会话拿新出口 IP; 分流规则/模式全不变 (需确认)。"
        printf '\n   %s 返回\n\n' "$(cm "$UI_RET")"
        printf "  选择: " >&2
        local c
        ui_read c
        case "$c" in
            1) printf "  forward on|off: " >&2; local v; read -r v
               if [[ "$v" == "on" ]] && ! ui_danger "开启 Forward 转发分流" "这会:|  - 写 iptables **PREROUTING** 与 **MASQUERADE** 规则|  - 转发经过本机的流量也会被分流|不会:|  - 不影响本机自身出站|  - 不删除网站规则|注意: 普通出口分流**不需要**开启此项; 入站服务不受影响但规则面变大"; then
                   echo "  已取消" >&2; ui_pause; continue
               fi
               cmd_forward "$v"; ui_pause ;;
            2) parse_creds >/dev/null 2>&1 || { err "未找到 WARP 凭据"; ui_pause; continue; }
               gen_outbound
               local s5x; s5x=$(socks5_status)
               if [[ -n "$s5x" ]]; then
                   ok "形态B socks5: 127.0.0.1:$s5x"
                   echo "    mihomo: {name: warp-socks, type: socks5, server: 127.0.0.1, port: $s5x, udp: true}" >&2
                   echo "    Xray  : {protocol: socks, settings: {servers: [{address: 127.0.0.1, port: $s5x}]}}" >&2
               else
                   info "socks5 未运行 (可选 fscarmen 'warp w' 装 WireProxy)"
               fi
               ui_pause ;;
            3) local s5b; s5b=$(socks5_status)
               [[ -n "$s5b" ]] && ok "socks5: 127.0.0.1:$s5b" || info "socks5 未运行 (普通网站分流无需此项)"
               ui_pause ;;
            4) test_priority; ui_pause ;;
            5) menu_default ;;
            6) cmd_stream; ui_pause ;;
            7) cmd_endpoint_opt; ui_pause ;;
            8) cmd_newip; ui_pause ;;
            0) return ;;
        esac
    done
}

# [5.x] 默认出口模式页 (三模式: v4/v6/双栈 + 补栈说明)
menu_default() {
    while true; do
        ui_init; dash_data
        echo ""
        cl "  ── 默认出口模式 ──"
        echo ""
        printf '  当前栈模式: %s %s\n' "$(ui_dot ok)" "$D_STK"
        printf '  IPv4 出站: %s     IPv6 出站: %s\n' "$D_DEF4" "$D_DEF6"
        echo ""
        cl "   [1] WARP 只走 IPv4 (补 v4 出口)"
        echo "       v4 出站默认 WARP; v6 出站保持你机器原本的 v6 通道不动。"
        echo "       适合: v4 想换 WARP 但 v6 入站/出口不想被碰;"
        echo "             机器没有公网 IPv4, 想通过 WARP 补一个 IPv4 出口。"
        cl "   [2] WARP 只走 IPv6 (补栈模式)"
        echo "       v6 出站默认 WARP; v4 保持原生。"
        echo "       补栈: 没有 v6 上游的机器, 通过 WARP 直接获得 v6 出口;"
        echo "       已有 v6 入站 (如 he-ipv6) 的机器, 入站回包走原路不受影响。"
        cl "   [3] 双栈 (v4+v6 全走 WARP, 缺哪个补哪个)"
        echo "       两个协议栈出站都默认 WARP; 缺栈机器同时获得补齐的出口。"
        cl "   [4] 恢复全 Native (出厂)"
        echo "       普通出站全回原生; warp 规则域名仍走 WARP。"
        cl "   [5] 测试当前默认出口 (真实出口实测 v4/v6)"
        cl "   [6] 查看例外规则 (网站分流)"
        echo ""
        echo "  任何模式下: Xray/Mihomo 明确 outbound 永远优先; main 路由不替换;"
        echo "  Forward 独立 OFF; 切换即时生效, 不重装 WARP。"
        printf '\n   %s 返回\n\n' "$(cm "$UI_RET")"
        printf "  选择: " >&2
        local c
        ui_read c
        case "$c" in
            1) cmd_default v4; ui_pause ;;
            2) cmd_default v6; ui_pause ;;
            3) cmd_default dual; ui_pause ;;
            4) cmd_default native; ui_pause ;;
            5) printf '  v4 出口: '; timeout 8 curl -s -4 https://ifconfig.me || echo "(探测失败)"
               printf '  v6 出口: '; timeout 8 curl -6 -s https://ifconfig.me || echo "(v6 不通或无上游)"
               echo ""
               ui_pause ;;
            6) menu_sites; ui_pause ;;
            0) return ;;
        esac
    done
}

# [6] 系统维护 (每项带说明 + 危险提示)
menu_sys() {
    while true; do
        ui_init; dash_data
        echo ""
        cl "  ── 系统维护 ──"
        echo ""
        printf '  分流状态   %s %s\n' "$(ui_dot $([[ -f $APPLIED_FLAG ]] && echo ok || echo na))" "$([[ -f $APPLIED_FLAG ]] && echo 已应用 || echo 未应用)"
        echo ""
        cl "   [1] 应用分流 (apply)"
        echo "       把已保存的网站 WARP/Native 规则真正部署到系统。"
        cl "   [2] 暂停分流 (revoke)"
        echo "       移除 catmi-warp 的系统分流规则, 恢复系统默认出口。"
        echo "       注意: 网站规则不会删除, WARP 本体不受影响; 可再次应用恢复。"
        cl "   [3] 开机自动恢复 (units)"
        echo "       重启后自动恢复分流 + 定时刷新网站 IP / WARP 保活。配置稳定后建议开启。"
        cl "   [4] 迁移 V2 规则 (migrate)"
        echo "       从旧版 V2 只读导入网站规则 (V2 原件零改动)。"
        cl "   [5] 更新脚本 (update)"
        echo "       从 URL 下载新版脚本 (校验 + 失败回滚)。"
        cl "   [6] 卸载模块 (危险)"
        echo "       删除脚本与开机单元; 分流先自动拆除; WARP 本体保留; 网站配置备份保留。"
        printf '\n   %s 返回\n\n' "$(cm "$UI_RET")"
        printf "  选择: " >&2
        local c
        ui_read c
        case "$c" in
            1) apply || { warn "应用未完成 — 用 [4] 网络诊断 ${UI_ARROW} 健康检查 查看详情; 已部署部分已自动回滚"; }
               ui_pause ;;
            2) if ui_danger "暂停分流 (revoke)" "这会:|  - 移除 catmi-warp 的 iptables/ip rule/ipset/DNS 接管|  - 系统恢复默认出口 (全部 Native)|不会:|  - 不删除网站规则 (可再次应用恢复)|  - 不停 WARP 本体|  - 不影响 SSH/Nginx/HY2 入站"; then
                   revoke
               else
                   echo "  已取消" >&2
               fi
               ui_pause ;;
            3) install_units; ui_pause ;;
            7) cmd_snapshots; ui_pause ;;
            4) migrate_v2; ui_pause ;;
            5) printf "  更新源 URL (回车=\$CATMI_WARP_URL): " >&2; read -r c
               if ui_danger "更新脚本" "这会:|  - 从 URL 下载新版本并**替换 /usr/local/bin/catmi-warp3 本身**|不会:|  - 不修改分流规则与模式|  - 不重启 WARP / 不动入站|保障: 新版本会先过语法校验, 失败自动回滚到当前版本"; then
                   update_self "$c"
               else
                   echo "  已取消" >&2
               fi
               ui_pause ;;
            6) if ui_danger "卸载模块 (uninstall)" "这会:|  - 删除 /usr/local/bin/catmi-warp3 与开机单元|  - 自动拆除当前分流 (revoke)|不会:|  - 不删除 WARP 本体 (warp-go/wg 继续运行)|  - 不删除 /etc/catmi/warp3 配置与规则 (彻底清除需 rm -rf)"; then
                   uninstall_module; exit 0
               else
                   echo "  已取消" >&2
               fi ;;
            0) return ;;
        esac
    done
}

menu_register() {
    if ui_danger "重新注册 WARP" "这会:|  - 创建全新的 WARP 账号|  - WARP 出口 IP 大概率变化|不会:|  - 不删除网站分流规则|  - 不改变 Native 规则与系统路由策略|建议: 仅在旧账号失效/被封时使用"; then
        FORCE_REGISTER=1 install_warp
    else
        echo "  已取消 (保留现有 WARP 账号)" >&2
    fi
}

# 主入口: Dashboard + 分组菜单 (R 刷新 = 重绘, 不自动循环)
menu_main() {
    need_root
    init_dirs; migrate_v2
    while true; do
        ui_init          # 每帧唯一一次清屏 + 重新读终端宽度 (放这里, 不在 draw 函数里)
        dash_render
        ui_guide
        printf '  %s\n' "$(printf '%*s' 62 '' | tr ' ' '-')"
        echo ""
        cl "   [1] 快速设置        首次使用: 装 WARP / 加网站"
        cl "   [2] 网站分流        管理哪些网站走 WARP, 哪些走 Native"
        cl "   [3] WARP 管理       启动 / 停止 / 重启 / 安装 / 状态 / 重新注册"
        cl "   [4] 网络诊断        健康检查 / 网站实测 / 出站优先级 (只检查不修改)"
        cl "   [5] 高级设置        Forward / Outbound / SOCKS5 (普通用户通常无需)"
        cl "   [6] 系统维护        应用/暂停分流 / 开机恢复 / 更新 / 卸载"
        echo ""
        printf '   %s 重绘   %s 术语速查   %s 退出\n' "$(cm "[R]")" "$(cm "[T]")" "$(cm "[0]/[Q]")"
        echo ""
        printf '  %s\n' "$(printf '%*s' 62 '' | tr ' ' '-')"
        cm "  Catmiup © 2026"
        echo ""
        printf "  选择: " >&2
        local c
        ui_read c
        case "${c^^}" in
            1) menu_quick ;;
            2) menu_sites ;;
            3) menu_warp ;;
            4) menu_diag ;;
            5) menu_adv ;;
            6) menu_sys ;;
            R) : ;;
            T) cmd_terms; ui_pause ;;
            # 主面板的 0 也退出 —— 子菜单都在教"0 = 返回", 小白回首页按 0 想退出时,
            # 原来会落进 *) 无任何提示地整屏重画, 看起来像卡死。
            0|Q) printf '  %sBye ~%s\n' "$KM" "$KN"; echo; exit 0 ;;
        esac
    done
}

# ============================================================
# CLI# ============================================================
# CLI
# ============================================================
case "${1:-}" in
    status)    init_dirs; migrate_v2; cmd_status ;;
    start)     need_root; start_warp ;;
    stop)      shift; FORCE_STOP=$([[ "${1:-}" == "--force" ]] && echo 1 || echo 0); need_root; stop_warp ;;
    restart)   need_root; stop_warp; start_warp; health_check && ok "健康检查通过" || { warn "健康检查失败:"; diagnose; } ;;
    install)   shift
               # 原来只认 --force-register, 而提示文案却教用户 "install --yes" —— --yes 根本不存在,
               # 非交互环境必然卡在 /dev/tty 报错 (实测)。两个旗标都解析掉。
               while [[ $# -gt 0 ]]; do
                   case "$1" in
                       --force-register) FORCE_REGISTER=1 ;;
                       --yes|-y)         ASSUME_YES=1 ;;
                       *) break ;;
                   esac
                   shift
               done
               # 首次安装会注册新的 Cloudflare 账号 —— 不允许静默发生。
               # 已装 (只复用) 或显式 --yes / ASSUME_YES=1 时直接进行, 保持脚本化可用。
               if detect_iface >/dev/null 2>&1 || [[ "${ASSUME_YES:-0}" == "1" ]]; then
                   install_warp
               elif ui_danger "安装 / 准备 WARP (首次安装)" "这会:|  - **注册一个新的 Cloudflare WARP 账号** (出口 IP 由此确定)|  - 安装内核 WireGuard 配置与开机自动恢复单元|不会:|  - 不修改网站分流规则|  - 不替换 main 默认路由 (红线)|  - 不影响入站 (SSH / Nginx / 节点服务)|非交互环境请改用: catmi-warp3 install --yes"; then
                   install_warp
               else
                   err "已取消 — 首次安装会注册新的 Cloudflare 账号"; exit 1
               fi ;;
    check)     init_dirs; check_env ;;
    apply)     shift; ASSUME_YES=$([[ "${1:-}" == "--yes" || "${2:-}" == "--yes" || "${ASSUME_YES:-0}" == "1" ]] && echo 1 || echo 0); apply ;;
    revoke)    need_root; revoke ;;
    reload)    need_root; ASSUME_YES=1; apply ;;
    add)       need_root; rule_add "$2" "${3:-warp}" ;;
    del)       need_root; rule_del "$2" ;;
    on)        need_root; rule_set_enabled "$2" 1 ;;
    off)       need_root; rule_set_enabled "$2" 0 ;;
    test)      need_root; cmd_test "$2" "$3" ;;
    doctor)    need_root; if [[ "${2:-}" == "outbound" ]]; then test_priority; else doctor; fi ;;
    test-priority) need_root; test_priority ;;
    outbound)  need_root; init_dirs; gen_outbound ;;
    forward)   shift; cmd_forward "${1:-}" ;;
    default)   shift; cmd_default "${1:-}" ;;
    warm)      need_root; init_dirs; cmd_warm ;;
    stream)    cmd_stream ;;
    endpoint)  need_root; cmd_endpoint_opt ;;
    newip)     need_root; cmd_newip ;;
    keepalive) need_root; init_dirs; reconcile; cmd_warm || warn "预热未成功 (详见上)"; account_keepalive ;;
    units)     need_root; install_units ;;
    migrate)   need_root; init_dirs; migrate_v2 ;;
    update)    shift; update_self "${1:-}" ;;
    uninstall) uninstall_module ;;
    version)   echo "catmi-warp3 v$VERSION" ;;
    list|ls|rules) cmd_list ;;
    snapshots|backups|undo) cmd_snapshots ;;
    cleanup)   need_root; init_dirs; cmd_cleanup ;;
    terms|words|术语) cmd_terms ;;
    selftest)  selftest ;;
    menu|dashboard) need_root; menu_main ;;
    "")        need_root; menu_main ;;
    -h|--help|help)
        cat <<EOF
catmi-warp3 v$VERSION — 服务器默认出口的 WARP/Native 策略分流器
  原则: 内核明确指定的出站 (fwmark/bind/UID) 优先保留, 只接管无其他策略的默认出口

快速开始 (日常使用):
  catmi-warp3               打开 Catmiup 面板 (推荐, 有引导)
  catmi-warp3 install       安装/准备 WARP (已装自动复用, 不重注册)
  catmi-warp3 add <域名> warp    添加网站走 WARP
  catmi-warp3 add <域名> native  添加网站走 Native (服务器原出口)
  catmi-warp3 apply         应用分流 (把规则部署到系统)
  catmi-warp3 test <域名> [warp|native]   测试网站实际出口
  catmi-warp3 doctor        健康检查 (WARP/DNS/路由/分流)

常用:
  catmi-warp3 status        状态总览
  catmi-warp3 start|stop [--force]|restart   启停 (外部管理的 WARP 停止需确认)
  catmi-warp3 on|off <域名> 启用/禁用某条规则 (保留配置)
  catmi-warp3 del <域名>    删除规则
  catmi-warp3 reload        快速重新应用 (= apply --yes)

高级 (普通用户通常不需要):
  catmi-warp3 doctor outbound | test-priority   出站优先级实测 (Xray/Mihomo 保护验证)
  catmi-warp3 outbound      生成 xray/mihomo/sing-box 的 WARP 出站片段
  catmi-warp3 default v4|v6|dual|native   查看/切换出口模式: 只v4 / 只v6(补栈) / 双栈 / 全原生

流媒体 / 出口工具:
  catmi-warp3 stream             检测 Netflix 解锁 (Native/WARP 两方向实测, 只读)
  catmi-warp3 endpoint           WARP Endpoint 优选 (测速选最快入口, 需确认)
  catmi-warp3 newip              一键更换 WARP 出口 IP (重启会话, 需确认)

系统维护:
  catmi-warp3 check         安装前体检
  catmi-warp3 revoke        暂停分流 (规则保留, 可再次 apply 恢复)
  catmi-warp3 units         安装开机自动恢复单元
  catmi-warp3 migrate       从 V2 只读导入规则 (V2 零改动)
  catmi-warp3 snapshots     看改动前的现场备份 (自动只留最近 50 个)
  catmi-warp3 cleanup [N]   立刻清理旧快照 (默认保留 50 个)
  catmi-warp3 warm          立即刷新网站 IP 集合 (定时任务每 10 分钟自动做)
  catmi-warp3 keepalive     手动执行保活 (定时任务自动做)
  catmi-warp3 forward on|off    转发流量分流 (默认 OFF; 普通出口分流**无需**开启)
  catmi-warp3 update [URL]  自更新 (校验+回滚)
  catmi-warp3 uninstall     卸载模块 (WARP 本体保留)
  catmi-warp3 selftest|version|--help

概念说明:
  保存(add) = 只写配置   应用(apply) = 部署到系统网络   测试(test) = 实际验证出口
  revoke = 暂停分流(规则保留)   uninstall = 卸载模块(规则备份保留, WARP 本体保留)
  install = 复用/安装 WARP   --force-register = 重新注册新账号(出口 IP 会变, 慎用)

  看不懂 WARP / Native / 默认出口 / Forward / 补栈 这些词?
  执行: catmi-warp3 terms         (术语速查, 每个词都用大白话解释一遍)
EOF
        ;;
    *) err "未知命令: $1"; bash "$0" help; exit 1 ;;
esac
