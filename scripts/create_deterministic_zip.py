#!/usr/bin/env python3
"""把一个目录生成为元数据固定、内容顺序稳定的 ZIP 归档。"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import stat
import zipfile


class ArchiveError(RuntimeError):
    pass


def _zip_info(name: str, mode: int, epoch: int, is_directory: bool) -> zipfile.ZipInfo:
    timestamp = datetime.fromtimestamp(epoch, timezone.utc)
    if not 1980 <= timestamp.year <= 2107:
        raise ArchiveError("ZIP 时间戳必须位于 1980 至 2107 年")
    info = zipfile.ZipInfo(name, timestamp.timetuple()[:6])
    info.create_system = 3
    if is_directory:
        info.external_attr = ((stat.S_IFDIR | 0o755) << 16) | 0x10
        info.compress_type = zipfile.ZIP_STORED
    else:
        info.external_attr = (stat.S_IFREG | (mode & 0o777)) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
    return info


def create_deterministic_zip(source: Path, output: Path, epoch: int) -> None:
    source = source.resolve()
    output = output.resolve()
    if not source.is_dir():
        raise ArchiveError(f"源目录不存在：{source}")
    if output == source or source in output.parents:
        raise ArchiveError("输出 ZIP 不能位于源目录内")

    entries = sorted(source.rglob("*"), key=lambda path: path.relative_to(source).as_posix())
    for path in entries:
        if path.is_symlink() or not (path.is_dir() or path.is_file()):
            raise ArchiveError(f"源目录包含不支持的文件类型：{path}")

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{os.getpid()}.part")
    root_name = source.name
    try:
        with zipfile.ZipFile(
            temporary,
            mode="w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
            allowZip64=True,
        ) as archive:
            archive.writestr(_zip_info(f"{root_name}/", 0o755, epoch, True), b"")
            for path in entries:
                relative = path.relative_to(source).as_posix()
                archive_name = f"{root_name}/{relative}"
                if path.is_dir():
                    archive.writestr(_zip_info(f"{archive_name}/", 0o755, epoch, True), b"")
                    continue
                info = _zip_info(archive_name, path.stat().st_mode, epoch, False)
                with path.open("rb") as source_stream, archive.open(info, "w", force_zip64=True) as target:
                    for block in iter(lambda: source_stream.read(1024 * 1024), b""):
                        target.write(block)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--source-date-epoch", type=int, required=True)
    args = parser.parse_args()
    try:
        create_deterministic_zip(args.source, args.output, args.source_date_epoch)
    except (ArchiveError, OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"错误：{error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
