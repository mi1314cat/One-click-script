
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")
DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"
load_env $CATMIENV_FILE

NINSTALL_DIR="/root/catmi/$mode"
NINSTALL_ENV="$NINSTALL_DIR/install_info.env"


random_website() {
    # ================================================================
    # Reality 自动优选（自包含函数：整池 inside random_website，
    # 保证 sing-box-core 远程抽取本函数单独执行时 100% 可运行）
    #
    # 对外接口（保持不变）:
    #   stdout 仅输出一个域名, exit 0, 进度/诊断只写 stderr
    #
    # 选择逻辑:
    #   1. 洗牌候选池 (不做永久速度排名, 每次在现场重新验证)
    #   2. 逐个轻量验证: TCP 443 + TLS1.3 + HTTP/2 (ALPN h2) + 证书通过
    #   3. 最多验证 20 个 / 取 4 个健康候选即停 (部署速度快)
    #   4. 在健康候选里选 TLS 建连耗时最短者
    #   5. 全部失败 -> 二次小范围重试 -> 最终 fallback
    # ================================================================

    # ---- 候选池: 大型厂商官方基础设施 / 开源基金会 / 高校 (CC 实测 TLS1.3 + h2 + SAN 匹配) ----
    # 已剔除: 裸 oracle.com / mysql.com 等仅 TLS1.2 条目, Cloudflare/共享 CDN 条目(nodejs/redis.io等), SAN 不匹配条目
    local -a pool=(
        # Apple 官方分发基础设施
        "aod.itunes.apple.com"
        "swdist.apple.com"
        "osxapps.itunes.apple.com"
        "mensura.cdn-apple.com"
        "swcdn.apple.com"
        "updates.cdn-apple.com"
        "audio-ssl.itunes.apple.com"
        "apps.apple.com"
        # Google
        "dl.google.com"
        "storage.googleapis.com"
        "translate.googleapis.com"
        # Microsoft
        "software.download.prss.microsoft.com"
        "cdn-dynmedia-1.microsoft.com"
        "c.s-microsoft.com"
        # Amazon AWS/自家 CDN
        "s0.awsstatic.com"
        "d1.awsstatic.com"
        "images-na.ssl-images-amazon.com"
        "m.media-amazon.com"
        # Mozilla
        "addons.mozilla.org"
        "download-installer.cdn.mozilla.net"
        "ftp.mozilla.org"
        "releases.mozilla.org"
        # Oracle / Swift / Java / DB 厂商
        "www.oracle.com"
        "swift.org"
        "openjdk.org"
        "adoptium.net"
        "www.mysql.com"
        "mongodb.com"
        "elastic.co"
        # 语言 / 开源项目官网
        "python.org"
        "docs.python.org"
        "ruby-lang.org"
        "golang.org"
        "go.dev"
        "perl.org"
        "apache.org"
        "kernel.org"
        "debian.org"
        "ubuntu.com"
        "canonical.com"
        "freebsd.org"
        "netbsd.org"
        "openbsd.org"
        # 数据库 / 可观测性
        "redis.io"
        "zabbix.com"
        "prometheus.io"
        "grafana.com"
        # 硬件 / 芯片 / 设备厂商
        "www.nvidia.com"
        "academy.nvidia.com"
        "www.qualcomm.com"
        "arm.com"
        "amd.com"
        "intel.com"
        "lenovo.com"
        "acer.com"
        "asus.com"
        "sony.com"
        # 企业软件 / 安全
        "ibm.com"
        "redhat.com"
        "suse.com"
        # 教育 (多为校园自有基础设施)
        "mit.edu"
        "harvard.edu"
        "caltech.edu"
        "suffolk.edu"
        "umcg.nl"
        "utoronto.ca"
        "ethz.ch"
        # 日本
        "lovelive-anime.jp"
        "one-piece.com"
        "fom-international.com"
    )

    # ---- 兜底: 经实测 TLS1.3 + h2 + 域名 SAN 匹配 (与 sing-box-core 的 www.oracle.com 回退一致) ----
    local fallback_domain="www.oracle.com"

    # ---- 工具缺失时直接使用兜底 (不猜测环境) ----
    if ! command -v curl >/dev/null 2>&1; then
        echo "random_website: curl 不可用, 使用兜底 $fallback_domain" >&2
        echo "$fallback_domain"
        return 0
    fi

    local -a shuffled=()
    mapfile -t shuffled < <(printf '%s\n' "${pool[@]}" | shuf 2>/dev/null || printf '%s\n' "${pool[@]}")
    local total=${#shuffled[@]}
    if [ "$total" -eq 0 ]; then
        echo "random_website: 候选池为空, 使用兜底 $fallback_domain" >&2
        echo "$fallback_domain"
        return 0
    fi

    local -a healthy=()
    local -a healthy_t=()
    local scanned=0
    local max_scan=20      # 第一轮最多测 20 个, 控制部署耗时
    local max_healthy=4    # 拿到 4 个健康候选即停止测试

    echo "random_website: 开始现场验证候选 (池规模 $total, 第一轮最多 $max_scan 个)..." >&2

    local i d meta ver thr ok
    for ((i = 0; i < total; i++)); do
        [ "${#healthy[@]}" -ge "$max_healthy" ] && break
        [ "$scanned" -ge "$max_scan" ] && break
        d="${shuffled[$i]}"
        scanned=$((scanned + 1))

        # 1) 检查域名解析 (可用 getent 则做, 不存在则跳过此步)
        if command -v getent >/dev/null 2>&1; then
            getent hosts "$d" >/dev/null 2>&1 || { echo "  [跳过] $d: DNS 解析失败" >&2; continue; }
        fi

        # 2) 现场轻量 HTTPS 验证: 强制 TLS1.3, 读 ALPN 结果, 取 TLS 建连耗时 (一次请求完成)
        meta=$(curl -s --head -o /dev/null --connect-timeout 2 --max-time 4 --tlsv1.3 \
            "https://$d/" -w '%{http_version}|%{time_appconnect}' 2>/dev/null) || \
            { echo "  [失败] $d: TCP/TLS/HTTPS 不可用" >&2; continue; }

        ver="${meta%%|*}"
        thr="${meta##*|}"
        if [ "$ver" = "2" ] && [ -n "$thr" ] && [ "$thr" != "0" ] && [ "000$thr" != "000000000" ]; then
            # 附加约束: 数字比较防注入 (curl 数值输出)
            case "$thr" in (*[!0-9.]*) continue ;; esac
            healthy+=("$d")
            healthy_t+=("$thr")
            echo "  [可用] $d: TLS1.3+h2, TLS建连 ${thr}s" >&2
        else
            echo "  [失败] $d: 无 TLS1.3/HTTP2 (ver=$ver)" >&2
        fi
    done

    # ---- 第一轮全挂: 再给少量候选一次机会 (暂时失败域名不死删, 只是这一轮不选) ----
    if [ "${#healthy[@]}" -eq 0 ]; then
        echo "random_website: 第一轮无可用候选, 进入重试段..." >&2
        for ((i = max_scan; i < total; i++)); do
            [ "${#healthy[@]}" -ge 2 ] && break
            d="${shuffled[$i]}"
            meta=$(curl -s --head -o /dev/null --connect-timeout 2 --max-time 3 --tlsv1.3 \
                "https://$d/" -w '%{http_version}|%{time_appconnect}' 2>/dev/null) || continue
            ver="${meta%%|*}"
            thr="${meta##*|}"
            if [ "$ver" = "2" ] && [ -n "$thr" ] && [ "$thr" != "0" ] && [ "000$thr" != "000000000" ]; then
                case "$thr" in (*[!0-9.]*) continue ;; esac
                healthy+=("$d")
                healthy_t+=("$thr")
                echo "  [重试可用] $d: TLS1.3+h2" >&2
            fi
        done
    fi

    # ---- 选择: 健康候选中 TLS 建连耗时最短 (仅本次运行有效, 不持久化排名) ----
    if [ "${#healthy[@]}" -gt 0 ]; then
        local best_d="" best_t=""
        local j
        for j in "${!healthy[@]}"; do
            if [ -z "$best_t" ] || ( [ -n "${healthy_t[$j]}" ] && awk 'BEGIN{exit !(ARGV[1]<ARGV[2])}' "${healthy_t[$j]}" "$best_t" ); then
                best_t="${healthy_t[$j]}"
                best_d="${healthy[$j]}"
            fi
        done
        echo "random_website: 完成, 健康候选 ${#healthy[@]} 个, 选定 $best_d" >&2
        echo "$best_d"
        return 0
    fi

    # ---- 全部失败: 兜底 (保证绝不为空) ----
    echo "random_website: 所有候选验证失败, 使用兜底 $fallback_domain" >&2
    echo "$fallback_domain"
    return 0
}

# 生成密钥
read -rp "请输入Reality伪装网址: " dest_server
[ -z "$dest_server" ] && dest_server=$(random_website)
update_env $NINSTALL_ENV dest_server "${dest_server}"
