"""Content-defined chunking with FastCDC (normalized chunking, level 1).

Chunk boundaries depend on the bytes around them, not on their offset, so a
change in the middle of a file only changes the chunks around it. Two engine
builds that share most of their code then share most of their chunks, and an
update downloads only the chunks the phone does not have yet.

Boundaries are a server-side detail: the app never chunks anything, it only
downloads the chunks a manifest lists and checks their SHA-256.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import BinaryIO, Iterator

MIN_SIZE = 1 << 20  # 1 MiB
AVG_SIZE = 1 << 22  # 4 MiB
MAX_SIZE = 1 << 23  # 8 MiB

_MASK64 = (1 << 64) - 1


def _gear_table() -> tuple[int, ...]:
    """256 pseudo-random 64-bit values, derived from a fixed label so that
    every run of the tool cuts a file at the same places."""
    return tuple(
        int.from_bytes(hashlib.sha256(b"cartouche-fastcdc-gear" + bytes([i])).digest()[:8], "little")
        for i in range(256)
    )


GEAR = _gear_table()


@dataclass(frozen=True)
class Params:
    min_size: int = MIN_SIZE
    avg_size: int = AVG_SIZE
    max_size: int = MAX_SIZE

    def __post_init__(self) -> None:
        if not (0 < self.min_size < self.avg_size < self.max_size):
            raise ValueError("chunk sizes must satisfy 0 < min < avg < max")
        if self.avg_size & (self.avg_size - 1):
            raise ValueError("the average chunk size must be a power of two")

    @property
    def masks(self) -> tuple[int, int]:
        """(strict, loose): before the average size a cut needs one more zero
        bit than the average implies, after it one fewer, which keeps chunk
        sizes close to the average."""
        bits = self.avg_size.bit_length() - 1

        def top(n: int) -> int:
            return ((1 << n) - 1) << (64 - n)

        return top(bits + 1), top(bits - 1)


DEFAULT = Params()


def cut_point(data: bytes | memoryview, start: int, end: int, params: Params = DEFAULT) -> int:
    """Return the end offset of the chunk that begins at ``start``."""
    remaining = end - start
    if remaining <= params.min_size:
        return end
    limit = start + min(remaining, params.max_size)
    normal = start + min(remaining, params.avg_size)
    strict, loose = params.masks
    gear = GEAR
    fp = 0
    i = start + params.min_size
    while i < normal:
        fp = ((fp << 1) + gear[data[i]]) & _MASK64
        if not fp & strict:
            return i + 1
        i += 1
    while i < limit:
        fp = ((fp << 1) + gear[data[i]]) & _MASK64
        if not fp & loose:
            return i + 1
        i += 1
    return limit


def chunk_bytes(data: bytes | memoryview, params: Params = DEFAULT) -> Iterator[memoryview]:
    """Split ``data`` into chunks; their concatenation is ``data``."""
    view = memoryview(data)
    start, end = 0, len(view)
    while start < end:
        stop = cut_point(view, start, end, params)
        yield view[start:stop]
        start = stop


def chunk_stream(stream: BinaryIO, params: Params = DEFAULT) -> Iterator[bytes]:
    """Chunk a file without holding all of it in memory. A boundary depends
    only on the next ``max_size`` bytes, so keeping at least that much in the
    buffer (or the rest of the file) gives the same chunks as chunk_bytes."""
    buf = bytearray()
    eof = False
    while True:
        while not eof and len(buf) < 2 * params.max_size:
            block = stream.read(params.max_size)
            if not block:
                eof = True
            buf += block
        if not buf:
            return
        stop = cut_point(buf, 0, len(buf), params)
        yield bytes(buf[:stop])
        del buf[:stop]
