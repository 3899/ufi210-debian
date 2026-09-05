#!/usr/bin/env python3

import importlib.util
import struct
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("build_stock_qcdt.py")
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("build_stock_qcdt", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class BuildStockQcdtTests(unittest.TestCase):
    def test_builds_v3_table_with_one_shared_dtb(self) -> None:
        records = [
            {
                "platform_id": 245,
                "variant_id": 65547,
                "board_hw_subtype": 0,
                "soc_rev": revision,
                "pmic0": 65549,
                "pmic1": 0,
                "pmic2": 0,
                "pmic3": 0,
            }
            for revision in (0, 1)
        ]
        dtb = b"\xd0\x0d\xfe\xed" + struct.pack(">I", 12) + b"DTB!"
        output = MODULE.build_qcdt_v3(records, dtb, 2048)

        self.assertEqual(output[:4], b"QCDT")
        self.assertEqual(struct.unpack_from("<II", output, 4), (3, 2))
        first = struct.unpack_from("<10I", output, 12)
        second = struct.unpack_from("<10I", output, 52)
        self.assertEqual(first[8:], (2048, 2048))
        self.assertEqual(second[8:], (2048, 2048))
        self.assertEqual(output[2048 : 2048 + len(dtb)], dtb)

    def test_rejects_non_fdt_input(self) -> None:
        with self.assertRaisesRegex(ValueError, "FDT"):
            MODULE.build_qcdt_v3([{}], b"not-a-dtb", 2048)


if __name__ == "__main__":
    unittest.main()
