#!/usr/bin/env bash
set -e

# ================================
# 彩色定义
# ================================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
WHITE="\e[97m"
BOLD="\e[1m"
RESET="\e[0m"

print_info()  { echo -e "${CYAN}[Info]${RESET} $1" >&2; }
print_ok()    { echo -e "${GREEN}[OK]${RESET}  $1" >&2; }
print_error() { echo -e "${RED}[Error]${RESET} $1" >&2; }
print_warn()  { echo -e "${YELLOW}[提醒]${RESET} $1" >&2; }

print_title() {
    echo -e "${MAGENTA}${BOLD}" >&2
    echo "╔══════════════════════════════════════════════╗" >&2
    printf "║ %-42s ║\n" "$1" >&2
    echo "╚══════════════════════════════════════════════╝" >&2
    echo -e "${RESET}" >&2
}

# ================================
# 基础路径
# ================================
BASE_DIR="/root/catmi/xgost"
CONF_DIR="$BASE_DIR/client"
GOST_BIN="$BASE_DIR/gost"
SYSTEMD_DIR="/etc/systemd/system"

mkdir -p "$CONF_DIR"

# ================================
# 工具函数
# ================================
clean_input() {
    echo "$1" | tr -d '\000-\037'
}

port_in_use() {
    ss -tuln | awk '{print $5}' | grep -E -q "(:|])$1$"
}

random_port() { shuf -i 10000-60000 -n 1; }

random_free_port() {
    while true; do
        p=$(random_port)
        if ! port_in_use "$p"; then
            echo "$p"
            return
        fi
    done
}

safe_read() {
    local prompt="$1" default="$2" input
    printf "%s (默认: %s): " "$prompt" "$default" >&2
    read input
    input=$(clean_input "$input")
    echo "${input:-$default}"
}

safe_read_port() {
    local default="$1" input port
    while true; do
        printf "请输入端口 (默认: %s): " "$default" >&2
        read input
        input=$(clean_input "$input")
        port="${input:-$default}"

        [[ "$port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; continue; }
        (( port >= 1 && port <= 65535 )) || { print_error "端口范围错误"; continue; }

        if port_in_use "$port"; then
            print_error "端口 $port 已占用"
            printf "选择操作: [1] 强制使用 [2] 自动换端口 [3] 重新输入: " >&2
            read choice
            choice=$(clean_input "$choice")

            case "$choice" in
                1)
                    echo "$port"
                    return
                    ;;
                2)
                    local new_port="$port"
                    while port_in_use "$new_port"; do
                        ((new_port++))
                        ((new_port > 65535)) && { print_error "没有可用端口"; continue 2; }
                    done
                    print_info "自动选择可用端口: $new_port"
                    echo "$new_port"
                    return
                    ;;
                3)
                    continue
                    ;;
                *)
                    print_error "无效选择"
                    continue
                    ;;
            esac
        fi

        echo "$port"
        return
    done
}

# ================================
# 下载 gost
# ================================
install_gost() {
    if [ -x "$GOST_BIN" ]; then
        return
    fi

    print_info "未检测到 gost，正在下载..."

    local ARCH FILE_SUFFIX API_JSON URL VERSION
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)       FILE_SUFFIX="linux_amd64.tar.gz" ;;
        aarch64)      FILE_SUFFIX="linux_arm64.tar.gz" ;;
        armv7l|armhf) FILE_SUFFIX="linux_armv7.tar.gz" ;;
        *) print_error "不支持的架构: $ARCH"; exit 1 ;;
    esac

    API_JSON=$(curl -sL https://api.github.com/repos/go-gost/gost/releases/latest)
    URL=$(echo "$API_JSON" | grep browser_download_url | cut -d '"' -f4 | grep "$FILE_SUFFIX" | head -n1)

    wget -O /tmp/gost.tar.gz "$URL"
    tar -xzf /tmp/gost.tar.gz -C /tmp
    install -m 755 /tmp/gost "$GOST_BIN"

    print_ok "gost 安装完成：$GOST_BIN"
}

# ================================
# 隧道编号
# ================================
next_id() {
    local n
    n=$(ls "$CONF_DIR"/client-*.env 2>/dev/null | wc -l)
    echo $((n + 1))
}

# ================================
# 列出隧道（含认证信息掩码）
# ================================
list_tunnels() {
    print_title "客户端隧道列表"

    echo -e "${CYAN}编号 | 本地端口 | 远程端口 | 域名 | 协议 | 路径 | 认证 | systemd${RESET}" >&2
    echo "-------------------------------------------------------------------------------------------" >&2

    for f in "$CONF_DIR"/client-*.env; do
        [[ -f "$f" ]] || continue

        num=$(basename "$f" .env | cut -d'-' -f2)
        # 读取配置
        source "$f"
        # LOCAL_PORT, REMOTE_PORT, DOMAIN, SCHEME, PORT, WS_PATH, AUTH_USER, AUTH_PASS（可能不存在旧配置）
        local_port="$LOCAL_PORT"
        remote_port="$REMOTE_PORT"
        domain="$DOMAIN"
        scheme="$SCHEME"
        ws_path="$WS_PATH"
        auth_show="${AUTH_USER:-none}:$(if [ -n "$AUTH_PASS" ]; then echo "${AUTH_PASS:0:2}******"; else echo "none"; fi)"

        svc="xgost-client-$(printf "%02d" "$num").service"

        echo -e "${GREEN}$num${RESET}) 本地: ${YELLOW}$local_port${RESET} | 远程: ${CYAN}$remote_port${RESET} | 域名: ${MAGENTA}$domain${RESET} | 协议: ${BLUE}$scheme${RESET} | 路径: ${WHITE}$ws_path${RESET} | 认证: ${GREEN}$auth_show${RESET} | $svc" >&2
    done

    echo "-------------------------------------------------------------------------------------------" >&2
    echo -e "${YELLOW}提示：完整认证信息请查看对应配置文件 ${CONF_DIR}/client-*.env${RESET}" >&2
}

# ================================
# 新增隧道（支持认证）
# ================================
add_tunnel() {
    install_gost
    print_title "新增客户端隧道"

    # 本地监听端口（隧道入口）
    echo -e "${YELLOW}本地监听端口 (LOCAL_PORT)${RESET}"
    echo -e "说明：你的程序连接这个端口，数据会进入 RTCP 隧道（隧道入口）" >&2
    echo -e "例如：你本地软件连接 127.0.0.1:LOCAL_PORT" >&2
    local_port=$(safe_read_port "$(random_free_port)")

    # RTCP 远程端口（服务端监听端口）
    echo -e "${YELLOW}RTCP 远程端口 (REMOTE_PORT)${RESET}"
    echo -e "说明：RTCP 在远端监听的端口（隧道出口），必须唯一，且与服务端预期一致" >&2
    remote_port=$(safe_read_port "$(random_free_port)")

    # Cloudflare 域名
    echo -e "${YELLOW}请输入 Cloudflare 域名${RESET}"
    echo -e "说明：隧道最终通过此域名的 80/443 端口转发" >&2
    echo -e "例如：xxx.cloudflare.com 或 xxx.workers.dev" >&2
    domain=$(safe_read "CF 域名" "")
    [ -z "$domain" ] && { print_error "域名不能为空"; return; }

    # 协议选择（ws / wss）
    echo -e "${YELLOW}请选择访问协议${RESET}"
    echo -e "1) http  → relay+ws://域名:80" >&2
    echo -e "2) https → relay+wss://域名:443（推荐）" >&2
    echo -e "说明：Cloudflare 仅允许 80 和 443 端口" >&2
    printf "选择 (默认 2): " >&2
    read proto_choice
    proto_choice=$(clean_input "$proto_choice")

    case "$proto_choice" in
        1) scheme="ws";  port=80 ;;
        2|"") scheme="wss"; port=443 ;;
        *) scheme="wss"; port=443 ;;
    esac

    # WebSocket 路径（必须与服务端一致）
    default_path="/$(cat /proc/sys/kernel/random/uuid | cut -d'-' -f1)"
    echo -e "${YELLOW}请输入 WebSocket 路径 (WS_PATH)${RESET}"
    echo -e "说明：必须与服务端一致，用于区分不同隧道" >&2
    ws_path=$(safe_read "WS 路径" "$default_path")

    # ========== 新增：认证信息 ==========
    echo -e "${YELLOW}请输入服务端的认证信息${RESET}"
    echo -e "说明：与服务端创建时设置的 auth 完全一致" >&2
    auth_user=$(safe_read "认证用户名" "")
    if [ -z "$auth_user" ]; then
        print_error "认证用户名不能为空"
        return
    fi
    read -s -p "请输入认证密码: " auth_pass
    echo
    if [ -z "$auth_pass" ]; then
        print_error "认证密码不能为空"
        return
    fi
    read -s -p "确认认证密码: " auth_pass2
    echo
    if [ "$auth_pass" != "$auth_pass2" ]; then
        print_error "两次输入的密码不一致"
        return
    fi

    # 保存配置
    id=$(next_id)
    id2=$(printf "%02d" "$id")
    conf="$CONF_DIR/client-$id2.env"
    svc="xgost-client-$id2.service"

    cat > "$conf" <<EOF
ID=$id
LOCAL_PORT=$local_port
REMOTE_PORT=$remote_port
DOMAIN=$domain
SCHEME=$scheme
PORT=$port
WS_PATH=$ws_path
AUTH_USER=$auth_user
AUTH_PASS=$auth_pass
EOF

    # 构建带认证的 URL
    cat > "$SYSTEMD_DIR/$svc" <<EOF
[Unit]
Description=XGost Client Tunnel $id (auth)
After=network.target

[Service]
Type=simple
ExecStart=$GOST_BIN -L "rtcp://:$remote_port/127.0.0.1:$local_port" -F "relay+${scheme}://${domain}:$port?path=$ws_path&host=$domain&auth=$auth_user:$auth_pass"
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$svc"

    print_ok "客户端隧道创建成功（已启用认证）"
    echo -e "${CYAN}编号:${RESET} $id"
    echo -e "${CYAN}本地端口:${RESET} $local_port"
    echo -e "${CYAN}RTCP 远程端口:${RESET} $remote_port"
    echo -e "${CYAN}CF 域名:${RESET} $domain"
    echo -e "${CYAN}协议:${RESET} $scheme"
    echo -e "${CYAN}路径:${RESET} $ws_path"
    echo -e "${CYAN}认证用户名:${RESET} $auth_user"
    echo -e "${CYAN}认证密码:${RESET} $auth_pass (请妥善保存)"
    echo -e "${CYAN}systemd:${RESET} $svc"
}

# ================================
# 查看状态
# ================================
status_tunnels() {
    print_title "客户端隧道状态"
    for f in "$CONF_DIR"/client-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        svc="xgost-client-$num.service"

        if systemctl is-active --quiet "$svc"; then
            st="${GREEN}运行中${RESET}"
        else
            st="${RED}未运行${RESET}"
        fi

        echo -e "隧道 ${CYAN}$num${RESET} -> $svc : $st" >&2
    done
}

# ================================
# 查看日志
# ================================
view_logs() {
    list_tunnels
    printf "请输入要查看日志的编号: " >&2
    read num
    num=$(clean_input "$num")
    id2=$(printf "%02d" "$num")
    svc="xgost-client-$id2.service"

    if [ ! -f "$SYSTEMD_DIR/$svc" ]; then
        print_error "服务不存在: $svc"
        return
    fi

    print_info "显示 $svc 最近 50 行日志"
    journalctl -u "$svc" -n 50 --no-pager
}

# ================================
# 删除隧道
# ================================
delete_tunnel() {
    list_tunnels
    printf "请输入要删除的编号: " >&2
    read num
    num=$(clean_input "$num")
    id2=$(printf "%02d" "$num")

    conf="$CONF_DIR/client-$id2.env"
    svc="xgost-client-$id2.service"

    if [ ! -f "$conf" ]; then
        print_error "配置不存在: $conf"
        return
    fi

    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "$conf"
    rm -f "$SYSTEMD_DIR/$svc"
    systemctl daemon-reload

    print_ok "已删除客户端隧道 $num"
}

# ================================
# 删除全部隧道
# ================================
delete_all() {
    print_title "删除所有客户端隧道"
    read -p "确认删除所有客户端隧道？(yes/no): " ans
    ans=$(clean_input "$ans")
    [ "$ans" != "yes" ] && { print_info "已取消"; return; }

    for f in "$CONF_DIR"/client-*.env; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .env | cut -d'-' -f2)
        svc="xgost-client-$num.service"
        systemctl disable --now "$svc" 2>/dev/null || true
        rm -f "$SYSTEMD_DIR/$svc"
        rm -f "$f"
    done

    systemctl daemon-reload
    print_ok "已删除所有客户端隧道"
}

# ================================
# 主菜单
# ================================
menu() {
    while true; do
        print_title "XGost 客户端隧道面板 (认证版)"
        echo "1) 查看隧道列表" >&2
        echo "2) 新增隧道" >&2
        echo "3) 查看隧道状态" >&2
        echo "4) 查看某个隧道日志" >&2
        echo "5) 删除某个隧道" >&2
        echo "6) 删除所有隧道" >&2
        echo "0) 退出" >&2

        printf "请选择: " >&2
        read c
        c=$(clean_input "$c")

        case "$c" in
            1) list_tunnels;   printf "按回车继续..." >&2; read ;;
            2) add_tunnel;     printf "按回车继续..." >&2; read ;;
            3) status_tunnels; printf "按回车继续..." >&2; read ;;
            4) view_logs;      printf "按回车继续..." >&2; read ;;
            5) delete_tunnel;  printf "按回车继续..." >&2; read ;;
            6) delete_all;     printf "按回车继续..." >&2; read ;;
            0) exit 0 ;;
            *) print_error "无效选项"; printf "按回车继续..." >&2; read ;;
        esac
    done
}

menu
