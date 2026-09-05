#!/usr/bin/env python3
"""校验 ZU02 原厂分区备份并生成 QFIL rawprogram 文件。"""

from __future__ import annotations

import argparse
import json
import struct
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path


SECTOR_SIZE = 512
GPT_SIGNATURE = b"EFI PART"
OS_ONLY_PARTITIONS = {"boot", "system", "recovery"}
CACHE_TEST_PARTITIONS = OS_ONLY_PARTITIONS | {"cache"}
SENSITIVE_PARTITIONS = {"modem", "modemst1", "modemst2", "fsc", "fsg", "persist", "DDR"}


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def u64(data: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", data, offset)[0]


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def project_relative(path: Path, project_root: Path) -> str:
    return path.resolve().relative_to(project_root.resolve()).as_posix()


def parse_and_validate_gpt(primary_path: Path) -> tuple[dict[str, int], bytes, list[dict[str, int | str]]]:
    raw = primary_path.read_bytes()
    if len(raw) < 34 * SECTOR_SIZE:
        raise ValueError(f"主 GPT 文件过小：{len(raw)} 字节")

    header = raw[SECTOR_SIZE : 2 * SECTOR_SIZE]
    if header[:8] != GPT_SIGNATURE:
        raise ValueError("LBA1 没有 GPT 签名")

    header_size = u32(header, 12)
    if not 92 <= header_size <= SECTOR_SIZE:
        raise ValueError(f"GPT header_size 无效：{header_size}")

    stored_header_crc = u32(header, 16)
    header_for_crc = bytearray(header[:header_size])
    struct.pack_into("<I", header_for_crc, 16, 0)
    actual_header_crc = crc32(header_for_crc)
    if actual_header_crc != stored_header_crc:
        raise ValueError(
            f"GPT header CRC 不匹配：记录 0x{stored_header_crc:08x}，实际 0x{actual_header_crc:08x}"
        )

    current_lba = u64(header, 24)
    backup_lba = u64(header, 32)
    first_usable_lba = u64(header, 40)
    last_usable_lba = u64(header, 48)
    entries_lba = u64(header, 72)
    entry_count = u32(header, 80)
    entry_size = u32(header, 84)
    stored_entries_crc = u32(header, 88)
    if current_lba != 1 or entries_lba != 2:
        raise ValueError(f"不支持的 GPT 布局：header={current_lba}, entries={entries_lba}")
    if entry_size < 128 or entry_size % 8:
        raise ValueError(f"GPT entry_size 无效：{entry_size}")

    entries_length = entry_count * entry_size
    entries_start = entries_lba * SECTOR_SIZE
    entries = raw[entries_start : entries_start + entries_length]
    if len(entries) != entries_length:
        raise ValueError("主 GPT 文件没有包含完整分区表")
    actual_entries_crc = crc32(entries)
    if actual_entries_crc != stored_entries_crc:
        raise ValueError(
            f"GPT entries CRC 不匹配：记录 0x{stored_entries_crc:08x}，实际 0x{actual_entries_crc:08x}"
        )

    partitions: list[dict[str, int | str]] = []
    previous_last = first_usable_lba - 1
    for index in range(entry_count):
        entry = entries[index * entry_size : (index + 1) * entry_size]
        if entry[:16] == bytes(16):
            continue
        first_lba = u64(entry, 32)
        last_lba = u64(entry, 40)
        name = entry[56:entry_size].decode("utf-16le", errors="replace").rstrip("\0")
        if first_lba > last_lba or first_lba <= previous_last or last_lba > last_usable_lba:
            raise ValueError(f"分区 {name} 的 LBA 范围无效：{first_lba}-{last_lba}")
        partitions.append(
            {
                "index": index,
                "number": index + 1,
                "name": name,
                "first_lba": first_lba,
                "last_lba": last_lba,
                "sectors": last_lba - first_lba + 1,
            }
        )
        previous_last = last_lba

    metadata = {
        "header_size": header_size,
        "header_crc32": stored_header_crc,
        "entries_crc32": stored_entries_crc,
        "backup_lba": backup_lba,
        "disk_sectors": backup_lba + 1,
        "first_usable_lba": first_usable_lba,
        "last_usable_lba": last_usable_lba,
        "entry_count": entry_count,
        "entry_size": entry_size,
    }
    return metadata, header, partitions


def build_backup_gpt(metadata: dict[str, int], primary_header: bytes, primary_raw: bytes) -> bytes:
    entries_length = metadata["entry_count"] * metadata["entry_size"]
    entries = primary_raw[2 * SECTOR_SIZE : 2 * SECTOR_SIZE + entries_length]
    entry_sectors = (entries_length + SECTOR_SIZE - 1) // SECTOR_SIZE
    backup_entries_lba = metadata["backup_lba"] - entry_sectors
    backup_region_start = metadata["last_usable_lba"] + 1
    if backup_entries_lba < backup_region_start:
        raise ValueError("备 GPT 分区表与可用数据区重叠")

    backup_header = bytearray(primary_header)
    struct.pack_into("<Q", backup_header, 24, metadata["backup_lba"])
    struct.pack_into("<Q", backup_header, 32, 1)
    struct.pack_into("<Q", backup_header, 72, backup_entries_lba)
    struct.pack_into("<I", backup_header, 16, 0)
    header_size = metadata["header_size"]
    struct.pack_into("<I", backup_header, 16, crc32(backup_header[:header_size]))

    backup_region_sectors = metadata["backup_lba"] - backup_region_start + 1
    backup_region = bytearray(backup_region_sectors * SECTOR_SIZE)
    entries_offset = (backup_entries_lba - backup_region_start) * SECTOR_SIZE
    backup_region[entries_offset : entries_offset + len(entries)] = entries
    backup_region[-SECTOR_SIZE:] = backup_header
    return bytes(backup_region)


def find_partition_backups(backup_dir: Path, partitions: list[dict[str, int | str]]) -> None:
    files = [path for path in backup_dir.iterdir() if path.is_file()]
    for partition in partitions:
        prefix = f"{partition['index']}."
        matches = [path for path in files if path.name.startswith(prefix)]
        if len(matches) != 1:
            raise ValueError(f"分区 {partition['name']} 对应前缀 {prefix} 的备份数量为 {len(matches)}")
        backup = matches[0]
        expected_size = int(partition["sectors"]) * SECTOR_SIZE
        if backup.stat().st_size != expected_size:
            raise ValueError(
                f"{backup.name} 大小错误：{backup.stat().st_size}，GPT 预期 {expected_size}"
            )
        partition["backup"] = backup


def program_element(filename: str, label: str, start_lba: int, sectors: int) -> ET.Element:
    return ET.Element(
        "program",
        {
            "SECTOR_SIZE_IN_BYTES": str(SECTOR_SIZE),
            "file_sector_offset": "0",
            "filename": filename,
            "label": label,
            "num_partition_sectors": str(sectors),
            "physical_partition_number": "0",
            "sparse": "false",
            "start_sector": str(start_lba),
        },
    )


def write_xml(path: Path, elements: list[ET.Element], root_name: str = "data") -> None:
    root = ET.Element(root_name)
    root.extend(elements)
    tree = ET.ElementTree(root)
    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)


def main() -> None:
    project_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--primary-gpt",
        type=Path,
        default=project_root / "out/recovery-baseline/zu02-gpt-main.bin",
    )
    parser.add_argument(
        "--backup-dir",
        type=Path,
        default=project_root / "resource/backup",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=project_root / "out/recovery-baseline",
    )
    args = parser.parse_args()

    primary_path = args.primary_gpt.resolve()
    backup_dir = args.backup_dir.resolve()
    out_dir = args.out.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    metadata, primary_header, partitions = parse_and_validate_gpt(primary_path)
    primary_raw = primary_path.read_bytes()
    find_partition_backups(backup_dir, partitions)

    backup_gpt = build_backup_gpt(metadata, primary_header, primary_raw)
    backup_gpt_path = out_dir / "zu02-gpt-backup.bin"
    backup_gpt_path.write_bytes(backup_gpt)

    os_elements = []
    cache_test_elements = []
    full_elements = []
    for partition in partitions:
        backup_path = Path(partition["backup"])
        element = program_element(
            project_relative(backup_path, project_root),
            str(partition["name"]),
            int(partition["first_lba"]),
            int(partition["sectors"]),
        )
        full_elements.append(element)
        if partition["name"] in OS_ONLY_PARTITIONS:
            os_elements.append(
                program_element(
                    project_relative(backup_path, project_root),
                    str(partition["name"]),
                    int(partition["first_lba"]),
                    int(partition["sectors"]),
                )
            )
        if partition["name"] in CACHE_TEST_PARTITIONS:
            cache_test_elements.append(
                program_element(
                    project_relative(backup_path, project_root),
                    str(partition["name"]),
                    int(partition["first_lba"]),
                    int(partition["sectors"]),
                )
            )

    primary_sectors = len(primary_raw) // SECTOR_SIZE
    full_elements.extend(
        [
            program_element(
                project_relative(primary_path, project_root),
                "PrimaryGPT",
                0,
                primary_sectors,
            ),
            program_element(
                project_relative(backup_gpt_path, project_root),
                "BackupGPT",
                metadata["backup_lba"] - (len(backup_gpt) // SECTOR_SIZE) + 1,
                len(backup_gpt) // SECTOR_SIZE,
            ),
        ]
    )

    write_xml(out_dir / "rawprogram-zu02-android-os-only.xml", os_elements)
    write_xml(out_dir / "rawprogram-zu02-android-os-cache.xml", cache_test_elements)
    write_xml(out_dir / "rawprogram-zu02-full.xml", full_elements)
    write_xml(out_dir / "patch0-empty.xml", [], root_name="patches")

    manifest = {
        "disk_sectors": metadata["disk_sectors"],
        "disk_bytes": metadata["disk_sectors"] * SECTOR_SIZE,
        "primary_header_crc32": f"0x{metadata['header_crc32']:08x}",
        "partition_entries_crc32": f"0x{metadata['entries_crc32']:08x}",
        "partition_count": len(partitions),
        "partitions": [
            {
                "number": partition["number"],
                "name": partition["name"],
                "first_lba": partition["first_lba"],
                "sectors": partition["sectors"],
                "bytes": int(partition["sectors"]) * SECTOR_SIZE,
                "backup": project_relative(Path(partition["backup"]), project_root),
                "sensitive": partition["name"] in SENSITIVE_PARTITIONS,
            }
            for partition in partitions
        ],
    }
    (out_dir / "zu02-recovery-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"GPT CRC 校验通过，磁盘扇区数：{metadata['disk_sectors']}")
    print(f"已核验 {len(partitions)} 个分区备份，大小全部匹配")
    print(f"已生成：{out_dir / 'rawprogram-zu02-android-os-only.xml'}")
    print(f"已生成：{out_dir / 'rawprogram-zu02-android-os-cache.xml'}")
    print(f"已生成：{out_dir / 'rawprogram-zu02-full.xml'}")


if __name__ == "__main__":
    main()
