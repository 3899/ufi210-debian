#!/usr/bin/env python3

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parent.parent
AUDITOR = PROJECT_ROOT / "scripts/audit_public_release.sh"


class PublicReleaseAuditTests(unittest.TestCase):
    def run_source_audit(
        self, content: str, environment: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary)
            (target / "README.md").write_text(content, encoding="utf-8")
            env = os.environ.copy()
            if environment:
                env.update(environment)
            return subprocess.run(
                ["bash", str(AUDITOR), "source", str(target)],
                cwd=PROJECT_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

    def test_accepts_generic_public_text(self) -> None:
        result = self.run_source_audit("# Debian for UFI210(msm8909)\n")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_rejects_marker_from_external_denylist(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            denylist = Path(temporary) / "denylist.txt"
            denylist.write_text("private-release-marker\n", encoding="utf-8")
            result = self.run_source_audit(
                "# private-release-marker\n",
                {"UFI210_RELEASE_DENYLIST": str(denylist)},
            )
        self.assertNotEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
