from pathlib import Path
import io
import tarfile
import tempfile
import unittest

from scripts.audit_rootfs_privacy import (
    EXPECTED_DEVICE_LINKS,
    RootfsPrivacyError,
    audit_rootfs_archive,
)


def add_file(archive: tarfile.TarFile, name: str, content: bytes) -> None:
    member = tarfile.TarInfo(name)
    member.size = len(content)
    member.mode = 0o644
    archive.addfile(member, io.BytesIO(content))


def add_symlink(archive: tarfile.TarFile, name: str, target: str) -> None:
    member = tarfile.TarInfo(name)
    member.type = tarfile.SYMTYPE
    member.linkname = target
    member.mode = 0o777
    archive.addfile(member)


def create_archive(path: Path, extra=None, replace_link=None) -> None:
    with tarfile.open(path, "w:xz") as archive:
        add_file(archive, "./etc/machine-id", b"")
        add_file(archive, "./etc/hostname", b"ufi210\n")
        add_file(archive, "./etc/issue", b"Debian GNU/Linux 12\n")
        for name, target in EXPECTED_DEVICE_LINKS.items():
            if replace_link and name == replace_link[0]:
                replacement_type, replacement_value = replace_link[1:]
                if replacement_type == "file":
                    add_file(archive, f"./{name}", replacement_value)
                else:
                    add_symlink(archive, f"./{name}", replacement_value.decode())
            else:
                add_symlink(archive, f"./{name}", target)
        if extra:
            add_file(archive, extra[0], extra[1])


class RootfsPrivacyAuditTests(unittest.TestCase):
    def test_accepts_generic_rootfs_with_device_partition_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "rootfs.tar.xz"
            create_archive(
                archive,
                ("./usr/lib/systemd/system/system-systemd\\x2dcryptsetup.slice", b"unit\n"),
            )
            result = audit_rootfs_archive(archive)
            self.assertEqual(result["device_links"], len(EXPECTED_DEVICE_LINKS))

    def test_rejects_nonempty_machine_id(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "rootfs.tar.xz"
            with tarfile.open(archive, "w:xz") as output:
                add_file(output, "./etc/machine-id", b"device-id\n")
                add_file(output, "./etc/hostname", b"ufi210\n")
                for name, target in EXPECTED_DEVICE_LINKS.items():
                    add_symlink(output, f"./{name}", target)
            with self.assertRaisesRegex(RootfsPrivacyError, "machine-id"):
                audit_rootfs_archive(archive)

    def test_rejects_generated_ssh_host_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "rootfs.tar.xz"
            create_archive(archive, ("./etc/ssh/ssh_host_ed25519_key", b"private"))
            with self.assertRaisesRegex(RootfsPrivacyError, "private state"):
                audit_rootfs_archive(archive)

    def test_rejects_embedded_device_firmware(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "rootfs.tar.xz"
            name = next(iter(EXPECTED_DEVICE_LINKS))
            create_archive(archive, replace_link=(name, "file", b"firmware"))
            with self.assertRaisesRegex(RootfsPrivacyError, "must be a symlink"):
                audit_rootfs_archive(archive)

    def test_rejects_local_development_marker(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "rootfs.tar.xz"
            create_archive(archive, ("./etc/motd", b"built in M:\\IDE\\msm8909\n"))
            with self.assertRaisesRegex(RootfsPrivacyError, "local development marker"):
                audit_rootfs_archive(archive)


if __name__ == "__main__":
    unittest.main()
