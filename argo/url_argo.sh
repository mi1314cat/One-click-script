#!/usr/bin/env bash
set -e

WORKDIR="/root/argo_file"
BIN="$WORKDIR/cloudflared"
CF_DIR="/root/.cloudflared"
FILE_INFO="$WORKDIR/file_tunnel.txt"
LOG_FILE="$WORKDIR/file.log"

mkdir -p "$WORKDIR" "$CF_DIR"

err(){ echo "[ERR] $1" >&2; }

# ============================================================
# 自动根据 CPU 架构下载 cloudflared
# ============================================================
check_cloudflared(){
    if [[ ! -f "$BIN" ]]; then
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64)
                CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
                ;;
            aarch64)
                CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
                ;;
            armv7l|armhf)
                CFD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
                ;;
            *)
                err "不支持的架构: $ARCH"
                exit 1
                ;;
        esac

        echo "⬇️ 正在下载 cloudflared ($ARCH)..."
        wget -qO "$BIN" "$CFD_URL" || { err "cloudflared 下载失败"; exit 1; }
        chmod +x "$BIN"
    fi

    if ! "$BIN" --version >/dev/null 2>&1; then
        rm -f "$BIN"
        echo "⚠️ cloudflared 文件损坏，重新下载..."
        check_cloudflared
    fi
}

# ============================================================
# 创建 File Mode 隧道（最终稳定版）
# ============================================================
create_file_tunnel(){
    check_cloudflared
    title "创建文件模式固定隧道"

    # 1. login
    if [[ ! -f "$CF_DIR/cert.pem" ]]; then
        echo -e "${YELLOW}未检测到 cert.pem，执行 cloudflared login...${NC}"
        $BIN login || {
            echo -e "${RED}cloudflared login 失败${NC}"
            return
        }
    fi

    # 2. 创建隧道（不解析 OUTPUT）
    TUNNEL_NAME=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
    echo "Tunnel 名称：$TUNNEL_NAME"

    if ! $BIN tunnel create "$TUNNEL_NAME" >/dev/null 2>&1; then
        echo -e "${RED}创建隧道失败${NC}"
        return
    fi

    # 3. 从 JSON 文件名解析 TID（唯一正确方法）
    TID=$(ls -t "$CF_DIR"/*.json 2>/dev/null | head -n 1)
    TID=$(basename "$TID" .json)

    [[ -z "$TID" ]] && {
        echo -e "${RED}无法从 JSON 文件名解析 Tunnel ID${NC}"
        return
    }

    echo -e "🎯 解析到 Tunnel ID：${GREEN}$TID${NC}"

    # 4. 用户输入
    read -p "根域名: " ROOT_DOMAIN
    read -p "本地端口(默认 $xpr): " PORT
    PORT=${PORT:-$xpr}

    DOMAIN="$TUNNEL_NAME.$ROOT_DOMAIN"

    # 5. 写入 config.yml（永远正确）
cat > "$CF_DIR/config.yml" <<EOF
tunnel: $TID
credentials-file: $CF_DIR/$TID.json

ingress:
  - hostname: $DOMAIN
    service: http://localhost:$PORT
  - service: http_status:404
EOF

    echo "📄 已生成配置文件：$CF_DIR/config.yml"

    # 6. systemd
    systemctl daemon-reload
    systemctl enable argo-file >/dev/null 2>&1
    systemctl restart argo-file

    echo "$TID $DOMAIN $PORT" > "$FILE_INFO"

    echo
    echo "🎉 隧道创建成功！请到 Cloudflare DNS 添加："
    echo "$DOMAIN  CNAME  $TID.cfargotunnel.com"
    echo
}


# ============================================================
# 加载 catmi 环境变量
# ============================================================
DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")
load_env "$CATMIENV_FILE"

# ============================================================
# 端口选择逻辑
# ============================================================
if [ -n "$mode" ]; then
    case "$mode" in
        xray)    xpr=9970 ;;
        mihomo)  xpr=9971 ;;
        singbox) xpr=9972 ;;
        *)
            echo "mode 值无效: $mode"
            exit 1
            ;;
    esac
elif [ -n "$gost_port" ]; then
    xpr="$gost_port"
else
    xpr=8080
fi

echo "mode=$mode"
echo "xpr=$xpr"

# ============================================================
# 执行创建隧道
# ============================================================
create_file_tunnel
