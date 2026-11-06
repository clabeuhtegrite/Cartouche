"""Small synthetic files for the tests. None of them holds real game data."""

from __future__ import annotations

import io
import plistlib
import struct
import tarfile
import zipfile

from cartouche_guard import APP_BUNDLE_ID


def macho(segments: list[tuple[str, list[str]]]) -> bytes:
    """A 64-bit arm64 Mach-O header with the given segments and sections."""
    commands = b""
    for segname, sections in segments:
        size = 72 + 80 * len(sections)
        commands += struct.pack("<II16sQQQQiiII", 0x19, size, segname.encode(), 0, 0, 0, 0, 7, 5, len(sections), 0)
        for sectname in sections:
            commands += struct.pack("<16s16sQQIIIIIIII", sectname.encode(), segname.encode(), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, len(segments), len(commands), 0, 0)
    return header + commands


def fat(*slices: bytes) -> bytes:
    """A fat (universal) Mach-O holding the given slices."""
    offset = 8 + 20 * len(slices)
    header = struct.pack(">II", 0xCAFEBABE, len(slices))
    body = b""
    for data in slices:
        header += struct.pack(">iiIII", 0x0100000C, 0, offset + len(body), len(data), 0)
        body += data
    return header + body


CLEAN_MACHO = macho([("__PAGEZERO", []), ("__TEXT", ["__text", "__stubs"]), ("__DATA", ["__data"]), ("__LINKEDIT", [])])
GAME_SEGMENT_MACHO = macho([("__TEXT", ["__text"]), ("__DMmainW", ["__img"])])
GAME_SECTION_MACHO = macho([("__TEXT", ["__text", "__dmmainx0"])])


def zip_bytes(files: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in files.items():
            archive.writestr(name, data)
    return buffer.getvalue()


def tar_gz_bytes(files: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def ipa(bundle_id: str = APP_BUNDLE_ID, extra: dict[str, bytes] | None = None) -> bytes:
    files = {
        "Payload/LiveContainer.app/Info.plist": plistlib.dumps({"CFBundleIdentifier": bundle_id}),
        "Payload/LiveContainer.app/LiveContainer": CLEAN_MACHO,
        "Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/Info.plist": plistlib.dumps(
            {"CFBundleIdentifier": "com.SideStore.SideStore"}
        ),
    }
    files.update(extra or {})
    return zip_bytes(files)
