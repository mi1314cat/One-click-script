#!/usr/bin/env bash
set -e

# ================================
# 基础路径
# ================================
BASE_DIR="/root/catmi/argo_temp"
BIN="$BASE_DIR/cloudflared"
TEMP_LOG="$BASE_DIR/temp.log"
SD_FILE="$BASE_DIR/SD_domain.txt"
WATCHDOG_SCRIPT="$BASE_DIR/watchdog.sh"
FAIL_COUNT_FILE="$BASE_DIR/.fail_count"
UPDATE_NODES="$BASE_DIR/update_nodes.sh"          # 外部脚本（如果有）

DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

mkdir -p "$BASE_DIR"

# ================================
# 工具函数：安全加载 / 更新 .env（支持无外层引号的值）
# ================================
load_env() {
    local env_file="$1"
    [[ -z "$env_file" ]] && { echo "错误：必须传入 env 文件路径"; return 1; }
    [[ ! -f "$env_file" ]] && { echo "错误：env 文件不存在 -> $env_file"; return 1; }

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" != *"="* ]]; then
            echo "警告：跳过无效行 -> $line"
            continue
        fi

        key="${line%%=*}"
        value="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        # 移除可选的外层双引号
        if [[ "$value" =~ ^\".*\"$ ]]; then
            value="${value:1:-1}"
        fi

        # 转义处理
        value="${value//\\\\/\\}"
        value="${value//\\\"/\"}"
        value="${value//\\\$/\$}"

        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$env_file"
}

update_env() {
    local env_file="$1" key="$2" value="$3"
    [[ -n "$env_file" && -n "$key" ]] || return 1
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "Invalid key: $key"; return 1; }

    mkdir -p "$(dirname "$env_file")"
    [[ -f "$env_file" ]] || touch "$env_file"

    # 转义引号和反斜杠，写入时自动添加双引号
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\$}"

    local tmp_file
    tmp_file=$(mktemp "$(dirname "$env_file")/.env.tmp.XXXXXX")

    awk -v k="$key" 'index($0, k"=") != 1' "$env_file" > "$tmp_file"
    printf '%s="%s"\n' "$key" "$value" >> "$tmp_file"
    mv "$tmp_file" "$env_file"
}

# ================================
# 读取本地端口（从 catmi.env）
# ================================
LOCAL_PORT=8080
if [[ -f "$CATMIENV_FILE" ]]; then
    load_env "$CATMIENV_FILE"
    if [[ -n "${lsargo_port}" ]]; then
        LOCAL_PORT="${lsargo_port}"
    fi
fi
echo "使用本地端口：$LOCAL_PORT"

# ================================
# 架构检测与 cloudflared 安装
# ================================
install_cloudflared() {
    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)     CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        aarch64)    CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
        armv7l|armhf) CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
        *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
    esac

    echo "⬇️ 下载 cloudflared ($ARCH)..."
    wget -qO "$BIN" "$CFD_URL" || { echo "❌ 下载失败"; exit 1; }
    chmod +x "$BIN"
}

if [[ ! -x "$BIN" ]]; then
    install_cloudflared
elif ! "$BIN" --version >/dev/null 2>&1; then
    echo "cloudflared 损坏，重新下载..."
    install_cloudflared
fi

# ================================
# systemd 服务（基础保活，动态端口）
# ================================
cat > /etc/systemd/system/argo-temp.service <<EOF
[Unit]
Description=Argo Temporary Tunnel
After=network.target

[Service]
WorkingDirectory=$BASE_DIR
ExecStart=$BIN tunnel --url http://localhost:$LOCAL_PORT --no-autoupdate --config /dev/null
Restart=always
RestartSec=3
StandardOutput=append:$TEMP_LOG
StandardError=append:$TEMP_LOG
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable argo-temp

# ================================
# 增强的 watchdog（支持新域名提取等待、失败计数保护）
# ================================
cat > "$WATCHDOG_SCRIPT" <<'WATCHDOG_EOF'
#!/bin/bash

BASE_DIR="/root/catmi/argo_temp"
TEMP_LOG="$BASE_DIR/temp.log"
SD_FILE="$BASE_DIR/SD_domain.txt"
FAIL_COUNT_FILE="$BASE_DIR/.fail_count"
UPDATE_NODES="$BASE_DIR/update_nodes.sh"
MAX_FAIL=3
CHECK_TIMEOUT=5          # curl 超时秒数

DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

# 写入日志（带时间戳）
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$BASE_DIR/watchdog.log"
}

# 更新 .env 文件的函数（兼容无外层引号的值）
update_env() {
    local env_file="$1" key="$2" value="$3"
    [[ -n "$env_file" && -n "$key" ]] || return 1
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    mkdir -p "$(dirname "$env_file")"
    [[ -f "$env_file" ]] || touch "$env_file"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\$}"

    local tmp_file
    tmp_file=$(mktemp "$(dirname "$env_file")/.env.tmp.XXXXXX")
    awk -v k="$key" 'index($0, k"=") != 1' "$env_file" > "$tmp_file"
    printf '%s="%s"\n' "$key" "$value" >> "$tmp_file"
    mv "$tmp_file" "$env_file"
}

# 从日志中提取最新域名（仅匹配 trycloudflare.com）
extract_latest_domain() {
    grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TEMP_LOG" | tail -n 1
}

# 等待新域名出现在日志中（最长等待 12 秒）
wait_for_new_domain() {
    local waited=0
    local step=0.5
    local max_wait=12
    while (( $(echo "$waited < $max_wait" | bc -l) )); do
        local new_url=$(extract_latest_domain)
        if [[ -n "$new_url" ]]; then
            echo "$new_url"
            return 0
        fi
        sleep "$step"
        waited=$(echo "$waited + $step" | bc)
    done
    return 1
}

# 读取当前域名
DOMAIN=$(cat "$SD_FILE" 2>/dev/null || echo "")
if [[ -z "$DOMAIN" ]]; then
    log "SD_domain.txt 为空，退出 watchdog"
    exit 0
fi

# 健康检查
HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time $CHECK_TIMEOUT "https://$DOMAIN" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" =~ ^(200|301|302|404|502)$ ]]; then
    # 访问成功，重置失败计数
    echo 0 > "$FAIL_COUNT_FILE"
    log "健康检查通过 ($HTTP_CODE)，域名 $DOMAIN 有效"
    exit 0
fi

# 失败计数累加
FAIL_COUNT=0
if [[ -f "$FAIL_COUNT_FILE" ]]; then
    FAIL_COUNT=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
fi
FAIL_COUNT=$((FAIL_COUNT + 1))
echo "$FAIL_COUNT" > "$FAIL_COUNT_FILE"
log "健康检查失败 ($HTTP_CODE)，连续失败次数: $FAIL_COUNT/$MAX_FAIL"

if (( FAIL_COUNT < MAX_FAIL )); then
    exit 0
fi

# 连续失败达到阈值，重启 systemd 服务
log "连续失败 $MAX_FAIL 次，开始重启 argo-temp 服务..."
systemctl restart argo-temp

# 等待新域名出现
NEW_URL=$(wait_for_new_domain)
if [[ -z "$NEW_URL" ]]; then
    log "重启后 12 秒内未从 $TEMP_LOG 中提取到新域名，放弃本次更新"
    exit 1
fi

NEW_DOMAIN=$(echo "$NEW_URL" | sed 's#https://##')
echo "$NEW_DOMAIN" > "$SD_FILE"
update_env "$CATMIENV_FILE" SD_domain "$NEW_DOMAIN"
log "新域名已捕获并写入: $NEW_DOMAIN"

# 调用外部更新脚本（若存在）
if [[ -x "$UPDATE_NODES" ]]; then
    log "执行 $UPDATE_NODES"
    bash "$UPDATE_NODES" >> "$BASE_DIR/watchdog.log" 2>&1
fi

# 重置失败计数
echo 0 > "$FAIL_COUNT_FILE"
log "隧道恢复，域名更新完成"
exit 0
WATCHDOG_EOF

chmod +x "$WATCHDOG_SCRIPT"

# ================================
# 首次启动并捕获域名（增强等待逻辑）
# ================================
echo "启动临时隧道..."
rm -f "$TEMP_LOG" "$FAIL_COUNT_FILE"
systemctl restart argo-temp

# 提取域名函数（与 watchdog 保持一致）
extract_latest_domain() {
    grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TEMP_LOG" | tail -n 1
}

URL=""
for i in {1..30}; do
    URL=$(extract_latest_domain)
    [[ -n "$URL" ]] && break
    sleep 0.5
done

if [[ -z "$URL" ]]; then
    echo "❌ 未捕获到临时隧道 URL，请检查："
    tail -n 30 "$TEMP_LOG"
    exit 1
fi

DOMAIN=$(echo "$URL" | sed 's#https://##')
echo "$DOMAIN" > "$SD_FILE"
update_env "$CATMIENV_FILE" SD_domain "$DOMAIN"
echo "临时域名：$DOMAIN"

# ================================
# 添加 cron 每分钟执行 watchdog（先删除旧条目再添加）
# ================================
(crontab -l 2>/dev/null | grep -v "watchdog.sh" ; echo "* * * * * bash $WATCHDOG_SCRIPT >/dev/null 2>&1") | crontab -

echo "----------------------------------------"
echo "临时隧道部署完成（端口：$LOCAL_PORT）！"
echo "域名已写入 catmi.env"
echo "保活 watchdog 已启用（连续 3 次失败后自动重启）"
echo "日志位置：$BASE_DIR/watchdog.log"
echo "----------------------------------------"
