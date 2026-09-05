#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parent.parent
AUDITOR = PROJECT_ROOT / "scripts/audit_public_release.sh"


class PublicReleaseAuditTests(unittest.TestCase):
    def run_source_audit(self, content: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary)
            (target / "README.md").write_text(content, encoding="utf-8")
            return subprocess.run(
                ["bash", str(AUDITOR), "source", str(target)],
                cwd=PROJECT_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

    def test_accepts_generic_public_text(self) -> None:
        result = self.run_source_audit("# Debian for UFI210(msm8909)\n")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_rejects_forbidden_historical_names(self) -> None:
        markers = (
            "jjss" + "520",
            "semi" + "finished",
            "compe" + "titor",
            "Open" + "Stick",
            "postmarket" + "OS",
            "mi" + "ko",
            "全" + "自研",
            "竞" + "品",
            "套" + "壳",
            "SimAdmin " + "项目",
        )
        for marker in markers:
            with self.subTest(marker=marker):
                result = self.run_source_audit(f"# {marker}\n")
                self.assertNotEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
