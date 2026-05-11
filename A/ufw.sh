#!/usr/bin/env bash
# UFW 防火墙管理面板 v8.1（旗舰版 + SSH 动态适配 + 安全同步）
# - UI 美化（渐变标题 + 蓝色选项 + 子菜单）
# - 入站严格控制 / 出站全放行（适配 Vultr）
# - 多 SSH 端口支持（永不锁死）
# - SSH 端口变更后支持一键同步规则（先加后删，绝不失联）
# - 端口占用检测（TCP/UDP）
# - 自动检测端口是否已开放
# - 自动检测 Web 服务（Nginx/Caddy）
# - Web 服务快捷管理
# - 动态加载动画
# - 一键备份 / 恢复规则
# - 清空规则保留 SSH

set -euo pipefail

ROLLBACK_TIME=60
LOG_FILE="/var/log/ufw_panel.log"
CONFIRM_FLAG="/tmp/ufw_confirmed_$$"
INIT_FLAG="/etc/ufw/.ufw_initialized"
SSH_COMMENT="UFW_PANEL_SSH"   # 用于标记自动添加的 SSH 规则

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
print_warn() {
    echo -e "${CYAN}# ${YELLOW}[Warn]${RESET} $1"
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
# 检测当前所有 SSH 监听端口（多端口支持）
# =========================
get_current_ssh_ports() {
  local ports=()
  local line port

  # 1. 从 ss 获取实际监听的 sshd 端口
  while IFS= read -r line; do
    port="$(echo "$line" | awk '{print $4}' | sed 's/.*://g')"
    if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
      ports+=("$port")
    fi
  done < <(ss -tnlp 2>/dev/null | grep sshd || true)

  # 2. 从 sshd_config 补充（可能未启动或监听地址特殊）
  if [[ -f /etc/ssh/sshd_config ]]; then
    while IFS= read -r line; do
      port="$(echo "$line" | grep -iE '^Port ' | awk '{print $2}')"
      if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
        if [[ ! " ${ports[*]} " =~ " ${port} " ]]; then
          ports+=("$port")
        fi
      fi
    done < <(grep -iE '^Port ' /etc/ssh/sshd_config 2>/dev/null || true)
  fi

  # 默认 22
  if [[ ${#ports[@]} -eq 0 ]]; then
    ports=(22)
  fi

  # 去重、排序、输出空格分隔
  printf '%s\n' "${ports[@]}" | sort -nu | tr '\n' ' '
}

# =========================
# 获取当前 UFW 规则中已放行的 SSH 端口（通过注释识别）
# =========================
get_ufw_ssh_ports() {
  local ports=()
  local port
  # 直接 grep 包含注释的行，提取端口号
  while IFS= read -r line; do
    if echo "$line" | grep -q "$SSH_COMMENT"; then
      # 行格式如: "22/tcp ALLOW IN    Anywhere  # UFW_PANEL_SSH"
      port="$(echo "$line" | awk '{print $1}' | cut -d'/' -f1)"
      if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
        ports+=("$port")
      fi
    fi
  done < <(ufw status 2>/dev/null || true)
  printf '%s\n' "${ports[@]}" | sort -nu | tr '\n' ' '
}

# =========================
# 添加新的 SSH 端口规则（带注释）
# =========================
add_ssh_rule() {
  local port="$1"
  # 避免重复添加
  if ! ufw status | grep -q "$port/tcp.*$SSH_COMMENT"; then
    ufw allow from any to any port "$port" proto tcp comment "$SSH_COMMENT" >/dev/null
    log "添加 SSH 规则: $port/tcp"
  fi
}

# =========================
# 安全同步 SSH 端口规则（先添加新端口，再删除旧端口，避免失联）
# =========================
sync_ssh_ports() {
  local current_ports new_ports
  current_ports="$(get_ufw_ssh_ports)"
  new_ports="$(get_current_ssh_ports)"

  if [[ "$current_ports" == "$new_ports" ]]; then
    print_info "SSH 端口规则已是最新: $new_ports"
    return 0
  fi

  print_warn "当前 UFW 规则中的 SSH 端口: ${current_ports:-无}"
  print_warn "实际监听的 SSH 端口: $new_ports"

  # 额外警告：如果当前 SSH 会话端口不在新端口列表中，有失联风险
  local session_port="${SSH_CLIENT##* }"
  session_port="${session_port%% *}"
  if [[ -n "$session_port" && ! " $new_ports " =~ " $session_port " ]]; then
    echo -e "${RED}⚠️ 严重警告：您当前的 SSH 连接端口 ($session_port) 不在新的监听端口列表中！${RESET}"
    echo -e "${RED}   如果继续同步，您可能会立即断开连接。${RESET}"
    echo -e "${YELLOW}   建议先在 sshd_config 中同时保留新旧端口，重启 sshd，再执行同步。${RESET}"
    read -r -p "风险极高，是否仍然继续？(y/N): " force
    if [[ ! "$force" =~ ^[Yy]$ ]]; then
      print_info "取消同步"
      return 0
    fi
  fi

  echo -e "${YELLOW}是否更新防火墙规则？此操作会先添加新端口的规则，再删除旧端口的规则。${RESET}"
  echo -e "${YELLOW}注意：如果新旧端口不同，您当前的 SSH 连接不会中断（只要旧规则未被立即删除——但同步过程会保持旧规则直到最后一步删除）。${RESET}"
  read -r -p "确认同步？(y/N): " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    print_info "取消同步"
    return 0
  fi

  loading "正在安全同步 SSH 端口规则（先添加新端口）..."

  # 第一步：添加所有新端口的规则（如果已存在则跳过）
  for port in $new_ports; do
    add_ssh_rule "$port"
  done

  # 等待规则生效（UFW 规则添加通常即时生效）
  sleep 1

  # 第二步：删除旧端口的规则（仅删除带有注释且不在新端口列表中的）
  ufw status | grep "$SSH_COMMENT" | while IFS= read -r line; do
    port_proto="$(echo "$line" | awk '{print $1}')"
    port="$(echo "$port_proto" | cut -d'/' -f1)"
    if [[ -n "$port" && ! " $new_ports " =~ " $port " ]]; then
      ufw delete allow "$port_proto" >/dev/null 2>&1 || true
      log "删除旧 SSH 规则: $port_proto"
    fi
  done

  # 重载 UFW 使规则生效（删除操作后重载是必要的）
  ufw reload >/dev/null

  print_info "SSH 端口规则已安全更新为: $new_ports"
  log "SSH 端口规则安全同步: $new_ports"
}

# =========================
# 首次运行：初始化 UFW（永不锁死）
# =========================
if [[ ! -f "$INIT_FLAG" ]]; then
  log "首次运行脚本，执行 UFW 初始化流程"
  SSH_PORTS="$(get_current_ssh_ports)"
  print_info "检测到 SSH 端口：$SSH_PORTS"

  # 临时在 iptables 中放行所有 SSH 端口（防止启用 UFW 时瞬间断连）
  for port in $SSH_PORTS; do
    iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
  done

  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null

  # 为每个 SSH 端口添加规则（带注释）
  for port in $SSH_PORTS; do
    add_ssh_rule "$port"
  done
  # 开放 Web 服务常用端口
  ufw allow 80 >/dev/null
  ufw allow 443 >/dev/null

  # 回滚保护
  rollback_guard() {
    sleep "$ROLLBACK_TIME"
    if [[ ! -f "$CONFIRM_FLAG" ]]; then
      print_error "未确认，自动回滚 UFW"
      ufw disable >/dev/null 2>&1 || true
      # 清理 iptables 临时规则
      for port in $SSH_PORTS; do
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
      done
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
    # 清除 iptables 临时规则
    for port in $SSH_PORTS; do
      iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    done
    mkdir -p /etc/ufw
    touch "$INIT_FLAG"
    print_info "UFW 初始化成功，SSH 端口规则已生效"
  else
    print_error "未确认，已自动回滚"
    exit 1
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

    read -r -p "请选择操作：" sub

    case "$sub" in
      0) break ;;
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
      *) print_error "无效选择" ;;
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

  if systemctl is-active --quiet nginx; then
    echo -e "║ Nginx 状态：${GREEN}运行中${RESET}"
  else
    echo -e "║ Nginx 状态：${RED}未运行${RESET}"
  fi

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
    1) loading "正在启动 Nginx..."; systemctl start nginx; print_info "Nginx 已启动" ;;
    2) loading "正在停止 Nginx..."; systemctl stop nginx; print_info "Nginx 已停止" ;;
    3) loading "正在重载 Nginx..."; systemctl reload nginx; print_info "Nginx 已重载" ;;
    4) loading "正在启动 Caddy..."; systemctl start caddy; print_info "Caddy 已启动" ;;
    5) loading "正在停止 Caddy..."; systemctl stop caddy; print_info "Caddy 已停止" ;;
    6) loading "正在重载 Caddy..."; systemctl reload caddy; print_info "Caddy 已重载" ;;
    0) ;;
    *) print_error "无效选择" ;;
  esac
}

# =========================
# 端口占用检测（TCP/UDP）
# =========================
check_port_usage() {
  local port="$1"
  echo -e "${CYAN}╔══════════════════════════════════════╗"
  echo -e "║            端口占用检测              ║"
  echo -e "╠══════════════════════════════════════╣${RESET}"
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

    occupy=$(ss -tulnp 2>/dev/null | grep ":$port " | awk '{print $NF}' | sed 's/users://g' | sed 's/"//g')
    [[ -z "$occupy" ]] && occupy="未占用"

    [[ "$proto" == "tcp" ]] && COLOR="${BLUE}" || COLOR="${MAGENTA}"
    printf "║  ${COLOR}%-4s${RESET}   %-6s   %-15s   %-20s ║\n" "$proto" "$port" "$from" "$occupy"
  done
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${RESET}"
}

# =========================
# 自动开放所有被程序占用的端口（排除回环、Docker）
# =========================
auto_open_used_ports() {
  echo -e "${CYAN}╔════════════════════════════════════════════════╗"
  echo -e "║        自动开放所有被程序占用的端口（TCP/UDP）   ║"
  echo -e "╠════════════════════════════════════════════════╣${RESET}"
  ss -tulnp | tail -n +2 | while read -r line; do
    proto=$(echo "$line" | awk '{print $1}')
    local_addr=$(echo "$line" | awk '{print $5}')
    process=$(echo "$line" | awk '{print $NF}' | sed 's/users://g' | sed 's/"//g')
    port=$(echo "$local_addr" | sed 's/.*://')
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    [[ "$local_addr" == 127.0.0.1* ]] && continue
    [[ "$local_addr" == ::1* ]] && continue
    [[ "$process" == *docker* ]] && continue
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
# 备份规则（备份 /etc/ufw 目录）
# =========================
backup_rules() {
  local backup_dir="/etc/ufw/backups"
  mkdir -p "$backup_dir"
  local backup_file="$backup_dir/ufw_backup_$(date '+%Y%m%d_%H%M%S').tar.gz"
  tar -czf "$backup_file" /etc/ufw 2>/dev/null || {
    print_error "备份失败，请检查权限"
    return
  }
  print_info "规则已备份到：$backup_file"
  log "备份 UFW 规则到 $backup_file"
}

# =========================
# 恢复规则
# =========================
restore_rules() {
  local backup_dir="/etc/ufw/backups"
  echo -e "${CYAN}可用备份文件：${RESET}"
  ls -1 "$backup_dir"/ufw_backup_*.tar.gz 2>/dev/null || {
    print_error "没有找到任何备份文件"
    return
  }
  read -r -p "请输入要恢复的文件路径：" file
  if [[ ! -f "$file" ]]; then
    print_error "文件不存在"
    return
  fi
  loading "正在恢复规则，这会覆盖当前 UFW 配置..."
  tar -xzf "$file" -C / 2>/dev/null || {
    print_error "恢复失败，文件可能损坏"
    return
  }
  ufw reload >/dev/null
  print_info "规则已从备份恢复，请检查 SSH 连接后再确认"
  log "从备份恢复规则：$file"
}

# =========================
# 清空所有规则（保留 SSH 和基础端口）
# =========================
reset_rules() {
  print_error "你确定要清空所有规则吗？（YES 确认）"
  read -r confirm
  if [[ "${confirm^^}" != "YES" ]]; then
    print_info "取消操作"
    return
  fi
  loading "正在清空规则..."
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  # 重新添加当前 SSH 端口（带注释）
  local ssh_ports="$(get_current_ssh_ports)"
  for port in $ssh_ports; do
    add_ssh_rule "$port"
  done
  ufw allow 80 >/dev/null
  ufw allow 443 >/dev/null
  ufw reload >/dev/null
  print_info "所有规则已清空，SSH (${ssh_ports})、80、443 已保留"
  log "规则已重置，SSH 端口: $ssh_ports"
}

# =========================
# 删除 UFW（卸载防火墙）
# =========================
delete_ufw() {
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
}

# =========================
# 主菜单
# =========================
while true; do
  # 检查 SSH 端口一致性（警告）
  current_ssh="$(get_current_ssh_ports)"
  ufw_ssh="$(get_ufw_ssh_ports)"
  if [[ "$current_ssh" != "$ufw_ssh" ]]; then
    print_warn "检测到 SSH 端口不一致！规则中: ${ufw_ssh:-无}, 实际监听: $current_ssh"
    echo -e "   请使用主菜单选项 ${BLUE}12${RESET} 同步 SSH 端口规则"
  fi

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
  echo -e "${GRAD2}║              UFW 防火墙管理面板 v8.1           ║"
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
  echo -e "║ ${BLUE}12)${RESET} 同步 SSH 端口规则（解决改端口问题）"
  echo "╚════════════════════════════════════════════════╝"

  read -r -p "请选择操作：" choice

  case "$choice" in
    0) print_info "退出脚本"; exit 0 ;;
    1) port_menu ;;
    2) show_open_ports ;;
    3) print_info "显示最新 50 行日志："; tail -n 50 "$LOG_FILE" ;;
    4) reset_rules ;;
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
    7) backup_rules ;;
    8) restore_rules ;;
    9) web_service_menu ;;
    10) auto_open_used_ports ;;
    11) delete_ufw ;;
    12) sync_ssh_ports ;;
    *) print_error "无效选择" ;;
  esac
done
