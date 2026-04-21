# 定义函数，返回随机选择的域名
random_website() {
   domains=(
     "amd.com"
    "dl.google.com"
    "swdist.apple.com"
    "aod.itunes.apple.com"
    "updates.cdn-apple.com"
    "swcdn.apple.com"
    "itunes.apple.com"
    "d1.awsstatic.com"
    "mongodb.com"
    "images-na.ssl-images-amazon.com"
    "osxapps.itunes.apple.com"
    "asus.com"
    "samsung.com"
    "oracle.com"
    "s0.awsstatic.com"
    "cisco.com"
    "zh-hk.vuejs.org"
    "cdn-dynmedia-1.microsoft.com"
    "mensura.cdn-apple.com"
    "lovelive-anime.jp"
    "player.live-video.net"
    "mysql.com"
    "download-installer.cdn.mozilla.net"
    "python.org"
    "react.dev"
    "lol.secure.dyn.riotcdn.net"
    "cname.vercel-dns.com"
    "fom-international.com"
    "vercel-dns.com"
    "addons.mozilla.org"
    "gateway.icloud.com"
    "m.media-amazon.com"
    "software.download.prss.microsoft.com"
    "vuejs.org"
    "caltech.edu"
    "redis.io"
    "java.com"
    "umcg.nl"
    "u-can.co.jp"
    "suffolk.edu"
    "suny.edu"
    "calstatela.edu"
    "vuejs-jp.org"
    "one-piece.com"
    "academy.nvidia.com"
    "swift.com"
    "github.io"
    "google-analytics.com"
    )


    total_domains=${#domains[@]}
    random_index=$((RANDOM % total_domains))
    
    # 输出选择的域名
    echo "${domains[random_index]}"
}
# 生成密钥
read -rp "请输入回落域名: " dest_server
[ -z "$dest_server" ] && dest_server=$(random_website)
{

    echo "dest_server：${dest_server}"
    
} > "/root/catmi/dest_server.txt"


