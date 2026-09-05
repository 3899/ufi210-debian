#!/usr/bin/env python3
"""
Extract and summarize Qualcomm Android boot images with QCDT device-tree tables.

This script is intentionally dependency-light. It can parse Android boot image v0
headers, extract the kernel/ramdisk/QCDT area, split unique FDT blobs from QCDT,
and read a small set of root-node DT properties without requiring dtc. If dtc is
available, it also decompiles DTBs to DTS for manual inspection.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
from pathlib import Path
from typing import Any


BOOT_MAGIC = b"ANDROID!"
QCDT_MAGIC = b"QCDT"
FDT_MAGIC = b"\xd0\x0d\xfe\xed"

FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9


def align(value: int, page_size: int) -> int:
    return (value + page_size - 1) // page_size * page_size


def u32le(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def u16be(data: bytes, offset: int) -> int:
    return struct.unpack_from(">H", data, offset)[0]


def u32be(data: bytes, offset: int) -> int:
    return struct.unpack_from(">I", data, offset)[0]


def align4(value: int) -> int:
    return (value + 3) & ~3


def cstr(data: bytes) -> str:
    return data.split(b"\0", 1)[0].decode("ascii", "replace")


def str_list(data: bytes) -> list[str]:
    if not data:
        return []
    return [
        part.decode("ascii", "replace")
        for part in data.rstrip(b"\0").split(b"\0")
        if part
    ]


def cells(data: bytes) -> list[int] | None:
    if len(data) % 4:
        return None
    return [u32be(data, i) for i in range(0, len(data), 4)]


def slug(value: str, fallback: str) -> str:
    value = value.lower()
    value = value.replace("qualcomm technologies, inc.", "")
    value = value.replace("qualcomm", "")
    value = re.sub(r"[^a-z0-9]+", "-", value)
    value = value.strip("-")
    return value[:80] or fallback


def parse_boot_header(image: bytes) -> dict[str, Any]:
    if image[:8] != BOOT_MAGIC:
        raise SystemExit("not an Android boot image: missing ANDROID! magic")

    page_size = u32le(image, 36)
    if page_size <= 0 or page_size > 65536:
        raise SystemExit(f"invalid page size: {page_size}")

    header = {
        "magic": "ANDROID!",
        "kernel_size": u32le(image, 8),
        "kernel_addr": u32le(image, 12),
        "ramdisk_size": u32le(image, 16),
        "ramdisk_addr": u32le(image, 20),
        "second_size": u32le(image, 24),
        "second_addr": u32le(image, 28),
        "tags_addr": u32le(image, 32),
        "page_size": page_size,
        "qcdt_size_or_unused0": u32le(image, 40),
        "unused1_or_os_version": u32le(image, 44),
        "name": cstr(image[48:64]),
        "cmdline": cstr(image[64:64 + 512]) + cstr(image[608:608 + 1024]),
    }

    kernel_offset = page_size
    ramdisk_offset = kernel_offset + align(header["kernel_size"], page_size)
    second_offset = ramdisk_offset + align(header["ramdisk_size"], page_size)
    qcdt_offset = second_offset + align(header["second_size"], page_size)

    header.update({
        "kernel_offset": kernel_offset,
        "ramdisk_offset": ramdisk_offset,
        "second_offset": second_offset,
        "qcdt_offset": qcdt_offset,
        "qcdt_size": header["qcdt_size_or_unused0"],
    })
    return header


def parse_root_props(blob: bytes) -> dict[str, Any]:
    if blob[:4] != FDT_MAGIC:
        return {}

    totalsize = u32be(blob, 4)
    off_struct = u32be(blob, 8)
    off_strings = u32be(blob, 12)
    if totalsize > len(blob) or off_struct >= len(blob) or off_strings >= len(blob):
        return {}

    struct_block = blob[off_struct:totalsize]
    strings = blob[off_strings:totalsize]
    p = 0
    depth = -1
    path: list[str] = []
    props: dict[str, Any] = {}
    wanted = {
        "model",
        "compatible",
        "qcom,msm-id",
        "qcom,board-id",
        "qcom,pmic-id",
        "qcom,hardware-id",
    }

    while p + 4 <= len(struct_block):
        token = u32be(struct_block, p)
        p += 4
        if token == FDT_BEGIN_NODE:
            end = struct_block.find(b"\0", p)
            if end < 0:
                break
            name = struct_block[p:end].decode("ascii", "replace")
            p = align4(end + 1)
            depth += 1
            path.append(name)
        elif token == FDT_END_NODE:
            if path:
                path.pop()
            depth -= 1
        elif token == FDT_PROP:
            if p + 8 > len(struct_block):
                break
            length = u32be(struct_block, p)
            nameoff = u32be(struct_block, p + 4)
            p += 8
            data = struct_block[p:p + length]
            p = align4(p + length)
            name_end = strings.find(b"\0", nameoff)
            if name_end < 0:
                continue
            prop_name = strings[nameoff:name_end].decode("ascii", "replace")
            if depth == 0 and prop_name in wanted:
                if prop_name in {"model", "compatible"}:
                    props[prop_name] = str_list(data)
                else:
                    props[prop_name] = cells(data)
        elif token == FDT_NOP:
            continue
        elif token == FDT_END:
            break
        else:
            break
    return props


def find_fdt_blobs(qcdt: bytes) -> list[dict[str, int]]:
    blobs: list[dict[str, int]] = []
    i = 0
    while True:
        pos = qcdt.find(FDT_MAGIC, i)
        if pos < 0:
            break
        if pos + 8 <= len(qcdt):
            total_size = u32be(qcdt, pos + 4)
            if 0 < total_size <= len(qcdt) - pos:
                blobs.append({"offset": pos, "size": total_size})
        i = pos + 4
    return blobs


def parse_qcdt_entries(qcdt: bytes, blob_index_by_offset: dict[int, int]) -> dict[str, Any]:
    if qcdt[:4] != QCDT_MAGIC:
        return {"magic": qcdt[:4].hex(), "entries": []}

    version = u32le(qcdt, 4)
    count = u32le(qcdt, 8)
    if version >= 3:
        entry_size = 40
    elif version == 2:
        entry_size = 24
    else:
        entry_size = 20
    start = 12
    entries = []

    if start + count * entry_size > len(qcdt):
        return {"magic": "QCDT", "version": version, "count": count, "entries": entries}

    for idx in range(count):
        off = start + idx * entry_size
        if entry_size == 40:
            fields = struct.unpack_from("<10I", qcdt, off)
            dtb_offset = fields[8]
            dtb_size = fields[9]
            entry = {
                "entry_index": idx,
                "platform_id": fields[0],
                "variant_id": fields[1],
                "board_hw_subtype": fields[2],
                "soc_rev": fields[3],
                "pmic0": fields[4],
                "pmic1": fields[5],
                "pmic2": fields[6],
                "pmic3": fields[7],
                "dtb_offset": dtb_offset,
                "dtb_padded_size": dtb_size,
                "blob_index": blob_index_by_offset.get(dtb_offset),
            }
        elif entry_size == 24:
            fields = struct.unpack_from("<6I", qcdt, off)
            dtb_offset = fields[4]
            dtb_size = fields[5]
            entry = {
                "entry_index": idx,
                "platform_id": fields[0],
                "variant_id": fields[1],
                "board_hw_subtype": fields[2],
                "soc_rev": fields[3],
                "dtb_offset": dtb_offset,
                "dtb_padded_size": dtb_size,
                "blob_index": blob_index_by_offset.get(dtb_offset),
            }
        else:
            fields = struct.unpack_from("<5I", qcdt, off)
            dtb_offset = fields[3]
            dtb_size = fields[4]
            entry = {
                "entry_index": idx,
                "platform_id": fields[0],
                "variant_id": fields[1],
                "soc_rev": fields[2],
                "dtb_offset": dtb_offset,
                "dtb_padded_size": dtb_size,
                "blob_index": blob_index_by_offset.get(dtb_offset),
            }
        entries.append(entry)

    return {"magic": "QCDT", "version": version, "count": count, "entries": entries}


def write_csv(path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in fieldnames})


def maybe_decompile(dtb_path: Path, dts_path: Path) -> bool:
    dtc = shutil.which("dtc")
    if not dtc:
        return False
    subprocess.run(
        [dtc, "-I", "dtb", "-O", "dts", "-o", str(dts_path), str(dtb_path)],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return dts_path.exists()


def build_markdown(header: dict[str, Any], qcdt_summary: dict[str, Any], blobs: list[dict[str, Any]]) -> str:
    lines = [
        "# boot.img / QCDT 提取报告",
        "",
        "## Android boot header",
        "",
        f"- page size: `{header['page_size']}`",
        f"- kernel size: `{header['kernel_size']}`",
        f"- ramdisk size: `{header['ramdisk_size']}`",
        f"- QCDT offset: `{header['qcdt_offset']}`",
        f"- QCDT size: `{header['qcdt_size']}`",
        f"- cmdline: `{header['cmdline']}`",
        "",
        "## QCDT",
        "",
        f"- magic: `{qcdt_summary.get('magic')}`",
        f"- version: `{qcdt_summary.get('version')}`",
        f"- entries: `{qcdt_summary.get('count')}`",
        f"- unique FDT blobs: `{len(blobs)}`",
        "",
        "## DTB 列表",
        "",
        "| blob | 文件 | model | compatible | qcom,board-id | qcom,pmic-id |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for blob in blobs:
        props = blob.get("root_props", {})
        model = ", ".join(props.get("model", []))
        compatible = ", ".join(props.get("compatible", []))
        board_id = props.get("qcom,board-id", "")
        pmic_id = props.get("qcom,pmic-id", "")
        lines.append(
            f"| {blob['blob_index']} | `{blob['filename']}` | {model} | {compatible} | `{board_id}` | `{pmic_id}` |"
        )

    named_board_blobs = []
    for blob in blobs:
        props = blob.get("root_props", {})
        searchable = " ".join(
            [
                blob.get("filename", ""),
                *props.get("model", []),
                *props.get("compatible", []),
            ]
        ).lower()
        if "zu02" in searchable or "dw01" in searchable:
            named_board_blobs.append(blob["filename"])

    if named_board_blobs:
        board_finding = "- 发现 ZU02/DW01 命名的 DTB：" + ", ".join(
            f"`{filename}`" for filename in named_board_blobs
        ) + "。"
    else:
        board_finding = "- 未发现 ZU02 或 DW01 命名的 DTB。"

    lines += [
        "",
        "## 初步判断",
        "",
        board_finding,
        "- QCDT 列出的是镜像内可供 bootloader 匹配的候选 DTB。",
        "- 仅凭 QCDT 表不能证明实机最终选择了哪一个条目，仍需结合运行时板级 ID。",
    ]
    return "\n".join(lines) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--boot", default="resource/backup/19.boot.img", help="Android boot image path")
    ap.add_argument("--out", default="out/boot-analysis", help="output directory")
    ap.add_argument("--no-decompile", action="store_true", help="do not run dtc even when available")
    args = ap.parse_args()

    boot_path = Path(args.boot)
    out_dir = Path(args.out)
    dtb_dir = out_dir / "dtb"
    dts_dir = out_dir / "dts"
    out_dir.mkdir(parents=True, exist_ok=True)
    dtb_dir.mkdir(parents=True, exist_ok=True)
    dts_dir.mkdir(parents=True, exist_ok=True)

    image = boot_path.read_bytes()
    header = parse_boot_header(image)

    kernel = image[header["kernel_offset"]:header["kernel_offset"] + header["kernel_size"]]
    ramdisk = image[header["ramdisk_offset"]:header["ramdisk_offset"] + header["ramdisk_size"]]
    qcdt = image[header["qcdt_offset"]:header["qcdt_offset"] + header["qcdt_size"]]

    (out_dir / "kernel").write_bytes(kernel)
    (out_dir / "ramdisk.img").write_bytes(ramdisk)
    (out_dir / "qcdt.img").write_bytes(qcdt)
    (out_dir / "cmdline.txt").write_text(header["cmdline"] + "\n", encoding="utf-8")
    (out_dir / "boot-header.json").write_text(
        json.dumps(header, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    raw_blobs = find_fdt_blobs(qcdt)
    blob_index_by_offset = {item["offset"]: idx for idx, item in enumerate(raw_blobs)}
    qcdt_summary = parse_qcdt_entries(qcdt, blob_index_by_offset)

    blobs: list[dict[str, Any]] = []
    seen_hashes: dict[str, int] = {}
    for raw_index, item in enumerate(raw_blobs):
        blob = qcdt[item["offset"]:item["offset"] + item["size"]]
        sha = hashlib.sha256(blob).hexdigest()
        if sha in seen_hashes:
            continue
        props = parse_root_props(blob)
        model = ", ".join(props.get("model", []))
        filename = f"dtb_{len(blobs):02d}_{slug(model, f'blob-{raw_index}')}.dtb"
        dtb_path = dtb_dir / filename
        dtb_path.write_bytes(blob)
        dts_name = filename[:-4] + ".dts"
        decompiled = False
        if not args.no_decompile:
            decompiled = maybe_decompile(dtb_path, dts_dir / dts_name)
        entry = {
            "blob_index": len(blobs),
            "qcdt_offset": item["offset"],
            "size": item["size"],
            "sha256": sha,
            "filename": filename,
            "dts_filename": dts_name if decompiled else "",
            "root_props": props,
        }
        blobs.append(entry)
        seen_hashes[sha] = entry["blob_index"]

    summary = {
        "boot_image": str(boot_path),
        "header": header,
        "qcdt": qcdt_summary,
        "dtb_blobs": blobs,
    }
    (out_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    write_csv(
        out_dir / "qcdt-entries.csv",
        qcdt_summary.get("entries", []),
        [
            "entry_index",
            "platform_id",
            "variant_id",
            "board_hw_subtype",
            "soc_rev",
            "pmic0",
            "pmic1",
            "pmic2",
            "pmic3",
            "dtb_offset",
            "dtb_padded_size",
            "blob_index",
        ],
    )
    write_csv(
        out_dir / "dtb-blobs.csv",
        [
            {
                "blob_index": blob["blob_index"],
                "filename": blob["filename"],
                "dts_filename": blob["dts_filename"],
                "size": blob["size"],
                "qcdt_offset": blob["qcdt_offset"],
                "model": ", ".join(blob["root_props"].get("model", [])),
                "compatible": ", ".join(blob["root_props"].get("compatible", [])),
                "qcom_board_id": blob["root_props"].get("qcom,board-id"),
                "qcom_pmic_id": blob["root_props"].get("qcom,pmic-id"),
            }
            for blob in blobs
        ],
        [
            "blob_index",
            "filename",
            "dts_filename",
            "size",
            "qcdt_offset",
            "model",
            "compatible",
            "qcom_board_id",
            "qcom_pmic_id",
        ],
    )
    (out_dir / "REPORT.md").write_text(build_markdown(header, qcdt_summary, blobs), encoding="utf-8")

    print(f"wrote {out_dir}")
    print(f"unique dtb blobs: {len(blobs)}")
    print(f"qcdt entries: {qcdt_summary.get('count')}")
    if not shutil.which("dtc"):
        print("dtc not found; DTS decompile skipped")


if __name__ == "__main__":
    main()
