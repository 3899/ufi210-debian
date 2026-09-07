#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C.UTF-8

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
OUT_ROOT="${OUT_ROOT:-$PROJECT_ROOT/out/release-candidate}"
SOURCE_ROOT="${DEBIAN_SOURCE_ROOT:-$PROJECT_ROOT/out/debian-corresponding-sources/$VERSION}"
ROOTFS_TARBALL="$PROJECT_ROOT/out/mainline/debian-system/debian-bookworm-armhf-system-rootfs.tar.xz"
KERNEL_OUT="$PROJECT_ROOT/out/mainline/kernel"
KERNEL_MANIFEST="$KERNEL_OUT/BUILD-MANIFEST.txt"
KERNEL_PATCH="$PROJECT_ROOT/patches/linux/0001-arm-dts-qcom-add-zu02-dw01-minimal.patch"
KERNEL_CONFIG="$KERNEL_OUT/config"
KERNEL_SOURCE_ROOT="${KERNEL_SOURCE_ROOT:-$PROJECT_ROOT/.build/msm8909-kernel-source}"
PROJECT_SOURCE_DATE_EPOCH=1781860238
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$PROJECT_SOURCE_DATE_EPOCH}"
VERIFY_SOURCE_REPRODUCIBILITY="${VERIFY_SOURCE_REPRODUCIBILITY:-1}"
VERIFIED_DEBIAN_SOURCE_ARCHIVE="${VERIFIED_DEBIAN_SOURCE_ARCHIVE:-}"
VERIFIED_DEBIAN_SOURCE_SHA256="${VERIFIED_DEBIAN_SOURCE_SHA256:-}"
VERIFIED_KERNEL_SOURCE_ARCHIVE="${VERIFIED_KERNEL_SOURCE_ARCHIVE:-}"
VERIFIED_KERNEL_SOURCE_SHA256="${VERIFIED_KERNEL_SOURCE_SHA256:-}"
PACKAGE_SCRIPT="$PROJECT_ROOT/scripts/package_release_candidate.sh"
COLLECTOR="$PROJECT_ROOT/scripts/collect_debian_sources.py"
ARCHIVE_VERIFIER="$PROJECT_ROOT/scripts/verify_public_release.py"

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

for command_name in awk cmp cut dpkg-query git grep install mktemp python3 realpath sha256sum sort tar xz; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
done
[[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] \
    || die "请提供合法候选版本号"
[[ "$SOURCE_DATE_EPOCH" == "$PROJECT_SOURCE_DATE_EPOCH" ]] \
    || die "公开候选 SOURCE_DATE_EPOCH 必须为 $PROJECT_SOURCE_DATE_EPOCH"
[[ "$VERIFY_SOURCE_REPRODUCIBILITY" == 0 || "$VERIFY_SOURCE_REPRODUCIBILITY" == 1 ]] \
    || die "VERIFY_SOURCE_REPRODUCIBILITY 只能为 0 或 1"
if [[ -n "$VERIFIED_DEBIAN_SOURCE_ARCHIVE" ]]; then
    [[ "$VERIFIED_DEBIAN_SOURCE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
        || die "复用 Debian 对应源码归档时必须提供小写 SHA256"
fi
if [[ -n "$VERIFIED_KERNEL_SOURCE_ARCHIVE" ]]; then
    [[ "$VERIFIED_KERNEL_SOURCE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
        || die "复用 Linux 对应源码归档时必须提供小写 SHA256"
fi
[[ -s "$PACKAGE_SCRIPT" && -s "$COLLECTOR" && -s "$ARCHIVE_VERIFIER" ]] \
    || die "缺少候选打包器、Debian 源码收集器或发布归档验收器"
[[ -s "$ROOTFS_TARBALL" ]] || die "缺少 Debian system rootfs tarball"
for required in "$KERNEL_MANIFEST" "$KERNEL_PATCH" "$KERNEL_CONFIG"; do
    [[ -s "$required" ]] || die "缺少内核源码归档输入：$required"
done

OUT_ROOT="$(realpath -m "$OUT_ROOT")"
SOURCE_ROOT="$(realpath -m "$SOURCE_ROOT")"
case "$OUT_ROOT" in
    "$PROJECT_ROOT/out"|"$PROJECT_ROOT/out/"*) ;;
    *) die "OUT_ROOT 必须位于工程 out 目录内" ;;
esac
case "$SOURCE_ROOT" in
    "$PROJECT_ROOT/out"|"$PROJECT_ROOT/out/"*) ;;
    *) die "DEBIAN_SOURCE_ROOT 必须位于工程 out 目录内" ;;
esac
if [[ -n "$VERIFIED_DEBIAN_SOURCE_ARCHIVE" ]]; then
    VERIFIED_DEBIAN_SOURCE_ARCHIVE="$(realpath "$VERIFIED_DEBIAN_SOURCE_ARCHIVE")"
    [[ -s "$VERIFIED_DEBIAN_SOURCE_ARCHIVE" ]] || die "已验证 Debian 对应源码归档不存在"
    case "$VERIFIED_DEBIAN_SOURCE_ARCHIVE" in
        "$OUT_ROOT/$VERSION"|"$OUT_ROOT/$VERSION/"*)
            die "复用归档不能位于将被重新生成的候选目录内"
            ;;
    esac
    actual_source_hash="$(sha256sum "$VERIFIED_DEBIAN_SOURCE_ARCHIVE" | awk '{print $1}')"
    [[ "$actual_source_hash" == "$VERIFIED_DEBIAN_SOURCE_SHA256" ]] \
        || die "已验证 Debian 对应源码归档 SHA256 不匹配"
fi
if [[ -n "$VERIFIED_KERNEL_SOURCE_ARCHIVE" ]]; then
    VERIFIED_KERNEL_SOURCE_ARCHIVE="$(realpath "$VERIFIED_KERNEL_SOURCE_ARCHIVE")"
    [[ -s "$VERIFIED_KERNEL_SOURCE_ARCHIVE" ]] || die "已验证 Linux 对应源码归档不存在"
    case "$VERIFIED_KERNEL_SOURCE_ARCHIVE" in
        "$OUT_ROOT/$VERSION"|"$OUT_ROOT/$VERSION/"*)
            die "复用的 Linux 源码归档不能位于将被重新生成的候选目录内"
            ;;
    esac
    actual_kernel_source_hash="$(sha256sum "$VERIFIED_KERNEL_SOURCE_ARCHIVE" | awk '{print $1}')"
    [[ "$actual_kernel_source_hash" == "$VERIFIED_KERNEL_SOURCE_SHA256" ]] \
        || die "已验证 Linux 对应源码归档 SHA256 不匹配"
fi

OUT_ROOT="$OUT_ROOT" bash "$PACKAGE_SCRIPT" "$VERSION"

release_dir="$OUT_ROOT/$VERSION"
binary_name="ufi210-debian-zu02-dw01-$VERSION"
source_name="ufi210-debian-source-$VERSION"
debian_source_name="ufi210-debian-debian-sources-$VERSION"
kernel_source_name="ufi210-debian-kernel-source-$VERSION"
source_archive="$release_dir/$source_name.tar.xz"
debian_source_archive="$release_dir/$debian_source_name.tar.xz"
kernel_source_archive="$release_dir/$kernel_source_name.tar.xz"
collection="$SOURCE_ROOT/collection"
archive_collection="$collection"
mkdir -p "$SOURCE_ROOT"

tmp_dir="$(mktemp -d "$SOURCE_ROOT/package-public.XXXXXX")"
case "$tmp_dir" in
    "$SOURCE_ROOT"/package-public.*) ;;
    *) die "临时目录越界" ;;
esac
trap 'rm -rf -- "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/dpkg-root/var/lib/dpkg"
tar -C "$tmp_dir/dpkg-root" -xJf "$ROOTFS_TARBALL" ./var/lib/dpkg/status
dpkg-query --admindir="$tmp_dir/dpkg-root/var/lib/dpkg" \
    -W -f='${source:Package}\t${source:Version}\n' \
    | sort -u > "$tmp_dir/source-packages.txt"

kernel_manifest_value() {
    sed -n "s/^$1=//p" "$KERNEL_MANIFEST"
}
kernel_repo="$(kernel_manifest_value kernel_repo)"
kernel_commit="$(kernel_manifest_value kernel_commit)"
kernel_patch_sha256="$(kernel_manifest_value patch_sha256)"
kernel_reference_config_sha256="$(kernel_manifest_value reference_config_sha256)"
kernel_release="$(kernel_manifest_value kernel_release)"
[[ "$kernel_commit" =~ ^[0-9a-f]{40}$ ]] || die "内核 manifest 提交格式错误"
[[ "$kernel_patch_sha256" == "$(sha256sum "$KERNEL_PATCH" | awk '{print $1}')" ]] \
    || die "内核补丁与 manifest 不一致"
[[ "$kernel_reference_config_sha256" == \
    "$(sha256sum "$PROJECT_ROOT/configs/linux-msm8909-reference.config" | awk '{print $1}')" ]] \
    || die "内核参考配置与 manifest 不一致"
kernel_source_key="${kernel_patch_sha256:0:12}-${kernel_reference_config_sha256:0:12}"
kernel_checkout="$KERNEL_SOURCE_ROOT/linux-$kernel_source_key"
if [[ -n "$VERIFIED_KERNEL_SOURCE_ARCHIVE" ]]; then
    tar -tJf "$VERIFIED_KERNEL_SOURCE_ARCHIVE" \
        | awk -F/ -v root="$kernel_source_name" \
            '$1 != root || $0 ~ /(^|\/)\.\.(\/|$)/ { exit 1 }' \
        || die "已验证 Linux 对应源码归档的根目录或路径边界无效"
    tar -xJOf "$VERIFIED_KERNEL_SOURCE_ARCHIVE" \
        "$kernel_source_name/UFI210-BUILD-METADATA.txt" >/dev/null \
        || die "已验证 Linux 对应源码归档缺少构建元数据"
    install -m 0644 "$VERIFIED_KERNEL_SOURCE_ARCHIVE" "$kernel_source_archive"
    printf '复用同版本且已通过 SHA256 核对的 Linux 对应源码归档\n'
else
    [[ -d "$kernel_checkout/.git" ]] || die "缺少固定提交的内核 Git 工作树：$kernel_checkout"
    [[ "$(git -C "$kernel_checkout" rev-parse HEAD)" == "$kernel_commit" ]] \
        || die "内核工作树提交与 manifest 不一致"

    kernel_stage="$tmp_dir/$kernel_source_name"
    mkdir -p "$kernel_stage"
    printf '从固定提交生成完整 Linux 对应源码\n'
    git -C "$kernel_checkout" archive --format=tar "$kernel_commit" \
        | tar -C "$kernel_stage" -xf -
    git -C "$kernel_stage" apply --no-index "$KERNEL_PATCH"
    install -m 0644 "$KERNEL_CONFIG" "$kernel_stage/.config"
    install -m 0644 "$KERNEL_PATCH" "$kernel_stage/UFI210-DTS.patch"
    cat > "$kernel_stage/UFI210-BUILD-METADATA.txt" <<EOF
source_repository=$kernel_repo
source_commit=$kernel_commit
kernel_release=$kernel_release
applied_patch=UFI210-DTS.patch
build_config=.config
source_date_epoch=$SOURCE_DATE_EPOCH
EOF
    for required in \
        COPYING .config UFI210-DTS.patch UFI210-BUILD-METADATA.txt \
        arch/arm/boot/dts/qcom/qcom-msm8909-zu02-dw01.dts; do
        [[ -s "$kernel_stage/$required" ]] || die "内核对应源码缺少：$required"
    done
    cmp -s \
        "$kernel_stage/arch/arm/boot/dts/qcom/qcom-msm8909-zu02-dw01.dts" \
        "$kernel_checkout/arch/arm/boot/dts/qcom/qcom-msm8909-zu02-dw01.dts" \
        || die "内核源码归档中的 DW01 DTS 与构建工作树不一致"
    tar --sort=name --format=posix \
        --pax-option=delete=atime,delete=ctime \
        --owner=0 --group=0 --numeric-owner \
        --mtime="@$SOURCE_DATE_EPOCH" \
        -C "$tmp_dir" -cf - "$kernel_source_name" \
        | xz -T1 -3 > "$kernel_source_archive"
    xz -t "$kernel_source_archive"
    tar -xJOf "$kernel_source_archive" \
        "$kernel_source_name/arch/arm/boot/dts/qcom/qcom-msm8909-zu02-dw01.dts" \
        >/dev/null \
        || die "内核对应源码归档结构错误"
fi

if [[ -n "$VERIFIED_DEBIAN_SOURCE_ARCHIVE" ]]; then
    mapfile -t reused_package_lists < <(
        tar -tJf "$VERIFIED_DEBIAN_SOURCE_ARCHIVE" \
            | grep -E '^[^/]+/source-packages\.txt$'
    )
    (( ${#reused_package_lists[@]} == 1 )) \
        || die "已验证 Debian 对应源码归档的软件包清单数量不是 1"
    tar -xJOf "$VERIFIED_DEBIAN_SOURCE_ARCHIVE" \
        "${reused_package_lists[0]}" > "$tmp_dir/reused-source-packages.txt" \
        || die "已验证 Debian 对应源码归档缺少当前版本软件包清单"
    cmp -s "$tmp_dir/source-packages.txt" "$tmp_dir/reused-source-packages.txt" \
        || die "已验证 Debian 对应源码归档与当前 rootfs 软件包清单不一致"
    reused_root="${reused_package_lists[0]%/source-packages.txt}"
    tar -tJf "$VERIFIED_DEBIAN_SOURCE_ARCHIVE" \
        | awk -F/ -v root="$reused_root" \
            '$1 != root || $0 ~ /(^|\/)\.\.(\/|$)/ { exit 1 }' \
        || die "已验证 Debian 对应源码归档的路径边界无效"
    reused_collection="$tmp_dir/reused-collection"
    mkdir -p "$reused_collection"
    tar --no-same-owner --no-same-permissions --strip-components=1 \
        -C "$reused_collection" -xJf "$VERIFIED_DEBIAN_SOURCE_ARCHIVE"
    [[ -s "$reused_collection/source-packages.txt" \
        && -s "$reused_collection/DEBIAN-SOURCE-MANIFEST.txt" ]] \
        || die "已验证 Debian 对应源码归档的集合不完整"
    cmp -s "$tmp_dir/source-packages.txt" "$reused_collection/source-packages.txt" \
        || die "解包后的 Debian 源码集合与当前 rootfs 软件包清单不一致"
    python3 "$COLLECTOR" \
        "$reused_collection/source-packages.txt" "$reused_collection" \
        --verify-only \
        --archive "$debian_source_archive" \
        --release-version "$VERSION"
    archive_collection="$reused_collection"
    printf '复用已通过归档哈希核对的 Debian 对应源码集合并按当前名称重新归档\n'
elif [[ -s "$collection/source-packages.txt" \
    && -s "$collection/DEBIAN-SOURCE-MANIFEST.txt" ]] \
    && cmp -s "$tmp_dir/source-packages.txt" "$collection/source-packages.txt"; then
    printf '复用并离线复核已收集的 Debian 对应源码\n'
    python3 "$COLLECTOR" \
        "$collection/source-packages.txt" "$collection" \
        --verify-only \
        --archive "$debian_source_archive" \
        --release-version "$VERSION"
else
    printf '从 Debian Snapshot 收集精确版本对应源码\n'
    python3 "$COLLECTOR" \
        "$tmp_dir/source-packages.txt" "$collection" \
        --jobs "${DEBIAN_SOURCE_JOBS:-2}" \
        --archive "$debian_source_archive" \
        --release-version "$VERSION"
fi

if [[ "$VERIFY_SOURCE_REPRODUCIBILITY" == 1 ]]; then
    repro_archive="$tmp_dir/$debian_source_name.tar.xz"
    python3 "$COLLECTOR" \
        "$archive_collection/source-packages.txt" "$archive_collection" \
        --verify-only \
        --archive "$repro_archive" \
        --release-version "$VERSION"
    cmp -s "$debian_source_archive" "$repro_archive" \
        || die "两次 Debian 对应源码归档不一致"
    printf 'Debian 对应源码归档可复现性检查通过\n'
fi

(
    cd "$release_dir"
    sha256sum \
        "$source_name.tar.xz" \
        "$binary_name.zip" \
        "$debian_source_name.tar.xz" \
        "$kernel_source_name.tar.xz" \
        > SHA256SUMS
    sha256sum -c SHA256SUMS
)

printf '解包并复审全部公开候选归档\n'
python3 "$ARCHIVE_VERIFIER" "$VERSION" --out-root "$OUT_ROOT"

printf '公开候选发布材料完成：%s\n' "$release_dir"
cat "$release_dir/SHA256SUMS"
printf '注意：会建立蜂窝数据连接的测试必须先确认资费，并显式传入 -AllowCellularDataUsage。\n'
