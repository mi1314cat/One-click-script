#!/bin/bash
# =============================================================
#  account.sh — 账户管理
#  命令: account list|add|remove|edit|test|default
# =============================================================

# 校验凭据有效性 + 自动获取 Account ID
account_verify() {
    # $1=name $2=email $3=token $4=is_global(0/1) $5=out_var_name(可选)
    local name="$1" email="$2" tok="$3" isg="$4"
    local headers
    if [[ "$isg" == "1" ]]; then
        headers=(-H "X-Auth-Email: $email" -H "X-Auth-Key: $tok")
    else
        headers=(-H "Authorization: Bearer $tok")
    fi
    local tmp code acct_id
    tmp=$(mktemp /tmp/cfav.XXXXXX)
    code=$(curl -sS -4 -o "$tmp" -w '%{http_code}' -X GET \
        "${headers[@]}" --connect-timeout 8 -m 20 "$CF_API/accounts?per_page=5" 2>/dev/null)
    if [[ "$code" == "200" ]]; then
        acct_id=$(python3 -c "
import json
d=json.load(open('$tmp'))
print((d.get('result') or [{}])[0].get('id','') if d.get('success') else '')
" 2>/dev/null)
        rm -f "$tmp"
        [[ -n "$acct_id" ]] && { echo "$acct_id"; return 0; }
        return 1
    fi
    rm -f "$tmp"
    return 1
}

cmd_account_list() {
    local json=false
    [[ "$1" == "--json" ]] && { json=true; shift; }
    local n=0 line
    if [[ ! -f "$CF_ACCOUNTS_FILE" ]] || [[ $(account_load_all | wc -l) -eq 0 ]]; then
        print_warn "还没有保存的账号: 运行 'cf-manager.sh account add' 添加"
        return 0
    fi
    if $json; then
        echo "["
        local first=true
        while IFS='|' read -r name email tok acctid def; do
            [[ -z "$name" ]] && continue
            $first || echo ","
            first=false
            printf '  {"name":"%s","email":"%s","token":"%s","account_id":"%s","default":%s}' \
                "$name" "$email" "$(mask_token "$tok")" "${acctid:-}" \
                $([[ "$def" == "yes" ]] && echo true || echo false)
        done < <(account_load_all)
        echo ""
        echo "]"
        return 0
    fi
    echo -e "${CYAN}===== Cloudflare 账号 =====${PLAIN}"
    while IFS='|' read -r name email tok acctid def; do
        [[ -z "$name" ]] && continue
        n=$((n+1))
        local tag=""
        [[ "$def" == "yes" ]] && tag=" ${GREEN}(默认)${PLAIN}"
        echo -e "  ${YELLOW}${n}${PLAIN}. ${BOLD}${name}${PLAIN}${tag}"
        echo -e "     Email: ${email}"
        echo -e "     Token: $(mask_token "$tok")"
        echo -e "     Account ID: ${acctid:-}(未获取)"
    done < <(account_load_all)
}

cmd_account_add() {
    local name email token save="y" from_env=false
    # 参数化 (支持 --name --email --token --no-save)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)  name="$2"; shift 2 ;;
            --email) email="$2"; shift 2 ;;
            --token) token="$2"; shift 2 ;;
            --no-save) save="n"; shift ;;
            *) shift ;;
        esac
    done
    if [[ -z "$name" ]]; then
        printf "账号名称: " >&2; read -r name
    fi
    if [[ -z "$email" ]]; then
        printf "Cloudflare 登录邮箱: " >&2; read -r email
    fi
    if [[ -z "$token" ]]; then
        printf "API Token 或 Global API Key (key:开头表示 Global Key): " >&2; read -r token
    fi
    name=$(echo "$name" | tr -cd '[:alnum:]_-')
    [[ -z "$name" ]] && { print_error "账号名不能为空"; return 1; }
    [[ -z "$token" ]] && { print_error "Token 不能为空"; return 1; }

    # 自动识别 token 类型
    local isg=0 tok_plain="$token"
    [[ "$tok_plain" == key:* ]] && { isg=1; tok_plain="${tok_plain#key:}"; }

    # 验证 + 自动获取 account_id
    print_info "验证凭据..."
    local acct_id
    acct_id=$(account_verify "$name" "$email" "$tok_plain" "$isg")
    if [[ -z "$acct_id" ]]; then
        print_error "凭据验证失败 (Token 无效或无账号访问权限)"
        return 1
    fi
    print_ok "凭据有效, Account ID 已获取: $acct_id"

    if [[ "$save" == "n" ]]; then
        print_warn "未保存 Token (仅本次运行), 请用环境变量 CF_API_TOKEN 传递"
        CF_EMAIL="$email"; CF_TOKEN="$tok_plain"; CF_NAME="$name"
        CF_ACCOUNT_ID="$acct_id"; CF_TOKEN_SAVED=false
        return 0
    fi

    # 是否设为默认 (第一个账号自动默认)
    local isdefault="no"
    if [[ -z "$(account_load_all | head -1)" ]]; then
        isdefault="yes"
    fi
    [[ "$isdefault" == "yes" ]] || printf "设为默认账号? [y/N]: " >&2 && read -r dflt
    [[ "${dflt,,}" == "y" || "${dflt,,}" == "yes" ]] && isdefault="yes"

    # 若设为默认, 清除其他默认标记
    if [[ "$isdefault" == "yes" ]]; then
        local cur
        if [[ -f "$CF_ACCOUNTS_FILE" ]]; then
            awk -F'|' -v OFS='|' 'NR>1 && NF>=5 { $5="no" } { print }' "$CF_ACCOUNTS_FILE" > "$CF_ACCOUNTS_FILE.tmp" && mv "$CF_ACCOUNTS_FILE.tmp" "$CF_ACCOUNTS_FILE"
        fi
    fi
    account_save "$name" "$email" "$token" "$acct_id" "$isdefault"
    print_ok "已保存账号: $name ($email)"
    print_info "配置文件: $CF_ACCOUNTS_FILE (权限 600)"
}

cmd_account_remove() {
    local name="$1"
    [[ -z "$name" ]] && { print_error "用法: account remove <名称>"; return 1; }
    if account_by_name "$name" >/dev/null; then
        account_remove "$name"
        print_ok "已删除账号: $name (含缓存)"
    else
        print_error "没有账号: $name"
        return 1
    fi
}

cmd_account_edit() {
    local name="$1"
    [[ -z "$name" ]] && { print_error "用法: account edit <名称>"; return 1; }
    local line
    line=$(account_by_name "$name") || { print_error "没有账号: $name"; return 1; }
    IFS='|' read -r _ email tok acctid def <<< "$line"
    print_info "当前: $name <$email> Token=$(mask_token "$tok")"
    printf "新 Token (留空不变): " >&2; read -r newtok
    [[ -n "$newtok" ]] && tok="$newtok"
    local isg=0 tplain="$tok"
    [[ "$tplain" == key:* ]] && { isg=1; tplain="${tplain#key:}"; }
    local newid
    newid=$(account_verify "$name" "$email" "$tplain" "$isg")
    [[ -z "$newid" ]] && { print_error "新 Token 无效"; return 1; }
    account_save "$name" "$email" "$tok" "$newid" "$def"
    cf_cache_clear
    print_ok "账号 $name 已更新 (Account ID: $newid)"
}

cmd_account_test() {
    local name="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true; shift ;;
            *) name="$1"; shift ;;
        esac
    done
    if [[ -z "$name" ]]; then
        local def
        def=$(account_default)
        [[ -z "$def" ]] && { print_error "无账号"; return 1; }
        name=$(echo "$def" | cut -d'|' -f1)
    fi
    local line
    line=$(account_by_name "$name") || { print_error "没有账号: $name"; return 1; }
    IFS='|' read -r nm email tok acctid _ <<< "$line"
    local isg=0 tplain="$tok"
    [[ "$tplain" == key:* ]] && { isg=1; tplain="${tplain#key:}"; }
    local headers
    if [[ "$isg" == "1" ]]; then
        headers=(-H "X-Auth-Email: $email" -H "X-Auth-Key: $tplain")
    else
        headers=(-H "Authorization: Bearer $tplain")
    fi
    local code zones_ok=false tmp1 tmp2
    tmp1=$(mktemp /tmp/cft.XXXXXX); tmp2=$(mktemp /tmp/cft2.XXXXXX)
    code=$(curl -sS -4 -o "$tmp1" -w '%{http_code}' -X GET \
        "${headers[@]}" --connect-timeout 8 -m 20 "$CF_API/accounts?per_page=5" 2>/dev/null)
    local acct_name=""
    if [[ "$code" == "200" ]]; then
        acct_name=$(python3 -c "
import json
d=json.load(open('$tmp1'))
print((d.get('result') or [{}])[0].get('name','') if d.get('success') else '')
" 2>/dev/null)
    fi

    # 测 zones 权限
    code=$(curl -sS -4 -o "$tmp2" -w '%{http_code}' -X GET \
        "${headers[@]}" --connect-timeout 8 -m 20 "$CF_API/zones?per_page=1" 2>/dev/null)
    [[ "$code" == "200" ]] && zones_ok=true
    rm -f "$tmp1" "$tmp2"

    if $json; then
        printf '{"name":"%s","email":"%s","account_name":"%s","zones_permission":%s,"ok":%s}\n' \
            "$nm" "$email" "$acct_name" $($zones_ok && echo true || echo false) \
            $([[ -n "$acct_name" ]] && echo true || echo false)
        return 0
    fi
    if [[ -n "$acct_name" ]]; then
        print_ok "账号有效: $nm → $acct_name"
        print_info "Zones 权限: $($zones_ok && echo OK || echo '无权限(需 Zone:Read)')"
        return 0
    else
        print_error "凭据无效或无访问权限"
        return 1
    fi
}

cmd_account_default() {
    local name="${1:-}"
    [[ -z "$name" ]] && { print_error "用法: account default <名称>"; return 1; }
    local line
    line=$(account_by_name "$name") || { print_error "没有账号: $name"; return 1; }
    IFS='|' read -r nm email tok acctid _ <<< "$line"
    # 清除其它默认
    awk -F'|' -v OFS='|' 'NR>1 && NF>=5 { $5="no" } { print }' "$CF_ACCOUNTS_FILE" > "$CF_ACCOUNTS_FILE.tmp" && mv "$CF_ACCOUNTS_FILE.tmp" "$CF_ACCOUNTS_FILE"
    account_save "$nm" "$email" "$tok" "$acctid" "yes"
    print_ok "已设默认账号: $name"
}