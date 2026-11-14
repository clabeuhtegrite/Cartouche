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
import math
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
# A traceback's frames ('  File "/…/zipfile.py", line 1886, in write') name
# the code that ran, on the Mac's disk, never the disk that filled up.
FRAME = re.compile(r'^\s*File "[^"\n]*", line \d+.*$', re.MULTILINE)


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
    """The path a full disk's message names, when it names one: none of a
    traceback's frames."""
    text = FRAME.sub("", text or "")
    for pattern in NAMED:
        found = pattern.search(text)
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


def disk_name(path: Path | None) -> str:
    """"your Mac's disk", or "the disk “Games”", for words about PATH's disk."""
    name = volume(path)
    return t("room.named", name=name) if name else t("room.mac")


def no_room(path: Path, free_gb: float, needed_gb: float, unpacked_gb: float, keep_gb: int) -> str:
    """The player's words for a game the room kept free on the build
    folders' disk (PATH) did not let build (batch.py): how much is missing,
    and what makes room. NEEDED_GB is what the settings keep free (KEEP_GB),
    and UNPACKED_GB more for a zipped dump. In whole gigabytes, the free
    room rounded down and what is needed up, so that they add up."""
    free, needed = math.floor(free_gb), math.ceil(needed_gb)
    unpack = t("room.unpack", gb=math.ceil(unpacked_gb)) if unpacked_gb > 0 else ""
    return t("batch.no_room", short=needed - free, needed=needed, free=free, disk=disk_name(path), unpack=unpack, keep=keep_gb)


def room(path: Path, keep_gb: int, folders: int) -> dict | None:
    """The room a build has on the build folders' disk (PATH), before one
    starts, for the app's card: what is free and what the settings keep
    free, in whole gigabytes, and when it falls short, the player's words.
    FOLDERS is how many build folders the builder may remove first. None
    when the disk cannot be read (a share not connected)."""
    left = free_bytes(path)
    if left is None:
        return None
    free = math.floor(left / 2**30)
    found: dict = {"free_gb": free, "keep_gb": keep_gb, "folders": folders}
    if free < keep_gb:
        found["title"] = t("room.short_title", short=keep_gb - free)
        older = t("room.folders", count=folders) if folders else ""
        found["text"] = t("room.short", keep=keep_gb, free=free, disk=disk_name(path), folders=older)
    return found
