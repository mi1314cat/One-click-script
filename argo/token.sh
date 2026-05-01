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

# ============================================================
# 自动识别架构并下载 cloudflared（支持 x86 / ARM）
# ============================================================
install_cloudflared() {
    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64)
            CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        aarch64)
            CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        armv7l|armhf)
            CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
            ;;
        *)
            echo -e "${RED}不支持的架构: $ARCH${NC}"
            exit 1
            ;;
    esac

    echo -e "${YELLOW}正在下载 cloudflared ($ARCH)...${NC}"
    wget -qO "$BIN" "$CFD_URL" || {
        echo -e "${RED}cloudflared 下载失败${NC}"
        exit 1
    }
    chmod +x "$BIN"
}

# ============================================================
# cloudflared 检查（损坏自动重下）
# ============================================================
if [[ ! -f "$BIN" ]]; then
    install_cloudflared
elif ! "$BIN" --version >/dev/null 2>&1; then
    echo -e "${YELLOW}检测到 cloudflared 文件损坏，重新下载...${NC}"
    rm -f "$BIN"
    install_cloudflared
fi

# ============================================================
# Token 获取提示
# ============================================================
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

# ============================================================
# 写入 systemd 服务
# ============================================================
cat > /etc/systemd/system/argo-token.service <<EOF
[Unit]
Description=Argo Tunnel Token Mode
After=network.target

[Service]
WorkingDirectory=$WORKDIR
ExecStart=$BIN tunnel run --token $TOKEN
Restart=always
RestartSec=3
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
