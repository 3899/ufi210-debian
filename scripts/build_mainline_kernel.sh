#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C.UTF-8
# The source tree is intentionally patched and therefore dirty. An explicitly
# empty LOCALVERSION prevents Kbuild from appending its SCM dirty-tree "+".
export LOCALVERSION=

PROJECT_SOURCE_DATE_EPOCH=1781860238
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$PROJECT_SOURCE_DATE_EPOCH}"
[[ "$SOURCE_DATE_EPOCH" == "$PROJECT_SOURCE_DATE_EPOCH" ]] \
    || { printf '错误：正式内核 SOURCE_DATE_EPOCH 必须为 %s\n' "$PROJECT_SOURCE_DATE_EPOCH" >&2; exit 1; }
export SOURCE_DATE_EPOCH
export KBUILD_BUILD_TIMESTAMP="@$SOURCE_DATE_EPOCH"
export KBUILD_BUILD_USER=msm8909
export KBUILD_BUILD_HOST=builder
export KBUILD_BUILD_VERSION=1

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_ROOT/.build/mainline-kernel}"
SOURCE_ROOT="${SOURCE_ROOT:-$BUILD_DIR}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/out/mainline/kernel}"
JOBS="${JOBS:-}"
FORCE="${FORCE:-0}"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/weikaizhi4/linux.git}"
KERNEL_COMMIT="${KERNEL_COMMIT:-410d5647742474d7ed3eaa1b12aef09df18c2633}"
CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"
PATCH_FILE="$PROJECT_ROOT/patches/linux/0001-arm-dts-qcom-add-zu02-dw01-minimal.patch"
REFERENCE_CONFIG="${REFERENCE_CONFIG:-$PROJECT_ROOT/configs/linux-msm8909-reference.config}"
DTB_NAME="qcom-msm8909-zu02-dw01.dtb"
MANIFEST="$OUT_DIR/BUILD-MANIFEST.txt"

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

for command_name in awk depmod find gcc git grep make nproc sed sha256sum tar touch xz "${CROSS_COMPILE}gcc"; do
    require_command "$command_name"
done
[[ -f "$PATCH_FILE" ]] || die "缺少内核补丁：$PATCH_FILE"
mkdir -p "$BUILD_DIR" "$OUT_DIR"
[[ -n "$JOBS" ]] || JOBS="$(nproc)"

[[ -s "$REFERENCE_CONFIG" ]] || die "参考内核配置不存在或为空：$REFERENCE_CONFIG"

patch_sha256="$(sha256sum "$PATCH_FILE" | awk '{print $1}')"
config_sha256="$(sha256sum "$REFERENCE_CONFIG" | awk '{print $1}')"
script_sha256="$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')"
source_key="${patch_sha256:0:12}-${config_sha256:0:12}"
build_key="$source_key-${script_sha256:0:12}"
SOURCE_DIR="$SOURCE_ROOT/linux-$source_key"
OBJ_DIR="${OBJ_DIR:-$BUILD_DIR/obj-$build_key}"
mkdir -p "$SOURCE_ROOT"
if [[ ! -d "$OBJ_DIR" ]]; then
    shopt -s nullglob
    previous_obj_dirs=("$BUILD_DIR"/obj-"$source_key"-*)
    shopt -u nullglob
    if (( ${#previous_obj_dirs[@]} == 1 )) && [[ -f "${previous_obj_dirs[0]}/.config" ]]; then
        OBJ_DIR="${previous_obj_dirs[0]}"
        log "复用已有兼容对象目录：$OBJ_DIR"
    fi
fi

if [[ "$FORCE" != "1" && -s "$OUT_DIR/vmlinuz" && -s "$OUT_DIR/$DTB_NAME" && -f "$MANIFEST" ]] \
    && grep -qx "kernel_commit=$KERNEL_COMMIT" "$MANIFEST" \
    && grep -qx "patch_sha256=$patch_sha256" "$MANIFEST" \
    && grep -qx "reference_config_sha256=$config_sha256" "$MANIFEST" \
    && grep -qx "source_date_epoch=$SOURCE_DATE_EPOCH" "$MANIFEST" \
    && grep -qx "build_script_sha256=$script_sha256" "$MANIFEST"; then
    recorded_kernel_sha256="$(sed -n 's/^kernel_sha256=//p' "$MANIFEST")"
    recorded_dtb_sha256="$(sed -n 's/^dtb_sha256=//p' "$MANIFEST")"
    if [[ "$recorded_kernel_sha256" == "$(sha256sum "$OUT_DIR/vmlinuz" | awk '{print $1}')" \
        && "$recorded_dtb_sha256" == "$(sha256sum "$OUT_DIR/$DTB_NAME" | awk '{print $1}')" ]]; then
        log "源码、配置和产物均未变化，跳过重复编译"
        exit 0
    fi
fi

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    source_donor=""
    shopt -s nullglob
    for candidate in "$SOURCE_ROOT"/linux-*; do
        if [[ "$candidate" != "$SOURCE_DIR" && -d "$candidate/.git" ]] \
            && git -C "$candidate" cat-file -e "$KERNEL_COMMIT^{commit}" 2>/dev/null; then
            source_donor="$candidate"
            break
        fi
    done
    shopt -u nullglob
    if [[ -n "$source_donor" ]]; then
        log "从已有固定提交共享 Git 对象创建源码工作树"
        git clone --shared "$source_donor" "$SOURCE_DIR"
    else
        log "克隆固定内核源码"
        git clone --filter=blob:none "$KERNEL_REPO" "$SOURCE_DIR"
    fi
fi
if ! git -C "$SOURCE_DIR" cat-file -e "$KERNEL_COMMIT^{commit}" 2>/dev/null; then
    log "获取固定内核提交 $KERNEL_COMMIT"
    git -C "$SOURCE_DIR" fetch origin "$KERNEL_COMMIT"
fi
if [[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$KERNEL_COMMIT" ]]; then
    [[ -z "$(git -C "$SOURCE_DIR" status --porcelain)" ]] \
        || die "$SOURCE_DIR 存在未提交修改，请改用新的 BUILD_DIR"
    git -C "$SOURCE_DIR" checkout --detach "$KERNEL_COMMIT"
fi

if git -C "$SOURCE_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
    log "应用 ZU02/DW01 最小 DTS 补丁"
    git -C "$SOURCE_DIR" apply "$PATCH_FILE"
elif git -C "$SOURCE_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
    log "ZU02/DW01 DTS 补丁已经应用"
else
    die "内核补丁既不能应用也不能反向校验"
fi

mkdir -p "$OBJ_DIR"
cp "$REFERENCE_CONFIG" "$OBJ_DIR/.config"

config_tool="$SOURCE_DIR/scripts/config"
"$config_tool" --file "$OBJ_DIR/.config" \
    --disable USB_G_SERIAL \
    --enable USB_LIBCOMPOSITE \
    --enable USB_U_SERIAL \
    --enable USB_F_ACM \
    --enable USB_F_NCM \
    --enable USB_F_RNDIS \
    --enable USB_CONFIGFS \
    --enable USB_CONFIGFS_ACM \
    --enable USB_CONFIGFS_NCM \
    --enable USB_CONFIGFS_RNDIS \
    --enable USB_F_FS \
    --enable QCOM_WCNSS_PIL \
    --enable QCOM_WCNSS_CTRL \
    --enable WCN36XX \
    --enable QRTR \
    --enable QRTR_SMD \
    --enable WWAN \
    --module QCOM_BAM_DMUX \
    --module RPMSG_WWAN_CTRL \
    --module QCOM_Q6V5_MSS \
    --enable QCOM_SYSMON \
    --enable RPMSG_QCOM_SMD \
    --enable QCOM_MDT_LOADER \
    --enable QCOM_RMTFS_MEM \
    --enable QCOM_SMEM \
    --enable QCOM_SMP2P \
    --enable QCOM_SMSM \
    --enable SYSCON_REBOOT_MODE \
    --enable FAT_FS \
    --enable VFAT_FS \
    --enable NLS_CODEPAGE_437 \
    --enable NLS_ISO8859_1

log "解析内核配置"
make -C "$SOURCE_DIR" O="$OBJ_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

grep -qx '# CONFIG_USB_G_SERIAL is not set' "$OBJ_DIR/.config" \
    || die "CONFIG_USB_G_SERIAL 未禁用"
for symbol in USB_CONFIGFS USB_F_ACM USB_F_NCM USB_F_RNDIS USB_F_FS; do
    grep -qx "CONFIG_${symbol}=y" "$OBJ_DIR/.config" \
        || die "CONFIG_${symbol} 没有内建为 y"
done
for symbol in QCOM_WCNSS_PIL QCOM_WCNSS_CTRL WCN36XX CFG80211 MAC80211 RPMSG_QCOM_SMD; do
    grep -qx "CONFIG_${symbol}=y" "$OBJ_DIR/.config" \
        || die "CONFIG_${symbol} 没有内建为 y"
done
for symbol in QRTR QRTR_SMD WWAN QCOM_SYSMON QCOM_MDT_LOADER QCOM_RMTFS_MEM \
    QCOM_SMEM QCOM_SMP2P QCOM_SMSM SYSCON_REBOOT_MODE FAT_FS VFAT_FS \
    NLS_CODEPAGE_437 NLS_ISO8859_1; do
    grep -qx "CONFIG_${symbol}=y" "$OBJ_DIR/.config" \
        || die "CONFIG_${symbol} 没有内建为 y"
done
for symbol in QCOM_Q6V5_MSS QCOM_BAM_DMUX RPMSG_WWAN_CTRL; do
    grep -qx "CONFIG_${symbol}=m" "$OBJ_DIR/.config" \
        || die "CONFIG_${symbol} 没有构建为模块 m"
done

log "编译 zImage、DW01 DTB 和模块"
make -C "$SOURCE_DIR" -j"$JOBS" O="$OBJ_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" \
    zImage "qcom/$DTB_NAME" modules

kernel_release="$(make -s -C "$SOURCE_DIR" O="$OBJ_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" kernelrelease)"
[[ "$kernel_release" == "7.0.0-msm8909" ]] \
    || die "kernel release 为 $kernel_release，预期为 7.0.0-msm8909"

install -m 0644 "$OBJ_DIR/arch/arm/boot/zImage" "$OUT_DIR/vmlinuz"
install -m 0644 "$OBJ_DIR/arch/arm/boot/dts/qcom/$DTB_NAME" "$OUT_DIR/$DTB_NAME"
install -m 0644 "$OBJ_DIR/.config" "$OUT_DIR/config"
install -m 0644 "$OBJ_DIR/System.map" "$OUT_DIR/System.map"

modules_root="$BUILD_DIR/modules-$source_key"
rm -rf -- "$modules_root"
mkdir -p "$modules_root"
make -s -C "$SOURCE_DIR" O="$OBJ_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" \
    INSTALL_MOD_PATH="$modules_root" modules_install
rm -f \
    "$modules_root/lib/modules/$kernel_release/build" \
    "$modules_root/lib/modules/$kernel_release/source"
find "$modules_root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
tar --sort=name --format=posix \
    --pax-option=delete=atime,delete=ctime \
    --owner=0 --group=0 --numeric-owner \
    --mtime="@$SOURCE_DATE_EPOCH" \
    -C "$modules_root" -cf - lib/modules \
    | xz -T1 -9 > "$OUT_DIR/modules-$kernel_release.tar.xz"

kernel_sha256="$(sha256sum "$OUT_DIR/vmlinuz" | awk '{print $1}')"
dtb_sha256="$(sha256sum "$OUT_DIR/$DTB_NAME" | awk '{print $1}')"
modules_sha256="$(sha256sum "$OUT_DIR/modules-$kernel_release.tar.xz" | awk '{print $1}')"
toolchain_version="$("${CROSS_COMPILE}gcc" --version | head -n 1)"
{
    printf 'kernel_repo=%s\n' "$KERNEL_REPO"
    printf 'kernel_commit=%s\n' "$KERNEL_COMMIT"
    printf 'kernel_release=%s\n' "$kernel_release"
    printf 'patch_sha256=%s\n' "$patch_sha256"
    printf 'reference_config_sha256=%s\n' "$config_sha256"
    printf 'source_date_epoch=%s\n' "$SOURCE_DATE_EPOCH"
    printf 'kbuild_build_user=%s\n' "$KBUILD_BUILD_USER"
    printf 'kbuild_build_host=%s\n' "$KBUILD_BUILD_HOST"
    printf 'build_script_sha256=%s\n' "$script_sha256"
    printf 'toolchain=%s\n' "$toolchain_version"
    printf 'kernel_sha256=%s\n' "$kernel_sha256"
    printf 'dtb_sha256=%s\n' "$dtb_sha256"
    printf 'modules_sha256=%s\n' "$modules_sha256"
} > "$MANIFEST"

log "内核完成：$OUT_DIR/vmlinuz"
log "DTB 完成：$OUT_DIR/$DTB_NAME"
log "kernel SHA256：$kernel_sha256"
log "DTB SHA256：$dtb_sha256"
