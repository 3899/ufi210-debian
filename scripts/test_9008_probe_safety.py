#!/usr/bin/env python3

from pathlib import Path
import unittest


SCRIPT = Path(__file__).with_name("probe_9008_programmer.ps1")


class ProgrammerProbeSafetyTests(unittest.TestCase):
    def test_probe_contains_only_read_and_reset_firehose_operations(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8").lower()
        self.assertEqual(text.count('"--getstorageinfo=0"'), 1)
        self.assertEqual(text.count('"--reset"'), 1)
        for forbidden in (
            '"--sendxml=',
            '"--erase=',
            '"--firmwarewrite"',
            '"--fixgpt=',
            '"--sendimage=',
        ):
            self.assertNotIn(forbidden, text)

    def test_probe_requires_explicit_confirmation_and_exact_disk_geometry(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("ConfirmNoWriteProbe", text)
        self.assertIn("ExpectedDiskSectors = 7569408L", text)
        self.assertIn("ExpectedSectorBytes = 512L", text)
        self.assertIn("ExpectedPhysicalPartitions = 3", text)


if __name__ == "__main__":
    unittest.main()
