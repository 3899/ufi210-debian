#!/usr/bin/env python3

from pathlib import Path
import unittest


SCRIPT = Path(__file__).with_name("test_debian_modem_interfaces.ps1")


class ModemInterfaceProbeSafetyTests(unittest.TestCase):
    def test_probe_uses_only_read_only_modem_operations(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8").lower()
        for required in (
            "--dms-get-operating-mode",
            "--nas-get-signal-strength",
            "--wms-get-routes",
            "--messaging-status",
        ):
            self.assertEqual(text.count(required), 1)

        for forbidden in (
            "--wms-send",
            "--wms-delete",
            "--wds-start-network",
            "--wds-stop-network",
            "--dms-set-operating-mode",
            "--nas-register-network",
            "--messaging-create-sms",
            "--messaging-delete-sms",
            "--messaging-send-sms",
        ):
            self.assertNotIn(forbidden, text)

    def test_probe_does_not_touch_device_partitions(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8").lower()
        for forbidden in (
            "fastboot",
            "qdl",
            "qfil",
            "rawprogram",
            "/dev/mmcblk",
            "/dev/disk/by-partlabel",
        ):
            self.assertNotIn(forbidden, text)


if __name__ == "__main__":
    unittest.main()
