#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# USB Auto Mount Pro v2
# 适用于:
#   Armbian / Debian / Ubuntu / OpenWRT(部分)
#
# 功能:
#   - 自动识别 U 盘
#   - 自动挂载
#   - 自动恢复
#   - 自动卸载失效挂载
#   - 支持 exfat/ntfs/vfat/ext4
#   - systemd 后台运行
#   - CLI 管理面板
#
# 用法:
#   bash up.sh        -> 安装服务
#   bash up.sh run    -> 后台运行
#   bash up.sh panel  -> 管理面板
# =========================================================

# =========================================================
# 基础配置
# =========================================================

readonly MOUNT_POINT="/catmi"
readonly SERVICE_NAME="usb-catmi"
readonly SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

readonly SCRIPT_PATH="$(readlink -f "$0")"

# =========================================================
# 日志
# =========================================================

log() {
    echo "[USB-AUTO] $(date '+%F %T') | $*"
}

# =========================================================
# 初始化
# =========================================================

init_env() {

    mkdir -p "$MOUNT_POINT"

    # 防止 mountpoint 不存在
    command -v mountpoint >/dev/null 2>&1 || {
        log "缺少 mountpoint 命令"
        exit 1
    }

    command -v lsblk >/dev/null 2>&1 || {
        log "缺少 lsblk 命令"
        exit 1
    }
}

# =========================================================
# 判断是否已挂载
# =========================================================

is_mounted() {
    mountpoint -q "$MOUNT_POINT"
}

# =========================================================
# 获取当前挂载源
# =========================================================

get_mount_source() {
    findmnt -n -o SOURCE --target "$MOUNT_POINT" 2>/dev/null || true
}

# =========================================================
# 清理失效挂载
# =========================================================

cleanup_mount() {

    if ! is_mounted; then
        return
    fi

    local src
    src="$(get_mount_source)"

    [ -z "$src" ] && return

    # 如果设备不存在于 sysfs（真正掉线）
    if [ ! -e "/sys/block/$(basename "$src")" ] && \
       [ ! -e "/sys/block/${src#/dev/}" ]; then
        log "检测到设备掉线，卸载失效挂载..."
        umount -lf "$MOUNT_POINT" || true
        return
    fi

    # 如果设备存在但 I/O 错误（更强检测）
    if ! dd if="$src" of=/dev/null bs=1M count=1 status=none 2>/dev/null; then
        log "检测到设备 I/O 错误，卸载失效挂载..."
        umount -lf "$MOUNT_POINT" || true
        return
    fi
}


# =========================================================
# 查找 USB 分区（生产级稳定版）
# =========================================================

find_usb_partition() {

    # 查找所有可移动磁盘（RM=1）
    disks=($(lsblk -rpno NAME,RM,TYPE | awk '$2=="1" && $3=="disk"{print $1}'))

    [ ${#disks[@]} -eq 0 ] && return

    for disk in "${disks[@]}"; do

        # 找到所有分区
        parts=($(lsblk -rpno NAME,TYPE "$disk" | awk '$2=="part"{print $1}'))

        [ ${#parts[@]} -eq 0 ] && continue

        # 返回最大分区（你的 sda3）
        lsblk -rpno NAME,SIZE "${parts[@]}" | sort -k2 -h | tail -n1 | awk '{print $1}'
        return
    done
}



# =========================================================
# 尝试挂载
# =========================================================

mount_usb() {

    local part="$1"

    [ -z "$part" ] && return 1

    if is_mounted; then
        return 0
    fi

    log "发现 USB 分区: $part"

    # 自动识别挂载
    if mount -o rw "$part" "$MOUNT_POINT" 2>/dev/null; then
        log "自动挂载成功"
        return 0
    fi

    # 手动尝试文件系统
    local fs

    for fs in \
        exfat \
        ntfs3 \
        ntfs \
        vfat \
        ext4 \
        ext3 \
        ext2
    do

        if mount -t "$fs" -o rw "$part" "$MOUNT_POINT" 2>/dev/null; then
            log "使用 $fs 挂载成功"
            return 0
        fi

    done

    log "挂载失败: $part"

    return 1
}

# =========================================================
# 主循环
# =========================================================

usb_loop() {

    init_env

    log "USB 自动挂载服务启动"

    local part=""

    while true; do

        cleanup_mount

        # 已挂载
        if is_mounted; then
            sleep 3
            continue
        fi

        # 查找 USB 分区
        part="$(find_usb_partition || true)"

        if [ -z "${part:-}" ]; then
            sleep 3
            continue
        fi

        mount_usb "$part" || true

        sleep 3
    done
}

# =========================================================
# 管理面板
# =========================================================

panel() {

    while true; do

        clear

        echo "================================================"
        echo "              USB 自动挂载管理面板"
        echo "================================================"
        echo
        echo "1) 查看服务状态"
        echo "2) 重启服务"
        echo "3) 停止服务"
        echo "4) 查看实时日志"
        echo "5) 查看挂载状态"
        echo "6) 手动卸载"
        echo "7) 退出"
        echo
        echo "================================================"

        read -rp "请选择: " choice

        case "$choice" in

            1)
                systemctl status "$SERVICE_NAME" --no-pager
                read -rp "回车继续..."
                ;;

            2)
                systemctl restart "$SERVICE_NAME"
                echo
                echo "服务已重启"
                sleep 1
                ;;

            3)
                systemctl stop "$SERVICE_NAME"
                echo
                echo "服务已停止"
                sleep 1
                ;;

            4)
                journalctl -u "$SERVICE_NAME" -f
                ;;

            5)
                echo

                if is_mounted; then
                    findmnt "$MOUNT_POINT"
                else
                    echo "当前未挂载"
                fi

                echo
                lsblk
                echo

                read -rp "回车继续..."
                ;;

            6)
                echo

                if is_mounted; then
                    umount -lf "$MOUNT_POINT" && \
                    echo "卸载成功" || \
                    echo "卸载失败"
                else
                    echo "当前未挂载"
                fi

                sleep 2
                ;;

            7)
                exit 0
                ;;

            *)
                echo
                echo "无效选择"
                sleep 1
                ;;
        esac
    done
}

# =========================================================
# 生成 systemd 服务
# =========================================================

generate_service() {

    log "生成 systemd 服务..."

    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=USB Auto Mount Service
After=local-fs.target
Wants=local-fs.target

[Service]
Type=simple

ExecStart=/usr/bin/env bash ${SCRIPT_PATH} run

Restart=always
RestartSec=2

StandardOutput=journal
StandardError=journal

# 防止 systemd 误杀
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_PATH"

    log "重载 systemd..."
    systemctl daemon-reload

    log "启用服务..."
    systemctl enable --now "$SERVICE_NAME"

    # CLI 面板
    cat > /usr/local/bin/catmi-usb <<EOF
#!/usr/bin/env bash
bash ${SCRIPT_PATH} panel
EOF

    chmod +x /usr/local/bin/catmi-usb

    log "安装完成"
    log "输入: catmi-usb"
}

# =========================================================
# 主入口
# =========================================================

case "${1:-}" in

    run)
        usb_loop
        ;;

    panel)
        panel
        ;;

    *)
        generate_service
        ;;
esac
