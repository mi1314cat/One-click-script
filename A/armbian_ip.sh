#!/bin/bash
set -e

echo "=== MGV3000 Armbian 断电无 IP 修复脚本（增强版） ==="

echo "[1/6] 强制使用 eth0 命名规则"
BOOT_ENV="/boot/armbianEnv.txt"

if ! grep -q "net.ifnames=0" "$BOOT_ENV"; then
    sed -i '/^extraargs=/d' "$BOOT_ENV"
    echo 'extraargs=net.ifnames=0 biosdevname=0' >> "$BOOT_ENV"
    echo "  已写入 extraargs"
else
    echo "  已存在 net.ifnames=0"
fi

echo "[2/6] 禁用 NetworkManager 管理 eth0"
mkdir -p /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/10-unmanage-eth0.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:eth0
EOF

systemctl restart NetworkManager || true

echo "[3/6] 配置 eth0 DHCP（ifupdown）"
mkdir -p /etc/network/interfaces.d
cat >/etc/network/interfaces.d/eth0 <<'EOF'
auto eth0
iface eth0 inet dhcp
EOF

echo "[4/6] 创建更稳健的 systemd 服务"
cat >/etc/systemd/system/force-eth0.service <<'EOF'
[Unit]
Description=Force bring up eth0 on boot (MGV3000 fix)
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStartPre=/bin/sh -c 'sleep 2'
ExecStart=/sbin/ip link set eth0 up
ExecStart=/sbin/ifdown eth0 || true
ExecStart=/sbin/ifup eth0
RemainAfterExit=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "[5/6] 启用服务"
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable force-eth0.service

echo "[6/6] 清理可能的冲突配置"
rm -f /etc/network/interfaces.d/end0 || true

echo
echo "=== 修复完成（增强版）==="
echo "请执行：poweroff"
echo "然后【断电】→ 再上电测试（不要 reboot）"
