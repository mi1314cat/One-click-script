#!/bin/bash

# IPv6地址生成脚本 v4.0
# 功能：生成标准格式的IPv6地址并自动补全

# ---------- 函数定义 ----------
expand_ipv6() {
  python3 -c "import ipaddress; print(ipaddress.IPv6Address('$1').exploded)"
}
ip a
# ---------- 主流程 ----------
read -p "请输入基础IPv6前缀（如2a0f:7803:fac4:c933::/64）: " base_prefix
read -p "需要生成的地址数量: " count
read -p "网络接口名称（如eth0）: " interface

# 生成并验证地址
addresses=()
for i in $(seq 1 $count); do
  # 生成随机后缀（4组四位十六进制）
  suffix=$(dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -x -A n | \
           awk '{print $1$2$3$4}' | sed 's/../&:/g' | tr 'a-f' 'A-F')
  
  # 构建完整地址并标准化
  raw_ip="${base_prefix%%/*}:${suffix%%:*}"
  full_ip=$(expand_ipv6 "$raw_ip")/64
  
  addresses+=("$full_ip")
done

# 写入配置文件
echo -e "\nauto $interface" | sudo tee -a /etc/network/interfaces >/dev/null
echo "iface $interface inet6 static" | sudo tee -a /etc/network/interfaces >/dev/null
echo "    address ${addresses[0]}" | sudo tee -a /etc/network/interfaces >/dev/null
echo "    gateway ${base_prefix%%/*}::1" | sudo tee -a /etc/network/interfaces >/dev/null

for ip in "${addresses[@]:1}"; do
  echo "    up ip -6 addr add $ip dev $interface" | sudo tee -a /etc/network/interfaces >/dev/null
done

echo -e "\n\033[32m[√] 配置完成！重启网络服务生效：sudo systemctl restart networking\033[0m"
