#!/usr/bin/env bash
set -e

# ============================
# 独立目录（完全隔离）
# ============================
WORKDIR="/root/argo_temp"
BIN="$WORKDIR/cloudflared"
TEMP_LOG="$WORKDIR/temp.log"
TEMP_SAVE="$WORKDIR/temp_url.txt"
SD_FILE="$WORKDIR/SD_domain.txt"

mkdir -p "$WORKDIR"

echo "准备 cloudflared..."

# ============================
# 下载 cloudflared（独立）
# ============================
if [[ ! -f "$BIN" ]]; then
    wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x "$BIN"
fi

echo "关闭旧进程..."
pkill -f "cloudflared tunnel --url" 2>/dev/null || true
rm -f "$TEMP_LOG"

echo "启动临时隧道..."

# ============================
# 启动 cloudflared（前台运行）
# ============================
$BIN tunnel --url http://localhost:8080 --no-autoupdate --config /dev/null \
    > "$TEMP_LOG" 2>&1 &

sleep 2

echo "捕获域名..."

# ============================
# 捕获域名
# ============================
for i in {1..20}; do
    URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TEMP_LOG" | head -n 1)
    [[ -n "$URL" ]] && break
    sleep 1
done

if [[ -z "$URL" ]]; then
    echo "❌ 未捕获到临时隧道 URL"
    tail -n 20 "$TEMP_LOG"
    exit 1
fi

echo "$URL" > "$TEMP_SAVE"

# ============================
# 提取 SD_domain（去掉 https://）
# ============================
SD_domain=$(echo "$URL" | sed 's#https://##')
echo "$SD_domain" > "$SD_FILE"

echo "----------------------------------------"
echo "临时隧道已创建"
echo "URL: $URL"
echo "SD_domain: $SD_domain"
echo "----------------------------------------"

source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")
DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

update_env $CATMIENV_FILE SD_domain $SD_domain
