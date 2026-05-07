#!/usr/bin/env bash
set -e

# ================================
# 彩色定义（与 gost/argo 脚本统一）
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
# 基础路径（完全隔离，不影响 argo 文件模式）
# ================================
BASE_DIR="/root/catmi/argo_token"
BIN="$BASE_DIR/cloudflared"
TUNNELS_DIR="$BASE_DIR/tunnels"
SYSTEMD_DIR="/etc/systemd/system"
HEALTH_SCRIPT="$BASE_DIR/token_health.sh"

mkdir -p "$TUNNELS_DIR"

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

# ================================
# 列出所有 Token 隧道
# ================================
list_tunnels() {
    print_title "Token 模式隧道列表"
    echo -e "${CYAN}编号 | 备注名称 | Token (前20字符) | systemd 服务${RESET}" >&2
    echo "----------------------------------------------------------------------------" >&2
    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local num=$(basename "$dir")
        local env_file="$dir/token.env"
        if [[ -f "$env_file" ]]; then
            source "$env_file"
            local note="${NOTE:-无}"
            local token_prefix="${TOKEN:0:20}..."
            local svc="argo-token-${num}.service"
            echo -e "${GREEN}$num${RESET}) 备注: ${YELLOW}$note${RESET} | Token: ${MAGENTA}$token_prefix${RESET} | 服务: ${BLUE}$svc${RESET}" >&2
        fi
    done
    echo "----------------------------------------------------------------------------" >&2
}

# ================================
# 新增 Token 隧道
# ================================
add_tunnel() {
    install_cloudflared
    print_title "新增 Token 模式隧道"

    echo -e "${YELLOW}如何获取 Cloudflare Argo Token：${RESET}" >&2
    echo "1. 登录 Cloudflare Dashboard" >&2
    echo "2. 进入 Zero Trust 面板： https://one.dash.cloudflare.com/" >&2
    echo "3. 左侧菜单：Access → Tunnels" >&2
    echo "4. 找到你创建的隧道 → 右侧复制 Token" >&2
    echo "5. Token 格式类似：eyJhIjoiY2YtYWNjb3VudC0xMjMiLCJ0IjoiYWJjZGVmZ2hpamtsbW5vcHFyIn0..." >&2
    echo ""

    # 输入 Token
    printf "请输入 Cloudflare Argo Token (必填): " >&2
    read TOKEN
    TOKEN=$(clean_input "$TOKEN")
    if [[ -z "$TOKEN" ]]; then
        print_error "Token 不能为空"
        return 1
    fi

    # 输入备注（可选）
    printf "请输入隧道备注（方便识别，例如：Web 服务, SSH 等）: " >&2
    read NOTE
    NOTE=$(clean_input "$NOTE")
    NOTE="${NOTE:-未备注}"

    # 隧道编号
    local id=$(next_id)
    local id2=$(printf "%02d" "$id")
    local tunnel_dir="$TUNNELS_DIR/$id2"
    mkdir -p "$tunnel_dir"

    # 保存配置
    cat > "$tunnel_dir/token.env" <<EOF
ID=$id
TOKEN=$TOKEN
NOTE=$NOTE
EOF

    # 创建 systemd 服务
    local svc="argo-token-$id2.service"
    local log_file="$tunnel_dir/argo.log"
    cat > "$SYSTEMD_DIR/$svc" <<EOF
[Unit]
Description=Argo Token Tunnel $id2 ($NOTE)
After=network.target

[Service]
WorkingDirectory=$tunnel_dir
ExecStart=$BIN tunnel run --token $TOKEN
Restart=always
RestartSec=3
KillMode=process
StandardOutput=append:$log_file
StandardError=append:$log_file

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$svc"

    print_ok "Token 隧道创建成功"
    echo -e "编号: ${GREEN}$id2${RESET}"
    echo -e "备注: ${YELLOW}$NOTE${RESET}"
    echo -e "Token (已隐藏): ${MAGENTA}${TOKEN:0:20}...${RESET}"
    echo -e "Systemd 服务: ${BLUE}$svc${RESET}"
    echo ""
    print_info "此隧道对应的 Cloudflare 面板配置需自行设置 ingress 规则"
}

# ================================
# 查看状态
# ================================
status_tunnels() {
    print_title "Token 隧道运行状态"
    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local num=$(basename "$dir")
        local svc="argo-token-${num}.service"
        if systemctl is-active --quiet "$svc"; then
            echo -e "隧道 ${CYAN}$num${RESET} -> $svc : ${GREEN}运行中${RESET}" >&2
        else
            echo -e "隧道 ${CYAN}$num${RESET} -> $svc : ${RED}未运行${RESET}" >&2
        fi
    done
}

# ================================
# 查看日志
# ================================
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
        print_info "显示 argo-token-${num}.service 最近 50 行日志"
        tail -n 50 "$log_file"
    else
        print_error "日志文件不存在"
    fi
}

# ================================
# 停止、启动、重启
# ================================
stop_tunnel() {
    list_tunnels
    printf "请输入要停止的隧道编号: " >&2
    read num
    num=$(clean_input "$num")
    local svc="argo-token-${num}.service"
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
    local svc="argo-token-${num}.service"
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
    local svc="argo-token-${num}.service"
    if ! systemctl list-unit-files | grep -q "$svc"; then
        print_error "服务不存在: $svc"
        return
    fi
    systemctl restart "$svc"
    print_ok "已重启 $svc"
    systemctl status "$svc" --no-pager -l | head -n 5 >&2
}

# ================================
# 删除隧道
# ================================
delete_tunnel() {
    list_tunnels
    printf "请输入要删除的隧道编号: " >&2
    read num
    num=$(clean_input "$num")
    local tunnel_dir="$TUNNELS_DIR/$num"
    local svc="argo-token-${num}.service"
    if [[ ! -d "$tunnel_dir" ]]; then
        print_error "隧道不存在: $num"
        return
    fi
    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/$svc"
    rm -rf "$tunnel_dir"
    systemctl daemon-reload
    print_ok "已删除 Token 隧道 $num"
}

delete_all_tunnels() {
    print_title "删除所有 Token 隧道"
    read -p "确认删除所有 Token 隧道？(yes/no): " ans
    ans=$(clean_input "$ans")
    [[ "$ans" != "yes" ]] && { print_info "已取消"; return; }
    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local num=$(basename "$dir")
        local svc="argo-token-${num}.service"
        systemctl disable --now "$svc" 2>/dev/null || true
        rm -f "$SYSTEMD_DIR/$svc"
        rm -rf "$dir"
    done
    systemctl daemon-reload
    print_ok "已删除所有 Token 隧道"
}

# ================================
# 健康检查（检测所有隧道服务是否 active，否则重启）
# ================================
heal_check() {
    print_info "正在检查所有 Token 隧道健康状态..."
    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local num=$(basename "$dir")
        local svc="argo-token-${num}.service"
        if systemctl is-active --quiet "$svc"; then
            echo -e "隧道 $num ($svc) : ${GREEN}正常${RESET}"
        else
            echo -e "隧道 $num ($svc) : ${RED}未运行${RESET}，尝试重启..."
            systemctl restart "$svc"
        fi
    done
}

# ================================
# 定时健康检查安装
# ================================
install_heal_timer() {
    cat > "$HEALTH_SCRIPT" <<'HEAL_EOF'
#!/usr/bin/env bash
BASE_DIR="/root/catmi/argo_token"
TUNNELS_DIR="$BASE_DIR/tunnels"
for dir in "$TUNNELS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    num=$(basename "$dir")
    svc="argo-token-${num}.service"
    if ! systemctl is-active --quiet "$svc"; then
        systemctl restart "$svc"
    fi
done
HEAL_EOF
    chmod +x "$HEALTH_SCRIPT"

    cat > /etc/systemd/system/argo-token-health.service <<EOF
[Unit]
Description=Token Tunnel Health One-shot

[Service]
Type=oneshot
ExecStart=/bin/bash $HEALTH_SCRIPT
EOF

    cat > /etc/systemd/system/argo-token-health.timer <<EOF
[Unit]
Description=Every 5 minutes check token tunnels

[Timer]
OnBootSec=30
OnUnitActiveSec=300

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable argo-token-health.timer --now 2>/dev/null || true
    print_ok "Token 健康检查定时器已安装（每5分钟）"
}

# ================================
# 一键彻底删除（脚本 + 所有关联文件）
# ================================
purge_everything() {
    print_title "⚠ 彻底删除 Token 脚本及所有文件 ⚠"
    echo -e "${RED}将执行：${RESET}"
    echo "  - 删除所有 Token 隧道（含 systemd 服务）"
    echo "  - 删除健康检查定时器"
    echo "  - 删除 cloudflared 二进制"
    echo "  - 删除整个工作目录 $BASE_DIR"
    echo "  - 删除此脚本自身"
    echo ""
    read -p "确认彻底删除？请输入 yes 继续: " ans
    ans=$(clean_input "$ans")
    if [[ "$ans" != "yes" ]]; then
        print_info "已取消"
        return
    fi

    # 删除所有隧道
    for dir in "$TUNNELS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local num=$(basename "$dir")
        local svc="argo-token-${num}.service"
        systemctl disable --now "$svc" 2>/dev/null || true
        rm -f "$SYSTEMD_DIR/$svc"
        rm -rf "$dir"
    done

    # 删除健康检查
    systemctl disable --now argo-token-health.timer 2>/dev/null || true
    systemctl disable --now argo-token-health.service 2>/dev/null || true
    rm -f /etc/systemd/system/argo-token-health.service
    rm -f /etc/systemd/system/argo-token-health.timer

    # 删除工作目录
    print_info "删除工作目录 $BASE_DIR ..."
    rm -rf "$BASE_DIR"

    systemctl daemon-reload

    # 删除脚本自身
    SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
    print_info "删除脚本 $SCRIPT_PATH ..."
    rm -f "$SCRIPT_PATH"

    echo -e "${GREEN}彻底清理完成！所有文件已删除。脚本即将退出。${RESET}"
    exit 0
}

# ================================
# 主菜单
# ================================
menu() {
    # 安装健康检查（首次运行自动配置）
    install_heal_timer

    while true; do
        print_title "Argo Token 隧道管理面板（多隧道版）"
        echo "1) 查看隧道列表" >&2
        echo "2) 新增 Token 隧道" >&2
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
            1) list_tunnels;      printf "按回车继续..." >&2; read ;;
            2) add_tunnel;        printf "按回车继续..." >&2; read ;;
            3) status_tunnels;    printf "按回车继续..." >&2; read ;;
            4) view_logs;         printf "按回车继续..." >&2; read ;;
            5) stop_tunnel;       printf "按回车继续..." >&2; read ;;
            6) start_tunnel;      printf "按回车继续..." >&2; read ;;
            7) restart_tunnel;    printf "按回车继续..." >&2; read ;;
            8) delete_tunnel;     printf "按回车继续..." >&2; read ;;
            9) delete_all_tunnels; printf "按回车继续..." >&2; read ;;
            10) heal_check;       printf "按回车继续..." >&2; read ;;
            11) purge_everything; ;;   # 函数内退出
            0) exit 0 ;;
            *) print_error "无效选项"; printf "按回车继续..." >&2; read ;;
        esac
    done
}

menu
