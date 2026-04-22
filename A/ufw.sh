#!/usr/bin/env bash
# UFW 防火墙管理面板 v7.1（旗舰版）
# - UI 美化（渐变标题 + 蓝色选项 + 子菜单）
# - 入站严格控制 / 出站全放行（适配 Vultr）
# - 端口占用检测（TCP/UDP）
# - 自动检测端口是否已开放
# - 自动检测 Web 服务（Nginx/Caddy）
# - Web 服务快捷管理
# - 动态加载动画
# - 一键备份 / 恢复规则
# - 清空规则保留 SSH
# - 永不锁死 SSH，初始化只执行一次

set -euo pipefail

ROLLBACK_TIME=60
LOG_FILE="/var/log/ufw_panel.log"
CONFIRM_FLAG="/tmp/ufw_confirmed_$$"
INIT_FLAG="/etc/ufw/.ufw_initialized"

# =========================
# 颜色
# =========================
if [[ -t 1 ]]; then
  RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
  BLUE="\033[34m"; MAGENTA="\033[35m"; CYAN="\033[36m"
  BOLD="\033[1m"; RESET="\033[0m"
  GRAD1="\033[38;5;39m"; GRAD2="\033[38;5;45m"; GRAD3="\033[38;5;51m"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
  BOLD=""; RESET=""; GRAD1=""; GRAD2=""; GRAD3=""
fi

# =========================
# 动态加载动画
# =========================
loading() {
  local msg="$1"
  local frames=('■□□□□' '■■□□□' '■■■□□' '■■■■□' '■■■■■')
  for i in {1..10}; do
    for f in "${frames[@]}"; do
      echo -ne "${CYAN}[$f]${RESET} $msg\r"
      sleep 0.1
    done
  done
  echo -ne "\r"
}

# =========================
# 美化输出
# =========================
print_info() {
    echo -e "${CYAN}# ${GREEN}[Info]${RESET} $1"
}

print_error() {
    echo -e "${CYAN}# ${RED}[Error]${RESET} $1"
}

log() {
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="[$ts] $*"
  echo -e "$msg" | tee -a "$LOG_FILE" >&2
}

banner() {
  echo -e "${BOLD}${GRAD1}╔════════════════════════════════════════════════╗"
  echo -e "${GRAD2}║                      CATMI                   ║"
  echo -e "${GRAD3}╚════════════════════════════════════════════════╝${RESET}"

  echo -e "                       ${CYAN}|\\__/,|   (\\\\${RESET}"
  echo -e "                     ${CYAN}_.|o o  |_   ) )${RESET}"
  echo -e "       ${CYAN}-------------(((---(((-------------------${RESET}"
}


# =========================
# Root 检查
# =========================
if [[ $EUID -ne 0 ]]; then
  print_error "必须以 root 身份运行"
  exit 1
fi

# =========================
# 日志文件准备
# =========================
touch "$LOG_FILE" 2>/dev/null || {
  print_error "无法写入日志文件: $LOG_FILE"
  exit 1
}
chmod 600 "$LOG_FILE"

# =========================
# 自动检查是否安装 UFW
# =========================
if ! command -v ufw >/dev/null 2>&1; then
  print_info "未检测到 UFW，是否安装？(Y/n)"
  read -r ans
  if [[ "$ans" =~ ^(Y|y|)$ ]]; then
    apt update && apt install -y ufw
    log "已自动安装 UFW"
  else
    print_error "未安装 UFW，脚本退出"
    exit 1
  fi
fi

banner

# =========================
# 检测 SSH 端口
# =========================
detect_ssh_port() {
  local port=""
  port="$(ss -tnlp 2>/dev/null | grep sshd | awk '{print $4}' | sed 's/.*://g' | head -n1 || true)"
  [[ -z "$port" ]] && port="$(grep -iE '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1 || true)"
  [[ -z "$port" ]] && port="22"
  echo "$port"
}

SSH_PORT="$(detect_ssh_port)"

# =========================
# 首次运行：初始化 UFW（不会断线）
# =========================
if [[ ! -f "$INIT_FLAG" ]]; then
  log "首次运行脚本，执行 UFW 初始化流程"
  print_info "检测到 SSH 端口：$SSH_PORT"

  iptables -I INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || true

  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null

  ufw allow "${SSH_PORT}/tcp" >/dev/null
  ufw allow 80 >/dev/null
  ufw allow 443 >/dev/null

  rollback_guard() {
    sleep "$ROLLBACK_TIME"
    if [[ ! -f "$CONFIRM_FLAG" ]]; then
      print_error "未确认，自动回滚 UFW"
      ufw disable >/dev/null 2>&1 || true
    fi
  }

  rollback_guard &
  ROLLBACK_PID=$!

  loading "正在启用 UFW..."
  ufw --force enable >/dev/null

  print_info "如果 SSH 正常，请输入 YES 确认（${ROLLBACK_TIME}s 超时）"
  confirm=""
  read -r -t "$ROLLBACK_TIME" confirm || true

  if [[ "${confirm^^}" == "YES" ]]; then
    touch "$CONFIRM_FLAG"
    kill "$ROLLBACK_PID" >/dev/null 2>&1 || true
    rm -f "$CONFIRM_FLAG"
    mkdir -p /etc/ufw
    touch "$INIT_FLAG"
    print_info "UFW 初始化成功"
  else
    print_error "未确认，将自动回滚"
  fi
fi
# =========================
# 端口管理子菜单
# =========================
port_menu() {
  while true; do
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════╗"
    echo "║            端口管理子菜单            ║"
    echo "╠══════════════════════════════════════╣"
    echo -e "║ ${BLUE}1)${RESET} 开放单个端口（TCP+UDP）"
    echo -e "║ ${BLUE}2)${RESET} 关闭单个端口（TCP+UDP）"
    echo -e "║ ${BLUE}3)${RESET} 开放端口范围"
    echo -e "║ ${BLUE}4)${RESET} 关闭端口范围"
    echo -e "║ ${BLUE}0)${RESET} 返回主菜单"
    echo "╚══════════════════════════════════════╝"
    echo -e "${RESET}"

    print_info "请选择操作："
    read -r sub

    case "$sub" in
      0)
        break
        ;;

      1)
        read -r -p "请输入端口号: " port
        loading "正在开放端口..."
        ufw allow "${port}/tcp" >/dev/null
        ufw allow "${port}/udp" >/dev/null
        print_info "已开放端口 ${port}"
        ;;

      2)
        read -r -p "请输入端口号: " port
        loading "正在关闭端口..."
        ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
        ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
        print_info "已关闭端口 ${port}"
        ;;

      3)
        read -r -p "请输入端口范围（如 5000-6000）: " range
        loading "正在开放端口范围..."
        ufw allow "${range}/tcp" >/dev/null
        ufw allow "${range}/udp" >/dev/null
        print_info "已开放端口范围 ${range}"
        ;;

      4)
        read -r -p "请输入端口范围（如 5000-6000）: " range
        loading "正在关闭端口范围..."
        ufw delete allow "${range}/tcp" >/dev/null 2>&1 || true
        ufw delete allow "${range}/udp" >/dev/null 2>&1 || true
        print_info "已关闭端口范围 ${range}"
        ;;

      *)
        print_error "无效选择"
        ;;
    esac
  done
}
# =========================
# Web 服务检测与管理（Nginx / Caddy）
# =========================
web_service_menu() {
  echo -e "${CYAN}╔══════════════════════════════════════╗"
  echo -e "║          Web 服务管理（Nginx/Caddy） ║"
  echo -e "╠══════════════════════════════════════╣${RESET}"

  # 检测 Nginx 状态
  if systemctl is-active --quiet nginx; then
    echo -e "║ Nginx 状态：${GREEN}运行中${RESET}"
  else
    echo -e "║ Nginx 状态：${RED}未运行${RESET}"
  fi

  # 检测 Caddy 状态
  if systemctl is-active --quiet caddy; then
    echo -e "║ Caddy 状态：${GREEN}运行中${RESET}"
  else
    echo -e "║ Caddy 状态：${RED}未运行${RESET}"
  fi

  echo -e "${CYAN}╠══════════════════════════════════════╣"
  echo -e "║ 1) 启动 Nginx"
  echo -e "║ 2) 停止 Nginx"
  echo -e "║ 3) 重载 Nginx"
  echo -e "║ 4) 启动 Caddy"
  echo -e "║ 5) 停止 Caddy"
  echo -e "║ 6) 重载 Caddy"
  echo -e "║ 0) 返回主菜单"
  echo -e "╚══════════════════════════════════════╝${RESET}"

  read -r -p "请选择操作：" webop

  case "$webop" in
    1)
      loading "正在启动 Nginx..."
      systemctl start nginx
      print_info "Nginx 已启动"
      ;;

    2)
      loading "正在停止 Nginx..."
      systemctl stop nginx
      print_info "Nginx 已停止"
      ;;

    3)
      loading "正在重载 Nginx..."
      systemctl reload nginx
      print_info "Nginx 已重载"
      ;;

    4)
      loading "正在启动 Caddy..."
      systemctl start caddy
      print_info "Caddy 已启动"
      ;;

    5)
      loading "正在停止 Caddy..."
      systemctl stop caddy
      print_info "Caddy 已停止"
      ;;

    6)
      loading "正在重载 Caddy..."
      systemctl reload caddy
      print_info "Caddy 已重载"
      ;;

    0)
      ;;

    *)
      print_error "无效选择"
      ;;
  esac
}
# =========================
# 端口占用检测（TCP/UDP）
# =========================
check_port() {
  local port="$1"

  echo -e "${CYAN}╔══════════════════════════════════════╗"
  echo -e "║            端口占用检测              ║"
  echo -e "╠══════════════════════════════════════╣${RESET}"

  # 检测是否被程序占用
  local occupy
  occupy=$(ss -tulnp 2>/dev/null | grep ":$port " | awk '{print $NF}' | sed 's/users://g' | sed 's/"//g')

  if [[ -n "$occupy" ]]; then
    echo -e "║ 端口 ${GREEN}$port${RESET} 被占用：${YELLOW}$occupy${RESET}"
  else
    echo -e "║ 端口 ${GREEN}$port${RESET} 未被任何程序占用"
  fi

  echo -e "${CYAN}╚══════════════════════════════════════╝${RESET}"
}

# =========================
# 检测端口是否已开放（UFW）
# =========================
check_port_open() {
  local port="$1"

  echo -e "${CYAN}╔══════════════════════════════════════╗"
  echo -e "║            端口开放检测              ║"
  echo -e "╠══════════════════════════════════════╣${RESET}"

  if ufw status | grep -qE "^$port/"; then
    echo -e "║ 端口 ${GREEN}$port${RESET} 已在 UFW 中开放"
  else
    echo -e "║ 端口 ${RED}$port${RESET} 未在 UFW 中开放"
  fi

  echo -e "${CYAN}╚══════════════════════════════════════╝${RESET}"
}

# =========================
# 美化后的端口列表（彩色 + 占用状态）
# =========================
show_open_ports() {
  echo -e "${CYAN}╔══════════════════════════════════════════════╗"
  echo -e "║   协议    端口        来源            占用状态     ║"
  echo -e "╠══════════════════════════════════════════════╣${RESET}"

  ufw status | grep ALLOW | while read -r line; do
    proto_port=$(echo "$line" | awk '{print $1}')
    from=$(echo "$line" | awk '{print $3}')
    port=$(echo "$proto_port" | cut -d'/' -f1)
    proto=$(echo "$proto_port" | cut -d'/' -f2)

    # 检测占用程序
    occupy=$(ss -tulnp 2>/dev/null | grep ":$port " | awk '{print $NF}' | sed 's/users://g' | sed 's/"//g')
    [[ -z "$occupy" ]] && occupy="未占用"

    # 颜色
    [[ "$proto" == "tcp" ]] && COLOR="${BLUE}" || COLOR="${MAGENTA}"

    printf "║  ${COLOR}%-4s${RESET}   %-6s   %-15s   %-20s ║\n" "$proto" "$port" "$from" "$occupy"
  done

  echo -e "${CYAN}╚══════════════════════════════════════════════╝${RESET}"
}
# =========================
# 自动开放所有被程序占用的端口
# =========================
auto_open_used_ports() {
  echo -e "${CYAN}╔════════════════════════════════════════════════╗"
  echo -e "║        自动开放所有被程序占用的端口（TCP/UDP）   ║"
  echo -e "╠════════════════════════════════════════════════╣${RESET}"

  # 获取所有监听端口
  ss -tulnp | tail -n +2 | while read -r line; do
    proto=$(echo "$line" | awk '{print $1}')
    local_addr=$(echo "$line" | awk '{print $5}')
    process=$(echo "$line" | awk '{print $NF}' | sed 's/users://g' | sed 's/"//g')

    port=$(echo "$local_addr" | sed 's/.*://')

    # 跳过无效端口
    [[ "$port" =~ ^[0-9]+$ ]] || continue

    # 跳过本地回环端口
    [[ "$local_addr" == 127.0.0.1* ]] && continue
    [[ "$local_addr" == ::1* ]] && continue

    # 跳过 Docker 内部端口
    [[ "$process" == *docker* ]] && continue

    # 执行开放
    if [[ "$proto" == "tcp" ]]; then
      ufw allow "$port/tcp" >/dev/null 2>&1
    elif [[ "$proto" == "udp" ]]; then
      ufw allow "$port/udp" >/dev/null 2>&1
    fi

    printf "║ 已开放端口 %-6s 协议 %-4s 进程 %-20s ║\n" "$port" "$proto" "$process"
  done

  echo -e "${CYAN}╚════════════════════════════════════════════════╝${RESET}"
  print_info "所有被程序占用的端口已自动开放"
}

# =========================
# 主菜单
# =========================
while true; do
  RAW_STATUS=$(ufw status | head -n1 | awk '{print $2}')

  if [[ "$RAW_STATUS" == "active" ]]; then
    STATUS_TEXT="防火墙状态：已启用"
    STATUS_COLOR="${GREEN}"
    TOGGLE_TEXT="关闭防火墙"
    TOGGLE_ACTION="disable"
  else
    STATUS_TEXT="防火墙状态：未启用"
    STATUS_COLOR="${RED}"
    TOGGLE_TEXT="启动防火墙"
    TOGGLE_ACTION="enable"
  fi

  PANEL_WIDTH=48
  STATUS_LEN=$(echo -n "$STATUS_TEXT" | wc -c)
  LEFT_PAD=$(( (PANEL_WIDTH - STATUS_LEN) / 2 ))
  PADDED_STATUS="$(printf "%*s%s" $LEFT_PAD "" "$STATUS_TEXT")"

  echo -e "${BOLD}${GRAD1}╔════════════════════════════════════════════════╗"
  echo -e "${GRAD2}║              UFW 防火墙管理面板 v7.1           ║"
  echo -e "${GRAD3}╠════════════════════════════════════════════════╣${RESET}"
  echo -e "║${STATUS_COLOR}${PADDED_STATUS}${RESET}║"
  echo "╠════════════════════════════════════════════════╣"
  echo -e "║ ${BLUE}0)${RESET} 退出"
  echo -e "║ ${BLUE}1)${RESET} 开放关闭端口管理"
  echo -e "║ ${BLUE}2)${RESET} 查看当前已开放端口"
  echo -e "║ ${BLUE}3)${RESET} 查看防火墙日志"
  echo -e "║ ${BLUE}4)${RESET} 清空所有规则（保留 SSH）"
  echo -e "║ ${BLUE}5)${RESET} ${TOGGLE_TEXT}"
  echo -e "║ ${BLUE}6)${RESET} 查看端口占用情况"
  echo -e "║ ${BLUE}7)${RESET} 备份规则"
  echo -e "║ ${BLUE}8)${RESET} 恢复规则"
  echo -e "║ ${BLUE}9)${RESET} Web 服务管理（Nginx/Caddy）"
  echo -e "║ ${BLUE}10)${RESET} 自动开放所有被程序占用的端口"
  echo -e "║ ${BLUE}11)${RESET} 删除 UFW（卸载防火墙）"
  echo "╚════════════════════════════════════════════════╝"

  print_info "请选择操作："
  read -r choice

  case "$choice" in
    0)
      print_info "退出脚本"
      exit 0
      ;;

    1)
      port_menu
      ;;

    2)
      show_open_ports
      ;;

    3)
      print_info "显示最新 50 行日志："
      tail -n 50 "$LOG_FILE"
      ;;

    4)
      print_error "你确定要清空所有规则吗？（YES 确认）"
      read -r confirm
      if [[ "${confirm^^}" == "YES" ]]; then
        loading "正在清空规则..."
        ufw --force reset >/dev/null
        ufw default deny incoming >/dev/null
        ufw default allow outgoing >/dev/null
        ufw allow "${SSH_PORT}/tcp" >/dev/null
        ufw allow 80 >/dev/null
        ufw allow 443 >/dev/null
        print_info "所有规则已清空（SSH + 基础网络已保留）"
      else
        print_info "取消操作"
      fi
      ;;

    5)
      if [[ "$TOGGLE_ACTION" == "enable" ]]; then
        loading "正在启动防火墙..."
        ufw --force enable
        print_info "防火墙已启用"
      else
        loading "正在关闭防火墙..."
        ufw disable
        print_info "防火墙已禁用"
      fi
      ;;

    6)
  echo -e "${CYAN}╔════════════════════════════════════════════════╗"
  echo -e "║            查看端口占用情况（应用 → 端口）       ║"
  echo -e "╠════════════════════════════════════════════════╣${RESET}"

  ss -tulnp | tail -n +2 | while read -r line; do
    proto=$(echo "$line" | awk '{print $1}')
    local_addr=$(echo "$line" | awk '{print $5}')
    process=$(echo "$line" | awk '{print $NF}' | sed 's/users://g' | sed 's/"//g')

    port=$(echo "$local_addr" | sed 's/.*://')

    [[ -z "$process" ]] && process="未知进程"

    [[ "$proto" == "tcp" ]] && COLOR="${BLUE}" || COLOR="${MAGENTA}"

    printf "║  ${COLOR}%-4s${RESET}   %-6s   %-20s   %-20s ║\n" "$proto" "$port" "$process" "$local_addr"
  done

  echo -e "${CYAN}╚════════════════════════════════════════════════╝${RESET}"
  ;;


    7)
      backup_rules
      ;;

    8)
      restore_rules
      ;;

    9)
      web_service_menu

      ;;

    10)
      auto_open_used_ports
      ;;
  
    11)
      print_error "⚠ 你确定要卸载 UFW 吗？（YES 确认）"
      read -r confirm
      if [[ "${confirm^^}" == "YES" ]]; then
        loading "正在卸载 UFW..."

        systemctl stop ufw >/dev/null 2>&1 || true
        systemctl disable ufw >/dev/null 2>&1 || true

        apt remove -y ufw >/dev/null 2>&1 || true
        rm -rf /etc/ufw >/dev/null 2>&1 || true

        print_info "UFW 已成功卸载（SSH 不受影响）"
        print_info "脚本即将退出"
        exit 0
      else
        print_info "取消操作"
      fi
      ;;

    *)
      print_error "无效选择"
      ;;
  esac
done
