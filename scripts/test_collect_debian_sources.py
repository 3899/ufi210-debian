import hashlib
from pathlib import Path
import tarfile
import tempfile
import unittest

from scripts.collect_debian_sources import (
    SourceCollectionError,
    create_archive,
    encoded_version,
    hash_file,
    parse_dsc_checksums,
    parse_source_packages,
    verify_collection,
    write_manifest,
)


class CollectDebianSourcesTests(unittest.TestCase):
    def test_parse_source_packages(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "source-packages.txt"
            path.write_text("busybox\t1:1.35.0-4+deb12u1\napt\t2.6.1\n", encoding="utf-8")
            self.assertEqual(
                parse_source_packages(path),
                [("apt", "2.6.1"), ("busybox", "1:1.35.0-4+deb12u1")],
            )

    def test_rejects_duplicate_and_path_like_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "source-packages.txt"
            path.write_text("busybox\t1.0\nbusybox\t2.0\n", encoding="utf-8")
            with self.assertRaises(SourceCollectionError):
                parse_source_packages(path)
            path.write_text("busybox\t../1.0\n", encoding="utf-8")
            with self.assertRaises(SourceCollectionError):
                parse_source_packages(path)

    def test_parse_dsc_checksums(self):
        content = """-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

Format: 3.0 (quilt)
Checksums-Sha1:
 1111111111111111111111111111111111111111 12 package.orig.tar.xz
Checksums-Sha256:
 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 12 package.orig.tar.xz
Files:
 00000000000000000000000000000000 12 package.orig.tar.xz
-----BEGIN PGP SIGNATURE-----
"""
        self.assertEqual(
            parse_dsc_checksums(content, "Checksums-Sha1", 40),
            {"1" * 40: (12, "package.orig.tar.xz")},
        )
        self.assertEqual(
            parse_dsc_checksums(content, "Checksums-Sha256", 64),
            {"a" * 64: (12, "package.orig.tar.xz")},
        )

    def test_verify_and_deterministic_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "sources"
            version = "1:1.35.0-4+deb12u1"
            source_file = output / "files" / "busybox" / encoded_version(version) / "busybox.dsc"
            source_file.parent.mkdir(parents=True)
            source_file.write_bytes(b"source-data\n")
            sha256, sha1, size = hash_file(source_file)
            (output / "source-packages.txt").write_text(
                f"busybox\t{version}\n", encoding="utf-8", newline="\n"
            )
            write_manifest(
                output,
                [(sha256, sha1, size, source_file.relative_to(output).as_posix(), "busybox", version)],
            )
            self.assertEqual(verify_collection(output), 1)
            first = root / "first.tar.xz"
            second = root / "second.tar.xz"
            create_archive(output, first, "rc-test", 1781860238)
            create_archive(output, second, "rc-test", 1781860238)
            self.assertEqual(hashlib.sha256(first.read_bytes()).digest(), hashlib.sha256(second.read_bytes()).digest())
            with tarfile.open(first, "r:xz") as archive:
                names = archive.getnames()
            self.assertIn(
                "ufi210-debian-debian-sources-rc-test/source-packages.txt",
                names,
            )
            source_file.write_bytes(b"tampered\n")
            with self.assertRaises(SourceCollectionError):
                verify_collection(output)


if __name__ == "__main__":
    unittest.main()
