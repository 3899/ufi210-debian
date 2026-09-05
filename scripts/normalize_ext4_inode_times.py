#!/usr/bin/env python3
"""Normalize and verify timestamps for every allocated inode in an ext4 image."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


class InodeTimeError(RuntimeError):
    pass


def command_environment(epoch: int) -> dict[str, str]:
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    environment["E2FSPROGS_FAKE_TIME"] = str(epoch)
    return environment


def allocated_inodes(image: Path, epoch: int) -> list[int]:
    result = subprocess.run(
        ["dumpe2fs", str(image)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=command_environment(epoch),
    )
    if result.returncode != 0:
        raise InodeTimeError(f"dumpe2fs failed: {result.stderr.strip()}")

    inode_count_match = re.search(r"^Inode count:\s+(\d+)\s*$", result.stdout, re.MULTILINE)
    free_count_match = re.search(r"^Free inodes:\s+(\d+)\s*$", result.stdout, re.MULTILINE)
    if not inode_count_match or not free_count_match:
        raise InodeTimeError("cannot parse ext4 inode counters from dumpe2fs")

    inode_count = int(inode_count_match.group(1))
    expected_free_count = int(free_count_match.group(1))
    free_inodes: set[int] = set()
    for match in re.finditer(r"^[ \t]+Free inodes:\s*(.*?)\s*$", result.stdout, re.MULTILINE):
        value = match.group(1)
        if not value or value.lower() in {"none", "<none>"}:
            continue
        for item in value.split(","):
            item = item.strip()
            if not item:
                continue
            if "-" in item:
                first_text, last_text = item.split("-", 1)
                first = int(first_text)
                last = int(last_text)
            else:
                first = last = int(item)
            if first < 1 or last > inode_count or first > last:
                raise InodeTimeError(f"invalid free inode range: {item}")
            for inode in range(first, last + 1):
                if inode in free_inodes:
                    raise InodeTimeError(f"duplicate free inode in dumpe2fs output: {inode}")
                free_inodes.add(inode)

    if len(free_inodes) != expected_free_count:
        raise InodeTimeError(
            "free inode count mismatch: "
            f"parsed {len(free_inodes)}, superblock reports {expected_free_count}"
        )
    return [inode for inode in range(1, inode_count + 1) if inode not in free_inodes]


def write_commands(path: Path, inodes: list[int], epoch: int, mode: str) -> None:
    with path.open("w", encoding="ascii", newline="\n") as stream:
        if mode == "normalize":
            for inode in inodes:
                for field in ("atime", "ctime", "mtime", "crtime"):
                    stream.write(f"set_inode_field <{inode}> {field} @{epoch}\n")
                    stream.write(f"set_inode_field <{inode}> {field}_extra 0\n")
        else:
            for inode in inodes:
                stream.write(f"stat <{inode}>\n")


def verify_times(image: Path, inodes: list[int], epoch: int) -> None:
    expected_seconds = epoch & 0xFFFFFFFF
    marker_pattern = re.compile(r"^debugfs: stat <(\d+)>\s*$")
    time_pattern = re.compile(
        r"^\s*(atime|ctime|mtime|crtime):\s+0x([0-9a-fA-F]+)(?::([0-9a-fA-F]+))?"
    )
    extra_size_pattern = re.compile(r"^Size of extra inode fields:\s+(\d+)\s*$")

    with tempfile.NamedTemporaryFile("w", encoding="ascii", newline="\n") as command_file:
        write_commands(Path(command_file.name), inodes, epoch, "verify")
        command_file.flush()
        process = subprocess.Popen(
            ["debugfs", "-f", command_file.name, str(image)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=command_environment(epoch),
        )
        assert process.stdout is not None

        expected_index = 0
        current_inode: int | None = None
        current_times: dict[str, tuple[int, int]] = {}
        current_extra_size = 0

        def finish_inode() -> None:
            if current_inode is None:
                return
            required = {"atime", "ctime", "mtime"}
            if current_extra_size >= 32:
                required.add("crtime")
            missing = sorted(required.difference(current_times))
            if missing:
                raise InodeTimeError(
                    f"inode {current_inode} is missing timestamp fields: {', '.join(missing)}"
                )
            for field, (seconds, extra) in current_times.items():
                if seconds != expected_seconds or extra != 0:
                    raise InodeTimeError(
                        f"inode {current_inode} {field} is not normalized: "
                        f"seconds=0x{seconds:08x}, extra=0x{extra:08x}"
                    )

        for raw_line in process.stdout:
            line = raw_line.rstrip("\r\n")
            marker = marker_pattern.match(line)
            if marker:
                finish_inode()
                current_inode = int(marker.group(1))
                if expected_index >= len(inodes) or current_inode != inodes[expected_index]:
                    raise InodeTimeError(f"unexpected debugfs inode sequence at {current_inode}")
                expected_index += 1
                current_times = {}
                current_extra_size = 0
                continue
            if current_inode is None:
                continue
            time_match = time_pattern.match(line)
            if time_match:
                current_times[time_match.group(1)] = (
                    int(time_match.group(2), 16),
                    int(time_match.group(3) or "0", 16),
                )
                continue
            extra_size_match = extra_size_pattern.match(line)
            if extra_size_match:
                current_extra_size = int(extra_size_match.group(1))

        finish_inode()
        return_code = process.wait()
        if return_code != 0:
            raise InodeTimeError(f"debugfs stat verification failed with exit code {return_code}")
        if expected_index != len(inodes):
            raise InodeTimeError(
                f"debugfs verified {expected_index} inodes, expected {len(inodes)}"
            )


def normalize(image: Path, inodes: list[int], epoch: int) -> None:
    with tempfile.NamedTemporaryFile("w", encoding="ascii", newline="\n") as command_file:
        write_commands(Path(command_file.name), inodes, epoch, "normalize")
        command_file.flush()
        with tempfile.TemporaryFile(mode="w+") as output:
            result = subprocess.run(
                ["debugfs", "-w", "-f", command_file.name, str(image)],
                check=False,
                stdout=output,
                stderr=subprocess.STDOUT,
                text=True,
                env=command_environment(epoch),
            )
            if result.returncode != 0:
                output.seek(0)
                detail = output.read().strip()
                raise InodeTimeError(
                    f"debugfs normalization failed with exit code {result.returncode}: {detail}"
                )
    verify_times(image, inodes, epoch)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Normalize or verify all allocated ext4 inode timestamps."
    )
    parser.add_argument("mode", choices=("normalize", "verify"))
    parser.add_argument("image", type=Path)
    parser.add_argument("epoch", type=int)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.epoch < 0 or arguments.epoch > 0x7FFFFFFF:
        raise InodeTimeError("epoch must be between 0 and 2147483647")
    if not arguments.image.is_file():
        raise InodeTimeError(f"image does not exist: {arguments.image}")

    inodes = allocated_inodes(arguments.image, arguments.epoch)
    if not inodes:
        raise InodeTimeError("ext4 image has no allocated inodes")
    if arguments.mode == "normalize":
        normalize(arguments.image, inodes, arguments.epoch)
        action = "normalized"
    else:
        verify_times(arguments.image, inodes, arguments.epoch)
        action = "verified"
    print(f"{action} {len(inodes)} allocated inodes at epoch {arguments.epoch}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (InodeTimeError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
