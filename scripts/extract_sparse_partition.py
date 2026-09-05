#!/usr/bin/env python3
"""List or extract MBR partitions from an Android sparse disk image."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import BinaryIO


SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW = 0xCAC1
CHUNK_FILL = 0xCAC2
CHUNK_DONT_CARE = 0xCAC3
CHUNK_CRC32 = 0xCAC4
SECTOR_SIZE = 512


@dataclass(frozen=True)
class Chunk:
    chunk_type: int
    logical_offset: int
    logical_size: int
    payload_offset: int
    payload_size: int


@dataclass(frozen=True)
class Partition:
    number: int
    bootable: bool
    partition_type: int
    start_lba: int
    sectors: int

    @property
    def offset(self) -> int:
        return self.start_lba * SECTOR_SIZE

    @property
    def size(self) -> int:
        return self.sectors * SECTOR_SIZE


class SparseImage:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.block_size = 0
        self.logical_size = 0
        self.chunks: list[Chunk] = []
        self._parse()

    def _parse(self) -> None:
        with self.path.open("rb") as stream:
            header = stream.read(28)
            if len(header) != 28:
                raise ValueError("truncated Android sparse header")
            (
                magic,
                major,
                _minor,
                file_header_size,
                chunk_header_size,
                block_size,
                total_blocks,
                total_chunks,
                _checksum,
            ) = struct.unpack("<I4H4I", header)
            if magic != SPARSE_MAGIC:
                raise ValueError("input is not an Android sparse image")
            if major != 1:
                raise ValueError(f"unsupported sparse major version: {major}")
            if file_header_size < 28 or chunk_header_size < 12:
                raise ValueError("invalid sparse header size")
            if block_size == 0 or block_size % 4:
                raise ValueError("invalid sparse block size")

            self.block_size = block_size
            self.logical_size = total_blocks * block_size
            stream.seek(file_header_size)
            logical_offset = 0

            for _ in range(total_chunks):
                chunk_header = stream.read(chunk_header_size)
                if len(chunk_header) != chunk_header_size:
                    raise ValueError("truncated sparse chunk header")
                chunk_type, _reserved, chunk_blocks, total_size = struct.unpack(
                    "<2H2I", chunk_header[:12]
                )
                logical_size = chunk_blocks * block_size
                payload_size = total_size - chunk_header_size
                payload_offset = stream.tell()

                expected_payload = {
                    CHUNK_RAW: logical_size,
                    CHUNK_FILL: 4,
                    CHUNK_DONT_CARE: 0,
                    CHUNK_CRC32: 4,
                }.get(chunk_type)
                if expected_payload is None:
                    raise ValueError(f"unknown sparse chunk type: 0x{chunk_type:04x}")
                if payload_size != expected_payload:
                    raise ValueError(
                        f"invalid payload size for chunk 0x{chunk_type:04x}: "
                        f"got {payload_size}, expected {expected_payload}"
                    )

                if chunk_type != CHUNK_CRC32:
                    self.chunks.append(
                        Chunk(
                            chunk_type=chunk_type,
                            logical_offset=logical_offset,
                            logical_size=logical_size,
                            payload_offset=payload_offset,
                            payload_size=payload_size,
                        )
                    )
                    logical_offset += logical_size
                stream.seek(payload_size, 1)

            if logical_offset != self.logical_size:
                raise ValueError(
                    f"sparse logical size mismatch: got {logical_offset}, "
                    f"expected {self.logical_size}"
                )
            if stream.tell() != self.path.stat().st_size:
                raise ValueError("trailing or unparsed data in sparse image")

    def read_range(self, offset: int, size: int) -> bytes:
        output = bytearray()
        with self.path.open("rb") as stream:
            self._copy_range(stream, offset, size, output.extend, None)
        return bytes(output)

    def extract_range(self, offset: int, size: int, output_path: Path) -> str:
        digest = hashlib.sha256()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("rb") as stream, output_path.open("wb") as output:
            self._copy_range(stream, offset, size, output.write, digest)
        return digest.hexdigest()

    def _copy_range(
        self,
        stream: BinaryIO,
        offset: int,
        size: int,
        write,
        digest: hashlib._Hash | None,
    ) -> None:
        if offset < 0 or size < 0 or offset + size > self.logical_size:
            raise ValueError("requested range is outside the sparse image")

        range_end = offset + size
        copied = 0
        zero_block = bytes(1024 * 1024)
        for chunk in self.chunks:
            chunk_end = chunk.logical_offset + chunk.logical_size
            start = max(offset, chunk.logical_offset)
            end = min(range_end, chunk_end)
            if start >= end:
                continue

            relative = start - chunk.logical_offset
            remaining = end - start
            if chunk.chunk_type == CHUNK_RAW:
                stream.seek(chunk.payload_offset + relative)
                while remaining:
                    data = stream.read(min(remaining, len(zero_block)))
                    if not data:
                        raise ValueError("truncated raw sparse chunk")
                    write(data)
                    if digest is not None:
                        digest.update(data)
                    remaining -= len(data)
                    copied += len(data)
            elif chunk.chunk_type == CHUNK_FILL:
                stream.seek(chunk.payload_offset)
                fill = stream.read(4)
                if len(fill) != 4:
                    raise ValueError("truncated fill sparse chunk")
                fill_offset = relative % len(fill)
                while remaining:
                    count = min(remaining, len(zero_block))
                    repeated = (fill * ((fill_offset + count + 3) // 4))[
                        fill_offset : fill_offset + count
                    ]
                    write(repeated)
                    if digest is not None:
                        digest.update(repeated)
                    remaining -= count
                    copied += count
                    fill_offset = 0
            elif chunk.chunk_type == CHUNK_DONT_CARE:
                while remaining:
                    data = zero_block[: min(remaining, len(zero_block))]
                    write(data)
                    if digest is not None:
                        digest.update(data)
                    remaining -= len(data)
                    copied += len(data)

        if copied != size:
            raise ValueError(f"copied {copied} bytes, expected {size}")


def read_partitions(image: SparseImage) -> list[Partition]:
    mbr = image.read_range(0, SECTOR_SIZE)
    if mbr[510:512] != b"\x55\xaa":
        raise ValueError("logical image does not contain a valid MBR")

    partitions: list[Partition] = []
    for index in range(4):
        entry = mbr[446 + index * 16 : 446 + (index + 1) * 16]
        status, _chs_start, partition_type, _chs_end, start_lba, sectors = struct.unpack(
            "<B3sB3sII", entry
        )
        if partition_type == 0 or sectors == 0:
            continue
        if status not in (0x00, 0x80):
            raise ValueError(f"invalid MBR status for partition {index + 1}")
        partition = Partition(
            number=index + 1,
            bootable=status == 0x80,
            partition_type=partition_type,
            start_lba=start_lba,
            sectors=sectors,
        )
        if partition.offset + partition.size > image.logical_size:
            raise ValueError(f"partition {index + 1} exceeds logical image size")
        partitions.append(partition)
    return partitions


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--partition", type=int, help="one-based MBR partition number")
    parser.add_argument("--output", type=Path, help="raw partition output path")
    args = parser.parse_args()

    image = SparseImage(args.image.resolve())
    partitions = read_partitions(image)
    summary = {
        "image": str(image.path),
        "block_size": image.block_size,
        "logical_size": image.logical_size,
        "chunk_count": len(image.chunks),
        "partitions": [asdict(item) | {"offset": item.offset, "size": item.size} for item in partitions],
    }
    print(json.dumps(summary, indent=2))

    if args.partition is None and args.output is None:
        return
    if args.partition is None or args.output is None:
        parser.error("--partition and --output must be used together")
    matches = [item for item in partitions if item.number == args.partition]
    if len(matches) != 1:
        parser.error(f"MBR partition {args.partition} was not found")

    partition = matches[0]
    digest = image.extract_range(partition.offset, partition.size, args.output.resolve())
    print(f"output={args.output.resolve()}")
    print(f"sha256={digest}")


if __name__ == "__main__":
    main()
