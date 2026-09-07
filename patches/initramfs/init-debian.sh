#!/bin/busybox sh
set -eu

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

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

has_cmdline_flag() {
    expected="$1"
    for argument in $(cat /proc/cmdline); do
        [ "$argument" != "$expected" ] || return 0
    done
    return 1
}

uses_large_root() {
    for argument in $(cat /proc/cmdline); do
        [ "$argument" != 'root=/dev/mapper/ufi210-root' ] || return 0
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

find_exact_partition() {
    partlabel="$1"
    expected_sectors="$2"
    expected_start="$3"
    found=
    found_count=0
    for block in /sys/class/block/*; do
        [ -r "$block/uevent" ] || continue
        if grep -qx "PARTNAME=$partlabel" "$block/uevent"; then
            found="/dev/${block##*/}"
            found_count=$((found_count + 1))
        fi
    done
    [ "$found_count" -eq 0 ] && return 1
    if [ "$found_count" -ne 1 ]; then
        echo "[zu02-initramfs] expected one $partlabel partition, found $found_count" >/dev/kmsg
        return 2
    fi
    actual_sectors="$(cat "/sys/class/block/${found##*/}/size")"
    if [ "$actual_sectors" != "$expected_sectors" ]; then
        echo "[zu02-initramfs] $partlabel has $actual_sectors sectors, expected $expected_sectors" >/dev/kmsg
        return 2
    fi
    actual_start="$(cat "/sys/class/block/${found##*/}/start")"
    if [ "$actual_start" != "$expected_start" ]; then
        echo "[zu02-initramfs] $partlabel starts at $actual_start, expected $expected_start" >/dev/kmsg
        return 2
    fi
    printf '%s\n' "$found"
}

wait_for_exact_partition() {
    partlabel="$1"
    expected_sectors="$2"
    expected_start="$3"
    attempt=1
    while [ "$attempt" -le 60 ]; do
        if found="$(find_exact_partition "$partlabel" "$expected_sectors" "$expected_start")"; then
            printf '%s\n' "$found"
            return 0
        else
            status=$?
        fi
        [ "$status" -eq 1 ] || return "$status"
        sleep 1
        attempt=$((attempt + 1))
    done
    return 1
}

create_large_root() {
    readonly_flag="$1"
    system_sectors=2516584
    cache_sectors=524288
    userdata_sectors=3766239
    userdata_start=$((system_sectors + cache_sectors))
    total_sectors=$((userdata_start + userdata_sectors))
    system_start=461920
    cache_start=3044040
    userdata_lba=3803136

    if ! system_dev="$(wait_for_exact_partition system "$system_sectors" "$system_start")"; then
        rescue_shell 'system partition is missing, duplicated, or has the wrong size'
    fi
    if ! cache_dev="$(wait_for_exact_partition cache "$cache_sectors" "$cache_start")"; then
        rescue_shell 'cache partition is missing, duplicated, or has the wrong size'
    fi
    if ! userdata_dev="$(wait_for_exact_partition userdata "$userdata_sectors" "$userdata_lba")"; then
        rescue_shell 'userdata partition is missing, duplicated, or has the wrong size'
    fi

    mkdir -p /dev/mapper /run/lock
    if dmsetup info ufi210-root >/dev/null 2>&1; then
        rescue_shell 'ufi210-root already exists before setup'
    fi
    table="0 $system_sectors linear $system_dev 0
$system_sectors $cache_sectors linear $cache_dev 0
$userdata_start $userdata_sectors linear $userdata_dev 0"
    if [ "$readonly_flag" = yes ]; then
        dmsetup create --readonly --noudevsync ufi210-root --table "$table" \
            || rescue_shell 'failed to create read-only ufi210-root'
    else
        dmsetup create --noudevsync ufi210-root --table "$table" \
            || rescue_shell 'failed to create ufi210-root'
    fi
    dmsetup mknodes ufi210-root \
        || rescue_shell 'failed to create ufi210-root device node'
    [ -b /dev/mapper/ufi210-root ] \
        || rescue_shell 'ufi210-root device node is missing'
    actual_total="$(blockdev --getsz /dev/mapper/ufi210-root 2>/dev/null || true)"
    [ "$actual_total" = "$total_sectors" ] \
        || rescue_shell "ufi210-root has $actual_total sectors, expected $total_sectors"
    if [ "$readonly_flag" = yes ]; then
        [ "$(blockdev --getro /dev/mapper/ufi210-root)" = 1 ] \
            || rescue_shell 'ufi210-root probe is unexpectedly writable'
    fi
    log "created ufi210-root: $total_sectors sectors ($system_dev + $cache_dev + $userdata_dev)"
}

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run
mkdir -p /sys/kernel/config /sysroot

start_recovery_network || rescue_shell 'failed to start USB recovery gadget'

if uses_large_root; then
    if has_cmdline_flag 'ufi210.dm_probe=1'; then
        create_large_root yes
        rescue_shell 'read-only ufi210-root probe completed successfully'
    fi
    create_large_root no
    rootdev=/dev/mapper/ufi210-root
else
    root_partlabel="$(get_root_partlabel || true)"
    [ -n "$root_partlabel" ] \
        || rescue_shell 'root must select cache, system, or /dev/mapper/ufi210-root'

    rootdev=
    attempt=1
    while [ "$attempt" -le 60 ]; do
        rootdev="$(find_root_partition "$root_partlabel" || true)"
        [ -z "$rootdev" ] || break
        sleep 1
        attempt=$((attempt + 1))
    done
    [ -n "$rootdev" ] || rescue_shell "$root_partlabel partition was not found"
fi

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
