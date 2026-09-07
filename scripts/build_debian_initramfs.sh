#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C.UTF-8

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:?必须设置 ROOTFS}"
OUTPUT="${OUTPUT:?必须设置 OUTPUT}"
BUILD_DIR="${BUILD_DIR:-$PROJECT_ROOT/.build/debian-initramfs}"
INIT_SCRIPT="${INIT_SCRIPT:-$PROJECT_ROOT/patches/initramfs/init-debian.sh}"
USB_GADGET_SCRIPT="${USB_GADGET_SCRIPT:-$PROJECT_ROOT/patches/rootfs/usr/sbin/zu02-usb-gadget}"
REBOOT_COMPAT="${REBOOT_COMPAT:-$ROOTFS/system/bin/reboot}"
REGULATORY_DB="${REGULATORY_DB:?必须设置 REGULATORY_DB}"
REGULATORY_DB_SIGNATURE="${REGULATORY_DB_SIGNATURE:?必须设置 REGULATORY_DB_SIGNATURE}"
PROJECT_SOURCE_DATE_EPOCH=1781860238
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$PROJECT_SOURCE_DATE_EPOCH}"

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

[[ "$SOURCE_DATE_EPOCH" == "$PROJECT_SOURCE_DATE_EPOCH" ]] \
    || die "正式 initramfs SOURCE_DATE_EPOCH 必须为 $PROJECT_SOURCE_DATE_EPOCH"
for command_name in cpio file find gzip install readlink realpath sort touch; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
done
for required in "$INIT_SCRIPT" "$USB_GADGET_SCRIPT" "$REBOOT_COMPAT" "$REGULATORY_DB" "$REGULATORY_DB_SIGNATURE"; do
    [[ -s "$required" ]] || die "缺少输入文件：$required"
done
case "$(realpath -m "$BUILD_DIR")" in
    / | "$(realpath -m "$PROJECT_ROOT")") die "不安全的 BUILD_DIR：$BUILD_DIR" ;;
esac

busybox=""
for candidate in "$ROOTFS/bin/busybox" "$ROOTFS/usr/bin/busybox"; do
    if [[ -x "$candidate" ]]; then
        busybox="$candidate"
        break
    fi
done
[[ -n "$busybox" ]] || die "Debian rootfs 缺少 busybox-static"
file "$busybox" | grep -q 'ELF 32-bit.*ARM.*statically linked' \
    || die "busybox 不是 32 位 ARM 静态 ELF"
file "$REBOOT_COMPAT" | grep -q 'ELF 32-bit.*ARM.*statically linked' \
    || die "initramfs reboot 兼容程序不是 32 位 ARM 静态 ELF"

stage="$BUILD_DIR/root"
rm -rf -- "$stage"
mkdir -p "$stage"/{bin,sbin,dev,proc,sys,run,sysroot,etc,lib/firmware,system/bin}
install -m 0755 "$busybox" "$stage/bin/busybox"
install -m 0755 "$INIT_SCRIPT" "$stage/init"
install -m 0755 "$USB_GADGET_SCRIPT" "$stage/sbin/zu02-usb-gadget"
install -m 0755 "$REBOOT_COMPAT" "$stage/system/bin/reboot"
install -m 0644 "$REGULATORY_DB" "$stage/lib/firmware/regulatory.db"
install -m 0644 "$REGULATORY_DB_SIGNATURE" "$stage/lib/firmware/regulatory.db.p7s"

applets=(
    cat cut echo find grep head hostname ip killall ln ls mkdir mount mountpoint
    readlink rm sed setsid sh sha256sum sleep stty switch_root udhcpd umount wc
)
for applet in "${applets[@]}"; do
    ln -s busybox "$stage/bin/$applet"
done

cat > "$stage/etc/udhcpd.conf" <<'EOF'
start 192.168.68.2
end 192.168.68.10
interface usb0
option subnet 255.255.255.0
option router 192.168.68.1
lease_file /run/udhcpd.leases
pidfile /run/udhcpd.pid
EOF

mkdir -p "$(dirname "$OUTPUT")"
find "$stage" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
(cd "$stage" && find . -print0 | sort -z | \
    cpio --null -o --format=newc --owner=0:0 --reproducible 2>/dev/null) \
    | gzip -9n > "$OUTPUT"
[[ -s "$OUTPUT" ]] || die "initramfs 输出为空：$OUTPUT"
printf '完成：%s\n' "$OUTPUT"
