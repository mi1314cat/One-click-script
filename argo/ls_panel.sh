#!/usr/bin/env bash
set -e

# ============================
# 基础路径（完全隔离）
# ============================
WORKDIR="/root/argo_temp"
BIN="$WORKDIR/cloudflared"
TEMP_LOG="$WORKDIR/temp.log"
TEMP_SAVE="$WORKDIR/temp_url.txt"

mkdir -p "$WORKDIR"

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
# cloudflared 自动检测
# ============================
check_cloudflared() {
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
# 创建临时隧道（核心修复版）
# ============================
create_temp_tunnel() {
    check_cloudflared
    title "创建临时隧道"

    rm -f "$TEMP_LOG"

    # 关键修复：强制不加载任何配置
    nohup $BIN tunnel --url http://localhost:8080 --no-autoupdate --config /dev/null \
        > "$TEMP_LOG" 2>&1 &

    sleep 2

    if ! pgrep -f "cloudflared tunnel --url" >/dev/null; then
        echo -e "${RED}临时隧道启动失败！${NC}"
        tail -n 20 "$TEMP_LOG"
        return
    fi

    for i in {1..20}; do
        URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TEMP_LOG" | head -n 1)
        [[ -n "$URL" ]] && break
        sleep 1
    done

    if [[ -z "$URL" ]]; then
        echo -e "${RED}未捕获到临时隧道 URL${NC}"
        tail -n 20 "$TEMP_LOG"
        return
    fi

    echo "$URL" > "$TEMP_SAVE"
    echo -e "临时隧道：${GREEN}$URL${NC}"
}

# ============================
# 状态
# ============================
status_temp() {
    if pgrep -f "cloudflared tunnel --url" >/dev/null; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

# ============================
# 重启
# ============================
restart_temp() {
    stop_temp
    create_temp_tunnel
}

# ============================
# 停止
# ============================
stop_temp() {
    pkill -f "cloudflared tunnel --url" 2>/dev/null
    echo "临时隧道已关闭"
}

# ============================
# 删除
# ============================
delete_temp() {
    stop_temp
    rm -f "$TEMP_LOG" "$TEMP_SAVE"
    echo "临时隧道文件已删除"
}

# ============================
# 手动诊断 + 自动修复（无 systemd）
# ============================
heal_temp_manual() {
    if [[ ! -f "$TEMP_SAVE" ]]; then
        echo -e "${RED}没有记录中的临时隧道${NC}"
        return
    fi

    URL=$(cat "$TEMP_SAVE")
    echo -e "检测临时隧道：${GREEN}$URL${NC}"

    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "$URL" || echo "000")

    if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
        echo -e "${GREEN}临时隧道健康（HTTP $HTTP_CODE）${NC}"
        return
    fi

    echo -e "${RED}临时隧道异常（HTTP $HTTP_CODE），自动修复中...${NC}"

    restart_temp
}

# ============================
# 删除所有临时隧道文件（彻底清理）
# ============================
delete_all_temp() {
    title "删除所有临时隧道文件（彻底清理）"

    stop_temp
    rm -rf /root/argo_temp

    echo -e "${GREEN}临时隧道所有文件已彻底删除${NC}"
}

# ============================
# 查看日志
# ============================
view_temp_log() {
    title "临时隧道日志"
    if [[ -f "$TEMP_LOG" ]]; then
        tail -n 50 "$TEMP_LOG"
    else
        echo -e "${RED}没有日志文件${NC}"
    fi
}

# ============================
# 菜单
# ============================
menu() {
    while true; do
        title "临时隧道管理（优化稳定版）"

        echo -n "状态："; status_temp
        [[ -f "$TEMP_SAVE" ]] && echo "域名：$(cat $TEMP_SAVE)"
        echo

        echo "1) 创建临时隧道"
        echo "2) 重启临时隧道"
        echo "3) 关闭临时隧道"
        echo "4) 删除临时隧道"
        echo "5) 手动诊断并自动修复"
        echo "6) 查看临时隧道日志"
        echo "7) 删除所有临时隧道文件（彻底清理）"
        echo "0) 退出"

        read -p "选择: " CH

        case $CH in
            1) create_temp_tunnel ;;
            2) restart_temp ;;
            3) stop_temp ;;
            4) delete_temp ;;
            5) heal_temp_manual ;;
            6) view_temp_log ;;
            7) delete_all_temp ;;
            0) exit 0 ;;
        esac
    done
}

menu
