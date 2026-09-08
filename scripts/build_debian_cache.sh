#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C.UTF-8

PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BUILD_DIR="${BUILD_DIR:-$PROJECT_ROOT/.build/debian-cache}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/out/mainline/debian-cache}"
SUITE="${DEBIAN_SUITE:-bookworm}"
TARGET_PARTITION="${TARGET_PARTITION:-cache}"
DEBIAN_SNAPSHOT_TIMESTAMP="20260903T000000Z"
SNAPSHOT_DOWNLOAD_RETRIES=5
SNAPSHOT_CANONICAL_ORIGIN="https://snapshot.debian.org"
SNAPSHOT_TRANSPORT_ORIGIN="${DEBIAN_SNAPSHOT_TRANSPORT_ORIGIN:-$SNAPSHOT_CANONICAL_ORIGIN}"
MIRROR="$SNAPSHOT_TRANSPORT_ORIGIN/archive/debian/$DEBIAN_SNAPSHOT_TIMESTAMP"
SECURITY_MIRROR="$SNAPSHOT_TRANSPORT_ORIGIN/archive/debian-security/$DEBIAN_SNAPSHOT_TIMESTAMP"
MANIFEST_MIRROR="$SNAPSHOT_CANONICAL_ORIGIN/archive/debian/$DEBIAN_SNAPSHOT_TIMESTAMP"
MANIFEST_SECURITY_MIRROR="$SNAPSHOT_CANONICAL_ORIGIN/archive/debian-security/$DEBIAN_SNAPSHOT_TIMESTAMP"
RUNTIME_MIRROR="https://deb.debian.org/debian"
RUNTIME_SECURITY_MIRROR="https://security.debian.org/debian-security"
DEBIAN_KEYRING="${DEBIAN_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}"
ROOT_PASSWORD="${ROOT_PASSWORD:-simadmin}"
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-255}"
DATA_IMAGE_SIZE_MB="${DATA_IMAGE_SIZE_MB:-64}"
FORCE="${FORCE:-0}"
KERNEL_RELEASE="7.0.0-msm8909"
MIN_ROOTFS_FREE_BYTES=33554432
DATA_PARTITION_SIZE=1928314368
DATA_FILESYSTEM_SIZE=1928310784
DATA_UUID="89090000-0000-4000-8000-000000000029"
DATA_HASH_SEED="89090000-0000-4000-8000-000000000030"
DATA_LABEL="ufi210-data"
SYSTEM_PARTITION_SECTORS=2516584
CACHE_PARTITION_SECTORS=524288
USERDATA_PARTITION_SECTORS=3766239
SYSTEM_PARTITION_START=461920
CACHE_PARTITION_START=3044040
USERDATA_PARTITION_START=3803136
LARGE_ROOTFS_SECTORS=6807111
LARGE_ROOTFS_SIZE=3485240832
LARGE_ROOTFS_FILESYSTEM_SIZE=3485237248
LARGE_ROOTFS_TABLE="0 2516584 linear PARTLABEL=system 0;2516584 524288 linear PARTLABEL=cache 0;3040872 3766239 linear PARTLABEL=userdata 0"
PROJECT_SOURCE_DATE_EPOCH=1781860238
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$PROJECT_SOURCE_DATE_EPOCH}"
case "$TARGET_PARTITION" in
    cache)
        TARGET_PARTITION_SIZE=268435456
        ROOTFS_UUID="89090000-0000-4000-8000-000000000023"
        ROOTFS_HASH_SEED="89090000-0000-4000-8000-000000000024"
        ROOTFS_AUTO_GROW=disabled
        ROOTFS_DEVICE="PARTLABEL=cache"
        ROOTFS_LABEL="debian-cache"
        BOOT_ROOT_ARGUMENT="PARTLABEL=cache"
        ROOTFS_IMAGE_SIZE=$((IMAGE_SIZE_MB * 1048576))
        ;;
    system)
        TARGET_PARTITION_SIZE=1288491008
        ROOTFS_UUID="89090000-0000-4000-8000-000000000021"
        ROOTFS_HASH_SEED="89090000-0000-4000-8000-000000000022"
        ROOTFS_AUTO_GROW=enabled
        ROOTFS_DEVICE="PARTLABEL=system"
        ROOTFS_LABEL="debian-system"
        BOOT_ROOT_ARGUMENT="PARTLABEL=system"
        ROOTFS_IMAGE_SIZE=$((IMAGE_SIZE_MB * 1048576))
        ;;
    large-rootfs)
        TARGET_PARTITION_SIZE=$LARGE_ROOTFS_SIZE
        ROOTFS_UUID="89090000-0000-4000-8000-000000000031"
        ROOTFS_HASH_SEED="89090000-0000-4000-8000-000000000032"
        ROOTFS_AUTO_GROW=disabled
        ROOTFS_DEVICE="/dev/mapper/ufi210-root"
        ROOTFS_LABEL="ufi210-root"
        BOOT_ROOT_ARGUMENT="/dev/mapper/ufi210-root"
        ROOTFS_IMAGE_SIZE=$LARGE_ROOTFS_FILESYSTEM_SIZE
        ;;
    *)
        printf '错误：TARGET_PARTITION 只允许 cache、system 或 large-rootfs\n' >&2
        exit 1
        ;;
esac
export E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH"

KERNEL_DIR="$PROJECT_ROOT/out/mainline/kernel"
KERNEL="$KERNEL_DIR/vmlinuz"
DTB="$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb"
MODULES="$KERNEL_DIR/modules-$KERNEL_RELEASE.tar.xz"
INITRAMFS_BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_debian_initramfs.sh"
INODE_TIME_TOOL="$PROJECT_ROOT/scripts/normalize_ext4_inode_times.py"
QCDT_BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_stock_qcdt.py"
INITRAMFS_INIT="$PROJECT_ROOT/patches/initramfs/init-debian.sh"
USB_GADGET_SCRIPT="$PROJECT_ROOT/patches/rootfs/usr/sbin/zu02-usb-gadget"
USB_WATCHDOG_SCRIPT="$PROJECT_ROOT/patches/rootfs/usr/sbin/zu02-usb-watchdog"
WCNSS_START_SCRIPT="$PROJECT_ROOT/patches/rootfs/usr/sbin/zu02-wcnss-start"
MPSS_START_SCRIPT="$PROJECT_ROOT/patches/rootfs/usr/sbin/zu02-mpss-start"
MODEM_PREPARE_SCRIPT="$PROJECT_ROOT/patches/rootfs/usr/sbin/zu02-modem-prepare"
MODEM_REGISTER_SCRIPT="$PROJECT_ROOT/patches/rootfs/usr/sbin/zu02-modem-register"
MODEM_TIME_SYNC_SCRIPT="$PROJECT_ROOT/patches/rootfs/usr/sbin/ufi210-modem-time-sync"
WWAN_IP_SCRIPT="$PROJECT_ROOT/patches/rootfs/usr/sbin/zu02-wwan-ip"
NMTUI_WRAPPER="$PROJECT_ROOT/patches/rootfs/usr/local/bin/nmtui"
REBOOT_COMPAT_SOURCE="$PROJECT_ROOT/src/reboot-compat.c"
WIFI_AP_PROFILE="$PROJECT_ROOT/patches/rootfs/etc/NetworkManager/system-connections/zu02-wifi-ap.nmconnection"
USB_MANAGEMENT_CONF="$PROJECT_ROOT/patches/rootfs/etc/NetworkManager/conf.d/10-ufi210-usb-management.conf"
WIFI_MAC_CONF="$PROJECT_ROOT/patches/rootfs/etc/NetworkManager/conf.d/20-ufi210-wifi-mac.conf"
WCNSS_FIRMWARE_DIR="$PROJECT_ROOT/resource/backup/0.modem/image"
MPSS_FIRMWARE_DIR="$PROJECT_ROOT/resource/backup/0.modem/image"
WCNSS_NV="$PROJECT_ROOT/resource/backup/persist/WCNSS_qcom_wlan_nv.bin"
INITRAMFS="$OUT_DIR/initramfs-zu02-debian"
QCDT="$OUT_DIR/qcdt-zu02-dw01.img"
REFERENCE_BOOT="$PROJECT_ROOT/resource/backup/19.boot.img"
ROOTFS="$BUILD_DIR/rootfs-armhf"
REGULATORY_DB="$ROOTFS/usr/lib/firmware/regulatory.db-upstream"
REGULATORY_DB_SIGNATURE="$ROOTFS/usr/lib/firmware/regulatory.db.p7s-upstream"
IMAGE="$OUT_DIR/debian-${SUITE}-armhf-${TARGET_PARTITION}.ext4"
ROOTFS_SYSTEM_IMAGE=""
ROOTFS_CACHE_IMAGE=""
ROOTFS_USERDATA_IMAGE=""
if [[ "$TARGET_PARTITION" == large-rootfs ]]; then
    IMAGE="$BUILD_DIR/debian-${SUITE}-armhf-${TARGET_PARTITION}.ext4"
    ROOTFS_SYSTEM_IMAGE="$OUT_DIR/debian-${SUITE}-armhf-large-rootfs-system.img"
    ROOTFS_CACHE_IMAGE="$OUT_DIR/debian-${SUITE}-armhf-large-rootfs-cache.img"
    ROOTFS_USERDATA_IMAGE="$OUT_DIR/debian-${SUITE}-armhf-large-rootfs-userdata.img"
fi
DATA_IMAGE="$OUT_DIR/debian-${SUITE}-armhf-data.ext4"
BOOT_IMAGE="$OUT_DIR/boot-debian-${TARGET_PARTITION}.img"
ROOTFS_TARBALL="$OUT_DIR/debian-${SUITE}-armhf-${TARGET_PARTITION}-rootfs.tar.xz"
PACKAGE_LIST="$OUT_DIR/packages.txt"
MANIFEST="$OUT_DIR/BUILD-MANIFEST.txt"
WCNSS_MANIFEST="$OUT_DIR/WCNSS-FIRMWARE-MANIFEST.txt"
MPSS_MANIFEST="$OUT_DIR/MPSS-FIRMWARE-MANIFEST.txt"
WCNSS_FIRMWARE_FILES=(
    wcnss.mdt
    wcnss.b00
    wcnss.b01
    wcnss.b02
    wcnss.b04
    wcnss.b06
    wcnss.b09
    wcnss.b10
    wcnss.b11
    wcnss.b12
)
MPSS_FIRMWARE_FILES=(
    mba.mbn
    modem.mdt
    modem.b00
    modem.b01
    modem.b02
    modem.b03
    modem.b05
    modem.b06
    modem.b07
    modem.b08
    modem.b09
    modem.b10
    modem.b11
    modem.b12
    modem.b13
    modem.b14
    modem.b15
    modem.b16
    modem.b19
    modem.b20
    modem.b21
    modem.b22
    modem.b23
    modem.b24
)

log() {
    printf '[%(%H:%M:%S)T] %s\n' -1 "$*"
}

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

for command_name in arm-linux-gnueabihf-gcc awk cat chroot dd debootstrap debugfs depmod du dumpe2fs e2fsck file gpgv grep mkfs.ext4 openssl python3 qemu-arm-static realpath sed sha256sum sort stat tar touch truncate tune2fs wget xz; do
    require_command "$command_name"
done
for required in "$KERNEL" "$DTB" "$MODULES" "$INITRAMFS_BUILD_SCRIPT" "$INODE_TIME_TOOL" "$INITRAMFS_INIT" \
    "$QCDT_BUILD_SCRIPT" \
    "$USB_GADGET_SCRIPT" "$USB_WATCHDOG_SCRIPT" "$WCNSS_START_SCRIPT" "$MPSS_START_SCRIPT" \
    "$MODEM_PREPARE_SCRIPT" "$MODEM_REGISTER_SCRIPT" "$WWAN_IP_SCRIPT" \
    "$NMTUI_WRAPPER" "$REBOOT_COMPAT_SOURCE" "$WIFI_AP_PROFILE" "$USB_MANAGEMENT_CONF" "$WIFI_MAC_CONF" \
    "$WCNSS_NV" "$REFERENCE_BOOT"; do
    [[ -s "$required" ]] || die "缺少输入文件：$required"
done
for firmware_name in "${MPSS_FIRMWARE_FILES[@]}"; do
    [[ -s "$MPSS_FIRMWARE_DIR/$firmware_name" ]] \
        || die "缺少 MPSS 固件：$MPSS_FIRMWARE_DIR/$firmware_name"
done
for firmware_name in "${WCNSS_FIRMWARE_FILES[@]}"; do
    [[ -s "$WCNSS_FIRMWARE_DIR/$firmware_name" ]] \
        || die "缺少 WCNSS 固件：$WCNSS_FIRMWARE_DIR/$firmware_name"
done
[[ "$SUITE" == "bookworm" ]] || die "当前只固定支持 Debian bookworm"
if [[ -n "${DEBIAN_MIRROR+x}" || -n "${DEBIAN_SECURITY_MIRROR+x}" ]]; then
    die "正式构建已固定 Debian Snapshot，不再接受 DEBIAN_MIRROR/DEBIAN_SECURITY_MIRROR 覆盖"
fi
[[ "$SNAPSHOT_TRANSPORT_ORIGIN" =~ ^https://snapshot\.debian\.org(:[0-9]{1,5})?$ ]] \
    || die "DEBIAN_SNAPSHOT_TRANSPORT_ORIGIN 只允许 snapshot.debian.org 的 HTTPS 端口覆盖"
[[ "$SOURCE_DATE_EPOCH" == "$PROJECT_SOURCE_DATE_EPOCH" ]] \
    || die "正式 rootfs SOURCE_DATE_EPOCH 必须为 $PROJECT_SOURCE_DATE_EPOCH"
[[ -s "$DEBIAN_KEYRING" ]] \
    || die "缺少 Debian archive keyring：$DEBIAN_KEYRING；请先运行 scripts/install_debian_bookworm_keyring.sh"
[[ "$IMAGE_SIZE_MB" =~ ^[0-9]+$ ]] || die "IMAGE_SIZE_MB 必须是整数"
(( IMAGE_SIZE_MB > 0 )) || die "IMAGE_SIZE_MB 必须大于 0"
(( ROOTFS_IMAGE_SIZE < TARGET_PARTITION_SIZE )) \
    || die "${TARGET_PARTITION} 镜像必须小于目标设备 $TARGET_PARTITION_SIZE 字节"
[[ "$DATA_IMAGE_SIZE_MB" =~ ^[0-9]+$ ]] || die "DATA_IMAGE_SIZE_MB 必须是整数"
(( DATA_IMAGE_SIZE_MB > 0 && DATA_IMAGE_SIZE_MB * 1048576 < DATA_PARTITION_SIZE )) \
    || die "data 镜像必须小于 userdata 分区 $DATA_PARTITION_SIZE 字节"

mkdir -p "$BUILD_DIR" "$OUT_DIR"

script_sha256="$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')"
kernel_sha256="$(sha256sum "$KERNEL" | awk '{print $1}')"
dtb_sha256="$(sha256sum "$DTB" | awk '{print $1}')"
modules_sha256="$(sha256sum "$MODULES" | awk '{print $1}')"
initramfs_build_script_sha256="$(sha256sum "$INITRAMFS_BUILD_SCRIPT" | awk '{print $1}')"
inode_time_tool_sha256="$(sha256sum "$INODE_TIME_TOOL" | awk '{print $1}')"
qcdt_build_script_sha256="$(sha256sum "$QCDT_BUILD_SCRIPT" | awk '{print $1}')"
initramfs_init_sha256="$(sha256sum "$INITRAMFS_INIT" | awk '{print $1}')"
usb_gadget_script_sha256="$(sha256sum "$USB_GADGET_SCRIPT" | awk '{print $1}')"
usb_watchdog_script_sha256="$(sha256sum "$USB_WATCHDOG_SCRIPT" | awk '{print $1}')"
wcnss_start_script_sha256="$(sha256sum "$WCNSS_START_SCRIPT" | awk '{print $1}')"
mpss_start_script_sha256="$(sha256sum "$MPSS_START_SCRIPT" | awk '{print $1}')"
modem_prepare_script_sha256="$(sha256sum "$MODEM_PREPARE_SCRIPT" | awk '{print $1}')"
modem_register_script_sha256="$(sha256sum "$MODEM_REGISTER_SCRIPT" | awk '{print $1}')"
modem_time_sync_script_sha256="$(sha256sum "$MODEM_TIME_SYNC_SCRIPT" | awk '{print $1}')"
wwan_ip_script_sha256="$(sha256sum "$WWAN_IP_SCRIPT" | awk '{print $1}')"
nmtui_wrapper_sha256="$(sha256sum "$NMTUI_WRAPPER" | awk '{print $1}')"
reboot_compat_source_sha256="$(sha256sum "$REBOOT_COMPAT_SOURCE" | awk '{print $1}')"
wifi_ap_profile_sha256="$(sha256sum "$WIFI_AP_PROFILE" | awk '{print $1}')"
usb_management_conf_sha256="$(sha256sum "$USB_MANAGEMENT_CONF" | awk '{print $1}')"
wifi_mac_conf_sha256="$(sha256sum "$WIFI_MAC_CONF" | awk '{print $1}')"
wcnss_nv_sha256="$(sha256sum "$WCNSS_NV" | awk '{print $1}')"
wcnss_firmware_sha256="$(
    for firmware_name in "${WCNSS_FIRMWARE_FILES[@]}"; do
        printf '%s  %s\n' \
            "$(sha256sum "$WCNSS_FIRMWARE_DIR/$firmware_name" | awk '{print $1}')" \
            "$firmware_name"
    done | sha256sum | awk '{print $1}'
)"
mpss_firmware_sha256="$(
    for firmware_name in "${MPSS_FIRMWARE_FILES[@]}"; do
        printf '%s  %s\n' \
            "$(sha256sum "$MPSS_FIRMWARE_DIR/$firmware_name" | awk '{print $1}')" \
            "$firmware_name"
    done | sha256sum | awk '{print $1}'
)"
keyring_sha256="$(sha256sum "$DEBIAN_KEYRING" | awk '{print $1}')"

rootfs_artifacts_present=0
if [[ "$TARGET_PARTITION" == large-rootfs ]]; then
    if [[ -s "$ROOTFS_SYSTEM_IMAGE" && -s "$ROOTFS_CACHE_IMAGE" \
        && -s "$ROOTFS_USERDATA_IMAGE" ]]; then
        rootfs_artifacts_present=1
    fi
elif [[ -s "$IMAGE" ]]; then
    rootfs_artifacts_present=1
fi

if [[ "$FORCE" != "1" && "$rootfs_artifacts_present" == 1 \
    && -s "$BOOT_IMAGE" && -s "$INITRAMFS" && -s "$QCDT" \
    && -s "$WCNSS_MANIFEST" && -s "$MPSS_MANIFEST" && -f "$MANIFEST" ]] \
    && grep -qx "build_script_sha256=$script_sha256" "$MANIFEST" \
    && grep -qx "kernel_sha256=$kernel_sha256" "$MANIFEST" \
    && grep -qx "dtb_sha256=$dtb_sha256" "$MANIFEST" \
    && grep -qx "modules_sha256=$modules_sha256" "$MANIFEST" \
    && grep -qx "initramfs_build_script_sha256=$initramfs_build_script_sha256" "$MANIFEST" \
    && grep -qx "inode_time_tool_sha256=$inode_time_tool_sha256" "$MANIFEST" \
    && grep -qx "qcdt_build_script_sha256=$qcdt_build_script_sha256" "$MANIFEST" \
    && grep -qx "qcdt_sha256=$(sha256sum "$QCDT" | awk '{print $1}')" "$MANIFEST" \
    && grep -qx "initramfs_init_sha256=$initramfs_init_sha256" "$MANIFEST" \
    && grep -qx "usb_gadget_script_sha256=$usb_gadget_script_sha256" "$MANIFEST" \
    && grep -qx "usb_watchdog_script_sha256=$usb_watchdog_script_sha256" "$MANIFEST" \
    && grep -qx "wcnss_start_script_sha256=$wcnss_start_script_sha256" "$MANIFEST" \
    && grep -qx "mpss_start_script_sha256=$mpss_start_script_sha256" "$MANIFEST" \
    && grep -qx "modem_prepare_script_sha256=$modem_prepare_script_sha256" "$MANIFEST" \
    && grep -qx "modem_register_script_sha256=$modem_register_script_sha256" "$MANIFEST" \
    && grep -qx "modem_time_sync_script_sha256=$modem_time_sync_script_sha256" "$MANIFEST" \
    && grep -qx "wwan_ip_script_sha256=$wwan_ip_script_sha256" "$MANIFEST" \
    && grep -qx "nmtui_wrapper_sha256=$nmtui_wrapper_sha256" "$MANIFEST" \
    && grep -qx "reboot_compat_source_sha256=$reboot_compat_source_sha256" "$MANIFEST" \
    && grep -qx "wifi_ap_profile_sha256=$wifi_ap_profile_sha256" "$MANIFEST" \
    && grep -qx "usb_management_conf_sha256=$usb_management_conf_sha256" "$MANIFEST" \
    && grep -qx "wifi_mac_conf_sha256=$wifi_mac_conf_sha256" "$MANIFEST" \
    && grep -qx "wcnss_firmware_sha256=$wcnss_firmware_sha256" "$MANIFEST" \
    && grep -qx "mpss_firmware_sha256=$mpss_firmware_sha256" "$MANIFEST" \
    && grep -qx "wcnss_nv_sha256=$wcnss_nv_sha256" "$MANIFEST" \
    && grep -qx "debian_keyring_sha256=$keyring_sha256" "$MANIFEST" \
    && grep -qx "debian_snapshot_timestamp=$DEBIAN_SNAPSHOT_TIMESTAMP" "$MANIFEST" \
    && grep -qx "debian_snapshot_mirror=$MANIFEST_MIRROR" "$MANIFEST" \
    && grep -qx "debian_security_snapshot_mirror=$MANIFEST_SECURITY_MIRROR" "$MANIFEST" \
    && grep -qx "debian_runtime_mirror=$RUNTIME_MIRROR" "$MANIFEST" \
    && grep -qx "debian_runtime_security_mirror=$RUNTIME_SECURITY_MIRROR" "$MANIFEST" \
    && grep -qx "snapshot_download_retries=$SNAPSHOT_DOWNLOAD_RETRIES" "$MANIFEST" \
    && grep -qx "source_date_epoch=$SOURCE_DATE_EPOCH" "$MANIFEST" \
    && grep -qx "target_partition=$TARGET_PARTITION" "$MANIFEST" \
    && grep -qx "target_partition_bytes=$TARGET_PARTITION_SIZE" "$MANIFEST" \
    && grep -qx "rootfs_auto_grow=$ROOTFS_AUTO_GROW" "$MANIFEST" \
    && grep -qx "root_password=$ROOT_PASSWORD" "$MANIFEST" \
    && grep -qx "rootfs_image_bytes=$ROOTFS_IMAGE_SIZE" "$MANIFEST" \
    && grep -qx "rootfs_uuid=$ROOTFS_UUID" "$MANIFEST" \
    && grep -qx "rootfs_hash_seed=$ROOTFS_HASH_SEED" "$MANIFEST" \
    && grep -qx "rootfs_device=$ROOTFS_DEVICE" "$MANIFEST" \
    && grep -qx "rootfs_label=$ROOTFS_LABEL" "$MANIFEST" \
    && { [[ "$TARGET_PARTITION" != large-rootfs ]] \
        || { grep -qx "storage_layout=dm-linear-system-cache-userdata" "$MANIFEST" \
            && grep -qx "dm_total_sectors=$LARGE_ROOTFS_SECTORS" "$MANIFEST" \
            && grep -qx "dm_total_bytes=$LARGE_ROOTFS_SIZE" "$MANIFEST" \
            && grep -qx "dm_filesystem_bytes=$LARGE_ROOTFS_FILESYSTEM_SIZE" "$MANIFEST" \
            && grep -qx "dm_table=$LARGE_ROOTFS_TABLE" "$MANIFEST" \
            && grep -qx "rootfs_segments=complete-prebuilt-filesystem" "$MANIFEST"; }; } \
    && { [[ "$TARGET_PARTITION" != system ]] \
        || { [[ -s "$DATA_IMAGE" ]] \
            && grep -qx "data_partition=userdata" "$MANIFEST" \
            && grep -qx "data_partition_bytes=$DATA_PARTITION_SIZE" "$MANIFEST" \
            && grep -qx "data_image_bytes=$((DATA_IMAGE_SIZE_MB * 1048576))" "$MANIFEST" \
            && grep -qx "data_uuid=$DATA_UUID" "$MANIFEST" \
            && grep -qx "data_hash_seed=$DATA_HASH_SEED" "$MANIFEST" \
            && grep -qx "data_label=$DATA_LABEL" "$MANIFEST" \
            && grep -qx "data_mount=/data" "$MANIFEST" \
            && grep -qx "data_auto_grow=enabled" "$MANIFEST"; }; }; then
    image_recorded="$(sed -n 's/^rootfs_image_sha256=//p' "$MANIFEST")"
    boot_recorded="$(sed -n 's/^boot_image_sha256=//p' "$MANIFEST")"
    initramfs_recorded="$(sed -n 's/^initramfs_sha256=//p' "$MANIFEST")"
    rootfs_matches=1
    data_matches=1
    if [[ "$TARGET_PARTITION" == large-rootfs ]]; then
        for segment_spec in \
            "rootfs_system_image:$ROOTFS_SYSTEM_IMAGE" \
            "rootfs_cache_image:$ROOTFS_CACHE_IMAGE" \
            "rootfs_userdata_image:$ROOTFS_USERDATA_IMAGE"; do
            segment_key="${segment_spec%%:*}"
            segment_path="${segment_spec#*:}"
            segment_recorded="$(sed -n "s/^${segment_key}_sha256=//p" "$MANIFEST")"
            segment_bytes_recorded="$(sed -n "s/^${segment_key}_bytes=//p" "$MANIFEST")"
            [[ "$segment_recorded" == "$(sha256sum "$segment_path" | awk '{print $1}')" \
                && "$segment_bytes_recorded" == "$(stat -c %s "$segment_path")" ]] \
                || rootfs_matches=0
        done
        logical_rootfs_hash="$(cat "$ROOTFS_SYSTEM_IMAGE" "$ROOTFS_CACHE_IMAGE" \
            "$ROOTFS_USERDATA_IMAGE" | sha256sum | awk '{print $1}')"
        [[ "$image_recorded" == "$logical_rootfs_hash" ]] || rootfs_matches=0
    else
        [[ "$image_recorded" == "$(sha256sum "$IMAGE" | awk '{print $1}')" ]] \
            || rootfs_matches=0
    fi
    if [[ "$TARGET_PARTITION" == system ]]; then
        data_recorded="$(sed -n 's/^data_image_sha256=//p' "$MANIFEST")"
        [[ "$data_recorded" == "$(sha256sum "$DATA_IMAGE" | awk '{print $1}')" ]] \
            || data_matches=0
    fi
    if [[ "$rootfs_matches" == 1 \
        && "$boot_recorded" == "$(sha256sum "$BOOT_IMAGE" | awk '{print $1}')" \
        && "$initramfs_recorded" == "$(sha256sum "$INITRAMFS" | awk '{print $1}')" \
        && "$data_matches" == 1 ]]; then
        log "输入与 Debian ${TARGET_PARTITION} 产物未变化，跳过重复构建"
        exit 0
    fi
fi

case "$(realpath -m "$ROOTFS")" in
    "$(realpath -m "$BUILD_DIR")"/*) ;;
    *) die "拒绝清理 BUILD_DIR 之外的 rootfs：$ROOTFS" ;;
esac
rm -rf -- "$ROOTFS"
mkdir -p "$ROOTFS"

retry_bin="$BUILD_DIR/snapshot-retry-bin"
case "$(realpath -m "$retry_bin")" in
    "$(realpath -m "$BUILD_DIR")"/*) ;;
    *) die "Snapshot 下载包装器越出 BUILD_DIR：$retry_bin" ;;
esac
rm -rf -- "$retry_bin"
mkdir -p "$retry_bin"
real_wget="$(command -v wget)"
cat > "$retry_bin/wget" <<EOF
#!/bin/sh
attempt=1
while :; do
    if "$real_wget" "\$@"; then
        exit 0
    else
        rc=\$?
    fi
    if [ "\$attempt" -ge "$SNAPSHOT_DOWNLOAD_RETRIES" ]; then
        exit "\$rc"
    fi
    sleep \$((attempt * 2))
    attempt=\$((attempt + 1))
done
EOF
chmod 0755 "$retry_bin/wget"

base_packages="systemd-sysv,udev,dbus,kmod,busybox-static,openssh-server,iproute2,netbase,iputils-ping,dnsmasq,ca-certificates,curl,procps,util-linux,e2fsprogs,dmsetup"
log "debootstrap Debian $SUITE armhf 最小 rootfs"
PATH="$retry_bin:$PATH" debootstrap \
    --foreign \
    --arch=armhf \
    --variant=minbase \
    --keyring="$DEBIAN_KEYRING" \
    --force-check-gpg \
    --include="$base_packages" \
    "$SUITE" "$ROOTFS" "$MIRROR"

install -m 0755 "$(command -v qemu-arm-static)" "$ROOTFS/usr/bin/qemu-arm-static"
# 构建宿主可用 hosts 把固定 Snapshot 透明转发到受控隧道；最终镜像会重建此文件。
install -m 0644 /etc/hosts "$ROOTFS/etc/hosts"
log "验证 qemu-arm binfmt_misc 能执行 ARM 子进程"
if ! chroot "$ROOTFS" /usr/bin/qemu-arm-static /bin/bash -lc \
    '/bin/true && /usr/bin/grep --version >/dev/null'; then
    die "qemu-arm binfmt_misc 未启用；请在特权容器中安装 binfmt-support，挂载 binfmt_misc 并执行 update-binfmts --enable qemu-arm"
fi
log "通过 qemu-arm-static 和 ARM bash 执行 debootstrap 第二阶段"
chroot "$ROOTFS" /usr/bin/qemu-arm-static /bin/bash -lc \
    '/debootstrap/debootstrap --second-stage'

cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb [check-valid-until=no] $MIRROR $SUITE main
deb [check-valid-until=no] $MIRROR ${SUITE}-updates main
deb [check-valid-until=no] $SECURITY_MIRROR ${SUITE}-security main
deb [check-valid-until=no] $MIRROR ${SUITE}-backports main
EOF
cat > "$ROOTFS/etc/apt/apt.conf.d/99zu02-build-snapshot" <<'EOF'
Acquire::Check-Valid-Until "false";
Acquire::Retries "5";
EOF
cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"

log "安装 NetworkManager、Wi-Fi/AP、MPSS/QRTR 和 Debian adbd armhf"
chroot "$ROOTFS" /usr/bin/qemu-arm-static /bin/bash -lc \
    "export DEBIAN_FRONTEND=noninteractive; apt-get update; \
    apt-get install -y --no-install-recommends \
        hostapd iw libpam-systemd libqmi-utils locales modemmanager network-manager nftables qrtr-tools \
        rfkill rmtfs systemd-timesyncd usr-is-merged wireless-regdb wpasupplicant; \
    apt-get install -y --no-install-recommends -t ${SUITE}-backports adbd; \
    apt-get purge -y usrmerge perl libperl5.36 perl-modules-5.36 \
        libfile-find-rule-perl libnumber-compare-perl libtext-glob-perl"

log "生成 nmtui 专用简体中文 locale"
chroot "$ROOTFS" /usr/bin/qemu-arm-static /bin/bash -lc \
    "sed -i 's/^#[[:space:]]*zh_CN.UTF-8[[:space:]]\+UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen; \
    locale-gen zh_CN.UTF-8; locale -a | grep -Fqx zh_CN.utf8"
nmtui_catalog="$ROOTFS/usr/share/locale/zh_CN/LC_MESSAGES/NetworkManager.mo"
[[ -s "$nmtui_catalog" ]] || die "NetworkManager 包缺少 zh_CN 翻译目录"
nmtui_catalog_staging="$BUILD_DIR/NetworkManager.zh_CN.mo"
install -m 0644 "$nmtui_catalog" "$nmtui_catalog_staging"
locale_archive="$ROOTFS/usr/lib/locale/locale-archive"
[[ -s "$locale_archive" ]] || die "locale-gen 未生成 locale archive"
locale_archive_staging="$BUILD_DIR/locale-archive.zh_CN"
install -m 0644 "$locale_archive" "$locale_archive_staging"
chroot "$ROOTFS" /usr/bin/qemu-arm-static /bin/bash -lc \
    'export DEBIAN_FRONTEND=noninteractive; apt-get purge -y locales libc-l10n'

# 固定快照只用于生成可复现镜像；设备安装后仍从 Debian 正常更新源获取安全更新。
cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $RUNTIME_MIRROR $SUITE main
deb $RUNTIME_MIRROR ${SUITE}-updates main
deb $RUNTIME_SECURITY_MIRROR ${SUITE}-security main
deb $RUNTIME_MIRROR ${SUITE}-backports main
EOF
rm -f "$ROOTFS/etc/apt/apt.conf.d/99zu02-build-snapshot"

printf 'ufi210\n' > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 ufi210
EOF
root_mount_options=defaults,noatime
if [[ "$ROOTFS_AUTO_GROW" == enabled ]]; then
    root_mount_options+=,x-systemd.growfs
fi
cat > "$ROOTFS/etc/fstab" <<EOF
$ROOTFS_DEVICE / ext4 $root_mount_options 0 1
EOF
if [[ "$TARGET_PARTITION" == system ]]; then
    cat >> "$ROOTFS/etc/fstab" <<'EOF'
PARTLABEL=userdata /data ext4 defaults,noatime,nosuid,nodev,nofail,x-systemd.growfs,x-systemd.device-timeout=30s 0 2
EOF
fi
cat >> "$ROOTFS/etc/fstab" <<EOF
PARTLABEL=modem /firmware vfat ro,nosuid,nodev,noexec,fmask=0133,dmask=0022,nofail,x-systemd.device-timeout=30s 0 0
PARTLABEL=persist /persist ext4 ro,noload,nosuid,nodev,noexec,nofail,x-systemd.device-timeout=30s 0 0
proc /proc proc defaults 0 0
EOF
root_password_hash="$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -salt zu02bookworm -stdin)"
awk -F: -v OFS=: -v hash="$root_password_hash" \
    '$1 == "root" {$2=hash; $3="20623"} {print}' \
    "$ROOTFS/etc/shadow" > "$ROOTFS/etc/shadow.new"
chmod --reference="$ROOTFS/etc/shadow" "$ROOTFS/etc/shadow.new"
chown --reference="$ROOTFS/etc/shadow" "$ROOTFS/etc/shadow.new"
mv "$ROOTFS/etc/shadow.new" "$ROOTFS/etc/shadow"

mkdir -p "$ROOTFS/etc/ssh/sshd_config.d" "$ROOTFS/etc/systemd/system/ssh.service.d"
cat > "$ROOTFS/etc/ssh/sshd_config.d/10-zu02.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
EOF
cat > "$ROOTFS/etc/systemd/system/ssh.service.d/10-zu02.conf" <<'EOF'
[Unit]
After=zu02-firewall.service zu02-usb-network.service
BindsTo=zu02-firewall.service
Wants=zu02-usb-network.service

[Service]
ExecStartPre=
ExecStartPre=/usr/bin/find /etc/ssh -maxdepth 1 -type f -name ssh_host_*_key.* ! -name *.pub -delete
ExecStartPre=/usr/bin/ssh-keygen -A
ExecStartPre=/usr/sbin/sshd -t
EOF

mkdir -p \
    "$ROOTFS/usr/sbin" \
    "$ROOTFS/usr/local/bin" \
    "$ROOTFS/system/bin" \
    "$ROOTFS/etc/systemd/system" \
    "$ROOTFS/etc/NetworkManager/dispatcher.d" \
    "$ROOTFS/etc/NetworkManager/conf.d" \
    "$ROOTFS/etc/NetworkManager/system-connections" \
    "$ROOTFS/firmware" \
    "$ROOTFS/persist"
if [[ "$TARGET_PARTITION" == system ]]; then
    mkdir -p "$ROOTFS/data"
fi
install -d -m 1777 "$ROOTFS/data/local/tmp"
install -m 0755 "$USB_GADGET_SCRIPT" "$ROOTFS/usr/sbin/zu02-usb-gadget"
install -m 0755 "$USB_WATCHDOG_SCRIPT" "$ROOTFS/usr/sbin/zu02-usb-watchdog"
install -m 0755 "$WCNSS_START_SCRIPT" "$ROOTFS/usr/sbin/zu02-wcnss-start"
install -m 0755 "$MPSS_START_SCRIPT" "$ROOTFS/usr/sbin/zu02-mpss-start"
install -m 0755 "$MODEM_PREPARE_SCRIPT" "$ROOTFS/usr/sbin/zu02-modem-prepare"
install -m 0755 "$MODEM_REGISTER_SCRIPT" "$ROOTFS/usr/sbin/zu02-modem-register"
install -m 0755 "$MODEM_TIME_SYNC_SCRIPT" "$ROOTFS/usr/sbin/ufi210-modem-time-sync"
install -m 0755 "$WWAN_IP_SCRIPT" "$ROOTFS/etc/NetworkManager/dispatcher.d/90-zu02-wwan-ip"
install -m 0755 "$NMTUI_WRAPPER" "$ROOTFS/usr/local/bin/nmtui"
arm-linux-gnueabihf-gcc \
    -Os -static -fno-ident -fno-asynchronous-unwind-tables \
    -Wl,--build-id=none -Wl,-z,relro,-z,now,-z,noexecstack -s \
    -o "$ROOTFS/system/bin/reboot" "$REBOOT_COMPAT_SOURCE"
file "$ROOTFS/system/bin/reboot" | grep -q 'ELF 32-bit.*ARM.*statically linked' \
    || die "ADB reboot 兼容程序不是 32 位 ARM 静态 ELF"
reboot_test_rc=0
chroot "$ROOTFS" /usr/bin/qemu-arm-static /system/bin/reboot unsupported \
    >/dev/null 2>&1 || reboot_test_rc=$?
(( reboot_test_rc == 2 )) || die "ADB reboot 兼容程序的参数校验失败"
reboot_compat_binary_sha256="$(sha256sum "$ROOTFS/system/bin/reboot" | awk '{print $1}')"
install -m 0600 "$WIFI_AP_PROFILE" \
    "$ROOTFS/etc/NetworkManager/system-connections/zu02-wifi-ap.nmconnection"
install -m 0644 "$USB_MANAGEMENT_CONF" \
    "$ROOTFS/etc/NetworkManager/conf.d/10-ufi210-usb-management.conf"
install -m 0644 "$WIFI_MAC_CONF" \
    "$ROOTFS/etc/NetworkManager/conf.d/20-ufi210-wifi-mac.conf"

cat > "$ROOTFS/etc/systemd/system/zu02-usb-gadget.service" <<'EOF'
[Unit]
Description=ZU02 fixed RNDIS and ACM USB gadget
Wants=sys-kernel-config.mount
After=sys-kernel-config.mount systemd-udevd.service
Before=zu02-usb-network.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/zu02-usb-gadget setup
ExecStartPost=/usr/sbin/zu02-usb-gadget activate
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > "$ROOTFS/etc/systemd/system/adbd.service" <<'EOF'
[Unit]
Description=Android Debug Bridge daemon on the USB management network
After=zu02-firewall.service zu02-usb-network.service
BindsTo=zu02-firewall.service
Wants=zu02-usb-network.service
StartLimitIntervalSec=0

[Service]
Type=notify
Environment=ADBD_PORT=5555
ExecStart=/usr/lib/android-sdk/platform-tools/adbd
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat > "$ROOTFS/etc/systemd/system/zu02-usb-watchdog.service" <<'EOF'
[Unit]
Description=Recover the UFI210 USB management gadget
After=zu02-usb-gadget.service zu02-usb-network.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/zu02-usb-watchdog
EOF

cat > "$ROOTFS/etc/systemd/system/zu02-usb-watchdog.timer" <<'EOF'
[Unit]
Description=Periodically verify the UFI210 USB management gadget

[Timer]
OnBootSec=90s
OnUnitActiveSec=5s
AccuracySec=1s
RandomizedDelaySec=0
Unit=zu02-usb-watchdog.service

[Install]
WantedBy=timers.target
EOF

cat > "$ROOTFS/usr/sbin/zu02-usb-network" <<'EOF'
#!/bin/sh
set -eu

for _ in $(seq 1 30); do
    [ -e /sys/class/net/usb0 ] && break
    sleep 1
done
[ -e /sys/class/net/usb0 ]

ip link set usb0 up
ip addr replace 192.168.68.1/24 dev usb0
EOF
chmod 0755 "$ROOTFS/usr/sbin/zu02-usb-network"

cat > "$ROOTFS/etc/systemd/system/zu02-usb-network.service" <<'EOF'
[Unit]
Description=ZU02 USB management network
Requires=zu02-usb-gadget.service
After=zu02-usb-gadget.service
Before=ssh.service dnsmasq.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/zu02-usb-network
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > "$ROOTFS/etc/systemd/system/zu02-wcnss.service" <<'EOF'
[Unit]
Description=Start ZU02 Qualcomm WCNSS remote processor
After=systemd-udev-trigger.service local-fs.target
Before=NetworkManager.service
ConditionPathExistsGlob=/sys/class/remoteproc/remoteproc*/state
RequiresMountsFor=/firmware /persist

[Service]
Type=oneshot
ExecStart=/usr/sbin/zu02-wcnss-start
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

mkdir -p \
    "$ROOTFS/etc/modprobe.d" \
    "$ROOTFS/etc/systemd/system/rmtfs.service.d" \
    "$ROOTFS/etc/systemd/system/ModemManager.service.d"
cat > "$ROOTFS/etc/modprobe.d/zu02-mpss.conf" <<'EOF'
# Only rmtfs may register MPSS, after /firmware is mounted and before it synchronizes startup.
blacklist qcom_q6v5_mss
EOF
cat > "$ROOTFS/etc/systemd/system/rmtfs.service.d/10-zu02-read-only.conf" <<'EOF'
[Unit]
After=local-fs.target systemd-udev-trigger.service qrtr-ns.service
Before=zu02-mpss.service
RequiresMountsFor=/firmware

[Service]
ExecStartPre=/sbin/modprobe qcom_q6v5_mss
ExecStart=
ExecStart=/usr/bin/rmtfs -r -P -s
EOF
cat > "$ROOTFS/etc/systemd/system/zu02-mpss.service" <<'EOF'
[Unit]
Description=Start ZU02 Qualcomm MPSS remote processor
Wants=qrtr-ns.service
Requires=rmtfs.service
After=local-fs.target systemd-udev-trigger.service qrtr-ns.service rmtfs.service
Before=zu02-modem-prepare.service ModemManager.service
RequiresMountsFor=/firmware

[Service]
Type=oneshot
ExecStart=/usr/sbin/zu02-mpss-start
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
cat > "$ROOTFS/etc/systemd/system/zu02-modem-prepare.service" <<'EOF'
[Unit]
Description=Open ZU02 MSM8909 QMI and BAM-DMUX ports
Requires=zu02-mpss.service qrtr-ns.service rmtfs.service
After=zu02-mpss.service qrtr-ns.service rmtfs.service
Before=ModemManager.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/sbin/zu02-modem-prepare
RemainAfterExit=yes
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
cat > "$ROOTFS/etc/systemd/system/ModemManager.service.d/10-zu02-dpm.conf" <<'EOF'
[Unit]
Requires=zu02-modem-prepare.service
After=zu02-modem-prepare.service
EOF
cat > "$ROOTFS/etc/systemd/system/zu02-modem-register.service" <<'EOF'
[Unit]
Description=Set ZU02 modem to 3G and 4G with 4G preferred
Requires=ModemManager.service rmtfs.service
After=ModemManager.service rmtfs.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/sbin/zu02-modem-register
RemainAfterExit=yes
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
cat > "$ROOTFS/etc/systemd/system/ufi210-modem-time-sync.service" <<'EOF'
[Unit]
Description=Seed the UFI210 system clock from validated modem time
Requires=zu02-modem-register.service
After=zu02-modem-register.service systemd-timesyncd.service

[Service]
Type=oneshot
RuntimeDirectory=ufi210
ExecStart=/usr/sbin/ufi210-modem-time-sync
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > "$ROOTFS/etc/dnsmasq.d/zu02-usb.conf" <<'EOF'
port=0
interface=usb0
bind-dynamic
dhcp-range=192.168.68.2,192.168.68.10,255.255.255.0,12h
dhcp-option=3
dhcp-option=6
EOF
mkdir -p "$ROOTFS/etc/systemd/system/dnsmasq.service.d"
cat > "$ROOTFS/etc/systemd/system/dnsmasq.service.d/10-zu02.conf" <<'EOF'
[Unit]
Requires=zu02-usb-network.service
After=zu02-usb-network.service
EOF

mkdir -p "$ROOTFS/etc/nftables.d"
cat > "$ROOTFS/etc/nftables.d/zu02-firewall.nft" <<'EOF'
table inet zu02_firewall {
    chain input {
        type filter hook input priority filter; policy accept;
        iifname "lo" accept
        iifname != "usb0" tcp dport { 22, 5555 } counter drop
        iifname "wwan0" ct state established,related accept
        iifname "wwan0" counter drop
    }
}
EOF
cat > "$ROOTFS/usr/sbin/zu02-firewall" <<'EOF'
#!/bin/sh
set -eu

delete_table() {
    if nft list table inet zu02_firewall >/dev/null 2>&1; then
        nft delete table inet zu02_firewall
    fi
}

case "${1:-start}" in
    start|reload)
        delete_table
        nft -f /etc/nftables.d/zu02-firewall.nft
        ;;
    stop)
        delete_table
        ;;
    *)
        echo "usage: $0 start|reload|stop" >&2
        exit 2
        ;;
esac
EOF
chmod 0755 "$ROOTFS/usr/sbin/zu02-firewall"
cat > "$ROOTFS/etc/systemd/system/zu02-firewall.service" <<'EOF'
[Unit]
Description=ZU02 firewall protecting USB-only management and WWAN ingress
Wants=network-pre.target
Before=network-pre.target shutdown.target
Conflicts=shutdown.target
DefaultDependencies=no
RefuseManualStop=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/zu02-firewall start
ExecReload=/usr/sbin/zu02-firewall reload
ExecStop=/usr/sbin/zu02-firewall stop

[Install]
WantedBy=sysinit.target
EOF

mkdir -p \
    "$ROOTFS/etc/systemd/system/getty.target.wants" \
    "$ROOTFS/etc/systemd/system/serial-getty@ttyGS0.service.d"
ln -sf /lib/systemd/system/serial-getty@.service \
    "$ROOTFS/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service"
cat > "$ROOTFS/etc/systemd/system/serial-getty@ttyGS0.service.d/10-zu02.conf" <<'EOF'
[Unit]
Requires=zu02-usb-gadget.service
After=zu02-usb-gadget.service
EOF

mkdir -p "$ROOTFS/etc/systemd/journald.conf.d" "$ROOTFS/var/log/journal"
cat > "$ROOTFS/etc/systemd/journald.conf.d/10-zu02.conf" <<'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=16M
SystemKeepFree=16M
RuntimeMaxUse=8M
EOF
printf 'LANG=C.UTF-8\n' > "$ROOTFS/etc/default/locale"

log "安装 $KERNEL_RELEASE 模块"
modules_tmp="$BUILD_DIR/modules-unpacked"
rm -rf -- "$modules_tmp"
mkdir -p "$modules_tmp" "$ROOTFS/usr/lib/modules"
tar -C "$modules_tmp" -xf "$MODULES"
cp -a "$modules_tmp/lib/modules/$KERNEL_RELEASE" "$ROOTFS/usr/lib/modules/"
rm -f "$ROOTFS/usr/lib/modules/$KERNEL_RELEASE/build" "$ROOTFS/usr/lib/modules/$KERNEL_RELEASE/source"
depmod -b "$ROOTFS" "$KERNEL_RELEASE"

log "建立指向设备原厂 modem/persist 分区的 WCNSS 固件和校准 NV 链接"
mkdir -p "$ROOTFS/usr/lib/firmware/wlan/prima"
{
    printf 'firmware_source=device:PARTLABEL=modem:/image\n'
    printf 'nv_source=device:PARTLABEL=persist:/WCNSS_qcom_wlan_nv.bin\n'
    printf 'packaging=symlink-only\n'
    for firmware_name in "${WCNSS_FIRMWARE_FILES[@]}"; do
        ln -sfn "/firmware/image/$firmware_name" \
            "$ROOTFS/usr/lib/firmware/$firmware_name"
        printf '%s  %s\n' \
            "$(sha256sum "$WCNSS_FIRMWARE_DIR/$firmware_name" | awk '{print $1}')" \
            "$firmware_name"
    done
    ln -sfn /persist/WCNSS_qcom_wlan_nv.bin \
        "$ROOTFS/usr/lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin"
    printf '%s  %s\n' "$wcnss_nv_sha256" 'wlan/prima/WCNSS_qcom_wlan_nv.bin'
} > "$WCNSS_MANIFEST"

log "建立指向原厂 modem 分区的 MPSS 固件符号链接"
{
    printf 'source=device:PARTLABEL=modem:/image\n'
    printf 'packaging=symlink-only\n'
    for firmware_name in "${MPSS_FIRMWARE_FILES[@]}"; do
        ln -sfn "/firmware/image/$firmware_name" \
            "$ROOTFS/usr/lib/firmware/$firmware_name"
        printf '%s  %s\n' \
            "$(sha256sum "$MPSS_FIRMWARE_DIR/$firmware_name" | awk '{print $1}')" \
            "$firmware_name"
    done
} > "$MPSS_MANIFEST"

log "从 Debian busybox-static 生成纯 Debian initramfs"
[[ -s "$REGULATORY_DB" && -s "$REGULATORY_DB_SIGNATURE" ]] \
    || die "Debian wireless-regdb 缺少 upstream 数据库或签名"
regulatory_db_sha256="$(sha256sum "$REGULATORY_DB" | awk '{print $1}')"
regulatory_db_signature_sha256="$(sha256sum "$REGULATORY_DB_SIGNATURE" | awk '{print $1}')"
ROOTFS="$ROOTFS" \
OUTPUT="$INITRAMFS" \
BUILD_DIR="$BUILD_DIR/debian-initramfs" \
INIT_SCRIPT="$INITRAMFS_INIT" \
USB_GADGET_SCRIPT="$USB_GADGET_SCRIPT" \
REGULATORY_DB="$REGULATORY_DB" \
REGULATORY_DB_SIGNATURE="$REGULATORY_DB_SIGNATURE" \
    bash "$INITRAMFS_BUILD_SCRIPT"
initramfs_sha256="$(sha256sum "$INITRAMFS" | awk '{print $1}')"
python3 "$QCDT_BUILD_SCRIPT" \
    --stock-boot "$REFERENCE_BOOT" \
    --dtb "$DTB" \
    --out "$QCDT"
qcdt_sha256="$(sha256sum "$QCDT" | awk '{print $1}')"

chroot "$ROOTFS" /usr/bin/qemu-arm-static /bin/bash -lc \
    'systemctl enable zu02-firewall zu02-usb-gadget zu02-usb-watchdog.timer zu02-wcnss adbd zu02-usb-network ssh dnsmasq NetworkManager qrtr-ns rmtfs zu02-mpss zu02-modem-prepare ModemManager zu02-modem-register ufi210-modem-time-sync systemd-timesyncd fstrim.timer serial-getty@ttyGS0.service >/dev/null'

log "清理 Debian ${TARGET_PARTITION} rootfs"
chroot "$ROOTFS" /usr/bin/qemu-arm-static /bin/bash -lc 'apt-get clean'
chroot "$ROOTFS" /usr/bin/qemu-arm-static /bin/bash -lc \
    "dpkg-query -W -f='\${binary:Package}\t\${Version}\n'" \
    | sort > "$PACKAGE_LIST"
rm -f "$ROOTFS/usr/bin/qemu-arm-static" "$ROOTFS/usr/sbin/policy-rc.d"
rm -f "$ROOTFS/etc/NetworkManager/dispatcher.d/01-ifupdown"
rm -f "$ROOTFS/etc/resolv.conf"
ln -s /run/NetworkManager/resolv.conf "$ROOTFS/etc/resolv.conf"
rm -f "$ROOTFS/etc/ssh/ssh_host_"*
rm -rf -- \
    "$ROOTFS/var/lib/apt/lists/"* \
    "$ROOTFS/var/cache/apt/archives/"* \
    "$ROOTFS/usr/share/man/"* \
    "$ROOTFS/usr/share/info/"* \
    "$ROOTFS/var/log/apt" \
    "$ROOTFS/tmp/"* \
    "$ROOTFS/var/tmp/"*
find "$ROOTFS/usr/share/doc" -mindepth 2 -type f ! -name copyright -delete
find "$ROOTFS/usr/share/doc" -mindepth 1 -depth -type d -empty -delete
rm -f \
    "$ROOTFS/etc/.pwd.lock" \
    "$ROOTFS/etc/group-" \
    "$ROOTFS/etc/gshadow-" \
    "$ROOTFS/etc/passwd-" \
    "$ROOTFS/etc/shadow-" \
    "$ROOTFS/etc/xml/catalog.old" \
    "$ROOTFS/etc/xml/polkitd.xml.old" \
    "$ROOTFS/etc/xml/xml-core.xml.old" \
    "$ROOTFS/var/cache/debconf/config.dat-old" \
    "$ROOTFS/var/cache/debconf/templates.dat-old" \
    "$ROOTFS/var/cache/ldconfig/aux-cache" \
    "$ROOTFS/var/lib/dpkg/diversions-old" \
    "$ROOTFS/var/lib/dpkg/lock" \
    "$ROOTFS/var/lib/dpkg/status-old" \
    "$ROOTFS/var/lib/dpkg/triggers/Lock" \
    "$ROOTFS/var/lib/sgml-base/supercatalog.old" \
    "$ROOTFS/var/log/alternatives.log" \
    "$ROOTFS/var/log/bootstrap.log" \
    "$ROOTFS/var/log/dpkg.log" \
    "$ROOTFS/var/log/lastlog" \
    "$ROOTFS/var/log/wtmp" \
    "$ROOTFS/var/log/btmp"
rm -rf -- "$ROOTFS/usr/share/locale/"*
install -D -m 0644 "$nmtui_catalog_staging" \
    "$ROOTFS/usr/share/locale/zh_CN/LC_MESSAGES/NetworkManager.mo"
install -D -m 0644 "$locale_archive_staging" "$ROOTFS/usr/lib/locale/locale-archive"
nmtui_catalog_sha256="$(sha256sum "$ROOTFS/usr/share/locale/zh_CN/LC_MESSAGES/NetworkManager.mo" | awk '{print $1}')"
locale_archive_sha256="$(sha256sum "$ROOTFS/usr/lib/locale/locale-archive" | awk '{print $1}')"
: > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/dbus/machine-id"

find "$ROOTFS" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

used_mb="$(du -sm "$ROOTFS" | awk '{print $1}')"
(( (used_mb + 20) * 1048576 < ROOTFS_IMAGE_SIZE )) \
    || die "rootfs 已使用 ${used_mb} MiB，无法安全放入 $ROOTFS_IMAGE_SIZE 字节镜像"

log "生成 $ROOTFS_IMAGE_SIZE 字节 ${TARGET_PARTITION} ext4 镜像（rootfs 已用 ${used_mb} MiB）"
rm -f "$IMAGE"
truncate -s "$ROOTFS_IMAGE_SIZE" "$IMAGE"
mkfs.ext4 -q -F -m 0 -L "$ROOTFS_LABEL" \
    -U "$ROOTFS_UUID" \
    -E "lazy_itable_init=0,lazy_journal_init=0,hash_seed=$ROOTFS_HASH_SEED" \
    -d "$ROOTFS" "$IMAGE"
log "归一化 ext4 已分配 inode 的时间字段"
python3 "$INODE_TIME_TOOL" normalize "$IMAGE" "$SOURCE_DATE_EPOCH"
fsck_rc=0
e2fsck -fn "$IMAGE" >/dev/null || fsck_rc=$?
(( fsck_rc <= 1 )) || die "e2fsck 校验 ${TARGET_PARTITION} 镜像失败，退出码 $fsck_rc"
filesystem_stats="$(tune2fs -l "$IMAGE")"
rootfs_block_size="$(awk -F: '$1 == "Block size" {sub(/^[[:space:]]+/, "", $2); print $2}' <<<"$filesystem_stats")"
rootfs_free_blocks="$(awk -F: '$1 == "Free blocks" {sub(/^[[:space:]]+/, "", $2); print $2}' <<<"$filesystem_stats")"
[[ "$rootfs_block_size" =~ ^[0-9]+$ && "$rootfs_free_blocks" =~ ^[0-9]+$ ]] \
    || die "无法解析 ext4 可用空间"
rootfs_free_bytes=$((rootfs_block_size * rootfs_free_blocks))
(( rootfs_free_bytes >= MIN_ROOTFS_FREE_BYTES )) \
    || die "ext4 仅剩 $rootfs_free_bytes 字节，低于最低要求 $MIN_ROOTFS_FREE_BYTES 字节"
image_bytes="$(stat -c %s "$IMAGE")"
(( image_bytes < TARGET_PARTITION_SIZE )) \
    || die "rootfs 镜像不小于目标 ${TARGET_PARTITION} 分区"

rootfs_system_image_bytes=0
rootfs_cache_image_bytes=0
rootfs_userdata_image_bytes=0
rootfs_system_image_sha256=""
rootfs_cache_image_sha256=""
rootfs_userdata_image_sha256=""
if [[ "$TARGET_PARTITION" == large-rootfs ]]; then
    log "按 system、cache、userdata 边界切分完整大根卷镜像"
    rm -f "$ROOTFS_SYSTEM_IMAGE" "$ROOTFS_CACHE_IMAGE" "$ROOTFS_USERDATA_IMAGE"
    dd if="$IMAGE" of="$ROOTFS_SYSTEM_IMAGE" bs=512 count="$SYSTEM_PARTITION_SECTORS" \
        iflag=fullblock conv=sparse status=none
    dd if="$IMAGE" of="$ROOTFS_CACHE_IMAGE" bs=512 \
        skip="$SYSTEM_PARTITION_SECTORS" count="$CACHE_PARTITION_SECTORS" \
        iflag=fullblock conv=sparse status=none
    dd if="$IMAGE" of="$ROOTFS_USERDATA_IMAGE" bs=512 \
        skip=$((SYSTEM_PARTITION_SECTORS + CACHE_PARTITION_SECTORS)) \
        count=$((USERDATA_PARTITION_SECTORS - 7)) \
        iflag=fullblock conv=sparse status=none
    rootfs_system_image_bytes="$(stat -c %s "$ROOTFS_SYSTEM_IMAGE")"
    rootfs_cache_image_bytes="$(stat -c %s "$ROOTFS_CACHE_IMAGE")"
    rootfs_userdata_image_bytes="$(stat -c %s "$ROOTFS_USERDATA_IMAGE")"
    (( rootfs_system_image_bytes == SYSTEM_PARTITION_SECTORS * 512 )) \
        || die "system 根卷分段大小错误"
    (( rootfs_cache_image_bytes == CACHE_PARTITION_SECTORS * 512 )) \
        || die "cache 根卷分段大小错误"
    (( rootfs_userdata_image_bytes == LARGE_ROOTFS_FILESYSTEM_SIZE - rootfs_system_image_bytes - rootfs_cache_image_bytes )) \
        || die "userdata 根卷分段大小错误"
    rootfs_system_image_sha256="$(sha256sum "$ROOTFS_SYSTEM_IMAGE" | awk '{print $1}')"
    rootfs_cache_image_sha256="$(sha256sum "$ROOTFS_CACHE_IMAGE" | awk '{print $1}')"
    rootfs_userdata_image_sha256="$(sha256sum "$ROOTFS_USERDATA_IMAGE" | awk '{print $1}')"
fi

data_image_bytes=0
data_image_sha256=""
if [[ "$TARGET_PARTITION" == system ]]; then
    data_root="$BUILD_DIR/data-root"
    case "$(realpath -m "$data_root")" in
        "$(realpath -m "$BUILD_DIR")"/*) ;;
        *) die "拒绝清理 BUILD_DIR 之外的 data root：$data_root" ;;
    esac
    rm -rf -- "$data_root"
    install -d -m 0755 \
        "$data_root/apps" \
        "$data_root/backups" \
        "$data_root/srv"
    find "$data_root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

    log "生成 ${DATA_IMAGE_SIZE_MB} MiB userdata ext4 镜像"
    rm -f "$DATA_IMAGE"
    truncate -s "${DATA_IMAGE_SIZE_MB}M" "$DATA_IMAGE"
    mkfs.ext4 -q -F -b 4096 -m 0 -L "$DATA_LABEL" \
        -U "$DATA_UUID" \
        -E "lazy_itable_init=0,lazy_journal_init=0,hash_seed=$DATA_HASH_SEED" \
        -d "$data_root" "$DATA_IMAGE"
    python3 "$INODE_TIME_TOOL" normalize "$DATA_IMAGE" "$SOURCE_DATE_EPOCH"
    data_fsck_rc=0
    e2fsck -fn "$DATA_IMAGE" >/dev/null || data_fsck_rc=$?
    (( data_fsck_rc <= 1 )) || die "e2fsck 校验 userdata 镜像失败，退出码 $data_fsck_rc"
    data_image_bytes="$(stat -c %s "$DATA_IMAGE")"
    (( data_image_bytes < DATA_PARTITION_SIZE )) \
        || die "data 镜像不小于 userdata 分区"
    data_image_sha256="$(sha256sum "$DATA_IMAGE" | awk '{print $1}')"
fi

log "打包 rootfs tarball"
find "$ROOTFS" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
tar --sort=name --format=posix \
    --pax-option=delete=atime,delete=ctime \
    --numeric-owner --xattrs --acls \
    --mtime="@$SOURCE_DATE_EPOCH" \
    -C "$ROOTFS" -cf - . \
    | xz -T1 -9 > "$ROOTFS_TARBALL"

cmdline="console=ttyMSM0,115200n8 console=tty0 earlycon panic=0 loglevel=8 ignore_loglevel clk_ignore_unused pd_ignore_unused reboot=warm root=$BOOT_ROOT_ARGUMENT rootfstype=ext4 rw rootwait"
log "生成 Debian ${TARGET_PARTITION} boot image"
python3 "$PROJECT_ROOT/scripts/repack_android_boot.py" \
    --original "$REFERENCE_BOOT" \
    --kernel "$KERNEL" \
    --ramdisk "$INITRAMFS" \
    --qcdt "$QCDT" \
    --output "$BOOT_IMAGE" \
    --cmdline "$cmdline" \
    --name "deb-$TARGET_PARTITION"

boot_bytes="$(stat -c %s "$BOOT_IMAGE")"
(( boot_bytes < 33554432 )) || die "Debian boot image 不小于 32 MiB boot 分区"
rootfs_sha256="$(sha256sum "$IMAGE" | awk '{print $1}')"
boot_sha256="$(sha256sum "$BOOT_IMAGE" | awk '{print $1}')"
tarball_sha256="$(sha256sum "$ROOTFS_TARBALL" | awk '{print $1}')"
{
    printf 'debian_suite=%s\n' "$SUITE"
    printf 'debian_snapshot_timestamp=%s\n' "$DEBIAN_SNAPSHOT_TIMESTAMP"
    printf 'debian_snapshot_mirror=%s\n' "$MANIFEST_MIRROR"
    printf 'debian_security_snapshot_mirror=%s\n' "$MANIFEST_SECURITY_MIRROR"
    printf 'debian_runtime_mirror=%s\n' "$RUNTIME_MIRROR"
    printf 'debian_runtime_security_mirror=%s\n' "$RUNTIME_SECURITY_MIRROR"
    printf 'snapshot_valid_until_override=build-only-removed\n'
    printf 'snapshot_download_retries=%s\n' "$SNAPSHOT_DOWNLOAD_RETRIES"
    printf 'debian_keyring=%s\n' "$DEBIAN_KEYRING"
    printf 'debian_keyring_sha256=%s\n' "$keyring_sha256"
    printf 'architecture=armhf\n'
    printf 'hostname=ufi210\n'
    printf 'kernel_release=%s\n' "$KERNEL_RELEASE"
    printf 'source_date_epoch=%s\n' "$SOURCE_DATE_EPOCH"
    printf 'rootfs_uuid=%s\n' "$ROOTFS_UUID"
    printf 'rootfs_hash_seed=%s\n' "$ROOTFS_HASH_SEED"
    printf 'rootfs_label=%s\n' "$ROOTFS_LABEL"
    printf 'rootfs_device=%s\n' "$ROOTFS_DEVICE"
    printf 'rootfs_inode_time_epoch=%s\n' "$SOURCE_DATE_EPOCH"
    printf 'build_script_sha256=%s\n' "$script_sha256"
    printf 'kernel_sha256=%s\n' "$kernel_sha256"
    printf 'dtb_sha256=%s\n' "$dtb_sha256"
    printf 'modules_sha256=%s\n' "$modules_sha256"
    printf 'initramfs_build_script_sha256=%s\n' "$initramfs_build_script_sha256"
    printf 'inode_time_tool_sha256=%s\n' "$inode_time_tool_sha256"
    printf 'qcdt_build_script_sha256=%s\n' "$qcdt_build_script_sha256"
    printf 'initramfs_init_sha256=%s\n' "$initramfs_init_sha256"
    printf 'initramfs_sha256=%s\n' "$initramfs_sha256"
    printf 'qcdt_sha256=%s\n' "$qcdt_sha256"
    printf 'qcdt_version=3\n'
    printf 'qcdt_record_count=30\n'
    printf 'qcdt_unique_dtb_count=1\n'
    printf 'regulatory_db_sha256=%s\n' "$regulatory_db_sha256"
    printf 'regulatory_db_signature_sha256=%s\n' "$regulatory_db_signature_sha256"
    printf 'usb_gadget_script_sha256=%s\n' "$usb_gadget_script_sha256"
    printf 'usb_watchdog_script_sha256=%s\n' "$usb_watchdog_script_sha256"
    printf 'wcnss_start_script_sha256=%s\n' "$wcnss_start_script_sha256"
    printf 'mpss_start_script_sha256=%s\n' "$mpss_start_script_sha256"
    printf 'modem_prepare_script_sha256=%s\n' "$modem_prepare_script_sha256"
    printf 'modem_register_script_sha256=%s\n' "$modem_register_script_sha256"
    printf 'modem_time_sync_script_sha256=%s\n' "$modem_time_sync_script_sha256"
    printf 'wwan_ip_script_sha256=%s\n' "$wwan_ip_script_sha256"
    printf 'nmtui_wrapper_sha256=%s\n' "$nmtui_wrapper_sha256"
    printf 'reboot_compat_source_sha256=%s\n' "$reboot_compat_source_sha256"
    printf 'reboot_compat_binary_sha256=%s\n' "$reboot_compat_binary_sha256"
    printf 'wifi_ap_profile_sha256=%s\n' "$wifi_ap_profile_sha256"
    printf 'usb_management_conf_sha256=%s\n' "$usb_management_conf_sha256"
    printf 'wifi_mac_conf_sha256=%s\n' "$wifi_mac_conf_sha256"
    printf 'nmtui_catalog_sha256=%s\n' "$nmtui_catalog_sha256"
    printf 'locale_archive_sha256=%s\n' "$locale_archive_sha256"
    printf 'wcnss_firmware_sha256=%s\n' "$wcnss_firmware_sha256"
    printf 'mpss_firmware_sha256=%s\n' "$mpss_firmware_sha256"
    printf 'wcnss_nv_sha256=%s\n' "$wcnss_nv_sha256"
    printf 'rootfs_used_mb=%s\n' "$used_mb"
    printf 'rootfs_free_bytes=%s\n' "$rootfs_free_bytes"
    printf 'rootfs_min_free_bytes=%s\n' "$MIN_ROOTFS_FREE_BYTES"
    printf 'rootfs_image_bytes=%s\n' "$image_bytes"
    printf 'rootfs_image_sha256=%s\n' "$rootfs_sha256"
    printf 'rootfs_tarball_sha256=%s\n' "$tarball_sha256"
    printf 'boot_image_bytes=%s\n' "$boot_bytes"
    printf 'boot_image_sha256=%s\n' "$boot_sha256"
    printf 'target_partition=%s\n' "$TARGET_PARTITION"
    printf 'target_partition_bytes=%s\n' "$TARGET_PARTITION_SIZE"
    printf 'rootfs_auto_grow=%s\n' "$ROOTFS_AUTO_GROW"
    if [[ "$TARGET_PARTITION" == large-rootfs ]]; then
        printf 'storage_layout=dm-linear-system-cache-userdata\n'
        printf 'dm_name=ufi210-root\n'
        printf 'dm_total_sectors=%s\n' "$LARGE_ROOTFS_SECTORS"
        printf 'dm_total_bytes=%s\n' "$LARGE_ROOTFS_SIZE"
        printf 'dm_filesystem_bytes=%s\n' "$LARGE_ROOTFS_FILESYSTEM_SIZE"
        printf 'dm_system_sectors=%s\n' "$SYSTEM_PARTITION_SECTORS"
        printf 'dm_cache_sectors=%s\n' "$CACHE_PARTITION_SECTORS"
        printf 'dm_userdata_sectors=%s\n' "$USERDATA_PARTITION_SECTORS"
        printf 'dm_system_start=%s\n' "$SYSTEM_PARTITION_START"
        printf 'dm_cache_start=%s\n' "$CACHE_PARTITION_START"
        printf 'dm_userdata_start=%s\n' "$USERDATA_PARTITION_START"
        printf 'dm_table=%s\n' "$LARGE_ROOTFS_TABLE"
        printf 'rootfs_system_image=debian-%s-armhf-large-rootfs-system.img\n' "$SUITE"
        printf 'rootfs_system_image_bytes=%s\n' "$rootfs_system_image_bytes"
        printf 'rootfs_system_image_sha256=%s\n' "$rootfs_system_image_sha256"
        printf 'rootfs_cache_image=debian-%s-armhf-large-rootfs-cache.img\n' "$SUITE"
        printf 'rootfs_cache_image_bytes=%s\n' "$rootfs_cache_image_bytes"
        printf 'rootfs_cache_image_sha256=%s\n' "$rootfs_cache_image_sha256"
        printf 'rootfs_userdata_image=debian-%s-armhf-large-rootfs-userdata.img\n' "$SUITE"
        printf 'rootfs_userdata_image_bytes=%s\n' "$rootfs_userdata_image_bytes"
        printf 'rootfs_userdata_image_sha256=%s\n' "$rootfs_userdata_image_sha256"
        printf 'rootfs_segments=complete-prebuilt-filesystem\n'
        printf 'data_mount=none\n'
        printf 'gpt_changes=none\n'
        printf 'cache_previous_contents=erased-by-installer\n'
        printf 'userdata_previous_contents=erased-by-installer\n'
    fi
    if [[ "$TARGET_PARTITION" == system ]]; then
        printf 'data_partition=userdata\n'
        printf 'data_partition_bytes=%s\n' "$DATA_PARTITION_SIZE"
        printf 'data_filesystem_bytes=%s\n' "$DATA_FILESYSTEM_SIZE"
        printf 'data_image_bytes=%s\n' "$data_image_bytes"
        printf 'data_image_sha256=%s\n' "$data_image_sha256"
        printf 'data_uuid=%s\n' "$DATA_UUID"
        printf 'data_hash_seed=%s\n' "$DATA_HASH_SEED"
        printf 'data_label=%s\n' "$DATA_LABEL"
        printf 'data_mount=/data\n'
        printf 'data_mount_options=defaults,noatime,nosuid,nodev,nofail,x-systemd.growfs,x-systemd.device-timeout=30s\n'
        printf 'data_auto_grow=enabled\n'
        printf 'data_initial_directories=apps,backups,srv\n'
        printf 'userdata_previous_contents=erased-by-installer\n'
    fi
    printf 'fstrim=weekly-systemd-timer\n'
    printf 'reboot_mode=warm\n'
    printf 'device_ip=192.168.68.1\n'
    printf 'root_password=%s\n' "$ROOT_PASSWORD"
    printf 'adbd=tcp-5555\n'
    printf 'adbd_shell_tmpdir=/data/local/tmp\n'
    printf 'adbd_shell_tmpdir_storage=rootfs\n'
    printf 'fastboot_reboot_command=adb-shell-system-bin-reboot-bootloader\n'
    printf 'adb_tcp_endpoint=192.168.68.1:5555\n'
    printf 'usb_functions=rndis-acm\n'
    printf 'usb_product_id=0xD001\n'
    printf 'usb_watchdog=systemd-timer\n'
    printf 'usb_watchdog_interval_seconds=5\n'
    printf 'usb_watchdog_unhealthy_seconds=5\n'
    printf 'rndis_mac=device-derived-stable-local-unicast\n'
    printf 'windows_rndis_os_desc=MSFT100-0xcd\n'
    printf 'wcnss_iris=qcom,wcn3620\n'
    printf 'wcnss_country=CN\n'
    printf 'wcnss_firmware_source=PARTLABEL-modem-read-only\n'
    printf 'wcnss_nv_source=PARTLABEL-persist-read-only\n'
    printf 'persist_mount=read-only-noload\n'
    printf 'mpss_firmware_source=PARTLABEL-modem-read-only\n'
    printf 'rmtfs_mode=read-only-physical-partitions-synchronized\n'
    printf 'modem_manager=qcom-soc-qrtr\n'
    printf 'modem_default_modes=3g-4g-preferred-4g\n'
    printf 'wwan_ipv4=networkmanager-dispatcher-bearer-values\n'
    printf 'resolv_conf=NetworkManager-runtime\n'
    printf 'time_sync=qmi-dms-forward-only+systemd-timesyncd\n'
    printf 'system_locale=C.UTF-8\n'
    printf 'nmtui_locale=zh_CN.UTF-8\n'
    printf 'wifi_ap_profile=preinstalled-disabled\n'
    printf 'wifi_ap_ssid=ZU02-Debian\n'
    printf 'wifi_ap_ipv4=192.168.69.1/24\n'
    printf 'wifi_interface_concurrency=managed-or-ap-exclusive\n'
    printf 'usb_management=static-service-networkmanager-unmanaged\n'
    printf 'network_topology=isolated-usb-wifi-no-bridge\n'
    printf 'thermal_cpu_passive_trip_millic=75000\n'
    printf 'thermal_cpu_passive_hysteresis_millic=3000\n'
    printf 'routing_firewall=NetworkManager-nftables\n'
    printf 'management_ingress=usb-only-rndis-ssh-tcp-adb-acm\n'
    printf 'wwan_ingress=drop-new-and-untracked\n'
    printf 'lte_apn=not-preconfigured\n'
} > "$MANIFEST"

log "完成：$IMAGE"
if [[ "$TARGET_PARTITION" == large-rootfs ]]; then
    log "完成：$ROOTFS_SYSTEM_IMAGE"
    log "完成：$ROOTFS_CACHE_IMAGE"
    log "完成：$ROOTFS_USERDATA_IMAGE"
    rm -f "$IMAGE"
fi
if [[ "$TARGET_PARTITION" == system ]]; then
    log "完成：$DATA_IMAGE"
    log "data SHA256：$data_image_sha256"
fi
log "完成：$BOOT_IMAGE"
log "rootfs SHA256：$rootfs_sha256"
log "boot SHA256：$boot_sha256"
