#!/bin/bash
# =============================================================
#  context.sh — Domain Context (核心)
#  输入域名 → 自动定位 (Account, Token, Zone, Zone ID)
#  全部以 Cloudflare API 返回的真实 Zone 为准, 不猜 TLD
# =============================================================

# ---------- 账户配置解析 ----------
# 格式 (accounts.conf):
#   name|email|token|account_id(可为空)|default(yes/no)
# 首行: #name|email|token|account_id|default  (表头注释, 不解析)
account_load_all() {
    # 输出: 每行 name email token account_id isdefault
    [[ -f "$CF_ACCOUNTS_FILE" ]] || return 0
    awk -F'|' 'NR>1 && NF>=3 && $1 !~ /^[[:space:]]*#/ {print}' "$CF_ACCOUNTS_FILE"
}

account_by_name() {
    # $1=name → 输出 name|email|token|account_id|isdefault
    local name="$1"
    [[ -f "$CF_ACCOUNTS_FILE" ]] || return 1
    awk -F'|' -v n="$name" 'NR>1 && $1==n {print; found=1} END{exit !found}' "$CF_ACCOUNTS_FILE"
}

account_default() {
    # 输出默认账号或第一个
    [[ -f "$CF_ACCOUNTS_FILE" ]] || return 0
    local line
    line=$(awk -F'|' 'NR>1 && NF>=3 && $5=="yes" {print; exit}' "$CF_ACCOUNTS_FILE")
    [[ -z "$line" ]] && line=$(awk -F'|' 'NR>1 && NF>=3 {print; exit}' "$CF_ACCOUNTS_FILE")
    echo "$line"
}

account_save() {
    # $1=name $2=email $3=token $4=account_id $5=default
    mkdir -p "$CF_CONFIG_DIR"
    local tmp="$CF_ACCOUNTS_FILE.tmp"
    if [[ ! -f "$CF_ACCOUNTS_FILE" ]]; then
        echo "# name|email|token|account_id|default" > "$tmp"
    else
        cp "$CF_ACCOUNTS_FILE" "$tmp"
    fi
    # 同 name 覆盖
    local found=false line
    while IFS='|' read -r n e t a d; do
        [[ -z "$n" ]] && continue
        if [[ "$n" == "$1" ]]; then
            echo "$1|$2|$3|$4|$5"; found=true
        else
            echo "$n|$e|$t|$a|$d"
        fi
    done < "$tmp" > "$tmp.2"
    if ! $found; then
        echo "$1|$2|$3|$4|$5" >> "$tmp.2"
    fi
    mv "$tmp.2" "$CF_ACCOUNTS_FILE"
    chmod 600 "$CF_ACCOUNTS_FILE"
    chmod 700 "$CF_CONFIG_DIR" 2>/dev/null || true
    rm -f "$tmp"
}

account_remove() {
    local name="$1"
    [[ -f "$CF_ACCOUNTS_FILE" ]] || return 1
    grep -v "^$name|" "$CF_ACCOUNTS_FILE" > "$CF_ACCOUNTS_FILE.tmp" || true
    mv "$CF_ACCOUNTS_FILE.tmp" "$CF_ACCOUNTS_FILE"
    chmod 600 "$CF_ACCOUNTS_FILE"
    # 清理该账号缓存
    cf_cache_remove_account "$name"
}

# ---------- 指定账号凭据 (用于所有 API 调用) ----------
# cf_use_account <name> → 设置全局 CF_NAME/CF_EMAIL/CF_KEY/CF_TOKEN/CF_ACCOUNT_ID/CF_TOKEN_SAVED
cf_use_account() {
    local name="$1" line
    line=$(account_by_name "$name") || return 1
    IFS='|' read -r CF_NAME CF_EMAIL CF_KEY CF_ACCOUNT_ID CF_IS_DEFAULT <<< "$line"
    CF_TOKEN=""            # 优先 API token; accounts.conf 存的是 token (兼容存 key 情况)
    # 若单元格开头是 "key:" 则为 Global Key, 否则视为 API Token
    if [[ "$CF_KEY" == key:* ]]; then
        CF_KEY="${CF_KEY#key:}"
        CF_TOKEN=""
    else
        CF_TOKEN="$CF_KEY"
        CF_KEY=""
    fi
    CF_TOKEN_SAVED=true
    return 0
}

# 从环境变量构造临时凭据 (不落盘)
cf_use_env() {
    CF_NAME="env"
    CF_EMAIL=""; CF_KEY=""; CF_TOKEN="${CF_API_TOKEN:-}"
    CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
    CF_TOKEN_SAVED=false
    [[ -n "$CF_TOKEN" ]] || [[ -n "$CF_KEY" ]]
}

# ---------- 缓存 ----------
cf_cache_read_lookup() {
    # $1=domain → 输出 suffix|zone_id|account_name  (未过期才返回)
    local domain="$1" now
    [[ -f "$CF_CACHE_FILE" ]] || return 1
    now=$(date +%s)
    # 先找最长后缀匹配的缓存项
    awk -F'|' -v d="$domain" -v now="$now" -v ttl="$CF_CACHE_TTL" '
        $1 != "" && (d == $1 || d ~ ("\\." $1 "$")) && (now - $4) < ttl {
            if (length($1) > best) { best = length($1); line = $0 }
        }
        END { if (line != "") print line }' "$CF_CACHE_FILE"
}

cf_cache_write() {
    # $1=suffix $2=zone_id $3=account_name
    mkdir -p "$CF_CACHE_DIR"
    touch "$CF_CACHE_FILE"
    chmod 600 "$CF_CACHE_FILE" 2>/dev/null || true
    local now tmp
    now=$(date +%s)
    tmp="$CF_CACHE_FILE.tmp"
    grep -v "^$1|" "$CF_CACHE_FILE" > "$tmp" 2>/dev/null || true
    echo "$1|$2|$3|$now" >> "$tmp"
    mv "$tmp" "$CF_CACHE_FILE"
    chmod 600 "$CF_CACHE_FILE" 2>/dev/null || true
}

cf_cache_clear() {
    rm -f "$CF_CACHE_FILE"
    print_ok "缓存已清空"
}

cf_cache_remove_account() {
    # $1=account_name → 删除该账号所有缓存项
    [[ -f "$CF_CACHE_FILE" ]] || return 0
    grep -v "|$1|" "$CF_CACHE_FILE" > "$CF_CACHE_FILE.tmp" 2>/dev/null || true
    mv "$CF_CACHE_FILE.tmp" "$CF_CACHE_FILE" 2>/dev/null || true
}

# ---------- 账号 zones 查询 (带 token 试配) ----------
# 对单个账号: 列出所有 zones (name|id)
account_zones() {
    # $1=name $2=email $3=token_or_key $4=is_global(0/1)
    local name="$1" email="$2" tok="$3" isg="$4"
    local headers
    if [[ "$isg" == "1" ]]; then
        headers=(-H "X-Auth-Email: $email" -H "X-Auth-Key: $tok")
    else
        headers=(-H "Authorization: Bearer $tok")
    fi
    local tmp
    tmp=$(mktemp /tmp/cfz.XXXXXX)
    local code
    code=$(curl -sS -4 -o "$tmp" -w '%{http_code}' -X GET \
        "${headers[@]}" --connect-timeout 8 -m 20 \
        "$CF_API/zones?per_page=50&status=active" 2>/dev/null)
    if [[ "$code" == "200" ]]; then
        python3 -c "
import sys,json
d=json.load(open('$tmp'))
for z in (d.get('result') or []):
    print(z['name'] + '|' + z['id'])
" 2>/dev/null
    fi
    rm -f "$tmp"
}

# ---------- Domain Context 主入口 ----------
# cf_resolve_context <domain>
# 成功: 设置全局 CF_DOMAIN CF_ZONE CF_ZONE_ID CF_NAME CF_EMAIL CF_KEY CF_TOKEN CF_ACCOUNT_ID
# 失败: 返回 1, 输出错误信息
cf_resolve_context() {
    local domain="$1"
    domain=$(normalize_domain "$domain")
    [[ -z "$domain" ]] && { print_error "域名为空"; return 1; }
    CF_DOMAIN="$domain"

    # 1. 环境变量优先 (CF_API_TOKEN)
    if [[ -n "${CF_API_TOKEN:-}" || -n "${CF_API_KEY:-}" ]]; then
        cf_use_env
        # 用默认账号的 email (若 token 模式不需要)
        if [[ -n "${CF_API_KEY:-}" && -n "${CF_API_EMAIL:-}" ]]; then
            CF_KEY="${CF_API_KEY}"; CF_EMAIL="${CF_API_EMAIL}"; CF_TOKEN=""
        fi
        local zresult
        if zresult=$(cf_find_zone_in_current "$domain"); then
            CF_ZONE=$(echo "$zresult" | cut -d'|' -f1)
            CF_ZONE_ID=$(echo "$zresult" | cut -d'|' -f2)
            return 0
        fi
        print_error "环境变量凭据下找不到域名 $domain 的 zone"
        return 1
    fi

    # 2. 缓存 (仅用于已知账号的快速路径, 且需再次校验有效性)
    local cached suffix zid acct zresult
    cached=$(cf_cache_read_lookup "$domain")
    if [[ -n "$cached" ]]; then
        IFS='|' read -r suffix zid acct _ <<< "$cached"
        if cf_use_account "$acct"; then
            # 校验: 该 zone 是否仍归此账号
            if zresult=$(cf_find_zone_in_current "$domain"); then
                CF_ZONE=$(echo "$zresult" | cut -d'|' -f1)
                CF_ZONE_ID=$(echo "$zresult" | cut -d'|' -f2)
                return 0
            fi
        fi
        # 缓存失效 → 继续全量匹配
    fi

    # 3. 全量匹配: 遍历所有账号
    local line name email tok isg zone_hit acc_hit=""
    local best_zone="" best_zid="" best_acct=""
    while IFS='|' read -r name email tok acctid _; do
        [[ -z "$name" || -z "$tok" ]] && continue
        isg=0; [[ "$tok" == key:* ]] && { isg=1; tok="${tok#key:}"; }
        # $email 在 key 模式下需要; token 模式可空
        local zl
        zl=$(account_zones "$name" "$email" "$tok" "$isg")
        [[ -z "$zl" ]] && continue
        while IFS='|' read -r zname zid2; do
            [[ -z "$zname" ]] && continue
            # 匹配: 精确 or 域名以 .zone 结尾 (最长优先)
            if [[ "$domain" == "$zname" ]] || [[ "$domain" == *".$zname" ]]; then
                if [[ ${#zname} -gt ${#best_zone} ]]; then
                    best_zone="$zname"; best_zid="$zid2"; best_acct="$name"
                fi
            fi
        done <<< "$zl"
    done < <(account_load_all)

    if [[ -n "$best_zone" ]]; then
        cf_use_account "$best_acct" || return 1
        CF_ZONE="$best_zone"; CF_ZONE_ID="$best_zid"
        cf_cache_write "$best_zone" "$best_zid" "$best_acct"
        return 0
    fi

    print_error "域名 $domain 不在任何已保存账号的 zone 下 (先 account add 并确认域名托管在 CF)"
    return 1
}

# 在"当前已设凭据"下找 domain 的 zone (精确→最长后缀)
# 输出: "zone名|zone_id" (stdout), 失败无输出
cf_find_zone_in_current() {
    local domain="$1"
    local zl zname zid2 best="" bestid=""
    local isg=0 thetok="${CF_TOKEN:-$CF_KEY}"
    [[ -z "${CF_TOKEN:-}" ]] && isg=1
    zl=$(account_zones "$CF_NAME" "$CF_EMAIL" "$thetok" "$isg")
    while IFS='|' read -r zname zid2; do
        [[ -z "$zname" ]] && continue
        if [[ "$domain" == "$zname" ]] || [[ "$domain" == *".$zname" ]]; then
            if [[ ${#zname} -gt ${#best} ]]; then
                best="$zname"; bestid="$zid2"
            fi
        fi
    done <<< "$zl"
    [[ -n "$bestid" ]] && { printf '%s|%s\n' "$best" "$bestid"; return 0; }
    return 1
}