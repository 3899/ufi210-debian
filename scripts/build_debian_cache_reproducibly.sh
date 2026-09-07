#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C.UTF-8

PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TARGET_PARTITION="${TARGET_PARTITION:-cache}"
RESUME_VERIFIED_A="${RESUME_VERIFIED_A:-0}"
BUILD_SCRIPT="${BUILD_SCRIPT:-$PROJECT_ROOT/scripts/build_debian_cache.sh}"
VERIFY_SCRIPT="${VERIFY_SCRIPT:-$PROJECT_ROOT/scripts/verify_debian_cache.sh}"
case "$TARGET_PARTITION" in
    cache|system) ;;
    *)
        printf '错误：TARGET_PARTITION 只允许 cache 或 system\n' >&2
        exit 1
        ;;
esac
case "$RESUME_VERIFIED_A" in
    0|1) ;;
    *)
        printf '错误：RESUME_VERIFIED_A 只允许 0 或 1\n' >&2
        exit 1
        ;;
esac
EXPECTED_REPRO_ROOT="$PROJECT_ROOT/out/mainline/debian-${TARGET_PARTITION}-reproducibility"
EXPECTED_BUILD_ROOT="/build/msm8909-debian-${TARGET_PARTITION}-reproducibility"
EXPECTED_PUBLISH_DIR="$PROJECT_ROOT/out/mainline/debian-${TARGET_PARTITION}"
REPRO_ROOT="${REPRO_ROOT:-$EXPECTED_REPRO_ROOT}"
BUILD_ROOT="${BUILD_ROOT:-$EXPECTED_BUILD_ROOT}"
PUBLISH_DIR="${PUBLISH_DIR:-$EXPECTED_PUBLISH_DIR}"
FILES=(
    "debian-bookworm-armhf-${TARGET_PARTITION}.ext4"
    "debian-bookworm-armhf-${TARGET_PARTITION}-rootfs.tar.xz"
    "boot-debian-${TARGET_PARTITION}.img"
    initramfs-zu02-debian
    qcdt-zu02-dw01.img
    packages.txt
    BUILD-MANIFEST.txt
    WCNSS-FIRMWARE-MANIFEST.txt
    MPSS-FIRMWARE-MANIFEST.txt
)
if [[ "$TARGET_PARTITION" == system ]]; then
    FILES+=("debian-bookworm-armhf-data.ext4")
fi

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

for command_name in cmp install realpath sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
done
[[ -s "$BUILD_SCRIPT" && -s "$VERIFY_SCRIPT" ]] || die "缺少构建脚本或静态验收脚本"

REPRO_ROOT="$(realpath -m "$REPRO_ROOT")"
BUILD_ROOT="$(realpath -m "$BUILD_ROOT")"
PUBLISH_DIR="$(realpath -m "$PUBLISH_DIR")"
[[ "$REPRO_ROOT" == "$(realpath -m "$EXPECTED_REPRO_ROOT")" ]] \
    || die "REPRO_ROOT 必须为 $EXPECTED_REPRO_ROOT"
[[ "$BUILD_ROOT" == "$EXPECTED_BUILD_ROOT" ]] \
    || die "BUILD_ROOT 必须为 $EXPECTED_BUILD_ROOT"
[[ "$PUBLISH_DIR" == "$(realpath -m "$EXPECTED_PUBLISH_DIR")" ]] \
    || die "PUBLISH_DIR 必须为 $EXPECTED_PUBLISH_DIR"

RUN_A="$REPRO_ROOT/build-a"
RUN_B="$REPRO_ROOT/build-b"
BUILD_A="$BUILD_ROOT/build-a"
BUILD_B="$BUILD_ROOT/build-b"
REPORT="$REPRO_ROOT/REPRODUCIBILITY.txt"

if [[ "$RESUME_VERIFIED_A" == 1 ]]; then
    printf '[1/5] 重新验收已完成的第一轮固定快照构建\n'
    for file in "${FILES[@]}"; do
        [[ -s "$RUN_A/$file" ]] || die "续跑缺少第一轮产物：$file"
    done
    rm -rf -- "$RUN_B" "$BUILD_B"
    rm -f -- "$REPORT"
    mkdir -p "$RUN_B" "$PUBLISH_DIR"
    TARGET_PARTITION="$TARGET_PARTITION" OUT_DIR="$RUN_A" bash "$VERIFY_SCRIPT"
else
    rm -rf -- "$REPRO_ROOT" "$BUILD_A" "$BUILD_B"
    mkdir -p "$RUN_A" "$RUN_B" "$PUBLISH_DIR"
    printf '[1/5] 在独立目录执行第一轮固定快照构建\n'
    TARGET_PARTITION="$TARGET_PARTITION" FORCE=1 BUILD_DIR="$BUILD_A" OUT_DIR="$RUN_A" \
        bash "$BUILD_SCRIPT"
    TARGET_PARTITION="$TARGET_PARTITION" OUT_DIR="$RUN_A" bash "$VERIFY_SCRIPT"
fi

printf '[2/5] 在独立目录执行第二轮固定快照构建\n'
TARGET_PARTITION="$TARGET_PARTITION" FORCE=1 BUILD_DIR="$BUILD_B" OUT_DIR="$RUN_B" \
    bash "$BUILD_SCRIPT"
TARGET_PARTITION="$TARGET_PARTITION" OUT_DIR="$RUN_B" bash "$VERIFY_SCRIPT"

printf '[3/5] 逐字节比较两轮全部正式产物\n'
for file in "${FILES[@]}"; do
    [[ -s "$RUN_A/$file" && -s "$RUN_B/$file" ]] || die "双构建缺少产物：$file"
    cmp -s "$RUN_A/$file" "$RUN_B/$file" || die "双构建产物不一致：$file"
done

{
    printf 'result=passed\n'
    printf 'debian_snapshot_timestamp=20260903T000000Z\n'
    printf 'comparison=byte-for-byte\n'
    printf 'target_partition=%s\n' "$TARGET_PARTITION"
    for file in "${FILES[@]}"; do
        printf '%s  %s\n' "$(sha256sum "$RUN_A/$file" | awk '{print $1}')" "$file"
    done
} > "$REPORT"

printf '[4/5] 发布已通过双构建比较的产物\n'
for file in "${FILES[@]}"; do
    install -m 0644 "$RUN_A/$file" "$PUBLISH_DIR/.$file.new"
    mv -f "$PUBLISH_DIR/.$file.new" "$PUBLISH_DIR/$file"
done
install -m 0644 "$REPORT" "$PUBLISH_DIR/REPRODUCIBILITY.txt"

printf '[5/5] 对发布目录执行最终静态验收\n'
TARGET_PARTITION="$TARGET_PARTITION" OUT_DIR="$PUBLISH_DIR" bash "$VERIFY_SCRIPT"
printf '固定快照双构建逐字节一致，结果：%s\n' "$REPORT"
