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
# 临时隧道（后台运行 + 错误捕获）
# ============================
create_temp_tunnel() {
    title "创建临时隧道"

    rm -f "$TEMP_LOG"

    nohup $BIN tunnel --url http://localhost:8080 --no-autoupdate \
        > "$TEMP_LOG" 2>&1 &

    sleep 2

    if ! pgrep -f "cloudflared tunnel --url" >/dev/null; then
        echo -e "${RED}临时隧道启动失败！${NC}"
        echo "错误日志："
        tail -n 20 "$TEMP_LOG"
        return
    fi

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

cat > /etc/systemd/system/argo-file.service <<EOF
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

    echo "$TUNNEL_ID $DOMAIN $PORT file" > "$WORKDIR/fixed_file.txt"

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

cat > /etc/systemd/system/argo-token.service <<EOF
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

    echo "$TOKEN" > "$WORKDIR/fixed_token.txt"

    systemctl daemon-reload
    systemctl enable argo-token
    systemctl restart argo-token

    echo -e "${GREEN}固定隧道（Token 模式）已启动${NC}"
}

# ============================
# 删除逻辑（独立）
# ============================
delete_fixed_file() {
    echo -e "${YELLOW}确认删除文件模式隧道？(y/n)${NC}"
    read -p "> " CONFIRM
    [[ "$CONFIRM" != "y" ]] && echo "已取消" && return

    systemctl stop argo-file 2>/dev/null
    systemctl disable argo-file 2>/dev/null
    rm -f /etc/systemd/system/argo-file.service
    rm -f "$WORKDIR/fixed_file.txt"
    rm -f "$CF_DIR/config.yml"

    echo -e "${GREEN}文件模式隧道已删除${NC}"
}

delete_fixed_token() {
    echo -e "${YELLOW}确认删除 Token 模式隧道？(y/n)${NC}"
    read -p "> " CONFIRM
    [[ "$CONFIRM" != "y" ]] && echo "已取消" && return

    systemctl stop argo-token 2>/dev/null
    systemctl disable argo-token 2>/dev/null
    rm -f /etc/systemd/system/argo-token.service
    rm -f "$WORKDIR/fixed_token.txt"

    echo -e "${GREEN}Token 模式隧道已删除${NC}"
}

delete_all() {
    echo -e "${RED}⚠⚠⚠ 危险操作：删除所有 Argo 隧道配置与文件 ⚠⚠⚠${NC}"
    echo -e "${YELLOW}确认继续？(输入 YES 删除)：${NC}"
    read -p "> " CONFIRM

    [[ "$CONFIRM" != "YES" ]] && echo "已取消" && return

    systemctl stop argo-file 2>/dev/null
    systemctl stop argo-token 2>/dev/null
    systemctl disable argo-file 2>/dev/null
    systemctl disable argo-token 2>/dev/null

    rm -f /etc/systemd/system/argo-file.service
    rm -f /etc/systemd/system/argo-token.service

    rm -rf "$WORKDIR"
    rm -rf "$CF_DIR"

    echo -e "${GREEN}所有 Argo 隧道文件与服务已删除${NC}"
}

# ============================
# 固定隧道子菜单
# ============================
menu_fixed_file() {
    title "文件模式隧道管理"

    if [[ -f "$WORKDIR/fixed_file.txt" ]]; then
        read FID FDOMAIN FPORT FMODE < "$WORKDIR/fixed_file.txt"
        echo -e "文件模式隧道：${GREEN}运行中${NC}"
        echo "域名：$FDOMAIN"
        echo "Tunnel ID：$FID"
    else
        echo -e "${RED}文件模式隧道未创建${NC}"
    fi

    echo
    echo "1) 创建文件模式隧道"
    echo "2) 重启文件模式隧道"
    echo "3) 关闭文件模式隧道"
    echo "4) 删除文件模式隧道"
    echo "0) 返回"
    read -p "选择: " CH

    case $CH in
        1) download_cloudflared; create_fixed_tunnel_file ;;
        2) systemctl restart argo-file ;;
        3) systemctl stop argo-file ;;
        4) delete_fixed_file ;;
        0) return ;;
    esac
}

menu_fixed_token() {
    title "Token 模式隧道管理"

    if [[ -f "$WORKDIR/fixed_file.txt" ]]; then
        read FID FDOMAIN FPORT FMODE < "$WORKDIR/fixed_file.txt"
        echo -e "文件模式隧道：${GREEN}运行中${NC}"
        echo "域名：$FDOMAIN"
        echo "Tunnel ID：$FID"
        echo
    fi

    if [[ -f "$WORKDIR/fixed_token.txt" ]]; then
        read TOKEN < "$WORKDIR/fixed_token.txt"
        echo -e "Token 模式隧道：${GREEN}运行中${NC}"
        echo "Token：$TOKEN"
    else
        echo -e "${RED}Token 模式隧道未创建${NC}"
    fi

    echo
    echo "1) 创建 Token 模式隧道"
    echo "2) 重启 Token 模式隧道"
    echo "3) 关闭 Token 模式隧道"
    echo "4) 删除 Token 模式隧道"
    echo "0) 返回"
    read -p "选择: " CH

    case $CH in
        1) download_cloudflared; create_fixed_tunnel_token ;;
        2) systemctl restart argo-token ;;
        3) systemctl stop argo-token ;;
        4) delete_fixed_token ;;
        0) return ;;
    esac
}

menu_fixed() {
    while true; do
        title "固定隧道管理"

        if [[ -f "$WORKDIR/fixed_file.txt" ]]; then
            read FID FDOMAIN FPORT FMODE < "$WORKDIR/fixed_file.txt"
            echo -e "文件模式隧道：${GREEN}运行中${NC}"
            echo "域名：$FDOMAIN"
            echo "Tunnel ID：$FID"
        else
            echo -e "文件模式隧道：${RED}未创建${NC}"
        fi

        echo

        if [[ -f "$WORKDIR/fixed_token.txt" ]]; then
            read TOKEN < "$WORKDIR/fixed_token.txt"
            echo -e "Token 模式隧道：${GREEN}运行中${NC}"
            echo "Token：$TOKEN"
        else
            echo -e "Token 模式隧道：${RED}未创建${NC}"
        fi

        echo
        echo "1) 文件模式隧道管理"
        echo "2) Token 模式隧道管理"
        echo "3) 删除所有隧道（危险）"
        echo "0) 返回"
        read -p "选择: " CH

        case $CH in
            1) menu_fixed_file ;;
            2) menu_fixed_token ;;
            3) delete_all ;;
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

        echo

        if [[ -f "$WORKDIR/fixed_file.txt" ]]; then
            read FID FDOMAIN FPORT FMODE < "$WORKDIR/fixed_file.txt"
            echo -e "文件模式隧道：${GREEN}存在${NC}（不代表一定在运行）"
            echo "域名：$FDOMAIN"
            echo "Tunnel ID：$FID"
        else
            echo -e "文件模式隧道：${RED}未创建${NC}"
        fi

        if [[ -f "$WORKDIR/fixed_token.txt" ]]; then
            read TOKEN < "$WORKDIR/fixed_token.txt"
            echo -e "Token 模式隧道：${GREEN}存在${NC}（不代表一定在运行）"
            echo "Token：$TOKEN"
        else
            echo -e "Token 模式隧道：${RED}未创建${NC}"
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
