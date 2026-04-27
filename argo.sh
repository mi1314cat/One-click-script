#!/usr/bin/env bash
set -e

WORKDIR="/root/argo"
BIN="$WORKDIR/cloudflared"
LOG="$WORKDIR/temp.log"
SAVE="$WORKDIR/tunnel_url.txt"
SERVICE="/etc/systemd/system/argo.service"

mkdir -p "$WORKDIR"

GREEN="\033[32m"
RED="\033[31m"
NC="\033[0m"

download_cloudflared() {
    if [[ ! -f "$BIN" ]]; then
        echo "正在下载 cloudflared..."
        wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x "$BIN"
    fi
}

# -------------------------
# 临时隧道
# -------------------------
create_temp_tunnel() {
    echo "正在创建临时 Argo 隧道..."
    rm -f "$LOG"
    $BIN tunnel --url http://localhost:8080 --no-autoupdate 2>&1 | tee "$LOG" &
    sleep 2

    echo "等待隧道 URL 输出..."

    for i in {1..20}; do
        URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$LOG" | head -n 1)
        [[ -n "$URL" ]] && break
        sleep 1
    done

    if [[ -z "$URL" ]]; then
        echo "未能捕获到临时隧道 URL"
        exit 1
    fi

    echo "$URL" > "$SAVE"
    echo "临时隧道地址：$URL"
    echo "已保存到：$SAVE"
}

status_temp_tunnel_color() {
    if pgrep -f "cloudflared tunnel --url" >/dev/null; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

restart_temp_tunnel() {
    stop_temp_tunnel
    create_temp_tunnel
}

stop_temp_tunnel() {
    pkill -f "cloudflared tunnel --url" 2>/dev/null && echo "临时隧道已关闭" || echo "未找到临时隧道进程"
}

# -------------------------
# 固定隧道
# -------------------------
create_fixed_tunnel() {

    echo "=============================="
    echo "固定隧道创建说明"
    echo "=============================="
    echo
    echo "1. 登录 Cloudflare Zero Trust 后台："
    echo "   https://one.dash.cloudflare.com/"
    echo
    echo "2. 进入：Access → Tunnels → Create Tunnel"
    echo
    echo "3. 创建一个新的 Tunnel，并复制生成的 Token"
    echo
    echo "4. 将 Token 粘贴到下面（输入 0 返回）"
    echo

    read -p "请输入 Argo Token: " TOKEN

    [[ "$TOKEN" == "0" ]] && return
    [[ -z "$TOKEN" ]] && echo "Token 不能为空" && return

cat > "$SERVICE" <<EOF
[Unit]
Description=Argo 隧道
After=network.target

[Service]
ExecStart=$BIN tunnel --no-autoupdate run --token $TOKEN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable argo
    systemctl restart argo

    echo "固定隧道已启动"
}

status_fixed_tunnel_color() {
    if systemctl is-active --quiet argo; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

restart_fixed_tunnel() {
    systemctl restart argo && echo "固定隧道已重启"
}

stop_fixed_tunnel() {
    systemctl stop argo 2>/dev/null && echo "固定隧道已关闭" || echo "未找到固定隧道服务"
}

# -------------------------
# 删除逻辑
# -------------------------
delete_temp() {
    stop_temp_tunnel
    rm -f "$LOG" "$SAVE"
    echo "临时隧道文件已删除"
}

delete_fixed() {
    stop_fixed_tunnel
    systemctl disable argo 2>/dev/null || true
    rm -f "$SERVICE"
    systemctl daemon-reload
    echo "固定隧道已删除"
}

delete_all() {
    delete_temp
    delete_fixed
    rm -rf "$WORKDIR"
    echo "所有脚本文件已删除"
}

# -------------------------
# 子菜单（循环）
# -------------------------
menu_temp() {
    while true; do
        echo "------ 临时隧道管理 ------"
        echo -n "状态："; status_temp_tunnel_color
        [[ -f "$SAVE" ]] && echo "隧道地址：$(cat $SAVE)"
        echo
        echo "1) 创建临时隧道"
        echo "2) 查看状态"
        echo "3) 重启临时隧道"
        echo "4) 关闭临时隧道"
        echo "0) 返回主菜单"
        read -p "请选择: " CH
        case $CH in
            1) download_cloudflared; create_temp_tunnel ;;
            2) echo -n "状态："; status_temp_tunnel_color; [[ -f "$SAVE" ]] && echo "隧道地址：$(cat $SAVE)" ;;
            3) restart_temp_tunnel ;;
            4) stop_temp_tunnel ;;
            0) return ;;
            *) echo "无效选项" ;;
        esac
    done
}

menu_fixed() {
    while true; do
        echo "------ 固定隧道管理 ------"
        echo -n "状态："; status_fixed_tunnel_color
        echo
        echo "1) 创建固定隧道"
        echo "2) 查看状态"
        echo "3) 重启固定隧道"
        echo "4) 关闭固定隧道"
        echo "0) 返回主菜单"
        read -p "请选择: " CH
        case $CH in
            1) download_cloudflared; create_fixed_tunnel ;;
            2) echo -n "状态："; status_fixed_tunnel_color ;;
            3) restart_fixed_tunnel ;;
            4) stop_fixed_tunnel ;;
            0) return ;;
            *) echo "无效选项" ;;
        esac
    done
}

menu_delete() {
    while true; do
        echo "------ 删除管理 ------"
        echo "1) 删除临时隧道"
        echo "2) 删除固定隧道"
        echo "3) 删除所有脚本文件"
        echo "0) 返回主菜单"
        read -p "请选择: " CH
        case $CH in
            1) delete_temp ;;
            2) delete_fixed ;;
            3) delete_all ;;
            0) return ;;
            *) echo "无效选项" ;;
        esac
    done
}

# -------------------------
# 主菜单（循环 + 状态显示）
# -------------------------
menu() {
    while true; do
        echo "=============================="
        echo "      Argo 隧道管理工具"
        echo "=============================="

        echo -n "临时隧道："; status_temp_tunnel_color
        [[ -f "$SAVE" ]] && echo "临时域名：$(cat $SAVE)"

        echo -n "固定隧道："; status_fixed_tunnel_color
        echo

        echo "1) 临时隧道管理"
        echo "2) 固定隧道管理"
        echo "3) 删除管理"
        echo "0) 退出"
        read -p "请选择: " CH

        case $CH in
            1) menu_temp ;;
            2) menu_fixed ;;
            3) menu_delete ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac
    done
}

menu
