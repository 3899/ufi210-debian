#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C.UTF-8

PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/out/mainline/debian-cache}"
TARGET_PARTITION="${TARGET_PARTITION:-cache}"
KERNEL_DIR="$PROJECT_ROOT/out/mainline/kernel"
IMAGE="$OUT_DIR/debian-bookworm-armhf-${TARGET_PARTITION}.ext4"
ROOTFS_SYSTEM_IMAGE="$OUT_DIR/debian-bookworm-armhf-large-rootfs-system.img"
ROOTFS_CACHE_IMAGE="$OUT_DIR/debian-bookworm-armhf-large-rootfs-cache.img"
ROOTFS_USERDATA_IMAGE="$OUT_DIR/debian-bookworm-armhf-large-rootfs-userdata.img"
DATA_IMAGE="$OUT_DIR/debian-bookworm-armhf-data.ext4"
BOOT_IMAGE="$OUT_DIR/boot-debian-${TARGET_PARTITION}.img"
INITRAMFS_BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_debian_initramfs.sh"
INODE_TIME_TOOL="$PROJECT_ROOT/scripts/normalize_ext4_inode_times.py"
QCDT_BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_stock_qcdt.py"
INITRAMFS_INIT="$PROJECT_ROOT/patches/initramfs/init-debian.sh"
INITRAMFS="$OUT_DIR/initramfs-zu02-debian"
QCDT="$OUT_DIR/qcdt-zu02-dw01.img"
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
ROOTFS_TARBALL="$OUT_DIR/debian-bookworm-armhf-${TARGET_PARTITION}-rootfs.tar.xz"
PACKAGE_LIST="$OUT_DIR/packages.txt"
MANIFEST="$OUT_DIR/BUILD-MANIFEST.txt"
WCNSS_MANIFEST="$OUT_DIR/WCNSS-FIRMWARE-MANIFEST.txt"
MPSS_MANIFEST="$OUT_DIR/MPSS-FIRMWARE-MANIFEST.txt"
BOOT_PARTITION_SIZE=33554432
MIN_ROOTFS_FREE_BYTES=33554432
DATA_PARTITION_SIZE=1928314368
DATA_FILESYSTEM_SIZE=1928310784
DATA_UUID="89090000-0000-4000-8000-000000000029"
DATA_HASH_SEED="89090000-0000-4000-8000-000000000030"
DATA_LABEL="ufi210-data"
SYSTEM_PARTITION_SIZE=1288491008
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
DEBIAN_SNAPSHOT_TIMESTAMP="20260903T000000Z"
DEBIAN_SNAPSHOT_MIRROR="https://snapshot.debian.org/archive/debian/$DEBIAN_SNAPSHOT_TIMESTAMP"
DEBIAN_SECURITY_SNAPSHOT_MIRROR="https://snapshot.debian.org/archive/debian-security/$DEBIAN_SNAPSHOT_TIMESTAMP"
DEBIAN_RUNTIME_MIRROR="https://deb.debian.org/debian"
DEBIAN_RUNTIME_SECURITY_MIRROR="https://security.debian.org/debian-security"
case "$TARGET_PARTITION" in
    cache)
        TARGET_PARTITION_SIZE=268435456
        ROOTFS_UUID="89090000-0000-4000-8000-000000000023"
        ROOTFS_HASH_SEED="89090000-0000-4000-8000-000000000024"
        ROOTFS_AUTO_GROW=disabled
        ROOTFS_DEVICE="PARTLABEL=cache"
        ROOTFS_LABEL="debian-cache"
        BOOT_ROOT_ARGUMENT="PARTLABEL=cache"
        ;;
    system)
        TARGET_PARTITION_SIZE=1288491008
        ROOTFS_UUID="89090000-0000-4000-8000-000000000021"
        ROOTFS_HASH_SEED="89090000-0000-4000-8000-000000000022"
        ROOTFS_AUTO_GROW=enabled
        ROOTFS_DEVICE="PARTLABEL=system"
        ROOTFS_LABEL="debian-system"
        BOOT_ROOT_ARGUMENT="PARTLABEL=system"
        ;;
    large-rootfs)
        TARGET_PARTITION_SIZE=$LARGE_ROOTFS_SIZE
        ROOTFS_UUID="89090000-0000-4000-8000-000000000031"
        ROOTFS_HASH_SEED="89090000-0000-4000-8000-000000000032"
        ROOTFS_AUTO_GROW=disabled
        ROOTFS_DEVICE="/dev/mapper/ufi210-root"
        ROOTFS_LABEL="ufi210-root"
        BOOT_ROOT_ARGUMENT="/dev/mapper/ufi210-root"
        ;;
    *)
        printf '错误：TARGET_PARTITION 只允许 cache、system 或 large-rootfs\n' >&2
        exit 1
        ;;
esac
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
if [[ "$TARGET_PARTITION" == large-rootfs ]]; then
    IMAGE="$tmp_dir/debian-bookworm-armhf-large-rootfs.ext4"
fi
EXPECTED_ROOT_HASH='$6$zu02bookworm$EkyrnT4tC/ZBMvbIhomnJMwfjZE.WmJf.aahDRaj7TO27.LiwOTWJ1HxtFvZ4o/MOl17fr4mT5hDcrAs61Sk5/'
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

for command_name in awk cmp cpio cut dd debugfs dumpe2fs e2fsck fdtget file grep gzip head python3 qemu-arm-static readelf readlink sha256sum stat tail tar truncate tune2fs; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
done
for required in "$BOOT_IMAGE" "$INITRAMFS" "$ROOTFS_TARBALL" "$PACKAGE_LIST" \
    "$MANIFEST" "$WCNSS_MANIFEST" "$MPSS_MANIFEST" "$WCNSS_START_SCRIPT" \
    "$MPSS_START_SCRIPT" "$MODEM_PREPARE_SCRIPT" "$MODEM_REGISTER_SCRIPT" "$WWAN_IP_SCRIPT" \
    "$NMTUI_WRAPPER" "$REBOOT_COMPAT_SOURCE" "$WIFI_AP_PROFILE" "$USB_MANAGEMENT_CONF" "$WIFI_MAC_CONF" \
    "$INITRAMFS_BUILD_SCRIPT" "$INODE_TIME_TOOL" \
    "$INITRAMFS_INIT" "$QCDT_BUILD_SCRIPT" "$QCDT" "$USB_GADGET_SCRIPT" "$USB_WATCHDOG_SCRIPT" "$WCNSS_NV"; do
    [[ -s "$required" ]] || die "缺少产物：$required"
done
if [[ "$TARGET_PARTITION" == large-rootfs ]]; then
    for required in "$ROOTFS_SYSTEM_IMAGE" "$ROOTFS_CACHE_IMAGE" "$ROOTFS_USERDATA_IMAGE"; do
        [[ -s "$required" ]] || die "缺少根卷分段：$required"
    done
    [[ "$(stat -c %s "$ROOTFS_SYSTEM_IMAGE")" == "$((SYSTEM_PARTITION_SECTORS * 512))" ]] \
        || die "system 根卷分段大小错误"
    [[ "$(stat -c %s "$ROOTFS_CACHE_IMAGE")" == "$((CACHE_PARTITION_SECTORS * 512))" ]] \
        || die "cache 根卷分段大小错误"
    [[ "$(stat -c %s "$ROOTFS_USERDATA_IMAGE")" == "$((LARGE_ROOTFS_FILESYSTEM_SIZE - SYSTEM_PARTITION_SIZE - CACHE_PARTITION_SECTORS * 512))" ]] \
        || die "userdata 根卷分段大小错误"
    truncate -s "$LARGE_ROOTFS_FILESYSTEM_SIZE" "$IMAGE"
    dd if="$ROOTFS_SYSTEM_IMAGE" of="$IMAGE" bs=512 count="$SYSTEM_PARTITION_SECTORS" \
        iflag=fullblock conv=notrunc,sparse status=none
    dd if="$ROOTFS_CACHE_IMAGE" of="$IMAGE" bs=512 seek="$SYSTEM_PARTITION_SECTORS" \
        count="$CACHE_PARTITION_SECTORS" iflag=fullblock conv=notrunc,sparse status=none
    dd if="$ROOTFS_USERDATA_IMAGE" of="$IMAGE" bs=512 \
        seek=$((SYSTEM_PARTITION_SECTORS + CACHE_PARTITION_SECTORS)) \
        count=$((USERDATA_PARTITION_SECTORS - 7)) \
        iflag=fullblock conv=notrunc,sparse status=none
else
    [[ -s "$IMAGE" ]] || die "缺少产物：$IMAGE"
fi
if [[ "$TARGET_PARTITION" == system ]]; then
    [[ -s "$DATA_IMAGE" ]] || die "缺少产物：$DATA_IMAGE"
fi
for firmware_name in "${MPSS_FIRMWARE_FILES[@]}"; do
    [[ -s "$MPSS_FIRMWARE_DIR/$firmware_name" ]] \
        || die "缺少 MPSS 固件输入：$firmware_name"
done
for firmware_name in "${WCNSS_FIRMWARE_FILES[@]}"; do
    [[ -s "$WCNSS_FIRMWARE_DIR/$firmware_name" ]] \
        || die "缺少 WCNSS 固件输入：$firmware_name"
done

manifest_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; found=1} END {exit !found}' "$MANIFEST"
}

check_sha256() {
    local key="$1"
    local path="$2"
    local expected actual
    expected="$(manifest_value "$key")"
    actual="$(sha256sum "$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] \
        || die "$path SHA256 不匹配：$actual != $expected"
}

check_size() {
    local key="$1"
    local path="$2"
    local expected actual
    expected="$(manifest_value "$key")"
    actual="$(stat -c %s "$path")"
    [[ "$actual" == "$expected" ]] \
        || die "$path 大小不匹配：$actual != $expected"
}

log "核对 manifest 与构建输入"
[[ "$(manifest_value debian_suite)" == "bookworm" ]] || die "Debian suite 不是 bookworm"
[[ "$(manifest_value debian_snapshot_timestamp)" == "$DEBIAN_SNAPSHOT_TIMESTAMP" ]] \
    || die "Debian Snapshot 时间戳不匹配"
[[ "$(manifest_value debian_snapshot_mirror)" == "$DEBIAN_SNAPSHOT_MIRROR" ]] \
    || die "Debian 构建快照地址不匹配"
[[ "$(manifest_value debian_security_snapshot_mirror)" == "$DEBIAN_SECURITY_SNAPSHOT_MIRROR" ]] \
    || die "Debian security 构建快照地址不匹配"
[[ "$(manifest_value debian_runtime_mirror)" == "$DEBIAN_RUNTIME_MIRROR" ]] \
    || die "Debian 运行期更新源不匹配"
[[ "$(manifest_value debian_runtime_security_mirror)" == "$DEBIAN_RUNTIME_SECURITY_MIRROR" ]] \
    || die "Debian security 运行期更新源不匹配"
[[ "$(manifest_value snapshot_valid_until_override)" == "build-only-removed" ]] \
    || die "Snapshot Valid-Until 临时豁免策略不匹配"
[[ "$(manifest_value snapshot_download_retries)" == "5" ]] \
    || die "Snapshot 下载重试策略不匹配"
[[ "$(manifest_value architecture)" == "armhf" ]] || die "架构不是 armhf"
[[ "$(manifest_value kernel_release)" == "7.0.0-msm8909" ]] || die "内核版本不匹配"
[[ "$(manifest_value source_date_epoch)" == "$PROJECT_SOURCE_DATE_EPOCH" ]] \
    || die "SOURCE_DATE_EPOCH 不匹配"
[[ "$(manifest_value rootfs_uuid)" == "$ROOTFS_UUID" ]] || die "rootfs UUID 策略不匹配"
[[ "$(manifest_value rootfs_hash_seed)" == "$ROOTFS_HASH_SEED" ]] \
    || die "rootfs 目录哈希种子策略不匹配"
[[ "$(manifest_value rootfs_label)" == "$ROOTFS_LABEL" ]] \
    || die "rootfs 标签策略不匹配"
[[ "$(manifest_value rootfs_device)" == "$ROOTFS_DEVICE" ]] \
    || die "rootfs 设备策略不匹配"
[[ "$(manifest_value rootfs_inode_time_epoch)" == "$PROJECT_SOURCE_DATE_EPOCH" ]] \
    || die "rootfs inode 时间策略不匹配"
[[ "$(manifest_value rootfs_min_free_bytes)" == "$MIN_ROOTFS_FREE_BYTES" ]] \
    || die "rootfs 最低空闲空间策略不匹配"
[[ "$(manifest_value persist_mount)" == "read-only-noload" ]] \
    || die "persist 挂载策略不匹配"
[[ "$(manifest_value target_partition)" == "$TARGET_PARTITION" ]] \
    || die "目标分区不是 $TARGET_PARTITION"
[[ "$(manifest_value target_partition_bytes)" == "$TARGET_PARTITION_SIZE" ]] \
    || die "目标分区容量策略不匹配"
[[ "$(manifest_value rootfs_auto_grow)" == "$ROOTFS_AUTO_GROW" ]] \
    || die "rootfs 自动扩容策略不匹配"
if [[ "$TARGET_PARTITION" == system ]]; then
    [[ "$(manifest_value data_partition)" == "userdata" ]] \
        || die "data 目标分区策略不匹配"
    [[ "$(manifest_value data_partition_bytes)" == "$DATA_PARTITION_SIZE" ]] \
        || die "userdata 分区容量策略不匹配"
    [[ "$(manifest_value data_filesystem_bytes)" == "$DATA_FILESYSTEM_SIZE" ]] \
        || die "data 扩容后文件系统容量策略不匹配"
    [[ "$(manifest_value data_uuid)" == "$DATA_UUID" ]] || die "data UUID 策略不匹配"
    [[ "$(manifest_value data_hash_seed)" == "$DATA_HASH_SEED" ]] \
        || die "data 目录哈希种子策略不匹配"
    [[ "$(manifest_value data_label)" == "$DATA_LABEL" ]] || die "data 标签策略不匹配"
    [[ "$(manifest_value data_mount)" == "/data" ]] || die "data 挂载点策略不匹配"
    [[ "$(manifest_value data_auto_grow)" == "enabled" ]] \
        || die "data 自动扩容策略不匹配"
    [[ "$(manifest_value data_initial_directories)" == "apps,backups,srv" ]] \
        || die "data 初始目录策略不匹配"
    [[ "$(manifest_value userdata_previous_contents)" == "erased-by-installer" ]] \
        || die "userdata 擦除策略不匹配"
fi
if [[ "$TARGET_PARTITION" == large-rootfs ]]; then
    [[ "$(manifest_value storage_layout)" == "dm-linear-system-cache-userdata" ]] \
        || die "大根卷布局策略不匹配"
    [[ "$(manifest_value dm_name)" == "ufi210-root" ]] || die "dm 名称不匹配"
    [[ "$(manifest_value dm_total_sectors)" == "$LARGE_ROOTFS_SECTORS" ]] \
        || die "dm 总扇区数不匹配"
    [[ "$(manifest_value dm_total_bytes)" == "$LARGE_ROOTFS_SIZE" ]] \
        || die "dm 总字节数不匹配"
    [[ "$(manifest_value dm_filesystem_bytes)" == "$LARGE_ROOTFS_FILESYSTEM_SIZE" ]] \
        || die "dm 扩容后文件系统字节数不匹配"
    [[ "$(manifest_value dm_system_sectors)" == "$SYSTEM_PARTITION_SECTORS" ]] \
        || die "dm system 扇区数不匹配"
    [[ "$(manifest_value dm_cache_sectors)" == "$CACHE_PARTITION_SECTORS" ]] \
        || die "dm cache 扇区数不匹配"
    [[ "$(manifest_value dm_userdata_sectors)" == "$USERDATA_PARTITION_SECTORS" ]] \
        || die "dm userdata 扇区数不匹配"
    [[ "$(manifest_value dm_system_start)" == "$SYSTEM_PARTITION_START" ]] \
        || die "dm system 起始 LBA 不匹配"
    [[ "$(manifest_value dm_cache_start)" == "$CACHE_PARTITION_START" ]] \
        || die "dm cache 起始 LBA 不匹配"
    [[ "$(manifest_value dm_userdata_start)" == "$USERDATA_PARTITION_START" ]] \
        || die "dm userdata 起始 LBA 不匹配"
    [[ "$(manifest_value dm_table)" == "$LARGE_ROOTFS_TABLE" ]] \
        || die "dm table 不匹配"
    [[ "$(manifest_value gpt_changes)" == none ]] || die "大根卷不得修改 GPT"
    [[ "$(manifest_value cache_previous_contents)" == erased-by-installer ]] \
        || die "cache 擦除策略不匹配"
    [[ "$(manifest_value userdata_previous_contents)" == erased-by-installer ]] \
        || die "userdata 擦除策略不匹配"
    [[ "$(manifest_value rootfs_segments)" == complete-prebuilt-filesystem ]] \
        || die "大根卷分段不是完整预构建文件系统"
fi
[[ "$(manifest_value fstrim)" == "weekly-systemd-timer" ]] \
    || die "定期 TRIM 策略不匹配"
[[ "$(manifest_value reboot_mode)" == "warm" ]] || die "重启模式不是 warm"
[[ "$(manifest_value device_ip)" == "192.168.68.1" ]] || die "设备 IP 不匹配"
[[ "$(manifest_value root_password)" == "simadmin" ]] || die "root 初始密码不匹配"
[[ "$(manifest_value fastboot_reboot_command)" == \
    "adb-shell-system-bin-reboot-bootloader" ]] \
    || die "Debian 进入 fastboot 的命令策略不匹配"
check_sha256 build_script_sha256 "$PROJECT_ROOT/scripts/build_debian_cache.sh"
check_sha256 kernel_sha256 "$KERNEL_DIR/vmlinuz"
check_sha256 dtb_sha256 "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb"
check_sha256 modules_sha256 "$KERNEL_DIR/modules-7.0.0-msm8909.tar.xz"
check_sha256 initramfs_build_script_sha256 "$INITRAMFS_BUILD_SCRIPT"
check_sha256 inode_time_tool_sha256 "$INODE_TIME_TOOL"
check_sha256 qcdt_build_script_sha256 "$QCDT_BUILD_SCRIPT"
check_sha256 initramfs_init_sha256 "$INITRAMFS_INIT"
check_sha256 initramfs_sha256 "$INITRAMFS"
check_sha256 qcdt_sha256 "$QCDT"
check_sha256 usb_gadget_script_sha256 "$USB_GADGET_SCRIPT"
check_sha256 usb_watchdog_script_sha256 "$USB_WATCHDOG_SCRIPT"
check_sha256 wcnss_start_script_sha256 "$WCNSS_START_SCRIPT"
check_sha256 mpss_start_script_sha256 "$MPSS_START_SCRIPT"
check_sha256 modem_prepare_script_sha256 "$MODEM_PREPARE_SCRIPT"
check_sha256 modem_register_script_sha256 "$MODEM_REGISTER_SCRIPT"
check_sha256 modem_time_sync_script_sha256 "$MODEM_TIME_SYNC_SCRIPT"
check_sha256 wwan_ip_script_sha256 "$WWAN_IP_SCRIPT"
check_sha256 nmtui_wrapper_sha256 "$NMTUI_WRAPPER"
check_sha256 reboot_compat_source_sha256 "$REBOOT_COMPAT_SOURCE"
check_sha256 wifi_ap_profile_sha256 "$WIFI_AP_PROFILE"
check_sha256 usb_management_conf_sha256 "$USB_MANAGEMENT_CONF"
check_sha256 wifi_mac_conf_sha256 "$WIFI_MAC_CONF"
check_sha256 wcnss_nv_sha256 "$WCNSS_NV"
wcnss_firmware_sha256="$(
    for firmware_name in "${WCNSS_FIRMWARE_FILES[@]}"; do
        printf '%s  %s\n' \
            "$(sha256sum "$WCNSS_FIRMWARE_DIR/$firmware_name" | awk '{print $1}')" \
            "$firmware_name"
    done | sha256sum | awk '{print $1}'
)"
[[ "$(manifest_value wcnss_firmware_sha256)" == "$wcnss_firmware_sha256" ]] \
    || die "WCNSS 固件集合哈希不匹配"
mpss_firmware_sha256="$(
    for firmware_name in "${MPSS_FIRMWARE_FILES[@]}"; do
        printf '%s  %s\n' \
            "$(sha256sum "$MPSS_FIRMWARE_DIR/$firmware_name" | awk '{print $1}')" \
            "$firmware_name"
    done | sha256sum | awk '{print $1}'
)"
[[ "$(manifest_value mpss_firmware_sha256)" == "$mpss_firmware_sha256" ]] \
    || die "MPSS 固件集合哈希不匹配"
grep -q '^exec switch_root /sysroot /sbin/init$' "$INITRAMFS_INIT" \
    || die "正式 initramfs 缺少自动 switch_root"
[[ "$(manifest_value adbd)" == "tcp-5555" ]] || die "ADB 模式不匹配"
[[ "$(manifest_value adb_tcp_endpoint)" == "192.168.68.1:5555" ]] || die "TCP ADB 地址不匹配"
[[ "$(manifest_value usb_functions)" == "rndis-acm" ]] || die "USB 复合功能不匹配"
[[ "$(manifest_value usb_product_id)" == "0xD001" ]] || die "USB product ID 不匹配"
[[ "$(manifest_value usb_watchdog)" == "systemd-timer" ]] || die "USB watchdog 模式不匹配"
[[ "$(manifest_value usb_watchdog_interval_seconds)" == "5" ]] \
    || die "USB watchdog 检查间隔不匹配"
[[ "$(manifest_value usb_watchdog_unhealthy_seconds)" == "5" ]] \
    || die "USB watchdog 连续异常阈值不匹配"
[[ "$(manifest_value rndis_mac)" == "device-derived-stable-local-unicast" ]] \
    || die "RNDIS MAC 派生策略不匹配"
[[ "$(manifest_value windows_rndis_os_desc)" == "MSFT100-0xcd" ]] || die "Windows RNDIS 描述符不匹配"
[[ "$(manifest_value wcnss_iris)" == "qcom,wcn3620" ]] || die "WCNSS Iris 型号不匹配"
[[ "$(manifest_value wcnss_country)" == "CN" ]] || die "WCNSS 监管域不匹配"
[[ "$(manifest_value wcnss_firmware_source)" == "PARTLABEL-modem-read-only" ]] \
    || die "WCNSS 固件来源策略不匹配"
[[ "$(manifest_value wcnss_nv_source)" == "PARTLABEL-persist-read-only" ]] \
    || die "WCNSS NV 来源策略不匹配"
[[ "$(manifest_value mpss_firmware_source)" == "PARTLABEL-modem-read-only" ]] \
    || die "MPSS 固件来源策略不匹配"
[[ "$(manifest_value rmtfs_mode)" == "read-only-physical-partitions-synchronized" ]] \
    || die "rmtfs 安全模式不匹配"
[[ "$(manifest_value modem_manager)" == "qcom-soc-qrtr" ]] \
    || die "ModemManager 模式不匹配"
[[ "$(manifest_value modem_default_modes)" == "3g-4g-preferred-4g" ]] \
    || die "modem 默认模式不匹配"
[[ "$(manifest_value wwan_ipv4)" == "networkmanager-dispatcher-bearer-values" ]] \
    || die "WWAN IPv4 兼容策略不匹配"
[[ "$(manifest_value resolv_conf)" == "NetworkManager-runtime" ]] \
    || die "DNS 运行时策略不匹配"
[[ "$(manifest_value time_sync)" == "qmi-dms-forward-only+systemd-timesyncd" ]] \
    || die "联网校时策略不匹配"
[[ "$(manifest_value system_locale)" == "C.UTF-8" ]] \
    || die "系统默认 locale 不匹配"
[[ "$(manifest_value nmtui_locale)" == "zh_CN.UTF-8" ]] \
    || die "nmtui 简体中文 locale 不匹配"
[[ "$(manifest_value wifi_ap_profile)" == "preinstalled-disabled" ]] \
    || die "Wi-Fi AP 预置策略不匹配"
[[ "$(manifest_value wifi_ap_ssid)" == "ZU02-Debian" ]] \
    || die "Wi-Fi AP 默认 SSID 不匹配"
[[ "$(manifest_value wifi_ap_ipv4)" == "192.168.69.1/24" ]] \
    || die "Wi-Fi AP 默认地址不匹配"
[[ "$(manifest_value wifi_interface_concurrency)" == "managed-or-ap-exclusive" ]] \
    || die "Wi-Fi 接口并发策略不匹配"
[[ "$(manifest_value usb_management)" == "static-service-networkmanager-unmanaged" ]] \
    || die "USB 管理网络所有权策略不匹配"
[[ "$(manifest_value network_topology)" == "isolated-usb-wifi-no-bridge" ]] \
    || die "默认网络拓扑不匹配"
[[ "$(manifest_value thermal_cpu_passive_trip_millic)" == "75000" ]] \
    || die "CPU 被动降频阈值不匹配"
[[ "$(manifest_value thermal_cpu_passive_hysteresis_millic)" == "3000" ]] \
    || die "CPU 被动降频回差不匹配"
[[ "$(manifest_value routing_firewall)" == "NetworkManager-nftables" ]] \
    || die "路由防火墙策略不匹配"
[[ "$(manifest_value management_ingress)" == "usb-only-rndis-ssh-tcp-adb-acm" ]] \
    || die "管理入口未限制为 USB"
[[ "$(manifest_value wwan_ingress)" == "drop-new-and-untracked" ]] \
    || die "WWAN 入站策略不匹配"
[[ "$(manifest_value lte_apn)" == "not-preconfigured" ]] \
    || die "纯 Debian 基础镜像不得预置运营商 APN"
keyring="$(manifest_value debian_keyring)"
[[ -s "$keyring" ]] || die "缺少构建所用 keyring：$keyring"
check_sha256 debian_keyring_sha256 "$keyring"

[[ "$(fdtget -t s "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" \
    /soc@0/remoteproc@a21b000 status)" == "okay" ]] \
    || die "DW01 DTB 未启用 WCNSS remoteproc"
[[ "$(fdtget -t s "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" \
    /soc@0/remoteproc@a21b000/iris compatible)" == "qcom,wcn3620" ]] \
    || die "DW01 DTB 的 WCNSS Iris 不是 qcom,wcn3620"
[[ "$(fdtget -t s "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" \
    /soc@0/remoteproc@4080000 status)" == "okay" ]] \
    || die "DW01 DTB 未启用 MPSS remoteproc"
[[ "$(fdtget -t x "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" \
    /reserved-memory/rmtfs@87c00000 reg)" == "87c00000 e0000" ]] \
    || die "DW01 DTB 的 RMTFS reserved-memory 不匹配"
[[ "$(fdtget -t s "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" \
    /soc@0/sram@8600000 compatible)" == "qcom,msm8909-imem syscon simple-mfd" ]] \
    || die "DW01 DTB 的 IMEM syscon 不匹配"
[[ "$(fdtget -t x "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" \
    /soc@0/sram@8600000 reg)" == "8600000 1000" ]] \
    || die "DW01 DTB 的 IMEM 地址不匹配"
[[ "$(fdtget -t s "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" \
    /soc@0/sram@8600000/reboot-mode compatible)" == "syscon-reboot-mode" ]] \
    || die "DW01 DTB 未启用 IMEM reboot-mode"
[[ "$(fdtget -t x "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" \
    /soc@0/sram@8600000/reboot-mode offset)" == "65c" ]] \
    || die "DW01 DTB 的 IMEM reboot-mode 偏移不匹配"
[[ "$(fdtget -t x "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" \
    /soc@0/sram@8600000/reboot-mode mode-bootloader)" == "77665500" ]] \
    || die "DW01 DTB 的 fastboot 重启魔数不匹配"
[[ "$(fdtget -t x "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" \
    /soc@0/sram@8600000/reboot-mode mode-normal)" == "77665501" ]] \
    || die "DW01 DTB 的普通重启魔数不匹配"
[[ "$(fdtget -t x "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" \
    /soc@0/sram@8600000/reboot-mode mode-recovery)" == "77665502" ]] \
    || die "DW01 DTB 的 recovery 重启魔数不匹配"
for thermal_zone in cpu0-2-thermal cpu1-3-thermal; do
    thermal_trip="/thermal-zones/$thermal_zone/trips/trip-point0"
    [[ "$(fdtget -t i "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" "$thermal_trip" temperature)" == "75000" ]] \
        || die "$thermal_zone 被动降频阈值不是 75000 m°C"
    [[ "$(fdtget -t i "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" "$thermal_trip" hysteresis)" == "3000" ]] \
        || die "$thermal_zone 被动降频回差不是 3000 m°C"
    thermal_critical_trip="/thermal-zones/$thermal_zone/trips/cpu_crit"
    [[ "$(fdtget -t s "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" "$thermal_critical_trip" type)" == "critical" ]] \
        || die "$thermal_zone 缺少 critical 保护"
    [[ "$(fdtget -t i "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" "$thermal_critical_trip" temperature)" == "100000" ]] \
        || die "$thermal_zone 临界关机阈值不是 100000 m°C"
    [[ "$(fdtget -t i "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" "$thermal_critical_trip" hysteresis)" == "2000" ]] \
        || die "$thermal_zone 临界关机回差不是 2000 m°C"
done
[[ "$(fdtget -t x "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" \
    /reserved-memory/mpss@88000000 reg)" == "88000000 5500000" ]] \
    || die "DW01 DTB 的 MPSS reserved-memory 不匹配"
[[ "$(fdtget -t x "$KERNEL_DIR/qcom-msm8909-zu02-dw01.dtb" \
    /reserved-memory/mba@8dc00000 reg)" == "8dc00000 100000" ]] \
    || die "DW01 DTB 的 MBA reserved-memory 不匹配"
for symbol in QCOM_WCNSS_PIL QCOM_WCNSS_CTRL WCN36XX CFG80211 MAC80211 RPMSG_QCOM_SMD; do
    grep -qx "CONFIG_${symbol}=y" "$KERNEL_DIR/config" \
        || die "内核未内建 CONFIG_${symbol}"
done
for symbol in QRTR QRTR_SMD WWAN QCOM_SYSMON QCOM_MDT_LOADER QCOM_RMTFS_MEM \
    QCOM_SMEM QCOM_SMP2P QCOM_SMSM SYSCON_REBOOT_MODE FAT_FS VFAT_FS \
    NLS_CODEPAGE_437 NLS_ISO8859_1; do
    grep -qx "CONFIG_${symbol}=y" "$KERNEL_DIR/config" \
        || die "内核未内建 CONFIG_${symbol}"
done
for symbol in QCOM_Q6V5_MSS QCOM_BAM_DMUX RPMSG_WWAN_CTRL; do
    grep -qx "CONFIG_${symbol}=m" "$KERNEL_DIR/config" \
        || die "内核未将 CONFIG_${symbol} 构建为模块"
done

log "核对产物哈希和分区边界"
check_sha256 rootfs_image_sha256 "$IMAGE"
check_sha256 boot_image_sha256 "$BOOT_IMAGE"
check_sha256 rootfs_tarball_sha256 "$ROOTFS_TARBALL"
check_size rootfs_image_bytes "$IMAGE"
check_size boot_image_bytes "$BOOT_IMAGE"
if [[ "$TARGET_PARTITION" == system ]]; then
    check_sha256 data_image_sha256 "$DATA_IMAGE"
    check_size data_image_bytes "$DATA_IMAGE"
    (( $(stat -c %s "$DATA_IMAGE") < DATA_PARTITION_SIZE )) \
        || die "data 镜像不小于 userdata 分区"
fi
if [[ "$TARGET_PARTITION" == large-rootfs ]]; then
    check_sha256 rootfs_system_image_sha256 "$ROOTFS_SYSTEM_IMAGE"
    check_size rootfs_system_image_bytes "$ROOTFS_SYSTEM_IMAGE"
    check_sha256 rootfs_cache_image_sha256 "$ROOTFS_CACHE_IMAGE"
    check_size rootfs_cache_image_bytes "$ROOTFS_CACHE_IMAGE"
    check_sha256 rootfs_userdata_image_sha256 "$ROOTFS_USERDATA_IMAGE"
    check_size rootfs_userdata_image_bytes "$ROOTFS_USERDATA_IMAGE"
fi
if [[ "$TARGET_PARTITION" == large-rootfs ]]; then
    [[ "$(stat -c %s "$IMAGE")" == "$LARGE_ROOTFS_FILESYSTEM_SIZE" ]] \
        || die "重组后的大根卷文件系统尺寸错误"
else
    (( $(stat -c %s "$IMAGE") < TARGET_PARTITION_SIZE )) \
        || die "rootfs 镜像不小于 $TARGET_PARTITION 分区"
fi
(( $(stat -c %s "$BOOT_IMAGE") < BOOT_PARTITION_SIZE )) \
    || die "boot 镜像不小于 32 MiB boot 分区"

log "只读检查 ext4 文件系统"
fsck_rc=0
e2fsck -fn "$IMAGE" || fsck_rc=$?
(( fsck_rc == 0 )) || die "e2fsck 只读检查失败，退出码 $fsck_rc"
label="$(tune2fs -l "$IMAGE" | awk -F: '$1 == "Filesystem volume name" {sub(/^[[:space:]]+/, "", $2); print $2}')"
[[ "$label" == "$ROOTFS_LABEL" ]] || die "ext4 标签不匹配：$label"
uuid="$(tune2fs -l "$IMAGE" | awk -F: '$1 == "Filesystem UUID" {sub(/^[[:space:]]+/, "", $2); print $2}')"
[[ "$uuid" == "$ROOTFS_UUID" ]] || die "ext4 UUID 不匹配：$uuid"
hash_seed="$(tune2fs -l "$IMAGE" | awk -F: '$1 == "Directory Hash Seed" {sub(/^[[:space:]]+/, "", $2); print $2}')"
[[ "$hash_seed" == "$ROOTFS_HASH_SEED" ]] || die "ext4 目录哈希种子不匹配：$hash_seed"
rootfs_block_size="$(tune2fs -l "$IMAGE" | awk -F: '$1 == "Block size" {sub(/^[[:space:]]+/, "", $2); print $2}')"
rootfs_free_blocks="$(tune2fs -l "$IMAGE" | awk -F: '$1 == "Free blocks" {sub(/^[[:space:]]+/, "", $2); print $2}')"
[[ "$rootfs_block_size" =~ ^[0-9]+$ && "$rootfs_free_blocks" =~ ^[0-9]+$ ]] \
    || die "无法解析 ext4 可用空间"
rootfs_free_bytes=$((rootfs_block_size * rootfs_free_blocks))
(( rootfs_free_bytes >= MIN_ROOTFS_FREE_BYTES )) \
    || die "ext4 可用空间不足：$rootfs_free_bytes < $MIN_ROOTFS_FREE_BYTES"
[[ "$(manifest_value rootfs_free_bytes)" == "$rootfs_free_bytes" ]] \
    || die "manifest 中的 ext4 可用空间不匹配"
python3 "$INODE_TIME_TOOL" verify "$IMAGE" "$PROJECT_SOURCE_DATE_EPOCH" \
    || die "ext4 inode 时间字段未归一化"
os_release="$(debugfs -R 'cat /usr/lib/os-release' "$IMAGE" 2>/dev/null)"
grep -q '^ID=debian$' <<<"$os_release" || die "ext4 内不是 Debian"
grep -q 'VERSION_ID="12"' <<<"$os_release" || die "ext4 内不是 Debian 12"
hostname_text="$(debugfs -R 'cat /etc/hostname' "$IMAGE" 2>/dev/null)"
[[ "$hostname_text" == "ufi210" ]] || die "ext4 内主机名不是 ufi210"
hosts_text="$(debugfs -R 'cat /etc/hosts' "$IMAGE" 2>/dev/null)"
grep -Fqx '127.0.1.1 ufi210' <<<"$hosts_text" || die "ext4 内 hosts 未映射 ufi210"
[[ "$(manifest_value hostname)" == "ufi210" ]] || die "manifest 主机名不是 ufi210"
fstab="$(debugfs -R 'cat /etc/fstab' "$IMAGE" 2>/dev/null)"
if [[ "$ROOTFS_AUTO_GROW" == enabled ]]; then
    grep -Fqx "$ROOTFS_DEVICE / ext4 defaults,noatime,x-systemd.growfs 0 1" <<<"$fstab" \
        || die "ext4 内 fstab 未启用 $TARGET_PARTITION 根分区自动扩容"
    debugfs -R 'stat /usr/lib/systemd/systemd-growfs' "$IMAGE" 2>/dev/null | grep -q '^Inode:' \
        || die "ext4 内缺少 systemd-growfs"
else
    grep -Fqx "$ROOTFS_DEVICE / ext4 defaults,noatime 0 1" <<<"$fstab" \
        || die "ext4 内 fstab 未指向 $TARGET_PARTITION"
fi
if [[ "$TARGET_PARTITION" == system ]]; then
    grep -Fqx 'PARTLABEL=userdata /data ext4 defaults,noatime,nosuid,nodev,nofail,x-systemd.growfs,x-systemd.device-timeout=30s 0 2' <<<"$fstab" \
        || die "ext4 内 fstab 未正确配置 userdata /data 自动扩容"
fi
grep -q '^PARTLABEL=modem /firmware vfat ro,nosuid,nodev,noexec,fmask=0133,dmask=0022,nofail,x-systemd.device-timeout=30s ' <<<"$fstab" \
    || die "ext4 内 modem 固件分区未按只读策略挂载"
grep -q '^PARTLABEL=persist /persist ext4 ro,noload,nosuid,nodev,noexec,nofail,x-systemd.device-timeout=30s ' <<<"$fstab" \
    || die "ext4 内 persist 校准分区未按只读策略挂载"
systemd_stat="$(debugfs -R 'stat /usr/lib/systemd/systemd' "$IMAGE" 2>/dev/null)"
grep -q '^Inode:' <<<"$systemd_stat" || die "ext4 内缺少 systemd"

if [[ "$TARGET_PARTITION" == system ]]; then
    log "只读检查 userdata data ext4 文件系统"
    data_fsck_rc=0
    e2fsck -fn "$DATA_IMAGE" || data_fsck_rc=$?
    (( data_fsck_rc == 0 )) || die "data e2fsck 只读检查失败，退出码 $data_fsck_rc"
    data_label="$(tune2fs -l "$DATA_IMAGE" | awk -F: '$1 == "Filesystem volume name" {sub(/^[[:space:]]+/, "", $2); print $2}')"
    [[ "$data_label" == "$DATA_LABEL" ]] || die "data ext4 标签不匹配：$data_label"
    data_uuid="$(tune2fs -l "$DATA_IMAGE" | awk -F: '$1 == "Filesystem UUID" {sub(/^[[:space:]]+/, "", $2); print $2}')"
    [[ "$data_uuid" == "$DATA_UUID" ]] || die "data ext4 UUID 不匹配：$data_uuid"
    data_hash_seed="$(tune2fs -l "$DATA_IMAGE" | awk -F: '$1 == "Directory Hash Seed" {sub(/^[[:space:]]+/, "", $2); print $2}')"
    [[ "$data_hash_seed" == "$DATA_HASH_SEED" ]] \
        || die "data ext4 目录哈希种子不匹配：$data_hash_seed"
    data_block_size="$(tune2fs -l "$DATA_IMAGE" | awk -F: '$1 == "Block size" {sub(/^[[:space:]]+/, "", $2); print $2}')"
    [[ "$data_block_size" == "4096" ]] || die "data ext4 block size 不匹配：$data_block_size"
    python3 "$INODE_TIME_TOOL" verify "$DATA_IMAGE" "$PROJECT_SOURCE_DATE_EPOCH" \
        || die "data ext4 inode 时间字段未归一化"
    for data_dir in apps backups srv; do
        debugfs -R "stat /$data_dir" "$DATA_IMAGE" 2>/dev/null | grep -q '^Inode:' \
            || die "data ext4 缺少初始目录：/$data_dir"
    done
fi

mkdir -p "$tmp_dir/initramfs-root"
gzip -dc "$INITRAMFS" | (cd "$tmp_dir/initramfs-root" && cpio -idmu --no-absolute-filenames 2>/dev/null)
cmp -s "$INITRAMFS_INIT" "$tmp_dir/initramfs-root/init" \
    || die "纯 Debian initramfs 的 init 脚本不匹配"
cmp -s "$USB_GADGET_SCRIPT" "$tmp_dir/initramfs-root/sbin/zu02-usb-gadget" \
    || die "纯 Debian initramfs 的 USB gadget 脚本不匹配"
cmp -s "$tmp_dir/initramfs-root/lib/firmware/regulatory.db" \
    <(tar -xJOf "$ROOTFS_TARBALL" ./usr/lib/firmware/regulatory.db-upstream) \
    || die "initramfs regulatory.db 不是 Debian upstream 数据库"
cmp -s "$tmp_dir/initramfs-root/lib/firmware/regulatory.db.p7s" \
    <(tar -xJOf "$ROOTFS_TARBALL" ./usr/lib/firmware/regulatory.db.p7s-upstream) \
    || die "initramfs regulatory.db.p7s 不是 upstream 签名"
check_initramfs_regdb_hash="$(sha256sum "$tmp_dir/initramfs-root/lib/firmware/regulatory.db" | awk '{print $1}')"
[[ "$check_initramfs_regdb_hash" == "$(manifest_value regulatory_db_sha256)" ]] \
    || die "initramfs regulatory.db SHA256 与 manifest 不匹配"
check_initramfs_regdb_signature_hash="$(sha256sum "$tmp_dir/initramfs-root/lib/firmware/regulatory.db.p7s" | awk '{print $1}')"
[[ "$check_initramfs_regdb_signature_hash" == "$(manifest_value regulatory_db_signature_sha256)" ]] \
    || die "initramfs regulatory.db.p7s SHA256 与 manifest 不匹配"
file "$tmp_dir/initramfs-root/bin/busybox" | grep -q 'ELF 32-bit.*ARM.*statically linked' \
    || die "纯 Debian initramfs 的 busybox 不是 32 位 ARM 静态 ELF"
file "$tmp_dir/initramfs-root/system/bin/reboot" | grep -q 'ELF 32-bit.*ARM.*statically linked' \
    || die "纯 Debian initramfs 的 reboot 兼容程序不是 32 位 ARM 静态 ELF"
file "$tmp_dir/initramfs-root/usr/sbin/dmsetup" | grep -q 'ELF 32-bit.*ARM.*dynamically linked' \
    || die "纯 Debian initramfs 的 dmsetup 不是 32 位 ARM 动态 ELF"
readelf -d "$tmp_dir/initramfs-root/usr/sbin/dmsetup" \
    "$tmp_dir/initramfs-root"/lib/arm-linux-gnueabihf/*.so* \
    > "$tmp_dir/initramfs-needed.txt" 2>/dev/null \
    || die "无法读取 initramfs dmsetup 动态依赖"
for needed in libdevmapper.so.1.02.1 libc.so.6 libselinux.so.1 libudev.so.1 libm.so.6 libpcre2-8.so.0; do
    grep -Fq "Shared library: [$needed]" "$tmp_dir/initramfs-needed.txt" \
        || die "initramfs dmsetup 依赖闭包缺少：$needed"
done
qemu-arm-static -L "$tmp_dir/initramfs-root" \
    "$tmp_dir/initramfs-root/usr/sbin/dmsetup" help \
    > "$tmp_dir/initramfs-dmsetup-help.txt" 2>&1 \
    || die "qemu-arm-static 无法执行 initramfs dmsetup"
grep -Fq 'create <dev_name>' "$tmp_dir/initramfs-dmsetup-help.txt" \
    || die "initramfs dmsetup 的 ARM 运行探针输出异常"
[[ -L "$tmp_dir/initramfs-root/lib/ld-linux-armhf.so.3" ]] \
    || die "initramfs 缺少 ARM 动态加载器链接"
for runtime_path in \
    lib/arm-linux-gnueabihf/ld-linux-armhf.so.3 \
    lib/arm-linux-gnueabihf/libpcre2-8.so.0.11.2 \
    lib/arm-linux-gnueabihf/libudev.so.1.7.5; do
    [[ -f "$tmp_dir/initramfs-root/$runtime_path" ]] \
        || die "initramfs dmsetup 运行库链接目标缺失：/$runtime_path"
done
cmp -s "$tmp_dir/initramfs-root/system/bin/reboot" \
    <(tar -xJOf "$ROOTFS_TARBALL" ./system/bin/reboot) \
    || die "纯 Debian initramfs 的 reboot 兼容程序与 rootfs 不一致"
for applet in blockdev cut ip mount sha256sum stty switch_root udhcpd; do
    [[ -L "$tmp_dir/initramfs-root/bin/$applet" ]] \
        || die "纯 Debian initramfs 缺少 busybox applet：$applet"
done
[[ ! -e "$tmp_dir/initramfs-root/bin/telnetd" ]] \
    || die "纯 Debian initramfs 不得开放 telnetd"
grep -Fq 'recovery shell is available on USB ACM /dev/ttyGS0' "$tmp_dir/initramfs-root/init" \
    || die "纯 Debian initramfs 未提供 USB ACM 救援说明"
grep -Fq '/system/bin/reboot bootloader' "$tmp_dir/initramfs-root/init" \
    || die "纯 Debian initramfs 未提供进入 fastboot 的救援命令"
grep -Fq 'if /sbin/zu02-usb-gadget setup && /sbin/zu02-usb-gadget activate; then' \
    "$tmp_dir/initramfs-root/init" \
    || die "纯 Debian initramfs 未重试完整 USB gadget 建立流程"
grep -Fq 'start_recovery_network 1 || log' "$tmp_dir/initramfs-root/init" \
    || die "纯 Debian initramfs 会因早期 USB 不可用而阻断正常启动"
grep -Fq 'start_recovery_network 60 || log' "$tmp_dir/initramfs-root/init" \
    || die "纯 Debian initramfs 救援模式未重试 USB gadget"
grep -Fq 'USB recovery RNDIS did not appear' "$tmp_dir/initramfs-root/init" \
    || die "纯 Debian initramfs 未核对 RNDIS 管理接口"
grep -Fq 'USB recovery ACM is unavailable; continuing with RNDIS management' \
    "$tmp_dir/initramfs-root/init" \
    || die "纯 Debian initramfs 会因 ACM 缺失阻断正常启动"
grep -Fq 'finish_readonly_probe()' "$tmp_dir/initramfs-root/init" \
    || die "纯 Debian initramfs 缺少只读探针成功返回 fastboot 的路径"
grep -Fq "finish_readonly_probe 'read-only ufi210-root probe completed successfully'" \
    "$tmp_dir/initramfs-root/init" \
    || die "大根卷只读探针完成后不会自动返回 fastboot"
grep -Fq 'read-only probe failed, returning to persistent boot' "$tmp_dir/initramfs-root/init" \
    || die "大根卷只读探针失败时不会返回持久系统"
grep -Fq "has_cmdline_flag 'ufi210.pre_dm_rescue=1'" "$tmp_dir/initramfs-root/init" \
    || die "纯 Debian initramfs 缺少 dm 设置前的 USB 诊断入口"
grep -Fq 'root=PARTLABEL=cache)' "$tmp_dir/initramfs-root/init" \
    || die "纯 Debian initramfs 未限制接受 cache 根分区"
grep -Fq 'root=PARTLABEL=system)' "$tmp_dir/initramfs-root/init" \
    || die "纯 Debian initramfs 未限制接受 system 根分区"
grep -Fq 'PARTNAME=$partlabel' "$tmp_dir/initramfs-root/init" \
    || die "纯 Debian initramfs 未按所选 GPT PARTNAME 查找根分区"
if [[ "$TARGET_PARTITION" == large-rootfs ]]; then
    for initramfs_line in \
        "root=/dev/mapper/ufi210-root" \
        "system_sectors=$SYSTEM_PARTITION_SECTORS" \
        "cache_sectors=$CACHE_PARTITION_SECTORS" \
        "userdata_sectors=$USERDATA_PARTITION_SECTORS" \
        "system_start=$SYSTEM_PARTITION_START" \
        "cache_start=$CACHE_PARTITION_START" \
        "userdata_lba=$USERDATA_PARTITION_START" \
        "dmsetup create --readonly --noudevsync ufi210-root" \
        "dmsetup create --noudevsync ufi210-root" \
        "dmsetup mknodes ufi210-root" \
        'actual_table="$(dmsetup table ufi210-root' \
        '[ "$actual_table" = "$expected_table" ]' \
        "! mountpoint -q /sysroot" \
        "ufi210.dm_probe=1"; do
        grep -Fq "$initramfs_line" "$tmp_dir/initramfs-root/init" \
            || die "大根卷 initramfs 缺少：$initramfs_line"
    done
fi
tar -tJf "$ROOTFS_TARBALL" > "$tmp_dir/rootfs-files.txt"
mkdir -p "$tmp_dir/rootfs-meta"
tar -C "$tmp_dir/rootfs-meta" -xJf "$ROOTFS_TARBALL" \
    ./etc/resolv.conf ./etc/apt ./etc/NetworkManager/system-connections ./usr/local/bin/nmtui
[[ -L "$tmp_dir/rootfs-meta/etc/resolv.conf" ]] \
    || die "rootfs 的 /etc/resolv.conf 不是符号链接"
[[ "$(readlink "$tmp_dir/rootfs-meta/etc/resolv.conf")" == "/run/NetworkManager/resolv.conf" ]] \
    || die "rootfs 的 /etc/resolv.conf 未交给 NetworkManager 管理"
[[ ! -e "$tmp_dir/rootfs-meta/etc/NetworkManager/system-connections/zu02-usb-management.nmconnection" ]] \
    || die "rootfs 不得保留旧的 NetworkManager USB 管理连接"
[[ "$(stat -c '%a' "$tmp_dir/rootfs-meta/etc/NetworkManager/system-connections/zu02-wifi-ap.nmconnection")" == "600" ]] \
    || die "Wi-Fi AP 连接权限不是 0600"
[[ "$(stat -c '%a' "$tmp_dir/rootfs-meta/usr/local/bin/nmtui")" == "755" ]] \
    || die "nmtui 包装器权限不是 0755"
expected_runtime_sources="$(cat <<EOF
deb $DEBIAN_RUNTIME_MIRROR bookworm main
deb $DEBIAN_RUNTIME_MIRROR bookworm-updates main
deb $DEBIAN_RUNTIME_SECURITY_MIRROR bookworm-security main
deb $DEBIAN_RUNTIME_MIRROR bookworm-backports main
EOF
)"
actual_runtime_sources="$(cat "$tmp_dir/rootfs-meta/etc/apt/sources.list")"
[[ "$actual_runtime_sources" == "$expected_runtime_sources" ]] \
    || die "rootfs 的运行期 APT 源不匹配"
if grep -RIEq 'snapshot\.debian\.org|check-valid-until|Check-Valid-Until' \
    "$tmp_dir/rootfs-meta/etc/apt"; then
    die "rootfs 残留构建期 Snapshot 地址或 Valid-Until 豁免"
fi

log "核对 rootfs 服务、密码和 ARM adbd"
for required_path in \
    ./etc/systemd/system/adbd.service \
    ./etc/systemd/system/zu02-usb-gadget.service \
    ./etc/systemd/system/zu02-usb-watchdog.service \
    ./etc/systemd/system/zu02-usb-watchdog.timer \
    ./etc/systemd/system/zu02-usb-network.service \
    ./etc/systemd/system/zu02-wcnss.service \
    ./etc/systemd/system/zu02-mpss.service \
    ./etc/systemd/system/zu02-modem-prepare.service \
    ./etc/systemd/system/zu02-modem-register.service \
    ./etc/systemd/system/ufi210-modem-time-sync.service \
    ./etc/systemd/system/zu02-firewall.service \
    ./etc/systemd/system/rmtfs.service.d/10-zu02-read-only.conf \
    ./etc/systemd/system/ModemManager.service.d/10-zu02-dpm.conf \
    ./etc/modprobe.d/zu02-mpss.conf \
    ./etc/systemd/system/multi-user.target.wants/adbd.service \
    ./etc/systemd/system/multi-user.target.wants/zu02-usb-gadget.service \
    ./etc/systemd/system/timers.target.wants/zu02-usb-watchdog.timer \
    ./etc/systemd/system/timers.target.wants/fstrim.timer \
    ./etc/systemd/system/multi-user.target.wants/zu02-usb-network.service \
    ./etc/systemd/system/multi-user.target.wants/zu02-wcnss.service \
    ./etc/systemd/system/multi-user.target.wants/zu02-mpss.service \
    ./etc/systemd/system/multi-user.target.wants/zu02-modem-prepare.service \
    ./etc/systemd/system/multi-user.target.wants/zu02-modem-register.service \
    ./etc/systemd/system/multi-user.target.wants/ufi210-modem-time-sync.service \
    ./etc/systemd/system/sysinit.target.wants/zu02-firewall.service \
    ./etc/systemd/system/multi-user.target.wants/qrtr-ns.service \
    ./etc/systemd/system/multi-user.target.wants/rmtfs.service \
    ./etc/systemd/system/multi-user.target.wants/ModemManager.service \
    ./etc/systemd/system/multi-user.target.wants/ssh.service \
    ./etc/systemd/system/ssh.service.d/10-zu02.conf \
    ./etc/systemd/system/multi-user.target.wants/dnsmasq.service \
    ./etc/systemd/system/multi-user.target.wants/NetworkManager.service \
    ./etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service \
    ./etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service \
    ./etc/systemd/system/serial-getty@ttyGS0.service.d/10-zu02.conf \
    ./etc/systemd/journald.conf.d/10-zu02.conf \
    ./etc/NetworkManager/dispatcher.d/90-zu02-wwan-ip \
    ./etc/NetworkManager/conf.d/10-ufi210-usb-management.conf \
    ./etc/NetworkManager/conf.d/20-ufi210-wifi-mac.conf \
    ./etc/NetworkManager/system-connections/zu02-wifi-ap.nmconnection \
    ./etc/nftables.d/zu02-firewall.nft \
    ./etc/resolv.conf \
    ./etc/default/locale \
    ./system/bin/reboot \
    ./usr/bin/curl \
    ./usr/bin/nmcli \
    ./usr/bin/nmtui \
    ./usr/local/bin/nmtui \
    ./usr/bin/mmcli \
    ./usr/bin/qmicli \
    ./usr/bin/qrtr-ns \
    ./usr/bin/rmtfs \
    ./usr/lib/systemd/system/systemd-timesyncd.service \
    ./usr/lib/locale/locale-archive \
    ./usr/share/locale/zh_CN/LC_MESSAGES/NetworkManager.mo \
    ./usr/share/doc/base-files/copyright \
    ./usr/share/doc/busybox-static/copyright \
    ./usr/share/doc/curl/copyright \
    ./usr/share/doc/network-manager/copyright \
    ./usr/share/doc/adbd/copyright \
    ./usr/lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin \
    ./usr/sbin/hostapd \
    ./usr/sbin/iw \
    ./usr/sbin/rfkill \
    ./usr/sbin/wpa_supplicant \
    ./usr/sbin/ModemManager \
    ./usr/sbin/nft \
    ./usr/sbin/zu02-modem-prepare \
    ./usr/sbin/zu02-modem-register \
    ./usr/sbin/ufi210-modem-time-sync \
    ./usr/sbin/zu02-firewall \
    ./usr/sbin/zu02-mpss-start \
    ./usr/sbin/zu02-usb-gadget \
    ./usr/sbin/zu02-usb-watchdog \
    ./usr/sbin/zu02-usb-network \
    ./usr/sbin/zu02-wcnss-start \
    ./usr/lib/modules/7.0.0-msm8909/modules.dep; do
    grep -Fqx "$required_path" "$tmp_dir/rootfs-files.txt" \
        || die "rootfs 缺少：$required_path"
done
for module_name in qcom_q6v5_mss qcom_bam_dmux rpmsg_wwan_ctrl; do
    grep -Eq "/${module_name}\.ko(\.(gz|xz|zst))?$" "$tmp_dir/rootfs-files.txt" \
        || die "rootfs 缺少内核模块：$module_name"
done
for firmware_name in "${WCNSS_FIRMWARE_FILES[@]}"; do
    grep -Fqx "./usr/lib/firmware/$firmware_name" "$tmp_dir/rootfs-files.txt" \
        || die "rootfs 缺少 WCNSS 固件：$firmware_name"
done
if grep -Fqx './usr/bin/qemu-arm-static' "$tmp_dir/rootfs-files.txt"; then
    die "rootfs 不应保留宿主机 qemu-arm-static"
fi
if grep -Eq '^\./etc/ssh/ssh_host_.*_key(\.pub)?$' "$tmp_dir/rootfs-files.txt"; then
    die "rootfs 不得预置构建期 SSH host key"
fi
if grep -Eq '^\./var/log/(apt/|alternatives\.log$|bootstrap\.log$|dpkg\.log$|lastlog$|wtmp$|btmp$)' "$tmp_dir/rootfs-files.txt"; then
    die "rootfs 不得保留非确定性的构建期安装日志"
fi
if grep -Eq '^\./(etc/(group-|gshadow-|passwd-|shadow-|xml/.*\.old$)|var/cache/ldconfig/aux-cache$|var/lib/dpkg/(diversions-old|status-old|lock)$)' "$tmp_dir/rootfs-files.txt"; then
    die "rootfs 不得保留安装期密码备份、inode 缓存、锁或旧状态文件"
fi
root_shadow="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/shadow | awk -F: '$1 == "root" {print $2 ":" $3}')"
[[ "$root_shadow" == "$EXPECTED_ROOT_HASH:20623" ]] \
    || die "root 密码哈希或固定变更日期不匹配"
tar -xJOf "$ROOTFS_TARBALL" ./usr/lib/android-sdk/platform-tools/adbd > "$tmp_dir/adbd"
file "$tmp_dir/adbd" | grep -q 'ELF 32-bit.*ARM' || die "adbd 不是 32 位 ARM ELF"
tar -xJOf "$ROOTFS_TARBALL" ./system/bin/reboot > "$tmp_dir/reboot-compat"
file "$tmp_dir/reboot-compat" | grep -q 'ELF 32-bit.*ARM.*statically linked' \
    || die "ADB reboot 兼容程序不是 32 位 ARM 静态 ELF"
[[ "$(sha256sum "$tmp_dir/reboot-compat" | awk '{print $1}')" == \
    "$(manifest_value reboot_compat_binary_sha256)" ]] \
    || die "ADB reboot 兼容程序哈希不匹配"
grep -q 'LINUX_REBOOT_CMD_RESTART2' "$REBOOT_COMPAT_SOURCE" \
    || die "ADB reboot 兼容程序未使用 RESTART2"
grep -q 'strcmp(argv\[1\], "bootloader")' "$REBOOT_COMPAT_SOURCE" \
    || die "ADB reboot 兼容程序未限制 bootloader 模式"
grep -q 'strcmp(argv\[1\], "recovery")' "$REBOOT_COMPAT_SOURCE" \
    || die "ADB reboot 兼容程序未限制 recovery 模式"
adbd_service="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/adbd.service)"
grep -q '^Type=notify$' <<<"$adbd_service" || die "adbd 服务类型不是 notify"
grep -q '^Environment=ADBD_PORT=5555$' <<<"$adbd_service" || die "adbd 未启用 TCP 5555"
grep -q '^BindsTo=zu02-firewall.service$' <<<"$adbd_service" \
    || die "adbd 没有绑定 fail-closed 防火墙服务"
grep -q '^Wants=zu02-usb-network.service$' <<<"$adbd_service" \
    || die "adbd 没有声明 USB 管理网络软依赖"
grep -q '^After=zu02-firewall.service zu02-usb-network.service$' <<<"$adbd_service" \
    || die "adbd 没有排在防火墙和 USB 管理网络之后"
grep -q '^StartLimitIntervalSec=0$' <<<"$adbd_service" || die "adbd 未关闭启动频率限制"
grep -q '^ExecStart=/usr/lib/android-sdk/platform-tools/adbd$' <<<"$adbd_service" \
    || die "adbd 启动命令不匹配"
grep -q '^Restart=on-failure$' <<<"$adbd_service" || die "adbd 未启用故障重启"
if grep -Eqi 'functionfs|ffs\.adb|zu02-usb-gadget|^ExecStartPre=|^ExecStartPost=|^ExecStopPost=' <<<"$adbd_service"; then
    die "TCP adbd 不得管理 USB gadget 生命周期"
fi
gadget_service="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/zu02-usb-gadget.service)"
grep -q '^Type=oneshot$' <<<"$gadget_service" || die "USB gadget 服务不是 oneshot"
grep -q '^ExecStart=/usr/sbin/zu02-usb-gadget setup$' <<<"$gadget_service" \
    || die "USB gadget 服务缺少 setup"
grep -q '^ExecStartPost=/usr/sbin/zu02-usb-gadget activate$' <<<"$gadget_service" \
    || die "USB gadget 服务缺少 activate"
grep -q '^RemainAfterExit=yes$' <<<"$gadget_service" || die "USB gadget 服务未保持 active 状态"
gadget_script="$(tar -xJOf "$ROOTFS_TARBALL" ./usr/sbin/zu02-usb-gadget)"
grep -q 'echo MSFT100.*os_desc/qw_sign' <<<"$gadget_script" || die "USB gadget 缺少 MSFT100 描述符"
grep -q 'echo 5162001.*sub_compatible_id' <<<"$gadget_script" || die "USB gadget 缺少 RNDIS 子兼容标识"
grep -q '^    echo ZU02-DW01 > "\$G/strings/0x409/serialnumber"$' <<<"$gadget_script" \
    || die "USB gadget 序列号不匹配"
grep -q '^    echo 0xD001 > "\$G/idProduct"$' <<<"$gadget_script" \
    || die "USB gadget product ID 不是已验证的 D001"
grep -Fq 'androidboot.serialno=*)' <<<"$gadget_script" \
    || die "USB gadget 未优先使用设备序列种子"
grep -Fq 'sha256sum | cut -c1-10' <<<"$gadget_script" \
    || die "USB gadget 未哈希设备种子"
grep -Fq 'RNDIS_DEV_ADDR="02:$suffix"' <<<"$gadget_script" \
    || die "USB gadget 设备端 MAC 不是本地管理单播地址"
grep -Fq 'RNDIS_HOST_ADDR="06:$suffix"' <<<"$gadget_script" \
    || die "USB gadget 主机端 MAC 不是本地管理单播地址"
grep -Fq 'echo "$RNDIS_DEV_ADDR" > "$G/functions/rndis.usb0/dev_addr"' <<<"$gadget_script" \
    || die "USB gadget 未固定设备端 RNDIS MAC"
grep -Fq 'echo "$RNDIS_HOST_ADDR" > "$G/functions/rndis.usb0/host_addr"' <<<"$gadget_script" \
    || die "USB gadget 未固定主机端 RNDIS MAC"
grep -q 'attempt.*-le 10' <<<"$gadget_script" || die "USB gadget 缺少有限重试"
grep -q 'can_reuse_active_gadget' <<<"$gadget_script" || die "USB gadget 缺少运行期复用路径"
grep -q "echo 'RNDIS + ACM'.*configuration" <<<"$gadget_script" \
    || die "USB gadget 配置字符串不匹配"
if grep -Eqi 'functionfs|ffs\.adb' <<<"$gadget_script"; then
    die "固定 RNDIS + ACM gadget 不得包含 FunctionFS ADB"
fi
grep -q '^rebuild() {$' <<<"$gadget_script" || die "USB gadget 缺少完整强制重建路径"
grep -q '^    rebuild) rebuild ;;$' <<<"$gadget_script" || die "USB gadget 未导出完整强制重建命令"
watchdog_script="$(tar -xJOf "$ROOTFS_TARBALL" ./usr/sbin/zu02-usb-watchdog)"
grep -q '^MIN_UNHEALTHY_SECONDS=5$' <<<"$watchdog_script" \
    || die "USB watchdog 连续异常阈值不匹配"
grep -q '^usb_healthy() {$' <<<"$watchdog_script" || die "USB watchdog 缺少健康检查"
grep -q '^    systemctl is-active --quiet zu02-usb-gadget\.service$' <<<"$watchdog_script" \
    || die "USB watchdog 没有核对 gadget 服务状态"
if grep -Eqi 'adbd|functionfs|ffs\.adb|/sys/class/udc/.*/state' <<<"$watchdog_script"; then
    die "USB watchdog 不得依赖 ADB 生命周期或主机枚举状态"
fi
grep -Fq '0x[dD]001)' <<<"$watchdog_script" \
    || die "USB watchdog 未核对固定 product ID"
grep -q '^/usr/sbin/zu02-usb-gadget rebuild$' <<<"$watchdog_script" \
    || die "USB watchdog 没有强制重建 gadget"
grep -q '^/usr/sbin/zu02-usb-network$' <<<"$watchdog_script" \
    || die "USB watchdog 没有恢复管理网络"
watchdog_service="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/zu02-usb-watchdog.service)"
grep -q '^ExecStart=/usr/sbin/zu02-usb-watchdog$' <<<"$watchdog_service" \
    || die "USB watchdog 服务启动命令不匹配"
watchdog_timer="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/zu02-usb-watchdog.timer)"
grep -q '^OnBootSec=90s$' <<<"$watchdog_timer" || die "USB watchdog 启动延迟不匹配"
grep -q '^OnUnitActiveSec=5s$' <<<"$watchdog_timer" || die "USB watchdog 定时间隔不匹配"
grep -q '^RandomizedDelaySec=0$' <<<"$watchdog_timer" || die "USB watchdog 不得随机延迟"
network_service="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/zu02-usb-network.service)"
grep -q '^Requires=zu02-usb-gadget.service$' <<<"$network_service" \
    || die "USB 网络服务未依赖固定 gadget"
if grep -Eq '^(Wants|Requires)=adbd\.service$' <<<"$network_service"; then
    die "USB 网络服务不得依赖 adbd"
fi
serial_service="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/serial-getty@ttyGS0.service.d/10-zu02.conf)"
grep -q '^Requires=zu02-usb-gadget.service$' <<<"$serial_service" \
    || die "ACM getty 未依赖固定 gadget 服务"
wcnss_service="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/zu02-wcnss.service)"
grep -q '^Before=NetworkManager.service$' <<<"$wcnss_service" \
    || die "WCNSS 服务未排在 NetworkManager 之前"
grep -q '^ExecStart=/usr/sbin/zu02-wcnss-start$' <<<"$wcnss_service" \
    || die "WCNSS 服务启动命令不匹配"
grep -q '^RequiresMountsFor=/firmware /persist$' <<<"$wcnss_service" \
    || die "WCNSS 服务未依赖只读 modem/persist 挂载点"
wcnss_script="$(tar -xJOf "$ROOTFS_TARBALL" ./usr/sbin/zu02-wcnss-start)"
grep -q 'remoteproc.*/name' <<<"$wcnss_script" || die "WCNSS 脚本未按 remoteproc name 查找设备"
grep -q '^        iw reg set CN$' <<<"$wcnss_script" || die "WCNSS 脚本未设置 CN 监管域"
grep -q "iw reg get | grep -q '\^country CN:'" <<<"$wcnss_script" \
    || die "WCNSS 脚本未验证 CN 监管域已生效"
grep -q 'findmnt -nro OPTIONS' <<<"$wcnss_script" \
    || die "WCNSS 脚本未验证 modem/persist 只读挂载"
if grep -q 'remoteproc0' <<<"$wcnss_script"; then
    die "WCNSS 脚本不应硬编码 remoteproc0"
fi

mpss_service="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/zu02-mpss.service)"
grep -q '^Requires=rmtfs.service$' <<<"$mpss_service" \
    || die "MPSS 服务未强制依赖 rmtfs"
grep -q '^RequiresMountsFor=/firmware$' <<<"$mpss_service" \
    || die "MPSS 服务未依赖只读 firmware 挂载点"
grep -q '^Before=zu02-modem-prepare.service ModemManager.service$' <<<"$mpss_service" \
    || die "MPSS 服务顺序不匹配"
grep -q '^ExecStart=/usr/sbin/zu02-mpss-start$' <<<"$mpss_service" \
    || die "MPSS 服务启动命令不匹配"
mpss_script="$(tar -xJOf "$ROOTFS_TARBALL" ./usr/sbin/zu02-mpss-start)"
grep -q 'findmnt -nro OPTIONS /firmware' <<<"$mpss_script" \
    || die "MPSS 脚本未验证 firmware 只读挂载"
grep -q '^modprobe qcom_q6v5_mss$' <<<"$mpss_script" \
    || die "MPSS 脚本未加载 qcom_q6v5_mss"
if grep -q 'remoteproc0' <<<"$mpss_script"; then
    die "MPSS 脚本不应硬编码 remoteproc0"
fi
rmtfs_override="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/rmtfs.service.d/10-zu02-read-only.conf)"
grep -q '^RequiresMountsFor=/firmware$' <<<"$rmtfs_override" \
    || die "rmtfs 未依赖 modem firmware 挂载点"
grep -q '^ExecStartPre=/sbin/modprobe qcom_q6v5_mss$' <<<"$rmtfs_override" \
    || die "rmtfs 未在启动前注册 MPSS remoteproc"
grep -q '^ExecStart=/usr/bin/rmtfs -r -P -s$' <<<"$rmtfs_override" \
    || die "rmtfs 未固定为只读物理分区同步模式"
modem_prepare_service="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/zu02-modem-prepare.service)"
grep -q '^Requires=zu02-mpss.service qrtr-ns.service rmtfs.service$' <<<"$modem_prepare_service" \
    || die "modem prepare 服务依赖不完整"
grep -q '^Before=ModemManager.service$' <<<"$modem_prepare_service" \
    || die "modem prepare 服务未排在 ModemManager 之前"
modem_prepare_script="$(tar -xJOf "$ROOTFS_TARBALL" ./usr/sbin/zu02-modem-prepare)"
grep -Fq "ctrl-port-name=DATA5_CNTL,hw-data-ep-type=bam-dmux" <<<"$modem_prepare_script" \
    || die "modem prepare 脚本缺少 DATA5_CNTL/BAM-DMUX DPM 请求"
grep -q '^    ip link set wwan0 up$' <<<"$modem_prepare_script" \
    || die "modem prepare 脚本未提前打开 BAM-DMUX netdev"
modemmanager_override="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/ModemManager.service.d/10-zu02-dpm.conf)"
grep -q '^Requires=zu02-modem-prepare.service$' <<<"$modemmanager_override" \
    || die "ModemManager 未强制依赖 DPM 准备服务"
modem_register_service="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/zu02-modem-register.service)"
grep -q '^Requires=ModemManager.service rmtfs.service$' <<<"$modem_register_service" \
    || die "modem 默认模式服务依赖不完整"
grep -q '^ExecStart=/usr/sbin/zu02-modem-register$' <<<"$modem_register_service" \
    || die "modem 默认模式服务命令不匹配"
modem_register_script="$(tar -xJOf "$ROOTFS_TARBALL" ./usr/sbin/zu02-modem-register)"
grep -Fq -- "--set-allowed-modes='3g|4g'" <<<"$modem_register_script" \
    || die "modem 默认模式脚本未启用 3G+4G"
grep -q '^        --set-preferred-mode=4g; then$' <<<"$modem_register_script" \
    || die "modem 默认模式脚本未优先 4G"
modem_time_sync_service="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/ufi210-modem-time-sync.service)"
grep -q '^Requires=zu02-modem-register.service$' <<<"$modem_time_sync_service" \
    || die "基带校时服务未依赖 modem 注册服务"
grep -q '^After=zu02-modem-register.service systemd-timesyncd.service$' <<<"$modem_time_sync_service" \
    || die "基带校时服务启动顺序不匹配"
grep -q '^ExecStart=/usr/sbin/ufi210-modem-time-sync$' <<<"$modem_time_sync_service" \
    || die "基带校时服务命令不匹配"
modem_time_sync_script="$(tar -xJOf "$ROOTFS_TARBALL" ./usr/sbin/ufi210-modem-time-sync)"
grep -Fq -- '--dms-get-time' <<<"$modem_time_sync_script" \
    || die "基带校时脚本未读取 QMI DMS 时间"
grep -q '^minimum_unix_seconds=1704067200$' <<<"$modem_time_sync_script" \
    || die "基带校时脚本最小可信时间不匹配"
grep -q '^maximum_unix_seconds=2147483647$' <<<"$modem_time_sync_script" \
    || die "基带校时脚本最大可信时间不匹配"
grep -Fq 'if [ "$modem_unix_seconds" -le $((current_unix_seconds + 5)) ]; then' \
    <<<"$modem_time_sync_script" || die "基带校时脚本可能向后拨动系统时钟"
wwan_ip_script="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/NetworkManager/dispatcher.d/90-zu02-wwan-ip)"
grep -q '^    wwan0|wwan0qmi0) ;;$' <<<"$wwan_ip_script" \
    || die "WWAN dispatcher 未限制到目标 modem 接口"
grep -q 'bearer\.ipv4-config\.address' <<<"$wwan_ip_script" \
    || die "WWAN dispatcher 未读取 bearer IPv4 地址"
grep -q '^max_bearer_attempts=15$' <<<"$wwan_ip_script" \
    || die "WWAN dispatcher 未等待 ModemManager 发布 connected bearer"
grep -Fq 'modem\.generic\.bearers[[:space:]]*:' <<<"$wwan_ip_script" \
    || die "WWAN dispatcher 未兼容单值 bearer 列表"
grep -Fq 'modem\.generic\.bearers\.value\[[0-9][0-9]*\]' <<<"$wwan_ip_script" \
    || die "WWAN dispatcher 未兼容多值 bearer 列表"
grep -q '^ip address replace "$address/$prefix" dev wwan0$' <<<"$wwan_ip_script" \
    || die "WWAN dispatcher 未配置 wwan0 地址"
grep -q '^ip route replace default via "$gateway" dev wwan0 metric 700$' <<<"$wwan_ip_script" \
    || die "WWAN dispatcher 未配置默认路由"
if grep -Eqi 'ctnet|mycdma|vnet\.mobi|gsm\.(username|password)' <<<"$wwan_ip_script"; then
    die "纯 Debian WWAN dispatcher 不得预置 APN 或运营商凭据"
fi
if grep -Fqx './etc/NetworkManager/dispatcher.d/01-ifupdown' "$tmp_dir/rootfs-files.txt"; then
    die "rootfs 不应保留会拒绝 NetworkManager reapply 动作的 ifupdown dispatcher"
fi
modprobe_policy="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/modprobe.d/zu02-mpss.conf)"
grep -q '^blacklist qcom_q6v5_mss$' <<<"$modprobe_policy" \
    || die "MPSS 模块未限制为 rmtfs 控制的显式加载"

grep -Fqx 'firmware_source=device:PARTLABEL=modem:/image' "$WCNSS_MANIFEST" \
    || die "WCNSS 固件清单来源不匹配"
grep -Fqx 'nv_source=device:PARTLABEL=persist:/WCNSS_qcom_wlan_nv.bin' "$WCNSS_MANIFEST" \
    || die "WCNSS NV 清单来源不匹配"
grep -Fqx 'packaging=symlink-only' "$WCNSS_MANIFEST" \
    || die "WCNSS 清单未声明只打包符号链接"
mkdir -p "$tmp_dir/wcnss-links"
wcnss_tar_paths=()
for firmware_name in "${WCNSS_FIRMWARE_FILES[@]}"; do
    wcnss_tar_paths+=("./usr/lib/firmware/$firmware_name")
done
wcnss_tar_paths+=("./usr/lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin")
tar -C "$tmp_dir/wcnss-links" -xJf "$ROOTFS_TARBALL" "${wcnss_tar_paths[@]}"
for firmware_name in "${WCNSS_FIRMWARE_FILES[@]}"; do
    expected_hash="$(sha256sum "$WCNSS_FIRMWARE_DIR/$firmware_name" | awk '{print $1}')"
    firmware_link="$tmp_dir/wcnss-links/usr/lib/firmware/$firmware_name"
    [[ -L "$firmware_link" ]] || die "rootfs 内 WCNSS 固件不是符号链接：$firmware_name"
    [[ "$(readlink "$firmware_link")" == "/firmware/image/$firmware_name" ]] \
        || die "rootfs 内 WCNSS 固件链接目标不匹配：$firmware_name"
    grep -Fqx "$expected_hash  $firmware_name" "$WCNSS_MANIFEST" \
        || die "WCNSS 固件清单缺少：$firmware_name"
done
nv_link="$tmp_dir/wcnss-links/usr/lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin"
[[ -L "$nv_link" ]] || die "rootfs 内 WCNSS 校准 NV 不是符号链接"
[[ "$(readlink "$nv_link")" == "/persist/WCNSS_qcom_wlan_nv.bin" ]] \
    || die "rootfs 内 WCNSS 校准 NV 链接目标不匹配"
actual_nv_hash="$(manifest_value wcnss_nv_sha256)"
[[ "$actual_nv_hash" == "$(sha256sum "$WCNSS_NV" | awk '{print $1}')" ]] \
    || die "WCNSS 校准 NV 输入哈希不匹配"
grep -Fqx "$actual_nv_hash  wlan/prima/WCNSS_qcom_wlan_nv.bin" "$WCNSS_MANIFEST" \
    || die "WCNSS 固件清单缺少校准 NV"

grep -Fqx 'source=device:PARTLABEL=modem:/image' "$MPSS_MANIFEST" \
    || die "MPSS 固件清单来源不匹配"
grep -Fqx 'packaging=symlink-only' "$MPSS_MANIFEST" \
    || die "MPSS 固件清单未声明只打包符号链接"
mkdir -p "$tmp_dir/mpss-links"
mpss_tar_paths=()
for firmware_name in "${MPSS_FIRMWARE_FILES[@]}"; do
    mpss_tar_paths+=("./usr/lib/firmware/$firmware_name")
done
tar -C "$tmp_dir/mpss-links" -xJf "$ROOTFS_TARBALL" "${mpss_tar_paths[@]}"
for firmware_name in "${MPSS_FIRMWARE_FILES[@]}"; do
    firmware_link="$tmp_dir/mpss-links/usr/lib/firmware/$firmware_name"
    [[ -L "$firmware_link" ]] || die "rootfs 内 MPSS 固件不是符号链接：$firmware_name"
    [[ "$(readlink "$firmware_link")" == "/firmware/image/$firmware_name" ]] \
        || die "rootfs 内 MPSS 固件链接目标不匹配：$firmware_name"
    expected_hash="$(sha256sum "$MPSS_FIRMWARE_DIR/$firmware_name" | awk '{print $1}')"
    grep -Fqx "$expected_hash  $firmware_name" "$MPSS_MANIFEST" \
        || die "MPSS 固件清单缺少：$firmware_name"
done
journal_config="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/journald.conf.d/10-zu02.conf)"
grep -q '^Storage=persistent$' <<<"$journal_config" || die "journald 未启用持久日志"
nmtui_wrapper="$(tar -xJOf "$ROOTFS_TARBALL" ./usr/local/bin/nmtui)"
grep -q '^unset LC_ALL$' <<<"$nmtui_wrapper" \
    || die "nmtui 包装器未清除会覆盖中文设置的 LC_ALL"
grep -q '^export LANG=zh_CN.UTF-8$' <<<"$nmtui_wrapper" \
    || die "nmtui 包装器未设置简体中文 LANG"
grep -q '^export LC_MESSAGES=zh_CN.UTF-8$' <<<"$nmtui_wrapper" \
    || die "nmtui 包装器未设置简体中文消息 locale"
grep -q '^exec /usr/bin/nmtui "$@"$' <<<"$nmtui_wrapper" \
    || die "nmtui 包装器没有执行 Debian nmtui"
[[ "$(sha256sum "$PROJECT_ROOT/patches/rootfs/usr/local/bin/nmtui" | awk '{print $1}')" == \
    "$(manifest_value nmtui_wrapper_sha256)" ]] || die "nmtui 包装器输入哈希不匹配"
wifi_ap_profile="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/NetworkManager/system-connections/zu02-wifi-ap.nmconnection)"
for profile_line in \
    'id=ZU02 Wi-Fi AP' \
    'interface-name=wlan0' \
    'autoconnect=false' \
    'mode=ap' \
    'cloned-mac-address=stable' \
    'ssid=ZU02-Debian' \
    'key-mgmt=wpa-psk' \
    'address1=192.168.69.1/24' \
    'method=shared' \
    'never-default=true'; do
    grep -Fqx "$profile_line" <<<"$wifi_ap_profile" \
        || die "Wi-Fi AP 预置连接缺少：$profile_line"
done
[[ "$(sha256sum "$PROJECT_ROOT/patches/rootfs/etc/NetworkManager/system-connections/zu02-wifi-ap.nmconnection" | awk '{print $1}')" == \
    "$(manifest_value wifi_ap_profile_sha256)" ]] || die "Wi-Fi AP 连接输入哈希不匹配"
if grep -Fqx './etc/NetworkManager/system-connections/zu02-usb-management.nmconnection' \
    "$tmp_dir/rootfs-files.txt"; then
    die "rootfs 不得保留可由 nmtui 停用的 USB 管理连接"
fi
usb_management_conf="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/NetworkManager/conf.d/10-ufi210-usb-management.conf)"
grep -Fqx 'unmanaged-devices=interface-name:usb0' <<<"$usb_management_conf" \
    || die "NetworkManager 未排除固定 USB 管理接口"
[[ "$(sha256sum "$USB_MANAGEMENT_CONF" | awk '{print $1}')" == \
    "$(manifest_value usb_management_conf_sha256)" ]] || die "USB 管理配置输入哈希不匹配"
wifi_mac_conf="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/NetworkManager/conf.d/20-ufi210-wifi-mac.conf)"
grep -Fqx 'match-device=interface-name:wlan0' <<<"$wifi_mac_conf" \
    || die "Wi-Fi 稳定 MAC 配置未限定 wlan0"
grep -Fqx 'wifi.cloned-mac-address=stable' <<<"$wifi_mac_conf" \
    || die "Wi-Fi 连接未统一使用稳定 MAC"
[[ "$(sha256sum "$WIFI_MAC_CONF" | awk '{print $1}')" == \
    "$(manifest_value wifi_mac_conf_sha256)" ]] || die "Wi-Fi MAC 配置输入哈希不匹配"
usb_network_service="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/zu02-usb-network.service)"
grep -q '^After=zu02-usb-gadget.service$' <<<"$usb_network_service" \
    || die "USB 网络服务没有排在 gadget 之后"
grep -q '^Before=ssh.service dnsmasq.service$' <<<"$usb_network_service" \
    || die "USB 网络服务没有排在管理服务之前"
usb_network_script="$(tar -xJOf "$ROOTFS_TARBALL" ./usr/sbin/zu02-usb-network)"
if grep -Eq 'nmcli|NetworkManager' <<<"$usb_network_script"; then
    die "USB 网络脚本不得把管理接口交给 NetworkManager"
fi
grep -q '^ip link set usb0 up$' <<<"$usb_network_script" \
    || die "USB 网络脚本没有启用 usb0"
grep -q '^ip addr replace 192.168.68.1/24 dev usb0$' <<<"$usb_network_script" \
    || die "USB 网络脚本缺少静态地址恢复路径"
nmtui_catalog_hash="$(tar -xJOf "$ROOTFS_TARBALL" ./usr/share/locale/zh_CN/LC_MESSAGES/NetworkManager.mo | sha256sum | awk '{print $1}')"
[[ "$nmtui_catalog_hash" == "$(manifest_value nmtui_catalog_sha256)" ]] \
    || die "NetworkManager 简体中文消息目录哈希不匹配"
locale_archive_hash="$(tar -xJOf "$ROOTFS_TARBALL" ./usr/lib/locale/locale-archive | sha256sum | awk '{print $1}')"
[[ "$locale_archive_hash" == "$(manifest_value locale_archive_sha256)" ]] \
    || die "zh_CN.UTF-8 locale archive 哈希不匹配"
unexpected_locale="$(grep '^\./usr/share/locale/.*[^/]$' "$tmp_dir/rootfs-files.txt" \
    | grep -Fvx './usr/share/locale/zh_CN/LC_MESSAGES/NetworkManager.mo' || true)"
[[ -z "$unexpected_locale" ]] || die "rootfs 含有 nmtui 之外的 locale 文件：$unexpected_locale"
firewall_rules="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/nftables.d/zu02-firewall.nft)"
grep -q '^table inet zu02_firewall {$' <<<"$firewall_rules" \
    || die "缺少独立 ZU02 nftables 表"
grep -q 'iifname "lo" accept' <<<"$firewall_rules" \
    || die "管理面防火墙未保留 loopback"
management_drop_line="$(grep -n 'iifname != "usb0" tcp dport { 22, 5555 } counter drop' <<<"$firewall_rules" | cut -d: -f1)"
wwan_established_line="$(grep -n 'iifname "wwan0" ct state established,related accept' <<<"$firewall_rules" | cut -d: -f1)"
[[ "$management_drop_line" =~ ^[0-9]+$ && "$wwan_established_line" =~ ^[0-9]+$ \
    && "$management_drop_line" -lt "$wwan_established_line" ]] \
    || die "SSH/TCP ADB 非 USB 丢弃规则缺失或顺序错误"
grep -q 'iifname "wwan0" ct state established,related accept' <<<"$firewall_rules" \
    || die "WWAN 入站防火墙未允许已建立连接回包"
grep -q 'iifname "wwan0" counter drop' <<<"$firewall_rules" \
    || die "WWAN 入站防火墙未丢弃新连接"
if grep -q 'flush ruleset' <<<"$firewall_rules"; then
    die "ZU02 防火墙不得清空 NetworkManager 动态 nftables 规则"
fi
firewall_service="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/zu02-firewall.service)"
grep -q '^Before=network-pre.target shutdown.target$' <<<"$firewall_service" \
    || die "ZU02 防火墙没有在网络启动前加载"
grep -q '^RefuseManualStop=yes$' <<<"$firewall_service" \
    || die "ZU02 防火墙允许被单独手动停止"
grep -q '^ExecStart=/usr/sbin/zu02-firewall start$' <<<"$firewall_service" \
    || die "ZU02 防火墙服务入口不匹配"
firewall_script="$(tar -xJOf "$ROOTFS_TARBALL" ./usr/sbin/zu02-firewall)"
grep -q '^        nft delete table inet zu02_firewall$' <<<"$firewall_script" \
    || die "ZU02 防火墙重载未限制为项目专用表"
if grep -q 'flush ruleset' <<<"$firewall_script"; then
    die "ZU02 防火墙脚本不得清空完整 nftables ruleset"
fi
ssh_dropin="$(tar -xJOf "$ROOTFS_TARBALL" ./etc/systemd/system/ssh.service.d/10-zu02.conf)"
grep -q '^BindsTo=zu02-firewall.service$' <<<"$ssh_dropin" \
    || die "SSH 没有绑定 fail-closed 防火墙服务"
grep -q '^Wants=zu02-usb-network.service$' <<<"$ssh_dropin" \
    || die "SSH 没有声明 USB 管理网络软依赖"
if grep -q '^Requires=zu02-usb-network.service$' <<<"$ssh_dropin"; then
    die "SSH 不得因 USB 管理网络短暂重启而被停止"
fi
grep -q '^ExecStartPre=$' <<<"$ssh_dropin" || die "SSH drop-in 未重置原有 ExecStartPre"
grep -Fq 'ExecStartPre=/usr/bin/find /etc/ssh -maxdepth 1 -type f -name ssh_host_*_key.* ! -name *.pub -delete' <<<"$ssh_dropin" \
    || die "SSH 未清理中断的主机密钥临时文件"
keygen_line="$(grep -n '^ExecStartPre=/usr/bin/ssh-keygen -A$' <<<"$ssh_dropin" | cut -d: -f1)"
sshd_test_line="$(grep -n '^ExecStartPre=/usr/sbin/sshd -t$' <<<"$ssh_dropin" | cut -d: -f1)"
[[ "$keygen_line" =~ ^[0-9]+$ && "$sshd_test_line" =~ ^[0-9]+$ && "$keygen_line" -lt "$sshd_test_line" ]] \
    || die "SSH host key 生成没有排在 sshd 配置检查之前"

for package_name in adbd busybox-static dmsetup dnsmasq hostapd iproute2 iw kmod libqmi-utils libqrtr-glib0 \
    modemmanager network-manager nftables openssh-server qrtr-tools rfkill rmtfs systemd systemd-sysv \
    systemd-timesyncd udev \
    usr-is-merged wireless-regdb wpasupplicant; do
    awk -F '\t' -v package_name="$package_name" \
        '$1 == package_name || $1 == package_name ":armhf" {found=1} END {exit !found}' "$PACKAGE_LIST" \
        || die "包清单缺少：$package_name"
done
for removed_package in usrmerge perl libperl5.36 perl-modules-5.36 locales libc-l10n; do
    if awk -F '\t' -v package_name="$removed_package" \
        '$1 == package_name || $1 == package_name ":armhf" {found=1} END {exit !found}' "$PACKAGE_LIST"; then
        die "包清单仍包含仅用于构建的包：$removed_package"
    fi
done

log "解析并核对 Android boot image"
python3 "$PROJECT_ROOT/scripts/analyze_bootimg.py" \
    --boot "$BOOT_IMAGE" \
    --out "$tmp_dir/boot-analysis" \
    --no-decompile >/dev/null
python3 - "$tmp_dir/boot-analysis/summary.json" "$TARGET_PARTITION" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    summary = json.load(stream)
header = summary["header"]
qcdt = summary["qcdt"]
dtbs = summary["dtb_blobs"]
target = sys.argv[2]
assert header["magic"] == "ANDROID!"
assert header["page_size"] == 2048
assert header["name"] == f"deb-{target}"
assert header["qcdt_size"] > 0
cmdline = header["cmdline"].split()
assert "reboot=warm" in cmdline
expected_root = "/dev/mapper/ufi210-root" if target == "large-rootfs" else f"PARTLABEL={target}"
assert f"root={expected_root}" in cmdline
assert "rootfstype=ext4" in cmdline
assert "rw" in cmdline
assert "rootwait" in cmdline
assert qcdt["magic"] == "QCDT"
assert qcdt["version"] == 3
assert qcdt["count"] == 30
assert len(qcdt["entries"]) == 30
assert all(entry["platform_id"] == 245 for entry in qcdt["entries"])
assert all(entry["blob_index"] == 0 for entry in qcdt["entries"])
assert len(dtbs) == 1
assert dtbs[0]["root_props"]["model"] == ["DW01 (ZU02_main_v1.1)"]
assert "zu02,dw01" in dtbs[0]["root_props"]["compatible"]
PY

cmp -s "$tmp_dir/boot-analysis/ramdisk.img" "$INITRAMFS" \
    || die "boot 内 initramfs 与正式 Debian initramfs 不匹配"
cmp -s "$tmp_dir/boot-analysis/qcdt.img" "$QCDT" \
    || die "boot 内 QCDT 与正式 QCDT 不匹配"

kernel_segment="$tmp_dir/boot-analysis/kernel"
vmlinuz_bytes="$(stat -c %s "$KERNEL_DIR/vmlinuz")"
(( $(stat -c %s "$kernel_segment") == vmlinuz_bytes )) \
    || die "boot kernel 段长度不等于 vmlinuz"
[[ "$(sha256sum "$kernel_segment" | awk '{print $1}')" == "$(manifest_value kernel_sha256)" ]] \
    || die "boot 内 vmlinuz 不匹配"
[[ "$(manifest_value qcdt_version)" == "3" ]] || die "QCDT 版本不是 3"
[[ "$(manifest_value qcdt_record_count)" == "30" ]] || die "QCDT 记录数不是 30"
[[ "$(manifest_value qcdt_unique_dtb_count)" == "1" ]] || die "QCDT 不是唯一 DTB"
[[ "$(sha256sum "$tmp_dir/boot-analysis/dtb/dtb_00_dw01-zu02-main-v1-1.dtb" | awk '{print $1}')" \
    == "$(manifest_value dtb_sha256)" ]] || die "QCDT 内 DW01 DTB 不匹配"

log "Debian ${TARGET_PARTITION} 静态验收全部通过"
printf 'rootfs=%s\n' "$IMAGE"
printf 'rootfs_sha256=%s\n' "$(manifest_value rootfs_image_sha256)"
if [[ "$TARGET_PARTITION" == system ]]; then
    printf 'data=%s\n' "$DATA_IMAGE"
    printf 'data_sha256=%s\n' "$(manifest_value data_image_sha256)"
fi
printf 'boot=%s\n' "$BOOT_IMAGE"
printf 'boot_sha256=%s\n' "$(manifest_value boot_image_sha256)"
