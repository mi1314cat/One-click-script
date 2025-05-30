#!/bin/bash

# === 请修改这三项为你的实际中央服务器信息 ===
central_user="root"
read -p "请输入 服务ip: " central_host
central_dir="/root/catmi/ss"

# === 第一步：生成 SSH 密钥（如果不存在）===
if [ ! -f ~/.ssh/id_ed25519 ]; then
    echo "==> 生成 SSH 密钥..."
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
else
    echo "==> SSH 密钥已存在，跳过生成"
fi

# === 第二步：拷贝公钥到中央服务器，设置免密 ===
echo "==> 拷贝公钥到中央服务器以实现免密登录..."
ssh-copy-id -i ~/.ssh/id_ed25519.pub ${central_user}@${central_host}

# === 第三步：创建上传脚本 ===
echo "==> 创建上传脚本 /root/upload_log.sh ..."
cat > /root/upload_log.sh <<EOF
#!/bin/bash
local_file="/root/log.txt"
ip=\$(hostname -I | awk '{print \$1}')
target_file="log_\${ip//./_}.txt"
scp "\$local_file" "${central_user}@${central_host}:${central_dir}/\$target_file"
EOF

chmod +x /root/upload_log.sh


