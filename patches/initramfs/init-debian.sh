#!/bin/busybox sh
set -eu

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

log() {
    echo "[zu02-initramfs] $*" > /dev/kmsg
    echo "[zu02-initramfs] $*"
}

start_recovery_network() {
    max_attempts="${1:-1}"
    gadget_started=no
    attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        if /sbin/zu02-usb-gadget setup && /sbin/zu02-usb-gadget activate; then
            gadget_started=yes
            break
        fi
        log "USB recovery gadget is not ready (attempt $attempt/$max_attempts)"
        sleep 1
        attempt=$((attempt + 1))
    done
    if [ "$gadget_started" != yes ]; then
        log "USB recovery gadget did not start within $max_attempts attempts"
        return 1
    fi

    attempt=1
    while [ "$attempt" -le 15 ]; do
        [ -e /sys/class/net/usb0 ] && break
        sleep 1
        attempt=$((attempt + 1))
    done
    if [ ! -e /sys/class/net/usb0 ]; then
        log 'USB recovery RNDIS did not appear after gadget activation'
        return 1
    fi
    if [ ! -c /dev/ttyGS0 ]; then
        log 'USB recovery ACM is unavailable; continuing with RNDIS management'
    fi

    ip link set usb0 up
    ip addr replace 192.168.68.1/24 dev usb0
    : > /run/udhcpd.leases
    udhcpd /etc/udhcpd.conf >/dev/kmsg 2>&1 || true
}

rescue_shell() {
    reason="$*"
    if [ ! -e /sys/class/net/usb0 ]; then
        start_recovery_network 60 || log 'USB recovery gadget remains unavailable'
    fi
    log "$reason; recovery shell is available on USB ACM /dev/ttyGS0"
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

finish_readonly_probe() {
    reason="$*"
    log "$reason; returning to fastboot"
    /system/bin/reboot bootloader \
        || rescue_shell "$reason; automatic fastboot reboot failed"
    rescue_shell "$reason; automatic fastboot reboot returned unexpectedly"
}

large_root_failure() {
    readonly_flag="$1"
    shift
    reason="$*"
    if [ "$readonly_flag" = yes ]; then
        log "$reason; read-only probe failed, returning to persistent boot"
        /system/bin/reboot \
            || rescue_shell "$reason; automatic persistent reboot failed"
        rescue_shell "$reason; automatic persistent reboot returned unexpectedly"
    fi
    rescue_shell "$reason"
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
        large_root_failure "$readonly_flag" 'system partition is missing, duplicated, or has the wrong size'
    fi
    if ! cache_dev="$(wait_for_exact_partition cache "$cache_sectors" "$cache_start")"; then
        large_root_failure "$readonly_flag" 'cache partition is missing, duplicated, or has the wrong size'
    fi
    if ! userdata_dev="$(wait_for_exact_partition userdata "$userdata_sectors" "$userdata_lba")"; then
        large_root_failure "$readonly_flag" 'userdata partition is missing, duplicated, or has the wrong size'
    fi

    mkdir -p /dev/mapper /run/lock
    if dmsetup info ufi210-root >/dev/null 2>&1; then
        large_root_failure "$readonly_flag" 'ufi210-root already exists before setup'
    fi
    table="0 $system_sectors linear $system_dev 0
$system_sectors $cache_sectors linear $cache_dev 0
$userdata_start $userdata_sectors linear $userdata_dev 0"
    if [ "$readonly_flag" = yes ]; then
        dmsetup create --readonly --noudevsync ufi210-root --table "$table" \
            || large_root_failure "$readonly_flag" 'failed to create read-only ufi210-root'
    else
        dmsetup create --noudevsync ufi210-root --table "$table" \
            || large_root_failure "$readonly_flag" 'failed to create ufi210-root'
    fi
    dmsetup mknodes ufi210-root \
        || large_root_failure "$readonly_flag" 'failed to create ufi210-root device node'
    [ -b /dev/mapper/ufi210-root ] \
        || large_root_failure "$readonly_flag" 'ufi210-root device node is missing'
    actual_total="$(blockdev --getsz /dev/mapper/ufi210-root 2>/dev/null || true)"
    [ "$actual_total" = "$total_sectors" ] \
        || large_root_failure "$readonly_flag" "ufi210-root has $actual_total sectors, expected $total_sectors"
    system_devno="$(cat "/sys/class/block/${system_dev##*/}/dev")"
    cache_devno="$(cat "/sys/class/block/${cache_dev##*/}/dev")"
    userdata_devno="$(cat "/sys/class/block/${userdata_dev##*/}/dev")"
    expected_table="0 $system_sectors linear $system_devno 0
$system_sectors $cache_sectors linear $cache_devno 0
$userdata_start $userdata_sectors linear $userdata_devno 0"
    actual_table="$(dmsetup table ufi210-root 2>/dev/null || true)"
    [ "$actual_table" = "$expected_table" ] \
        || large_root_failure "$readonly_flag" 'ufi210-root table does not match the requested segments'
    if [ "$readonly_flag" = yes ]; then
        [ "$(blockdev --getro /dev/mapper/ufi210-root)" = 1 ] \
            || large_root_failure "$readonly_flag" 'ufi210-root probe is unexpectedly writable'
        ! mountpoint -q /sysroot \
            || large_root_failure "$readonly_flag" 'ufi210-root probe mounted a root filesystem unexpectedly'
    fi
    log "created ufi210-root: $total_sectors sectors ($system_dev + $cache_dev + $userdata_dev)"
}

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run
mkdir -p /sys/kernel/config /sysroot

start_recovery_network 1 || log 'USB recovery gadget deferred to Debian userspace'

if has_cmdline_flag 'ufi210.pre_dm_rescue=1'; then
    rescue_shell 'pre-dm diagnostic rescue requested'
fi

if uses_large_root; then
    if has_cmdline_flag 'ufi210.dm_probe=1'; then
        create_large_root yes
        finish_readonly_probe 'read-only ufi210-root probe completed successfully'
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
