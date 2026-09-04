#!/bin/bash
# =============================================================
#  cf-manager.sh — Cloudflare API 基础设施管理器
#  所有脚本统一调用的 Cloudflare API 基础组件
#
#  用法:
#    cf-manager.sh account list|add|remove|edit|test|default
#    cf-manager.sh zone info <domain> [--json] | zone list
#    cf-manager.sh dns ensure <domain> <IP> [--proxy on|off|auto] [--ttl N]
#    cf-manager.sh dns status|list|delete <domain>
#    cf-manager.sh ech enable|disable|status <domain>
#    cf-manager.sh ssl status|mode|tls13|always-https|hsts
#    cf-manager.sh origin port|list <domain> [<port>] [--path /xxx]
#    cf-manager.sh cert issue|status|renew <domain>
#    cf-manager.sh config show | cache clear | logs tail | api test
#    短参: -A domain ip | -E domain | -S domain | -P domain port
#    cf-manager.sh (无参 → 交互面板)
# =============================================================

if locale -a 2>/dev/null | grep -qi 'C.utf8'; then
    export LC_ALL=C.UTF-8
fi

CF_BASE_DIR="${CF_BASE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
CF_MODULES_DIR="$CF_BASE_DIR/modules"
CF_CONFIG_DIR="$CF_BASE_DIR/config"
CF_CACHE_DIR="$CF_BASE_DIR/cache"
CF_LOG_DIR="$CF_BASE_DIR/logs"
CF_CERTS_DIR="$CF_BASE_DIR/certs"

# =============================================================
# 自举 (Bootstrap): 首次安装只有单文件时, 自动从 GitHub 拉取 modules/
# 触发条件: modules/common.sh 不存在 (且未显式禁用 CF_SKIP_BOOTSTRAP=1)
# 来源: https://github.com/mi1314cat/One-click-script/tree/main/cfapi
# 策略: 优先 tarball (单请求, 快), 失败回退逐文件 raw
# =============================================================
CF_BOOTSTRAP_REPO="${CF_BOOTSTRAP_REPO:-mi1314cat/One-click-script}"
CF_BOOTSTRAP_BRANCH="${CF_BOOTSTRAP_BRANCH:-main}"
if [[ "${CF_SKIP_BOOTSTRAP:-0}" != "1" && ! -f "$CF_MODULES_DIR/common.sh" ]]; then
    echo "[cf-manager] 检测到缺少 modules/ (首次安装?), 正在自动下载..." >&2
    if ! command -v curl >/dev/null 2>&1; then
        echo "[cf-manager] 错误: 需要 curl 才能自动下载 modules/" >&2
        echo "[cf-manager] 请手动获取完整 cfapi/ 目录 (含 modules/) 或安装 curl 后重试" >&2
        exit 1
    fi
    mkdir -p "$CF_MODULES_DIR"
    dl_ok=0
    # 方案1: tarball 一次性拉取整个 cfapi 目录
    if command -v tar >/dev/null 2>&1; then
        if curl -fsSL --max-time 60 -o /tmp/cfapi-bootstrap.tgz \
            "https://codeload.github.com/$CF_BOOTSTRAP_REPO/tar.gz/refs/heads/$CF_BOOTSTRAP_BRANCH" 2>/dev/null \
            && tar -xzf /tmp/cfapi-bootstrap.tgz -C /tmp \
            && cp -f /tmp/One-click-script-$CF_BOOTSTRAP_BRANCH/cfapi/modules/*.sh "$CF_MODULES_DIR/" 2>/dev/null; then
            dl_ok=1
        fi
        rm -f /tmp/cfapi-bootstrap.tgz
        rm -rf "/tmp/One-click-script-$CF_BOOTSTRAP_BRANCH" 2>/dev/null
    fi
    # 方案2: 逐文件 raw (tarball 不可用时)
    if [[ "$dl_ok" != "1" ]]; then
        for m in common context account zone dns ech ssl origin cert; do
            curl -fsSL --max-time 20 -o "$CF_MODULES_DIR/$m.sh" \
                "https://raw.githubusercontent.com/$CF_BOOTSTRAP_REPO/$CF_BOOTSTRAP_BRANCH/cfapi/modules/$m.sh" \
                || { echo "[cf-manager] 下载失败: modules/$m.sh" >&2; dl_ok=0; break; }
            dl_ok=1
        done
    fi
    if [[ "$dl_ok" = "1" && -f "$CF_MODULES_DIR/common.sh" ]]; then
        chmod 644 "$CF_MODULES_DIR"/*.sh 2>/dev/null
        echo "[cf-manager] 模块自举完成: $CF_MODULES_DIR" >&2
    else
        echo "[cf-manager] 模块下载不完整, 请检查网络或手动放置 modules/ 目录" >&2
        exit 1
    fi
fi

# 加载公共库 + 模块
source "$CF_MODULES_DIR/common.sh" || { echo "缺少 modules/common.sh"; exit 1; }
for m in context account zone dns ech ssl origin cert; do
    source "$CF_MODULES_DIR/$m.sh" || { echo "缺少 modules/$m.sh"; exit 1; }
done

log_init

# ------- 非交互默认 -------
export CF_NON_INTERACTIVE=true

# ------- 快捷参数 -------
dispatch_short() {
    local opt="$1"; shift
    case "$opt" in
        -A|--dns)    cmd_dns_ensure "$@" ;;
        -E|--ech)    cmd_ech_enable "$@" ;;
        -S|--ssl)    cmd_ssl_status "$@" ;;
        -P|--origin) cmd_origin_port "$@" ;;
        *) print_error "未知短参: $opt"; exit 1 ;;
    esac
}

# ------- 子命令分发 -------
dispatch() {
    local cmd="$1"
    [[ -z "$cmd" ]] && { panel_loop; return 0; }
    shift
    case "$cmd" in
        account|acc)
            local sub="${1:-}"
            shift || true
            case "$sub" in
                list)   cmd_account_list "$@" ;;
                add)    cmd_account_add "$@" ;;
                remove|rm) cmd_account_remove "${1:-}" ;;
                edit)   cmd_account_edit "${1:-}" ;;
                test)   cmd_account_test "$@" ;;
                default) cmd_account_default "${1:-}" ;;
                *)      echo "account 子命令: list|add|remove <名>|edit <名>|test [名]|default <名>"; exit 1 ;;
            esac ;;
        zone)
            local sub="${1:-}"; shift || true
            case "$sub" in
                info) cmd_zone_info "$@" ;;
                list) cmd_zone_list "$@" ;;
                *) echo "zone 子命令: info <域名> [--json] | list"; exit 1 ;;
            esac ;;
        dns)
            local sub="${1:-}"; shift || true
            case "$sub" in
                ensure) cmd_dns_ensure "$@" ;;
                status) cmd_dns_status "$@" ;;
                delete) cmd_dns_delete "$@" ;;
                list)   cmd_dns_list "$@" ;;
                *) echo "dns 子命令: ensure|status|delete|list"; exit 1 ;;
            esac ;;
        ech)
            local sub="${1:-}"; shift || true
            case "$sub" in
                enable)  cmd_ech_enable "$@" ;;
                disable) cmd_ech_disable "$@" ;;
                status)  cmd_ech_status "$@" ;;
                *) echo "ech 子命令: enable|disable|status"; exit 1 ;;
            esac ;;
        ssl)
            local sub="${1:-}"; shift || true
            case "$sub" in
                status)       cmd_ssl_status "$@" ;;
                mode)         cmd_ssl_mode "$@" ;;
                tls13)        cmd_ssl_tls13 "$@" ;;
                always-https) cmd_ssl_always_https "$@" ;;
                hsts)         cmd_ssl_hsts "$@" ;;
                *) echo "ssl 子命令: status|mode <m>|tls13 <on|off>|always-https <on|off>|hsts <on|off>"; exit 1 ;;
            esac ;;
        origin)
            local sub="${1:-}"; shift || true
            case "$sub" in
                port) cmd_origin_port "$@" ;;
                list) cmd_origin_port --list "$@" ;;
                *) echo "origin 子命令: port <域名> <端口> [--path] [--delete] | list <域名>"; exit 1 ;;
            esac ;;
        cert)
            local sub="${1:-}"; shift || true
            case "$sub" in
                issue)  cmd_cert_issue "$@" ;;
                status) cmd_cert_status "$@" ;;
                renew)  cmd_cert_renew "$@" ;;
                *) echo "cert 子命令: issue|status|renew <域名>"; exit 1 ;;
            esac ;;
        cache)
            case "${1:-}" in
                clear) cf_cache_clear ;;
                *) echo "cache 子命令: clear"; exit 1 ;;
            esac ;;
        config)
            case "${1:-}" in
                show)
                    cmd_account_list
                    echo -e "\n${CYAN}===== 私有配置 =====${PLAIN}"
                    echo -e "  配置目录: $CF_CONFIG_DIR (700)"
                    echo -e "  凭据文件: $CF_ACCOUNTS_FILE (600)"
                    echo -e "  缓存文件: $CF_CACHE_FILE (600)"
                    echo -e "  日志文件: $CF_LOG_FILE (无敏感信息)"
                    ;;
                *) echo "config 子命令: show"; exit 1 ;;
            esac ;;
        logs)
            case "${1:-}" in
                tail) tail -n 30 "$CF_LOG_FILE" 2>/dev/null || echo "(无日志)" ;;
                *) echo "logs 子命令: tail"; exit 1 ;;
            esac ;;
        api)
            case "${1:-}" in
                test) cmd_account_test "${2:-}" ;;
                *) echo "api 子命令: test [账号名]"; exit 1 ;;
            esac ;;
        help|-h|--help) help_text ;;
        *) print_error "未知命令: $cmd (help 查看用法)"; exit 1 ;;
    esac
}

help_text() {
    cat <<'EOF'
Cloudflare API Manager (cf-manager)

账户:
  account list | add [--name N --email E --token T --no-save] | remove <名> | edit <名> | test [名] | default <名>
域名/Zone:
  zone info <域名> [--json] | zone list
DNS (幂等):
  dns ensure <域名> <IP> [--proxy on|off|auto] [--ttl N]     IPv4→A, IPv6→AAAA
  dns status <域名> [--json] | dns list <域名> | dns delete <域名> --force
ECH:
  ech enable|disable|status <域名> [--json]
SSL/TLS:
  ssl status <域名> [--json] | ssl mode <域名> <full|strict|flexible|off>
  ssl tls13 <域名> <on|off> | ssl always-https <域名> <on|off> | ssl hsts <域名> <on|off>
回源端口 (Origin Rules):
  origin port <域名> <端口> [--path /xxx] [--delete] | origin list <域名>
证书 (Origin CA, 需 ORIGIN_CA_TOKEN):
  cert issue|status|renew <域名> [--type rsa|ec]
基础设施:
  cache clear | config show | logs tail | api test <账号>
快捷:
  -A <域名> <IP> (dns ensure)  -E <域名> (ech enable)  -S <域名> (ssl status)  -P <域名> <端口> (origin port)
无参数: 交互面板
EOF
}

# ------- 交互面板 -------
panel_loop() {
    while true; do
        clear
        echo -e "${GREEN}  ╔══════════════════════════════════════╗${PLAIN}"
        echo -e "${GREEN}  ║     Cloudflare API Manager          ║${PLAIN}"
        echo -e "${GREEN}  ╚══════════════════════════════════════╝${PLAIN}"
        echo
        echo -e "  ${YELLOW}[1]${PLAIN} 账户管理"
        echo -e "  ${YELLOW}[2]${PLAIN} 域名 / Zone"
        echo -e "  ${YELLOW}[3]${PLAIN} DNS"
        echo -e "  ${YELLOW}[4]${PLAIN} ECH"
        echo -e "  ${YELLOW}[5]${PLAIN} SSL/TLS"
        echo -e "  ${YELLOW}[6]${PLAIN} 回源端口"
        echo -e "  ${YELLOW}[7]${PLAIN} 证书 (Origin CA)"
        echo -e "  ${YELLOW}[8]${PLAIN} 缓存/配置/日志"
        echo -e "  ${YELLOW}[0]${PLAIN} 退出"
        echo
        printf "${GREEN}  请选择: ${PLAIN}"
        read -r c
        case "$c" in
            1)
                echo
                echo -e "  ${CYAN}── 账户管理 ──────────────────────${PLAIN}"
                echo -e "  ${YELLOW}[1]${PLAIN} 查看账号列表"
                echo -e "  ${YELLOW}[2]${PLAIN} 添加新账号"
                echo -e "  ${YELLOW}[3]${PLAIN} 删除账号"
                echo -e "  ${YELLOW}[4]${PLAIN} 编辑账号"
                echo -e "  ${YELLOW}[5]${PLAIN} 测试凭据"
                echo -e "  ${YELLOW}[6]${PLAIN} 设为默认账号"
                echo -e "  ${YELLOW}[0]${PLAIN} 返回"
                echo
                printf "  选择: "; read -r a
                case "$a" in
                    1) cmd_account_list ;;
                    2) cmd_account_add ;;
                    3) printf "账号名: "; read -r n; cmd_account_remove "$n" ;;
                    4) printf "账号名: "; read -r n; cmd_account_edit "$n" ;;
                    5) printf "账号名(空=默认): "; read -r n; cmd_account_test "$n" ;;
                    6) printf "账号名: "; read -r n; cmd_account_default "$n" ;;
                    0) continue ;;
                esac ;;
            2)
                echo
                echo -e "  ${CYAN}── 域名 / Zone ────────────────────${PLAIN}"
                echo -e "  ${YELLOW}[1]${PLAIN} 列出全部域名"
                echo -e "  ${YELLOW}[2]${PLAIN} 查询单个域名"
                echo -e "  ${YELLOW}[0]${PLAIN} 返回"
                echo
                printf "  选择: "; read -r a
                case "$a" in
                    1) cmd_zone_list ;;
                    2) printf "域名: "; read -r d; cmd_zone_info "$d" ;;
                    0) continue ;;
                esac ;;
            3)
                echo
                echo -e "  ${CYAN}── DNS 管理 ───────────────────────${PLAIN}"
                echo -e "  ${YELLOW}[1]${PLAIN} 查看 DNS 状态"
                echo -e "  ${YELLOW}[2]${PLAIN} 创建/修改记录 (ensure)"
                echo -e "  ${YELLOW}[3]${PLAIN} 删除记录"
                echo -e "  ${YELLOW}[0]${PLAIN} 返回"
                echo
                printf "  选择: "; read -r a
                case "$a" in
                    1) printf "域名: "; read -r d; cmd_dns_status "$d" ;;
                    2) printf "域名: "; read -r d; printf "IP/值: "; read -r ip; printf "代理(on/off/auto): "; read -r p; cmd_dns_ensure "$d" "$ip" --proxy "${p:-auto}" ;;
                    3) printf "域名: "; read -r d; cmd_dns_delete "$d" --force ;;
                    0) continue ;;
                esac ;;
            4)
                echo
                echo -e "  ${CYAN}── ECH 管理 ───────────────────────${PLAIN}"
                echo -e "  ${YELLOW}[1]${PLAIN} 开启 ECH"
                echo -e "  ${YELLOW}[2]${PLAIN} 关闭 ECH"
                echo -e "  ${YELLOW}[3]${PLAIN} 查看 ECH 状态 (中文显示)"
                echo -e "  ${YELLOW}[0]${PLAIN} 返回"
                echo
                printf "  选择: "; read -r a
                printf "域名: "; read -r d
                case "$a" in
                    1) cmd_ech_enable "$d" ;;
                    2) cmd_ech_disable "$d" ;;
                    3) cmd_ech_status "$d" ;;
                    0) continue ;;
                esac ;;
            5)
                echo
                echo -e "  ${CYAN}── SSL/TLS 管理 ───────────────────${PLAIN}"
                echo -e "  ${YELLOW}[1]${PLAIN} 查看 SSL 状态"
                echo -e "  ${YELLOW}[2]${PLAIN} 设置模式 (full/strict/flexible/off)"
                echo -e "  ${YELLOW}[3]${PLAIN} TLS 1.3 (on/off)"
                echo -e "  ${YELLOW}[4]${PLAIN} Always HTTPS (on/off)"
                echo -e "  ${YELLOW}[5]${PLAIN} HSTS (on/off)"
                echo -e "  ${YELLOW}[0]${PLAIN} 返回"
                echo
                printf "  选择: "; read -r a
                printf "域名: "; read -r d
                case "$a" in
                    1) cmd_ssl_status "$d" ;;
                    2) printf "模式(full/strict/flexible/off): "; read -r m; cmd_ssl_mode "$d" "$m" ;;
                    3) printf "on/off: "; read -r v; cmd_ssl_tls13 "$d" "$v" ;;
                    4) printf "on/off: "; read -r v; cmd_ssl_always_https "$d" "$v" ;;
                    5) printf "on/off: "; read -r v; cmd_ssl_hsts "$d" "$v" ;;
                    0) continue ;;
                esac ;;
            6)
                echo
                echo -e "  ${CYAN}── 回源端口 (Origin Rules) ───────${PLAIN}"
                echo -e "  ${YELLOW}[1]${PLAIN} 查看回源端口列表"
                echo -e "  ${YELLOW}[2]${PLAIN} 添加回源端口"
                echo -e "  ${YELLOW}[3]${PLAIN} 删除回源端口"
                echo -e "  ${YELLOW}[0]${PLAIN} 返回"
                echo
                printf "  选择: "; read -r a
                printf "域名: "; read -r d
                case "$a" in
                    1) cmd_origin_port --list "$d" ;;
                    2) printf "端口: "; read -r p; printf "路径(/xxx, 可空): "; read -r pa; cmd_origin_port "$d" "$p" ${pa:+--path "$pa"} ;;
                    3) printf "端口: "; read -r p; cmd_origin_port "$d" "$p" --delete ;;
                    0) continue ;;
                esac ;;
            7)
                echo
                echo -e "  ${CYAN}── 证书 (Origin CA) ───────────────${PLAIN}"
                if [[ -z "${ORIGIN_CA_TOKEN:-}" ]]; then
                    echo -e "  ${YELLOW}!${PLAIN} 需要 ORIGIN_CA_TOKEN 环境变量 (未设置, 证书操作可能失败)"
                fi
                echo -e "  ${YELLOW}[1]${PLAIN} 签发证书"
                echo -e "  ${YELLOW}[2]${PLAIN} 查看证书状态"
                echo -e "  ${YELLOW}[3]${PLAIN} 续期证书"
                echo -e "  ${YELLOW}[0]${PLAIN} 返回"
                echo
                printf "  选择: "; read -r a
                printf "域名: "; read -r d
                case "$a" in
                    1) cmd_cert_issue "$d" ;;
                    2) cmd_cert_status "$d" ;;
                    3) cmd_cert_renew "$d" ;;
                    0) continue ;;
                esac ;;
            8)
                echo
                echo -e "  ${CYAN}── 缓存 / 配置 / 日志 ────────────${PLAIN}"
                echo -e "  ${YELLOW}[1]${PLAIN} 清空缓存"
                echo -e "  ${YELLOW}[2]${PLAIN} 查看配置"
                echo -e "  ${YELLOW}[3]${PLAIN} 查看日志"
                echo -e "  ${YELLOW}[0]${PLAIN} 返回"
                echo
                printf "  选择: "; read -r a
                case "$a" in
                    1) cf_cache_clear ;;
                    2) cmd_account_list ;;
                    3) tail -n 20 "$CF_LOG_FILE" 2>/dev/null || echo "(无日志)" ;;
                    0) continue ;;
                esac ;;
            0) return 0 ;;
        esac
        echo
        read -r -p "  回车继续..." _ 2>/dev/null
    done
}

# ------- 入口 -------
main() {
    # 短参开头 → 快捷分发
    case "${1:-}" in
        -A|-E|-S|-P|--dns|--ech|--ssl|--origin)
            dispatch_short "$1" "${@:2}"; exit $? ;;
    esac
    dispatch "$@"
    exit $?
}

main "$@"