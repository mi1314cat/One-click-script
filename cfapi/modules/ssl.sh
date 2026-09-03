#!/bin/bash
# =============================================================
#  ssl.sh — SSL/TLS 设置管理 (zone settings)
#  命令:
#    ssl status <domain> [--json]
#    ssl mode <domain> <full|strict|flexible|off>
#    ssl tls13 <domain> <on|off>
#    ssl always-https <domain> <on|off>
#    ssl hsts <domain> <on|off>
#  注意: 参数名 tls_1_3 (不是 tls13, 探测确认 400)
# =============================================================

# 通用: 读取 zone setting
_ssl_get() {
    # $1=setting名 $2=domain → 输出 value
    local setting="$1"
    local resp
    resp=$(cf_call_retry GET "/zones/$CF_ZONE_ID/settings/$setting")
    json_get "$resp" "d['result'].get('value','') if d.get('success') else ''"
}

_ssl_patch() {
    # $1=setting名 $2=body, 输出 new value or 空
    local setting="$1" body="$2"
    local resp
    resp=$(cf_call_retry PATCH "/zones/$CF_ZONE_ID/settings/$setting" "$body")
    json_get "$resp" "d['result'].get('value','') if d.get('success') else ''"
}

cmd_ssl_status() {
    local domain="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true; shift ;;
            *) domain="$1"; shift ;;
        esac
    done
    [[ -z "$domain" ]] && { print_error "用法: ssl status <域名> [--json]"; return 1; }
    if ! cf_resolve_context "$domain"; then return 1; fi

    local ssl_mode tls13 always hsts_str hsts_enabled
    ssl_mode=$(_ssl_get "ssl")
    tls13=$(_ssl_get "tls_1_3")
    always=$(_ssl_get "always_use_https")
    local hsts_resp
    hsts_resp=$(cf_call_retry GET "/zones/$CF_ZONE_ID/settings/security_header")
    hsts_enabled=$(json_get "$hsts_resp" "str((d['result'].get('strict_transport_security') or {}).get('enabled','')).lower() if d.get('success') else ''")

    log_write ssl "$CF_DOMAIN" "status" "ok" ""
    if [[ "$json" == "true" ]]; then
        printf '{"ok":true,"domain":"%s","ssl_mode":"%s","tls_1_3":"%s","always_https":"%s","hsts":%s}\n' \
            "$CF_DOMAIN" "$ssl_mode" "$tls13" "$always" $([ "$hsts_enabled" == "true" ] && echo true || echo false)
        return 0
    fi
    echo -e "  ${BOLD}SSL 模式:${PLAIN}    $ssl_mode"
    echo -e "  ${BOLD}TLS 1.3:${PLAIN}    $tls13"
    echo -e "  ${BOLD}Always HTTPS:${PLAIN} $always"
    echo -e "  ${BOLD}HSTS:${PLAIN}       $([ "$hsts_enabled" == "true" ] && echo "开启" || echo "关闭")"
}

cmd_ssl_mode() {
    local domain="$1" mode="$2"
    [[ -z "$domain" || -z "$mode" ]] && { print_error "用法: ssl mode <域名> <full|strict|flexible|off>"; return 1; }
    case "$mode" in
        full|strict|flexible|off) ;;
        *) print_error "支持的 SSL 模式: full | strict | flexible | off"; return 1 ;;
    esac
    if ! cf_resolve_context "$domain"; then return 1; fi
    local newv
    newv=$(_ssl_patch "ssl" "{\"value\": \"$mode\"}")
    if [[ -n "$newv" ]]; then
        log_write ssl "$CF_DOMAIN" "mode $mode" "ok→$newv" ""
        print_ok "SSL 模式已设置: $newv"
    else
        print_error "设置 SSL 模式失败 (需 Zone Settings Edit 权限)"
        return 1
    fi
}

cmd_ssl_tls13() {
    local domain="$1" val="$2"
    [[ -z "$domain" || -z "$val" ]] && { print_error "用法: ssl tls13 <域名> <on|off>"; return 1; }
    [[ "$val" == "on" || "$val" == "off" ]] || { print_error "参数须 on/off"; return 1; }
    if ! cf_resolve_context "$domain"; then return 1; fi
    # 幂等
    local cur
    cur=$(_ssl_get "tls_1_3")
    if [[ "$cur" == "$val" ]]; then
        print_ok "TLS 1.3 已为 $val, 无需修改"
        return 0
    fi
    local newv
    newv=$(_ssl_patch "tls_1_3" "{\"value\": \"$val\"}")
    if [[ -n "$newv" ]]; then
        log_write ssl "$CF_DOMAIN" "tls13 $val" "ok→$newv" ""
        print_ok "TLS 1.3 已设置: $newv"
    else
        print_error "设置 TLS 1.3 失败 (需 Zone Settings Edit 权限)"
        return 1
    fi
}

cmd_ssl_always_https() {
    local domain="$1" val="$2"
    [[ -z "$domain" || -z "$val" ]] && { print_error "用法: ssl always-https <域名> <on|off>"; return 1; }
    [[ "$val" == "on" || "$val" == "off" ]] || { print_error "参数须 on/off"; return 1; }
    if ! cf_resolve_context "$domain"; then return 1; fi
    local newv
    newv=$(_ssl_patch "always_use_https" "{\"value\": \"$val\"}")
    if [[ -n "$newv" ]]; then
        log_write ssl "$CF_DOMAIN" "always-https $val" "ok→$newv" ""
        print_ok "Always HTTPS 已设置: $newv"
    else
        print_error "设置 Always HTTPS 失败 (需 Zone Settings Edit 权限)"
        return 1
    fi
}

cmd_ssl_hsts() {
    local domain="$1" val="$2"
    [[ -z "$domain" || -z "$val" ]] && { print_error "用法: ssl hsts <域名> <on|off>"; return 1; }
    [[ "$val" == "on" || "$val" == "off" ]] || { print_error "参数须 on/off"; return 1; }
    if ! cf_resolve_context "$domain"; then return 1; fi
    # 先取当前完整 security_header 再改 enabled (API 需传全量)
    local resp cur_body newv
    resp=$(cf_call_retry GET "/zones/$CF_ZONE_ID/settings/security_header")
    cur_body=$(echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
h=(d['result'].get('strict_transport_security') or {})
h['enabled']=('$val'=='on')
h['include_subdomains']=h.get('include_subdomains',False)
h['preload']=h.get('preload',False)
print(json.dumps({'value':{'strict_transport_security':h}}))")
    resp=$(cf_call_retry PATCH "/zones/$CF_ZONE_ID/settings/security_header" "$cur_body")
    newv=$(json_get "$resp" "str((d['result'].get('strict_transport_security') or {}).get('enabled','')).lower() if d.get('success') else ''")
    if [[ "$newv" == "$val" ]]; then
        log_write ssl "$CF_DOMAIN" "hsts $val" "ok" ""
        print_ok "HSTS 已设置: $val"
    else
        print_error "设置 HSTS 失败 (需 Zone Settings Edit 权限)"
        return 1
    fi
}