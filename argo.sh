#!/usr/bin/env bash
set -e

# ============================
# 基础路径
# ============================
WORKDIR="/root/argo"
BIN="$WORKDIR/cloudflared"
CF_DIR="/root/.cloudflared"
TEMP_LOG="$WORKDIR/temp.log"
TEMP_SAVE="$WORKDIR/temp_url.txt"
FIXED_INFO="$WORKDIR/fixed_info.txt"
SERVICE_FILE="/etc/systemd/system/argo-file.service"

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

line() {
    echo -e "${BLUE}----------------------------------------${NC}"
}

title() {
    echo -e "${GREEN}$1${NC}"
    line
}

# ============================
# 下载 cloudflared
# ============================
download_cloudflared() {
    if [[ ! -f "$BIN" ]]; then
        title "正在下载 cloudflared..."
        wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x "$BIN"
    fi
}

# ============================
# 临时隧道（后台运行）
# ============================
# ============================
# 临时隧道（后台运行 + 错误捕获）
# ============================
create_temp_tunnel() {
    title "创建临时隧道"

    rm -f "$TEMP_LOG"

    # 后台运行，不阻塞脚本，不受 Ctrl+C 影响
    nohup $BIN tunnel --url http://localhost:8080 --no-autoupdate \
        > "$TEMP_LOG" 2>&1 &

    sleep 2

    # 检查 cloudflared 是否真的启动
    if ! pgrep -f "cloudflared tunnel --url" >/dev/null; then
        echo -e "${RED}临时隧道启动失败！${NC}"
        echo "错误日志："
        tail -n 20 "$TEMP_LOG"
        return
    fi

    # 捕获 URL
    for i in {1..20}; do
        URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TEMP_LOG" | head -n 1)
        [[ -n "$URL" ]] && break
        sleep 1
    done

    if [[ -z "$URL" ]]; then
        echo -e "${RED}未能捕获到临时隧道 URL${NC}"
        echo "错误日志："
        tail -n 20 "$TEMP_LOG"
        return
    fi

    echo "$URL" > "$TEMP_SAVE"
    echo -e "临时隧道：${GREEN}$URL${NC}"
}

status_temp() {
    if pgrep -f "cloudflared tunnel --url" >/dev/null; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

restart_temp() {
    stop_temp
    create_temp_tunnel
}

stop_temp() {
    pkill -f "cloudflared tunnel --url" 2>/dev/null && echo "临时隧道已关闭"
}

delete_temp() {
    stop_temp
    rm -f "$TEMP_LOG" "$TEMP_SAVE"
    echo "临时隧道文件已删除"
}


# ============================
# 固定隧道（文件模式）
# ============================
create_fixed_tunnel_file() {

    title "文件模式固定隧道创建"

    rm -f "$CF_DIR/config.yml"

    if [[ -f "$CF_DIR/cert.pem" ]]; then
        echo "检测到 cert.pem，跳过登录"
    else
        $BIN login
    fi

    TUNNEL_NAME=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
    echo "Tunnel 名称：$TUNNEL_NAME"

    OUTPUT=$($BIN tunnel create "$TUNNEL_NAME" 2>&1)
    echo "$OUTPUT"

    TUNNEL_ID=$(echo "$OUTPUT" | grep -oE "[a-f0-9-]{36}" | head -n 1)
    echo "Tunnel ID：$TUNNEL_ID"

    read -p "请输入授权根域名（例如 catmicos.dpdns.org）: " ROOT_DOMAIN
    read -p "请输入本地反代端口（默认 8080）: " PORT
    PORT=${PORT:-8080}

    DOMAIN="${TUNNEL_NAME}.${ROOT_DOMAIN}"

cat > "$CF_DIR/config.yml" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CF_DIR/$TUNNEL_ID.json

ingress:
  - hostname: $DOMAIN
    service: http://localhost:$PORT
  - service: http_status:404
EOF

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Argo Tunnel (File Mode)
After=network.target

[Service]
ExecStart=$BIN tunnel run --config $CF_DIR/config.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    echo "$TUNNEL_ID $DOMAIN $PORT file" > "$FIXED_INFO"

    systemctl daemon-reload
    systemctl enable argo-file
    systemctl restart argo-file

    echo
    echo -e "${GREEN}固定隧道（文件模式）已启动${NC}"
    echo "域名：$DOMAIN"
    echo "Tunnel ID：$TUNNEL_ID"
    echo
    echo -e "${YELLOW}请到 Cloudflare DNS 添加 CNAME：${NC}"
    echo "  $DOMAIN  →  $TUNNEL_ID.cfargotunnel.com"
}

# ============================
# 固定隧道（Token 模式）
# ============================
create_fixed_tunnel_token() {

    title "Token 模式固定隧道创建"

    read -p "请输入 Cloudflare Argo Token: " TOKEN
    [[ -z "$TOKEN" ]] && echo "Token 不能为空" && return

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Argo Tunnel (Token Mode)
After=network.target

[Service]
ExecStart=$BIN tunnel run --token $TOKEN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    echo "token-mode" > "$FIXED_INFO"

    systemctl daemon-reload
    systemctl enable argo-file
    systemctl restart argo-file

    echo -e "${GREEN}固定隧道（Token 模式）已启动${NC}"
}

# ============================
# 固定隧道操作
# ============================
status_fixed() {
    if systemctl is-active --quiet argo-file; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

restart_fixed() {
    systemctl restart argo-file
    echo "固定隧道已重启"
}

stop_fixed() {
    systemctl stop argo-file 2>/dev/null
    echo "固定隧道已关闭"
}

delete_fixed() {
    stop_fixed
    systemctl disable argo-file 2>/dev/null
    rm -f "$SERVICE_FILE"
    rm -f "$FIXED_INFO"
    rm -f "$CF_DIR/config.yml"
    echo "固定隧道已删除"
}

# ============================
# 临时隧道菜单
# ============================
menu_temp() {
    while true; do
        title "临时隧道管理"
        echo -n "状态："; status_temp
        [[ -f "$TEMP_SAVE" ]] && echo "域名：$(cat $TEMP_SAVE)"
        echo
        echo "1) 创建临时隧道"
        echo "2) 重启临时隧道"
        echo "3) 关闭临时隧道"
        echo "4) 删除临时隧道"
        echo "0) 返回"
        read -p "选择: " CH
        case $CH in
            1) download_cloudflared; create_temp_tunnel ;;
            2) restart_temp ;;
            3) stop_temp ;;
            4) delete_temp ;;
            0) return ;;
        esac
    done
}

# ============================
# 固定隧道菜单（双模式）
# ============================
menu_fixed() {
    while true; do
        title "固定隧道管理"

        echo -n "状态："; status_fixed

        if [[ -f "$FIXED_INFO" ]]; then
            read TID DOMAIN PORT MODE < "$FIXED_INFO"

            if [[ "$MODE" == "file" ]]; then
                echo -e "模式：${GREEN}文件模式${NC}"
                echo "域名：$DOMAIN"
                echo "Tunnel ID：$TID"
            elif [[ "$MODE" == "token-mode" ]]; then
                echo -e "模式：${YELLOW}Token 模式${NC}"
                echo "（Token 模式无域名与 TunnelID 显示）"
            fi
        else
            echo -e "${RED}未创建固定隧道（无 fixed_info.txt）${NC}"
        fi

        echo
        echo "1) 创建固定隧道（文件模式）"
        echo "2) 创建固定隧道（Token 模式）"
        echo "3) 重启固定隧道"
        echo "4) 关闭固定隧道"
        echo "5) 删除固定隧道"
        echo "0) 返回"
        read -p "选择: " CH
        case $CH in
            1) download_cloudflared; create_fixed_tunnel_file ;;
            2) download_cloudflared; create_fixed_tunnel_token ;;
            3) restart_fixed ;;
            4) stop_fixed ;;
            5) delete_fixed ;;
            0) return ;;
        esac
    done
}



# ============================
# 主菜单
# ============================
menu_main() {
    while true; do
        title "Argo 隧道管理工具"

        echo -n "临时隧道："; status_temp
        [[ -f "$TEMP_SAVE" ]] && echo "临时域名：$(cat $TEMP_SAVE)"

        echo -n "固定隧道："; status_fixed
        if [[ -f "$FIXED_INFO" ]]; then
            read TID DOMAIN PORT MODE < "$FIXED_INFO"
            [[ "$MODE" == "file" ]] && echo "固定域名：$DOMAIN"
            [[ "$MODE" == "token-mode" ]] && echo "固定隧道模式：Token 模式"
        fi

        echo
        echo "1) 临时隧道管理"
        echo "2) 固定隧道管理"
        echo "0) 退出"
        read -p "选择: " CH
        case $CH in
            1) menu_temp ;;
            2) menu_fixed ;;
            0) exit 0 ;;
        esac
    done
}

menu_main
