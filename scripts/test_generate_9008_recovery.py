#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zlib


SCRIPT = Path(__file__).with_name("generate_9008_recovery.py")
SPEC = importlib.util.spec_from_file_location("generate_9008_recovery", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def make_primary_gpt() -> bytes:
    disk_sectors = 10000
    backup_lba = disk_sectors - 1
    last_usable_lba = backup_lba - 33
    entry_count = 32
    entry_size = 128
    entries = bytearray(entry_count * entry_size)
    entries[0:16] = bytes.fromhex("a2a0d0ebe5b9334487c068b6b72699c7")
    entries[16:32] = bytes.fromhex("7c63c545025406820a0adbd2611d6ce0")
    struct.pack_into("<QQQ", entries, 32, 2048, 4095, 0)
    entries[56 : 56 + len("system".encode("utf-16le"))] = "system".encode("utf-16le")

    header = bytearray(512)
    header[:8] = b"EFI PART"
    struct.pack_into("<I", header, 8, 0x00010000)
    struct.pack_into("<I", header, 12, 92)
    struct.pack_into("<QQQQ", header, 24, 1, backup_lba, 34, last_usable_lba)
    header[56:72] = bytes.fromhex("00112233445566778899aabbccddeeff")
    struct.pack_into("<QIII", header, 72, 2, entry_count, entry_size, zlib.crc32(entries))
    struct.pack_into("<I", header, 16, zlib.crc32(header[:92]))

    primary = bytearray(34 * 512)
    primary[510:512] = b"\x55\xaa"
    primary[512:1024] = header
    primary[1024 : 1024 + len(entries)] = entries
    return bytes(primary)


class BackupGptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.primary = make_primary_gpt()
        self.directory = tempfile.TemporaryDirectory()
        self.primary_path = Path(self.directory.name) / "primary.bin"
        self.primary_path.write_bytes(self.primary)
        self.metadata, self.header, _ = MODULE.parse_and_validate_gpt(self.primary_path)

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_qualcomm_backup_entries_start_after_last_usable_lba(self) -> None:
        backup = MODULE.build_backup_gpt(self.metadata, self.header, self.primary)
        self.assertEqual(len(backup), 33 * 512)
        self.assertEqual(backup[: 8 * 512], self.primary[2 * 512 : 10 * 512])
        self.assertEqual(backup[8 * 512 : 32 * 512], bytes(24 * 512))
        self.assertEqual(MODULE.u64(backup[-512:], 72), self.metadata["last_usable_lba"] + 1)

        backup_path = Path(self.directory.name) / "backup.bin"
        backup_path.write_bytes(backup)
        self.assertEqual(
            MODULE.validate_backup_gpt(
                backup_path, self.metadata, self.header, self.primary
            ),
            backup,
        )

    def test_backup_header_corruption_is_rejected(self) -> None:
        backup = bytearray(MODULE.build_backup_gpt(self.metadata, self.header, self.primary))
        backup[-492] ^= 1
        backup_path = Path(self.directory.name) / "backup-corrupt.bin"
        backup_path.write_bytes(backup)
        with self.assertRaisesRegex(ValueError, "header CRC"):
            MODULE.validate_backup_gpt(
                backup_path, self.metadata, self.header, self.primary
            )

    def test_private_device_baseline_matches_when_available(self) -> None:
        project_root = SCRIPT.parents[1]
        primary_path = project_root / "resource/backup/gpt-20260907/gpt-primary.bin"
        backup_path = project_root / "resource/backup/gpt-20260907/gpt-backup.bin"
        if not primary_path.is_file() or not backup_path.is_file():
            self.skipTest("本机没有设备专属 GPT 回读文件")
        metadata, header, _ = MODULE.parse_and_validate_gpt(primary_path)
        primary = primary_path.read_bytes()
        backup = MODULE.validate_backup_gpt(backup_path, metadata, header, primary)
        self.assertEqual(MODULE.build_backup_gpt(metadata, header, primary), backup)


if __name__ == "__main__":
    unittest.main()
