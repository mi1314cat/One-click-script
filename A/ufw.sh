#!/usr/bin/env bash
# UFW 安全启用 + 自定义端口管理（带自动回滚、颜色 UI、日志）

set -euo pipefail

# =========================
# 配置区
# =========================
ROLLBACK_TIME=60
LOG_FILE="/var/log/ufw_safe_enable.log"
CONFIRM_FLAG="/tmp/ufw_confirmed_$$"

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

# =========================
# Banner
# =========================
banner() {
  echo -e "${BOLD}${CYAN}============================================${RESET}"
  echo -e "${BOLD}${MAGENTA}   UFW 安全启用模式 + 自定义端口管理   ${RESET}"
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
log "启动 UFW 安全启用流程"

# =========================
# 检测 SSH 端口
# =========================
detect_ssh_port() {
  local port=""
  port="$(ss -tnlp 2>/dev/null \
    | awk '/sshd/ {
        gsub(/

\[|\]

/,"",$4);
        split($4,a,":");
        print a[length(a)]
      }' | grep -E '^[0-9]+$' | head -n1 || true)"

  [[ -z "$port" ]] && port="$(grep -iE '^Port ' /etc/ssh/sshd_config | awk '{print $2}' | head -n1 || true)"
  [[ -z "$port" ]] && port="22"
  echo "$port"
}

SSH_PORT="$(detect_ssh_port)"
echo -e "${BLUE}🔍 检测到 SSH 端口: ${BOLD}${SSH_PORT}${RESET}"
log "检测到 SSH 端口: $SSH_PORT"

# =========================
# 放行 SSH
# =========================
echo -e "${CYAN}🛡️ 放行 SSH 端口...${RESET}"
ufw insert 1 allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || ufw allow "${SSH_PORT}/tcp" >/dev/null
log "放行 SSH 端口 ${SSH_PORT}/tcp"

# =========================
# 自动回滚守护进程
# =========================
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

# =========================
# 启用 UFW
# =========================
echo -e "${CYAN}🚀 启用 UFW...${RESET}"
ufw --force enable >/dev/null
log "UFW 已启用"

sleep 2

# =========================
# 检查 SSH 规则
# =========================
if ! ufw status numbered | grep -q "${SSH_PORT}/tcp"; then
  echo -e "${RED}❌ SSH 端口未被放行，立即回滚${RESET}"
  log "SSH 端口未被放行，回滚"
  ufw disable >/dev/null
  exit 1
fi

# =========================
# 用户确认
# =========================
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
else
  echo -e "${YELLOW}⚠ 未确认，将在超时后自动回滚${RESET}"
  log "用户未确认，等待自动回滚"
fi

# =========================
# 自定义端口管理菜单
# =========================

while true; do
  echo -e "${BOLD}${CYAN}
========= 自定义端口管理 =========
1) 开放端口（TCP + UDP）
2) 关闭端口（TCP + UDP）
3) 查看 UFW 状态
4) 退出
=================================${RESET}"

  read -r -p "请选择操作: " choice

  case "$choice" in
    1)
      read -r -p "请输入要开放的端口号: " port
      echo -e "${CYAN}➡ 开放 ${port}/tcp 和 ${port}/udp ...${RESET}"

      ufw allow "${port}/tcp" >/dev/null 2>&1 || true
      ufw allow "${port}/udp" >/dev/null 2>&1 || true

      echo -e "${GREEN}✔ 已开放端口 ${port}（TCP + UDP）${RESET}"
      log "开放端口 ${port}（TCP + UDP）"
      ;;
    2)
      read -r -p "请输入要关闭的端口号: " port
      echo -e "${CYAN}➡ 关闭 ${port}/tcp 和 ${port}/udp ...${RESET}"

      ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
      ufw delete allow "${port}/udp" >/dev/null 2>&1 || true

      echo -e "${GREEN}✔ 已关闭端口 ${port}（TCP + UDP）${RESET}"
      log "关闭端口 ${port}（TCP + UDP）"
      ;;
    3)
      ufw status verbose
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


