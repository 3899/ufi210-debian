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
    if grep -RIlEq --exclude='audit_public_release.sh' \
        '([A-Za-z]:\\(IDE|Users)\\|\\\\[^\\]+\\docker\\)' "$TARGET"; then
        die "发布树包含本地开发环境路径"
    fi
    if grep -RIlEi --exclude='audit_public_release.sh' \
        'jjss520|semifinished|competitor|openstick|postmarketos|miko|全自研|竞品|套壳|SimAdmin 项目' \
        "$TARGET"; then
        die "发布树包含禁止出现在正式材料中的历史名称或表述"
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
    local path rel manifest rootfs_hash data_hash boot_hash
    local count=0

    log "审计面向用户的候选固件树：$TARGET"
    while IFS= read -r -d '' path; do
        rel="${path#"$TARGET"/}"
        case "$rel" in
            LICENSE|LICENSING.md|README.md|RELEASE-NOTES.md|INSTALL-MANIFEST.txt|SHA256SUMS|debian-bookworm-armhf-system.ext4|debian-bookworm-armhf-data.ext4|boot-debian-system.img|install.bat|enter-fastboot.bat) ;;
            LICENSES/MIT.txt|LICENSES/GPL-2.0-only.txt) ;;
            scripts/install_debian_system.ps1|scripts/enter_fastboot.ps1) ;;
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
        install.bat enter-fastboot.bat scripts/install_debian_system.ps1 scripts/enter_fastboot.ps1 \
        debian-bookworm-armhf-system.ext4 debian-bookworm-armhf-data.ext4 boot-debian-system.img; do
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
        'target_partition=system' \
        'target_partition_bytes=1288491008' \
        'persistent_partitions=boot,system,userdata' \
        'android_system_partition=overwritten' \
        'android_userdata_partition=erased' \
        'rootfs_auto_grow=enabled' \
        'data_partition=userdata' \
        'data_partition_bytes=1928314368' \
        'data_filesystem_bytes=1928310784' \
        'data_uuid=89090000-0000-4000-8000-000000000029' \
        'data_label=ufi210-data' \
        'data_mount=/data' \
        'data_mount_options=defaults,noatime,nosuid,nodev,nofail,x-systemd.growfs,x-systemd.device-timeout=30s' \
        'data_auto_grow=enabled' \
        'data_initial_directories=apps,backups,srv' \
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
        'rootfs_image=debian-bookworm-armhf-system.ext4' \
        'data_image=debian-bookworm-armhf-data.ext4' \
        'boot_image=boot-debian-system.img'; do
        grep -Fqx "$field" "$manifest" || die "安装清单缺少或不匹配：$field"
    done

    rootfs_hash="$(sed -n 's/^rootfs_image_sha256=//p' "$manifest")"
    data_hash="$(sed -n 's/^data_image_sha256=//p' "$manifest")"
    boot_hash="$(sed -n 's/^boot_image_sha256=//p' "$manifest")"
    [[ "$rootfs_hash" =~ ^[0-9a-f]{64}$ && "$data_hash" =~ ^[0-9a-f]{64}$ \
        && "$boot_hash" =~ ^[0-9a-f]{64}$ ]] \
        || die "安装清单镜像哈希格式错误"
    [[ "$rootfs_hash" == "$(sha256sum "$TARGET/debian-bookworm-armhf-system.ext4" | awk '{print $1}')" ]] \
        || die "安装清单 rootfs 哈希不匹配"
    [[ "$data_hash" == "$(sha256sum "$TARGET/debian-bookworm-armhf-data.ext4" | awk '{print $1}')" ]] \
        || die "安装清单 data 哈希不匹配"
    [[ "$boot_hash" == "$(sha256sum "$TARGET/boot-debian-system.img" | awk '{print $1}')" ]] \
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
