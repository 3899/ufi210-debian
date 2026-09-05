#!/usr/bin/env python3
"""Audit a release rootfs tarball for device-specific or private state."""

from __future__ import annotations

import argparse
from pathlib import Path, PurePosixPath
import sys
import tarfile


class RootfsPrivacyError(RuntimeError):
    pass


WCNSS_FIRMWARE = (
    "wcnss.mdt",
    "wcnss.b00",
    "wcnss.b01",
    "wcnss.b02",
    "wcnss.b04",
    "wcnss.b06",
    "wcnss.b09",
    "wcnss.b10",
    "wcnss.b11",
    "wcnss.b12",
)

MPSS_FIRMWARE = (
    "mba.mbn",
    "modem.mdt",
    "modem.b00",
    "modem.b01",
    "modem.b02",
    "modem.b03",
    "modem.b05",
    "modem.b06",
    "modem.b07",
    "modem.b08",
    "modem.b09",
    "modem.b10",
    "modem.b11",
    "modem.b12",
    "modem.b13",
    "modem.b14",
    "modem.b15",
    "modem.b16",
    "modem.b19",
    "modem.b20",
    "modem.b21",
    "modem.b22",
    "modem.b23",
    "modem.b24",
)

EXPECTED_DEVICE_LINKS = {
    **{
        f"usr/lib/firmware/{name}": f"/firmware/image/{name}"
        for name in WCNSS_FIRMWARE + MPSS_FIRMWARE
    },
    "usr/lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin": (
        "/persist/WCNSS_qcom_wlan_nv.bin"
    ),
}

FORBIDDEN_EXACT_PATHS = {
    "etc/adjtime",
    "etc/udev/rules.d/70-persistent-net.rules",
    "root/.bash_history",
    "root/.lesshst",
    "root/.wget-hsts",
    "var/lib/dbus/machine-id",
    "var/lib/systemd/random-seed",
}

FORBIDDEN_STATE_PREFIXES = (
    "etc/ssl/private/",
    "root/.ssh/",
    "var/lib/ModemManager/",
    "var/lib/NetworkManager/",
    "var/lib/connman/",
    "var/lib/dhcp/",
    "var/lib/iwd/",
    "var/lib/wpa_supplicant/",
)

FORBIDDEN_TEXT_MARKERS = (
    b"M:\\IDE\\",
    b"\\\\DiskStation\\docker\\",
    b"192.168.66.66",
)


def normalized_member_name(name: str) -> str:
    while name.startswith("./"):
        name = name[2:]
    if name in ("", "."):
        return ""
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise RootfsPrivacyError(f"archive member escapes the rootfs: {name}")
    return path.as_posix().rstrip("/")


def is_forbidden_state_path(name: str) -> bool:
    if name in FORBIDDEN_EXACT_PATHS:
        return True
    if name.startswith("etc/ssh/ssh_host_"):
        return True
    if name.startswith("home/") and "/.ssh/" in f"{name}/":
        return True
    return any(name.startswith(prefix) for prefix in FORBIDDEN_STATE_PREFIXES)


def read_regular_member(archive: tarfile.TarFile, member: tarfile.TarInfo) -> bytes:
    extracted = archive.extractfile(member)
    if extracted is None:
        raise RootfsPrivacyError(f"cannot read regular member: {member.name}")
    return extracted.read()


def audit_rootfs_archive(path: Path) -> dict[str, int]:
    if not path.is_file():
        raise RootfsPrivacyError(f"rootfs tarball does not exist: {path}")

    members: dict[str, tarfile.TarInfo] = {}
    regular_files = 0
    symlinks = 0

    try:
        archive = tarfile.open(path, "r:xz")
    except (OSError, tarfile.TarError) as error:
        raise RootfsPrivacyError(f"cannot open rootfs tarball: {error}") from error

    with archive:
        for member in archive:
            name = normalized_member_name(member.name)
            if not name:
                continue
            if name in members:
                raise RootfsPrivacyError(f"duplicate archive member: {name}")
            members[name] = member

            if member.isfile():
                regular_files += 1
            elif member.issym():
                symlinks += 1

            if is_forbidden_state_path(name) and not member.isdir():
                raise RootfsPrivacyError(f"rootfs contains generated private state: {name}")

            if (name.startswith("firmware/") or name.startswith("persist/")) and not member.isdir():
                raise RootfsPrivacyError(f"device partition data is embedded in rootfs: {name}")

            if member.isfile() and member.size <= 1024 * 1024:
                content = read_regular_member(archive, member)
                for marker in FORBIDDEN_TEXT_MARKERS:
                    if marker in content:
                        raise RootfsPrivacyError(
                            f"rootfs contains a local development marker in {name}"
                        )

        machine_id = members.get("etc/machine-id")
        if machine_id is None or not machine_id.isfile() or machine_id.size != 0:
            raise RootfsPrivacyError("etc/machine-id must be an empty regular file")

        hostname = members.get("etc/hostname")
        if hostname is None or not hostname.isfile():
            raise RootfsPrivacyError("rootfs is missing etc/hostname")
        if read_regular_member(archive, hostname) != b"ufi210\n":
            raise RootfsPrivacyError("rootfs hostname is not the generic ufi210 value")

        for name, expected_target in EXPECTED_DEVICE_LINKS.items():
            member = members.get(name)
            if member is None:
                raise RootfsPrivacyError(f"rootfs is missing device firmware link: {name}")
            if not member.issym() or member.linkname != expected_target:
                raise RootfsPrivacyError(
                    f"device firmware must be a symlink to {expected_target}: {name}"
                )

    return {
        "members": len(members),
        "regular_files": regular_files,
        "symlinks": symlinks,
        "device_links": len(EXPECTED_DEVICE_LINKS),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit a UFI210 Debian rootfs tarball for private device state."
    )
    parser.add_argument("rootfs_tarball", type=Path)
    arguments = parser.parse_args()

    try:
        result = audit_rootfs_archive(arguments.rootfs_tarball)
    except RootfsPrivacyError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print("rootfs privacy audit passed")
    for key, value in result.items():
        print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
