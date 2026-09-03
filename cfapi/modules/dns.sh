#!/bin/bash
# =============================================================
#  dns.sh — DNS 记录管理 (幂等)
#  命令:
#    dns ensure <domain> <ip> [--proxy on|off|auto] [--ttl N]
#    dns ensure <domain> <ip> [--record CNAME <target>] [--record TXT <value>] ...
#    dns status <domain> [--json]
#    dns delete <domain> [--force]
#    dns list <domain>
# =============================================================

# 判断 IP 类型: 含冒号 → IPv6(AAAA), 否则 A
ip_type() {
    local v="$1"
    if [[ "$v" == *:* ]]; then echo "AAAA"; else echo "A"; fi
}

# 从 records json 找记录: $1=json $2=type $3=fqdn
# 输出: id|content|proxied(true/false小写)|ttl
dns_find_record() {
    local resp="$1" rtype="$2" fqdn="$3"
    python3 -c "
import sys,json
d=json.loads(sys.argv[1])
for r in (d.get('result') or []):
    if r['type']==sys.argv[2] and r['name']==sys.argv[3]:
        p=str(r.get('proxied',False)).lower()
        print(r['id']+'|'+r['content']+'|'+p+'|'+str(r.get('ttl','1')))
        break
" "$resp" "$rtype" "$fqdn"
}

cmd_dns_ensure() {
    local domain="" value="" proxy="auto" ttl="300" rtype="" rname="" target="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --proxy) proxy="${2,,}"; shift 2 ;;
            --ttl)   ttl="$2"; shift 2 ;;
            --record) rtype="$2"; rname="$3"; target="$4"; shift 4 ;;
            --json)  json=true; shift ;;
            *)
                if [[ -z "$domain" ]]; then domain="$1"
                elif [[ -z "$value" ]]; then value="$1"
                fi
                shift ;;
        esac
    done
    [[ -z "$domain" || -z "$value" ]] && { print_error "用法: dns ensure <域名> <IP|值> [--proxy on|off|auto] [--ttl N]"; return 1; }
    if ! cf_resolve_context "$domain"; then return 1; fi

    # 类型判断: --record 指定则用之, 否则 IP 自动 A/AAAA
    if [[ -n "$rtype" ]]; then
        : # CNAME/TXT/CAA 等, rname 可选 (@ = zone 根)
    else
        rtype=$(ip_type "$value")
    fi
    # fqdn 计算:
    #   --record 指定了 rname 时 → rname.zone 或 @ → zone
    #   未指定 rname 时 → 用 CF_DOMAIN (已小写, 保证与 CF 存储一致, 幂等成立)
    local fqdn
    if [[ -n "$rtype" && -n "$rname" ]]; then
        [[ "$rname" == "@" ]] && fqdn="$CF_ZONE" || fqdn="${rname,,}.$CF_ZONE"
    else
        fqdn="$CF_DOMAIN"
    fi

    # proxied 处理: on→true, off→false, auto→保持现有
    local proxied_bool=""
    if [[ "$proxy" == "on" || "$proxy" == "true" ]]; then proxied_bool="true"
    elif [[ "$proxy" == "off" || "$proxy" == "false" ]]; then proxied_bool="false"
    fi

    # 1. 查询现有
    local resp found id cur_content cur_proxied cur_ttl
    resp=$(cf_call_retry GET "/zones/$CF_ZONE_ID/dns_records?type=$rtype&name=$fqdn")
    found=$(dns_find_record "$resp" "$rtype" "$fqdn")

    local need_update=false reason=""
    if [[ -n "$found" ]]; then
        IFS='|' read -r id cur_content cur_proxied cur_ttl <<< "$found"
        # 幂等: 三要素对比 (content/proxied/ttl)
        if [[ "$cur_content" != "$value" ]]; then
            need_update=true; reason="IP 变化: $cur_content → $value"
        elif [[ -n "$proxied_bool" && "$cur_proxied" != "$proxied_bool" ]]; then
            need_update=true; reason="代理状态变化: $cur_proxied → $proxied_bool"
        elif [[ "$ttl" != "300" && "$cur_ttl" != "$ttl" ]]; then
            need_update=true; reason="TTL 变化: $cur_ttl → $ttl"
        fi
    fi

    if [[ -n "$found" && "$need_update" == "false" ]]; then
        log_write dns "$CF_DOMAIN" "ensure $rtype $fqdn" "already-configured" ""
        if $json; then
            printf '{"ok":true,"action":"already-configured","domain":"%s","type":"%s","name":"%s","content":"%s","proxied":%s,"ttl":%s}\n' \
                "$CF_DOMAIN" "$rtype" "$fqdn" "$value" "${proxied_bool:-$cur_proxied}" "${ttl}"
        else
            print_ok "DNS already configured: $fqdn → $value ($rtype)"
        fi
        return 0
    fi

    # 2. 创建或更新
    local body rc
    local pval
    local cur_proxied_bool="${cur_proxied:-false}"
    if [[ -z "$proxied_bool" ]]; then
        # auto: 保持现有
        pval=$([[ "$cur_proxied_bool" == "true" ]] && echo True || echo False)
    else
        pval=$([[ "$proxied_bool" == "true" ]] && echo True || echo False)
    fi
    # L5: 橙云(proxied)记录 CF 强制 ttl=1; 显式 --ttl 对代理记录无意义 → 统一 1
    #     否则 cur_ttl=1 vs 请求 ttl=300 永远"TTL 变化" → 幂等不成立
    # 注意: pval 是大写 True/False (python), 不能 `if $pval`, 要比较字符串
    if [[ "$pval" == "True" ]]; then ttl=1; fi
    if [[ -z "$found" ]]; then
        # 新建: proxied 仅 A/AAAA/CNAME 支持
        if [[ "$rtype" == "A" || "$rtype" == "AAAA" || "$rtype" == "CNAME" ]]; then
            body=$(python3 -c "
import json,sys
d={'type':'$rtype','name':'$fqdn','content':'$value','ttl':int('$ttl'),'proxied':$pval}
print(json.dumps(d))")
        else
            body=$(python3 -c "
import json,sys
d={'type':'$rtype','name':'$fqdn','content':'$value','ttl':int('$ttl')}
print(json.dumps(d))")
        fi
        resp=$(cf_call_retry POST "/zones/$CF_ZONE_ID/dns_records" "$body")
        if [[ -z "$(json_get "$resp" "'OK' if d.get('success') else ''")" ]]; then
            log_write dns "$CF_DOMAIN" "ensure $rtype $fqdn" "created-fail" "$(json_error_code "$resp")"
            if $json; then
                printf '{"ok":false,"action":"created","domain":"%s","type":"%s","name":"%s","error":"API rejected","cf_error_code":"%s"}\n' \
                    "$CF_DOMAIN" "$rtype" "$fqdn" "$(json_error_code "$resp")"
            else
                print_error "创建 $rtype 记录失败: $(json_error_code "$resp") $(redact_text "$resp" | head -c 200)"
            fi
            return 1
        fi
        log_write dns "$CF_DOMAIN" "ensure $rtype $fqdn" "created" "$(json_error_code "$resp")"
        if $json; then
            printf '{"ok":true,"action":"created","domain":"%s","type":"%s","name":"%s","content":"%s"}\n' \
                "$CF_DOMAIN" "$rtype" "$fqdn" "$value"
        else
            print_ok "已创建 $rtype 记录: $fqdn → $value ${proxied_bool:+ (proxy=$proxied_bool)}"
        fi
    else
        # 更新 (PATCH)
        body=$(python3 -c "
import json,sys
d={'content':'$value','ttl':int('$ttl')}
if '$rtype' in ('A','AAAA','CNAME'): d['proxied']=$pval
print(json.dumps(d))")
        resp=$(cf_call_retry PATCH "/zones/$CF_ZONE_ID/dns_records/$id" "$body")
        if [[ -z "$(json_get "$resp" "'OK' if d.get('success') else ''")" ]]; then
            log_write dns "$CF_DOMAIN" "ensure $rtype $fqdn" "updated-fail" "$(json_error_code "$resp")"
            if $json; then
                printf '{"ok":false,"action":"updated","domain":"%s","type":"%s","name":"%s","error":"API rejected","cf_error_code":"%s"}\n' \
                    "$CF_DOMAIN" "$rtype" "$fqdn" "$(json_error_code "$resp")"
            else
                print_error "更新 $rtype 记录失败: $(json_error_code "$resp") $(redact_text "$resp" | head -c 200)"
            fi
            return 1
        fi
        log_write dns "$CF_DOMAIN" "ensure $rtype $fqdn" "updated" "$(json_error_code "$resp")"
        if $json; then
            printf '{"ok":true,"action":"updated","domain":"%s","type":"%s","name":"%s","content":"%s","reason":"%s"}\n' \
                "$CF_DOMAIN" "$rtype" "$fqdn" "$value" "$reason"
        else
            print_ok "已更新 $rtype 记录: $fqdn → $value ($reason)"
        fi
    fi
    return 0
}

cmd_dns_status() {
    local domain="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true; shift ;;
            *) domain="$1"; shift ;;
        esac
    done
    [[ -z "$domain" ]] && { print_error "用法: dns status <域名> [--json]"; return 1; }
    if ! cf_resolve_context "$domain"; then return 1; fi
    local resp
    resp=$(cf_call_retry GET "/zones/$CF_ZONE_ID/dns_records?per_page=100&name=$CF_DOMAIN")
    local nrec
    nrec=$(echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(len(d.get('result') or []))" 2>/dev/null || echo 0)
    if $json; then
        echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(json.dumps([{'type':r['type'],'name':r['name'],'content':r['content'],'proxied':r.get('proxied',False),'ttl':r.get('ttl','1')} for r in (d.get('result') or [])]))"
        return 0
    fi
    echo -e "${CYAN}===== DNS 记录 ($CF_DOMAIN) =====${PLAIN}"
    if [[ "$nrec" == "0" ]]; then
        print_warn "该域名没有 DNS 记录"
        return 0
    fi
    echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for r in (d.get('result') or []):
    prox = '橙云' if r.get('proxied') else '灰云'
    print(f\"  {r['type']:>6}  {r['name']:<45} → {r['content']}  ({prox}, ttl={r.get('ttl','1')})\")"
}

cmd_dns_delete() {
    local domain="" force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            *) domain="$1"; shift ;;
        esac
    done
    [[ -z "$domain" ]] && { print_error "用法: dns delete <域名> [--force]"; return 1; }
    if [[ "$force" != "true" ]]; then
        print_error "删除 DNS 记录影响流量, 请显式加 --force 确认"
        return 1
    fi
    if ! cf_resolve_context "$domain"; then return 1; fi
    # 删除该域名下的 A/AAAA/CNAME/TXT 全部 (找不到则提示无)
    local resp ids
    resp=$(cf_call_retry GET "/zones/$CF_ZONE_ID/dns_records?per_page=100&name=$CF_DOMAIN")
    ids=$(echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for r in (d.get('result') or []):
    if r['name']=='$CF_DOMAIN' or r['name']=='$CF_DOMAIN.':
        print(r['id'])
")
    if [[ -z "$ids" ]]; then
        print_warn "域名 $CF_DOMAIN 没有 DNS 记录"
        return 0
    fi
    local n=0 id
    while read -r id; do
        [[ -z "$id" ]] && continue
        cf_call_retry DELETE "/zones/$CF_ZONE_ID/dns_records/$id" >/dev/null
        n=$((n+1))
    done <<< "$ids"
    log_write dns "$CF_DOMAIN" "delete" "ok ($n records)" ""
    print_ok "已删除 $n 条记录: $CF_DOMAIN"
}

cmd_dns_list() {
    local domain="$1"
    [[ -z "$domain" ]] && { print_error "用法: dns list <域名>"; return 1; }
    cmd_dns_status "$domain"
}