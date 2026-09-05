#!/usr/bin/env python3
"""收集并校验 Debian rootfs 的精确对应源码包。"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import lzma
import os
from pathlib import Path
import re
import tarfile
import time
from typing import Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


DEFAULT_SNAPSHOT = "https://snapshot.debian.org"
DEFAULT_SOURCE_DATE_EPOCH = 1781860238
PACKAGE_RE = re.compile(r"^[a-z0-9][a-z0-9+.-]*$")
VERSION_RE = re.compile(r"^[^\s/\\]+$")
SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
MANIFEST_HEADER = (
    "sha256\tsnapshot_sha1\tsize\tpath\tsource_package\tsource_version\n"
)


class SourceCollectionError(RuntimeError):
    pass


def parse_source_packages(path: Path) -> list[tuple[str, str]]:
    packages: list[tuple[str, str]] = []
    seen: set[str] = set()
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw_line or raw_line.startswith("#"):
            continue
        fields = raw_line.split("\t")
        if len(fields) != 2:
            raise SourceCollectionError(f"{path}:{line_number}: 预期两列制表符分隔数据")
        package, version = fields
        if not PACKAGE_RE.fullmatch(package) or not VERSION_RE.fullmatch(version):
            raise SourceCollectionError(f"{path}:{line_number}: 非法源码包名或版本")
        if package in seen:
            raise SourceCollectionError(f"{path}:{line_number}: 重复源码包 {package}")
        seen.add(package)
        packages.append((package, version))
    if not packages:
        raise SourceCollectionError(f"源码包清单为空：{path}")
    return sorted(packages)


def encoded_version(version: str) -> str:
    return quote(version, safe="")


def hash_file(path: Path) -> tuple[str, str, int]:
    sha256 = hashlib.sha256()
    sha1 = hashlib.sha1()
    size = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha256.update(block)
            sha1.update(block)
            size += len(block)
    return sha256.hexdigest(), sha1.hexdigest(), size


def parse_dsc_checksums(
    content: str, field_name: str, hash_length: int
) -> dict[str, tuple[int, str]]:
    lines = content.splitlines()
    header = f"{field_name}:"
    try:
        start = lines.index(header) + 1
    except ValueError as error:
        raise SourceCollectionError(f".dsc 缺少 {field_name}") from error
    entries: dict[str, tuple[int, str]] = {}
    for line in lines[start:]:
        if not line.startswith((" ", "\t")):
            break
        fields = line.split()
        if len(fields) != 3:
            raise SourceCollectionError(f".dsc 的 {field_name} 条目无效")
        checksum, size_text, name = fields
        if (
            not re.fullmatch(rf"[0-9a-f]{{{hash_length}}}", checksum)
            or not size_text.isdigit()
            or Path(name).name != name
        ):
            raise SourceCollectionError(f".dsc 的 {field_name} 校验字段无效")
        if checksum in entries:
            raise SourceCollectionError(f".dsc 的 {field_name} 出现重复哈希")
        entries[checksum] = (int(size_text), name)
    if not entries:
        raise SourceCollectionError(f".dsc 的 {field_name} 为空")
    return entries


class SnapshotClient:
    def __init__(self, base_url: str, timeout: int, retries: int) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.retries = retries

    def _open(self, url: str):
        request = Request(url, headers={"User-Agent": "ufi210-debian-source-collector/1"})
        for attempt in range(self.retries + 1):
            try:
                return urlopen(request, timeout=self.timeout)
            except HTTPError as error:
                if error.code not in {429, 500, 502, 503, 504} or attempt == self.retries:
                    raise
            except URLError:
                if attempt == self.retries:
                    raise
            time.sleep(min(2**attempt, 8))
        raise AssertionError("unreachable")

    def get_json(self, path: str) -> dict:
        with self._open(f"{self.base_url}{path}") as response:
            return json.load(response)

    def download(self, snapshot_sha1: str, target: Path, expected_size: int) -> None:
        if target.exists():
            _, current_sha1, current_size = hash_file(target)
            if current_sha1 == snapshot_sha1 and current_size == expected_size:
                return
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_name(f".{target.name}.{os.getpid()}.part")
        try:
            sha1 = hashlib.sha1()
            size = 0
            with self._open(f"{self.base_url}/file/{snapshot_sha1}") as response:
                with temporary.open("wb") as stream:
                    for block in iter(lambda: response.read(1024 * 1024), b""):
                        stream.write(block)
                        sha1.update(block)
                        size += len(block)
            if size != expected_size or sha1.hexdigest() != snapshot_sha1:
                raise SourceCollectionError(f"Snapshot 文件校验失败：{target.name}")
            os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)

    def collect_package(
        self, package: str, version: str, output_dir: Path
    ) -> list[tuple[str, str, int, str, str, str]]:
        package_url = quote(package, safe="")
        version_url = quote(version, safe="")
        metadata = self.get_json(f"/mr/package/{package_url}/{version_url}/srcfiles")
        hashes = sorted({item.get("hash", "") for item in metadata.get("result", [])})
        if not hashes or any(not SHA1_RE.fullmatch(value) for value in hashes):
            raise SourceCollectionError(f"Snapshot 没有源码文件：{package}={version}")

        expected_dsc_name = f"{package}_{version.split(':', 1)[-1]}.dsc"
        dsc_candidates: list[tuple[str, int]] = []
        for snapshot_sha1 in hashes:
            info = self.get_json(f"/mr/file/{snapshot_sha1}/info").get("result", [])
            for item in info:
                if item.get("name") == expected_dsc_name and isinstance(item.get("size"), int):
                    dsc_candidates.append((snapshot_sha1, item["size"]))
                    break
        if len(dsc_candidates) != 1:
            raise SourceCollectionError(
                f"无法唯一确定 .dsc：{package}={version}（{len(dsc_candidates)} 个候选）"
            )
        dsc_sha1, dsc_size = dsc_candidates[0]
        package_dir = output_dir / "files" / package / encoded_version(version)
        dsc_target = package_dir / expected_dsc_name
        self.download(dsc_sha1, dsc_target, dsc_size)
        try:
            dsc_content = dsc_target.read_text(encoding="utf-8")
        except UnicodeDecodeError as error:
            raise SourceCollectionError(f".dsc 不是 UTF-8 文本：{expected_dsc_name}") from error
        sha1_entries = parse_dsc_checksums(dsc_content, "Checksums-Sha1", 40)
        sha256_entries = parse_dsc_checksums(dsc_content, "Checksums-Sha256", 64)
        expected_source_hashes = set(sha1_entries) | {dsc_sha1}
        if expected_source_hashes != set(hashes):
            raise SourceCollectionError(f".dsc 与 Snapshot srcfiles 集合不一致：{package}={version}")

        rows: list[tuple[str, str, int, str, str, str]] = []
        for snapshot_sha1 in hashes:
            expected_sha256 = None
            if snapshot_sha1 == dsc_sha1:
                name = expected_dsc_name
                size = dsc_size
            else:
                size, name = sha1_entries[snapshot_sha1]
                sha256_match = [
                    checksum
                    for checksum, entry in sha256_entries.items()
                    if entry == (size, name)
                ]
                if len(sha256_match) != 1:
                    raise SourceCollectionError(f".dsc 的 SHA1/SHA256 条目不一致：{name}")
                expected_sha256 = sha256_match[0]
            relative = Path("files") / package / encoded_version(version) / name
            target = output_dir / relative
            self.download(snapshot_sha1, target, size)
            sha256, actual_sha1, actual_size = hash_file(target)
            if (
                actual_sha1 != snapshot_sha1
                or actual_size != size
                or (expected_sha256 is not None and sha256 != expected_sha256)
            ):
                raise SourceCollectionError(f"下载后复核失败：{relative.as_posix()}")
            rows.append(
                (sha256, snapshot_sha1, size, relative.as_posix(), package, version)
            )
        return rows


def write_manifest(
    output_dir: Path, rows: Iterable[tuple[str, str, int, str, str, str]]
) -> None:
    content = [MANIFEST_HEADER]
    for row in sorted(rows, key=lambda value: (value[4], value[5], value[3])):
        content.append("\t".join(map(str, row)) + "\n")
    temporary = output_dir / ".DEBIAN-SOURCE-MANIFEST.txt.part"
    temporary.write_text("".join(content), encoding="utf-8", newline="\n")
    os.replace(temporary, output_dir / "DEBIAN-SOURCE-MANIFEST.txt")


def verify_collection(output_dir: Path) -> int:
    declared_packages = dict(parse_source_packages(output_dir / "source-packages.txt"))
    manifest = output_dir / "DEBIAN-SOURCE-MANIFEST.txt"
    lines = manifest.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] + "\n" != MANIFEST_HEADER:
        raise SourceCollectionError("Debian 源码文件清单表头无效")
    count = 0
    resolved_packages: set[tuple[str, str]] = set()
    resolved_paths: set[str] = set()
    for line_number, line in enumerate(lines[1:], 2):
        fields = line.split("\t")
        if len(fields) != 6:
            raise SourceCollectionError(f"{manifest}:{line_number}: 列数无效")
        expected_sha256, expected_sha1, size_text, relative, package, version = fields
        if not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
            raise SourceCollectionError(f"{manifest}:{line_number}: SHA256 无效")
        if not SHA1_RE.fullmatch(expected_sha1) or not size_text.isdigit():
            raise SourceCollectionError(f"{manifest}:{line_number}: Snapshot 校验字段无效")
        expected_path = Path("files") / package / encoded_version(version)
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts or path.parent != expected_path:
            raise SourceCollectionError(f"{manifest}:{line_number}: 文件路径越界")
        if declared_packages.get(package) != version:
            raise SourceCollectionError(f"{manifest}:{line_number}: 源码包版本不在输入清单中")
        if relative in resolved_paths:
            raise SourceCollectionError(f"{manifest}:{line_number}: 重复文件路径")
        resolved_paths.add(relative)
        resolved_packages.add((package, version))
        target = output_dir / path
        actual_sha256, actual_sha1, actual_size = hash_file(target)
        if (
            actual_sha256 != expected_sha256
            or actual_sha1 != expected_sha1
            or actual_size != int(size_text)
        ):
            raise SourceCollectionError(f"Debian 源码文件校验失败：{relative}")
        count += 1
    if count == 0:
        raise SourceCollectionError("Debian 源码文件清单为空")
    if resolved_packages != set(declared_packages.items()):
        raise SourceCollectionError("并非每个 Debian 源码包都有已解析文件")
    return count


def create_archive(
    output_dir: Path, archive_path: Path, release_version: str, source_date_epoch: int
) -> None:
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._-]*", release_version):
        raise SourceCollectionError("候选版本号含非法字符")
    verify_collection(output_dir)
    root_name = f"ufi210-debian-debian-sources-{release_version}"
    paths = sorted(
        [output_dir / "source-packages.txt", output_dir / "DEBIAN-SOURCE-MANIFEST.txt"]
        + [path for path in (output_dir / "files").rglob("*") if path.is_file()],
        key=lambda path: path.relative_to(output_dir).as_posix(),
    )
    directories = {Path(root_name)}
    for path in paths:
        archive_name = Path(root_name) / path.relative_to(output_dir)
        directories.update(parent for parent in archive_name.parents if parent != Path("."))
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = archive_path.with_name(f".{archive_path.name}.{os.getpid()}.part")
    try:
        with lzma.open(temporary, "wb", preset=3) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.GNU_FORMAT) as archive:
                for directory in sorted(directories, key=lambda value: value.as_posix()):
                    info = tarfile.TarInfo(directory.as_posix() + "/")
                    info.type = tarfile.DIRTYPE
                    info.mode = 0o755
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = source_date_epoch
                    archive.addfile(info)
                for path in paths:
                    archive_name = (Path(root_name) / path.relative_to(output_dir)).as_posix()
                    info = tarfile.TarInfo(archive_name)
                    info.mode = 0o644
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = source_date_epoch
                    info.size = path.stat().st_size
                    with path.open("rb") as stream:
                        archive.addfile(info, stream)
        os.replace(temporary, archive_path)
    finally:
        temporary.unlink(missing_ok=True)


def collect(args: argparse.Namespace) -> None:
    package_list = Path(args.package_list).resolve()
    output_dir = Path(args.output_dir).resolve()
    packages = parse_source_packages(package_list)
    if args.only:
        selected = set(args.only)
        available = {package for package, _ in packages}
        missing = sorted(selected - available)
        if missing:
            raise SourceCollectionError(f"源码包清单不存在：{', '.join(missing)}")
        packages = [item for item in packages if item[0] in selected]
    output_dir.mkdir(parents=True, exist_ok=True)
    selected_list = "".join(f"{package}\t{version}\n" for package, version in packages)
    (output_dir / "source-packages.txt").write_text(
        selected_list, encoding="utf-8", newline="\n"
    )
    client = SnapshotClient(args.snapshot_base, args.timeout, args.retries)
    rows: list[tuple[str, str, int, str, str, str]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = {
            executor.submit(client.collect_package, package, version, output_dir): (package, version)
            for package, version in packages
        }
        for future in concurrent.futures.as_completed(futures):
            package, version = futures[future]
            package_rows = future.result()
            rows.extend(package_rows)
            print(f"已收集 {package}={version}（{len(package_rows)} 个文件）", flush=True)
    write_manifest(output_dir, rows)
    count = verify_collection(output_dir)
    print(f"Debian 对应源码校验通过：{len(packages)} 个源码包，{count} 个文件")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package_list", help="source-packages.txt 路径")
    parser.add_argument("output_dir", help="源码收集目录")
    parser.add_argument("--snapshot-base", default=DEFAULT_SNAPSHOT)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument("--only", action="append", help="只收集指定源码包，可重复")
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--archive", help="生成确定性 tar.xz 的路径")
    parser.add_argument("--release-version")
    parser.add_argument("--source-date-epoch", type=int, default=DEFAULT_SOURCE_DATE_EPOCH)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.jobs < 1 or args.timeout < 1 or args.retries < 0:
            raise SourceCollectionError("并发数、超时或重试次数无效")
        output_dir = Path(args.output_dir).resolve()
        if args.verify_only:
            count = verify_collection(output_dir)
            print(f"Debian 对应源码离线校验通过：{count} 个文件")
        else:
            collect(args)
        if args.archive:
            if not args.release_version:
                raise SourceCollectionError("生成归档时必须提供 --release-version")
            create_archive(
                output_dir,
                Path(args.archive).resolve(),
                args.release_version,
                args.source_date_epoch,
            )
            print(f"已生成 Debian 对应源码归档：{Path(args.archive).resolve()}")
    except (OSError, ValueError, SourceCollectionError, HTTPError, URLError) as error:
        print(f"错误：{error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
