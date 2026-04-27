#!/usr/bin/env bash
set -e

WORKDIR="/root/argo_token"
BIN="$WORKDIR/cloudflared"
LOG_FILE="$WORKDIR/token.log"

mkdir -p "$WORKDIR"

RED="\033[31m"
YELLOW="\033[33m"
GREEN="\033[32m"
NC="\033[0m"

# cloudflared 检查
if [[ ! -f "$BIN" ]]; then
    wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 || {
        echo -e "${RED}cloudflared 下载失败${NC}"
        exit 1
    }
    chmod +x "$BIN"
fi

if ! "$BIN" --version >/dev/null 2>&1; then
    rm -f "$BIN"
    wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 || {
        echo -e "${RED}cloudflared 下载失败${NC}"
        exit 1
    }
    chmod +x "$BIN"
fi

# ============================
# 完整 Token 获取提示（你要求的）
# ============================
echo -e "${YELLOW}如何获取 Cloudflare Argo Token：${NC}"
echo -e "1. 登录 Cloudflare Dashboard（https://dash.cloudflare.com）"
echo -e "2. 进入 Zero Trust 面板：${GREEN}https://one.dash.cloudflare.com${NC}"
echo -e "3. 左侧菜单选择：${GREEN}Access → Tunnels${NC}"
echo -e "4. 找到你创建的隧道（Tunnel Name）"
echo -e "5. 点击右侧的 ${GREEN}... More → Copy token${NC}"
echo -e "6. Token 格式示例："
echo -e "   ${GREEN}eyJhIjoiY2YtYWNjb3VudC0xMjMiLCJ0IjoiYWJjZGVmZ2hpamtsbW5vcHFyIn0...${NC}"
echo

read -p "请输入 Token: " TOKEN
[[ -z "$TOKEN" ]] && { echo -e "${RED}Token 不能为空${NC}"; exit 1; }

# 写入 systemd
cat > /etc/systemd/system/argo-token.service <<EOF
[Unit]
Description=Argo Tunnel Token Mode
After=network.target

[Service]
WorkingDirectory=$WORKDIR
ExecStart=$BIN tunnel run --token $TOKEN
Restart=always
RestartSec=5
KillMode=process
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable argo-token >/dev/null 2>&1
systemctl restart argo-token >/dev/null 2>&1 || {
    echo -e "${RED}隧道启动失败${NC}"
    exit 1
}

# 成功静默
exit 0
