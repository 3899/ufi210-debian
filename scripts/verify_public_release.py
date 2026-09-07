#!/usr/bin/env python3
"""Unpack and audit all public UFI210 release archives."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile


class ReleaseVerificationError(RuntimeError):
    pass


CHECKSUM_RE = re.compile(r"^([0-9a-f]{64})  ([^/\r\n][^\r\n]*)$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_member_name(name: str, expected_root: str) -> PurePosixPath:
    if "\\" in name:
        raise ReleaseVerificationError(f"archive member contains a backslash: {name}")
    stripped = name.rstrip("/")
    path = PurePosixPath(stripped)
    if not stripped or path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise ReleaseVerificationError(f"unsafe archive member: {name}")
    if path.parts[0] != expected_root:
        raise ReleaseVerificationError(
            f"archive member is outside {expected_root}: {name}"
        )
    return path


def collapse_link_target(path: PurePosixPath, expected_root: str) -> PurePosixPath:
    parts: list[str] = []
    for part in path.parts:
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                raise ReleaseVerificationError(f"archive link escapes its root: {path}")
            parts.pop()
        else:
            parts.append(part)
    if not parts or parts[0] != expected_root:
        raise ReleaseVerificationError(f"archive link escapes {expected_root}: {path}")
    return PurePosixPath(*parts)


def validate_link(member: tarfile.TarInfo, member_path: PurePosixPath, expected_root: str) -> None:
    target = member.linkname
    if not target or "\\" in target or PurePosixPath(target).is_absolute():
        raise ReleaseVerificationError(f"unsafe archive link target: {member.name} -> {target}")
    target_path = PurePosixPath(target)
    if member.issym():
        target_path = member_path.parent / target_path
    elif target_path.parts and target_path.parts[0] != expected_root:
        target_path = member_path.parent / target_path
    collapse_link_target(target_path, expected_root)


def extract_tar_archive(archive_path: Path, destination: Path, expected_root: str) -> Path:
    seen: set[str] = set()
    try:
        archive = tarfile.open(archive_path, "r:xz")
    except (OSError, tarfile.TarError) as error:
        raise ReleaseVerificationError(f"cannot open {archive_path.name}: {error}") from error

    with archive:
        members = archive.getmembers()
        if not members:
            raise ReleaseVerificationError(f"archive is empty: {archive_path.name}")
        for member in members:
            member_path = normalize_member_name(member.name, expected_root)
            normalized = member_path.as_posix()
            if normalized in seen:
                raise ReleaseVerificationError(
                    f"duplicate member in {archive_path.name}: {normalized}"
                )
            seen.add(normalized)
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ReleaseVerificationError(
                    f"special file in {archive_path.name}: {member.name}"
                )
            if member.issym() or member.islnk():
                validate_link(member, member_path, expected_root)

        try:
            archive.extractall(destination)
        except (OSError, tarfile.TarError) as error:
            raise ReleaseVerificationError(
                f"cannot extract {archive_path.name}: {error}"
            ) from error

    extracted_root = destination / expected_root
    if not extracted_root.is_dir():
        raise ReleaseVerificationError(f"archive root is missing: {expected_root}")
    return extracted_root


def extract_zip_archive(archive_path: Path, destination: Path, expected_root: str) -> Path:
    seen: set[str] = set()
    try:
        archive = zipfile.ZipFile(archive_path)
    except (OSError, zipfile.BadZipFile) as error:
        raise ReleaseVerificationError(f"cannot open {archive_path.name}: {error}") from error

    with archive:
        members = archive.infolist()
        if not members:
            raise ReleaseVerificationError(f"archive is empty: {archive_path.name}")
        for member in members:
            member_path = normalize_member_name(member.filename, expected_root)
            normalized = member_path.as_posix()
            if normalized in seen:
                raise ReleaseVerificationError(
                    f"duplicate member in {archive_path.name}: {normalized}"
                )
            seen.add(normalized)
            if member.flag_bits & 0x1:
                raise ReleaseVerificationError(
                    f"encrypted member in {archive_path.name}: {member.filename}"
                )
            unix_mode = (member.external_attr >> 16) & 0xFFFF
            if unix_mode and stat.S_ISLNK(unix_mode):
                raise ReleaseVerificationError(
                    f"symbolic link in {archive_path.name}: {member.filename}"
                )
        bad_member = archive.testzip()
        if bad_member is not None:
            raise ReleaseVerificationError(
                f"CRC failure in {archive_path.name}: {bad_member}"
            )
        archive.extractall(destination)

    extracted_root = destination / expected_root
    if not extracted_root.is_dir():
        raise ReleaseVerificationError(f"archive root is missing: {expected_root}")
    return extracted_root


def parse_checksum_manifest(path: Path, expected_names: set[str]) -> dict[str, str]:
    if not path.is_file():
        raise ReleaseVerificationError(f"checksum manifest is missing: {path}")
    result: dict[str, str] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        match = CHECKSUM_RE.fullmatch(line)
        if match is None:
            raise ReleaseVerificationError(f"invalid checksum line: {line!r}")
        digest, name = match.groups()
        if name in result:
            raise ReleaseVerificationError(f"duplicate checksum entry: {name}")
        result[name] = digest
    if set(result) != expected_names:
        missing = sorted(expected_names - set(result))
        extra = sorted(set(result) - expected_names)
        raise ReleaseVerificationError(
            f"checksum entries do not match release files; missing={missing}, extra={extra}"
        )
    return result


def parse_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ReleaseVerificationError(f"invalid metadata line in {path}: {line!r}")
        key, value = line.split("=", 1)
        if not key or key in values:
            raise ReleaseVerificationError(f"duplicate or empty metadata key in {path}: {key}")
        values[key] = value
    return values


def run_checked(command: list[str], project_root: Path) -> None:
    print("+ " + " ".join(command), flush=True)
    environment = os.environ.copy()
    environment["LC_ALL"] = "C.UTF-8"
    subprocess.run(command, cwd=project_root, env=environment, check=True)


def verify_kernel_tree(kernel_root: Path, project_root: Path) -> None:
    kernel_manifest = parse_key_values(
        project_root / "out/mainline/kernel/BUILD-MANIFEST.txt"
    )
    metadata = parse_key_values(kernel_root / "UFI210-BUILD-METADATA.txt")
    expected_metadata = {
        "source_repository": kernel_manifest["kernel_repo"],
        "source_commit": kernel_manifest["kernel_commit"],
        "kernel_release": kernel_manifest["kernel_release"],
        "applied_patch": "UFI210-DTS.patch",
        "build_config": ".config",
        "source_date_epoch": "1781860238",
    }
    if metadata != expected_metadata:
        raise ReleaseVerificationError("Linux source build metadata does not match the build")

    comparisons = (
        (kernel_root / ".config", project_root / "out/mainline/kernel/config"),
        (
            kernel_root / "UFI210-DTS.patch",
            project_root / "patches/linux/0001-arm-dts-qcom-add-zu02-dw01-minimal.patch",
        ),
    )
    for archived, original in comparisons:
        if sha256_file(archived) != sha256_file(original):
            raise ReleaseVerificationError(f"Linux source member does not match: {archived.name}")
    for required in (
        "COPYING",
        "arch/arm/boot/dts/qcom/qcom-msm8909-zu02-dw01.dts",
    ):
        if not (kernel_root / required).is_file():
            raise ReleaseVerificationError(f"Linux source member is missing: {required}")
    file_count = sum(1 for path in kernel_root.rglob("*") if path.is_file())
    if file_count < 10000:
        raise ReleaseVerificationError(
            f"Linux source tree is unexpectedly small: {file_count} files"
        )
    print(f"Linux source tree audit passed: files={file_count}")


def verify_release(project_root: Path, out_root: Path, version: str) -> None:
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._-]*", version):
        raise ReleaseVerificationError("invalid release version")
    release_dir = (out_root / version).resolve()
    if release_dir.parent != out_root.resolve() or not release_dir.is_dir():
        raise ReleaseVerificationError(f"release directory does not exist: {release_dir}")

    names = {
        "source": f"ufi210-debian-source-{version}",
        "binary": f"ufi210-debian-zu02-dw01-{version}",
        "debian": f"ufi210-debian-debian-sources-{version}",
        "kernel": f"ufi210-debian-kernel-source-{version}",
    }
    archive_names = {
        f"{names['source']}.tar.xz",
        f"{names['binary']}.zip",
        f"{names['debian']}.tar.xz",
        f"{names['kernel']}.tar.xz",
    }
    actual_entries = {path.name for path in release_dir.iterdir()}
    expected_entries = archive_names | {"SHA256SUMS"}
    if actual_entries != expected_entries or any(
        not path.is_file() for path in release_dir.iterdir()
    ):
        raise ReleaseVerificationError(
            f"release directory contents differ; expected={sorted(expected_entries)}, "
            f"actual={sorted(actual_entries)}"
        )

    checksums = parse_checksum_manifest(release_dir / "SHA256SUMS", archive_names)
    for name, expected_digest in checksums.items():
        actual_digest = sha256_file(release_dir / name)
        if actual_digest != expected_digest:
            raise ReleaseVerificationError(f"SHA256 mismatch: {name}")
        print(f"SHA256 passed: {actual_digest}  {name}")

    run_checked(["bash", str(project_root / "scripts/verify_debian_system.sh")], project_root)
    run_checked(
        [
            sys.executable,
            str(project_root / "scripts/audit_rootfs_privacy.py"),
            str(
                project_root
                / "out/mainline/debian-system/debian-bookworm-armhf-system-rootfs.tar.xz"
            ),
        ],
        project_root,
    )

    temp_parent = project_root / "out/release-verification"
    temp_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f"{version}-", dir=temp_parent) as temporary:
        extract_root = Path(temporary)
        source_root = extract_tar_archive(
            release_dir / f"{names['source']}.tar.xz", extract_root, names["source"]
        )
        binary_root = extract_zip_archive(
            release_dir / f"{names['binary']}.zip", extract_root, names["binary"]
        )
        debian_root = extract_tar_archive(
            release_dir / f"{names['debian']}.tar.xz", extract_root, names["debian"]
        )
        kernel_root = extract_tar_archive(
            release_dir / f"{names['kernel']}.tar.xz", extract_root, names["kernel"]
        )

        run_checked(
            ["bash", str(project_root / "scripts/audit_public_release.sh"), "source", str(source_root)],
            project_root,
        )
        run_checked(
            ["bash", str(project_root / "scripts/audit_public_release.sh"), "binary", str(binary_root)],
            project_root,
        )
        run_checked(
            [
                sys.executable,
                str(project_root / "scripts/collect_debian_sources.py"),
                str(debian_root / "source-packages.txt"),
                str(debian_root),
                "--verify-only",
            ],
            project_root,
        )
        verify_kernel_tree(kernel_root, project_root)

        built_root = project_root / "out/mainline/debian-system"
        for image_name in (
            "debian-bookworm-armhf-system.ext4",
            "debian-bookworm-armhf-data.ext4",
            "boot-debian-system.img",
        ):
            if sha256_file(binary_root / image_name) != sha256_file(built_root / image_name):
                raise ReleaseVerificationError(
                    f"unpacked firmware image differs from verified build: {image_name}"
                )

    try:
        temp_parent.rmdir()
    except OSError:
        pass
    print(f"public release archive verification passed: {release_dir}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--project-root", type=Path)
    parser.add_argument("--out-root", type=Path)
    arguments = parser.parse_args()

    project_root = (
        arguments.project_root.resolve()
        if arguments.project_root
        else Path(__file__).resolve().parent.parent
    )
    out_root = (
        arguments.out_root.resolve()
        if arguments.out_root
        else project_root / "out/release-candidate"
    )
    try:
        verify_release(project_root, out_root, arguments.version)
    except (
        KeyError,
        OSError,
        ReleaseVerificationError,
        subprocess.CalledProcessError,
        tarfile.TarError,
        UnicodeError,
        zipfile.BadZipFile,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
