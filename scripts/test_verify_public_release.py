#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
import zipfile


MODULE_PATH = Path(__file__).with_name("verify_public_release.py")
SPEC = importlib.util.spec_from_file_location("verify_public_release", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class PublicReleaseVerificationTests(unittest.TestCase):
    def test_parse_checksum_manifest_requires_exact_names(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "SHA256SUMS"
            manifest.write_text("a" * 64 + "  release.zip\n", encoding="ascii")
            self.assertEqual(
                MODULE.parse_checksum_manifest(manifest, {"release.zip"}),
                {"release.zip": "a" * 64},
            )
            with self.assertRaises(MODULE.ReleaseVerificationError):
                MODULE.parse_checksum_manifest(manifest, {"other.zip"})

    def test_tar_extraction_rejects_parent_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "bad.tar.xz"
            with tarfile.open(archive_path, "w:xz") as archive:
                member = tarfile.TarInfo("release/../../escaped")
                content = b"bad"
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
            with self.assertRaises(MODULE.ReleaseVerificationError):
                MODULE.extract_tar_archive(archive_path, root / "out", "release")

    def test_zip_extraction_rejects_duplicate_members(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "bad.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("release/file", b"first")
                archive.writestr("release/file", b"second")
            with self.assertRaises(MODULE.ReleaseVerificationError):
                MODULE.extract_zip_archive(archive_path, root / "out", "release")

    def test_tar_extraction_accepts_safe_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "good.tar.xz"
            with tarfile.open(archive_path, "w:xz") as archive:
                directory = tarfile.TarInfo("release/")
                directory.type = tarfile.DIRTYPE
                archive.addfile(directory)
                member = tarfile.TarInfo("release/file")
                content = b"ok"
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
            extracted = MODULE.extract_tar_archive(
                archive_path, root / "out", "release"
            )
            self.assertEqual((extracted / "file").read_bytes(), b"ok")

    def test_tar_extraction_accepts_in_tree_relative_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "links.tar.xz"
            with tarfile.open(archive_path, "w:xz") as archive:
                member = tarfile.TarInfo("release/scripts/syscall.tbl")
                content = b"table"
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
                link = tarfile.TarInfo("release/arch/arm64/tools/syscall_64.tbl")
                link.type = tarfile.SYMTYPE
                link.linkname = "../../../scripts/syscall.tbl"
                archive.addfile(link)
            extracted = MODULE.extract_tar_archive(
                archive_path, root / "out", "release"
            )
            self.assertEqual(
                (extracted / "arch/arm64/tools/syscall_64.tbl").read_bytes(), b"table"
            )

    def test_tar_extraction_rejects_escaping_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "bad-link.tar.xz"
            with tarfile.open(archive_path, "w:xz") as archive:
                link = tarfile.TarInfo("release/link")
                link.type = tarfile.SYMTYPE
                link.linkname = "../../escaped"
                archive.addfile(link)
            with self.assertRaises(MODULE.ReleaseVerificationError):
                MODULE.extract_tar_archive(archive_path, root / "out", "release")


if __name__ == "__main__":
    unittest.main()
