#!/usr/bin/env bash
set -e

# ============================
# 基础路径
# ============================
WORKDIR="/root/argo_token"
BIN="$WORKDIR/cloudflared"
TOKEN_INFO="$WORKDIR/token_tunnel.txt"

mkdir -p "$WORKDIR"

# ============================
# 颜色
# ============================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[36m"
NC="\033[0m"

line(){ echo -e "${BLUE}----------------------------------------${NC}"; }
title(){ echo -e "${GREEN}$1${NC}"; line; }

# ============================
# cloudflared 自动检测
# ============================
check_cloudflared(){
    if [[ ! -f "$BIN" ]]; then
        echo -e "${YELLOW}cloudflared 不存在，正在下载...${NC}"
        wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x "$BIN"
    fi

    if ! "$BIN" --version >/dev/null 2>&1; then
        echo -e "${RED}cloudflared 文件损坏，重新下载...${NC}"
        rm -f "$BIN"
        wget -qO "$BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x "$BIN"
    fi
}

# ============================
# 创建 Token 模式固定隧道
# ============================
create_token_tunnel(){
    check_cloudflared
    title "创建 Token 模式固定隧道"

    read -p "请输入 Cloudflare Argo Token: " TOKEN
    [[ -z "$TOKEN" ]] && echo -e "${RED}Token 不能为空${NC}" && return

cat > /etc/systemd/system/argo-token.service <<EOF
[Unit]
Description=Argo Tunnel Token Mode
After=network.target

[Service]
ExecStart=$BIN tunnel run --token $TOKEN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "$TOKEN" > "$TOKEN_INFO"

systemctl daemon-reload
systemctl enable argo-token
systemctl restart argo-token

echo -e "${GREEN}Token 模式固定隧道已启动${NC}"
echo "Token：$TOKEN"
}

# ============================
# 自动诊断 + 自动修复（手动）
# ============================
heal_token_manual(){
    if [[ ! -f "$TOKEN_INFO" ]]; then
        echo -e "${RED}未创建 Token 模式隧道${NC}"
        return
    fi

    echo -e "${BLUE}检测 Token 隧道状态...${NC}"

    if systemctl is-active --quiet argo-token; then
        echo -e "${GREEN}Token 隧道正在运行${NC}"
        return
    fi

    echo -e "${RED}Token 隧道未运行，正在自动修复...${NC}"

    systemctl restart argo-token
    sleep 2

    if systemctl is-active --quiet argo-token; then
        echo -e "${GREEN}修复成功，Token 隧道已恢复运行${NC}"
    else
        echo -e "${RED}修复失败，Token 隧道仍未运行${NC}"
    fi
}

# ============================
# systemd 自动修复
# ============================
generate_token_health_script(){
cat > "$WORKDIR/token_health.sh" <<'EOF'
#!/usr/bin/env bash

if ! systemctl is-active --quiet argo-token; then
    systemctl restart argo-token
fi
EOF

chmod +x "$WORKDIR/token_health.sh"
}

install_token_health_timer(){
cat > /etc/systemd/system/argo-token-health.service <<EOF
[Unit]
Description=自动修复 Token 模式隧道

[Service]
Type=oneshot
ExecStart=/bin/bash $WORKDIR/token_health.sh
EOF

cat > /etc/systemd/system/argo-token-health.timer <<EOF
[Unit]
Description=每 5 分钟自动修复 Token 模式隧道

[Timer]
OnBootSec=30
OnUnitActiveSec=300

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable argo-token-health.timer
systemctl start argo-token-health.timer
}

# ============================
# 删除 Token 隧道
# ============================
delete_token_tunnel(){
    echo -e "${YELLOW}确认删除 Token 模式隧道？(YES 删除)${NC}"
    read -p "> " C
    [[ "$C" != "YES" ]] && echo "已取消" && return

    systemctl stop argo-token 2>/dev/null
    systemctl disable argo-token 2>/dev/null
    rm -f /etc/systemd/system/argo-token.service

    rm -f "$TOKEN_INFO"

    echo -e "${GREEN}Token 模式隧道已删除${NC}"
}

# ============================
# 菜单
# ============================
menu(){
    while true; do
        title "固定隧道（Token 模式）独立管理"

        if [[ -f "$TOKEN_INFO" ]]; then
            read TOKEN < "$TOKEN_INFO"
            echo -e "状态：${GREEN}已创建${NC}"
            echo "Token：$TOKEN"
        else
            echo -e "状态：${RED}未创建${NC}"
        fi

        echo
        echo "1) 创建 Token 模式隧道"
        echo "2) 重启 Token 模式隧道"
        echo "3) 停止 Token 模式隧道"
        echo "4) 删除 Token 模式隧道"
        echo "5) 手动诊断并自动修复"
        echo "0) 退出"
        read -p "选择: " CH

        case $CH in
            1) create_token_tunnel ;;
            2) systemctl restart argo-token ;;
            3) systemctl stop argo-token ;;
            4) delete_token_tunnel ;;
            5) heal_token_manual ;;
            0) exit 0 ;;
        esac
    done
}

# ============================
# 启动入口
# ============================
generate_token_health_script
install_token_health_timer
menu
