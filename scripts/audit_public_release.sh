#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C.UTF-8

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-workspace}"
TARGET="${2:-$PROJECT_ROOT}"

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

require_command find
require_command grep
require_command sha256sum

[[ -d "$TARGET" ]] || die "目录不存在：$TARGET"
TARGET="$(cd "$TARGET" && pwd)"

audit_private_content() {
    local forbidden

    if grep -RIlEq --exclude='audit_public_release.sh' \
        '([A-Za-z]:\\(IDE|Users)\\|\\\\[^\\]+\\docker\\)' "$TARGET"; then
        die "发布树包含本地开发环境路径"
    fi
    if [[ -n "${UFI210_RELEASE_DENYLIST:-}" ]]; then
        [[ -f "$UFI210_RELEASE_DENYLIST" ]] \
            || die "私有发布禁用词清单不存在：$UFI210_RELEASE_DENYLIST"
        while IFS= read -r forbidden || [[ -n "$forbidden" ]]; do
            [[ -z "$forbidden" || "$forbidden" == \#* ]] && continue
            if grep -RIlF --exclude='audit_public_release.sh' -- "$forbidden" "$TARGET" \
                >/dev/null; then
                die "发布树包含私有禁用词清单中的内容"
            fi
        done < "$UFI210_RELEASE_DENYLIST"
    fi
}

for pattern in \
    '/resource/backup/' '/out/' '/.build/' '/AndroidBak/' \
    '/adb.exe' '/fastboot.exe' '/AdbWinApi.dll' '/AdbWinUsbApi.dll' \
    '*.bin' '*.img' '*.fat' '*.ext4' '*.raw'; do
    grep -Fqx "$pattern" "$PROJECT_ROOT/.gitignore" \
        || die ".gitignore 缺少保护规则：$pattern"
done

audit_source_tree() {
    local path rel
    local count=0

    log "审计公开源码树：$TARGET"
    while IFS= read -r -d '' path; do
        rel="${path#"$TARGET"/}"
        case "$rel" in
            .dockerignore|.gitattributes|.gitignore|Dockerfile|LICENSE|README.md|SECURITY.md|TODO.md|build.sh|install.bat|enter-fastboot.bat|resource/README.md) ;;
            docker/kernel/Dockerfile) ;;
            .github/workflows/*.yml) ;;
            configs/*.config) ;;
            docs/*.md) ;;
            LICENSES/*.txt) ;;
            patches/linux/*.patch) ;;
            patches/initramfs/*.sh) ;;
            patches/rootfs/usr/sbin/*) ;;
            patches/rootfs/usr/local/bin/*) ;;
            patches/rootfs/etc/NetworkManager/conf.d/*.conf) ;;
            patches/rootfs/etc/NetworkManager/system-connections/*.nmconnection) ;;
            src/*.c) ;;
            scripts/*.sh|scripts/*.py|scripts/*.ps1) ;;
            *) die "公开源码树出现白名单外文件：$rel" ;;
        esac
        case "$rel" in
            resource/backup/*|out/*|.build/*|AndroidBak/*)
                die "公开源码树包含私有目录：$rel"
                ;;
        esac
        case "${rel,,}" in
            *.bin|*.img|*.fat|*.ext4|*.raw|*.simg|*.sparse|*.zip|*.tar|*.tar.*|*.dll|*.exe)
                die "公开源码树包含二进制或镜像：$rel"
                ;;
        esac
        if grep -Iq . "$path"; then
            :
        else
            die "公开源码树包含非文本文件：$rel"
        fi
        count=$((count + 1))
    done < <(find "$TARGET" -type f -print0)

    (( count > 0 )) || die "公开源码树为空"
    if [[ -n "$(find "$TARGET" -type l -print -quit)" ]]; then
        die "公开源码树不允许包含符号链接"
    fi
    audit_private_content
    log "公开源码树审计通过，共 $count 个文本文件"
}

audit_binary_tree() {
    local path rel manifest rootfs_hash rootfs_system_hash rootfs_cache_hash rootfs_userdata_hash boot_hash
    local count=0

    log "审计面向用户的候选固件树：$TARGET"
    while IFS= read -r -d '' path; do
        rel="${path#"$TARGET"/}"
        case "$rel" in
            LICENSE|LICENSING.md|README.md|RELEASE-NOTES.md|INSTALL-MANIFEST.txt|SHA256SUMS|install.bat|enter-fastboot.bat) ;;
            debian-bookworm-armhf-large-rootfs-system.img|debian-bookworm-armhf-large-rootfs-cache.img|debian-bookworm-armhf-large-rootfs-userdata.img|boot-debian-large-rootfs.img) ;;
            LICENSES/MIT.txt|LICENSES/GPL-2.0-only.txt) ;;
            scripts/install_debian_large_rootfs.ps1|scripts/enter_fastboot.ps1) ;;
            *) die "用户固件包出现白名单外文件：$rel" ;;
        esac
        case "${rel,,}" in
            *modemst*|*persist.img|*fsg.img|*modem.fat|*boot-stock*|*cache-stock*|*rawprogram*|*patch*.xml)
                die "用户固件包包含私有分区或 9008 写入文件：$rel"
                ;;
        esac
        count=$((count + 1))
    done < <(find "$TARGET" -type f -print0)

    (( count > 0 )) || die "用户固件包为空"
    for required in \
        README.md RELEASE-NOTES.md INSTALL-MANIFEST.txt SHA256SUMS \
        LICENSE LICENSING.md LICENSES/MIT.txt LICENSES/GPL-2.0-only.txt \
        install.bat enter-fastboot.bat scripts/install_debian_large_rootfs.ps1 scripts/enter_fastboot.ps1 \
        debian-bookworm-armhf-large-rootfs-system.img \
        debian-bookworm-armhf-large-rootfs-cache.img \
        debian-bookworm-armhf-large-rootfs-userdata.img boot-debian-large-rootfs.img; do
        [[ -s "$TARGET/$required" ]] || die "用户固件包缺少：$required"
    done

    manifest="$TARGET/INSTALL-MANIFEST.txt"
    for field in \
        'release_channel=candidate' \
        'release_status=persistent-device-validation' \
        'project_name=Debian for UFI210(msm8909)' \
        'platform=msm8909' \
        'hardware_target=zu02-dw01' \
        'hostname=ufi210' \
        'architecture=armhf' \
        'debian_suite=bookworm' \
        'target_partition=large-rootfs' \
        'target_partition_bytes=3485240832' \
        'persistent_partitions=boot,system,cache,userdata' \
        'android_system_partition=overwritten' \
        'android_cache_partition=overwritten' \
        'android_userdata_partition=erased' \
        'rootfs_auto_grow=disabled' \
        'rootfs_device=/dev/mapper/ufi210-root' \
        'rootfs_label=ufi210-root' \
        'rootfs_uuid=89090000-0000-4000-8000-000000000031' \
        'rootfs_image_bytes=3485237248' \
        'rootfs_segments=complete-prebuilt-filesystem' \
        'storage_layout=dm-linear-system-cache-userdata' \
        'dm_name=ufi210-root' \
        'dm_total_sectors=6807111' \
        'dm_total_bytes=3485240832' \
        'dm_filesystem_bytes=3485237248' \
        'dm_system_sectors=2516584' \
        'dm_cache_sectors=524288' \
        'dm_userdata_sectors=3766239' \
        'dm_system_start=461920' \
        'dm_cache_start=3044040' \
        'dm_userdata_start=3803136' \
        'dm_table=0 2516584 linear PARTLABEL=system 0;2516584 524288 linear PARTLABEL=cache 0;3040872 3766239 linear PARTLABEL=userdata 0' \
        'gpt_changes=none' \
        'cache_previous_contents=erased-by-installer' \
        'userdata_previous_contents=erased-by-installer' \
        'fstrim=weekly-systemd-timer' \
        'time_sync=qmi-dms-forward-only+systemd-timesyncd' \
        'boot_mode=stock-aboot-direct-qcdt' \
        'bootloader_changes=none' \
        'reboot_mode=warm' \
        'device_ip=192.168.68.1' \
        'root_password=simadmin' \
        'adbd=tcp-5555' \
        'fastboot_reboot_command=adb-shell-system-bin-reboot-bootloader' \
        'adb_tcp_endpoint=192.168.68.1:5555' \
        'usb_functions=rndis-acm' \
        'usb_product_id=0xD001' \
        'usb_watchdog=systemd-timer' \
        'usb_watchdog_interval_seconds=5' \
        'usb_watchdog_unhealthy_seconds=5' \
        'rndis_mac=device-derived-stable-local-unicast' \
        'usb_management=static-service-networkmanager-unmanaged' \
        'wifi_ap_profile=preinstalled-disabled' \
        'wifi_ap_password=simadmin' \
        'wifi_interface_concurrency=managed-or-ap-exclusive' \
        'network_topology=isolated-usb-wifi-no-bridge' \
        'management_ingress=usb-only-rndis-ssh-tcp-adb-acm' \
        'wwan_ingress=drop-new-and-untracked' \
        'lte_apn=not-preconfigured' \
        'qcdt_version=3' \
        'qcdt_record_count=30' \
        'qcdt_unique_dtb_count=1' \
        'closed_firmware=device-modem-persist-read-only' \
        'device_calibration=not-packaged' \
        'platform_tools=required-not-bundled' \
        'rootfs_system_image=debian-bookworm-armhf-large-rootfs-system.img' \
        'rootfs_system_image_bytes=1288491008' \
        'rootfs_cache_image=debian-bookworm-armhf-large-rootfs-cache.img' \
        'rootfs_cache_image_bytes=268435456' \
        'rootfs_userdata_image=debian-bookworm-armhf-large-rootfs-userdata.img' \
        'rootfs_userdata_image_bytes=1928310784' \
        'boot_image=boot-debian-large-rootfs.img'; do
        grep -Fqx "$field" "$manifest" || die "安装清单缺少或不匹配：$field"
    done

    rootfs_system_hash="$(sed -n 's/^rootfs_system_image_sha256=//p' "$manifest")"
    rootfs_cache_hash="$(sed -n 's/^rootfs_cache_image_sha256=//p' "$manifest")"
    rootfs_userdata_hash="$(sed -n 's/^rootfs_userdata_image_sha256=//p' "$manifest")"
    boot_hash="$(sed -n 's/^boot_image_sha256=//p' "$manifest")"
    rootfs_hash="$(sed -n 's/^rootfs_image_sha256=//p' "$manifest")"
    [[ "$rootfs_hash" =~ ^[0-9a-f]{64}$ \
        && "$rootfs_system_hash" =~ ^[0-9a-f]{64}$ \
        && "$rootfs_cache_hash" =~ ^[0-9a-f]{64}$ \
        && "$rootfs_userdata_hash" =~ ^[0-9a-f]{64}$ \
        && "$boot_hash" =~ ^[0-9a-f]{64}$ ]] \
        || die "安装清单镜像哈希格式错误"
    [[ "$rootfs_system_hash" == "$(sha256sum "$TARGET/debian-bookworm-armhf-large-rootfs-system.img" | awk '{print $1}')" ]] \
        || die "安装清单 rootfs system 分段哈希不匹配"
    [[ "$rootfs_cache_hash" == "$(sha256sum "$TARGET/debian-bookworm-armhf-large-rootfs-cache.img" | awk '{print $1}')" ]] \
        || die "安装清单 rootfs cache 分段哈希不匹配"
    [[ "$rootfs_userdata_hash" == "$(sha256sum "$TARGET/debian-bookworm-armhf-large-rootfs-userdata.img" | awk '{print $1}')" ]] \
        || die "安装清单 rootfs userdata 分段哈希不匹配"
    [[ "$rootfs_hash" == "$(cat \
        "$TARGET/debian-bookworm-armhf-large-rootfs-system.img" \
        "$TARGET/debian-bookworm-armhf-large-rootfs-cache.img" \
        "$TARGET/debian-bookworm-armhf-large-rootfs-userdata.img" \
        | sha256sum | awk '{print $1}')" ]] \
        || die "安装清单完整逻辑 rootfs 哈希不匹配"
    [[ "$boot_hash" == "$(sha256sum "$TARGET/boot-debian-large-rootfs.img" | awk '{print $1}')" ]] \
        || die "安装清单 boot 哈希不匹配"

    if grep -RIE 'repository=|wcnss_nv_sha256=|kernel_commit=|source_date_epoch=' "$TARGET"; then
        die "用户固件包包含开发仓库、设备校准哈希或内部构建字段"
    fi
    (
        cd "$TARGET"
        sha256sum -c SHA256SUMS
    ) >/dev/null
    audit_private_content
    log "用户固件包审计通过，共 $count 个必要文件"
}

audit_workspace() {
    local tracked

    log "审计工作区忽略规则"
    if [[ -d "$PROJECT_ROOT/.git" ]]; then
        tracked="$(mktemp)"
        trap 'rm -f "$tracked"' RETURN
        git -C "$PROJECT_ROOT" ls-files > "$tracked"
        if grep -E '^(resource/backup|out|\.build|AndroidBak)/|(^|/)(adb|fastboot)\.exe$|\.(bin|img|fat|ext4|raw|simg|sparse|dll)$' "$tracked"; then
            die "Git 已跟踪私有输入、构建产物或本地工具"
        fi
        log "Git 跟踪文件审计通过"
    else
        log "当前尚未初始化 Git；已验证 .gitignore 保护规则"
    fi
}

case "$MODE" in
    workspace) audit_workspace ;;
    source) audit_source_tree ;;
    binary) audit_binary_tree ;;
    *) die "用法：$0 workspace|source|binary [目录]" ;;
esac
