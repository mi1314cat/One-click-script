#!/usr/bin/env bash
set -e

# ============================
# 基础路径
# ============================
CLOUDFLARED="/root/argo/cloudflared"
CF_DIR="/root/.cloudflared"

mkdir -p /root/argo
mkdir -p "$CF_DIR"

# ============================
# 清理旧 config.yml（关键）
# ============================
if [[ -f "$CF_DIR/config.yml" ]]; then
    rm -f "$CF_DIR/config.yml"
fi

# ============================
# 下载 cloudflared（如不存在）
# ============================
if [[ ! -f "$CLOUDFLARED" ]]; then
    echo "正在下载 cloudflared..."
    wget -qO "$CLOUDFLARED" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x "$CLOUDFLARED"
fi

# ============================
# Cloudflare 登录
# ============================
echo "=============================="
echo " 点击授权 Cloudflare 账号"
echo "=============================="
read -p "按回车继续（或 Ctrl+C 退出）"

if [[ -f "$CF_DIR/cert.pem" ]]; then
    echo "检测到已有 cert.pem，跳过 cloudflared login"
else
    $CLOUDFLARED login
fi

# ============================
# 生成 Tunnel 名称
# ============================
TUNNEL_NAME=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
echo "Tunnel 名称：$TUNNEL_NAME"

# ============================
# 创建 Tunnel
# ============================
OUTPUT=$($CLOUDFLARED tunnel create "$TUNNEL_NAME" 2>&1)
echo "$OUTPUT"

TUNNEL_ID=$(echo "$OUTPUT" | grep -oE "[a-f0-9-]{36}" | head -n 1)

if [[ -z "$TUNNEL_ID" ]]; then
    echo "❌ 创建 Tunnel 失败，请检查上方输出"
    exit 1
fi

echo "Tunnel ID：$TUNNEL_ID"

# ============================
# 输入授权域名
# ============================
read -p "请输入授权根域名（例如 catmicos.dpdns.org）: " AUTHORIZED_DOMAIN
if [[ -z "$AUTHORIZED_DOMAIN" ]]; then
    echo "授权域名不能为空"
    exit 1
fi

# ============================
# 输入端口（默认 8080）
# ============================
read -p "请输入本地反代端口（默认 8080）: " PORT
PORT=${PORT:-8080}

# ============================
# 自动生成完整域名
# ============================
DOMAIN="${TUNNEL_NAME}.${AUTHORIZED_DOMAIN}"
echo "绑定域名：$DOMAIN"

# ============================
# 写入 config.yml（绝对干净）
# ============================
cat > "$CF_DIR/config.yml" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CF_DIR/$TUNNEL_ID.json

ingress:
  - hostname: $DOMAIN
    service: http://localhost:$PORT
  - service: http_status:404
EOF

echo "config.yml 已生成：$CF_DIR/config.yml"

# ============================
# systemd 服务
# ============================
SERVICE="/etc/systemd/system/argo-file.service"

cat > "$SERVICE" <<EOF
[Unit]
Description=Argo Tunnel (File Mode)
After=network.target

[Service]
ExecStart=$CLOUDFLARED tunnel --config $CF_DIR/config.yml run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable argo-file
systemctl restart argo-file

# ============================
# 完成
# ============================
echo
echo "=============================="
echo " 文件方式固定隧道已启动（最终版）"
echo "=============================="
echo "Tunnel 名称：$TUNNEL_NAME"
echo "Tunnel ID：$TUNNEL_ID"
echo "绑定域名：$DOMAIN"
echo "反代端口：$PORT"
echo
echo "⚠ 请到 Cloudflare DNS 手动添加 CNAME："
echo "   ${DOMAIN}  →  ${TUNNEL_ID}.cfargotunnel.com"
echo
echo "systemctl status argo-file 查看状态"
