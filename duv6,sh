#!/bin/bash

# 备份原始配置文件
sudo cp /etc/network/interfaces /etc/network/interfaces.bak

# 获取用户输入
read -p "请输入基础IPv6地址（含前缀，如2a0f:7803:fac4:c933::1/64）: " base_ip
read -p "需要生成的地址数量: " count
read -p "网络接口名称（如eth0）: " interface

# 验证输入
if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    echo "错误：数量必须是数字！"
    exit 1
fi

# 提取地址和前缀长度
ip_part="${base_ip%%/*}"
prefix_len="${base_ip##*/}"

# 展开IPv6地址（需Python3支持）
expanded_ip=$(python3 -c "import ipaddress; print(ipaddress.IPv6Address('$ip_part').exploded)")

# 分割地址块
IFS=':' read -ra blocks <<< "$expanded_ip"
if [ ${#blocks[@]} -ne 8 ]; then
    echo "错误：IPv6地址格式无效！"
    exit 1
fi

# 提取前缀和起始点
prefix=$(IFS=':'; echo "${blocks[*]:0:4}" | sed 's/ /:/g')
last_block_hex="${blocks[7]}"
start_num=$((16#$last_block_hex))

# 生成地址列表
addresses=()
for ((i=0; i<count; i++)); do
    current_hex=$(printf "%04x" $((start_num + i)))
    new_ip="${prefix}:$(printf "%s:%s:%s:%s" "${blocks[4]}" "${blocks[5]}" "${blocks[6]}" "$current_hex")"
    addresses+=("$new_ip")
done

# 配置网关（通常为::1）
gateway="${prefix%:*}::1"

# 写入配置文件
echo -e "\nauto $interface" | sudo tee -a /etc/network/interfaces >/dev/null
echo "iface $interface inet6 static" | sudo tee -a /etc/network/interfaces >/dev/null
echo "    address ${addresses[0]}/$prefix_len" | sudo tee -a /etc/network/interfaces >/dev/null
echo "    gateway $gateway" | sudo tee -a /etc/network/interfaces >/dev/null

# 添加额外地址（通过post-up）
for ip in "${addresses[@]:1}"; do
    echo "    post-up ip -6 addr add $ip/$prefix_len dev $interface" | sudo tee -a /etc/network/interfaces >/dev/null
done

echo -e "\n配置完成！重启网络服务生效：\nsudo systemctl restart networking"
