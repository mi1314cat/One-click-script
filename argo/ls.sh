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

# catmi 环境文件路径
DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

mkdir -p "$BASE_DIR"

# ================================
# 工具函数：安全加载 / 更新 .env
# ================================
load_env() {
    local env_file="$1"
    [[ -z "$env_file" ]] && { echo "错误：必须传入 env 文件路径"; return 1; }
    [[ ! -f "$env_file" ]] && { echo "错误：env 文件不存在 -> $env_file"; return 1; }

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" != *=* ]]; then
            echo "警告：跳过无效行 -> $line"
            continue
        fi

        key="${line%%=*}"
        value="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "错误：非法变量名 -> $key"
            return 1
        fi

        if [[ ! "$value" =~ ^\".*\"$ ]]; then
            echo "错误：变量 $key 的值必须包含在双引号内 -> $value"
            return 1
        fi

        value="${value:1:-1}"
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
LOCAL_PORT=8080                     # 默认值
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
# 智能 watchdog（持久化失败计数）
# ================================
cat > "$WATCHDOG_SCRIPT" <<'WATCHDOG_EOF'
#!/bin/bash
BASE_DIR="/root/catmi/argo_temp"
TEMP_LOG="$BASE_DIR/temp.log"
SD_FILE="$BASE_DIR/SD_domain.txt"
FAIL_COUNT_FILE="$BASE_DIR/.fail_count"
UPDATE_NODES="$BASE_DIR/update_nodes.sh"
MAX_FAIL=3

DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

update_env() {
    local env_file="$1" key="$2" value="$3"
    [[ -n "$env_file" && -n "$key" ]] || return 1
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    mkdir -p "$(dirname "$env_file")"
    [[ -f "$env_file" ]] || touch "$env_file"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\$}"
    local tmp_file=$(mktemp "$(dirname "$env_file")/.env.tmp.XXXXXX")
    awk -v k="$key" 'index($0, k"=") != 1' "$env_file" > "$tmp_file"
    printf '%s="%s"\n' "$key" "$value" >> "$tmp_file"
    mv "$tmp_file" "$env_file"
}

DOMAIN=$(cat "$SD_FILE" 2>/dev/null || echo "")

if [[ -z "$DOMAIN" ]]; then
    exit 0
fi

if curl -s --max-time 5 "https://$DOMAIN" >/dev/null 2>&1; then
    echo 0 > "$FAIL_COUNT_FILE"
    exit 0
fi

FAIL_COUNT=0
if [[ -f "$FAIL_COUNT_FILE" ]]; then
    FAIL_COUNT=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
fi
FAIL_COUNT=$(( FAIL_COUNT + 1 ))
echo "$FAIL_COUNT" > "$FAIL_COUNT_FILE"

if (( FAIL_COUNT < MAX_FAIL )); then
    echo "域名检查失败 ($FAIL_COUNT/$MAX_FAIL)，暂不重启"
    exit 0
fi

echo "域名连续失效 $MAX_FAIL 次，重启隧道..."
systemctl restart argo-temp
sleep 2

NEW_URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TEMP_LOG" | tail -n 1)

if [[ -n "$NEW_URL" ]]; then
    NEW_DOMAIN=$(echo "$NEW_URL" | sed 's#https://##')
    echo "$NEW_DOMAIN" > "$SD_FILE"

    update_env "$CATMIENV_FILE" SD_domain "$NEW_DOMAIN"

    echo "[$(date)] 新域名: $NEW_DOMAIN"

    if [[ -f "$UPDATE_NODES" ]]; then
        bash "$UPDATE_NODES"
    fi

    echo 0 > "$FAIL_COUNT_FILE"
else
    echo "[$(date)] 重启后未能获取新域名！"
fi
WATCHDOG_EOF

chmod +x "$WATCHDOG_SCRIPT"

# ================================
# 首次启动并捕获域名
# ================================
echo "启动临时隧道..."
rm -f "$TEMP_LOG" "$FAIL_COUNT_FILE"
systemctl restart argo-temp
sleep 2

URL=""
for i in {1..20}; do
    URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TEMP_LOG" | head -n 1)
    [[ -n "$URL" ]] && break
    sleep 0.3
done

if [[ -z "$URL" ]]; then
    echo "❌ 未捕获到临时隧道 URL"
    tail -n 20 "$TEMP_LOG"
    exit 1
fi

DOMAIN=$(echo "$URL" | sed 's#https://##')
echo "$DOMAIN" > "$SD_FILE"
update_env "$CATMIENV_FILE" SD_domain "$DOMAIN"
echo "临时域名：$DOMAIN"

# ================================
# 添加 cron 每分钟执行 watchdog
# ================================
(crontab -l 2>/dev/null | grep -v "watchdog.sh" ; echo "* * * * * bash $WATCHDOG_SCRIPT >/dev/null 2>&1") | crontab -

echo "----------------------------------------"
echo "临时隧道部署完成（端口：$LOCAL_PORT）！"
echo "域名已写入 catmi.env"
echo "保活 watchdog 已启用（连续 3 次失败后自动重启）"
echo "----------------------------------------"
