#!/bin/bash
# Argo 隧道一键脚本（模块化核心）
# 功能：
#  - 自动识别隧道 UUID
#  - 自动生成 CloudFlare.yml
#  - 自动运行隧道
#  - 自动提取证书
# 默认目录：/root/catmi/xray/argo

BASE_DIR="/root/catmi/xray"
ARGO_DIR="$BASE_DIR/argo"

mkdir -p "$ARGO_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
PLAIN='\033[0m'

info(){ echo -e "${GREEN}[Argo]${PLAIN} $1"; }
err(){ echo -e "${RED}[Argo]${PLAIN} $1"; }

[[ $EUID -ne 0 ]] && { err "必须使用 root 用户运行"; exit 1; }

# -------------------------------
# 端口输入 + 随机 + 占用检测
# -------------------------------
ask_port(){
    local name="$1"
    while true; do
        local random_port=$((RANDOM % 10000 + 10000))
        read -p "请输入 ${name} 监听端口（回车随机）: " port
        port=${port:-$random_port}

        if ss -tuln | grep -q ":$port\b"; then
            err "端口 $port 已被占用，请重新输入"
        else
            echo "$port"
            return
        fi
    done
}

# -------------------------------
# 安装 Cloudflared（如未安装）
# -------------------------------
install_cloudflared(){
    if command -v cloudflared >/dev/null 2>&1; then
        info "已检测到 cloudflared"
        return
    fi

    info "未检测到 cloudflared，开始安装..."
    arch=$(uname -m)
    [[ "$arch" == "aarch64" ]] && arch="arm64"

    ver=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest \
        | grep tag_name | sed -E 's/.*"([^"]+)".*/\1/')

    if [[ -z "$ver" ]]; then
        err "获取 cloudflared 最新版本失败"
        exit 1
    fi

    wget -q -O /usr/local/bin/cloudflared \
        "https://github.com/cloudflare/cloudflared/releases/download/$ver/cloudflared-linux-$arch"

    chmod +x /usr/local/bin/cloudflared
    info "cloudflared 安装完成"
}

# -------------------------------
# 登录 Cloudflare（只需一次）
# -------------------------------
login_cloudflare(){
    if [[ -f /root/.cloudflared/cert.pem ]]; then
        info "已检测到 /root/.cloudflared/cert.pem，跳过登录"
        return
    fi

    info "开始 cloudflared tunnel login（浏览器授权一次）"
    cloudflared tunnel login
    if [[ $? -ne 0 ]]; then
        err "cloudflared 登录失败"
        exit 1
    fi
    info "cloudflared 登录成功"
}

# -------------------------------
# 创建 Argo 隧道 + 自动识别 UUID
# -------------------------------
create_argo_tunnel(){
    local argo_port="$1"

    read -p "请输入隧道名称: " TUNNEL_NAME
    read -p "请输入隧道域名: " TUNNEL_DOMAIN

    if [[ -z "$TUNNEL_NAME" || -z "$TUNNEL_DOMAIN" ]]; then
        err "隧道名称和域名不能为空"
        exit 1
    fi

    info "创建隧道：$TUNNEL_NAME"
    cloudflared tunnel create "$TUNNEL_NAME"

    # 自动识别 UUID
    TUNNEL_UUID=$(cloudflared tunnel list | awk -v name="$TUNNEL_NAME" '$2==name {print $1}' | head -n1)

    if [[ -z "$TUNNEL_UUID" ]]; then
        err "未能自动识别隧道 UUID，请检查 cloudflared tunnel list"
        exit 1
    fi

    info "自动识别隧道 UUID：$TUNNEL_UUID"

cat <<EOF > "$ARGO_DIR/CloudFlare.yml"
tunnel: $TUNNEL_UUID
credentials-file: /root/.cloudflared/$TUNNEL_UUID.json
ingress:
  - hostname: $TUNNEL_DOMAIN
    service: https://localhost:$argo_port
  - service: http_status:404
EOF

    echo "$TUNNEL_DOMAIN" > "$ARGO_DIR/domain.txt"
    echo "$TUNNEL_UUID" > "$ARGO_DIR/uuid.txt"
    echo "$argo_port" > "$ARGO_DIR/argo_port.txt"

    info "CloudFlare.yml 已生成：$ARGO_DIR/CloudFlare.yml"

    # 绑定 DNS
    info "为隧道绑定 DNS 记录：$TUNNEL_DOMAIN"
    cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_DOMAIN"
}

# -------------------------------
# 运行 Argo 隧道
# -------------------------------
run_argo_tunnel(){
    info "启动 Argo 隧道..."
    pkill -f "cloudflared tunnel" >/dev/null 2>&1 || true
    screen -dmS argo cloudflared tunnel --config "$ARGO_DIR/CloudFlare.yml" run
    info "Argo 隧道已在 screen 会话 argo 中运行"
}

# -------------------------------
# 提取 Argo 证书
# -------------------------------
extract_argo_cert(){
    local cert_file="/root/.cloudflared/cert.pem"

    if [[ ! -f "$cert_file" ]]; then
        err "未找到 $cert_file，无法提取证书"
        return
    fi

    sed -n '1,5p' "$cert_file" > "$ARGO_DIR/private.key"
    sed -n '6,24p' "$cert_file" > "$ARGO_DIR/cert.crt"

    info "Argo 证书已提取："
    echo "  私钥：$ARGO_DIR/private.key"
    echo "  证书：$ARGO_DIR/cert.crt"
}

# -------------------------------
# 主流程
# -------------------------------
install_cloudflared
login_cloudflare

argo_port=$(ask_port "Argo 回源端口")

create_argo_tunnel "$argo_port"
run_argo_tunnel
extract_argo_cert

info "Argo 隧道全部流程完成"
