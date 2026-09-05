#!/usr/bin/env python3
"""使用原厂匹配记录为单个主线 DTB 构建 Qualcomm QCDT v3。"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path

from analyze_bootimg import (
    QCDT_MAGIC,
    align,
    find_fdt_blobs,
    parse_boot_header,
    parse_qcdt_entries,
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build_qcdt_v3(records: list[dict], dtb: bytes, page_size: int) -> bytes:
    if not records:
        raise ValueError("QCDT 记录不能为空")
    if dtb[:4] != b"\xd0\x0d\xfe\xed":
        raise ValueError("输入不是有效的 FDT blob")

    table_size = 12 + 40 * len(records) + 4
    dtb_offset = align(table_size, page_size)
    dtb_padded_size = align(len(dtb), page_size)
    output = bytearray(struct.pack("<4sII", QCDT_MAGIC, 3, len(records)))
    for record in records:
        output.extend(
            struct.pack(
                "<IIIIIIIIII",
                int(record["platform_id"]),
                int(record["variant_id"]),
                int(record["board_hw_subtype"]),
                int(record["soc_rev"]),
                int(record["pmic0"]),
                int(record["pmic1"]),
                int(record["pmic2"]),
                int(record["pmic3"]),
                dtb_offset,
                dtb_padded_size,
            )
        )
    output.extend(struct.pack("<I", 0))
    output.extend(bytes(dtb_offset - len(output)))
    output.extend(dtb)
    output.extend(bytes(dtb_padded_size - len(dtb)))
    return bytes(output)


def extract_stock_records(stock_boot: bytes, platform_id: int) -> tuple[list[dict], int]:
    header = parse_boot_header(stock_boot)
    page_size = int(header["page_size"])
    qcdt_start = int(header["qcdt_offset"])
    qcdt_size = int(header["qcdt_size"])
    qcdt = stock_boot[qcdt_start : qcdt_start + qcdt_size]
    blobs = find_fdt_blobs(qcdt)
    blob_indexes = {item["offset"]: index for index, item in enumerate(blobs)}
    parsed = parse_qcdt_entries(qcdt, blob_indexes)
    if parsed.get("version") != 3:
        raise ValueError("原厂 boot image 的 QCDT 不是 v3")

    records = [
        record
        for record in parsed["entries"]
        if int(record["platform_id"]) == platform_id
    ]
    if not records:
        raise ValueError(f"原厂 QCDT 没有 platform_id={platform_id} 的记录")
    keys = {
        tuple(
            int(record[name])
            for name in (
                "platform_id",
                "variant_id",
                "board_hw_subtype",
                "soc_rev",
                "pmic0",
                "pmic1",
                "pmic2",
                "pmic3",
            )
        )
        for record in records
    }
    if len(keys) != len(records):
        raise ValueError("筛选后的原厂 QCDT 存在重复匹配记录")
    return records, page_size


def main() -> None:
    project_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--stock-boot",
        type=Path,
        default=project_root / "resource/backup/19.boot.img",
    )
    parser.add_argument(
        "--dtb",
        type=Path,
        default=project_root / "out/mainline/kernel/qcom-msm8909-zu02-dw01.dtb",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=project_root / "out/mainline/debian-cache/qcdt-zu02-dw01.img",
    )
    parser.add_argument("--platform-id", type=int, default=245)
    args = parser.parse_args()

    stock_path = args.stock_boot.resolve()
    dtb_path = args.dtb.resolve()
    output_path = args.out.resolve()
    stock_boot = stock_path.read_bytes()
    dtb = dtb_path.read_bytes()
    records, page_size = extract_stock_records(stock_boot, args.platform_id)
    output = build_qcdt_v3(records, dtb, page_size)

    blobs = find_fdt_blobs(output)
    parsed = parse_qcdt_entries(
        output, {item["offset"]: index for index, item in enumerate(blobs)}
    )
    if parsed.get("version") != 3 or len(parsed["entries"]) != len(records):
        raise ValueError("输出 QCDT 的版本或记录数不符合预期")
    if len(blobs) != 1:
        raise ValueError("输出 QCDT 必须只包含一个 DTB")
    if any(record.get("blob_index") != 0 for record in parsed["entries"]):
        raise ValueError("输出 QCDT 并非所有记录都指向唯一 DTB")
    blob = blobs[0]
    if output[blob["offset"] : blob["offset"] + blob["size"]] != dtb:
        raise ValueError("输出 QCDT 中的 DTB 与输入不一致")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(output)
    manifest = {
        "stock_boot": str(stock_path),
        "stock_boot_sha256": sha256(stock_boot),
        "dtb": str(dtb_path),
        "dtb_sha256": sha256(dtb),
        "platform_id": args.platform_id,
        "page_size": page_size,
        "qcdt_version": 3,
        "qcdt_record_count": len(records),
        "qcdt_unique_dtb_count": 1,
        "output": str(output_path),
        "output_sha256": sha256(output),
    }
    output_path.with_suffix(output_path.suffix + ".json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"原厂 MSM8909 QCDT 记录：{len(records)}")
    print(f"输出唯一 DW01 DTB：{len(blobs)}")
    print(f"输出：{output_path}")
    print(f"SHA256：{manifest['output_sha256']}")


if __name__ == "__main__":
    main()
