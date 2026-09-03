#!/bin/bash
# =============================================================
#  origin.sh — 回源端口 Origin Rules
#  命令:
#    origin port <domain> <port> [--path /xxx] [--delete] [--list]
#  官方 API: rulesets phase=http_request_origin
#    GET  /zones/{zid}/rulesets/phases/http_request_origin/entrypoint
#    PUT  /zones/{zid}/rulesets/phases/http_request_origin/entrypoint
# =============================================================

origin_get_ruleset() {
    # 输出当前 ruleset JSON (仅当 200; 失败输出空)
    cf_call_retry GET "/zones/$CF_ZONE_ID/rulesets/phases/http_request_origin/entrypoint"
}

# 取规则数组; GET 失败返回非0, 绝不返回"空数组"让调用方误判 (防误清空)
origin_get_rules_array() {
    local resp rules_json
    resp=$(origin_get_ruleset)
    literal_ok=$(json_get "$resp" "'OK' if d.get('success') else ''")
    if [[ -z "$literal_ok" ]]; then
        print_error "获取现有回源规则失败 (CF_HTTP_CODE=$CF_HTTP_CODE), 拒绝继续避免误删现有规则"
        return 1
    fi
    rules_json=$(echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(json.dumps((d.get('result') or {}).get('rules') or []))")
    echo "$rules_json"
    return 0
}

origin_put_ruleset() {
    # $1=new rules 数组JSON
    local rules_json="$1"
    cf_call_retry PUT "/zones/$CF_ZONE_ID/rulesets/phases/http_request_origin/entrypoint" \
        "{\"rules\": $rules_json}"
}

cmd_origin_port() {
    local domain="" port="" path="" action="add" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --path) path="$2"; shift 2 ;;
            --delete) action="delete"; shift ;;
            --list)  action="list"; shift ;;
            --json)  json=true; shift ;;
            *)
                if [[ -z "$domain" ]]; then domain="$1"
                elif [[ -z "$port" ]]; then port="$1"
                fi
                shift ;;
        esac
    done

    if [[ "$action" == "list" ]]; then
        [[ -z "$domain" ]] && { print_error "用法: origin list <域名>"; return 1; }
        if ! cf_resolve_context "$domain"; then return 1; fi
        local resp
        resp=$(origin_get_ruleset)
        if $json; then
            echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(json.dumps([{'port':(r.get('action_parameters') or {}).get('origin',{}).get('port'),'expression':r.get('expression'),'id':r.get('id')} for r in (d.get('result') or {}).get('rules') or []]))"
            return 0
        fi
        echo -e "${CYAN}===== 回源端口规则 ($CF_ZONE) =====${PLAIN}"
        echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
rules=(d.get('result') or {}).get('rules') or []
if not rules:
    print('  (无回源规则)')
for r in rules:
    port=(r.get('action_parameters') or {}).get('origin',{}).get('port','?')
    print(f\"  端口 {port:<6} | {r.get('expression','')}  [{r.get('id','')[:8]}]\")"
        return 0
    fi

    [[ -z "$domain" || -z "$port" ]] && { print_error "用法: origin port <域名> <端口> [--path /xxx] [--delete]"; return 1; }
    [[ "$port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; return 1; }
    if ! cf_resolve_context "$domain"; then return 1; fi

    local expr
    # H3修复: 用用户给的域名 (CF_DOMAIN 已小写) 而非 zone 顶点
    #   → 子域名规则 http.host eq "sub.zone" 正确匹配子域名流量
    if [[ -n "$path" ]]; then
        expr="(http.host eq \"$CF_DOMAIN\" and starts_with(http.request.uri.path, \"$path\"))"
    else
        expr="(http.host eq \"$CF_DOMAIN\")"
    fi

    # 现有规则列表 (GET 失败→返回1, 绝不误清空)
    local rules_json
    rules_json=$(origin_get_rules_array) || return 1

    if [[ "$action" == "delete" ]]; then
        local new_json
        new_json=$(python3 -c "
import sys,json
rules=json.loads(sys.argv[1])
port=int(sys.argv[2])
kept=[r for r in rules if (r.get('action_parameters') or {}).get('origin',{}).get('port')!=port]
print(json.dumps(kept))" "$rules_json" "$port")
        # 幂等: 原本就没有 → 直接成功
        if [[ "$new_json" == "$rules_json" ]]; then
            print_ok "回源端口 $port 规则不存在, 无需删除"
            return 0
        fi
        local out
        out=$(origin_put_ruleset "$new_json")
        local ok
        ok=$(json_get "$out" "'OK' if d.get('success') else ''")
        if [[ -n "$ok" ]]; then
            log_write origin "$CF_DOMAIN" "port delete $port" "ok" ""
            print_ok "已删除回源端口规则: $port ($expr)"
            return 0
        else
            log_write origin "$CF_DOMAIN" "port delete $port" "failed" "$(json_error_code "$out")"
            print_error "删除失败: $(redact_text "$out")"
            return 1
        fi
    fi

    # add
    local new_json
    new_json=$(python3 -c "
import sys,json
rules=json.loads(sys.argv[1])
port=int(sys.argv[2])
expr=sys.argv[3]
# 幂等: 同端口+同表达式已存在 → 不重复
for r in rules:
    if (r.get('action_parameters') or {}).get('origin',{}).get('port')==port and r.get('expression')==expr:
        sys.exit(2)  # 已存在
rules.append({'expression':expr,'action':'route','action_parameters':{'origin':{'port':port}},'description':'cf-manager origin port '+str(port)})
print(json.dumps(rules))" "$rules_json" "$port" "$expr")
    local rc=$?
    if [[ $rc -eq 2 ]]; then
        print_ok "回源规则已存在: 端口 $port ($expr)"
        return 0
    fi
    local out
    out=$(origin_put_ruleset "$new_json")
    local ok
    ok=$(json_get "$out" "'OK' if d.get('success') else ''")
    if [[ -n "$ok" ]]; then
        log_write origin "$CF_DOMAIN" "port add $port" "ok" ""
        print_ok "已添加回源端口规则: $port ($expr)"
        return 0
    else
        log_write origin "$CF_DOMAIN" "port add $port" "failed" "$(json_error_code "$out")"
        print_error "添加失败: $(redact_text "$out")"
        return 1
    fi
}