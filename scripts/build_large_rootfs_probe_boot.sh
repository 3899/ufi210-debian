#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C.UTF-8

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBIAN_OUT="${OUT_DIR:-$PROJECT_ROOT/out/mainline/debian-large-rootfs}"
KERNEL="$PROJECT_ROOT/out/mainline/kernel/vmlinuz"
BOOT="$DEBIAN_OUT/boot-debian-large-rootfs.img"
INITRAMFS="$DEBIAN_OUT/initramfs-zu02-debian"
QCDT="$DEBIAN_OUT/qcdt-zu02-dw01.img"
MANIFEST="$DEBIAN_OUT/BUILD-MANIFEST.txt"
OUTPUT="${OUTPUT:-$DEBIAN_OUT/boot-debian-large-rootfs-dm-probe.img}"
ANALYSIS="${ANALYSIS_DIR:-$DEBIAN_OUT/dm-probe-boot-analysis}"

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

for command_name in awk python3 sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
done
for required in "$KERNEL" "$BOOT" "$INITRAMFS" "$QCDT" "$MANIFEST" \
    "$PROJECT_ROOT/scripts/repack_android_boot.py" "$PROJECT_ROOT/scripts/analyze_bootimg.py"; do
    [[ -s "$required" ]] || die "缺少输入：$required"
done

manifest_value() {
    awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; found=1} END {exit !found}' "$MANIFEST"
}

[[ "$(manifest_value target_partition)" == large-rootfs ]] \
    || die "构建清单不是 large-rootfs"
[[ "$(manifest_value boot_image_sha256)" == "$(sha256sum "$BOOT" | awk '{print $1}')" ]] \
    || die "正式 boot 与构建清单哈希不一致"
[[ "$(manifest_value initramfs_sha256)" == "$(sha256sum "$INITRAMFS" | awk '{print $1}')" ]] \
    || die "initramfs 与构建清单哈希不一致"
[[ "$(manifest_value qcdt_sha256)" == "$(sha256sum "$QCDT" | awk '{print $1}')" ]] \
    || die "QCDT 与构建清单哈希不一致"

python3 "$PROJECT_ROOT/scripts/repack_android_boot.py" \
    --original "$BOOT" \
    --kernel "$KERNEL" \
    --ramdisk "$INITRAMFS" \
    --qcdt "$QCDT" \
    --output "$OUTPUT" \
    --append-cmdline 'ufi210.dm_probe=1' \
    --name 'deb-dm-probe'

rm -rf -- "$ANALYSIS"
python3 "$PROJECT_ROOT/scripts/analyze_bootimg.py" \
    --boot "$OUTPUT" \
    --out "$ANALYSIS" \
    --no-decompile
python3 - "$ANALYSIS/summary.json" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1], encoding="utf-8"))
header = summary["header"]
cmdline = header["cmdline"].split()
assert header["name"] == "deb-dm-probe"
assert "root=/dev/mapper/ufi210-root" in cmdline
assert "ufi210.dm_probe=1" in cmdline
assert "reboot=warm" in cmdline
assert header["qcdt_size"] > 0
PY

printf '只读 dm-linear RAM 探测镜像：%s\n' "$OUTPUT"
printf 'SHA256=%s\n' "$(sha256sum "$OUTPUT" | awk '{print $1}')"
printf '该镜像只用于 fastboot boot，不得 flash 到 boot 分区。\n'
