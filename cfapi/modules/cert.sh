#!/bin/bash
# =============================================================
#  cert.sh — Origin CA 证书管理
#  命令:
#    cert issue <domain> [--type rsa|ec] [--hosts a,b] [--json]
#    cert status <domain> [--json]
#    cert renew <domain> [--type rsa|ec]
#  已实测: Global API Key + CSR 即可签发 Origin CA (15年)
#  (不需要专用 token; 官方文档建议 API Token, 但 Global Key 经实测可用)
#  保存: $CF_CERTS_DIR/<domain>.crt + .key (chmod 600)
# =============================================================

CERT_OUT_DIR="${CF_CERTS_DIR:-/root/catmi/cloudflare/certs}"

cmd_cert_issue() {
    local domain="" rtype="origin-rsa" hosts="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type) rtype="$2"; shift 2 ;;
            --hosts) hosts="$2"; shift 2 ;;
            --json) json=true; shift ;;
            *) domain="$1"; shift ;;
        esac
    done
    [[ -z "$domain" ]] && { print_error "用法: cert issue <域名> [--type rsa|ec] [--hosts a,b]"; return 1; }
    if ! cf_resolve_context "$domain"; then return 1; fi

    # 默认 hostnames = 域名本身
    if [[ -z "$hosts" ]]; then
        hosts="$CF_DOMAIN"
    fi
    [[ "$rtype" == "ec" || "$rtype" == "ecc" ]] && rtype="origin-ecc"

    local outdir="$CERT_OUT_DIR"
    mkdir -p "$outdir"
    chmod 700 "$outdir" 2>/dev/null || true
    local keyfile="$outdir/$CF_DOMAIN.key"
    local csrfile="$outdir/$CF_DOMAIN.csr"
    local crtfile="$outdir/$CF_DOMAIN.crt"

    # 1. 本地生成私钥 + CSR (幂等: 已有私钥则复用, 保证 renew 不影响在用证书)
    # M6: 记录私钥类型 (rsa/ec) 到标记文件, --type 与已有私钥冲突则重新生成
    local keytype="rsa" type_mark="$outdir/$CF_DOMAIN.keytype"
    [[ "$rtype" == "origin-ecc" ]] && keytype="ec"
    if [[ -f "$keyfile" ]] && [[ -f "$type_mark" ]] && [[ "$(cat "$type_mark")" != "$keytype" ]]; then
        print_warn "私钥类型 ($(cat "$type_mark")) 与请求 ($keytype) 不一致, 重新生成密钥"
        rm -f "$keyfile" "$type_mark"
    fi
    if [[ -f "$keyfile" ]]; then
        print_info "复用已有私钥: $keyfile ($keytype)"
        openssl req -new -key "$keyfile" -out "$csrfile" -subj "/CN=$CF_DOMAIN" 2>/dev/null
        csr_saved=true
    elif [[ "$keytype" == "ec" ]]; then
        openssl ecparam -genkey -name prime256v1 -noout -out "$keyfile" 2>/dev/null
        openssl req -new -key "$keyfile" -out "$csrfile" -subj "/CN=$CF_DOMAIN" 2>/dev/null
        csr_saved=true
        chmod 600 "$keyfile"
    else
        openssl req -new -newkey rsa:2048 -nodes \
            -keyout "$keyfile" -out "$csrfile" \
            -subj "/CN=$CF_DOMAIN" 2>/dev/null
        csr_saved=true
        chmod 600 "$keyfile"
    fi
    printf '%s\n' "$keytype" > "$type_mark" 2>/dev/null
    chmod 600 "$type_mark" 2>/dev/null || true
    [[ -f "$csrfile" ]] || { print_error "CSR 生成失败"; return 1; }

    # 2. 构造请求 (Global Key 认证 + CSR)
    local hostarr reqbody
    hostarr=$(echo "$hosts" | tr ',' '\n' | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
    reqbody=$(python3 -c "
import json,sys
csr=open(sys.argv[1]).read()
d={'hostnames':json.loads(sys.argv[2]),'requested_validity':5475,'request_type':sys.argv[3],'csr':csr}
print(json.dumps(d))" "$csrfile" "$hostarr" "$rtype")

    # 3. 调用 API (用当前账号凭据)
    local headers
    if [[ -n "${CF_TOKEN:-}" ]]; then
        headers=(-H "Authorization: Bearer $CF_TOKEN")
    else
        headers=(-H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY")
    fi
    local resp
    resp=$(curl -sS -4 --connect-timeout 8 -m 30 -X POST "$CF_API/certificates" \
        "${headers[@]}" \
        -H "Content-Type: application/json" \
        --data "$reqbody" 2>/dev/null)

    local ok id
    ok=$(json_get "$resp" "'OK' if d.get('success') else ''")
    if [[ -z "$ok" ]]; then
        log_write cert "$CF_DOMAIN" "issue" "failed" "$(json_error_code "$resp")"
        if $json; then
            printf '{"ok":false,"domain":"%s","error":"issue failed","cf_error_code":"%s"}\n' "$CF_DOMAIN" "$(json_error_code "$resp")"
        else
            print_error "证书签发失败: $(json_error_code "$resp") ($(redact_text "$resp" | head -c 300))"
        fi
        return 1
    fi

    id=$(json_get "$resp" "d['result']['id']")
    python3 -c "
import sys,json
d=json.loads(sys.argv[1])
open(sys.argv[2],'w').write(d['result']['certificate'])
" "$resp" "$crtfile"
    chmod 600 "$crtfile"
    rm -f "$csrfile"

    log_write cert "$CF_DOMAIN" "issue" "ok" ""
    if $json; then
        printf '{"ok":true,"domain":"%s","cert_id":"%s","crt":"%s","key":"%s"}\n' \
            "$CF_DOMAIN" "$id" "$crtfile" "$keyfile"
    else
        print_ok "证书签发完成 ($rtype): $CF_DOMAIN"
        print_info "  证书: $crtfile"
        print_info "  私钥: $keyfile (600)"
        print_info "  有效期: 15 年 (Origin CA, 回源 nginx 信任)"
        print_info "  证书ID: $id"
    fi
    return 0
}

cmd_cert_status() {
    local domain="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true; shift ;;
            *) domain="$1"; shift ;;
        esac
    done
    [[ -z "$domain" ]] && { print_error "用法: cert status <域名> [--json]"; return 1; }
    if ! cf_resolve_context "$domain"; then return 1; fi

    local resp
    local headers
    if [[ -n "${CF_TOKEN:-}" ]]; then
        headers=(-H "Authorization: Bearer $CF_TOKEN")
    else
        headers=(-H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY")
    fi
    # N2 fix: CF 该接口强制要求 zone_id (hostname= 会报 1012), 客户端再按 hostnames 过滤
    resp=$(curl -sS -4 --connect-timeout 8 -m 30 -X GET "$CF_API/certificates?zone_id=$CF_ZONE_ID" "${headers[@]}" 2>/dev/null)

    local line
    line=$(echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for c in (d.get('result') or []):
    if '$CF_DOMAIN' in c.get('hostnames',[]):
        print(c.get('id','')+'|'+str(c.get('expires_on',''))+'|'+c.get('request_type','')+'|'+','.join(c.get('hostnames',[])))
        break
")
    local crtfile="$CERT_OUT_DIR/$CF_DOMAIN.crt"
    if [[ -z "$line" ]]; then
        if $json; then
            printf '{"ok":true,"domain":"%s","origin_ca":"none","local_crt":%s}\n' \
                "$CF_DOMAIN" $([[ -f "$crtfile" ]] && echo true || echo false)
        else
            print_warn "该域名没有 Origin CA 证书 (本地: $([[ -f "$crtfile" ]] && echo 有 || echo 无))"
            print_info "可执行: cert issue $CF_DOMAIN"
        fi
        return 0
    fi
    IFS='|' read -r cid cexp ctype chosts <<< "$line"
    local expires
    expires=$(python3 -c "
import datetime,sys
try:
    d=datetime.datetime.strptime(sys.argv[1].strip(),'%Y-%m-%d %H:%M:%S %z UTC')
    print(str(d.date()))
except Exception:
    print(sys.argv[1] if sys.argv[1] else '?')" "$cexp")
    log_write cert "$CF_DOMAIN" "status" "ok" ""
    if $json; then
        printf '{"ok":true,"domain":"%s","origin_ca":{"id":"%s","expires":"%s","type":"%s","hostnames":"%s","local_crt":%s}}\n' \
            "$CF_DOMAIN" "$cid" "$expires" "$ctype" "$chosts" $([[ -f "$crtfile" ]] && echo true || echo false)
    else
        echo -e "  ${BOLD}Origin CA 证书:${PLAIN}"
        echo -e "     ID: $cid"
        echo -e "     到期: $expires"
        echo -e "     类型: $ctype"
        echo -e "     域名: $chosts"
        echo -e "     本地: $([[ -f "$crtfile" ]] && echo "有 ($crtfile)" || echo 无)"
    fi
    return 0
}

cmd_cert_renew() {
    local domain="" rtype="origin-rsa"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type) rtype="$2"; shift 2 ;;
            *) domain="$1"; shift ;;
        esac
    done
    [[ -z "$domain" ]] && { print_error "用法: cert renew <域名> [--type rsa|ec]"; return 1; }
    # renew = 重新签发 (Origin CA 无自动续期; 复用私钥)
    print_info "Origin CA 证书到期重签 (复用已有私钥)..."
    cmd_cert_issue "$domain" --type "$rtype"
}