"""The publish guard: the last check before a file goes to the update server.

Cartouche's update server carries the project's own build outputs only. This
module refuses a file, or any file inside an archive, that looks like game
content, a console key or firmware, so that a mistake in a build script
cannot put one on the server. It fails closed: a file it cannot read is
refused too.

What it refuses:

* names and extensions of Switch content and keys (``.nsp``, ``.xci``,
  ``.nca``, ``.nso``, ``prod.keys``, ``romfs.img``...);
* the magic numbers of those formats, wherever the file is;
* Mach-O images that carry a game's rewritten code, which nxnative's
  ``gen_embed.py`` puts in ``__TEXT,__dm*`` sections and ``__DM*`` segments;
* an app archive whose bundle identifier is not Cartouche's;
* in catalog files, any URL, and any key that names a link or a download;
* files far larger than any build output.
"""

from __future__ import annotations

import io
import json
import plistlib
import struct
import tarfile
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterator

MiB = 1 << 20
GiB = 1 << 30

MAX_SIZE = {
    "app": 1 * GiB,
    "engine-host": 512 * MiB,
    "toolchain": 2 * GiB,
    "pipeline-list": 64 * MiB,
    "catalog": 8 * MiB,
}
MAX_MEMBER = 1 * GiB
MAX_NESTING = 3

FORBIDDEN_SUFFIXES = {
    ".nsp", ".nsz", ".xci", ".xcz", ".nca", ".ncz", ".nup",
    ".nso", ".nro", ".nrr", ".kip", ".keys", ".tik", ".romfs",
}
FORBIDDEN_NAMES = {"prod.keys", "title.keys", "dev.keys", "romfs.img", "romfs.bin"}

# (offset, magic, smallest file it is checked in, what it is). The weaker
# magics only count in files of a megabyte or more, as game images are.
MAGICS = (
    (0x0, b"PFS0", 0, "a Switch PFS0 partition (NSP)"),
    (0x0, b"HFS0", 0, "a Switch HFS0 partition (XCI)"),
    (0x0, b"NSO0", 0, "a Switch executable (NSO)"),
    (0x10, b"NRO0", 0, "a Switch executable (NRO)"),
    (0x0, b"KIP1", 0, "a Switch kernel initial process (KIP)"),
    (0x0, b"IVFC", 0, "a Switch RomFS hash tree"),
    (0x4000, b"NCZSECTN", 0, "a compressed Switch content archive (NCZ)"),
    (0x100, b"HEAD", MiB, "a Switch game card image (XCI)"),
    (0x0, struct.pack("<Q", 0x50), MiB, "a Switch RomFS image"),
)

ARCHIVE_SUFFIXES = (".zip", ".ipa", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2")

LINK_KEYS = ("url", "uri", "href", "link", "download", "magnet", "torrent", "mirror")


class Rejected(ValueError):
    """The file must not be published."""


@dataclass(frozen=True)
class Blob:
    name: str  # path inside the artifact, for messages
    data: bytes


# --------------------------------------------------------------------------
# Mach-O


_MH_MAGIC_64 = 0xFEEDFACF
_FAT_MAGIC = 0xCAFEBABE
_FAT_MAGIC_64 = 0xCAFEBABF
_LC_SEGMENT_64 = 0x19


def is_macho(data: bytes) -> bool:
    if len(data) < 8:
        return False
    if struct.unpack_from("<I", data)[0] == _MH_MAGIC_64:
        return True
    magic, count = struct.unpack_from(">II", data)
    # Java class files also start with CAFEBABE; their second word is a
    # class-file version, far above any plausible slice count.
    return magic in (_FAT_MAGIC, _FAT_MAGIC_64) and 0 < count <= 32


def macho_segments(data: bytes) -> Iterator[tuple[str, list[str]]]:
    """Yield (segment name, section names) for each segment of each slice."""
    magic = struct.unpack_from(">I", data)[0]
    if magic in (_FAT_MAGIC, _FAT_MAGIC_64):
        count = struct.unpack_from(">I", data, 4)[0]
        entry = 32 if magic == _FAT_MAGIC_64 else 20
        for i in range(count):
            at = 8 + i * entry
            if at + entry > len(data):
                raise Rejected("malformed fat Mach-O header")
            if magic == _FAT_MAGIC_64:
                offset, size = struct.unpack_from(">QQ", data, at + 8)
            else:
                offset, size = struct.unpack_from(">II", data, at + 8)
            if offset + size > len(data):
                raise Rejected("a Mach-O slice runs past the end of the file")
            yield from macho_segments(data[offset : offset + size])
        return
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != _MH_MAGIC_64:
        raise Rejected("only 64-bit Mach-O images are expected")
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    at, end = 32, 32 + sizeofcmds
    if end > len(data):
        raise Rejected("malformed Mach-O load commands")
    for _ in range(ncmds):
        if at + 8 > end:
            raise Rejected("malformed Mach-O load commands")
        cmd, cmdsize = struct.unpack_from("<II", data, at)
        if cmdsize < 8 or at + cmdsize > end:
            raise Rejected("malformed Mach-O load command")
        if cmd == _LC_SEGMENT_64:
            if cmdsize < 72:
                raise Rejected("malformed Mach-O segment")
            segname = data[at + 8 : at + 24].rstrip(b"\0").decode("ascii", "replace")
            nsects = struct.unpack_from("<I", data, at + 64)[0]
            if 72 + nsects * 80 > cmdsize:
                raise Rejected("malformed Mach-O segment")
            sections = [
                data[at + 72 + j * 80 : at + 72 + j * 80 + 16].rstrip(b"\0").decode("ascii", "replace")
                for j in range(nsects)
            ]
            yield segname, sections
        at += cmdsize


def check_macho(blob: Blob) -> None:
    for segname, sections in macho_segments(blob.data):
        if segname.startswith("__DM"):
            raise Rejected(f"{blob.name}: segment {segname} holds a game's rewritten code")
        for sect in sections:
            if sect.startswith("__dm"):
                raise Rejected(f"{blob.name}: section {segname},{sect} holds a game's rewritten code")


# --------------------------------------------------------------------------
# Generic checks


def check_name(name: str) -> None:
    path = PurePosixPath(name.replace("\\", "/"))
    lower = path.name.lower()
    if lower in FORBIDDEN_NAMES:
        raise Rejected(f"{name}: {path.name} is game content or a key file")
    for suffix in path.suffixes:
        if suffix.lower() in FORBIDDEN_SUFFIXES:
            raise Rejected(f"{name}: {suffix} files are game content, keys or firmware")


def check_magic(blob: Blob) -> None:
    for offset, magic, min_size, what in MAGICS:
        if len(blob.data) >= min_size and blob.data[offset : offset + len(magic)] == magic:
            raise Rejected(f"{blob.name}: looks like {what}")


def _is_archive(name: str, data: bytes) -> str | None:
    lower = name.lower()
    if data[:4] == b"PK\x03\x04" or lower.endswith((".zip", ".ipa")):
        return "zip"
    if lower.endswith((".tar", ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2")):
        return "tar"
    return None


def _members(blob: Blob, kind: str) -> Iterator[Blob]:
    try:
        if kind == "zip":
            with zipfile.ZipFile(io.BytesIO(blob.data)) as archive:
                for info in archive.infolist():
                    if info.is_dir():
                        continue
                    if info.file_size > MAX_MEMBER:
                        raise Rejected(f"{blob.name}/{info.filename}: {info.file_size} bytes is far larger than any build output")
                    yield Blob(f"{blob.name}/{info.filename}", archive.read(info))
        else:
            with tarfile.open(fileobj=io.BytesIO(blob.data)) as archive:
                for info in archive:
                    if not info.isfile():
                        continue
                    if info.size > MAX_MEMBER:
                        raise Rejected(f"{blob.name}/{info.name}: {info.size} bytes is far larger than any build output")
                    handle = archive.extractfile(info)
                    yield Blob(f"{blob.name}/{info.name}", handle.read() if handle else b"")
    except (zipfile.BadZipFile, tarfile.TarError, EOFError, OSError) as exc:
        raise Rejected(f"{blob.name}: cannot read the archive ({exc})") from exc


def check_blob(blob: Blob, depth: int = 0) -> None:
    """Name, magic and Mach-O checks, then the same for every archive member."""
    check_name(blob.name)
    archive = _is_archive(blob.name, blob.data)
    if archive is None:
        check_magic(blob)
        if is_macho(blob.data):
            check_macho(blob)
        return
    if depth >= MAX_NESTING:
        raise Rejected(f"{blob.name}: archives nested too deeply")
    for member in _members(blob, archive):
        check_blob(member, depth + 1)


# --------------------------------------------------------------------------
# Kind-specific checks


def app_bundle_id(data: bytes) -> str:
    """CFBundleIdentifier of the top-level app in an IPA."""
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        plists = [
            n for n in archive.namelist()
            if len(PurePosixPath(n).parts) == 3
            and PurePosixPath(n).parts[0] == "Payload"
            and PurePosixPath(n).parts[1].endswith(".app")
            and PurePosixPath(n).parts[2] == "Info.plist"
        ]
        if len(plists) != 1:
            raise Rejected("an IPA must hold exactly one Payload/<name>.app")
        try:
            info = plistlib.loads(archive.read(plists[0]))
        except Exception as exc:  # plistlib raises several unrelated types
            raise Rejected(f"cannot read {plists[0]} ({exc})") from exc
    bundle_id = info.get("CFBundleIdentifier")
    if not isinstance(bundle_id, str):
        raise Rejected("the app has no CFBundleIdentifier")
    return bundle_id


def _walk_catalog(value: Any, where: str) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if any(word in key.lower() for word in LINK_KEYS):
                raise Rejected(f"{where}: key {key!r} is not allowed in a catalog file")
            _walk_catalog(item, f"{where}.{key}")
    elif isinstance(value, list):
        for i, item in enumerate(value):
            _walk_catalog(item, f"{where}[{i}]")
    elif isinstance(value, str) and ("://" in value or value.lower().startswith(("www.", "magnet:"))):
        raise Rejected(f"{where}: catalog files hold no URLs")


def check_catalog(data: bytes, name: str = "catalog") -> None:
    try:
        parsed = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise Rejected(f"{name}: not UTF-8 JSON ({exc})") from exc
    _walk_catalog(parsed, name)


def check_pipeline_list(data: bytes, name: str = "pipeline list") -> None:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Rejected(f"{name}: a pipeline list is UTF-8 text") from exc
    if "\0" in text:
        raise Rejected(f"{name}: a pipeline list is text, not binary data")


def check_file(path: Path, kind: str, *, app_bundle_id_expected: str | None = None) -> None:
    """Raise Rejected unless ``path`` may be published as an artifact of ``kind``."""
    if kind not in MAX_SIZE:
        raise Rejected(f"unknown kind {kind!r}")
    size = path.stat().st_size
    if size > MAX_SIZE[kind]:
        raise Rejected(f"{path.name}: {size} bytes is over the {MAX_SIZE[kind]} byte limit for {kind}")
    data = path.read_bytes()
    # Content first, so that a game file is named as such whatever its kind.
    check_blob(Blob(path.name, data))
    if kind == "app":
        if not app_bundle_id_expected:
            raise Rejected("checking an app needs the expected bundle identifier")
        if _is_archive(path.name, data) != "zip":
            raise Rejected(f"{path.name}: an app is published as an IPA")
        found = app_bundle_id(data)
        if found != app_bundle_id_expected:
            raise Rejected(f"{path.name}: bundle identifier {found} is not Cartouche's ({app_bundle_id_expected})")
    elif kind == "engine-host":
        if not is_macho(data) and _is_archive(path.name, data) is None:
            raise Rejected(f"{path.name}: an engine host is a Mach-O image or an archive of one")
    elif kind == "toolchain":
        if _is_archive(path.name, data) is None:
            raise Rejected(f"{path.name}: a toolchain is published as an archive")
    elif kind == "pipeline-list":
        check_pipeline_list(data, path.name)
    elif kind == "catalog":
        check_catalog(data, path.name)
