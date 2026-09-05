import hashlib
from pathlib import Path
import tempfile
import unittest
import zipfile

from scripts.create_deterministic_zip import ArchiveError, create_deterministic_zip


class DeterministicZipTests(unittest.TestCase):
    def test_archive_is_reproducible_and_has_one_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "ufi210-debian-zu02-dw01-rc-test"
            (source / "scripts").mkdir(parents=True)
            (source / "README.md").write_text("说明\n", encoding="utf-8")
            script = source / "scripts" / "verify.ps1"
            script.write_bytes(b"Write-Output ok\n")
            first = root / "first.zip"
            second = root / "second.zip"

            create_deterministic_zip(source, first, 1781860238)
            create_deterministic_zip(source, second, 1781860238)

            self.assertEqual(
                hashlib.sha256(first.read_bytes()).digest(),
                hashlib.sha256(second.read_bytes()).digest(),
            )
            with zipfile.ZipFile(first) as archive:
                self.assertEqual(
                    archive.namelist(),
                    [
                        "ufi210-debian-zu02-dw01-rc-test/",
                        "ufi210-debian-zu02-dw01-rc-test/README.md",
                        "ufi210-debian-zu02-dw01-rc-test/scripts/",
                        "ufi210-debian-zu02-dw01-rc-test/scripts/verify.ps1",
                    ],
                )
                self.assertEqual(
                    archive.read("ufi210-debian-zu02-dw01-rc-test/README.md"),
                    "说明\n".encode(),
                )

    def test_rejects_output_inside_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source"
            source.mkdir()
            with self.assertRaises(ArchiveError):
                create_deterministic_zip(source, source / "release.zip", 1781860238)


if __name__ == "__main__":
    unittest.main()
