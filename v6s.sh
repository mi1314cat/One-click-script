#!/bin/bash

# 随机IPv6地址生成脚本 v2.0
# 功能：基于指定前缀生成随机后缀的IPv6地址，并自动配置网络接口

# ---------- 函数定义 ----------
validate_ipv6() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}/64$ ]] && return 0 || return 1
}

generate_suffix() {
  # 生成4组随机的16进制块（共64位）
  dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -x -A n | \
  tr -d ' ' | sed 's/../&:/g' | cut -d: -f1-4 | tr 'a-f' 'A-F'
}

# ---------- 主流程 ----------
# 备份配置文件
sudo cp /etc/network/interfaces /etc/network/interfaces.bak
ip a
# 获取用户输入
read -p "请输入基础IPv6前缀（格式如 2a0f:7803:fac4:5a46::/64）: " base_prefix
read -p "需要生成的地址数量: " count
read -p "网络接口名称（如eth0）: " interface

# 输入验证
if ! [[ "$base_prefix" =~ ^([0-9a-fA-F]{1,4}:){3}[0-9a-fA-F]{1,4}::/64$ ]]; then
  echo "错误：前缀格式无效！必须为 /64 格式"
  exit 1
fi
if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -gt 100 ]; then
  echo "错误：数量必须是1-100之间的整数！"
  exit 1
fi

# 提取纯净前缀（去除末尾的::）
pure_prefix=$(echo "$base_prefix" | awk -F '::' '{print $1}')

# 生成地址并写入配置
echo -e "\nauto $interface" | sudo tee -a /etc/network/interfaces >/dev/null
echo "iface $interface inet6 manual" | sudo tee -a /etc/network/interfaces >/dev/null

for ((i=1; i<=count; i++)); do
  suffix=$(generate_suffix)
  full_ip="${pure_prefix}:${suffix}/64"
  echo "    post-up ip -6 addr add $full_ip dev $interface" | sudo tee -a /etc/network/interfaces >/dev/null
  echo "    pre-down ip -6 addr del $full_ip dev $interface" | sudo tee -a /etc/network/interfaces >/dev/null
done

# 添加默认路由（可选）
read -p "是否需要配置IPv6默认网关？[y/N] " set_gateway
if [[ "$set_gateway" =~ [yY] ]]; then
  read -p "请输入IPv6网关地址（如 ${pure_prefix}::1）: " gateway
  echo "    post-up ip -6 route add default via $gateway" | sudo tee -a /etc/network/interfaces >/dev/null
  echo "    pre-down ip -6 route del default via $gateway" | sudo tee -a /etc/network/interfaces >/dev/null
fi

# 完成提示
echo -e "\n\033[32m[+] 配置完成！已生成 $count 个随机IPv6地址\033[0m"
echo -e "请执行以下命令生效："
echo -e "sudo systemctl restart networking\n"
