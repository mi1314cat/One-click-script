# 定义安装函数
install_package() {
    local package_name="$1"
    if ! dpkg -s "$package_name" >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y "$package_name"
    fi
}

# 定义检查 Cloudflared 安装状态函数
check_cloudflared_status() {
    if cloudflared --version >/dev/null 2>&1; then
        return 0  # 已安装
    else
        return 1  # 未安装
    fi
}

# 定义安装 Cloudflared 函数
install_cloudflared() {
    local last_version
    last_version=$(curl -Ls "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    if [[ -z "$last_version" ]]; then
        print_error "检测 Cloudflared 版本失败，可能是超出 Github API 限制，请稍后再试"
        exit 1
    fi

    local arch="$CORE_ARCH"
    if [[ "$arch" == "aarch64" ]]; then
        arch="arm64"
    fi

    wget -N --no-check-certificate "https://github.com/cloudflare/cloudflared/releases/download/$last_version/cloudflared-linux-$arch" -O /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared

    print_info "Cloudflared 安装成功！"
}

# 定义登录 Cloudflared 函数
login_cloudflared() {
    cloudflared tunnel login
    if [[ $? -eq 0 ]]; then
        print_info "Cloudflared 登录成功！"
    else
        print_error "Cloudflared 登录失败！"
        exit 1
    fi
}

# 定义创建隧道函数
create_tunnel() {
    local tunnel_name="$1"
    local tunnel_domain="$2"
    local tunnel_uuid

    read -p "请设置隧道名称：" tunnel_name
    read -p "请设置隧道域名：" tunnel_domain

    cloudflared tunnel create "$tunnel_name"
    cloudflared tunnel route dns "$tunnel_name" "$tunnel_domain"
    DOMAIN_LOWER=$tunnel_domain
    tunnel_uuid=$(cloudflared tunnel list | grep "$tunnel_name" | awk -F ' ' '{print $1}')
    read -p "请输入隧道 UUID（复制 ID 里面的内容）：" tunnel_uuid

    local tunnel_file_name="CloudFlare"
    local config_file="/root/catmi/$tunnel_file_name.yml"
    tunnelPort=${PORT}
    mkdir -p /root/catmi

    cat <<EOF > "$config_file"
tunnel: $tunnel_name
credentials-file: /root/.cloudflared/$tunnel_uuid.json
originRequest:
  connectTimeout: 30s
  noTLSVerify: true
ingress:
  - hostname: $tunnel_domain
    service: https://localhost:$tunnelPort
  - service: http_status:404
EOF

    print_info "配置文件已保存至 $config_file"
}

# 定义运行隧道函数
run_tunnel() {
    install_package screen
    screen -dmS CloudFlare cloudflared tunnel --config /root/catmi/CloudFlare.yml run
    print_info "隧道已运行成功，请等待1-3分钟启动并解析完毕"
}

# 定义提取 Argo 证书函数
extract_argo_cert() {
    sed -n '1,5p' /root/.cloudflared/cert.pem > /root/catmi/private.key
    sed -n '6,24p' /root/.cloudflared/cert.pem > /root/catmi/cert.crt
    print_info "Argo 证书提取成功！"
    print_info "证书路径：/root/catmi/cert.crt"
    print_info "私钥路径：/root/catmi/private.key"
}


# 提示输入监听端口号
read -p "请输入cf 监听端口 (默认为 443): " PORT
PORT=${PORT:-6666}



mkdir -p /root/catmi
install_package
check_cloudflared_status
install_cloudflared
login_cloudflared
create_tunnel
run_tunnel
extract_argo_cert
