#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C.UTF-8

BINFMT_DIR="/proc/sys/fs/binfmt_misc"
FALLBACK_NAME="qemu-arm-syno"
INTERPRETER="/usr/bin/qemu-arm-static"
MAGIC='\x7f\x45\x4c\x46\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00'
MASK='\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

(( EUID == 0 )) || die "必须以 root 身份注册 binfmt_misc"
command -v mount >/dev/null 2>&1 || die "缺少命令：mount"
command -v mountpoint >/dev/null 2>&1 || die "缺少命令：mountpoint"
[[ -x "$INTERPRETER" ]] || die "缺少解释器：$INTERPRETER"

mkdir -p "$BINFMT_DIR"
if ! mountpoint -q "$BINFMT_DIR"; then
    mount -t binfmt_misc binfmt_misc "$BINFMT_DIR" \
        || die "无法挂载 binfmt_misc；容器需要特权模式或 CAP_SYS_ADMIN"
fi
[[ -w "$BINFMT_DIR/register" ]] || die "binfmt_misc register 不可写"

if command -v update-binfmts >/dev/null 2>&1; then
    update-binfmts --import qemu-arm >/dev/null 2>&1 || true
    update-binfmts --enable qemu-arm >/dev/null 2>&1 || true
fi

if [[ -r "$BINFMT_DIR/qemu-arm" ]] \
    && grep -qx enabled "$BINFMT_DIR/qemu-arm"; then
    printf '已启用标准 qemu-arm binfmt 规则\n'
    cat "$BINFMT_DIR/qemu-arm"
    exit 0
fi

# Synology 的旧内核可能不支持 fix_binary(F)。不带 F 时，解释器必须存在于 chroot 内；
# build_debian_cache.sh 会在执行 ARM 子进程前复制 qemu-arm-static。
if [[ -e "$BINFMT_DIR/$FALLBACK_NAME" ]]; then
    printf '%s\n' -1 > "$BINFMT_DIR/$FALLBACK_NAME"
fi
spec=":$FALLBACK_NAME:M:0:$MAGIC:$MASK:$INTERPRETER:OC"
printf '%s\n' "$spec" > "$BINFMT_DIR/register" \
    || die "兼容 qemu-arm 规则注册失败"

[[ -r "$BINFMT_DIR/$FALLBACK_NAME" ]] || die "注册后未找到 $FALLBACK_NAME"
grep -qx enabled "$BINFMT_DIR/$FALLBACK_NAME" \
    || die "$FALLBACK_NAME 未启用"
printf '已启用 Synology 兼容 qemu-arm binfmt 规则（OC，无 P/F 标志）\n'
cat "$BINFMT_DIR/$FALLBACK_NAME"
