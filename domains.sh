
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")
DINSTALL_CATMI="/root/catmi"
CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"
load_env $CATMIENV_FILE

NINSTALL_DIR="/root/catmi/$mode"
NINSTALL_ENV="$NINSTALL_DIR/install_info.env"


random_website() {
   domains=(
    "aod.itunes.apple.com"
"software.download.prss.microsoft.com"
"swdist.apple.com"
"osxapps.itunes.apple.com"
"dl.google.com"
"mensura.cdn-apple.com"
"swcdn.apple.com"
"updates.cdn-apple.com"
"python.org"
"asus.com"
"umcg.nl"
"suffolk.edu"
"mysql.com"
"java.com"
"lovelive-anime.jp"
"mongodb.com"
"calstatela.edu"
"one-piece.com"
"react.dev"
"google-analytics.com"
"u-can.co.jp"
"caltech.edu"
"vuejs.org"
"lol.secure.dyn.riotcdn.net"
"d1.awsstatic.com"
"oracle.com"
"addons.mozilla.org"
"player.live-video.net"
"fom-international.com"
"swift.com"
"download-installer.cdn.mozilla.net"
"zh-hk.vuejs.org"
"vercel-dns.com"
"samsung.com"
"s0.awsstatic.com"
"images-na.ssl-images-amazon.com"
"redis.io"
"suny.edu"
"vuejs-jp.org"
"m.media-amazon.com"
"cdn-dynmedia-1.microsoft.com"
"amd.com"
"cisco.com"
"github.io"
"academy.nvidia.com"
"gateway.icloud.com"

    )


    total_domains=${#domains[@]}
    random_index=$((RANDOM % total_domains))
    
    # 输出选择的域名
    echo "${domains[random_index]}"
}
# 生成密钥
read -rp "请输入Reality伪装网址: " dest_server
[ -z "$dest_server" ] && dest_server=$(random_website)
update_env $NINSTALL_ENV dest_server "${dest_server}"

