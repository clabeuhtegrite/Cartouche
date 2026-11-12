"""A full disk, in the player's words.

A disk that fills up shows as an OSError of errno 28 (ENOSPC) in the
builder's own code, as "No space left on device" in what git, Xcode or
nxnative's tools say, and as nxnative's own check of the room before it
unpacks a game ("less than 32 GB free on the volume of ..."). Whatever the
way, the player reads which disk is full and how much is left on it: "your
Mac's disk" for the startup disk, which holds the builder's own folder, or
the disk's name for an external drive or a share (/Volumes/<name>).
"""

from __future__ import annotations

import errno
import re
import shutil
from pathlib import Path

from .i18n import language, t

# What tools say of a full disk: the C library's words, Python's errno, the
# errno's name, nxnative's check of the room before it unpacks, and Xcode's.
FULL = re.compile(
    r"No space left on device|\[Errno 28\]|\berrno 28\b|\bENOSPC\b|less than \d+ GB free on the volume of"
    r"|not enough (?:free )?(?:disk )?space|disk (?:is )?full",
    re.IGNORECASE,
)
# The path a message names: Python's "...device: '/path'", nxnative's
# "... free on the volume of /path", or the first absolute path in it.
NAMED = (
    re.compile(r"""(?:device|space)[^'"\n]*?: ['"](/[^'"\n]+)['"]"""),
    re.compile(r"free on the volume of (/\S+)"),
    re.compile(r"""['"](/[^'"\n]+)['"]"""),
)
# nxnative's check of the room: what it needs.
NEEDED = re.compile(r"less than (\d+) GB free on the volume of")


def is_full(error: BaseException | str | None) -> bool:
    """Whether ERROR (an exception, or what a tool said) is a full disk."""
    if error is None:
        return False
    if isinstance(error, BaseException):
        if isinstance(error, OSError) and error.errno == errno.ENOSPC:
            return True
        error = str(error)
    return bool(FULL.search(error))


def path_in(text: str) -> Path | None:
    """The path a full disk's message names, when it names one."""
    for pattern in NAMED:
        found = pattern.search(text or "")
        if found:
            return Path(found.group(1))
    return None


def volume(path: Path | None) -> str:
    """The name of the disk PATH is on, "" for the startup disk."""
    if path is None:
        return ""
    parts = Path(path).expanduser().parts
    if len(parts) >= 3 and parts[0] == "/" and parts[1] == "Volumes":
        return parts[2]
    return ""


def free_bytes(path: Path | None) -> int | None:
    """What is left on PATH's disk, None when no folder of it can be read."""
    if path is None:
        return None
    current = Path(path).expanduser().absolute()
    # A folder of the disk itself: an external drive or a share that is not
    # mounted has none, and the startup disk's folders above it are not its.
    top = Path("/Volumes", volume(current)) if volume(current) else Path("/")
    for candidate in (current, *current.parents):
        if candidate != top and top not in candidate.parents:
            break
        try:
            if candidate.exists():
                return shutil.disk_usage(candidate).free
        except OSError:
            return None
    return None


def amount(size: int | None) -> str:
    """"0.4 GB", "12 GB" (Go, with a decimal comma, in French)."""
    if size is None:
        return ""
    gb = size / 1e9
    text = f"{gb:.1f}" if gb < 10 else f"{gb:.0f}"
    if language() == "fr":
        return text.replace(".", ",") + " Go"
    return text + " GB"


def message(path: Path | None, text: str = "") -> str:
    """The player's words for a full disk: the one TEXT names, else PATH's
    (where the builder was writing), else the Mac's. nxnative's check of the
    room says what it needs ("less than 32 GB free"), which the player reads
    beside what is left."""
    where = path_in(text) or path
    name = volume(where)
    left = free_bytes(where)
    needed = NEEDED.search(text or "")
    if needed and left is not None:
        wanted = amount(int(needed.group(1)) * 10**9)
        if name:
            return t("disk.room_named", name=name, needed=wanted, free=amount(left))
        return t("disk.room_mac", needed=wanted, free=amount(left))
    if name:
        key = "disk.full_named" if left is not None else "disk.full_named_unknown"
        return t(key, name=name, free=amount(left))
    key = "disk.full_mac" if left is not None else "disk.full_mac_unknown"
    return t(key, free=amount(left))


def describe(error: BaseException, fallback: Path | None = None) -> str:
    """ERROR's words for the player: a full disk's, else the error's own.
    FALLBACK is where the builder was writing, when the error names no file."""
    if not is_full(error):
        return str(error)
    path = Path(error.filename) if isinstance(error, OSError) and isinstance(error.filename, str) and error.filename.startswith("/") else None
    return message(path or fallback, str(error))
