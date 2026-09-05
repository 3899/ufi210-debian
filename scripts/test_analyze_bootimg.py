#!/usr/bin/env python3

import importlib.util
import struct
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("analyze_bootimg.py")
SPEC = importlib.util.spec_from_file_location("analyze_bootimg", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ParseQcdtEntriesTests(unittest.TestCase):
    def test_version_1_entry(self) -> None:
        entry = struct.pack("<5I", 245, 8, 0x100, 0x800, 0x800)
        qcdt = b"QCDT" + struct.pack("<2I", 1, 1) + entry

        result = MODULE.parse_qcdt_entries(qcdt, {0x800: 3})

        self.assertEqual(result["version"], 1)
        self.assertEqual(result["entries"][0]["variant_id"], 8)
        self.assertEqual(result["entries"][0]["blob_index"], 3)

    def test_version_2_entry_has_subtype_and_24_byte_stride(self) -> None:
        entries = b"".join(
            [
                struct.pack("<6I", 245, 8, 0x100, 0, 0x800, 0x800),
                struct.pack("<6I", 245, 0x1000B, 9, 0x20000, 0x1000, 0x800),
            ]
        )
        qcdt = b"QCDT" + struct.pack("<2I", 2, 2) + entries

        result = MODULE.parse_qcdt_entries(qcdt, {0x800: 0, 0x1000: 1})

        self.assertEqual(result["version"], 2)
        self.assertEqual(result["count"], 2)
        self.assertEqual(result["entries"][0]["variant_id"], 8)
        self.assertEqual(result["entries"][1]["variant_id"], 0x1000B)
        self.assertEqual(result["entries"][1]["board_hw_subtype"], 9)
        self.assertEqual(result["entries"][1]["soc_rev"], 0x20000)
        self.assertEqual(result["entries"][1]["blob_index"], 1)

    def test_version_3_entry(self) -> None:
        fields = (245, 65547, 9, 0, 65549, 0, 0, 0, 0x1800, 0x26000)
        qcdt = b"QCDT" + struct.pack("<2I", 3, 1) + struct.pack("<10I", *fields)

        result = MODULE.parse_qcdt_entries(qcdt, {0x1800: 7})

        entry = result["entries"][0]
        self.assertEqual(entry["variant_id"], 65547)
        self.assertEqual(entry["board_hw_subtype"], 9)
        self.assertEqual(entry["pmic0"], 65549)
        self.assertEqual(entry["blob_index"], 7)


if __name__ == "__main__":
    unittest.main()
