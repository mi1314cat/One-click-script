#!/bin/bash

config_file="/root/.logsync.conf"

# === 第一次运行时输入配置 ===
if [ ! -f "$config_file" ]; then
    echo "🚀 首次运行：请输入中央服务器信息（仅需一次）"
    read -p "中央服务器用户名（如 youruser）: " central_user
    read -p "中央服务器IP地址（如 1.2.3.4）: " central_host
    read -p "中央服务器目录（如 /home/youruser/logs）: " central_base_dir
    read -p "本地目录（你要上传哪个目录，例如 /root/logs）: " local_dir

    cat > "$config_file" <<EOF
central_user="$central_user"
central_host="$central_host"
central_base_dir="$central_base_dir"
local_dir="$local_dir"
EOF

    echo "✅ 已保存配置到 $config_file"
fi

# === 加载配置 ===
source "$config_file"

# === 信息面板 ===
echo "================ 当前上传配置 ================"
echo "📌 中央服务器用户      ：$central_user"
echo "📌 中央服务器地址      ：$central_host"
echo "📁 中央存储目录        ：$central_base_dir"
echo "📂 本地上传目录        ：$local_dir"
echo "==============================================="

# === 第一步：生成 SSH 密钥 ===
if [ ! -f ~/.ssh/id_ed25519 ]; then
    echo "🔑 正在生成 SSH 密钥..."
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
else
    echo "🔑 SSH 密钥已存在"
fi

# === 第二步：设置免密登录 ===
echo "🔗 设置免密登录中..."
ssh-copy-id -i ~/.ssh/id_ed25519.pub ${central_user}@${central_host}

# === 第三步：生成上传脚本 ===
echo "📦 正在创建上传脚本 /root/upload_logs.sh..."

cat > /root/upload_logs.sh <<EOF
#!/bin/bash

central_user="$central_user"
central_host="$central_host"
central_base_dir="$central_base_dir"
local_dir="$local_dir"

ip=\$(hostname -I | awk '{print \$1}')
remote_subdir="\${central_base_dir}/\${ip//./_}"

ssh \${central_user}@\${central_host} "mkdir -p \${remote_subdir}"

for file in "\$local_dir"/*.txt; do
    filename=\$(basename "\$file")
    scp "\$file" "\${central_user}@\${central_host}:\${remote_subdir}/\${filename}"
done
EOF

chmod +x /root/upload_logs.sh

# === 第四步：设置自动上传定时任务 ===

