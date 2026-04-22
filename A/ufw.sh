#!/usr/bin/env bash
# UFW 安全启用 + HY2 端口管理（最终版 v4.5，不会断线 + 表格端口显示）

set -euo pipefail

ROLLBACK_TIME=60
LOG_FILE="/var/log/ufw_safe_enable.log"
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
# 日志函数
# =========================
log() {
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="[$ts] $*"
  echo -e "$msg" | tee -a "$LOG_FILE" >&2
}

banner() {
  echo -e "${BOLD}${CYAN}============================================${RESET}"
  echo -e "${BOLD}${MAGENTA}   UFW 安全启用模式 + HY2 端口管理 v4.5   ${RESET}"
  echo -e "${BOLD}${CYAN}============================================${RESET}"
}

# =========================
# Root 检查
# =========================
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}❌ 必须以 root 身份运行${RESET}"
  exit 1
fi

# =========================
# 日志文件准备
# =========================
touch "$LOG_FILE" 2>/dev/null || {
  echo -e "${RED}❌ 无法写入日志文件: $LOG_FILE${RESET}"
  exit 1
}
chmod 600 "$LOG_FILE"

# =========================
# 自动检查是否安装 UFW
# =========================
if ! command -v ufw >/dev/null 2>&1; then
  echo -e "${YELLOW}⚠️ 未检测到 UFW，是否安装？(Y/n)${RESET}"
  read -r ans
  if [[ "$ans" =~ ^(Y|y|)$ ]]; then
    apt update && apt install -y ufw
    log "已自动安装 UFW"
  else
    echo -e "${RED}❌ 未安装 UFW，脚本退出${RESET}"
    exit 1
  fi
fi

banner

# =========================
# 稳定版 SSH 端口检测（无 awk 正则）
# =========================
detect_ssh_port() {
  local port=""

  if command -v ss >/dev/null 2>&1; then
    port="$(ss -tnlp 2>/dev/null \
      | grep sshd \
      | awk '{print $4}' \
      | sed 's/.*://g' \
      | grep -E '^[0-9]+$' \
      | head -n1 || true)"
  fi

  [[ -z "$port" ]] && port="$(grep -iE '^Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1 || true)"
  [[ -z "$port" ]] && port="22"

  echo "$port"
}

SSH_PORT="$(detect_ssh_port)"

# =========================
# 第一次运行：执行安全启用流程
# =========================
if [[ ! -f "$INIT_FLAG" ]]; then
  log "首次运行脚本，执行 UFW 初始化流程"
  echo -e "${BLUE}🔍 检测到 SSH 端口: ${BOLD}${SSH_PORT}${RESET}"

  # iptables 兜底保护
  iptables -I INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || true
  log "iptables 兜底保护 SSH 端口 ${SSH_PORT}"

  # 默认策略
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  log "设置默认策略：deny incoming / allow outgoing"

  # 放行 SSH
  ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true
  log "放行 SSH 端口 ${SSH_PORT}/tcp"

  # 自动回滚守护进程
  rollback_guard() {
    sleep "$ROLLBACK_TIME"
    if [[ ! -f "$CONFIRM_FLAG" ]]; then
      echo -e "${RED}⚠️ 未确认，自动回滚 UFW${RESET}"
      log "未确认，执行自动回滚"
      ufw disable >/dev/null 2>&1 || true
    fi
  }

  rollback_guard &
  ROLLBACK_PID=$!
  log "回滚守护进程 PID: $ROLLBACK_PID"

  # 启用 UFW（不会断线）
  echo -e "${CYAN}🚀 启用 UFW...${RESET}"
  ufw --force enable >/dev/null
  log "UFW 已启用"

  sleep 2

  # 用户确认
  echo -e "${BOLD}${CYAN}============================================${RESET}"
  echo -e "${GREEN}如果 SSH 正常，请输入 YES 确认${RESET}"
  echo -e "${YELLOW}否则将在 ${ROLLBACK_TIME}s 后自动回滚${RESET}"
  echo -e "${BOLD}${CYAN}============================================${RESET}"

  confirm=""
  if [[ -t 0 ]]; then
    read -r -t "$ROLLBACK_TIME" confirm || true
  fi

  if [[ "$confirm" == "YES" ]]; then
    touch "$CONFIRM_FLAG"
    kill "$ROLLBACK_PID" >/dev/null 2>&1 || true
    rm -f "$CONFIRM_FLAG"
    echo -e "${GREEN}✔ UFW 安全启用完成${RESET}"
    log "用户确认，UFW 保持启用"

    # 创建初始化标记
    mkdir -p /etc/ufw
    touch "$INIT_FLAG"
    log "创建初始化标记文件：$INIT_FLAG"
  else
    echo -e "${YELLOW}⚠ 未确认，将在超时后自动回滚${RESET}"
    log "用户未确认，等待自动回滚"
  fi
fi

# =========================
# 菜单：HY2 / 自定义端口管理
# =========================
while true; do
  echo -e "${BOLD}${CYAN}
========= HY2 / 自定义端口管理 =========
1) 开放端口（TCP + UDP）
2) 关闭端口（TCP + UDP）
3) 查看当前已开放端口（表格）
4) 退出
========================================${RESET}"

  read -r -p "请选择操作: " choice

  case "$choice" in
    1)
      read -r -p "请输入要开放的端口号: " port
      ufw allow "${port}/tcp" >/dev/null 2>&1 || true
      ufw allow "${port}/udp" >/dev/null 2>&1 || true
      iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
      echo -e "${GREEN}✔ 已开放端口 ${port}（TCP + UDP）${RESET}"
      log "开放端口 ${port}（TCP + UDP）"
      ;;
    2)
      read -r -p "请输入要关闭的端口号: " port
      ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
      ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
      echo -e "${GREEN}✔ 已关闭端口 ${port}（TCP + UDP）${RESET}"
      log "关闭端口 ${port}（TCP + UDP）"
      ;;
    3)
      echo -e "${CYAN}协议    端口\n----------------${RESET}"
      ufw status numbered | grep -Eo '(tcp|udp).*' | awk '{print $1"    "$2}'
      ;;
    4)
      echo -e "${CYAN}退出脚本${RESET}"
      exit 0
      ;;
    *)
      echo -e "${RED}❌ 无效选择${RESET}"
      ;;
  esac
done
