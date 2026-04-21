DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

update_env() {
    local key="$1"
    local value="$2"

    # 校验 key
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        echo "Invalid key: $key"
        return 1
    }

    # 确保目录 & 文件
    mkdir -p "$(dirname "$CATMIENV_FILE")"
    [ -f "$CATMIENV_FILE" ] || touch "$CATMIENV_FILE"

    # 获取权限 & 属主（兼容 Linux / BSD）
    local mode owner group
    if mode=$(stat -c "%a" "$CATMIENV_FILE" 2>/dev/null); then
        owner=$(stat -c "%u" "$CATMIENV_FILE")
        group=$(stat -c "%g" "$CATMIENV_FILE")
    else
        mode=$(stat -f "%Lp" "$CATMIENV_FILE")
        owner=$(stat -f "%u" "$CATMIENV_FILE")
        group=$(stat -f "%g" "$CATMIENV_FILE")
    fi

    # 转义 value
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\$}"

    # 加锁 + 自动释放
    (
        flock 200

        local tmp_file
        tmp_file=$(mktemp "$(dirname "$CATMIENV_FILE")/.env.tmp.XXXXXX")

        # 先设置权限
        chmod "$mode" "$tmp_file"
        chown "$owner":"$group" "$tmp_file" 2>/dev/null || true

        # 精确删除旧 key（严格匹配 key=）
        awk -v k="$key" 'index($0, k"=") != 1' "$CATMIENV_FILE" > "$tmp_file"

        # 写入新值
        printf '%s="%s"\n' "$key" "$value" >> "$tmp_file"

        # 原子替换
        mv "$tmp_file" "$CATMIENV_FILE"

    ) 200>"$CATMIENV_FILE.lock"
}

random_website() {
   domains=(
    "zh-hk.vuejs.org"
    "samsung.com"
    "amd.com"
    "cdn-dynmedia-1.microsoft.com"
    "github.io"
    "updates.cdn-apple.com"
    "download-installer.cdn.mozilla.net"
    "gateway.icloud.com"
    "cisco.com"
    "redis.io"
    "umcg.nl"
    "s0.awsstatic.com"
    "cname.vercel-dns.com"
    "dl.google.com"
    "images-na.ssl-images-amazon.com"
    "suny.edu"
    "osxapps.itunes.apple.com"
    "itunes.apple.com"
    "vuejs-jp.org"
    "academy.nvidia.com"
    "m.media-amazon.com"
    "react.dev"
    "one-piece.com"
    "vercel-dns.com"
    "d1.awsstatic.com"
    "mensura.cdn-apple.com"
    "mongodb.com"
    "software.download.prss.microsoft.com"
    "swdist.apple.com"
    "addons.mozilla.org"
    "fom-international.com"
    "player.live-video.net"
    "aod.itunes.apple.com"
    "vuejs.org"
    "swift.com"
    "oracle.com"
    "caltech.edu"
    "swcdn.apple.com"
    "lol.secure.dyn.riotcdn.net"
    "python.org"
    "asus.com"
    "lovelive-anime.jp"
    "mysql.com"
    "java.com"
    "u-can.co.jp"
    "calstatela.edu"
    "google-analytics.com"
    "suffolk.edu"
    )


    total_domains=${#domains[@]}
    random_index=$((RANDOM % total_domains))
    
    # 输出选择的域名
    echo "${domains[random_index]}"
}
# 生成密钥
read -rp "请输入回落域名: " dest_server
[ -z "$dest_server" ] && dest_server=$(random_website)
update_env dest_server "${dest_server}"

