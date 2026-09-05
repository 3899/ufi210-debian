#!/usr/bin/env python3
"""Repack an Android boot image v0 while preserving addresses and page size."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
import struct
from pathlib import Path


BOOT_MAGIC = b"ANDROID!"
HEADER_SIZE = 1632


def align_blob(data: bytes, page_size: int) -> bytes:
    return data + (b"\0" * ((-len(data)) % page_size))


def cstr(value: str, size: int, field: str) -> bytes:
    raw = value.encode("ascii", "ignore")
    if len(raw) > size:
        raise SystemExit(f"{field} is too long: {len(raw)} > {size}")
    return raw + b"\0" * (size - len(raw))


def u32le(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def parse_original(path: Path) -> dict[str, int | str]:
    data = path.read_bytes()
    if data[:8] != BOOT_MAGIC:
        raise SystemExit(f"{path} is not an Android boot image")
    return {
        "kernel_addr": u32le(data, 12),
        "ramdisk_addr": u32le(data, 20),
        "second_addr": u32le(data, 28),
        "tags_addr": u32le(data, 32),
        "page_size": u32le(data, 36),
        "name": data[48:64].split(b"\0", 1)[0].decode("ascii", "replace"),
        "cmdline": (
            data[64:64 + 512].split(b"\0", 1)[0]
            + data[608:608 + 1024].split(b"\0", 1)[0]
        ).decode("ascii", "replace"),
    }


def empty_newc_gzip() -> bytes:
    # Header fields: magic + 13 eight-hex-digit fields.
    name = b"TRAILER!!!\0"
    namesize = len(name)
    header = (
        b"070701"
        + b"00000000"  # ino
        + b"00000000"  # mode
        + b"00000000"  # uid
        + b"00000000"  # gid
        + b"00000001"  # nlink
        + b"00000000"  # mtime
        + b"00000000"  # filesize
        + b"00000000"  # devmajor
        + b"00000000"  # devminor
        + b"00000000"  # rdevmajor
        + b"00000000"  # rdevminor
        + f"{namesize:08x}".encode("ascii")
        + b"00000000"  # check
    )
    blob = header + name
    blob += b"\0" * ((-len(blob)) % 4)
    return gzip.compress(blob, compresslevel=9)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--original", default="resource/backup/19.boot.img")
    ap.add_argument("--kernel", default="out/boot-analysis/kernel")
    ap.add_argument("--ramdisk", default="", help="ramdisk image; if omitted, use an empty gzip newc initramfs")
    ap.add_argument(
        "--qcdt",
        default="out/boot-analysis/qcdt.img",
        help="QCDT/DT image, or 'none'/'-' to omit it",
    )
    ap.add_argument("--output", default="out/boot-test/boot-debian-test.img")
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--append-cmdline", default="")
    ap.add_argument("--name", default="debian-test")
    args = ap.parse_args()

    original = parse_original(Path(args.original))
    page_size = int(original["page_size"])

    kernel = Path(args.kernel).read_bytes()
    if args.ramdisk:
        ramdisk = Path(args.ramdisk).read_bytes()
    else:
        ramdisk = empty_newc_gzip()
    qcdt = (
        Path(args.qcdt).read_bytes()
        if args.qcdt and args.qcdt.lower() not in {"none", "-"}
        else b""
    )
    second = b""

    cmdline = args.cmdline or str(original["cmdline"])
    if args.append_cmdline:
        cmdline = (cmdline + " " + args.append_cmdline).strip()

    sha = hashlib.sha1()
    for blob in (kernel, ramdisk, second, qcdt):
        sha.update(blob)
        sha.update(struct.pack("<I", len(blob)))
    img_id = sha.digest() + b"\0" * 12

    cmd0 = cmdline[:512]
    cmd1 = cmdline[512:]

    header = bytearray()
    header += BOOT_MAGIC
    header += struct.pack(
        "<10I",
        len(kernel),
        int(original["kernel_addr"]),
        len(ramdisk),
        int(original["ramdisk_addr"]),
        len(second),
        int(original["second_addr"]),
        int(original["tags_addr"]),
        page_size,
        len(qcdt),
        0,
    )
    header += cstr(args.name, 16, "name")
    header += cstr(cmd0, 512, "cmdline")
    header += img_id[:32]
    header += cstr(cmd1, 1024, "extra_cmdline")
    if len(header) != HEADER_SIZE:
        raise SystemExit(f"internal header size mismatch: {len(header)}")

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("wb") as f:
        f.write(align_blob(bytes(header), page_size))
        f.write(align_blob(kernel, page_size))
        f.write(align_blob(ramdisk, page_size))
        if second:
            f.write(align_blob(second, page_size))
        if qcdt:
            f.write(align_blob(qcdt, page_size))

    print(f"wrote {out}")
    print(f"kernel={len(kernel)} ramdisk={len(ramdisk)} qcdt={len(qcdt)} page={page_size}")
    print(f"cmdline={cmdline}")


if __name__ == "__main__":
    main()
