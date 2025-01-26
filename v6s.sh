#!/bin/bash

# IPv6自定义前缀地址生成脚本 v3.1
# 更新：支持自动提取网络前缀

# ---------- 函数定义 ----------
validate_prefix() {
  local prefix="$1"
  # 使用Python3验证并标准化前缀
  full_prefix=$(python3 - <<EOF 2>/dev/null
import ipaddress
try:
    net = ipaddress.IPv6Network('${prefix}', strict=False)
    print(net.with_prefixlen)
except Exception as e:
    exit(1)
EOF
  )
  return $?
}

generate_random_suffix() {
  # 生成4组随机的16进制块（兼容任意前缀长度）
  dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -x -A n | \
  tr -d ' ' | sed 's/../&:/g' | cut -d: -f1-4 | tr 'a-f' 'A-F'
}

# ---------- 主流程 ----------
# 备份配置文件
sudo cp /etc/network/interfaces /etc/network/interfaces.bak
ip a
# 获取用户输入
read -p "请输入IPv6地址或前缀（如 2a0f:7803:fac4:5a46::1/64）: " user_input
read -p "需要生成的地址数量: " count
read -p "网络接口名称（如eth0）: " interface

# 验证并提取标准前缀
if ! validate_prefix "$user_input"; then
  echo "错误：'$user_input' 不是有效的IPv6地址/前缀！"
  exit 1
fi

# 提取前缀信息
prefix=$(echo "$full_prefix" | cut -d'/' -f1)
prefix_len=$(echo "$full_prefix" | cut -d'/' -f2)

# 生成地址并写入配置
echo -e "\nauto $interface" | sudo tee -a /etc/network/interfaces >/dev/null
echo "iface $interface inet6 manual" | sudo tee -a /etc/network/interfaces >/dev/null

for ((i=1; i<=count; i++)); do
  suffix=$(generate_random_suffix)
  full_ip="${prefix%::*}::${suffix}/$prefix_len"
  echo "    post-up ip -6 addr add $full_ip dev $interface" | sudo tee -a /etc/network/interfaces >/dev/null
  echo "    pre-down ip -6 addr del $full_ip dev $interface" | sudo tee -a /etc/network/interfaces >/dev/null
done

# 添加默认路由（可选）
read -p "是否配置IPv6默认网关？[y/N] " set_gateway
if [[ "$set_gateway" =~ [yY] ]]; then
  read -p "请输入IPv6网关地址（如 ${prefix%::*}::1）: " gateway
  echo "    post-up ip -6 route add default via $gateway" | sudo tee -a /etc/network/interfaces >/dev/null
  echo "    pre-down ip -6 route del default via $gateway" | sudo tee -a /etc/network/interfaces >/dev/null
fi

echo -e "\n\033[32m[√] 配置完成！已生成 $count 个随机地址\033[0m"
echo -e "重启网络服务生效：\nsudo systemctl restart networking"
