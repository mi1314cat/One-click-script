#!/usr/bin/env bash
set -euo pipefail

# ========= 基本路径 =========
BASE_DIR="/root/catmi/cfd"
BIN_DIR="${BASE_DIR}/bin"
WORK_DIR="${BASE_DIR}/work"
LOG_DIR="${BASE_DIR}/logs"
HOSTS_BAK="${BASE_DIR}/hosts.bak"
CONFIG_FILE="${BASE_DIR}/config"
PARAM_FILE="${BASE_DIR}/params"
SERVICE="/etc/systemd/system/catmi-cfd.service"
CFD_PORT=9666
INTERVAL="30s"

# ========= 仓库配置 =========
REPO_MAIN="mi1314cat/cfd_return"
REPO_FALLBACK="fscarmen/cfd_return"

# ========= 颜色 =========
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; BLUE="\033[1;34m"; RESET="\033[0m"

info(){ echo -e "${BLUE}[信息]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[警告]${RESET} $*"; }
err(){ echo -e "${RED}[错误]${RESET} $*" >&2; }

# ========= 架构检测 =========
arch(){
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7*|armv6*) echo arm ;;
    *) echo amd64 ;;
  esac
}

# ========= 智能下载逻辑 =========

smart_download(){
  local file="$1"
  local out="$2"

  # 你的仓库优先
  local urls_main=(
    "https://raw.githubusercontent.com/${REPO_MAIN}/main/cfd/${file}"
    "https://cdn.jsdelivr.net/gh/${REPO_MAIN}/cfd/${file}"
    "https://ghproxy.net/https://raw.githubusercontent.com/${REPO_MAIN}/main/cfd/${file}"
  )

  # 原作者仓库
  local urls_fallback=(
    "https://raw.githubusercontent.com/${REPO_FALLBACK}/main/cfd/${file}"
    "https://cdn.jsdelivr.net/gh/${REPO_FALLBACK}/cfd/${file}"
    "https://ghproxy.net/https://raw.githubusercontent.com/${REPO_FALLBACK}/main/cfd/${file}"
  )

  info "正在尝试从你的仓库下载：${REPO_MAIN} ..."
  for u in "${urls_main[@]}"; do
    info "尝试：$u"
    if curl -fsSL "$u" -o "$out"; then
      chmod +x "$out"
      info "下载成功：$u"
      return 0
    fi
  done

  warn "你的仓库下载失败，切换到原作者仓库：${REPO_FALLBACK} ..."
  for u in "${urls_fallback[@]}"; do
    info "尝试：$u"
    if curl -fsSL "$u" -o "$out"; then
      chmod +x "$out"
      info "下载成功：$u"
      return 0
    fi
  done

  err "所有下载源均失败：${file}"
  exit 1
}


install_binary(){
  local name="$1" a="$2"
  local file=""

  if [ "$name" = "cfd" ]; then
    file="cfd-linux-${a}"
  else
    file="cfd-tls-linux-${a}"
  fi

  mkdir -p "$BIN_DIR"
  smart_download "$file" "${BIN_DIR}/${name}"
}

# ========= hosts 备份 / 恢复 =========

backup_hosts(){
  cp /etc/hosts "$HOSTS_BAK"
  info "已备份 hosts → $HOSTS_BAK"
}

restore_hosts(){
  if [ -f "$HOSTS_BAK" ]; then
    cp "$HOSTS_BAK" /etc/hosts
    info "已恢复 hosts"
  else
    warn "没有 hosts 备份文件"
  fi
}

# ========= IP 列表生成 =========

gen_ip(){
  mkdir -p "$WORK_DIR"
  curl -fsSL https://cdn.jsdelivr.net/gh/fscarmen/cfd_return/cfd/ip.txt \
    -o "${WORK_DIR}/ip_raw" || echo "" > "${WORK_DIR}/ip_raw"

  awk 'NF && $1 !~ /^#/ {print $1}' "${WORK_DIR}/ip_raw" > "${WORK_DIR}/ip"
  info "已生成 IP 列表：${WORK_DIR}/ip"
}

# ========= 参数调试菜单 =========

PARAM_MIN=150
PARAM_MAX=300
PARAM_MULTI=false
PARAM_NUM=10
PARAM_TASK=100

load_params(){
  [ -f "$PARAM_FILE" ] && . "$PARAM_FILE"
}

save_params(){
  cat > "$PARAM_FILE" <<EOF
PARAM_MIN=${PARAM_MIN}
PARAM_MAX=${PARAM_MAX}
PARAM_MULTI=${PARAM_MULTI}
PARAM_NUM=${PARAM_NUM}
PARAM_TASK=${PARAM_TASK}
EOF
}

apply_params(){
  save_params
  write_unit
  systemctl restart catmi-cfd.service
  info "参数已应用并自动重启服务"
}

param_menu(){
  load_params

  while true; do
    clear
    echo "========== CFD 参数调试 =========="
    echo "当前参数："
    echo "  1) min      = ${PARAM_MIN}"
    echo "  2) max      = ${PARAM_MAX}"
    echo "  3) multi    = ${PARAM_MULTI}"
    echo "  4) num      = ${PARAM_NUM}"
    echo "  5) task     = ${PARAM_TASK}"
    echo "----------------------------------"
    echo "  6) 应用参数（自动重启服务）"
    echo "  0) 返回主菜单"
    echo "=================================="
    read -rp "选择要修改的参数: " p

    case "$p" in
      1)
        read -rp "输入新的 min（回车默认 ${PARAM_MIN}）: " v
        [[ -n "$v" ]] && PARAM_MIN="$v"
        save_params
        ;;
      2)
        read -rp "输入新的 max（回车默认 ${PARAM_MAX}）: " v
        [[ -n "$v" ]] && PARAM_MAX="$v"
        save_params
        ;;
      3)
        read -rp "multi？(true/false，回车默认 ${PARAM_MULTI}): " v
        case "$v" in
          true|false) PARAM_MULTI="$v" ;;
          "") ;;
          *) warn "必须是 true 或 false" ;;
        esac
        save_params
        ;;
      4)
        read -rp "num（最大 50，回车默认 ${PARAM_NUM}）: " v
        if [[ -n "$v" ]]; then
          (( v > 50 )) && v=50
          PARAM_NUM="$v"
        fi
        save_params
        ;;
      5)
        read -rp "task（最大 200，回车默认 ${PARAM_TASK}）: " v
        if [[ -n "$v" ]]; then
          (( v > 200 )) && v=200
          PARAM_TASK="$v"
        fi
        save_params
        ;;
      6)
        apply_params
        ;;
      0)
        return
        ;;
      *)
        warn "无效选择"
        ;;
    esac
  done
}

# ========= 当前选择的二进制 =========

get_selected(){
  [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
  echo "${selected:-cfd}"
}

# ========= 写入 systemd unit =========

write_unit(){
  local sel; sel=$(get_selected)
  load_params

  CFD_ARGS="-min ${PARAM_MIN} -max ${PARAM_MAX} -multi=${PARAM_MULTI} -num ${PARAM_NUM} -task ${PARAM_TASK}"

  if [ "$sel" = "cfd" ]; then
    cat > "$SERVICE" <<EOF
[Unit]
Description=Catmi CFD Service
After=network.target

[Service]
ExecStart=${BIN_DIR}/cfd -file ${WORK_DIR}/ip ${CFD_ARGS}
WorkingDirectory=${WORK_DIR}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  else
    cat > "$SERVICE" <<EOF
[Unit]
Description=Catmi CFD-TLS Service
After=network.target

[Service]
ExecStart=${BIN_DIR}/cfd-tls -l :443 -r 127.0.0.1:${CFD_PORT}
WorkingDirectory=${WORK_DIR}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  fi

  systemctl daemon-reload
  systemctl enable --now catmi-cfd.service
}

# ========= 安装流程 =========

install_flow(){
  mkdir -p "$BIN_DIR" "$WORK_DIR" "$LOG_DIR"

  backup_hosts

  local a; a=$(arch)

  echo "选择安装版本："
  echo "1) cfd（IP 优选器）"
  echo "2) cfd-tls（TLS 转发器）"
  read -rp "选择 [1]: " sel
  sel="${sel:-1}"

  if [ "$sel" = "2" ]; then
    echo "selected=cfd-tls" > "$CONFIG_FILE"
    install_binary "cfd-tls" "$a"
  else
    echo "selected=cfd" > "$CONFIG_FILE"
    install_binary "cfd" "$a"
  fi

  save_params
  gen_ip
  write_unit

  info "安装完成！当前使用：$(get_selected)"
}

# ========= 切换二进制 =========

switch_bin(){
  local cur new a
  cur=$(get_selected)

  echo "当前：$cur"
  echo "1) 切换到 cfd"
  echo "2) 切换到 cfd-tls"
  read -rp "选择 [1]: " sel
  sel="${sel:-1}"

  if [ "$sel" = "2" ]; then new="cfd-tls"; else new="cfd"; fi
  [ "$new" = "$cur" ] && { warn "已经是 $new"; return; }

  a=$(arch)
  install_binary "$new" "$a"
  echo "selected=${new}" > "$CONFIG_FILE"

  write_unit
  systemctl restart catmi-cfd.service

  info "已切换为 ${new}"
}

# ========= 停止 / 卸载 =========

stop_service(){
  systemctl stop catmi-cfd.service || true
  read -rp "是否恢复 hosts？[y/N]: " a
  [[ "$a" =~ [Yy] ]] && restore_hosts
}

uninstall(){
  systemctl stop catmi-cfd.service || true
  systemctl disable catmi-cfd.service || true
  rm -f "$SERVICE"
  systemctl daemon-reload

  restore_hosts
  rm -rf "$BASE_DIR"

  info "卸载完成"
}

# ========= 状态显示 =========

status(){
  if systemctl is-active --quiet catmi-cfd.service; then
    echo -e "${GREEN}● 运行中${RESET}"
  else
    echo -e "${RED}● 已停止${RESET}"
  fi
}

# ========= 主菜单 =========

while true; do
  clear
  echo -e "服务状态：$(status)    当前二进制：$(get_selected)    端口：${CFD_PORT}"
  echo "========================================"
  echo " Catmi CFD — 中文管理面板（智能下载 + 参数调试版）"
  echo " 目录：${BASE_DIR}"
  echo " 服务名：catmi-cfd.service"
  echo "========================================"
  echo " 1) 安装（备份 hosts、下载 cfd/cfd-tls、生成 IP）"
  echo " 2) 启动服务"
  echo " 3) 停止服务（可选择恢复 hosts）"
  echo " 4) 查看状态"
  echo " 5) 查看日志"
  echo " 6) 查看 /etc/hosts"
  echo " 7) 手动备份 hosts"
  echo " 8) 恢复 hosts（从备份）"
  echo " 9) 切换二进制（cfd ↔ cfd-tls）"
  echo "10) 卸载（删除全部并恢复 hosts）"
  echo "11) 参数调试（min/max/multi/num/task）"
  echo " 0) 退出"
  echo "========================================"
  read -rp "请选择操作: " opt

  case "$opt" in
    1) install_flow ;;
    2) systemctl start catmi-cfd.service ;;
    3) stop_service ;;
    4) systemctl status catmi-cfd.service --no-pager ;;
    5) journalctl -u catmi-cfd.service -n 200 --no-pager ;;
    6) cat /etc/hosts ;;
    7) backup_hosts ;;
    8) restore_hosts ;;
    9) switch_bin ;;
    10) uninstall ;;
    11) param_menu ;;
    0) exit 0 ;;
    *) warn "无效选择" ;;
  esac

  echo
  read -rp "按回车返回菜单..." _
done
