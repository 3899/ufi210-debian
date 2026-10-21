#!/usr/bin/env python3
"""
生成支持全系 MSM8909 / UFI210 硬件变种的通用 Universal boot.img
融合原厂 137 条 QCDT 硬件条目与 Debian 7.0.0-msm8909 主线内核及 DTB。
"""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys
from pathlib import Path

# 引用仓库内置工具
script_dir = Path(__file__).resolve().parent
sys.path.insert(0, str(script_dir))

from analyze_bootimg import (
    QCDT_MAGIC,
    align,
    find_fdt_blobs,
    parse_boot_header,
    parse_qcdt_entries,
)
from build_stock_qcdt import build_qcdt_v3


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def pad_to_size(data: bytes, target_size: int) -> bytes:
    if len(data) > target_size:
        raise ValueError(f"数据大小 ({len(data)}) 超出目标分区大小 ({target_size})")
    return data + b"\x00" * (target_size - len(data))


def find_default_raw_boot(project_root: Path) -> Path | None:
    """在 out 目录下查找最新的 boot-raw.img。"""
    out_dir = project_root / "out"
    if out_dir.is_dir():
        candidates = sorted(
            out_dir.glob("**/boot-raw.img"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if candidates:
            return candidates[0]
    return None


def main() -> None:
    project_root = script_dir.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--stock-boot",
        type=Path,
        default=project_root / "resource" / "backup" / "19.boot.img",
        help="原厂包含完整 QCDT 的 boot 镜像路径",
    )
    parser.add_argument(
        "--debian-raw-boot",
        type=Path,
        default=None,
        help="Debian 基础 boot-raw.img 路径（未指定时自动查找 out 目录下最新镜像）",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="输出目录（未指定时默认输出至输入镜像所在目录或 out 根目录）",
    )
    parser.add_argument(
        "--partition-bytes",
        type=int,
        default=33554432,  # 32MB
        help="9008 分区扇区填充大小（字节）",
    )
    args = parser.parse_args()

    debian_raw_boot = args.debian_raw_boot
    if debian_raw_boot is None:
        debian_raw_boot = find_default_raw_boot(project_root)
        if debian_raw_boot is None or not debian_raw_boot.is_file():
            raise FileNotFoundError("未指定 --debian-raw-boot，且在 out 目录下未找到 boot-raw.img")

    output_dir = args.output_dir
    if output_dir is None:
        output_dir = debian_raw_boot.parent

    print(f"[*] 读取原厂 boot: {args.stock_boot}")
    stock_bytes = args.stock_boot.read_bytes()
    stock_hdr = parse_boot_header(stock_bytes)
    stock_qcdt = stock_bytes[
        stock_hdr["qcdt_offset"] : stock_hdr["qcdt_offset"] + stock_hdr["qcdt_size"]
    ]
    stock_blobs = find_fdt_blobs(stock_qcdt)
    stock_blob_indexes = {item["offset"]: idx for idx, item in enumerate(stock_blobs)}
    stock_parsed = parse_qcdt_entries(stock_qcdt, stock_blob_indexes)
    all_records = stock_parsed["entries"]
    print(f"[+] 提取到原厂 QCDT 硬件条目: {len(all_records)} 条")

    print(f"[*] 读取 Debian boot: {debian_raw_boot}")
    deb_bytes = debian_raw_boot.read_bytes()
    deb_hdr = parse_boot_header(deb_bytes)
    page_size = int(deb_hdr["page_size"])

    # 提取 Debian 内核
    k_offset = page_size
    k_size = int(deb_hdr["kernel_size"])
    kernel = deb_bytes[k_offset : k_offset + k_size]

    # 提取 Debian ramdisk
    r_offset = int(deb_hdr["ramdisk_offset"])
    r_size = int(deb_hdr["ramdisk_size"])
    ramdisk = deb_bytes[r_offset : r_offset + r_size]

    # 提取 Debian DTB
    deb_qcdt = deb_bytes[
        deb_hdr["qcdt_offset"] : deb_hdr["qcdt_offset"] + deb_hdr["qcdt_size"]
    ]
    deb_blobs = find_fdt_blobs(deb_qcdt)
    if not deb_blobs:
        raise ValueError("Debian boot 未包含有效的 DTB")
    dtb = deb_qcdt[deb_blobs[0]["offset"] : deb_blobs[0]["offset"] + deb_blobs[0]["size"]]
    print(f"[+] 提取到 Debian 主线 DTB 大小: {len(dtb)} 字节")

    # 构建 Universal 137 条目 QCDT
    print("[*] 正在构建通用 QCDT v3 (137 条记录全部映射至主线 DTB)...")
    univ_qcdt = build_qcdt_v3(all_records, dtb, page_size)
    print(f"[+] 通用 QCDT 构建成功: {len(univ_qcdt)} 字节")

    # 组装 Android Boot Header
    new_hdr = bytearray(deb_bytes[:page_size])
    # 更新 dt_size (offset 40)
    struct.pack_into("<I", new_hdr, 40, len(univ_qcdt))

    def align_block(data: bytes, boundary: int) -> bytes:
        rem = len(data) % boundary
        return data + (b"\x00" * (boundary - rem) if rem else b"")

    new_boot_raw = bytearray()
    new_boot_raw.extend(new_hdr)
    new_boot_raw.extend(align_block(kernel, page_size))
    new_boot_raw.extend(align_block(ramdisk, page_size))
    new_boot_raw.extend(align_block(univ_qcdt, page_size))

    # 更新 Header 中的 SHA 摘要 (8 个 uint32)
    sha = hashlib.sha1()
    sha.update(kernel)
    sha.update(struct.pack("<I", len(kernel)))
    sha.update(ramdisk)
    sha.update(struct.pack("<I", len(ramdisk)))
    sha.update(b"")  # second
    sha.update(struct.pack("<I", 0))
    sha.update(univ_qcdt)
    sha.update(struct.pack("<I", len(univ_qcdt)))
    digest = sha.digest()
    new_boot_raw[576 : 576 + len(digest)] = digest

    # 填充到 32MB 分区大小
    new_boot_padded = pad_to_size(bytes(new_boot_raw), args.partition_bytes)

    out_dir = output_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    # 写入文件
    raw_path = out_dir / "boot-raw.img"
    img_path = out_dir / "boot.img"
    bin_path = out_dir / "boot"

    raw_path.write_bytes(new_boot_raw)
    img_path.write_bytes(new_boot_padded)
    bin_path.write_bytes(new_boot_padded)

    print(f"[OK] 生成完成:")
    print(f"  - boot-raw.img: {len(new_boot_raw)} 字节 (SHA256: {sha256_file(raw_path)})")
    print(f"  - boot.img:     {len(new_boot_padded)} 字节 (SHA256: {sha256_file(img_path)})")
    print(f"  - boot:         {len(new_boot_padded)} 字节 (SHA256: {sha256_file(bin_path)})")


if __name__ == "__main__":
    main()
