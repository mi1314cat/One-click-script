#!/bin/bash
# =============================================================
#  zone.sh — 域名/Zone 信息
#  命令: zone info <domain> [--json] | zone list
# =============================================================

cmd_zone_info() {
    local domain="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true; shift ;;
            *) domain="$1"; shift ;;
        esac
    done
    [[ -z "$domain" ]] && { print_error "用法: zone info <域名> [--json]"; return 1; }
    if ! cf_resolve_context "$domain"; then return 1; fi

    # 取 zone 详情
    local resp
    resp=$(cf_call_retry GET "/zones/$CF_ZONE_ID")
    local status plan
    status=$(json_get "$resp" "d['result'].get('status','')")
    plan=$(json_get "$resp" "(d['result'].get('plan') or {}).get('name','')")

    log_write zone "$CF_DOMAIN" "info" "ok" ""
    if $json; then
        printf '{"ok":true,"domain":"%s","zone":"%s","zone_id":"%s","account_id":"%s","status":"%s","plan":"%s"}\n' \
            "$CF_DOMAIN" "$CF_ZONE" "$CF_ZONE_ID" "${CF_ACCOUNT_ID:-}" "$status" "$plan"
        return 0
    fi
    echo -e "  ${BOLD}域名:${PLAIN}   $CF_DOMAIN"
    echo -e "  ${BOLD}Zone:${PLAIN}   $CF_ZONE"
    echo -e "  ${BOLD}Zone ID:${PLAIN} $CF_ZONE_ID"
    echo -e "  ${BOLD}Account:${PLAIN} $CF_NAME${CF_ACCOUNT_ID:+ ($CF_ACCOUNT_ID)}"
    echo -e "  ${BOLD}状态:${PLAIN}   $status"
    echo -e "  ${BOLD}套餐:${PLAIN}   $plan"
}

cmd_zone_list() {
    local json=false
    [[ "$1" == "--json" ]] && { json=true; shift; }
    if [[ ! -f "$CF_ACCOUNTS_FILE" ]] || [[ $(account_load_all | wc -l) -eq 0 ]]; then
        print_warn "无账号: 先 account add"
        return 0
    fi
    if $json; then
        echo "["
        local first=true
        while IFS='|' read -r name email tok acctid def; do
            [[ -z "$name" ]] && continue
            local isg=0 tplain="$tok"
            [[ "$tplain" == key:* ]] && { isg=1; tplain="${tplain#key:}"; }
            local zl
            zl=$(account_zones "$name" "$email" "$tplain" "$isg")
            while IFS='|' read -r zname zid2; do
                [[ -z "$zname" ]] && continue
                $first || echo ","
                first=false
                printf '  {"account":"%s","zone":"%s","zone_id":"%s"}' "$name" "$zname" "$zid2"
            done <<< "$zl"
        done < <(account_load_all)
        echo ""
        echo "]"
        return 0
    fi
    echo -e "${CYAN}===== Cloudflare 全部域名 =====${PLAIN}"
    while IFS='|' read -r name email tok acctid def; do
        [[ -z "$name" ]] && continue
        local isg=0 tplain="$tok"
        [[ "$tplain" == key:* ]] && { isg=1; tplain="${tplain#key:}"; }
        local zl
        zl=$(account_zones "$name" "$email" "$tplain" "$isg")
        if [[ -z "$zl" ]]; then
            echo -e "  ${GRAY}[账号 $name]: 无 zone 或无权限${PLAIN}"
            continue
        fi
        echo -e "  ${YELLOW}[账号 $name]${PLAIN}"
        local zname zid2
        while IFS='|' read -r zname zid2; do
            [[ -z "$zname" ]] && continue
            echo -e "    ${GREEN}${zname}${PLAIN}  ($zid2)"
        done <<< "$zl"
    done < <(account_load_all)
}