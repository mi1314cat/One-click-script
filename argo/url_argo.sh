#!/usr/bin/env bash
set -e

WORKDIR="/root/argo_file"
BIN="$WORKDIR/cloudflared"
CF_DIR="/root/.cloudflared"
FILE_INFO="$WORKDIR/file_tunnel.txt"
LOG_FILE="$WORKDIR/file.log"

mkdir -p "$WORKDIR" "$CF_DIR"

err(){ echo "[ERR] $1" >&2; }

check_cloudflared(){
    if [[ ! -f "$BIN" ]]; then
        wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
            || { err "cloudflared 下载失败"; exit 1; }
        chmod +x "$BIN"
    fi

    if ! "$BIN" --version >/dev/null 2>&1; then
        rm -f "$BIN"
        wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
            || { err "cloudflared 下载失败"; exit 1; }
        chmod +x "$BIN"
    fi
}

create_file_tunnel(){
    check_cloudflared

    if [[ ! -f "$CF_DIR/cert.pem" ]]; then
        $BIN login || { err "cloudflared login 失败"; exit 1; }
    fi

    TUNNEL_NAME=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
    OUTPUT=$($BIN tunnel create "$TUNNEL_NAME" 2>&1) || { err "隧道创建失败"; exit 1; }

    TID=$(echo "$OUTPUT" | grep -oE "[a-f0-9-]{36}" | head -n 1)
    [[ -z "$TID" ]] && { err "无法解析 Tunnel ID"; exit 1; }

    read -p "根域名: " ROOT_DOMAIN
    read -p "本地端口(默认8080): " PORT
    PORT=${PORT:-8080}

    DOMAIN="$TUNNEL_NAME.$ROOT_DOMAIN"

cat > "$CF_DIR/config.yml" <<EOF
tunnel: $TID
credentials-file: $CF_DIR/$TID.json

ingress:
  - hostname: $DOMAIN
    service: http://localhost:$PORT
  - service: http_status:404
EOF

# ⭐ 关键：变量写法，但 Bash 会展开
cat > /etc/systemd/system/argo-file.service <<EOF
[Unit]
Description=Argo Tunnel File Mode
After=network.target

[Service]
WorkingDirectory=$WORKDIR
ExecStart=$BIN tunnel --config $CF_DIR/config.yml run
Restart=always
RestartSec=5
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

echo "$TID $DOMAIN $PORT" > "$FILE_INFO"

systemctl daemon-reload
systemctl enable argo-file >/dev/null 2>&1
systemctl restart argo-file

echo
echo "请到 Cloudflare DNS 添加："
echo "$DOMAIN  CNAME  $TID.cfargotunnel.com"
echo
}

create_file_tunnel
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")
DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"
uargo_domain=$(awk '{print $2}' "$FILE_INFO")
update_env $CATMIENV_FILE uargo_domain $uargo_domain
