#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C.UTF-8

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
PROJECT_SOURCE_DATE_EPOCH=1781860238
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$PROJECT_SOURCE_DATE_EPOCH}"
OUT_ROOT="${OUT_ROOT:-$PROJECT_ROOT/out/release-candidate}"
DEBIAN_OUT="$PROJECT_ROOT/out/mainline/debian-large-rootfs"
AUDIT_SCRIPT="$PROJECT_ROOT/scripts/audit_public_release.sh"
PRIVACY_AUDITOR="$PROJECT_ROOT/scripts/audit_rootfs_privacy.py"
VERIFY_SCRIPT="$PROJECT_ROOT/scripts/verify_debian_large_rootfs.sh"
ZIPPER="$PROJECT_ROOT/scripts/create_deterministic_zip.py"

log() {
    printf '[%(%H:%M:%S)T] %s\n' -1 "$*"
}

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

for command_name in awk cp find grep install python3 realpath sed sha256sum sort tar xargs xz; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
done
[[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] \
    || die "请提供只包含字母、数字、点、下划线和连字符的候选版本号"
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || die "SOURCE_DATE_EPOCH 必须是非负整数"
[[ "$SOURCE_DATE_EPOCH" == "$PROJECT_SOURCE_DATE_EPOCH" ]] \
    || die "候选发布 SOURCE_DATE_EPOCH 必须为 $PROJECT_SOURCE_DATE_EPOCH"

OUT_ROOT="$(realpath -m "$OUT_ROOT")"
case "$OUT_ROOT" in
    "$PROJECT_ROOT/out"|"$PROJECT_ROOT/out/"*) ;;
    *) die "OUT_ROOT 必须位于工程 out 目录内：$OUT_ROOT" ;;
esac

for required in \
    "$AUDIT_SCRIPT" "$PRIVACY_AUDITOR" "$VERIFY_SCRIPT" "$ZIPPER" "$PROJECT_ROOT/install.bat" \
    "$PROJECT_ROOT/enter-fastboot.bat" "$PROJECT_ROOT/scripts/enter_fastboot.ps1" \
    "$PROJECT_ROOT/LICENSE" "$PROJECT_ROOT/docs/release-install.md" \
    "$PROJECT_ROOT/docs/release-notes.md" "$PROJECT_ROOT/docs/licensing.md" \
    "$PROJECT_ROOT/LICENSES/MIT.txt" "$PROJECT_ROOT/LICENSES/GPL-2.0-only.txt" \
    "$DEBIAN_OUT/debian-bookworm-armhf-large-rootfs-system.img" \
    "$DEBIAN_OUT/debian-bookworm-armhf-large-rootfs-cache.img" \
    "$DEBIAN_OUT/debian-bookworm-armhf-large-rootfs-userdata.img" \
    "$DEBIAN_OUT/boot-debian-large-rootfs.img" \
    "$DEBIAN_OUT/BUILD-MANIFEST.txt" "$DEBIAN_OUT/REPRODUCIBILITY.txt"; do
    [[ -s "$required" ]] || die "缺少发布输入：$required"
done

log "运行 Debian large-rootfs 静态验收"
bash "$VERIFY_SCRIPT"
python3 "$PRIVACY_AUDITOR" "$DEBIAN_OUT/debian-bookworm-armhf-large-rootfs-rootfs.tar.xz"
bash "$AUDIT_SCRIPT" workspace

release_dir="$OUT_ROOT/$VERSION"
[[ "$release_dir" == "$OUT_ROOT/"* ]] || die "候选发布目录越界：$release_dir"
stage_dir="$release_dir/.stage"
source_name="ufi210-debian-source-$VERSION"
binary_name="ufi210-debian-zu02-dw01-$VERSION"
source_stage="$stage_dir/$source_name"
binary_stage="$stage_dir/$binary_name"

rm -rf -- "$release_dir"
mkdir -p "$source_stage" "$binary_stage/scripts" "$binary_stage/LICENSES"

log "按白名单收集公开源码"
for file in .dockerignore .gitattributes .gitignore Dockerfile LICENSE README.md SECURITY.md TODO.md build.sh install.bat enter-fastboot.bat resource/README.md; do
    install -D -m 0644 "$PROJECT_ROOT/$file" "$source_stage/$file"
done
while IFS= read -r -d '' file; do
    rel="${file#"$PROJECT_ROOT"/}"
    case "$rel" in
        scripts/*.sh|scripts/*.py|scripts/*.ps1)
            install -D -m 0755 "$file" "$source_stage/$rel"
            ;;
        *) install -D -m 0644 "$file" "$source_stage/$rel" ;;
    esac
done < <(find \
    "$PROJECT_ROOT/.github" "$PROJECT_ROOT/configs" "$PROJECT_ROOT/docker" \
    "$PROJECT_ROOT/docs" "$PROJECT_ROOT/LICENSES" "$PROJECT_ROOT/patches" \
    "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/src" \
    -type d -name '__pycache__' -prune -o -type f -print0 | sort -z)
bash "$AUDIT_SCRIPT" source "$source_stage"

log "收集持久 Debian 候选固件"
install -m 0644 "$PROJECT_ROOT/docs/release-install.md" "$binary_stage/README.md"
install -m 0644 "$PROJECT_ROOT/docs/release-notes.md" "$binary_stage/RELEASE-NOTES.md"
install -m 0644 "$PROJECT_ROOT/LICENSE" "$binary_stage/LICENSE"
install -m 0644 "$PROJECT_ROOT/docs/licensing.md" "$binary_stage/LICENSING.md"
install -m 0644 "$PROJECT_ROOT/LICENSES/MIT.txt" "$binary_stage/LICENSES/MIT.txt"
install -m 0644 "$PROJECT_ROOT/LICENSES/GPL-2.0-only.txt" "$binary_stage/LICENSES/GPL-2.0-only.txt"
install -m 0644 "$PROJECT_ROOT/install.bat" "$binary_stage/install.bat"
install -m 0644 "$PROJECT_ROOT/enter-fastboot.bat" "$binary_stage/enter-fastboot.bat"
install -m 0644 "$DEBIAN_OUT/debian-bookworm-armhf-large-rootfs-system.img" "$binary_stage/"
install -m 0644 "$DEBIAN_OUT/debian-bookworm-armhf-large-rootfs-cache.img" "$binary_stage/"
install -m 0644 "$DEBIAN_OUT/debian-bookworm-armhf-large-rootfs-userdata.img" "$binary_stage/"
install -m 0644 "$DEBIAN_OUT/boot-debian-large-rootfs.img" "$binary_stage/"
install -m 0644 "$PROJECT_ROOT/scripts/install_debian_large_rootfs.ps1" "$binary_stage/scripts/"
install -m 0644 "$PROJECT_ROOT/scripts/enter_fastboot.ps1" "$binary_stage/scripts/"

rootfs_system_hash="$(sha256sum "$binary_stage/debian-bookworm-armhf-large-rootfs-system.img" | awk '{print $1}')"
rootfs_cache_hash="$(sha256sum "$binary_stage/debian-bookworm-armhf-large-rootfs-cache.img" | awk '{print $1}')"
rootfs_userdata_hash="$(sha256sum "$binary_stage/debian-bookworm-armhf-large-rootfs-userdata.img" | awk '{print $1}')"
boot_hash="$(sha256sum "$binary_stage/boot-debian-large-rootfs.img" | awk '{print $1}')"
manifest_value() {
    sed -n "s/^$1=//p" "$DEBIAN_OUT/BUILD-MANIFEST.txt"
}
[[ "$(manifest_value rootfs_system_image_sha256)" == "$rootfs_system_hash" ]] \
    || die "rootfs system 分段哈希与构建清单不一致"
[[ "$(manifest_value rootfs_cache_image_sha256)" == "$rootfs_cache_hash" ]] \
    || die "rootfs cache 分段哈希与构建清单不一致"
[[ "$(manifest_value rootfs_userdata_image_sha256)" == "$rootfs_userdata_hash" ]] \
    || die "rootfs userdata 分段哈希与构建清单不一致"
[[ "$(manifest_value rootfs_image_sha256)" == "$(cat \
    "$binary_stage/debian-bookworm-armhf-large-rootfs-system.img" \
    "$binary_stage/debian-bookworm-armhf-large-rootfs-cache.img" \
    "$binary_stage/debian-bookworm-armhf-large-rootfs-userdata.img" \
    | sha256sum | awk '{print $1}')" ]] \
    || die "完整逻辑 rootfs 哈希与三个分段不一致"
[[ "$(manifest_value boot_image_sha256)" == "$boot_hash" ]] \
    || die "boot 哈希与构建清单不一致"
for reproducibility_field in \
    'result=passed' \
    'comparison=byte-for-byte' \
    'target_partition=large-rootfs'; do
    grep -Fqx "$reproducibility_field" "$DEBIAN_OUT/REPRODUCIBILITY.txt" \
        || die "双构建报告缺少：$reproducibility_field"
done
grep -Fqx "$rootfs_system_hash  debian-bookworm-armhf-large-rootfs-system.img" \
    "$DEBIAN_OUT/REPRODUCIBILITY.txt" \
    || die "当前 rootfs system 分段不属于已通过双构建比较的产物"
grep -Fqx "$rootfs_cache_hash  debian-bookworm-armhf-large-rootfs-cache.img" \
    "$DEBIAN_OUT/REPRODUCIBILITY.txt" \
    || die "当前 rootfs cache 分段不属于已通过双构建比较的产物"
grep -Fqx "$rootfs_userdata_hash  debian-bookworm-armhf-large-rootfs-userdata.img" \
    "$DEBIAN_OUT/REPRODUCIBILITY.txt" \
    || die "当前 rootfs userdata 分段不属于已通过双构建比较的产物"
grep -Fqx "$boot_hash  boot-debian-large-rootfs.img" \
    "$DEBIAN_OUT/REPRODUCIBILITY.txt" \
    || die "当前 boot 不属于已通过双构建比较的产物"

cat > "$binary_stage/INSTALL-MANIFEST.txt" <<EOF
release_version=$VERSION
release_channel=candidate
release_status=persistent-device-validation
project_name=Debian for UFI210(msm8909)
platform=msm8909
hardware_target=zu02-dw01
device=ZU02_main_v1.1-DW01
soc=MSM8909
persistent_partitions=boot,system,cache,userdata
android_system_partition=overwritten
android_cache_partition=overwritten
android_userdata_partition=erased
boot_mode=stock-aboot-direct-qcdt
bootloader_changes=none
closed_firmware=device-modem-persist-read-only
device_calibration=not-packaged
platform_tools=required-not-bundled
architecture=$(manifest_value architecture)
debian_suite=$(manifest_value debian_suite)
kernel_release=$(manifest_value kernel_release)
hostname=$(manifest_value hostname)
target_partition=$(manifest_value target_partition)
target_partition_bytes=$(manifest_value target_partition_bytes)
rootfs_auto_grow=$(manifest_value rootfs_auto_grow)
rootfs_device=$(manifest_value rootfs_device)
rootfs_label=$(manifest_value rootfs_label)
rootfs_uuid=$(manifest_value rootfs_uuid)
rootfs_image_bytes=$(manifest_value rootfs_image_bytes)
rootfs_image_sha256=$(manifest_value rootfs_image_sha256)
rootfs_segments=$(manifest_value rootfs_segments)
data_mount=$(manifest_value data_mount)
adbd_shell_tmpdir=$(manifest_value adbd_shell_tmpdir)
adbd_shell_tmpdir_storage=$(manifest_value adbd_shell_tmpdir_storage)
storage_layout=$(manifest_value storage_layout)
dm_name=$(manifest_value dm_name)
dm_total_sectors=$(manifest_value dm_total_sectors)
dm_total_bytes=$(manifest_value dm_total_bytes)
dm_filesystem_bytes=$(manifest_value dm_filesystem_bytes)
dm_system_sectors=$(manifest_value dm_system_sectors)
dm_cache_sectors=$(manifest_value dm_cache_sectors)
dm_userdata_sectors=$(manifest_value dm_userdata_sectors)
dm_system_start=$(manifest_value dm_system_start)
dm_cache_start=$(manifest_value dm_cache_start)
dm_userdata_start=$(manifest_value dm_userdata_start)
dm_table=$(manifest_value dm_table)
gpt_changes=$(manifest_value gpt_changes)
cache_previous_contents=$(manifest_value cache_previous_contents)
userdata_previous_contents=$(manifest_value userdata_previous_contents)
fstrim=$(manifest_value fstrim)
time_sync=$(manifest_value time_sync)
reboot_mode=$(manifest_value reboot_mode)
device_ip=$(manifest_value device_ip)
root_password=$(manifest_value root_password)
adbd=$(manifest_value adbd)
usb_adb=$(manifest_value usb_adb)
usb_adb_experiment_modes=$(manifest_value usb_adb_experiment_modes)
usb_adb_functionfs_mount=$(manifest_value usb_adb_functionfs_mount)
usb_adb_experiment_product_id=$(manifest_value usb_adb_experiment_product_id)
fastboot_reboot_command=$(manifest_value fastboot_reboot_command)
adb_tcp_endpoint=$(manifest_value adb_tcp_endpoint)
usb_functions=$(manifest_value usb_functions)
usb_product_id=$(manifest_value usb_product_id)
usb_watchdog=$(manifest_value usb_watchdog)
usb_watchdog_interval_seconds=$(manifest_value usb_watchdog_interval_seconds)
usb_watchdog_unhealthy_seconds=$(manifest_value usb_watchdog_unhealthy_seconds)
rndis_mac=$(manifest_value rndis_mac)
usb_management=$(manifest_value usb_management)
wifi_ap_profile=$(manifest_value wifi_ap_profile)
wifi_ap_ssid=$(manifest_value wifi_ap_ssid)
wifi_ap_ipv4=$(manifest_value wifi_ap_ipv4)
wifi_ap_password=simadmin
wifi_interface_concurrency=$(manifest_value wifi_interface_concurrency)
network_topology=$(manifest_value network_topology)
system_locale=$(manifest_value system_locale)
nmtui_locale=$(manifest_value nmtui_locale)
thermal_cpu_passive_trip_millic=$(manifest_value thermal_cpu_passive_trip_millic)
routing_firewall=$(manifest_value routing_firewall)
management_ingress=$(manifest_value management_ingress)
wwan_ingress=$(manifest_value wwan_ingress)
lte_apn=$(manifest_value lte_apn)
qcdt_version=$(manifest_value qcdt_version)
qcdt_record_count=$(manifest_value qcdt_record_count)
qcdt_unique_dtb_count=$(manifest_value qcdt_unique_dtb_count)
rootfs_system_image=debian-bookworm-armhf-large-rootfs-system.img
rootfs_system_image_bytes=$(manifest_value rootfs_system_image_bytes)
rootfs_system_image_sha256=$rootfs_system_hash
rootfs_cache_image=debian-bookworm-armhf-large-rootfs-cache.img
rootfs_cache_image_bytes=$(manifest_value rootfs_cache_image_bytes)
rootfs_cache_image_sha256=$rootfs_cache_hash
rootfs_userdata_image=debian-bookworm-armhf-large-rootfs-userdata.img
rootfs_userdata_image_bytes=$(manifest_value rootfs_userdata_image_bytes)
rootfs_userdata_image_sha256=$rootfs_userdata_hash
boot_image=boot-debian-large-rootfs.img
boot_image_sha256=$boot_hash
EOF

(
    cd "$binary_stage"
    find . -type f ! -name SHA256SUMS -print0 \
        | sort -z \
        | xargs -0 sha256sum \
        > SHA256SUMS
)
bash "$AUDIT_SCRIPT" binary "$binary_stage"

mkdir -p "$release_dir"
create_archive() {
    local parent="$1"
    local name="$2"
    local output="$3"
    tar --sort=name --format=posix \
        --pax-option=delete=atime,delete=ctime \
        --owner=0 --group=0 --numeric-owner \
        --mtime="@$SOURCE_DATE_EPOCH" \
        -C "$parent" -cf - "$name" \
        | xz -T1 -3 > "$output"
}

log "生成确定性源码和候选固件归档"
create_archive "$stage_dir" "$source_name" "$release_dir/$source_name.tar.xz"
python3 "$ZIPPER" "$binary_stage" "$release_dir/$binary_name.zip" \
    --source-date-epoch "$SOURCE_DATE_EPOCH"
(
    cd "$release_dir"
    sha256sum "$source_name.tar.xz" "$binary_name.zip" > SHA256SUMS
)
rm -rf -- "$stage_dir"

log "候选发布包完成：$release_dir"
cat "$release_dir/SHA256SUMS"
printf '注意：首个候选不声明短信、IPv6、SIM 热插拔、多客户端或长期蜂窝持续流量耐久性。\n'
