# 定义函数，返回随机选择的域名
DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

update_env() {
    local key="$1"
    local value="$2"

    # key 必须是合法的 env 变量名
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        echo "Invalid key: $key"
        return 1
    }

    # 转义 value 中的双引号
    value="${value//\"/\\\"}"

    [ -f "$CATMIENV_FILE" ] || touch "$CATMIENV_FILE"

    if grep -q "^${key}=" "$CATMIENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$CATMIENV_FILE"
    else
        echo "${key}=\"${value}\"" >> "$CATMIENV_FILE"
    fi
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

