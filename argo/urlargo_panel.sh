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
# 基础路径（完全隔离）
# ================================
BASE_DIR="/root/catmi/argo"
BIN="$BASE_DIR/cloudflared"
export HOME="$BASE_DIR"
CF_DIR="$BASE_DIR/.cloudflared"
TUNNELS_DIR="$BASE_DIR/tunnels"
SYSTEMD_DIR="/etc/systemd/system"
HEALTH_SCRIPT="$BASE_DIR/argo_health.sh"

mkdir -p "$TUNNELS_DIR" "$CF_DIR"

# ================================
# 工具函数
# ================================
clean_input() {
    echo "$1" | tr -d '\000-\037'
}

safe_read() {
    local prompt="$1" default="$2" input
    printf "%s (默认: %s): " "$prompt" "$default" >&2
    read input
    input=$(clean_input "$input")
    echo "${input:-$default}"
}

install_cloudflared() {
    if [[ -x "$BIN" ]] && "$BIN" --version >/dev/null 2>&1; then
        return
    fi
    print_info "未检测到 cloudflared，正在下载最新版..."
    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)     CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        aarch64)    CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
        armv7l|armhf) CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
        *) print_error "不支持的架构: $ARCH"; exit 1 ;;
    esac
    wget -qO "$BIN" "$CFD_URL" || { print_error "cloudflared 下载失败"; exit 1; }
    chmod +x "$BIN"
    print_ok "cloudflared 安装完成：$BIN"
}

next_id() {
    local n
    n=$(ls -d "$TUNNELS_DIR"/*/ 2>/dev/null | wc -l)
    echo $((n + 1))
}

list_tunnels() {
    print_title "Argo 隧道列表"
    echo -e "${CYAN}编号 | 域名 | 本地端口 | Tunnel ID | systemd 服务${RESET}" >&2
    echo "----------------------------------------------------------------------------" >&2
    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local num=$(basename "$dir")
        local env_file="$dir/tunnel.env"
        if [[ -f "$env_file" ]]; then
            source "$env_file"
            local domain="${DOMAIN}"
            local port="${LOCAL_PORT}"
            local tid="${TID}"
            local svc="argo-tunnel-${num}.service"
            echo -e "${GREEN}$num${RESET}) 域名: ${MAGENTA}$domain${RESET} | 本地端口: ${YELLOW}$port${RESET} | TID: ${CYAN}$tid${RESET} | 服务: ${BLUE}$svc${RESET}" >&2
        fi
    done
    echo "----------------------------------------------------------------------------" >&2
}

get_existing_root_domains() {
    local domains=()
    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local env="$dir/tunnel.env"
        if [[ -f "$env" ]]; then
            source "$env"
            if [[ -n "$ROOT_DOMAIN" ]]; then
                domains+=("$ROOT_DOMAIN")
            fi
        fi
    done
    printf "%s\n" "${domains[@]}" | sort -u
}

add_tunnel() {
    install_cloudflared
    print_title "新增 Argo 文件隧道"

    if [[ ! -f "$CF_DIR/cert.pem" ]]; then
        print_info "未检测到 cert.pem，执行 cloudflared login（将打开浏览器，请在本地操作后继续）"
        $BIN login || { print_error "login 失败"; return 1; }
    fi

    local existing_root_domains
    existing_root_domains=$(get_existing_root_domains)
    local root_domain

    if [[ -z "$existing_root_domains" ]]; then
        printf "请输入根域名（例如 example.com）: "
        read root_domain
        root_domain=$(clean_input "$root_domain")
        [[ -z "$root_domain" ]] && { print_error "域名不能为空"; return 1; }
    else
        echo -e "${CYAN}检测到已使用的根域名：${RESET}" >&2
        mapfile -t DOMAINS_ARR <<< "$existing_root_domains"
        local i=1
        for domain in "${DOMAINS_ARR[@]}"; do
            echo "  $i) $domain" >&2
            ((i++))
        done
        echo "  $i) 输入新的根域名" >&2
        printf "请选择根域名 (默认 1): " >&2
        read choice
        choice=$(clean_input "${choice:-1}")
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#DOMAINS_ARR[@]} )); then
            root_domain="${DOMAINS_ARR[$((choice-1))]}"
        elif [[ "$choice" -eq $i ]]; then
            printf "请输入新的根域名: "
            read root_domain
            root_domain=$(clean_input "$root_domain")
            [[ -z "$root_domain" ]] && { print_error "域名不能为空"; return 1; }
        else
            print_error "无效选择"
            return 1
        fi
    fi

    local TUNNEL_NAME
    TUNNEL_NAME="$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)"
    print_info "创建 Cloudflare 隧道：$TUNNEL_NAME"
    $BIN tunnel create "$TUNNEL_NAME" >/dev/null 2>&1 || { print_error "创建隧道失败"; return 1; }

    local TID
    TID=$(ls -t "$CF_DIR"/*.json 2>/dev/null | head -n 1 | xargs -I {} basename {} .json)
    [[ -z "$TID" ]] && { print_error "获取 Tunnel ID 失败"; return 1; }
    print_ok "Tunnel ID: $TID"

    local default_port="8888"
    local local_port
    printf "请输入本地服务端口（默认 %s）: " "$default_port"
    read local_port
    local_port=$(clean_input "${local_port:-$default_port}")
    if ! [[ "$local_port" =~ ^[0-9]+$ ]] || (( local_port < 1 || local_port > 65535 )); then
        print_error "端口无效"; return 1
    fi

    local domain="${TUNNEL_NAME}.${root_domain}"

    local id=$(next_id)
    local id2=$(printf "%02d" "$id")
    local tunnel_dir="$TUNNELS_DIR/$id2"
    mkdir -p "$tunnel_dir"

    cat > "$tunnel_dir/tunnel.env" <<EOF
ID=$id
TUNNEL_NAME=$TUNNEL_NAME
DOMAIN=$domain
LOCAL_PORT=$local_port
TID=$TID
ROOT_DOMAIN=$root_domain
EOF

    cat > "$tunnel_dir/config.yml" <<EOF
tunnel: $TID
credentials-file: $CF_DIR/$TID.json

ingress:
  - hostname: $domain
    service: http://localhost:$local_port
  - service: http_status:404
EOF

    local svc="argo-tunnel-$id2.service"
    local log_file="$tunnel_dir/argo.log"
    cat > "$SYSTEMD_DIR/$svc" <<EOF
[Unit]
Description=Argo Tunnel $id2 ($domain)
After=network.target

[Service]
WorkingDirectory=$tunnel_dir
ExecStart=$BIN tunnel --config $tunnel_dir/config.yml run
Restart=always
RestartSec=5
StandardOutput=append:$log_file
StandardError=append:$log_file

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$svc"

    print_ok "Argo 隧道创建成功"
    echo -e "编号: ${GREEN}$id2${RESET}"
    echo -e "域名: ${MAGENTA}$domain${RESET}"
    echo -e "本地端口: ${YELLOW}$local_port${RESET}"
    echo -e "Tunnel ID: ${CYAN}$TID${RESET}"
    echo -e "Systemd 服务: ${BLUE}$svc${RESET}"
    echo ""
    print_info "DNS 记录设置：请前往 Cloudflare DNS 添加 CNAME 记录："
    echo -e "  ${CYAN}$domain${RESET}  CNAME  ${CYAN}$TID.cfargotunnel.com${RESET}"
}

status_tunnels() {
    print_title "Argo 隧道运行状态"
    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local num=$(basename "$dir")
        local svc="argo-tunnel-${num}.service"
        if systemctl is-active --quiet "$svc"; then
            echo -e "隧道 ${CYAN}$num${RESET} -> $svc : ${GREEN}运行中${RESET}" >&2
        else
            echo -e "隧道 ${CYAN}$num${RESET} -> $svc : ${RED}未运行${RESET}" >&2
        fi
    done
}

view_logs() {
    list_tunnels
    printf "请输入要查看日志的隧道编号: " >&2
    read num
    num=$(clean_input "$num")
    local tunnel_dir="$TUNNELS_DIR/$num"
    if [[ ! -d "$tunnel_dir" ]]; then
        print_error "隧道不存在: $num"
        return
    fi
    local log_file="$tunnel_dir/argo.log"
    if [[ -f "$log_file" ]]; then
        print_info "显示 argo-tunnel-${num}.service 最近 50 行日志"
        tail -n 50 "$log_file"
    else
        print_error "日志文件不存在"
    fi
}

stop_tunnel() {
    list_tunnels
    printf "请输入要停止的隧道编号: " >&2
    read num
    num=$(clean_input "$num")
    local svc="argo-tunnel-${num}.service"
    if ! systemctl list-unit-files | grep -q "$svc"; then
        print_error "服务不存在: $svc"
        return
    fi
    systemctl stop "$svc"
    print_ok "已停止 $svc"
    systemctl status "$svc" --no-pager -l | head -n 5 >&2
}

start_tunnel() {
    list_tunnels
    printf "请输入要启动的隧道编号: " >&2
    read num
    num=$(clean_input "$num")
    local svc="argo-tunnel-${num}.service"
    if ! systemctl list-unit-files | grep -q "$svc"; then
        print_error "服务不存在: $svc"
        return
    fi
    systemctl start "$svc"
    print_ok "已启动 $svc"
    systemctl status "$svc" --no-pager -l | head -n 5 >&2
}

restart_tunnel() {
    list_tunnels
    printf "请输入要重启的隧道编号: " >&2
    read num
    num=$(clean_input "$num")
    local svc="argo-tunnel-${num}.service"
    if ! systemctl list-unit-files | grep -q "$svc"; then
        print_error "服务不存在: $svc"
        return
    fi
    systemctl restart "$svc"
    print_ok "已重启 $svc"
    systemctl status "$svc" --no-pager -l | head -n 5 >&2
}

delete_tunnel() {
    list_tunnels
    printf "请输入要删除的隧道编号: " >&2
    read num
    num=$(clean_input "$num")
    local tunnel_dir="$TUNNELS_DIR/$num"
    local svc="argo-tunnel-${num}.service"
    if [[ ! -d "$tunnel_dir" ]]; then
        print_error "隧道不存在: $num"
        return
    fi
    if [[ -f "$tunnel_dir/tunnel.env" ]]; then
        source "$tunnel_dir/tunnel.env"
        [[ -n "$TID" && -f "$CF_DIR/$TID.json" ]] && rm -f "$CF_DIR/$TID.json"
    fi
    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/$svc"
    rm -rf "$tunnel_dir"
    systemctl daemon-reload
    print_ok "已删除隧道 $num"
}

delete_all_tunnels() {
    print_title "删除所有 Argo 隧道"
    read -p "确认删除所有隧道？(yes/no): " ans
    ans=$(clean_input "$ans")
    [[ "$ans" != "yes" ]] && { print_info "已取消"; return; }
    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local num=$(basename "$dir")
        local svc="argo-tunnel-${num}.service"
        if [[ -f "$dir/tunnel.env" ]]; then
            source "$dir/tunnel.env"
            [[ -n "$TID" && -f "$CF_DIR/$TID.json" ]] && rm -f "$CF_DIR/$TID.json"
        fi
        systemctl disable --now "$svc" 2>/dev/null || true
        rm -f "$SYSTEMD_DIR/$svc"
        rm -rf "$dir"
    done
    systemctl daemon-reload
    print_ok "已删除所有隧道"
}

heal_check() {
    print_info "正在检查所有隧道健康状态..."
    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local num=$(basename "$dir")
        source "$dir/tunnel.env"
        local svc="argo-tunnel-${num}.service"
        local http_code
        http_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "https://$DOMAIN" || echo "000")
        if [[ "$http_code" =~ ^(200|301|302)$ ]]; then
            echo -e "隧道 $num (${DOMAIN}) : ${GREEN}正常${RESET}"
        else
            echo -e "隧道 $num (${DOMAIN}) : ${RED}异常 (HTTP $http_code)${RESET}，尝试重启..."
            systemctl restart "$svc"
        fi
    done
}

install_heal_timer() {
    cat > "$HEALTH_SCRIPT" <<'HEAL_EOF'
#!/usr/bin/env bash
BASE_DIR="/root/catmi/argo"
TUNNELS_DIR="$BASE_DIR/tunnels"
for dir in "$TUNNELS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    num=$(basename "$dir")
    source "$dir/tunnel.env"
    svc="argo-tunnel-${num}.service"
    http_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "https://$DOMAIN" || echo "000")
    if [[ ! "$http_code" =~ ^(200|301|302)$ ]]; then
        systemctl restart "$svc"
    fi
done
HEAL_EOF
    chmod +x "$HEALTH_SCRIPT"

    cat > /etc/systemd/system/argo-health.service <<EOF
[Unit]
Description=Argo Tunnel Health Check (One-shot)

[Service]
Type=oneshot
ExecStart=/bin/bash $HEALTH_SCRIPT
EOF

    cat > /etc/systemd/system/argo-health.timer <<EOF
[Unit]
Description=Every 5 minutes Argo health check

[Timer]
OnBootSec=30
OnUnitActiveSec=300

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable argo-health.timer --now 2>/dev/null || true
    print_ok "定时健康检查已安装（每5分钟）"
}

# ================================
# 一键彻底删除（脚本 + 所有关联文件）
# ================================
purge_everything() {
    print_title "⚠ 彻底删除脚本及所有 Argo 相关文件 ⚠"
    echo -e "${RED}这是不可逆操作！将执行：${RESET}"
    echo "  - 停止并删除所有 Argo 隧道"
    echo "  - 删除 cloudflared 二进制与凭证"
    echo "  - 删除所有配置文件、日志、健康检查服务"
    echo "  - 删除此脚本自身"
    echo ""
    read -p "确认彻底删除？请输入 yes 继续: " ans
    ans=$(clean_input "$ans")
    if [[ "$ans" != "yes" ]]; then
        print_info "已取消"
        return
    fi

    # 1. 删除所有隧道（使用内部逻辑，避免递归确认）
    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local num=$(basename "$dir")
        local svc="argo-tunnel-${num}.service"
        if [[ -f "$dir/tunnel.env" ]]; then
            source "$dir/tunnel.env"
            [[ -n "$TID" && -f "$CF_DIR/$TID.json" ]] && rm -f "$CF_DIR/$TID.json"
        fi
        systemctl disable --now "$svc" 2>/dev/null || true
        rm -f "$SYSTEMD_DIR/$svc"
        rm -rf "$dir"
    done

    # 2. 删除健康检查服务与定时器
    systemctl disable --now argo-health.timer 2>/dev/null || true
    systemctl disable --now argo-health.service 2>/dev/null || true
    rm -f /etc/systemd/system/argo-health.service
    rm -f /etc/systemd/system/argo-health.timer

    # 3. 删除整个 BASE_DIR（包含 cloudflared、所有凭证、配置）
    print_info "删除工作目录 $BASE_DIR ..."
    rm -rf "$BASE_DIR"

    systemctl daemon-reload

   

    echo -e "${GREEN}彻底清理完成！所有文件已删除。脚本即将退出。${RESET}"
    exit 0
}

# ================================
# 主菜单
# ================================
menu() {
    install_heal_timer

    while true; do
        print_title "Argo 文件隧道管理面板（多隧道版）"
        echo "1) 查看隧道列表" >&2
        echo "2) 新增隧道" >&2
        echo "3) 查看隧道运行状态" >&2
        echo "4) 查看某个隧道日志" >&2
        echo "5) 停止某个隧道" >&2
        echo "6) 启动某个隧道" >&2
        echo "7) 重启某个隧道" >&2
        echo "8) 删除某个隧道" >&2
        echo "9) 删除所有隧道" >&2
        echo "10) 手动健康检查" >&2
        echo "11) 彻底删除脚本及所有文件" >&2
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
            9) delete_all_tunnels; printf "按回车继续..." >&2; read ;;
            10) heal_check;     printf "按回车继续..." >&2; read ;;
            11) purge_everything; ;;   # 该函数内部会 exit，不再返回菜单
            0) exit 0 ;;
            *) print_error "无效选项"; printf "按回车继续..." >&2; read ;;
        esac
    done
}

menu
