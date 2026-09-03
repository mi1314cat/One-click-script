#!/bin/bash
# =============================================================
#  ech.sh — ECH (Encrypted Client Hello) 管理
#  命令: ech enable|disable|status <domain> [--json]
#  使用官方 API: GET/PATCH /zones/{zid}/settings/ech
# =============================================================

_cmd_ech_common() {
    # $1=domain $2=action(enable|disable|status) $3=json
    local domain="$1" action="$2" json="${3:-false}"
    if ! cf_resolve_context "$domain"; then return 1; fi

    local resp cur
    resp=$(cf_call_retry GET "/zones/$CF_ZONE_ID/settings/ech")
    cur=$(json_get "$resp" "d['result'].get('value','?') if d.get('success') else 'ERR'")
    [[ "$cur" == "ERR" ]] && { print_error "查询 ECH 状态失败: $(redact_text "$resp")"; return 1; }

    if [[ "$action" == "status" ]]; then
        log_write ech "$CF_DOMAIN" "status" "$cur" ""
        if [[ "$json" == "true" ]]; then
            printf '{"ok":true,"domain":"%s","ech":"%s"}\n' "$CF_DOMAIN" "$cur"
        else
            echo -e "  ECH: $([[ "$cur" == "on" ]] && echo -e "${GREEN}ENABLED${PLAIN}" || echo -e "${YELLOW}DISABLED${PLAIN}")"
        fi
        return 0
    fi

    local want
    [[ "$action" == "enable" ]] && want="on" || want="off"

    # 幂等
    if [[ "$cur" == "$want" ]]; then
        log_write ech "$CF_DOMAIN" "$action" "already-${action}d" ""
        if [[ "$json" == "true" ]]; then
            printf '{"ok":true,"action":"already-%sd","domain":"%s","ech":"%s"}\n' "$action" "$CF_DOMAIN" "$cur"
        else
            print_ok "ECH already $([ "$action" == "enable" ] && echo enabled || echo disabled)"
        fi
        return 0
    fi

    # PATCH
    resp=$(cf_call_retry PATCH "/zones/$CF_ZONE_ID/settings/ech" "{\"value\": \"$want\"}")
    local newv
    newv=$(json_get "$resp" "d['result'].get('value','') if d.get('success') else ''")
    if [[ -n "$newv" ]]; then
        log_write ech "$CF_DOMAIN" "$action" "ok→$newv" "$(json_error_code "$resp")"
        if [[ "$json" == "true" ]]; then
            printf '{"ok":true,"action":"%s","domain":"%s","ech":"%s"}\n' "$action" "$CF_DOMAIN" "$newv"
        else
            print_ok "ECH 已$([ "$action" == "enable" ] && echo 开启 || echo 关闭) ($newv)"
        fi
        return 0
    else
        log_write ech "$CF_DOMAIN" "$action" "failed" "$(json_error_code "$resp")"
        print_error "ECH 设置失败: $(redact_text "$resp")"
        return 1
    fi
}

cmd_ech_enable() {
    local domain="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true; shift ;;
            *) domain="$1"; shift ;;
        esac
    done
    [[ -z "$domain" ]] && { print_error "用法: ech enable <域名>"; return 1; }
    _cmd_ech_common "$domain" "enable" "$json"
}

cmd_ech_disable() {
    local domain="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true; shift ;;
            *) domain="$1"; shift ;;
        esac
    done
    [[ -z "$domain" ]] && { print_error "用法: ech disable <域名>"; return 1; }
    _cmd_ech_common "$domain" "disable" "$json"
}

cmd_ech_status() {
    local domain="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true; shift ;;
            *) domain="$1"; shift ;;
        esac
    done
    [[ -z "$domain" ]] && { print_error "用法: ech status <域名>"; return 1; }
    _cmd_ech_common "$domain" "status" "$json"
}