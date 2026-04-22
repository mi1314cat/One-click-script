#!/usr/bin/env bash
# UFW 防火墙管理面板 v6.5（方案 B：出站全放行）
# - UI 美化（中文 + 蓝色选项 + 子菜单）
# - 入站严格控制
# - 出站完全放行（解决 Vultr DNS 断网问题）
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
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; BOLD=""; RESET=""
fi

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
  echo -e "${BOLD}${CYAN}"
  echo "╔════════════════════════════════════════════════╗"
  echo "║              UFW 防火墙管理面板 v6.5           ║"
  echo "╚════════════════════════════════════════════════╝"
  echo -e "${RESET}"
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

  # iptables 兜底保护 SSH
  iptables -I INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || true
  log "iptables 兜底保护 SSH 端口"

  # 默认策略（方案 B：出站全放行）
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null

  # 放行 SSH
  ufw allow "${SSH_PORT}/tcp" >/dev/null

  # 放行基础入站端口（可选）
  ufw allow 80 >/dev/null
  ufw allow 443 >/dev/null

  # ❗ 不要放行任何 DNS 出站规则（避免 Vultr DNS BUG）
  # ❗ 不要放行 53 / 53/udp / 443 / 853 出站
  # ❗ 不要使用 ufw route allow

  # 回滚守护
  rollback_guard() {
    sleep "$ROLLBACK_TIME"
    if [[ ! -f "$CONFIRM_FLAG" ]]; then
      print_error "未确认，自动回滚 UFW"
      ufw disable >/dev/null 2>&1 || true
    fi
  }

  rollback_guard &
  ROLLBACK_PID=$!

  print_info "正在启用 UFW..."
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

  echo -e "${BOLD}${CYAN}"
  echo "╔════════════════════════════════════════════════╗"
  echo "║              UFW 防火墙管理面板 v6.5           ║"
  echo "╠════════════════════════════════════════════════╣"
  echo -e "║${STATUS_COLOR}${PADDED_STATUS}${RESET}║"
  echo "╠════════════════════════════════════════════════╣"
  echo -e "║ ${BLUE}0)${RESET} 退出"
  echo -e "║ ${BLUE}1)${RESET} 端口管理（子菜单）"
  echo -e "║ ${BLUE}2)${RESET} 查看当前已开放端口（彩色表格）"
  echo -e "║ ${BLUE}3)${RESET} 查看防火墙日志"
  echo -e "║ ${BLUE}4)${RESET} 清空所有规则（排除 SSH）"
  echo -e "║ ${BLUE}5)${RESET} ${TOGGLE_TEXT}"
  echo "╚════════════════════════════════════════════════╝"
  echo -e "${RESET}"

  print_info "请选择操作："
  read -r choice

  case "$choice" in
    0)
      print_info "退出脚本"
      exit 0
      ;;

    1)
      # 子菜单：端口管理
      while true; do
        echo -e "${CYAN}"
        echo "╔══════════════════════════════════════╗"
        echo "║            端口管理子菜单            ║"
        echo "╠══════════════════════════════════════╣"
        echo -e "║ ${BLUE}1)${RESET} 开放单个端口（TCP+UDP）"
        echo -e "║ ${BLUE}2)${RESET} 关闭单个端口（TCP+UDP）"
        echo -e "║ ${BLUE}3)${RESET} 开放端口范围（5000-6000）"
        echo -e "║ ${BLUE}4)${RESET} 关闭端口范围（5000-6000）"
        echo -e "║ ${BLUE}0)${RESET} 返回主菜单"
        echo "╚══════════════════════════════════════╝"
        echo -e "${RESET}"

        print_info "请选择操作："
        read -r sub

        case "$sub" in
          0) break ;;
          1)
            read -r -p "请输入端口号: " port
            ufw allow "${port}/tcp" >/dev/null
            ufw allow "${port}/udp" >/dev/null
            print_info "已开放端口 ${port}"
            ;;
          2)
            read -r -p "请输入端口号: " port
            ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
            ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
            print_info "已关闭端口 ${port}"
            ;;
          3)
            read -r -p "请输入端口范围（如 5000-6000）: " range
            ufw allow "${range}/tcp" >/dev/null
            ufw allow "${range}/udp" >/dev/null
            print_info "已开放端口范围 ${range}"
            ;;
          4)
            read -r -p "请输入端口范围（如 5000-6000）: " range
            ufw delete allow "${range}/tcp" >/dev/null 2>&1 || true
            ufw delete allow "${range}/udp" >/dev/null 2>&1 || true
            print_info "已关闭端口范围 ${range}"
            ;;
          *)
            print_error "无效选择"
            ;;
        esac
      done
      ;;

    2)
      echo -e "${CYAN}╔══════════════════════════════════════╗"
      echo -e "║   协议        端口                    ║"
      echo -e "╠══════════════════════════════════════╣${RESET}"

      ufw status | grep ALLOW \
        | awk '{print $1}' \
        | grep -Eo '^[0-9]+(-[0-9]+)?/(tcp|udp)' \
        | sed 's/\// /g' \
        | while read -r port proto; do
            if [[ "$proto" == "tcp" ]]; then
              COLOR="${BLUE}"
            else
              COLOR="${MAGENTA}"
            fi
            printf "║  ${COLOR}%-6s${RESET}   %-15s      ║\n" "$proto" "$port"
          done

      echo -e "${CYAN}╚══════════════════════════════════════╝${RESET}"
      ;;

    3)
      print_info "显示最新 50 行日志："
      tail -n 50 "$LOG_FILE"
      ;;

    4)
      print_error "你确定要清空所有规则吗？（YES 确认）"
      read -r confirm
      if [[ "${confirm^^}" == "YES" ]]; then
        SSH_PORT=$(detect_ssh_port)

        ufw --force reset >/dev/null
        ufw default deny incoming >/dev/null
        ufw default allow outgoing >/dev/null
        ufw allow "${SSH_PORT}/tcp" >/dev/null

        # 清空后恢复基础入站端口
        ufw allow 80 >/dev/null
        ufw allow 443 >/dev/null

        print_info "所有规则已清空（SSH + 基础网络已保留）"
      else
        print_info "取消操作"
      fi
      ;;

    5)
      if [[ "$TOGGLE_ACTION" == "enable" ]]; then
        ufw --force enable
        print_info "防火墙已启用"
      else
        ufw disable
        print_info "防火墙已禁用"
      fi
      ;;

    *)
      print_error "无效选择"
      ;;
  esac
done
