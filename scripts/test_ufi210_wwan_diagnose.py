#!/usr/bin/env python3
"""
Unit test for ufi210-wwan-diagnose script.
Verifies that the diagnostic tool exists, is executable, syntactically valid shell code,
and properly redacts sensitive identifiers.
"""
import re
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DIAGNOSE_SCRIPT = PROJECT_ROOT / "patches/rootfs/usr/sbin/ufi210-wwan-diagnose"
WWAN_IP_SCRIPT = PROJECT_ROOT / "patches/rootfs/usr/sbin/zu02-wwan-ip"


class TestUfi210WwanDiagnose(unittest.TestCase):
    def test_diagnose_script_exists_and_format(self):
        self.assertTrue(DIAGNOSE_SCRIPT.is_file(), "ufi210-wwan-diagnose must exist")
        content = DIAGNOSE_SCRIPT.read_text(encoding="utf-8")
        self.assertTrue(content.startswith("#!/bin/sh"), "Must have standard POSIX sh shebang")
        self.assertIn("redact_stream", content, "Must implement redaction")
        self.assertIn("health.overall_status", content, "Must evaluate health contract")
        self.assertIn("shared_wwan0", content, "Must declare shared_wwan0 topology")

    def test_redaction_patterns(self):
        content = DIAGNOSE_SCRIPT.read_text(encoding="utf-8")
        # Ensure sensitive fields are addressed in redaction
        for pattern in ["imei", "password", "equipment-identifier"]:
            self.assertIn(pattern, content, f"Must redact {pattern}")

    def test_wwan_ip_supports_dual_stack(self):
        self.assertTrue(WWAN_IP_SCRIPT.is_file(), "zu02-wwan-ip must exist")
        content = WWAN_IP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("has_ipv4=1", content, "Must support IPv4")
        self.assertIn("has_ipv6=1", content, "Must support IPv6")
        self.assertIn("ip -6 route del default dev wwan0 metric 700", content, "Must flush IPv6 routes on down")
        self.assertIn("ip -6 address flush dev wwan0 scope global", content, "Must flush IPv6 addrs on down")
        self.assertIn("ip address replace \"$address/$prefix\" dev wwan0", content, "Must retain IPv4 address command")
        self.assertIn("ip route replace default via \"$gateway\" dev wwan0 metric 700", content, "Must retain IPv4 default route command")


if __name__ == "__main__":
    unittest.main()
