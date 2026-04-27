#!/usr/bin/env bash
set -e

# ============================
# 基础目录
# ============================
WORKDIR="/root/argo_temp"
BIN="$WORKDIR/cloudflared"
TEMP_LOG="$WORKDIR/temp.log"
TEMP_SAVE="$WORKDIR/temp_url.txt"
SD_FILE="$WORKDIR/SD_domain.txt"
UPDATE_NODES="/root/argo_temp/update_nodes.sh"

mkdir -p "$WORKDIR"

echo "=== 安装 cloudflared ==="

if [[ ! -f "$BIN" ]]; then
    wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x "$BIN"
fi

# ============================
# 创建 systemd 服务（保活）
# ============================
echo "=== 创建 systemd 服务 ==="

cat > /etc/systemd/system/argo-temp.service <<EOF
[Unit]
Description=Argo Temporary Tunnel
After=network.target

[Service]
WorkingDirectory=$WORKDIR
ExecStart=$BIN tunnel --url http://localhost:8080 --no-autoupdate --config /dev/null
Restart=always
RestartSec=3
StandardOutput=append:$TEMP_LOG
StandardError=append:$TEMP_LOG

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable argo-temp

# ============================
# 启动临时隧道
# ============================
echo "=== 启动临时隧道 ==="

systemctl restart argo-temp
sleep 2

# ============================
# 捕获临时域名
# ============================
echo "=== 捕获临时域名 ==="

for i in {1..10}; do
    URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TEMP_LOG" | head -n 1)
    [[ -n "$URL" ]] && break
    sleep 0.5
done

if [[ -z "$URL" ]]; then
    echo "❌ 未捕获到临时隧道 URL"
    tail -n 20 "$TEMP_LOG"
    exit 1
fi

echo "$URL" > "$TEMP_SAVE"

SD_domain=$(echo "$URL" | sed 's#https://##')
echo "$SD_domain" > "$SD_FILE"

echo "临时域名：$SD_domain"

# ============================
# 写入 catmi.env
# ============================
echo "=== 写入 catmi.env ==="

source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
update_env /root/catmi/catmi.env SD_domain "$SD_domain"

# ============================
# 创建 watchdog（自动检测域名失效）
# ============================
echo "=== 创建 watchdog ==="

cat > "$WORKDIR/watchdog.sh" <<EOF
#!/bin/bash

WORKDIR="/root/argo_temp"
TEMP_LOG="\$WORKDIR/temp.log"
SD_FILE="\$WORKDIR/SD_domain.txt"
UPDATE_NODES="/root/argo_temp/update_nodes.sh"

DOMAIN=\$(cat "\$SD_FILE" 2>/dev/null)

# 无域名 → 重启
if [[ -z "\$DOMAIN" ]]; then
    systemctl restart argo-temp
    exit 0
fi

# 检查域名是否可访问
if ! curl -s --max-time 3 "https://\$DOMAIN" >/dev/null; then
    echo "域名失效，重启临时隧道..."
    systemctl restart argo-temp
    sleep 2
fi

# 捕获新域名
NEW_URL=\$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "\$TEMP_LOG" | head -n 1)

if [[ -n "\$NEW_URL" ]]; then
    NEW_DOMAIN=\$(echo "\$NEW_URL" | sed 's#https://##')

    if [[ "\$NEW_DOMAIN" != "\$DOMAIN" ]]; then
        echo "\$NEW_DOMAIN" > "\$SD_FILE"

        source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
        update_env /root/catmi/catmi.env SD_domain "\$NEW_DOMAIN"

        echo "检测到新域名：\$NEW_DOMAIN"

        # 自动更新节点配置
        [[ -f "\$UPDATE_NODES" ]] && bash "\$UPDATE_NODES"
    fi
fi
EOF

chmod +x "$WORKDIR/watchdog.sh"

# ============================
# 加入 cron 定时任务
# ============================
echo "=== 添加 cron 定时任务 ==="

(crontab -l 2>/dev/null | grep -v "watchdog.sh" ; echo "* * * * * bash /root/argo_temp/watchdog.sh >/dev/null 2>&1") | crontab -

echo "----------------------------------------"
echo "临时 Argo 完整框架已安装完成"
echo "systemd 保活 + 自动检测失效 + 自动更新域名"
echo "----------------------------------------"
