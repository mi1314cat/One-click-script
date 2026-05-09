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

# ---------- Base64 编码工具 ----------
base64_encode() {
    local input="$1"
    if command -v base64 >/dev/null 2>&1; then
        echo -n "$input" | base64 -w 0
    elif command -v openssl >/dev/null 2>&1; then
        echo -n "$input" | openssl base64 -A
    else
        print_error "系统中未找到 base64 或 openssl 命令，无法进行认证编码。"
        print_info "请安装 coreutils 或 openssl 后重试。"
        exit 1
    fi
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
# 列出隧道（增加 mux 列）
# ================================
list_tunnels() {
    print_title "客户端隧道列表"

    echo -e "${CYAN}编号 | 本地端口 | 远程端口 | 域名 | 协议 | 路径 | 认证 | MUX | systemd${RESET}" >&2
    echo "---------------------------------------------------------------------------------------------------" >&2

    for f in "$CONF_DIR"/client-*.env; do
        [[ -f "$f" ]] || continue

        num=$(basename "$f" .env | cut -d'-' -f2)
        source "$f"
        local_port="${LOCAL_PORT:-?}"
        remote_port="${REMOTE_PORT:-?}"
        domain="${DOMAIN:-?}"
        scheme="${SCHEME:-?}"
        ws_path="${WS_PATH:-?}"
        auth_user="${AUTH_USER:-none}"
        auth_pass="${AUTH_PASS:-}"
        masked_auth="${auth_user}:$(if [ -n "$auth_pass" ]; then echo "${auth_pass:0:2}******"; else echo "none"; fi)"
        mux="${MUX:-2}"    # [新增] 读取 mux，默认为 2

        svc="xgost-client-$(printf "%02d" "$num").service"

        echo -e "${GREEN}$num${RESET}) 本地: ${YELLOW}$local_port${RESET} | 远程: ${CYAN}$remote_port${RESET} | 域名: ${MAGENTA}$domain${RESET} | 协议: ${BLUE}$scheme${RESET} | 路径: ${WHITE}$ws_path${RESET} | 认证: ${GREEN}$masked_auth${RESET} | MUX: ${WHITE}$mux${RESET} | $svc" >&2
    done

    echo "---------------------------------------------------------------------------------------------------" >&2
    echo -e "${YELLOW}提示：完整认证信息请查看对应配置文件 ${CONF_DIR}/client-*.env${RESET}" >&2
}

# ================================
# 解析服务端链接（仅提取路径、认证、协议）
# ================================
parse_service_link() {
    local raw_link="$1"
    raw_link=$(echo "$raw_link" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^-F[[:space:]]*//' -e 's/^["'\'']//' -e 's/["'\'']$//')

    # 提取 scheme (ws 或 wss)
    if echo "$raw_link" | grep -q 'relay+wss://'; then
        scheme="wss"
        default_port=443
    elif echo "$raw_link" | grep -q 'relay+ws://'; then
        scheme="ws"
        default_port=80
    else
        return 1
    fi

    # 去掉协议前缀
    host_part=$(echo "$raw_link" | sed -E 's#^relay\+wss?://##')
    # 提取端口（如果有）
    port=$(echo "$host_part" | grep -oP ':\K[0-9]+(?=[/?]|$)' || echo "$default_port")

    # 提取参数：path 和 auth
    path=$(echo "$host_part" | grep -oP 'path=\K[^&]+' || echo "")
    auth=$(echo "$host_part" | grep -oP 'auth=\K[^&]+' || echo "")
    # 提取 host（备用）
    host_from_link=$(echo "$host_part" | grep -oP 'host=\K[^&]+' || echo "")

    if [ -z "$path" ] || [ -z "$auth" ]; then
        return 1
    fi

    auth_user=$(echo "$auth" | cut -d':' -f1)
    auth_pass=$(echo "$auth" | cut -d':' -f2-)
    if [ -z "$auth_user" ] || [ -z "$auth_pass" ]; then
        return 1
    fi

    # 导出解析结果（不包含域名，域名由用户输入）
    export SCHEME="$scheme"
    export PORT="$port"
    export WS_PATH="$path"
    export AUTH_USER="$auth_user"
    export AUTH_PASS="$auth_pass"
    return 0
}

# ================================
# 新增隧道（两种模式）+ 增加 mux 参数
# ================================
add_tunnel() {
    install_gost
    print_title "新增客户端隧道"

    echo -e "${YELLOW}请选择配置方式：${RESET}" >&2
    echo "1) 粘贴服务端提供的链接（自动提取路径/认证，域名需手动输入）" >&2
    echo "2) 手动逐步输入" >&2
    printf "请选择 (默认 1): " >&2
    read -r mode
    mode=$(clean_input "$mode")
    mode="${mode:-1}"

    local local_port remote_port domain scheme port ws_path auth_user auth_pass host_para mux_val

    # ---------- 本地监听端口 ----------
    echo -e "${YELLOW}本地监听端口 (LOCAL_PORT)${RESET}" >&2
    echo -e "说明：你的程序连接这个端口，数据会进入 RTCP 隧道（隧道入口）" >&2
    local_port=$(safe_read_port "$(random_free_port)")

    # ---------- RTCP 远程端口 ----------
    echo -e "${YELLOW}RTCP 远程端口 (REMOTE_PORT)${RESET}" >&2
    echo -e "说明：RTCP 在远端监听的端口（隧道出口），必须唯一，且与服务端预期一致" >&2
    remote_port=$(safe_read_port "$(random_free_port)")

    # ---------- 多路复用并发数 MUX ----------
    echo -e "${YELLOW}多路复用并发数 (MUX)${RESET}" >&2
    echo -e "说明：控制 gost 单个连接内的最大并发流数量，范围 1-8，默认 2（设为 1 表示禁用多路复用）" >&2
    default_mux=2
    while true; do
        read -r -p "请输入 MUX 值 (默认 $default_mux): " mux_input
        mux_input=$(clean_input "$mux_input")
        if [ -z "$mux_input" ]; then
            mux_val=$default_mux
            break
        fi
        if [[ "$mux_input" =~ ^[0-9]+$ ]]; then
            if [ "$mux_input" -lt 1 ]; then
                print_warn "输入值小于最小值 1，已自动调整为 1"
                mux_val=1
            elif [ "$mux_input" -gt 8 ]; then
                print_warn "输入值大于最大值 8，已自动调整为 8"
                mux_val=8
            else
                mux_val=$mux_input
            fi
            break
        else
            print_error "请输入一个数字"
        fi
    done

    # ---------- 配置模式 ----------
    if [ "$mode" = "1" ]; then
        # 模式1：粘贴链接，提取参数
        echo -e "${YELLOW}请粘贴完整的服务端转发链接${RESET}" >&2
        echo -e "格式示例: relay+wss://your.domain:443?path=/xxx&auth=user:pass&host=your.domain" >&2
        read -r -p "链接: " raw_link
        raw_link=$(clean_input "$raw_link")
        if parse_service_link "$raw_link"; then
            scheme="$SCHEME"
            port="$PORT"
            ws_path="$WS_PATH"
            auth_user="$AUTH_USER"
            auth_pass="$AUTH_PASS"
            print_ok "成功解析链接参数："
            echo -e "  协议: $scheme, 端口: $port" >&2
            echo -e "  路径: $ws_path" >&2
            echo -e "  认证: $auth_user:******" >&2
            echo "" >&2
        else
            print_error "链接格式无法识别，请检查后重试，或选择手动输入模式"
            return 1
        fi

        # 域名必须由用户输入（即使链接中有域名，也以此为准）
        while true; do
            read -r -p "请输入您自己的 Cloudflare 域名（必填）: " domain
            domain=$(clean_input "$domain")
            if [ -n "$domain" ]; then
                break
            else
                print_error "域名不能为空，请重新输入"
            fi
        done
        host_para="$domain"
    else
        # 模式2：手动逐步输入
        echo -e "${YELLOW}请输入 Cloudflare 域名${RESET}" >&2
        echo -e "说明：隧道最终通过此域名的 80/443 端口转发" >&2
        domain=$(safe_read "CF 域名" "")
        [ -z "$domain" ] && { print_error "域名不能为空"; return 1; }

        echo -e "${YELLOW}请选择访问协议${RESET}" >&2
        echo "1) http  → relay+ws://域名:80" >&2
        echo "2) https → relay+wss://域名:443（推荐）" >&2
        read -r -p "选择 (默认 2): " proto_choice
        proto_choice=$(clean_input "$proto_choice")
        case "$proto_choice" in
            1) scheme="ws";  port=80 ;;
            2|"") scheme="wss"; port=443 ;;
            *) scheme="wss"; port=443 ;;
        esac

        default_path="/$(cat /proc/sys/kernel/random/uuid | cut -d'-' -f1)"
        ws_path=$(safe_read "WS 路径" "$default_path")

        echo -e "${YELLOW}请输入服务端的认证信息${RESET}" >&2
        auth_user=$(safe_read "认证用户名" "")
        [ -z "$auth_user" ] && { print_error "认证用户名不能为空"; return 1; }
        read -r -s -p "请输入认证密码: " auth_pass
        echo
        read -r -s -p "确认认证密码: " auth_pass2
        echo
        if [ -z "$auth_pass" ] || [ "$auth_pass" != "$auth_pass2" ]; then
            print_error "密码为空或不匹配"
            return 1
        fi
        host_para="$domain"
    fi

    # ---------- 持久化配置 ----------
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
MUX=$mux_val
EOF

    # 认证信息 base64 编码
    AUTH_BASE64=$(base64_encode "$auth_user:$auth_pass")

    # 构建可选的 -mux 参数（mux=1 时不需要）
    if [ "$mux_val" -ne 1 ]; then
        mux_param="-mux $mux_val"
    else
        mux_param=""
    fi

    # ---------- 生成 systemd 服务 ----------
    cat > "$SYSTEMD_DIR/$svc" <<EOF
[Unit]
Description=XGost Client Tunnel $id (auth)
After=network.target

[Service]
Type=simple
ExecStart=$GOST_BIN -L "rtcp://:$remote_port/127.0.0.1:$local_port" -F "relay+${scheme}://${domain}:$port?path=$ws_path&host=$host_para&auth=$AUTH_BASE64" $mux_param
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
    echo -e "${CYAN}MUX 并发数:${RESET} $mux_val"
    if [ "$mux_val" -eq 1 ]; then
        echo -e "${CYAN}注意:${RESET} 多路复用已禁用（MUX=1）"
    fi
    echo -e "${CYAN}systemd:${RESET} $svc"
}

# ================================
# 状态、停止、启动、重启、日志、删除（与之前一致）
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

stop_tunnel() {
    list_tunnels
    printf "请输入要停止的隧道编号: " >&2
    read num
    num=$(clean_input "$num")
    id2=$(printf "%02d" "$num")
    svc="xgost-client-$id2.service"
    [ ! -f "$SYSTEMD_DIR/$svc" ] && { print_error "服务不存在: $svc"; return; }
    systemctl stop "$svc"
    print_ok "已停止 $svc"
    systemctl status "$svc" --no-pager -l | head -n 5 >&2
}

start_tunnel() {
    list_tunnels
    printf "请输入要启动的隧道编号: " >&2
    read num
    num=$(clean_input "$num")
    id2=$(printf "%02d" "$num")
    svc="xgost-client-$id2.service"
    [ ! -f "$SYSTEMD_DIR/$svc" ] && { print_error "服务不存在: $svc"; return; }
    systemctl start "$svc"
    print_ok "已启动 $svc"
    systemctl status "$svc" --no-pager -l | head -n 5 >&2
}

restart_tunnel() {
    list_tunnels
    printf "请输入要重启的隧道编号: " >&2
    read num
    num=$(clean_input "$num")
    id2=$(printf "%02d" "$num")
    svc="xgost-client-$id2.service"
    [ ! -f "$SYSTEMD_DIR/$svc" ] && { print_error "服务不存在: $svc"; return; }
    systemctl restart "$svc"
    print_ok "已重启 $svc"
    systemctl status "$svc" --no-pager -l | head -n 5 >&2
}

view_logs() {
    list_tunnels
    printf "请输入要查看日志的编号: " >&2
    read num
    num=$(clean_input "$num")
    id2=$(printf "%02d" "$num")
    svc="xgost-client-$id2.service"
    [ ! -f "$SYSTEMD_DIR/$svc" ] && { print_error "服务不存在: $svc"; return; }
    print_info "显示 $svc 最近 50 行日志"
    journalctl -u "$svc" -n 50 --no-pager
}

delete_tunnel() {
    list_tunnels
    printf "请输入要删除的编号: " >&2
    read num
    num=$(clean_input "$num")
    id2=$(printf "%02d" "$num")
    conf="$CONF_DIR/client-$id2.env"
    svc="xgost-client-$id2.service"
    [ ! -f "$conf" ] && { print_error "配置不存在: $conf"; return; }
    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "$conf" "$SYSTEMD_DIR/$svc"
    systemctl daemon-reload
    print_ok "已删除客户端隧道 $num"
}

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
        rm -f "$SYSTEMD_DIR/$svc" "$f"
    done
    systemctl daemon-reload
    print_ok "已删除所有客户端隧道"
}

# ================================
# 主菜单
# ================================
menu() {
    while true; do
        print_title "XGost 客户端隧道面板 (认证版 + MUX)"
        echo "1) 查看隧道列表" >&2
        echo "2) 新增隧道" >&2
        echo "3) 查看隧道状态" >&2
        echo "4) 查看某个隧道日志" >&2
        echo "5) 停止某个隧道" >&2
        echo "6) 启动某个隧道" >&2
        echo "7) 重启某个隧道" >&2
        echo "8) 删除某个隧道" >&2
        echo "9) 删除所有隧道" >&2
        echo "0) 退出" >&2

        printf "请选择: " >&2
        read c
        c=$(clean_input "$c")

        case "$c" in
            1) list_tunnels;    printf "按回车继续..." >&2; read ;;
            2) add_tunnel;      printf "按回车继续..." >&2; read ;;
            3) status_tunnels;  printf "按回车继续..." >&2; read ;;
            4) view_logs;       printf "按回车继续..." >&2; read ;;
            5) stop_tunnel;     printf "按回车继续..." >&2; read ;;
            6) start_tunnel;    printf "按回车继续..." >&2; read ;;
            7) restart_tunnel;  printf "按回车继续..." >&2; read ;;
            8) delete_tunnel;   printf "按回车继续..." >&2; read ;;
            9) delete_all;      printf "按回车继续..." >&2; read ;;
            0) exit 0 ;;
            *) print_error "无效选项"; printf "按回车继续..." >&2; read ;;
        esac
    done
}

menu
