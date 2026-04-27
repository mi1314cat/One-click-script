#!/usr/bin/env bash
set -e

WORKDIR="/root/argo_file"
BIN="$WORKDIR/cloudflared"
CF_DIR="/root/.cloudflared"
FILE_INFO="$WORKDIR/file_tunnel.txt"
LOG_FILE="$WORKDIR/file.log"
HEALTH_SCRIPT="$WORKDIR/file_health.sh"

mkdir -p "$WORKDIR" "$CF_DIR"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[36m"
NC="\033[0m"

line(){ echo -e "${BLUE}----------------------------------------${NC}"; }
title(){ echo -e "${GREEN}$1${NC}"; line; }

confirm(){
    read -p "> " C
    C=$(echo "$C" | tr 'A-Z' 'a-z')
    [[ "$C" == "y" ]]
}

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

create_file_tunnel(){
    check_cloudflared
    title "创建文件模式固定隧道"

    if [[ ! -f "$CF_DIR/cert.pem" ]]; then
        echo -e "${YELLOW}未检测到 cert.pem，执行 cloudflared login...${NC}"
        $BIN login
    fi

    TUNNEL_NAME=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
    echo "Tunnel 名称：$TUNNEL_NAME"

    OUTPUT=$($BIN tunnel create "$TUNNEL_NAME" 2>&1)
    echo "$OUTPUT"

    TID=$(echo "$OUTPUT" | grep -oE "[a-f0-9-]{36}" | head -n 1)
    [[ -z "$TID" ]] && { echo -e "${RED}创建隧道失败${NC}"; return; }

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
systemctl enable argo-file
systemctl restart argo-file

echo -e "${GREEN}隧道已启动${NC}"
echo "域名：$DOMAIN"
echo "Tunnel ID：$TID"
echo "请到 Cloudflare DNS 添加："
echo "$DOMAIN  CNAME  $TID.cfargotunnel.com"
}

heal_file_manual(){
    if [[ ! -f "$FILE_INFO" ]]; then
        echo -e "${RED}未创建隧道${NC}"
        return
    fi

    read TID DOMAIN PORT < "$FILE_INFO"

    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "https://$DOMAIN" || echo "000")

    if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
        echo -e "${GREEN}隧道健康${NC}"
        return
    fi

    echo -e "${RED}隧道异常，重启中...${NC}"
    systemctl restart argo-file
}

generate_file_health_script(){
cat > "$HEALTH_SCRIPT" <<EOF
#!/usr/bin/env bash
WORKDIR="/root/argo_file"
FILE_INFO="\$WORKDIR/file_tunnel.txt"

if [[ ! -f "\$FILE_INFO" ]]; then exit 0; fi

read TID DOMAIN PORT < "\$FILE_INFO"

HTTP_CODE=\$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "https://\$DOMAIN" || echo "000")

if [[ ! "\$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
    systemctl restart argo-file
fi
EOF

chmod +x "$HEALTH_SCRIPT"
}

install_file_health_timer(){
cat > /etc/systemd/system/argo-file-health.service <<EOF
[Unit]
Description=自动修复文件模式隧道

[Service]
Type=oneshot
ExecStart=/bin/bash $HEALTH_SCRIPT
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

delete_file_tunnel(){
    echo -e "${YELLOW}确认删除文件模式隧道？(y/n)${NC}"
    confirm || return

    if [[ -f /etc/systemd/system/argo-file.service ]]; then
        systemctl stop argo-file 2>/dev/null
        systemctl disable argo-file 2>/dev/null
        rm -f /etc/systemd/system/argo-file.service
    fi

    rm -f "$FILE_INFO"
    rm -f "$CF_DIR/config.yml"

    echo -e "${GREEN}文件模式隧道已删除${NC}"
}

delete_all(){
    echo -e "${YELLOW}确认彻底删除所有文件？(y/n)${NC}"
    confirm || return

    delete_file_tunnel
    rm -rf "$WORKDIR"

    echo -e "${GREEN}所有文件已删除${NC}"
}

delete_script(){
    echo -e "${YELLOW}此操作将彻底删除脚本 + 所有隧道文件 + 所有 Cloudflare 凭证${NC}"
    echo -e "${RED}删除后必须重新 cloudflared login${NC}"
    echo -e "${YELLOW}确认执行？(y/n)${NC}"
    confirm || return

    echo -e "${GREEN}正在删除 systemd 服务...${NC}"
    systemctl stop argo-file 2>/dev/null || true
    systemctl disable argo-file 2>/dev/null || true
    rm -f /etc/systemd/system/argo-file.service

    systemctl stop argo-file-health.timer 2>/dev/null || true
    systemctl disable argo-file-health.timer 2>/dev/null || true
    rm -f /etc/systemd/system/argo-file-health.service
    rm -f /etc/systemd/system/argo-file-health.timer

    echo -e "${GREEN}正在删除隧道目录...${NC}"
    rm -rf /root/argo_file

    echo -e "${GREEN}正在删除 Cloudflare 凭证...${NC}"
    rm -f /root/.cloudflared/*.json
    rm -f /root/.cloudflared/cert.pem
    rm -f /root/.cloudflared/config.yml

    echo -e "${GREEN}正在删除脚本本体...${NC}"
    rm -f /root/argo_file.sh

    echo -e "${GREEN}彻底删除完成！系统已恢复到初始状态${NC}"
    exit 0
}

view_log(){
    title "文件模式隧道日志"
    [[ -f "$LOG_FILE" ]] && tail -n 50 "$LOG_FILE" || echo -e "${RED}没有日志文件${NC}"
}

menu(){
    while true; do
        title "固定隧道（文件模式）管理"

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
        echo "6) 查看日志"
        echo "7) 删除所有文件"
        echo "8) 删除脚本"
        echo "0) 退出"
        read -p "选择: " CH

        case $CH in
            1) create_file_tunnel ;;
            2)
                [[ -f /etc/systemd/system/argo-file.service ]] && systemctl restart argo-file || echo -e "${RED}未创建隧道${NC}"
                ;;
            3)
                [[ -f /etc/systemd/system/argo-file.service ]] && systemctl stop argo-file || echo -e "${RED}未创建隧道${NC}"
                ;;
            4) delete_file_tunnel ;;
            5) heal_file_manual ;;
            6) view_log ;;
            7) delete_all ;;
            8) delete_script ;;
            0) exit 0 ;;
        esac
    done
}

generate_file_health_script
install_file_health_timer
menu
