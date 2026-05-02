#!/usr/bin/env bash
set -euo pipefail

# 管理面板脚本（增强版）
BASE_DIR="/root/catmi/gost"
ENV_FILE="$BASE_DIR/gost.env"
GOST_BIN="$BASE_DIR/gost"
LOG_DIR="/var/log/gost_manage"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
NC="\033[0m"

mkdir -p "$LOG_DIR"
touch "$LOG_DIR/manage.log"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_DIR/manage.log"; }

trap 'exit 1' INT TERM

# 读取 env
load_env() {
    if [ -f "$ENV_FILE" ]; then
        # shellcheck disable=SC1090
        source "$ENV_FILE"
    fi
}

# 更稳健的服务存在检测
has_service() {
    local name="$1"
    if systemctl list-unit-files --type=service --no-legend | awk '{print $1}' | grep -qx "${name}.service"; then
        return 0
    fi
    if [ -f "/etc/systemd/system/${name}.service" ] || [ -f "/lib/systemd/system/${name}.service" ] || [ -f "/usr/lib/systemd/system/${name}.service" ]; then
        return 0
    fi
    return 1
}

# 查找占用端口的进程
who_listen_port() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnp "( sport = :$port )" 2>/dev/null || true
    elif command -v lsof >/dev/null 2>&1; then
        lsof -iTCP -sTCP:LISTEN -P -n | grep ":$port" || true
    else
        netstat -ltnp 2>/dev/null | grep ":$port" || true
    fi
}

# 显示服务端状态
show_server_status() {
    echo -e "${YELLOW}====== 服务端状态 ======${NC}"
    if ! has_service "gost-server"; then
        echo -e "${RED}未检测到 gost-server.service${NC}"
        return
    fi

    load_env

    echo -e "${GREEN}服务：gost-server.service${NC}"
    systemctl --no-pager -l status gost-server.service | sed -n '1,12p' || true

    echo
    echo -e "${GREEN}配置：${NC}"
    echo "  uargo_domain = ${uargo_domain:-<未定义>}"
    echo "  ws_path      = ${ws_path:-<未定义>}"
    echo "  gost_port    = ${gost_port:-<未定义>}"

    echo
    echo -e "${GREEN}监听端口：${NC}"
    ss -tulnp | grep -E 'gost|gost-bin' || echo "  未找到 gost 监听（可能未运行或被占用）"
}

# 显示客户端状态
show_client_status() {
    echo -e "${YELLOW}====== 客户端状态 ======${NC}"
    load_env

    if has_service "gost-socks5"; then
        echo -e "${GREEN}服务：gost-socks5.service${NC}"
        systemctl --no-pager -l status gost-socks5.service | sed -n '1,10p' || true
    else
        echo -e "${RED}未检测到 gost-socks5.service${NC}"
    fi

    echo

    if has_service "gost-rtcp"; then
        echo -e "${GREEN}服务：gost-rtcp.service${NC}"
        systemctl --no-pager -l status gost-rtcp.service | sed -n '1,10p' || true
    else
        echo -e "${RED}未检测到 gost-rtcp.service${NC}"
    fi

    echo
    echo -e "${GREEN}配置：${NC}"
    echo "  uargo_domain = ${uargo_domain:-<未定义>}"
    echo "  ws_path      = ${ws_path:-<未定义>}"
    echo "  socks5_port  = ${socks5_port:-<未定义>}"
    echo "  rtcp_port    = ${rtcp_port:-<未定义>}"

    echo
    echo -e "${GREEN}监听端口：${NC}"
    ss -tulnp | grep -E 'gost|gost-bin' || echo "  未找到 gost 监听（可能未运行）"
}

# 重启服务端
restart_server() {
    if ! has_service "gost-server"; then
        echo -e "${RED}未检测到 gost-server.service${NC}"
        return
    fi
    log "重启 gost-server.service"
    systemctl restart gost-server.service
    systemctl status gost-server.service --no-pager -l | sed -n '1,12p'
}

# 重启客户端
restart_client() {
    local any=0
    if has_service "gost-socks5"; then
        log "重启 gost-socks5.service"
        systemctl restart gost-socks5.service
        systemctl status gost-socks5.service --no-pager -l | sed -n '1,8p'
        any=1
    fi
    if has_service "gost-rtcp"; then
        log "重启 gost-rtcp.service"
        systemctl restart gost-rtcp.service
        systemctl status gost-rtcp.service --no-pager -l | sed -n '1,8p'
        any=1
    fi
    if [ "$any" -eq 0 ]; then
        echo -e "${RED}未检测到客户端服务可重启${NC}"
    fi
}

# 查看日志
show_logs() {
    echo -e "${YELLOW}====== 日志查看 ======${NC}"
    echo "1) 服务端日志 (gost-server)"
    echo "2) 客户端日志 (gost-socks5 + gost-rtcp)"
    read -rp "选择: " c
    case "$c" in
        1)
            if has_service "gost-server"; then
                journalctl -u gost-server.service -n 200 --no-pager
            else
                echo -e "${RED}未检测到 gost-server.service${NC}"
            fi
            ;;
        2)
            if has_service "gost-socks5"; then
                journalctl -u gost-socks5.service -n 100 --no-pager
            fi
            if has_service "gost-rtcp"; then
                journalctl -u gost-rtcp.service -n 100 --no-pager
            fi
            if ! has_service "gost-socks5" && ! has_service "gost-rtcp"; then
                echo -e "${RED}未检测到客户端服務${NC}"
            fi
            ;;
        *)
            echo "返回"
            ;;
    esac
}

# 列出所有可能的 gost systemd 单元名
gost_unit_candidates() {
    printf "%s\n" "gost-server" "gost-socks5" "gost-rtcp" "gost-client" "gost" | sort -u
}

# 彻底删除所有 gost 相关文件与服务（不备份，确认 y/n 大小写不敏感）
delete_all() {
    echo -e "${RED}⚠ 警告：这将立即停止并删除所有 gost 相关服务与文件，且不做备份！${NC}"
    read -rp "确认删除？(y/n): " ans
    # 将输入转为小写再判断
    case "${ans,,}" in
        y|yes)
            log "用户确认删除（无备份）"
            ;;
        *)
            echo "已取消"
            return
            ;;
    esac

    log "停止并禁用相关 systemd 单元"
    for u in $(gost_unit_candidates); do
        if has_service "$u"; then
            systemctl stop "${u}.service" 2>/dev/null || true
            systemctl disable "${u}.service" 2>/dev/null || true
            systemctl mask "${u}.service" 2>/dev/null || true
            systemctl reset-failed "${u}.service" 2>/dev/null || true
            rm -f "/etc/systemd/system/${u}.service" "/lib/systemd/system/${u}.service" "/usr/lib/systemd/system/${u}.service" || true
        fi
    done

    systemctl daemon-reload || true

    # 删除二进制与 env
    if [ -f "$GOST_BIN" ]; then
        log "删除二进制 $GOST_BIN"
        rm -f "$GOST_BIN" || true
    fi
    if [ -f "$ENV_FILE" ]; then
        log "删除 env 文件 $ENV_FILE"
        rm -f "$ENV_FILE" || true
    fi

    # 删除 BASE_DIR（谨慎）
    if [ -d "$BASE_DIR" ]; then
        log "删除目录 $BASE_DIR"
        rm -rf "$BASE_DIR" || true
    fi

    # 清理 nginx 配置中可能的 gost 残留（仅在检测到相关内容时）
    if [ -f /etc/nginx/sites-enabled/default ]; then
        if grep -E "gost|ws/relay|proxy_pass.*127.0.0.1" /etc/nginx/sites-enabled/default >/dev/null 2>&1; then
            log "检测到 nginx default 中可能的 gost 配置，尝试移除相关 location 段"
            awk '
            BEGIN{skip=0}
            /location .*ws\/relay/ {skip=1; next}
            /location .*{/{ if(skip==0) print; next }
            /}/ { if(skip==1){ skip=0; next } }
            { if(skip==0) print }
            ' /etc/nginx/sites-enabled/default > /etc/nginx/sites-enabled/default.tmp || true
            mv /etc/nginx/sites-enabled/default.tmp /etc/nginx/sites-enabled/default || true
            systemctl restart nginx >/dev/null 2>&1 || true
        fi
    fi

    # 解除 mask 并重置失败状态
    for u in $(gost_unit_candidates); do
        systemctl unmask "${u}.service" 2>/dev/null || true
        systemctl reset-failed "${u}.service" 2>/dev/null || true
    done

    log "删除完成（无备份）"
    echo -e "${GREEN}已删除所有 gost 文件和 systemd 服务（无备份）${NC}"
}

# 查看端口监听情况
show_ports() {
    echo -e "${YELLOW}====== 端口监听 ======${NC}"
    ss -tulnp | sed -n '1,200p'
    echo
    echo -e "${YELLOW}检查常见端口占用（20000,30000）${NC}"
    for p in 20000 30000; do
        echo "端口 $p 占用信息："
        who_listen_port "$p" || echo "  未被占用"
    done
}

# 主菜单
main_menu() {
    while true; do
        clear
        ROLE="未检测到任何 gost 服务"
        if has_service "gost-server" && ( has_service "gost-socks5" || has_service "gost-rtcp" ); then
            ROLE="双端（服务端 + 客户端）"
        elif has_service "gost-server"; then
            ROLE="仅服务端"
        elif has_service "gost-socks5" || has_service "gost-rtcp"; then
            ROLE="仅客户端"
        fi

        echo -e "${YELLOW}====== Gost 控制面板（增强版） ======${NC}"
        echo -e "当前角色：${GREEN}$ROLE${NC}"
        echo
        echo "1) 查看服务端状态"
        echo "2) 查看客户端状态"
        echo "3) 重启服务端 gost"
        echo "4) 重启客户端 gost"
        echo "5) 查看日志"
        echo "6) 查看端口监听情况"
        echo "7) 彻底删除所有 gost 文件和服务（无备份，确认 y/n）"
        echo "0) 退出"
        echo
        read -rp "请选择: " opt
        case "$opt" in
            1) show_server_status; read -rp "回车继续..." ;;
            2) show_client_status; read -rp "回车继续..." ;;
            3) restart_server; read -rp "回车继续..." ;;
            4) restart_client; read -rp "回车继续..." ;;
            5) show_logs; read -rp "回车继续..." ;;
            6) show_ports; read -rp "回车继续..." ;;
            7) delete_all; read -rp "回车继续..." ;;
            0) exit 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

main_menu
