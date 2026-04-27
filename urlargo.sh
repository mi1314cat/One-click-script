#!/usr/bin/env bash
set -e

# ============================
# 基础路径
# ============================
WORKDIR="/root/argo_file"
BIN="$WORKDIR/cloudflared"
CF_DIR="/root/.cloudflared"
FILE_INFO="$WORKDIR/file_tunnel.txt"

mkdir -p "$WORKDIR"
mkdir -p "$CF_DIR"

# ============================
# 颜色
# ============================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[36m"
NC="\033[0m"

line(){ echo -e "${BLUE}----------------------------------------${NC}"; }
title(){ echo -e "${GREEN}$1${NC}"; line; }

# ============================
# cloudflared 自动检测
# ============================
check_cloudflared(){
    if [[ ! -f "$BIN" ]]; then
        echo -e "${YELLOW}cloudflared 不存在，正在下载...${NC}"
        wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x "$BIN"
    fi

    if ! "$BIN" --version >/dev/null 2>&1; then
        echo -e "${RED}cloudflared 文件损坏，重新下载...${NC}"
        rm -f "$BIN"
        wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x "$BIN"
    fi
}

# ============================
# 创建文件模式固定隧道
# ============================
create_file_tunnel(){
    check_cloudflared
    title "创建文件模式固定隧道"

    # cert.pem 检查
    if [[ ! -f "$CF_DIR/cert.pem" ]]; then
        echo -e "${YELLOW}未检测到 cert.pem，执行 cloudflared login...${NC}"
        $BIN login
    fi

    TUNNEL_NAME=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
    echo "Tunnel 名称：$TUNNEL_NAME"

    OUTPUT=$($BIN tunnel create "$TUNNEL_NAME" 2>&1)
    echo "$OUTPUT"

    TID=$(echo "$OUTPUT" | grep -oE "[a-f0-9-]{36}" | head -n 1)

    read -p "请输入根域名（例如 catmicos.dpdns.org）: " ROOT_DOMAIN
    read -p "请输入本地端口（默认 8080）: " PORT
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

cat > /etc/systemd/system/argo-file.service <<EOF
[Unit]
Description=Argo Tunnel File Mode
After=network.target

[Service]
ExecStart=$BIN tunnel run --config $CF_DIR/config.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "$TID $DOMAIN $PORT" > "$FILE_INFO"

systemctl daemon-reload
systemctl enable argo-file
systemctl restart argo-file

echo -e "${GREEN}文件模式固定隧道已启动${NC}"
echo "域名：$DOMAIN"
echo "Tunnel ID：$TID"
echo "请到 Cloudflare DNS 添加："
echo "$DOMAIN  CNAME  $TID.cfargotunnel.com"
}

# ============================
# 自动诊断 + 自动修复（手动）
# ============================
heal_file_manual(){
    if [[ ! -f "$FILE_INFO" ]]; then
        echo -e "${RED}未创建文件模式隧道${NC}"
        return
    fi

    read TID DOMAIN PORT < "$FILE_INFO"

    echo -e "检测固定隧道：${GREEN}$DOMAIN${NC}"

    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "https://$DOMAIN" || echo "000")

    if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
        echo -e "${GREEN}固定隧道健康（HTTP $HTTP_CODE）${NC}"
        return
    fi

    echo -e "${RED}固定隧道异常（HTTP $HTTP_CODE），自动修复中...${NC}"

    systemctl restart argo-file
    sleep 3

    HTTP2=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "https://$DOMAIN" || echo "000")

    if [[ "$HTTP2" =~ ^(200|301|302)$ ]]; then
        echo -e "${GREEN}修复成功（HTTP $HTTP2）${NC}"
    else
        echo -e "${RED}修复失败（HTTP $HTTP2）${NC}"
    fi
}

# ============================
# systemd 自动修复
# ============================
generate_file_health_script(){
cat > "$WORKDIR/file_health.sh" <<'EOF'
#!/usr/bin/env bash
WORKDIR="/root/argo_file"
FILE_INFO="$WORKDIR/file_tunnel.txt"

if [[ ! -f "$FILE_INFO" ]]; then
    exit 0
fi

read TID DOMAIN PORT < "$FILE_INFO"

HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "https://$DOMAIN" || echo "000")

if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
    exit 0
fi

systemctl restart argo-file
EOF

chmod +x "$WORKDIR/file_health.sh"
}

install_file_health_timer(){
cat > /etc/systemd/system/argo-file-health.service <<EOF
[Unit]
Description=自动修复文件模式隧道

[Service]
Type=oneshot
ExecStart=/bin/bash $WORKDIR/file_health.sh
EOF

cat > /etc/systemd/system/argo-file-health.timer <<EOF
[Unit]
Description=每 5 分钟自动修复文件模式隧道

[Timer]
OnBootSec=30
OnUnitActiveSec=300

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable argo-file-health.timer
systemctl start argo-file-health.timer
}

# ============================
# 删除隧道
# ============================
delete_file_tunnel(){
    echo -e "${YELLOW}确认删除文件模式隧道？(YES 删除)${NC}"
    read -p "> " C
    [[ "$C" != "YES" ]] && echo "已取消" && return

    systemctl stop argo-file 2>/dev/null
    systemctl disable argo-file 2>/dev/null
    rm -f /etc/systemd/system/argo-file.service

    rm -f "$FILE_INFO"
    rm -f "$CF_DIR/config.yml"

    echo -e "${GREEN}文件模式隧道已删除${NC}"
}

# ============================
# 菜单
# ============================
menu(){
    while true; do
        title "固定隧道（文件模式）独立管理"

        if [[ -f "$FILE_INFO" ]]; then
            read TID DOMAIN PORT < "$FILE_INFO"
            echo -e "状态：${GREEN}已创建${NC}"
            echo "域名：$DOMAIN"
            echo "Tunnel ID：$TID"
        else
            echo -e "状态：${RED}未创建${NC}"
        fi

        echo
        echo "1) 创建文件模式隧道"
        echo "2) 重启文件模式隧道"
        echo "3) 停止文件模式隧道"
        echo "4) 删除文件模式隧道"
        echo "5) 手动诊断并自动修复"
        echo "0) 退出"
        read -p "选择: " CH

        case $CH in
            1) create_file_tunnel ;;
            2) systemctl restart argo-file ;;
            3) systemctl stop argo-file ;;
            4) delete_file_tunnel ;;
            5) heal_file_manual ;;
            0) exit 0 ;;
        esac
    done
}

# ============================
# 启动入口
# ============================
generate_file_health_script
install_file_health_timer
menu
