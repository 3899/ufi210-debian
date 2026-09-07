#!/bin/busybox sh
set -eu

export PATH=/bin:/sbin

log() {
    echo "[zu02-initramfs] $*" > /dev/kmsg
    echo "[zu02-initramfs] $*"
}

start_recovery_network() {
    mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
    /sbin/zu02-usb-gadget setup
    /sbin/zu02-usb-gadget activate

    attempt=1
    while [ "$attempt" -le 15 ]; do
        [ -e /sys/class/net/usb0 ] && break
        sleep 1
        attempt=$((attempt + 1))
    done
    if [ -e /sys/class/net/usb0 ]; then
        ip link set usb0 up
        ip addr replace 192.168.68.1/24 dev usb0
        : > /run/udhcpd.leases
        udhcpd /etc/udhcpd.conf >/dev/kmsg 2>&1 || true
    fi
}

rescue_shell() {
    log "$*; recovery shell is available on USB ACM /dev/ttyGS0"
    attempt=1
    while [ "$attempt" -le 15 ]; do
        [ -c /dev/ttyGS0 ] && break
        sleep 1
        attempt=$((attempt + 1))
    done
    if [ -c /dev/ttyGS0 ]; then
        stty -F /dev/ttyGS0 115200 sane 2>/dev/null || true
        setsid sh -c \
            'echo "UFI210 initramfs recovery"; echo "Run /system/bin/reboot bootloader to enter fastboot."; exec sh -i' \
            </dev/ttyGS0 >/dev/ttyGS0 2>&1 &
    else
        log 'USB ACM ttyGS0 is unavailable'
    fi
    setsid sh -i </dev/console >/dev/console 2>&1 &
    while :; do sleep 60; done
}

get_root_partlabel() {
    for argument in $(cat /proc/cmdline); do
        case "$argument" in
            root=PARTLABEL=cache)
                printf 'cache\n'
                return 0
                ;;
            root=PARTLABEL=system)
                printf 'system\n'
                return 0
                ;;
        esac
    done
    return 1
}

find_root_partition() {
    partlabel="$1"
    for block in /sys/class/block/*; do
        [ -r "$block/uevent" ] || continue
        if grep -qx "PARTNAME=$partlabel" "$block/uevent"; then
            printf '/dev/%s\n' "${block##*/}"
            return 0
        fi
    done
    return 1
}

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run
mkdir -p /sys/kernel/config /sysroot

start_recovery_network || rescue_shell 'failed to start USB recovery gadget'

root_partlabel="$(get_root_partlabel || true)"
[ -n "$root_partlabel" ] \
    || rescue_shell 'root=PARTLABEL must select cache or system'

rootdev=
attempt=1
while [ "$attempt" -le 60 ]; do
    rootdev="$(find_root_partition "$root_partlabel" || true)"
    [ -z "$rootdev" ] || break
    sleep 1
    attempt=$((attempt + 1))
done
[ -n "$rootdev" ] || rescue_shell "$root_partlabel partition was not found"

log "mounting Debian root from $rootdev"
mount -t ext4 -o rw,noatime "$rootdev" /sysroot \
    || rescue_shell "failed to mount $rootdev"
[ -x /sysroot/usr/lib/systemd/systemd ] \
    || rescue_shell 'Debian systemd is missing'

log 'switching to Debian systemd'
killall udhcpd 2>/dev/null || true
mount --move /dev /sysroot/dev
mount --move /proc /sysroot/proc
mount --move /sys /sysroot/sys
mount --move /run /sysroot/run

exec switch_root /sysroot /sbin/init
