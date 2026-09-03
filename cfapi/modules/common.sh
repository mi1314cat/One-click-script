#!/bin/bash
# =============================================================
#  common.sh — Cloudflare Manager 公共库
#  职责: 颜色/日志/脱敏/JSON/curl 封装/退出码/配置解析
#  被所有模块 source, 不依赖其他模块
# =============================================================

if locale -a 2>/dev/null | grep -qi 'C.utf8'; then
    export LC_ALL=C.UTF-8
fi

# ---------- 全局常量 ----------
export CF_BASE_DIR="${CF_BASE_DIR:-/root/catmi/cloudflare}"
CF_MODULES_DIR="$CF_BASE_DIR/modules"
CF_CONFIG_DIR="$CF_BASE_DIR/config"
CF_CACHE_DIR="$CF_BASE_DIR/cache"
CF_LOG_DIR="$CF_BASE_DIR/logs"
CF_CERTS_DIR="$CF_BASE_DIR/certs"

CF_ACCOUNTS_FILE="$CF_CONFIG_DIR/accounts.conf"
CF_CACHE_FILE="$CF_CACHE_DIR/context.cache"
CF_LOG_FILE="$CF_LOG_DIR/cf-manager.log"
CF_CACHE_TTL=600          # 10 分钟

CF_API="https://api.cloudflare.com/client/v4"

# ---------- 颜色 ----------
export RED GREEN YELLOW BLUE MAGENTA CYAN GRAY PLAIN BOLD
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[36m"; MAGENTA="\033[35m"; CYAN="\033[96m"
GRAY="\033[90m"; PLAIN="\033[0m"; BOLD="\033[1m"

# ---------- 日志 ----------
CF_LOG_FD=-1
log_init() {
    mkdir -p "$CF_LOG_DIR" 2>/dev/null
    # 仅第一个打开的 FD 使用, 防止重复
    { exec 9>>"$CF_LOG_FILE"; } 2>/dev/null && CF_LOG_FD=9
}
# 日志只记录: 时间 功能 域名 操作 结果 错误码 (绝不记录 token/key/私钥)
log_write() {
    # $1=模块 $2=域名 $3=操作 $4=结果 $5=错误码
    [[ $CF_LOG_FD -gt 0 ]] || return 0
    local ts now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s | %s | %s | %s | %s | %s\n' \
        "$now" "$1" "${2:-}" "${3:-}" "${4:-}" "${5:-}" >&$CF_LOG_FD
}

# ---------- 输出 ----------
print_info()  { echo -e "${GREEN}[Info]${PLAIN} $1"; }
print_ok()    { echo -e "${GREEN}[OK]${PLAIN} $1"; }
print_warn()  { echo -e "${YELLOW}[Warn]${PLAIN} $1"; }
print_error() { echo -e "${RED}[Error]${PLAIN} $1"; }

# ---------- Token 脱敏 ----------
# mask_token "完整token" → "********后4位"
mask_token() {
    local t="${1:-}"
    [[ -z "$t" ]] && { echo "(empty)"; return; }
    if [[ ${#t} -gt 4 ]]; then
        echo "********${t: -4}"
    else
        echo "********"
    fi
}

# 对任意文本中的 token 脱敏 (从配置读取)
redact_text() {
    local text="$1" t
    # 逐账号把 token 替换
    if [[ -f "$CF_ACCOUNTS_FILE" ]]; then
        while IFS='|' read -r name email token acctid def; do
            [[ -n "$token" ]] && text="${text//$token/********}"
        done < <(awk -F'|' 'NR>1 && NF>=3 {print}' "$CF_ACCOUNTS_FILE" 2>/dev/null)
    fi
    # 环境变量 token
    [[ -n "${CF_API_TOKEN:-}" ]] && text="${text//$CF_API_TOKEN/********}"
    echo "$text"
}

# ---------- JSON ----------
# 从 JSON 取字段 (python3 标准库)
json_get() {
    # $1=json字符串 $2=python表达式 (d=json对象)
    python3 -c "
import sys,json
try:
    d=json.loads(sys.argv[1])
    print($2)
except Exception:
    sys.exit(1)
" "$1" 2>/dev/null
}

json_ok() {
    # $1=json字符串 → 是否 success
    json_get "$1" "'OK' if d.get('success') else ''"
}

json_error_code() {
    # $1=json字符串 → 第一个错误码
    json_get "$1" "str((d.get('errors') or [{}])[0].get('code','')) if not d.get('success') else ''"
}

# ---------- curl 封装 (统一 header + 脱敏调试) ----------
# cf_call METHOD PATH [JSON_BODY] [CODE_FILE]
# 返回: 输出到 stdout (响应体), 设置 CF_HTTP_CODE
# 注意: 若在 $(...) 子 shell 中调用, CF_HTTP_CODE 传不回外层!
#       需传 CODE_FILE 路径 (cf_call_retry 内部用它, 外部调用请在主 shell 直接用)
cf_call() {
    local method="$1" path="$2" body="${3:-}" code_file="${4:-}"
    local headers=()
    if [[ -n "${CF_TOKEN:-}" ]]; then
        headers=(-H "Authorization: Bearer $CF_TOKEN")
    elif [[ -n "${CF_EMAIL:-}" && -n "${CF_KEY:-}" ]]; then
        headers=(-H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY")
    fi
    [[ -n "$body" ]] && headers+=(-H "Content-Type: application/json" --data "$body")

    local out tmp
    tmp=$(mktemp /tmp/cfapi.XXXXXX)
    local code
    code=$(curl -sS -4 -o "$tmp" -w '%{http_code}' -X "$method" \
        "${headers[@]}" \
        --connect-timeout 8 -m 30 \
        "$CF_API$path" 2>/dev/null)
    CF_HTTP_CODE="$code"
    [[ -n "$code_file" ]] && printf '%s' "$code" > "$code_file"
    cat "$tmp"
    rm -f "$tmp"
}

# 429/5xx/网络失败(000/空) 重试 (最多3次)
# N1 fix: $(cf_call) 子 shell 丢 CF_HTTP_CODE → 用 code 文件透传, 避免每次请求无条件重试3次
cf_call_retry() {
    local method="$1" path="$2" body="${3:-}" attempt=0 out code
    local codefile
    codefile=$(mktemp /tmp/cfapi-code.XXXXXX)
    while (( attempt < 3 )); do
        out=$(cf_call "$method" "$path" "$body" "$codefile")
        code=$(cat "$codefile" 2>/dev/null)
        CF_HTTP_CODE="$code"
        if [[ "$code" == "429" ]] || [[ "$code" -ge 500 ]] || [[ -z "$code" || "$code" == "000" ]]; then
            attempt=$((attempt + 1))
            sleep 1
            continue
        fi
        break
    done
    rm -f "$codefile"
    echo "$out"
}

# ---------- 退出码统一 ----------
# 子命令成功/已满足目标 → 0; 失败 → 非0
cf_exit_ok()    { return 0; }
cf_exit_fail()  { return 1; }

# ---------- 幂等工具 ----------
# strip 域名: 小写/去 scheme/去路径/去尾点/去端口 (L9)
normalize_domain() {
    local d="${1,,}"
    d="${d#https://}"; d="${d#http://}"
    d="${d%%/*}"
    d="${d%.}"
    d="${d%%:*}"
    printf '%s\n' "$d"
}