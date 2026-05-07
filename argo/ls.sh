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
# 带重试的隧道启动函数（用于首次运行和 watchdog 重启）
# 参数: $1 端口 (可选，默认 LOCAL_PORT)
# 输出: 成功时返回 0 并将域名写入 SD_FILE & catmi.env
# ================================
start_tunnel_with_retry() {
    local port="${1:-$LOCAL_PORT}"
    local max_retries=5
    local retry_delay=15
    local attempt=1
    local temp_log_start="$BASE_DIR/start_temp.log"

    while (( attempt <= max_retries )); do
        echo "[尝试 $attempt/$max_retries] 启动 cloudflared 隧道 (端口 $port) ..."

        # 临时启动并捕获日志
        rm -f "$temp_log_start"
        nohup $BIN tunnel --url "http://localhost:$port" --no-autoupdate --config /dev/null \
            > "$temp_log_start" 2>&1 &
        local pid=$!
        sleep 3

        # 检查进程是否存活
        if ! kill -0 "$pid" 2>/dev/null; then
            # 进程已退出，查看是否 429
            if grep -q "429 Too Many Requests" "$temp_log_start" 2>/dev/null; then
                echo "⚠️  触发 Cloudflare 限流 (429)，等待 ${retry_delay} 秒后重试..."
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2))
                attempt=$((attempt + 1))
                continue
            else
                echo "❌ cloudflared 启动失败（非限流错误），日志："
                tail -n 20 "$temp_log_start"
                return 1
            fi
        fi

        # 提取域名
        local url=""
        for i in {1..30}; do
            url=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$temp_log_start" | head -n 1)
            [[ -n "$url" ]] && break
            sleep 0.5
        done

        if [[ -n "$url" ]]; then
            # 成功：将日志合并到正式日志，停止临时进程（因为 systemd 会接管）
            kill "$pid" 2>/dev/null || true
            cat "$temp_log_start" >> "$TEMP_LOG"
            rm -f "$temp_log_start"

            local domain=$(echo "$url" | sed 's#https://##')
            echo "$domain" > "$SD_FILE"
            update_env "$CATMIENV_FILE" SD_domain "$domain"
            echo "✅ 临时隧道创建成功，域名：$url"
            return 0
        else
            # 未捕获域名但进程还在，可能被限流或延迟
            kill "$pid" 2>/dev/null || true
            if grep -q "429 Too Many Requests" "$temp_log_start" 2>/dev/null; then
                echo "⚠️  返回域名前遇到限流 (429)，等待 ${retry_delay} 秒后重试..."
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2))
                attempt=$((attempt + 1))
                continue
            else
                echo "❌ 启动后未能提取到域名，日志："
                tail -n 20 "$temp_log_start"
                return 1
            fi
        fi
    done

    echo "❌ 经过 $max_retries 次重试仍失败，请稍后再试或改用固定隧道。"
    return 1
}

# ================================
# systemd 服务（基础保活，动态端口）
# 注意：ExecStart 不会直接处理 429，因为 systemd 重启很快。但我们的 watchdog 会处理健康检查失败导致的完整重启
# ================================
cat > /etc/systemd/system/argo-temp.service <<EOF
[Unit]
Description=Argo Temporary Tunnel
After=network.target

[Service]
WorkingDirectory=$BASE_DIR
ExecStart=$BIN tunnel --url http://localhost:$LOCAL_PORT --no-autoupdate --config /dev/null
Restart=always
RestartSec=5
StandardOutput=append:$TEMP_LOG
StandardError=append:$TEMP_LOG
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable argo-temp

# ================================
# 增强的 watchdog（无 bc 依赖，精确进程清理）
# ================================
cat > "$WATCHDOG_SCRIPT" <<'WATCHDOG_EOF'
#!/bin/bash

BASE_DIR="/root/catmi/argo_temp"
TEMP_LOG="$BASE_DIR/temp.log"
SD_FILE="$BASE_DIR/SD_domain.txt"
FAIL_COUNT_FILE="$BASE_DIR/.fail_count"
UPDATE_NODES="$BASE_DIR/update_nodes.sh"
MAX_FAIL=3
CHECK_TIMEOUT=5

DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"
BIN="$BASE_DIR/cloudflared"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$BASE_DIR/watchdog.log"
}

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

extract_latest_domain() {
    grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TEMP_LOG" | tail -n 1
}

wait_for_new_domain() {
    local max_wait=12  # 秒
    local waited=0
    while (( waited < max_wait )); do
        local new_url=$(extract_latest_domain)
        if [[ -n "$new_url" ]]; then
            echo "$new_url"
            return 0
        fi
        sleep 0.5
        waited=$((waited + 1))
    done
    return 1
}

restart_service_safely() {
    log "准备重启 argo-temp 服务并清理旧进程..."
    # 停止 systemd 服务（防止冲突）
    systemctl stop argo-temp 2>/dev/null || true
    # 精确杀掉与当前端口相关的残留进程（从 catmi.env 读取端口）
    local port=8080
    if [[ -f "$CATMIENV_FILE" ]]; then
        # 简单读取端口（因为 load_env 可能不可用，直接 grep）
        local port_line=$(grep -E '^lsargo_port=' "$CATMIENV_FILE" 2>/dev/null | tail -n1)
        if [[ -n "$port_line" ]]; then
            port=$(echo "$port_line" | sed -E 's/^lsargo_port="?([0-9]+)"?/\1/')
        fi
    fi
    pkill -f "cloudflared tunnel --url http://localhost:$port" 2>/dev/null || true
    sleep 1
    systemctl start argo-temp
    log "argo-temp 服务已重新启动"
}

# 读取当前域名
DOMAIN=$(cat "$SD_FILE" 2>/dev/null || echo "")
if [[ -z "$DOMAIN" ]]; then
    log "SD_domain.txt 为空，尝试重新创建隧道..."
    # 尝试启动隧道（带重试）
    bash -c "$BASE_DIR/start_once.sh" >> "$BASE_DIR/watchdog.log" 2>&1
    exit $?
fi

# 健康检查
HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time $CHECK_TIMEOUT "https://$DOMAIN" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" =~ ^(200|301|302|404|502)$ ]]; then
    echo 0 > "$FAIL_COUNT_FILE"
    log "健康检查通过 ($HTTP_CODE)，域名 $DOMAIN 有效"
    exit 0
fi

# 失败计数
FAIL_COUNT=0
if [[ -f "$FAIL_COUNT_FILE" ]]; then
    FAIL_COUNT=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
fi
FAIL_COUNT=$((FAIL_COUNT + 1))
echo "$FAIL_COUNT" > "$FAIL_COUNT_FILE"
log "健康检查失败 ($HTTP_CODE)，连续次数: $FAIL_COUNT/$MAX_FAIL"

if (( FAIL_COUNT < MAX_FAIL )); then
    exit 0
fi

# 连续失败达阈值，完全重启隧道
log "连续失败 $MAX_FAIL 次，开始完整重启隧道（获取新域名）..."

# 停止服务并清理残留
systemctl stop argo-temp 2>/dev/null || true
pkill -f "cloudflared tunnel" 2>/dev/null || true
sleep 1
rm -f "$TEMP_LOG"

# 使用带重试的启动逻辑创建新隧道（调用独立脚本，写入 SD_FILE）
if ! bash -c "$BASE_DIR/start_once.sh" >> "$BASE_DIR/start_once.log" 2>&1; then
    log "启动隧道失败，放弃本次重启"
    exit 1
fi

# 读取新域名
NEW_DOMAIN=$(cat "$SD_FILE" 2>/dev/null || echo "")
if [[ -z "$NEW_DOMAIN" ]]; then
    log "重启后未能获取新域名！"
    exit 1
fi

# 更新 env 文件（已由 start_once.sh 完成，但确保）
update_env "$CATMIENV_FILE" SD_domain "$NEW_DOMAIN"
log "新域名生效: $NEW_DOMAIN"

# 调用外部更新脚本
if [[ -x "$UPDATE_NODES" ]]; then
    log "执行 $UPDATE_NODES"
    bash "$UPDATE_NODES" >> "$BASE_DIR/watchdog.log" 2>&1
fi

echo 0 > "$FAIL_COUNT_FILE"
log "隧道已恢复，域名更新完成"
exit 0
WATCHDOG_EOF

# ================================
# 生成独立启动脚本（包含429重试），供 watchodg 调用
# ================================
cat > "$BASE_DIR/start_once.sh" <<'START_ONCE_EOF'
#!/bin/bash
BASE_DIR="/root/catmi/argo_temp"
BIN="$BASE_DIR/cloudflared"
TEMP_LOG="$BASE_DIR/temp.log"
SD_FILE="$BASE_DIR/SD_domain.txt"
CATMIENV_FILE="/root/catmi/catmi.env"

source /etc/profile 2>/dev/null || true

# 读取端口
LOCAL_PORT=8080
if [[ -f "$CATMIENV_FILE" ]]; then
    port_line=$(grep -E '^lsargo_port=' "$CATMIENV_FILE" 2>/dev/null | tail -n1)
    if [[ -n "$port_line" ]]; then
        LOCAL_PORT=$(echo "$port_line" | sed -E 's/^lsargo_port="?([0-9]+)"?/\1/')
    fi
fi

max_retries=5
retry_delay=15
attempt=1
temp_log_start="$BASE_DIR/start_once_temp.log"

while (( attempt <= max_retries )); do
    rm -f "$temp_log_start"
    nohup $BIN tunnel --url "http://localhost:$LOCAL_PORT" --no-autoupdate --config /dev/null \
        > "$temp_log_start" 2>&1 &
    pid=$!
    sleep 3

    if ! kill -0 "$pid" 2>/dev/null; then
        if grep -q "429 Too Many Requests" "$temp_log_start"; then
            echo "[attempt $attempt] 429限流，等待 ${retry_delay}s" >> "$BASE_DIR/start_once.log"
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))
            attempt=$((attempt + 1))
            continue
        else
            echo "启动失败（非429）" >> "$BASE_DIR/start_once.log"
            cat "$temp_log_start" >> "$BASE_DIR/start_once.log"
            exit 1
        fi
    fi

    # 提取域名
    url=""
    for i in {1..30}; do
        url=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$temp_log_start" | head -n1)
        [[ -n "$url" ]] && break
        sleep 0.5
    done

    if [[ -n "$url" ]]; then
        kill "$pid" 2>/dev/null || true
        cat "$temp_log_start" >> "$TEMP_LOG"
        domain=$(echo "$url" | sed 's#https://##')
        echo "$domain" > "$SD_FILE"
        # 更新 catmi.env
        # 简单更新函数（内嵌）
        env_file="$CATMIENV_FILE"
        key="SD_domain"
        value="$domain"
        value="${value//\\/\\\\}"
        value="${value//\"/\\\"}"
        value="${value//\$/\\$}"
        tmp_file=$(mktemp "$(dirname "$env_file")/.env.tmp.XXXXXX")
        awk -v k="$key" 'index($0, k"=") != 1' "$env_file" > "$tmp_file"
        printf '%s="%s"\n' "$key" "$value" >> "$tmp_file"
        mv "$tmp_file" "$env_file"

        echo "SUCCESS: $domain" >> "$BASE_DIR/start_once.log"
        exit 0
    else
        kill "$pid" 2>/dev/null || true
        if grep -q "429 Too Many Requests" "$temp_log_start"; then
            echo "[attempt $attempt] 429限流（域名未返回），等待 ${retry_delay}s" >> "$BASE_DIR/start_once.log"
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))
            attempt=$((attempt + 1))
            continue
        else
            echo "启动后未提取到域名" >> "$BASE_DIR/start_once.log"
            cat "$temp_log_start" >> "$BASE_DIR/start_once.log"
            exit 1
        fi
    fi
done

echo "重试次数耗尽，启动失败" >> "$BASE_DIR/start_once.log"
exit 1
START_ONCE_EOF

chmod +x "$BASE_DIR/start_once.sh"

# ================================
# 首次启动（使用重试函数）
# ================================
echo "首次启动临时隧道（可能因限流自动重试）..."
if ! start_tunnel_with_retry "$LOCAL_PORT"; then
    echo "❌ 隧道启动失败，请检查网络或稍后重试。"
    exit 1
fi

# 确保 systemd 服务使用正确的日志文件（日志已由 start_tunnel_with_retry 追加）
# 启动 systemd 服务（覆盖临时进程）
systemctl restart argo-temp
sleep 2
# 确保 SD_domain 和 catmi.env 已写入
DOMAIN=$(cat "$SD_FILE")
echo "✅ 临时隧道服务已启动，域名：https://$DOMAIN"

# ================================
# 添加 cron 每分钟执行 watchdog（保留原有 crontab）
# ================================
(crontab -l 2>/dev/null | grep -v "watchdog.sh" ; echo "* * * * * bash $WATCHDOG_SCRIPT >/dev/null 2>&1") | crontab -

echo "----------------------------------------"
echo "临时隧道部署完成（端口：$LOCAL_PORT）！"
echo "域名已写入 catmi.env"
echo "保活 watchdog 已启用（连续 3 次失败后自动重启，含429重试）"
echo "日志位置：$BASE_DIR/watchdog.log"
echo "----------------------------------------"
