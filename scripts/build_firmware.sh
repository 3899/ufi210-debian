#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C.UTF-8

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$script_root/scripts/build_mainline_kernel.sh" ]]; then
    PROJECT_ROOT="${PROJECT_ROOT:-$script_root}"
else
    PROJECT_ROOT="${PROJECT_ROOT:-${CONTAINER_WORKDIR:-/work}}"
fi
BUILD_ROOT="${BUILD_ROOT:-/build}"
BUILD_TMPFS_SIZE="${BUILD_TMPFS_SIZE:-6G}"
SOURCE_ROOT="${SOURCE_ROOT:-$PROJECT_ROOT/.build/msm8909-kernel-source}"
RELEASE_VERSION="${RELEASE_VERSION:-}"
FORCE="${FORCE:-0}"
PROJECT_SOURCE_DATE_EPOCH=1781860238
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$PROJECT_SOURCE_DATE_EPOCH}"
DEBIAN_KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
DEBIAN_KEYRING_SHA256="506b815cbb32d9b6066b4a2aa524071e071761e7e7f68c3ac74f3061ba852017"

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

(( EUID == 0 )) || die "完整固件构建必须以 root 运行"
[[ "$SOURCE_DATE_EPOCH" == "$PROJECT_SOURCE_DATE_EPOCH" ]] \
    || die "正式构建 SOURCE_DATE_EPOCH 必须为 $PROJECT_SOURCE_DATE_EPOCH"
export SOURCE_DATE_EPOCH
[[ -d "$PROJECT_ROOT/scripts" ]] || die "工程目录无效：$PROJECT_ROOT"
case "$(realpath -m "$BUILD_ROOT")" in
    /build|/build/*) ;;
    *) die "BUILD_ROOT 必须位于 /build：$BUILD_ROOT" ;;
esac

for command_name in mount mountpoint mknod python3 realpath sha256sum; do
    require_command "$command_name"
done
for required in \
    "$PROJECT_ROOT/resource/backup/19.boot.img" \
    "$PROJECT_ROOT/resource/backup/0.modem/image/modem.mdt" \
    "$PROJECT_ROOT/resource/backup/0.modem/image/wcnss.mdt" \
    "$PROJECT_ROOT/resource/backup/persist/WCNSS_qcom_wlan_nv.bin"; do
    [[ -s "$required" ]] || die "缺少本机私有构建输入：$required"
done

mkdir -p /build
if ! mountpoint -q /build; then
    log "挂载构建 tmpfs：$BUILD_TMPFS_SIZE"
    mount -t tmpfs -o "size=$BUILD_TMPFS_SIZE,mode=0755,exec,dev,nosuid" tmpfs /build \
        || die "无法挂载 /build；容器必须使用 --privileged 和 /build tmpfs"
fi
mkdir -p "$BUILD_ROOT"
device_test="$BUILD_ROOT/.device-test-$$"
mkdir -p "$device_test"
if ! mknod "$device_test/null" c 1 3 || ! printf 'ok\n' > "$device_test/null"; then
    rm -rf -- "$device_test"
    die "$BUILD_ROOT 不允许使用设备节点，不能运行 debootstrap"
fi
rm -rf -- "$device_test"

keyring_hash=""
if [[ -s "$DEBIAN_KEYRING" ]]; then
    keyring_hash="$(sha256sum "$DEBIAN_KEYRING" | awk '{print $1}')"
fi
if [[ "$keyring_hash" != "$DEBIAN_KEYRING_SHA256" ]]; then
    log "安装固定 Debian Bookworm archive keyring"
    bash "$PROJECT_ROOT/scripts/install_debian_bookworm_keyring.sh"
fi
keyring_hash="$(sha256sum "$DEBIAN_KEYRING" | awk '{print $1}')"
[[ "$keyring_hash" == "$DEBIAN_KEYRING_SHA256" ]] \
    || die "Debian archive keyring 哈希不匹配：$keyring_hash"

log "注册 Synology 兼容 ARM binfmt"
bash "$PROJECT_ROOT/scripts/register_qemu_arm_binfmt.sh"

log "构建固定主线内核、DW01 DTB 和模块"
FORCE="$FORCE" \
BUILD_DIR="$BUILD_ROOT/msm8909-mainline" \
SOURCE_ROOT="$SOURCE_ROOT" \
    bash "$PROJECT_ROOT/scripts/build_mainline_kernel.sh"

if [[ -n "$RELEASE_VERSION" ]]; then
    log "以固定 Debian Snapshot 执行两轮独立 large-rootfs 构建"
    bash "$PROJECT_ROOT/scripts/build_debian_large_rootfs_reproducibly.sh"
else
    log "构建 Debian Bookworm armhf 大根卷"
    FORCE="$FORCE" \
    BUILD_DIR="$BUILD_ROOT/msm8909-debian-large-rootfs" \
        bash "$PROJECT_ROOT/scripts/build_debian_large_rootfs.sh"
fi

log "执行独立静态验收"
bash "$PROJECT_ROOT/scripts/verify_debian_large_rootfs.sh"

if [[ -n "$RELEASE_VERSION" ]]; then
    log "生成候选发布包：$RELEASE_VERSION"
    bash "$PROJECT_ROOT/scripts/package_release_candidate.sh" "$RELEASE_VERSION"
fi

log "纯 Debian 大根卷固件构建完成"
printf 'rootfs_system=%s\n' "$PROJECT_ROOT/out/mainline/debian-large-rootfs/debian-bookworm-armhf-large-rootfs-system.img"
printf 'rootfs_cache=%s\n' "$PROJECT_ROOT/out/mainline/debian-large-rootfs/debian-bookworm-armhf-large-rootfs-cache.img"
printf 'rootfs_userdata=%s\n' "$PROJECT_ROOT/out/mainline/debian-large-rootfs/debian-bookworm-armhf-large-rootfs-userdata.img"
printf 'boot=%s\n' "$PROJECT_ROOT/out/mainline/debian-large-rootfs/boot-debian-large-rootfs.img"
