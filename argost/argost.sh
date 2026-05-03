#!/usr/bin/env bash
set -e

# ============================================================
#  Gost + Argo 一键安装脚本（服务端 + 客户端）
# ============================================================

BASE_DIR="/root/catmi/gost"
CATMI_ENV="/root/catmi/catmi.env"
ENV_FILE="$BASE_DIR/gost.env"
GOST_BIN="$BASE_DIR/gost"

mkdir -p "$BASE_DIR"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
NC="\033[0m"

# ============================================================
# 工具函数：循环检测端口是否被占用（无污染输出）
# ============================================================
ask_port() {
    local prompt default_port port
    prompt="$1"
    default_port="$2"

    while true; do
        read -p "$prompt（默认 $default_port）: " port
        port=${port:-$default_port}

        if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}端口必须是数字${NC}" >&2
            continue
        fi

        if ss -tuln | grep -q ":$port "; then
            echo -e "${RED}❌ 端口 $port 已被占用，请重新输入${NC}" >&2
        else
            echo -e "${GREEN}✔ 端口可用：$port${NC}" >&2
            printf "%s" "$port"
            return
        fi
    done
}

# ============================================================
# 自动识别架构并下载 gost
# ============================================================
install_gost() {
    echo "⬇️ 正在下载 gost..."

    local ARCH FILE_SUFFIX VERSION API_JSON URL

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)         FILE_SUFFIX="linux_amd64.tar.gz" ;;
        aarch64)        FILE_SUFFIX="linux_arm64.tar.gz" ;;
        armv7l|armhf)   FILE_SUFFIX="linux_armv7.tar.gz" ;;
        *)
            echo "❌ 不支持的架构：$ARCH"
            exit 1
            ;;
    esac

    API_JSON=$(curl -sL https://api.github.com/repos/go-gost/gost/releases/latest)

    if echo "$API_JSON" | grep -q '"browser_download_url"'; then
        URL=$(echo "$API_JSON" | grep browser_download_url | cut -d '"' -f4 | grep "$FILE_SUFFIX" | head -n1)
    else
        VERSION=$(curl -sI https://github.com/go-gost/gost/releases/latest | grep -i '^location:' | sed -E 's#.*tag/v##I' | tr -d '\r')
        URL="https://github.com/go-gost/gost/releases/download/v${VERSION}/gost_${VERSION}_${FILE_SUFFIX}"
    fi

    wget -O /tmp/gost.tar.gz "$URL"
    tar -xzf /tmp/gost.tar.gz -C /tmp
    install -m 755 /tmp/gost "$GOST_BIN"

    echo "✅ gost 安装完成：$GOST_BIN"
}

# ============================================================
# 从 catmi.env 读取变量
# ============================================================
read_from_catmi_env() {
    local key="$1"
    grep "^$key=" "$CATMI_ENV" | head -n 1 | sed "s/^$key=//" | sed 's/^"//;s/"$//'
}

# ============================================================
# 服务端安装（你家 VPS）
# ============================================================
install_server() {
    echo "=============================="
    echo "🟥 进入服务端安装模式（你家 VPS）"
    echo "=============================="

    source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
    source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")

    [ -f "$CATMI_ENV" ] && load_env "$CATMI_ENV"

    gost_port=$(ask_port "请输入本地 gost 服务端端口（仅本地使用）" "20000")
    update_env "$CATMI_ENV" gost_port "$gost_port"

    bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/argo/url_argo.sh)

    uargo_domain=$(read_from_catmi_env "uargo_domain")
    if [ -z "$uargo_domain" ]; then
        echo -e "${RED}catmi.env 中未找到 uargo_domain${NC}"
        exit 1
    fi

    ws_path=$(cat /proc/sys/kernel/random/uuid)

    install_gost

cat > "$ENV_FILE" <<EOF
uargo_domain=$uargo_domain
ws_path=$ws_path
gost_port=$gost_port
EOF

# ============================
# 正确的服务端（relay+ws）
# ============================
cat > /etc/systemd/system/gost-server.service <<EOF
[Unit]
Description=Gost Server (for Argo)
After=network.target

[Service]
Type=simple
ExecStart=$GOST_BIN -D -L relay+ws://127.0.0.1:$gost_port?path=/$ws_path&bind=true
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now gost-server.service

    echo "=============================="
    echo "🎉 服务端安装完成（relay+ws 服务端已启动）"
    echo "=============================="
    echo "本地监听：127.0.0.1:$gost_port"
    echo "Argo 域名：$uargo_domain"
    echo "WS 路径：/$ws_path"
}

# ============================================================
# 客户端安装
# ============================================================
install_client() {
    echo "=============================="
    echo "🟦 进入客户端安装模式"
    echo "=============================="

    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}❌ 未找到 $ENV_FILE${NC}"
        echo "请从服务端复制："
        echo "scp root@服务端IP:/root/catmi/gost/gost.env /root/catmi/gost/gost.env"
        exit 1
    fi

    source "$ENV_FILE"

    # 本地 SOCKS5 端口（仅本机使用）
    socks5_port=$(ask_port "请输入本地 SOCKS5 端口" "20000")

    # RTCP 公网监听端口（你电脑要连的）
    rtcp_port=$(ask_port "请输入本地 RTCP 端口（公网监听）" "30000")

    install_gost

    # ============================
    # 创建 SOCKS5 服务（本地代理）
    # ============================
cat > /etc/systemd/system/gost-socks5.service <<EOF
[Unit]
Description=Gost SOCKS5 Client
After=network.target

[Service]
Type=simple
ExecStart=$GOST_BIN -D -L socks5://127.0.0.1:$socks5_port
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # ============================
    # 创建 RTCP 服务（反向隧道）
    # ============================
cat > /etc/systemd/system/gost-rtcp.service <<EOF
[Unit]
Description=Gost RTCP Client
After=gost-socks5.service

[Service]
Type=simple
ExecStart=${GOST_BIN} -D -L "rtcp://:${rtcp_port}/127.0.0.1:${socks5_port}" -F "relay+wss://${uargo_domain}:443?path=/${WS_PATH}&host=${uargo_domain}"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now gost-socks5.service
    systemctl enable --now gost-rtcp.service

    echo "=============================="
    echo "🎉 客户端安装完成（argost：SOCKS5 + RTCP）"
    echo "=============================="
    echo "SOCKS5 本地端口：127.0.0.1:$socks5_port"
    echo "RTCP 公网端口：$rtcp_port"
    echo "Argo 域名：$uargo_domain"
}


# ============================================================
# 主菜单
# ============================================================
echo "请选择安装模式："
echo "1) 服务端安装（你家 VPS）"
echo "2) 客户端安装（VPS）"
read -p "请输入数字: " mode

case $mode in
    1) install_server ;;
    2) install_client ;;
    *) echo "无效选择" ;;
esac
