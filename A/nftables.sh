#!/usr/bin/env bash
# ============================================================================
# nftables 防火墙管理面板 v9.1(稳定版 / Debian+Ubuntu+CentOS 通用)
# - 独立规则文件:  /etc/nftables.d/ufw-panel.nft              (基础规则: SSH+基础网络)
# - 动态端口持久化: /etc/nftables.d/zz-ufw-panel-dynamic.nft   (开放端口重启后保留)
# - systemd 自动加载 + 开机自启(原生 nftables + 面板服务)
# - 渐变 UI + 子菜单 + 动态动画
# - 永不锁死 SSH(支持多端口、动态更新、禁止关闭 SSH 端口)
# - 端口管理 / Web 服务管理 / 自动开放端口
# - 备份 / 恢复 / 日志系统
# - 去除全局 set -e,改为局部防呆,避免意外退出
# ============================================================================

set -u  # 保留未定义变量保护,不用 -e

LOG_FILE="/var/log/nft_panel.log"
INIT_FLAG="/etc/nftables.d/.nft_panel_initialized"
NFT_DIR="/etc/nftables.d"
NFT_RULE_FILE="$NFT_DIR/ufw-panel.nft"
NFT_DYN_FILE="$NFT_DIR/zz-ufw-panel-dynamic.nft"
NFT_SERVICE="/etc/systemd/system/nftables-ufw-panel.service"

# =========================
# 颜色(非终端自动关闭)
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
# 统一输出(带颜色的消息)
# =========================
print_info()  { echo -e "${CYAN}# ${GREEN}[Info]${RESET} $1"; }
print_warn()  { echo -e "${CYAN}# ${YELLOW}[Warn]${RESET} $1"; }
print_error() { echo -e "${CYAN}# ${RED}[Error]${RESET} $1"; }

log() {
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')" || ts="unknown-time"
  msg="[$ts] $*"
  echo -e "$msg" | tee -a "$LOG_FILE" >&2
}

loading() {
  local msg="$1"
  local frames=('■□□□□' '■■□□□' '■■■□□' '■■■■□' '■■■■■')
  for _ in {1..10}; do
    for f in "${frames[@]}"; do
      echo -ne "${CYAN}[$f]${RESET} $msg\r"
      sleep 0.08
    done
  done
  echo -ne "\r"
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
chmod 600 "$LOG_FILE" 2>/dev/null || true

banner

# =========================
# 端口合法性校验(1-65535 数字)
# =========================
valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

# =========================
# 自动安装 nftables(跨发行版)+ 开机自启
# =========================
install_nftables_if_missing() {
  if command -v nft >/dev/null 2>&1; then
    # 已安装:确保原生服务开机自启(幂等)
    systemctl enable nftables 2>/dev/null || true
    return
  fi

  print_warn "检测到系统未安装 nftables,正在自动安装..."
  if command -v apt >/dev/null 2>&1; then
    apt update -y
    apt install -y nftables
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nftables
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nftables
  else
    print_error "无法自动安装 nftables,请手动安装后重试"
    exit 1
  fi

  if ! command -v nft >/dev/null 2>&1; then
    print_error "nftables 安装失败,请检查系统包管理器"
    exit 1
  fi

  # 开机自启 + 启动原生 nftables 服务(用户要求)
  systemctl enable nftables 2>/dev/null || true
  systemctl start nftables 2>/dev/null || true
  print_info "nftables 安装成功,并已设置 systemctl enable nftables"
}

install_nftables_if_missing

# =========================
# 命令存在性检查
# =========================
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    print_error "缺少必要命令:$1,请先安装后再运行"
    exit 1
  }
}
need_cmd ss
need_cmd systemctl

# =========================
# 检测当前 SSH 监听端口(多端口支持)
# =========================
get_current_ssh_ports() {
  local ports=()
  local line port

  # 1. 从 ss 中获取所有 sshd 监听端口
  while IFS= read -r line; do
    port="$(echo "$line" | awk '{print $4}' | sed 's/.*://g')"
    if valid_port "$port"; then
      ports+=("$port")
    fi
  done < <(ss -tnlp 2>/dev/null | grep sshd || true)

  # 2. 从 sshd_config 补充
  if [[ -f /etc/ssh/sshd_config ]]; then
    while IFS= read -r line; do
      port="$(echo "$line" | grep -iE '^Port ' | awk '{print $2}')"
      if valid_port "$port"; then
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

  printf '%s\n' "${ports[@]}" | sort -nu | tr '\n' ' '
}

# =========================
# 生成基础规则文件(SSH + 基础网络)
# =========================
write_rule_file() {
  local ssh_ports="$1"
  local ssh_accept_rules=""
  for port in $ssh_ports; do
    ssh_accept_rules+="    tcp dport $port accept comment \"UFW_PANEL_SSH\"\n"
  done

  cat > "$NFT_RULE_FILE" <<EOF
table inet filter {
  chain input {
    type filter hook input priority 0; policy accept;

    # 动态 SSH 端口(永不锁死)
$(echo -e "$ssh_accept_rules")
    # 基础安全
    ct state established,related accept
    iif lo accept
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }

  chain forward {
    type filter hook forward priority 0; policy accept;
  }
}
EOF
}

# =========================
# 生成 systemd 自动加载服务(基础 + 动态端口)
# =========================
generate_systemd_service() {
  local NFT_BIN
  NFT_BIN="$(command -v nft)"

  cat > "$NFT_SERVICE" <<EOF
[Unit]
Description=Load nftables rules for UFW Panel Replacement
After=network.target nftables.service
Wants=nftables.service

[Service]
Type=oneshot
ExecStart=-$NFT_BIN flush table inet filter
ExecStart=$NFT_BIN -f $NFT_RULE_FILE
ExecStart=$NFT_BIN -f $NFT_DYN_FILE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || true
  systemctl enable "$(basename "$NFT_SERVICE")" 2>/dev/null || true
}

# =========================
# 安全加载 nft 规则(基础 + 动态)
# =========================
safe_nft_load() {
  if [[ -f "$NFT_RULE_FILE" ]]; then
    nft flush table inet filter 2>/dev/null || true
    nft -f "$NFT_RULE_FILE" >/dev/null 2>&1 || {
      print_error "加载 nftables 基础规则失败,检查语法:$NFT_RULE_FILE"
      return 1
    }
  fi
  if [[ -f "$NFT_DYN_FILE" ]]; then
    nft -f "$NFT_DYN_FILE" >/dev/null 2>&1 || {
      print_error "加载动态端口规则失败,检查语法:$NFT_DYN_FILE"
      return 1
    }
  fi
  return 0
}

# =========================
# 动态端口持久化(把运行时开放端口写入文件,重启后保留)
# =========================
persist_dynamic_ports() {
  local proto port
  : > "$NFT_DYN_FILE"

  echo "table inet filter {" >> "$NFT_DYN_FILE"
  echo "  chain input {" >> "$NFT_DYN_FILE"
  # 注意:chain 的 type/hook 由基础规则文件定义,此处仅追加规则

  nft list chain inet filter input 2>/dev/null \
    | grep -E 'dport [0-9]+ accept' \
    | grep -v 'comment "UFW_PANEL_SSH"' \
    | while read -r line; do
        proto="$(echo "$line" | grep -oE '(tcp|udp)' || true)"
        port="$(echo "$line" | grep -oE 'dport [0-9]+' | awk '{print $2}' || true)"
        [[ -z "$proto" || -z "$port" ]] && continue
        echo "    ${proto} dport ${port} accept" >> "$NFT_DYN_FILE"
      done

  echo "  }" >> "$NFT_DYN_FILE"
  echo "}" >> "$NFT_DYN_FILE"
}

# =========================
# 获取当前规则中实际开放的 SSH 端口
# =========================
get_rules_ssh_ports() {
  nft list chain inet filter input 2>/dev/null \
    | grep -E 'tcp dport [0-9]+ accept comment "UFW_PANEL_SSH"' \
    | sed -n 's/.*dport \([0-9]\+\).*/\1/p' \
    | sort -nu | tr '\n' ' '
}

# =========================
# 删除所有带注释的 SSH 规则
# =========================
remove_ssh_rules() {
  nft -a list chain inet filter input 2>/dev/null \
    | grep 'comment "UFW_PANEL_SSH"' \
    | grep -o 'handle [0-9]\+' | awk '{print $2}' \
    | while read -r handle; do
        nft delete rule inet filter input handle "$handle" 2>/dev/null || true
      done
}

# =========================
# 安全同步 SSH 端口规则(先添加新端口,再删除旧端口,避免失联)
# =========================
sync_ssh_ports() {
  local current_ports new_ports
  current_ports="$(get_rules_ssh_ports)"
  new_ports="$(get_current_ssh_ports)"

  if [[ "$current_ports" == "$new_ports" ]]; then
    print_info "SSH 端口规则已是最新: $new_ports"
    return 0
  fi

  print_warn "当前规则中的 SSH 端口: ${current_ports:-无}"
  print_warn "实际监听的 SSH 端口: $new_ports"
  echo -e "${YELLOW}⚠️ 安全同步将:"
  echo "   1. 先添加所有新端口的允许规则"
  echo "   2. 再删除旧端口的规则(仅针对带 'UFW_PANEL_SSH' 注释且不在新端口列表中的规则)"
  echo "   3. 不会影响您当前已经开放的其它端口"
  echo -e "   这样可确保您的 SSH 连接不会中断。${RESET}"
  read -r -p "确认更新?(y/N): " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    print_info "取消同步"
    return 0
  fi

  loading "正在安全更新 SSH 端口规则..."

  # 第一步:添加所有新的 SSH 端口规则(带注释,避免重复)
  for port in $new_ports; do
    if ! nft list chain inet filter input 2>/dev/null | grep -q "tcp dport $port accept.*comment \"UFW_PANEL_SSH\""; then
      nft add rule inet filter input tcp dport "$port" accept comment "UFW_PANEL_SSH" 2>/dev/null
      log "添加新 SSH 规则: 端口 $port"
    else
      log "规则已存在,跳过: 端口 $port"
    fi
  done

  sleep 1

  # 第二步:删除旧的 SSH 规则(不在新端口列表中)
  nft -a list chain inet filter input 2>/dev/null \
    | grep 'comment "UFW_PANEL_SSH"' \
    | while read -r line; do
        port="$(echo "$line" | sed -n 's/.*dport \([0-9]\+\).*/\1/p')"
        handle="$(echo "$line" | grep -o 'handle [0-9]\+' | awk '{print $2}')"
        if [[ -n "$port" && -n "$handle" ]] && [[ ! " $new_ports " =~ " $port " ]]; then
          nft delete rule inet filter input handle "$handle" 2>/dev/null
          log "删除旧 SSH 规则: 端口 $port (handle $handle)"
        fi
      done

  # 第三步:同步基础规则文件(供重启后加载)
  write_rule_file "$new_ports"

  print_info "SSH 端口规则已安全更新为: $new_ports"
  log "SSH 端口规则安全同步: $new_ports"
}

# =========================
# 首次初始化
# =========================
if [[ ! -f "$INIT_FLAG" ]]; then
  print_info "首次运行,正在初始化 nftables..."

  mkdir -p "$NFT_DIR"
  SSH_PORTS="$(get_current_ssh_ports)"
  write_rule_file "$SSH_PORTS"
  : > "$NFT_DYN_FILE"                       # 初始无动态端口
  generate_systemd_service

  loading "正在加载 nftables 规则..."
  safe_nft_load || print_error "首次加载规则失败,请检查 $NFT_RULE_FILE"

  touch "$INIT_FLAG"
  print_info "初始化完成,SSH 端口已设置为: $SSH_PORTS"
fi

# =========================
# nftables 工具函数
# =========================
get_port_handles() {
  local port="$1"
  nft -a list chain inet filter input 2>/dev/null \
    | grep -E "dport $port " \
    | awk -F'# handle ' '{print $2}'
}

rule_exists() {
  local proto="$1" port="$2"
  nft list chain inet filter input 2>/dev/null | grep -qE "${proto} dport ${port} accept"
}

open_port() {
  local port="$1" changed=0
  valid_port "$port" || { print_error "无效端口号: $port"; return 1; }

  if ! rule_exists tcp "$port"; then
    nft add rule inet filter input tcp dport "$port" accept 2>/dev/null && changed=1
  fi
  if ! rule_exists udp "$port"; then
    nft add rule inet filter input udp dport "$port" accept 2>/dev/null && changed=1
  fi

  [[ "$changed" == 1 ]] && persist_dynamic_ports
  log "开放端口: $port (TCP/UDP)"
}

close_port() {
  local port="$1" h handles
  valid_port "$port" || { print_error "无效端口号: $port"; return 1; }

  # 防锁死:禁止关闭当前 SSH 监听端口
  if [[ " $(get_current_ssh_ports) " == *" $port "* ]]; then
    print_error "端口 $port 是当前 SSH 监听端口,禁止关闭(防锁死)"
    return 1
  fi

  handles="$(get_port_handles "$port")"
  if [[ -z "$handles" ]]; then
    print_error "端口 $port 没有可删除的规则"
    return 1
  fi

  for h in $handles; do
    nft delete rule inet filter input handle "$h" 2>/dev/null || true
  done

  persist_dynamic_ports
  log "关闭端口: $port (TCP/UDP)"
}

open_port_range() {
  local start end p proto existing_rules
  if [[ ! "$1" =~ ^[0-9]+-[0-9]+$ ]]; then
    print_error "无效端口范围: $1 (示例 5000-6000)"
    return 1
  fi
  start="$(echo "$1" | cut -d'-' -f1)"
  end="$(echo "$1" | cut -d'-' -f2)"
  if ! valid_port "$start" || ! valid_port "$end" || (( start > end )); then
    print_error "无效端口范围: $1 (示例 5000-6000)"
    return 1
  fi

  existing_rules="$(nft list chain inet filter input 2>/dev/null)"
  for ((p=start; p<=end; p++)); do
    for proto in tcp udp; do
      if ! grep -qE "${proto} dport ${p} accept" <<< "$existing_rules"; then
        nft add rule inet filter input "$proto" dport "$p" accept 2>/dev/null || true
      fi
    done
  done

  persist_dynamic_ports
  log "开放端口范围: $start-$end"
}

close_port_range() {
  local start end p h handles
  if [[ ! "$1" =~ ^[0-9]+-[0-9]+$ ]]; then
    print_error "无效端口范围: $1 (示例 5000-6000)"
    return 1
  fi
  start="$(echo "$1" | cut -d'-' -f1)"
  end="$(echo "$1" | cut -d'-' -f2)"
  if ! valid_port "$start" || ! valid_port "$end" || (( start > end )); then
    print_error "无效端口范围: $1 (示例 5000-6000)"
    return 1
  fi

  for ((p=start; p<=end; p++)); do
    # 跳过 SSH 监听端口(防锁死)
    if [[ " $(get_current_ssh_ports) " == *" $p "* ]]; then
      print_warn "跳过 SSH 端口 $p (防锁死)"
      continue
    fi
    handles="$(get_port_handles "$p")"
    for h in $handles; do
      nft delete rule inet filter input handle "$h" 2>/dev/null || true
    done
  done

  persist_dynamic_ports
  log "关闭端口范围: $start-$end"
}

check_port_open() {
  local port="$1"
  valid_port "$port" || { print_error "无效端口号: $port"; return 1; }
  if nft list chain inet filter input 2>/dev/null | grep -q "dport $port "; then
    print_info "端口 $port 已开放"
  else
    print_error "端口 $port 未开放"
  fi
}

check_port_usage() {
  local port="$1" occupy
  valid_port "$port" || { print_error "无效端口号: $port"; return 1; }
  occupy="$(ss -tulnp 2>/dev/null | grep ":$port " | awk '{print $NF}' | sed 's/users://g' | sed 's/\"//g')"
  if [[ -n "$occupy" ]]; then
    print_info "端口 $port 被占用: $occupy"
  else
    print_error "端口 $port 未被任何程序占用"
  fi
}

# =========================
# 端口管理子菜单
# =========================
port_menu() {
  while true; do
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════╗"
    echo "║            端口管理子菜单            ║"
    echo "╠══════════════════════════════════════╣"
    echo -e "║ ${BLUE}1)${RESET} 开放单个端口(TCP+UDP)"
    echo -e "║ ${BLUE}2)${RESET} 关闭单个端口(TCP+UDP)"
    echo -e "║ ${BLUE}3)${RESET} 开放端口范围"
    echo -e "║ ${BLUE}4)${RESET} 关闭端口范围"
    echo -e "║ ${BLUE}5)${RESET} 检查端口是否开放"
    echo -e "║ ${BLUE}6)${RESET} 检查端口占用情况"
    echo -e "║ ${BLUE}0)${RESET} 返回主菜单"
    echo "╚══════════════════════════════════════╝"
    echo -e "${RESET}"

    read -r -p "请选择操作:" sub || break

    case "$sub" in
      0) break ;;
      1)
        read -r -p "请输入端口号: " port
        loading "正在开放端口..."
        open_port "$port" && print_info "已开放端口 $port"
        ;;
      2)
        read -r -p "请输入端口号: " port
        loading "正在关闭端口..."
        close_port "$port" && print_info "已关闭端口 $port"
        ;;
      3)
        read -r -p "请输入端口范围(如 5000-6000): " range
        loading "正在开放端口范围..."
        open_port_range "$range" && print_info "已开放端口范围 $range"
        ;;
      4)
        read -r -p "请输入端口范围(如 5000-6000): " range
        loading "正在关闭端口范围..."
        close_port_range "$range" && print_info "已关闭端口范围 $range"
        ;;
      5)
        read -r -p "请输入端口号: " port
        check_port_open "$port"
        ;;
      6)
        read -r -p "请输入端口号: " port
        check_port_usage "$port"
        ;;
      *) print_error "无效选择" ;;
    esac
  done
}

# =========================
# Web 服务管理(Nginx / Caddy)
# =========================
web_service_menu() {
  echo -e "${CYAN}╔══════════════════════════════════════╗"
  echo -e "║          Web 服务管理(Nginx/Caddy) ║"
  echo -e "╠══════════════════════════════════════╣${RESET}"

  if systemctl is-active --quiet nginx 2>/dev/null; then
    echo -e "║ Nginx 状态:${GREEN}运行中${RESET}"
  else
    echo -e "║ Nginx 状态:${RED}未运行${RESET}"
  fi

  if systemctl is-active --quiet caddy 2>/dev/null; then
    echo -e "║ Caddy 状态:${GREEN}运行中${RESET}"
  else
    echo -e "║ Caddy 状态:${RED}未运行${RESET}"
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

  read -r -p "请选择操作:" webop || return

  case "$webop" in
    1) loading "正在启动 Nginx..."; systemctl start nginx 2>/dev/null || print_error "启动失败" ;;
    2) loading "正在停止 Nginx..."; systemctl stop nginx 2>/dev/null || print_error "停止失败" ;;
    3) loading "正在重载 Nginx..."; systemctl reload nginx 2>/dev/null || print_error "重载失败" ;;
    4) loading "正在启动 Caddy..."; systemctl start caddy 2>/dev/null || print_error "启动失败" ;;
    5) loading "正在停止 Caddy..."; systemctl stop caddy 2>/dev/null || print_error "停止失败" ;;
    6) loading "正在重载 Caddy..."; systemctl reload caddy 2>/dev/null || print_error "重载失败" ;;
    0) ;;
    *) print_error "无效选择" ;;
  esac
}

# =========================
# 美化后的端口列表
# =========================
show_open_ports() {
  echo -e "${CYAN}╔══════════════════════════════════════════════╗"
  echo -e "║   协议    端口        占用状态                ║"
  echo -e "╠══════════════════════════════════════════════╣${RESET}"

  nft list chain inet filter input 2>/dev/null \
    | grep dport \
    | while read -r line; do
        proto="$(echo "$line" | grep -oE '(tcp|udp)' || true)"
        port="$(echo "$line" | grep -oE 'dport [0-9]+' | awk '{print $2}' || true)"
        [[ -z "$port" ]] && continue

        occupy="$(ss -tulnp 2>/dev/null | grep ":$port " | awk '{print $NF}' | sed 's/users://g' | sed 's/\"//g')"
        [[ -z "$occupy" ]] && occupy="未占用"

        [[ "$proto" == "tcp" ]] && COLOR="${BLUE}" || COLOR="${MAGENTA}"
        printf "║  ${COLOR}%-4s${RESET}   %-6s   %-20s ║\n" "$proto" "$port" "$occupy"
      done

  local total
  total="$(nft list chain inet filter input 2>/dev/null | grep -cE 'dport [0-9]+ accept' || true)"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${RESET}"
  print_info "当前输入链共 $total 条端口放行规则"
}

# =========================
# 自动开放所有被程序占用的端口
# =========================
auto_open_used_ports() {
  echo -e "${CYAN}╔════════════════════════════════════════════════╗"
  echo -e "║        自动开放所有被程序占用的端口(TCP/UDP)   ║"
  echo -e "╠════════════════════════════════════════════════╣${RESET}"

  ss -tulnp 2>/dev/null | tail -n +2 | while read -r line; do
    proto="$(echo "$line" | awk '{print $1}')"
    local_addr="$(echo "$line" | awk '{print $5}')"
    process="$(echo "$line" | awk '{print $NF}' | sed 's/users://g' | sed 's/\"//g')"
    port="$(echo "$local_addr" | sed 's/.*://')"

    [[ "$port" =~ ^[0-9]+$ ]] || continue
    [[ "$local_addr" == 127.0.0.1* ]] && continue
    [[ "$local_addr" == ::1* ]] && continue
    [[ "$process" == *docker* ]] && continue

    if [[ "$proto" == "tcp" ]] && ! rule_exists tcp "$port"; then
      nft add rule inet filter input tcp dport "$port" accept 2>/dev/null || true
    elif [[ "$proto" == "udp" ]] && ! rule_exists udp "$port"; then
      nft add rule inet filter input udp dport "$port" accept 2>/dev/null || true
    fi

    printf "║ 已开放端口 %-6s 协议 %-4s 进程 %-20s ║\n" "$port" "$proto" "$process"
  done

  echo -e "${CYAN}╚════════════════════════════════════════════════╝${RESET}"
  persist_dynamic_ports
  print_info "所有被程序占用的端口已自动开放,并已持久化(重启后保留)"
}

# =========================
# 查看日志
# =========================
show_logs() {
  print_info "显示最新 50 行日志:"
  tail -n 50 "$LOG_FILE" 2>/dev/null || print_error "暂无日志"
}

# =========================
# 清空规则(保留 SSH + 基础网络,同时清空动态端口)
# =========================
reset_rules() {
  print_error "你确定要清空所有动态规则吗?(YES 确认)"
  read -r confirm || return
  if [[ "${confirm^^}" != "YES" ]]; then
    print_info "取消操作"
    return
  fi

  loading "正在重置规则..."
  local ssh_ports
  ssh_ports="$(get_current_ssh_ports)"
  write_rule_file "$ssh_ports"
  : > "$NFT_DYN_FILE"                        # 清空动态端口文件
  safe_nft_load || print_error "重载规则失败"

  print_info "所有动态规则已清空,SSH 端口 ($ssh_ports) 及基础网络已保留"
  log "规则已重置,SSH 端口: $ssh_ports"
}

# =========================
# 备份规则(基础 + 动态)
# =========================
backup_rules() {
  local backup="/etc/nftables.d/backup_$(date '+%Y%m%d_%H%M%S').nft"
  cp "$NFT_RULE_FILE" "$backup" 2>/dev/null || {
    print_error "备份失败,检查 $NFT_RULE_FILE 是否存在"
    return
  }
  cp "$NFT_DYN_FILE" "$backup.dyn" 2>/dev/null || true
  print_info "规则已备份到:$backup (含动态端口)"
  log "备份规则到 $backup"
}

# =========================
# 恢复规则(基础 + 动态)
# =========================
restore_rules() {
  echo -e "${CYAN}可用备份文件:${RESET}"
  ls -1 /etc/nftables.d/backup_*.nft 2>/dev/null || {
    print_error "没有找到任何备份文件"
    return
  }

  read -r -p "请输入要恢复的文件路径:" file || return
  if [[ ! -f "$file" ]]; then
    print_error "文件不存在"
    return
  fi

  cp "$file" "$NFT_RULE_FILE" 2>/dev/null || {
    print_error "复制失败"
    return
  }
  if [[ -f "$file.dyn" ]]; then
    cp "$file.dyn" "$NFT_DYN_FILE" 2>/dev/null || true
  else
    : > "$NFT_DYN_FILE"
  fi
  safe_nft_load || print_error "加载恢复规则失败"

  print_info "规则已从备份恢复"
  log "从备份恢复规则:$file"
}

# =========================
# 删除 nftables(卸载 / 清除 / 禁用)
# =========================
delete_nftables() {
  echo -e "${CYAN}╔══════════════════════════════════════════════╗"
  echo -e "║                删除 nftables 防火墙           ║"
  echo -e "╠══════════════════════════════════════════════╣${RESET}"
  echo -e "此操作将:"
  echo -e " - 停止 nftables 服务"
  echo -e " - 禁用 nftables 服务"
  echo -e " - 删除规则文件:/etc/nftables.d/ufw-panel.nft"
  echo -e " - 删除动态端口文件:/etc/nftables.d/zz-ufw-panel-dynamic.nft"
  echo -e " - 删除初始化标记:/etc/nftables.d/.nft_panel_initialized"
  echo -e " - 删除 systemd 服务:nftables-ufw-panel.service"
  echo -e " - 可选:卸载 nftables 包"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${RESET}"

  read -r -p "确认删除 nftables?输入 YES 执行:" confirm || return
  [[ "${confirm^^}" != "YES" ]] && { print_info "取消操作"; return; }

  print_info "停止 nftables 服务..."
  systemctl stop nftables 2>/dev/null || true
  systemctl stop nftables-ufw-panel.service 2>/dev/null || true

  print_info "禁用 nftables 服务..."
  systemctl disable nftables 2>/dev/null || true
  systemctl disable nftables-ufw-panel.service 2>/dev/null || true

  print_info "删除规则文件..."
  rm -f /etc/nftables.d/ufw-panel.nft 2>/dev/null || true
  rm -f /etc/nftables.d/zz-ufw-panel-dynamic.nft 2>/dev/null || true
  rm -f /etc/nftables.d/.nft_panel_initialized 2>/dev/null || true

  print_info "删除 systemd 服务..."
  rm -f /etc/systemd/system/nftables-ufw-panel.service 2>/dev/null || true
  systemctl daemon-reload || true

  echo
  echo -e "${YELLOW}是否卸载 nftables 包?${RESET}"
  echo -e "1) 卸载"
  echo -e "2) 保留"
  read -r -p "选择:" uninstall || true

  case "$uninstall" in
    1)
      print_info "正在卸载 nftables 包..."
      if command -v apt >/dev/null 2>&1; then
        apt remove -y nftables 2>/dev/null || true
      elif command -v yum >/dev/null 2>&1; then
        yum remove -y nftables 2>/dev/null || true
      elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y nftables 2>/dev/null || true
      fi
      ;;
    *)
      print_info "保留 nftables 包"
      ;;
  esac

  print_info "nftables 已彻底删除"
}

# =========================
# 主菜单
# =========================
while true; do
  # 每次循环检查 SSH 端口一致性(仅警告)
  current_rules_ports="$(get_rules_ssh_ports)"
  actual_ports="$(get_current_ssh_ports)"
  display_rules="${current_rules_ports:-无}"
  if [[ "$current_rules_ports" != "$actual_ports" ]]; then
    print_warn "检测到 SSH 端口不一致!规则中: $display_rules, 实际监听: $actual_ports"
    echo -e "   请使用主菜单选项 ${BLUE}12${RESET} 同步 SSH 端口规则"
  fi

  RAW_STATUS="$(systemctl is-active "$(basename "$NFT_SERVICE")" 2>/dev/null || true)"

  if [[ "$RAW_STATUS" == "active" ]]; then
    STATUS_TEXT="防火墙状态:已启用"
    STATUS_COLOR="${GREEN}"
    TOGGLE_TEXT="关闭防火墙"
    TOGGLE_ACTION="stop"
  else
    STATUS_TEXT="防火墙状态:未启用"
    STATUS_COLOR="${RED}"
    TOGGLE_TEXT="启动防火墙"
    TOGGLE_ACTION="start"
  fi

  PANEL_WIDTH=48
  STATUS_LEN="$(echo -n "$STATUS_TEXT" | wc -c)"
  LEFT_PAD=$(( (PANEL_WIDTH - STATUS_LEN) / 2 ))
  PADDED_STATUS="$(printf "%*s%s" "$LEFT_PAD" "" "$STATUS_TEXT")"

  echo -e "${BOLD}${GRAD1}╔════════════════════════════════════════════════╗"
  echo -e "${GRAD2}║           nftables 防火墙管理面板 v9.1         ║"
  echo -e "${GRAD3}╠════════════════════════════════════════════════╣${RESET}"
  echo -e "║${STATUS_COLOR}${PADDED_STATUS}${RESET}║"
  echo "╠════════════════════════════════════════════════╣"
  echo -e "║ ${BLUE}0)${RESET} 退出"
  echo -e "║ ${BLUE}1)${RESET} 开放关闭端口管理"
  echo -e "║ ${BLUE}2)${RESET} 查看当前已开放端口"
  echo -e "║ ${BLUE}3)${RESET} 查看防火墙日志"
  echo -e "║ ${BLUE}4)${RESET} 清空所有动态规则(保留 SSH)"
  echo -e "║ ${BLUE}5)${RESET} ${TOGGLE_TEXT}"
  echo -e "║ ${BLUE}6)${RESET} 查看端口占用情况"
  echo -e "║ ${BLUE}7)${RESET} 备份规则"
  echo -e "║ ${BLUE}8)${RESET} 恢复规则"
  echo -e "║ ${BLUE}9)${RESET} Web 服务管理(Nginx/Caddy)"
  echo -e "║ ${BLUE}10)${RESET} 自动开放所有被程序占用的端口"
  echo -e "║ ${BLUE}11)${RESET} 删除 nftables(卸载/清除)"
  echo -e "║ ${BLUE}12)${RESET} 同步 SSH 端口规则(解决改端口问题)"
  echo "╚════════════════════════════════════════════════╝"

  read -r -p "请选择操作:" choice || { echo; exit 0; }

  case "$choice" in
    0) print_info "退出脚本"; exit 0 ;;
    1) port_menu ;;
    2) show_open_ports ;;
    3) show_logs ;;
    4) reset_rules ;;
    5)
      if [[ "$TOGGLE_ACTION" == "start" ]]; then
        loading "正在启动防火墙..."
        systemctl start "$(basename "$NFT_SERVICE")" 2>/dev/null || print_error "启动失败"
        print_info "防火墙已启用"
      else
        loading "正在关闭防火墙..."
        systemctl stop "$(basename "$NFT_SERVICE")" 2>/dev/null || print_error "关闭失败"
        print_info "防火墙已禁用"
      fi
      ;;
    6)
      echo -e "${CYAN}╔════════════════════════════════════════════════╗"
      echo -e "║            查看端口占用情况(应用 → 端口)       ║"
      echo -e "╠════════════════════════════════════════════════╣${RESET}"

      ss -tulnp 2>/dev/null | tail -n +2 | while read -r line; do
        proto="$(echo "$line" | awk '{print $1}')"
        local_addr="$(echo "$line" | awk '{print $5}')"
        process="$(echo "$line" | awk '{print $NF}' | sed 's/users://g' | sed 's/\"//g')"
        port="$(echo "$local_addr" | sed 's/.*://')"

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
    11) delete_nftables ;;
    12) sync_ssh_ports ;;
    *) print_error "无效选择" ;;
  esac
done
