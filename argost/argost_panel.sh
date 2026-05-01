#!/usr/bin/env bash
set -e

BASE_DIR="/root/catmi/gost"
ENV_FILE="$BASE_DIR/gost.env"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
NC="\033[0m"

# 读取 env
load_env() {
    if [ -f "$ENV_FILE" ]; then
        # shellcheck disable=SC1090
        source "$ENV_FILE"
    fi
}

# 检查服务是否存在
has_service() {
    local name="$1"
    systemctl list-unit-files | grep -q "^${name}.service"
}

# 检查服务是否 active
is_active() {
    local name="$1"
    systemctl is-active --quiet "$name"
}

# 检测角色
detect_role() {
    ROLE=""
    SERVER=0
    CLIENT=0

    if has_service "gost-server"; then
        SERVER=1
    fi
    if has_service "gost-socks5" || has_service "gost-rtcp"; then
        CLIENT=1
    fi

    if [ "$SERVER" -eq 1 ] && [ "$CLIENT" -eq 1 ]; then
        ROLE="双端（服务端 + 客户端）"
    elif [ "$SERVER" -eq 1 ]; then
        ROLE="仅服务端"
    elif [ "$CLIENT" -eq 1 ]; then
        ROLE="仅客户端"
    else
        ROLE="未检测到任何 gost 服务"
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
    systemctl --no-pager -l status gost-server.service | sed -n '1,8p'

    echo
    echo -e "${GREEN}配置：${NC}"
    echo "  uargo_domain = ${uargo_domain:-<未定义>}"
    echo "  ws_path      = ${ws_path:-<未定义>}"
    echo "  gost_port    = ${gost_port:-<未定义>}"

    echo
    echo -e "${GREEN}监听端口：${NC}"
    ss -tulnp | grep gost || echo "  未找到 gost 监听（可能未运行或被占用）"
}

# 显示客户端状态
show_client_status() {
    echo -e "${YELLOW}====== 客户端状态 ======${NC}"

    load_env

    if has_service "gost-socks5"; then
        echo -e "${GREEN}服务：gost-socks5.service${NC}"
        systemctl --no-pager -l status gost-socks5.service | sed -n '1,8p'
    else
        echo -e "${RED}未检测到 gost-socks5.service${NC}"
    fi

    echo

    if has_service "gost-rtcp"; then
        echo -e "${GREEN}服务：gost-rtcp.service${NC}"
        systemctl --no-pager -l status gost-rtcp.service | sed -n '1,8p'
    else
        echo -e "${RED}未检测到 gost-rtcp.service${NC}"
    fi

    echo
    echo -e "${GREEN}配置：${NC}"
    echo "  uargo_domain = ${uargo_domain:-<未定义>}"
    echo "  ws_path      = ${ws_path:-<未定义>}"
    echo "  socks5_port  = ${socks5_port:-<你在安装时输入的端口>}"
    echo "  rtcp_port    = ${rtcp_port:-<你在安装时输入的端口>}"
    echo "  映射关系：本地 SOCKS5 → 127.0.0.1:${socks5_port:-20000}"
    echo "           RTCP 监听 → :${rtcp_port:-30000} → 远端 gost_port=${gost_port:-<服务端端口>}"
    echo
    echo -e "${GREEN}监听端口：${NC}"
    ss -tulnp | grep gost || echo "  未找到 gost 监听（可能未运行）"
}

# 重启服务端
restart_server() {
    if ! has_service "gost-server"; then
        echo -e "${RED}未检测到 gost-server.service${NC}"
        return
    fi
    systemctl restart gost-server.service
    echo -e "${GREEN}已重启 gost-server.service${NC}"
}

# 重启客户端
restart_client() {
    if has_service "gost-socks5"; then
        systemctl restart gost-socks5.service
        echo -e "${GREEN}已重启 gost-socks5.service${NC}"
    fi
    if has_service "gost-rtcp"; then
        systemctl restart gost-rtcp.service
        echo -e "${GREEN}已重启 gost-rtcp.service${NC}"
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
                journalctl -u gost-server.service -n 50 --no-pager
            else
                echo -e "${RED}未检测到 gost-server.service${NC}"
            fi
            ;;
        2)
            if has_service "gost-socks5"; then
                journalctl -u gost-socks5.service -n 30 --no-pager
            fi
            if has_service "gost-rtcp"; then
                journalctl -u gost-rtcp.service -n 30 --no-pager
            fi
            if ! has_service "gost-socks5" && ! has_service "gost-rtcp"; then
                echo -e "${RED}未检测到客户端服务${NC}"
            fi
            ;;
        *)
            echo "返回"
            ;;
    esac
}

# 删除所有 gost 相关
delete_all() {
    echo -e "${RED}⚠ 警告：这将删除所有 gost 文件和 systemd 服务！${NC}"
    read -rp "确认删除？输入 YES 确认: " ans
    if [ "$ans" != "YES" ]; then
        echo "已取消"
        return
    fi

    # 停止服务
    systemctl stop gost-server.service 2>/dev/null || true
    systemctl stop gost-socks5.service 2>/dev/null || true
    systemctl stop gost-rtcp.service 2>/dev/null || true

    # 删除服务文件
    rm -f /etc/systemd/system/gost-server.service
    rm -f /etc/systemd/system/gost-socks5.service
    rm -f /etc/systemd/system/gost-rtcp.service

    systemctl daemon-reload

    # 删除目录
    rm -rf "$BASE_DIR"

    echo -e "${GREEN}已删除所有 gost 文件和 systemd 服务${NC}"
}

# 主菜单
main_menu() {
    while true; do
        clear
        detect_role
        echo -e "${YELLOW}====== Gost 控制面板（脚本版）======${NC}"
        echo -e "当前角色：${GREEN}$ROLE${NC}"
        echo
        echo "1) 查看服务端状态"
        echo "2) 查看客户端状态"
        echo "3) 重启服务端 gost"
        echo "4) 重启客户端 gost"
        echo "5) 查看日志"
        echo "6) 查看端口监听情况"
        echo "7) 删除所有 gost 文件和服务"
        echo "0) 退出"
        echo
        read -rp "请选择: " opt
        case "$opt" in
            1) show_server_status; read -rp "回车继续..." ;;
            2) show_client_status; read -rp "回车继续..." ;;
            3) restart_server; read -rp "回车继续..." ;;
            4) restart_client; read -rp "回车继续..." ;;
            5) show_logs; read -rp "回车继续..." ;;
            6) ss -tulnp | grep gost || echo "未找到 gost 监听"; read -rp "回车继续..." ;;
            7) delete_all; read -rp "回车继续..." ;;
            0) exit 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

main_menu
