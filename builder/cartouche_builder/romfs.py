"""The DMROMFS1 identity used by nxnative's host/romfs_identity.h.

This checks the image's size, header and index, not the game data's
authenticity. Read in bounded blocks even for images larger than 4 GiB.
"""

import os
import struct

from .i18n import t


def identity(reader) -> tuple[int, str]:
    size = os.fstat(reader.fileno()).st_size
    reader.seek(0)
    header = reader.read(32)
    if len(header) != 32:
        raise ValueError(t("bundle.bad_image"))
    magic, offset, length, count = struct.unpack("<8sQQQ", header)
    if (magic != b"DMROMFS1" or not 0 < count <= 0xFFFFFFFF
            or not 32 <= offset <= size or length != size - offset or count > length // 24):
        raise ValueError(t("bundle.bad_image"))
    value = _mix(0xCBF29CE484222325, header)
    reader.seek(offset)
    left = length
    while left:
        block = reader.read(min(left, 1 << 20))
        if not block:
            raise ValueError(t("bundle.bad_image"))
        left -= len(block)
        if not left:
            block += b"\0" * (-len(block) % 8)
        value = _mix(value, block)
    return size, f"{value:016x}"


def _mix(value: int, data: bytes) -> int:
    for (word,) in struct.iter_unpack("<Q", data):
        value = ((value ^ word) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return value
