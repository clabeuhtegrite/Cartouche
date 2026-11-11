"""Which game a package or a NUP holds, read from the file itself.

The builder knows each game by its title ID. Most dumps carry it in their
names ("Game [0100000000010000][v0].nsp"), and library.py reads the names
first. A file named without it is read here, the way nxnative reads it at the
build:

- a NUP (a Switch 2 game in one container, https://github.com/a55uka/nup,
  SPEC v1): its table of contents lists each package with its title ID, in
  the clear;
- an NSP or an NSZ: a ticket's name is its rights ID, which starts with the
  title ID; without a ticket, the header of its content meta NCA;
- an XCI or an XCZ (a cartridge dump): the header of the content meta NCAs
  of its secure partition.

An NCA's header is encrypted with the header key of the player's prod.keys
(AES-128-XTS in sectors of 0x200 bytes, with Nintendo's big-endian tweak), so
an XCI, and an NSP without a ticket, need prod.keys: the one the build takes
anyway. Only a few hundred bytes of each NCA's header are read and
decrypted, never the game itself. Python has no AES of its own, and the
builder takes nothing but the standard library, so the cipher is here, and
checked against Python's cryptography package in the tests.

What a file was found to hold is kept in a cache by its path, size and
modification time, so the next look at the sources reads nothing again.
"""

from __future__ import annotations

import json
import os
import re
import struct
import tempfile
from pathlib import Path

from . import titles
from .i18n import t

PACKAGE_SUFFIXES = (".nsp", ".xci", ".nsz", ".xcz")
NUP_SUFFIX = ".nup"
# The header's sector holding its magic, its content type and its program ID.
SECTOR = 0x200
META = 1  # an NCA's content type: the content meta (cnmt)
CONTENT_TYPES = range(6)  # program, meta, control, manual, data, public data
MAX_ENTRIES = 4096  # more files than a game's partition ever has: not a package


class Unreadable(Exception):
    """The file is not a package or a NUP the builder can read, or it names
    no game: the message says why."""


class NeedsKeys(Unreadable):
    """Only prod.keys tells which game the file holds."""


# ---- AES-128 -------------------------------------------------------------------


def _xtime(a: int) -> int:
    a <<= 1
    return a ^ 0x11B if a & 0x100 else a


def _times(a: int, b: int) -> int:
    product = 0
    while b:
        if b & 1:
            product ^= a
        a = _xtime(a)
        b >>= 1
    return product


def _boxes() -> tuple[bytes, bytes]:
    # Each byte's inverse in GF(2^8), from the powers of 3, then the affine map.
    power, log = [0] * 255, [0] * 256
    x = 1
    for i in range(255):
        power[i], log[x] = x, i
        x ^= _xtime(x)
    box = bytearray(256)
    for a in range(256):
        inverse = power[-log[a] % 255] if a else 0
        value = inverse
        for shift in range(1, 5):
            value ^= ((inverse << shift) | (inverse >> (8 - shift))) & 0xFF
        box[a] = value ^ 0x63
    inverse_box = bytearray(256)
    for a, value in enumerate(box):
        inverse_box[value] = a
    return bytes(box), bytes(inverse_box)


_SBOX, _INV_SBOX = _boxes()
_M2, _M3, _M9, _M11, _M13, _M14 = (bytes(_times(a, n) for a in range(256)) for n in (2, 3, 9, 11, 13, 14))
# The state is 16 bytes, column after column; byte i is row i % 4 of column i // 4.
_SHIFT = [((i // 4 + i % 4) % 4) * 4 + i % 4 for i in range(16)]
_INV_SHIFT = [((i // 4 - i % 4) % 4) * 4 + i % 4 for i in range(16)]
_RCON = (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36)


class AES128:
    """AES with a 128-bit key, one 16-byte block at a time (FIPS 197)."""

    def __init__(self, key: bytes):
        if len(key) != 16:
            raise ValueError("AES-128 takes a key of 16 bytes")
        words = [list(key[i : i + 4]) for i in range(0, 16, 4)]
        for i in range(4, 44):
            word = list(words[i - 1])
            if i % 4 == 0:
                word = [_SBOX[b] for b in word[1:] + word[:1]]
                word[0] ^= _RCON[i // 4 - 1]
            words.append([a ^ b for a, b in zip(words[i - 4], word)])
        self._keys = [sum(words[4 * r : 4 * r + 4], []) for r in range(11)]

    def encrypt(self, block: bytes) -> bytes:
        keys = self._keys
        s = [a ^ b for a, b in zip(block, keys[0])]
        for r in range(1, 10):
            s = [_SBOX[s[i]] for i in _SHIFT]
            mixed = []
            for c in range(0, 16, 4):
                a0, a1, a2, a3 = s[c : c + 4]
                mixed += (
                    _M2[a0] ^ _M3[a1] ^ a2 ^ a3,
                    a0 ^ _M2[a1] ^ _M3[a2] ^ a3,
                    a0 ^ a1 ^ _M2[a2] ^ _M3[a3],
                    _M3[a0] ^ a1 ^ a2 ^ _M2[a3],
                )
            s = [a ^ b for a, b in zip(mixed, keys[r])]
        return bytes(_SBOX[s[i]] ^ k for i, k in zip(_SHIFT, keys[10]))

    def decrypt(self, block: bytes) -> bytes:
        keys = self._keys
        s = [a ^ b for a, b in zip(block, keys[10])]
        for r in range(9, 0, -1):
            s = [_INV_SBOX[s[i]] ^ k for i, k in zip(_INV_SHIFT, keys[r])]
            mixed = []
            for c in range(0, 16, 4):
                a0, a1, a2, a3 = s[c : c + 4]
                mixed += (
                    _M14[a0] ^ _M11[a1] ^ _M13[a2] ^ _M9[a3],
                    _M9[a0] ^ _M14[a1] ^ _M11[a2] ^ _M13[a3],
                    _M13[a0] ^ _M9[a1] ^ _M14[a2] ^ _M11[a3],
                    _M11[a0] ^ _M13[a1] ^ _M9[a2] ^ _M14[a3],
                )
            s = mixed
        return bytes(_INV_SBOX[s[i]] ^ k for i, k in zip(_INV_SHIFT, keys[0]))


def _double(tweak: bytes) -> bytes:
    """The tweak times x in GF(2^128), as XTS steps it from block to block."""
    value = int.from_bytes(tweak, "little") << 1
    if value >> 128:
        value = (value & ((1 << 128) - 1)) ^ 0x87
    return value.to_bytes(16, "little")


def xts_decrypt(data_key: bytes, tweak_key: bytes, tweak: bytes, data: bytes) -> bytes:
    """One data unit of AES-128-XTS (IEEE 1619), its tweak given as 16 bytes."""
    cipher = AES128(data_key)
    step = AES128(tweak_key).encrypt(tweak)
    out = bytearray()
    for i in range(0, len(data) - len(data) % 16, 16):
        block = bytes(a ^ b for a, b in zip(data[i : i + 16], step))
        out += bytes(a ^ b for a, b in zip(cipher.decrypt(block), step))
        step = _double(step)
    return bytes(out)


def nintendo_tweak(sector: int) -> bytes:
    """An NCA header sector's tweak: its number, big-endian (hactool's get_tweak)."""
    return sector.to_bytes(16, "big")


# ---- prod.keys -----------------------------------------------------------------


def header_key(keys: Path | None) -> bytes | None:
    """The header_key of a prod.keys file (32 bytes), or None without one."""
    if keys is None:
        return None
    try:
        text = keys.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    for line in text.splitlines():
        name, _, value = line.partition("=")
        if name.strip().lower() == "header_key":
            value = value.strip()
            if re.fullmatch(r"[0-9A-Fa-f]{64}", value):
                return bytes.fromhex(value)
    return None


# ---- NUP -----------------------------------------------------------------------

_NUP_SUPER = struct.Struct("<4sHHQQ32sQQII16s32s")  # 0x80
_NUP_TOC = struct.Struct("<4sIQQQQQ")  # 0x30
_NUP_PACKAGE = struct.Struct("<QIIIIBBHIQI20x")  # 0x40
_NUP_BASE, _NUP_UPDATE, _NUP_ADDON, _NUP_ADDON_UPDATE = 0, 1, 2, 3


def nup_title_ids(path: Path) -> list[str]:
    """The title IDs a NUP's packages carry: the base game's, its updates'
    and its DLC's, as its table of contents lists them."""
    with open(path, "rb") as f:
        head = f.read(_NUP_SUPER.size)
        if len(head) < _NUP_SUPER.size or head[:3] != b"NUP":
            raise Unreadable(t("identify.not_nup"))
        magic, header_size, _, toc_offset, toc_size, _, _, file_size, count, _, _, _ = _NUP_SUPER.unpack(head)
        if magic[3] != 1:
            raise Unreadable(t("identify.nup_version", version=magic[3]))
        if not 0 < count <= MAX_ENTRIES or toc_offset < _NUP_SUPER.size or toc_size < _NUP_TOC.size + count * _NUP_PACKAGE.size:
            raise Unreadable(t("identify.damaged"))
        f.seek(toc_offset)
        toc = f.read(_NUP_TOC.size + count * _NUP_PACKAGE.size)
    if len(toc) < _NUP_TOC.size + count * _NUP_PACKAGE.size or toc[:4] != b"TOC\x01":
        raise Unreadable(t("identify.cut_short"))
    found = []
    for i in range(count):
        title_id, _, _, _, _, kind, *_ = _NUP_PACKAGE.unpack_from(toc, _NUP_TOC.size + i * _NUP_PACKAGE.size)
        if title_id and kind in (_NUP_BASE, _NUP_UPDATE, _NUP_ADDON, _NUP_ADDON_UPDATE):
            found.append(f"{title_id:016X}")
    return found


# ---- NSP, NSZ, XCI and XCZ -----------------------------------------------------


def _partition(f, offset: int, magic: bytes, entry_size: int) -> list[tuple[str, int, int]]:
    """The files of a PFS0 (NSP) or HFS0 (XCI) partition at OFFSET: (name,
    offset in the file, size)."""
    f.seek(offset)
    head = f.read(16)
    if len(head) < 16 or head[:4] != magic:
        raise Unreadable(t("identify.damaged"))
    count, names_size = struct.unpack_from("<II", head, 4)
    if count > MAX_ENTRIES or names_size > 1 << 20:
        raise Unreadable(t("identify.damaged"))
    table = f.read(count * entry_size + names_size)
    if len(table) < count * entry_size + names_size:
        raise Unreadable(t("identify.cut_short"))
    names = table[count * entry_size :]
    data = offset + 16 + count * entry_size + names_size
    files = []
    for i in range(count):
        start, size, name_offset = struct.unpack_from("<QQI", table, i * entry_size)
        end = names.find(b"\0", name_offset)
        name = names[name_offset : end if end >= 0 else len(names)].decode("utf-8", "replace")
        files.append((name, data + start, size))
    return files


def _secure_partition(f) -> list[tuple[str, int, int]]:
    """The files of a cartridge dump's secure partition: the game's NCAs."""
    f.seek(0)
    head = f.read(0x140)
    if len(head) < 0x140 or head[0x100:0x104] != b"HEAD":
        raise Unreadable(t("identify.not_package"))
    root = struct.unpack_from("<Q", head, 0x130)[0]
    for name, offset, _ in _partition(f, root, b"HFS0", 0x40):
        if name == "secure":
            return _partition(f, offset, b"HFS0", 0x40)
    raise Unreadable(t("identify.no_secure"))


def _nca_ids(f, files: list[tuple[str, int, int]], key: bytes) -> list[str]:
    """The title IDs the content meta NCAs of FILES declare in their headers;
    every NCA's program ID when none says it is a content meta."""
    ncas = [(n, o, s) for n, o, s in files if n.lower().endswith((".nca", ".ncz")) and s >= 2 * SECTOR]
    metas = [entry for entry in ncas if ".cnmt." in entry[0].lower()]
    headers = []
    for _, offset, _ in metas or ncas:
        f.seek(offset + SECTOR)
        sector = f.read(SECTOR)
        if len(sector) < SECTOR:
            continue
        plain = xts_decrypt(key[:16], key[16:32], nintendo_tweak(1), sector)
        if plain[:4] not in (b"NCA3", b"NCA2", b"NCA0") or plain[5] not in CONTENT_TYPES:
            continue
        headers.append((plain[5], struct.unpack_from("<Q", plain, 0x10)[0]))
    if not headers:
        raise Unreadable(t("identify.wrong_keys"))
    meta = [program for kind, program in headers if kind == META and program]
    if meta:
        return [f"{program:016X}" for program in meta]
    # No content meta among them: the program, control and manual NCAs say
    # the game's ID (its update's), plus a multi-program game's program index.
    return [f"{program & ~0xF if kind in (0, 2, 3) and not program & 0x7F0 else program:016X}" for kind, program in headers if program]


def package_title_ids(path: Path, key: bytes | None) -> list[str]:
    """The title IDs a package holds: its base game's, its updates' and its
    DLC's. NeedsKeys when only the header key would tell, and none is given."""
    with open(path, "rb") as f:
        head = f.read(0x104)
        if head[:4] == b"PFS0":
            files = _partition(f, 0, b"PFS0", 0x18)
            tickets = [n[:16].upper() for n, _, _ in files if re.fullmatch(r"[0-9A-Fa-f]{32}\.tik", n) and int(n[:16], 16)]
            if tickets:
                return tickets
        elif head[0x100:0x104] == b"HEAD":
            files = _secure_partition(f)
        else:
            raise Unreadable(t("identify.not_package"))
        if key is None:
            raise NeedsKeys("")
        return _nca_ids(f, files, key)


def game_of(ids: list[str]) -> str:
    """The base game of the title IDs a file holds."""
    bases = {titles.base_title_id(i) for i in ids if titles.is_title_id(i)}
    if not bases:
        raise Unreadable(t("identify.no_game"))
    if len(bases) > 1:
        raise Unreadable(t("identify.several_games", ids=", ".join(sorted(bases))))
    return bases.pop()


# ---- The cache -----------------------------------------------------------------


class Reader:
    """Reads which game each file holds, through the cache at CACHE (a JSON
    file; None keeps nothing). KEYS is the player's prod.keys, or None."""

    def __init__(self, keys: Path | None = None, cache: Path | None = None):
        self.key = header_key(keys)
        self.cache = cache
        self._entries: dict[str, dict] | None = None
        self._changed = False
        self._seen: set[str] = set()

    def _load(self) -> dict[str, dict]:
        if self._entries is None:
            self._entries = {}
            if self.cache is not None:
                try:
                    data = json.loads(self.cache.read_text(encoding="utf-8"))
                    if isinstance(data, dict) and data.get("version") == 1 and isinstance(data.get("files"), dict):
                        self._entries = {k: v for k, v in data["files"].items() if isinstance(v, dict)}
                except (OSError, ValueError):
                    pass
        return self._entries

    def ids(self, path: Path) -> list[str]:
        """The title IDs PATH holds. Unreadable (or NeedsKeys) says why it
        tells none."""
        try:
            info = path.stat()
        except OSError as error:
            raise Unreadable(error.strerror or str(error)) from error
        entries = self._load()
        name = str(path)
        self._seen.add(name)
        entry = entries.get(name)
        if entry and entry.get("size") == info.st_size and entry.get("mtime") == info.st_mtime_ns:
            if isinstance(entry.get("ids"), list):
                return [str(i) for i in entry["ids"]]
            # A file that needed the keys is read again once they are there.
            if entry.get("needs_keys") and self.key is None:
                raise NeedsKeys("")
        try:
            if path.suffix.lower() == NUP_SUFFIX:
                found = nup_title_ids(path)
            else:
                found = package_title_ids(path, self.key)
        except NeedsKeys:
            self._keep(name, {"size": info.st_size, "mtime": info.st_mtime_ns, "needs_keys": True})
            raise
        except Unreadable:
            # Not kept: it says why in the player's language, each time.
            self._keep(name, None)
            raise
        except (OSError, ValueError, struct.error) as error:
            raise Unreadable(str(error)) from error
        self._keep(name, {"size": info.st_size, "mtime": info.st_mtime_ns, "ids": found})
        return found

    def _keep(self, name: str, entry: dict | None) -> None:
        entries = self._load()
        if entry is None:
            if entries.pop(name, None) is not None:
                self._changed = True
        elif entries.get(name) != entry:
            entries[name] = entry
            self._changed = True

    def save(self) -> None:
        """Writes the cache, without the files no longer looked at."""
        if self.cache is None or self._entries is None:
            return
        gone = set(self._entries) - self._seen
        if not self._changed and not gone:
            return
        for name in gone:
            del self._entries[name]
        temporary = None
        try:
            self.cache.parent.mkdir(parents=True, exist_ok=True)
            fd, temporary = tempfile.mkstemp(dir=self.cache.parent, prefix=f".{self.cache.name}.", suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as out:
                json.dump({"version": 1, "files": self._entries}, out)
            os.replace(temporary, self.cache)
        except OSError:
            # Only a cache: the next look reads the files again.
            if temporary:
                Path(temporary).unlink(missing_ok=True)
