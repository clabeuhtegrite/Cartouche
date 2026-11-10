"""Title IDs: in file names, in a game's NPDM, and the base game they belong to."""

from __future__ import annotations

import re
import struct

# 16 hex digits standing alone, as in "Game [0100152000022000][v0].nsp".
BRACKETED = re.compile(r"\[([0-9A-Fa-f]{16})\]")
BARE = re.compile(r"(?<![0-9A-Fa-f])([0-9A-Fa-f]{16})(?![0-9A-Fa-f])")
# A tag one digit short, as some folder names have it: resolved only when
# nxnative has a profile for the ID with a 0 added (never guessed).
SHORT_BRACKETED = re.compile(r"\[([0-9A-Fa-f]{15})\]")
TAGS = re.compile(r"\s*\[[^\]]*\]")


def is_title_id(text: str) -> bool:
    return len(text) == 16 and all(c in "0123456789abcdefABCDEF" for c in text)


def base_title_id(title_id: str) -> str:
    """The application a package's title ID belongs to.

    An update is the application's ID with 0x800 in its low 12 bits; add-on
    content is the application's ID plus 0x1000, plus its index.
    """
    value = int(title_id, 16)
    low = value & 0xFFF
    if low == 0:
        return f"{value:016X}"
    if low == 0x800:
        return f"{value & ~0xFFF:016X}"
    return f"{(value & ~0xFFF) - 0x1000:016X}"


def ids_in_name(name: str) -> list[str]:
    """The title IDs a file or folder name carries, bracketed ones first."""
    found = [m.upper() for m in BRACKETED.findall(name)]
    found += [m.upper() for m in BARE.findall(name) if m.upper() not in found]
    return found


def label(name: str) -> str:
    """A folder or file name without its [tags] and extension, for display."""
    stem = name
    for suffix in (".nsp", ".xci", ".nsz", ".xcz", ".nup", ".zip", ".ipa"):
        if stem.lower().endswith(suffix):
            stem = stem[: -len(suffix)]
            break
    cleaned = TAGS.sub("", stem).strip(" ._-")
    return cleaned or stem


def npdm_title_id(data: bytes) -> str | None:
    """The program ID in the ACI0 section of a main.npdm, or None."""
    if len(data) < 0x78 or data[:4] != b"META":
        return None
    offset, size = struct.unpack_from("<II", data, 0x70)
    if size < 0x18 or offset + 0x18 > len(data) or data[offset : offset + 4] != b"ACI0":
        return None
    program_id = struct.unpack_from("<Q", data, offset + 0x10)[0]
    if not program_id or program_id & 0xFFF:
        return None
    return f"{program_id:016X}"
