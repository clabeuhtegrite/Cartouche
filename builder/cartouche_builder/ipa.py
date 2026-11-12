"""IPAs: what an IPA says about its build, its name in the games folder, and
how a new one takes the place of the old one there.

nxnative writes into each app's Info.plist the commit it was built from
(DMCommit, 12 hex digits, "+dirty" for a checkout with changes), the shader
chain it carries (DMChain) and the game's title ID (DMTitleID). Its packer
gives each entry its source file's modification time, so the Info.plist
entry's time is when the app was made. Cartouche reads the same values to
tell a newer IPA of a game from the one installed.
"""

from __future__ import annotations

import errno
import os
import plistlib
import re
import shutil
import subprocess
import sys
import unicodedata
import zipfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from . import titles
from .i18n import t

INFO_PLIST = re.compile(r"^Payload/[^/]+\.app/Info\.plist$")
PARTIAL_SUFFIX = ".builder-partial"


@dataclass
class IpaInfo:
    title_id: str | None
    commit: str | None  # DMCommit without "+dirty"
    dirty: bool
    chain: str | None
    version: str | None
    bundle_id: str | None
    name: str | None
    built: datetime | None  # the Info.plist entry's time (local time)

    @property
    def short_commit(self) -> str | None:
        return self.commit[:12] if self.commit else None


def read_info(path: Path) -> IpaInfo | None:
    """What PATH's Info.plist says, or None for a file that is no app's IPA.

    Only the archive's central directory and one entry are read, a few
    reads even for an IPA of several gigabytes on a network share.
    """
    try:
        with zipfile.ZipFile(path) as archive:
            entries = [i for i in archive.infolist() if INFO_PLIST.match(i.filename)]
            if len(entries) != 1 or entries[0].file_size > 4 << 20:
                return None
            entry = entries[0]
            data = plistlib.loads(archive.read(entry))
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile, plistlib.InvalidFileException, ValueError, EOFError):
        return None
    if not isinstance(data, dict):
        return None

    def text(key: str) -> str | None:
        value = data.get(key)
        return value.strip() if isinstance(value, str) and value.strip() else None

    commit, dirty = text("DMCommit"), False
    if commit and commit.endswith("+dirty"):
        commit, dirty = commit[: -len("+dirty")], True
    title_id = text("DMTitleID")
    if title_id and not titles.is_title_id(title_id):
        title_id = None
    bundle_id = text("CFBundleIdentifier")
    if not title_id and bundle_id and bundle_id.lower().startswith("org.nxnative."):
        candidate = bundle_id[len("org.nxnative.") :][:16]
        title_id = candidate if titles.is_title_id(candidate) else None
    try:
        built = datetime(*entry.date_time)
    except ValueError:
        built = None
    return IpaInfo(
        title_id=title_id.upper() if title_id else None,
        commit=commit.lower() if commit and re.fullmatch(r"[0-9a-fA-F]{7,40}", commit) else None,
        dirty=dirty,
        chain=text("DMChain"),
        version=text("CFBundleShortVersionString"),
        bundle_id=bundle_id,
        name=text("CFBundleDisplayName") or text("CFBundleName"),
        built=built,
    )


# ---- Names -------------------------------------------------------------------


def clean_name(text: str) -> str:
    """TEXT as a file name every server takes, as Cartouche makes it
    (CartoucheStoragePath.fileName): no / \\ : * ? " < > | or control
    characters, no dot or space at its ends, at most 120 characters."""
    refused = set('/\\:*?"<>|')
    cleaned = "".join(" " if c in refused or unicodedata.category(c) in ("Cc", "Cf") else c for c in text)
    cleaned = " ".join(part for part in cleaned.split(" ") if part).strip(". ")
    return cleaned[:120] if cleaned else "Game"


def file_name(game: str, title_id: str) -> str:
    """The name Cartouche gives a game's IPA: "<game> [<title ID>].ipa"."""
    return f"{clean_name(game)} [{title_id.upper()}].ipa"


def find_in_folder(folder: Path, title_id: str, read: bool = True) -> list[Path]:
    """The IPAs of the game in FOLDER: by the [title ID] in their names, and
    (READ) by the Info.plist of the others."""
    try:
        candidates = sorted(p for p in folder.iterdir() if p.suffix.lower() == ".ipa" and p.is_file() and not p.name.startswith("."))
    except OSError:
        return []
    found = [p for p in candidates if title_id.upper() in titles.ids_in_name(p.name)]
    if read:
        for path in candidates:
            if path in found or titles.ids_in_name(path.name):
                continue
            info = read_info(path)
            if info and info.title_id == title_id.upper():
                found.append(path)
    return found


# ---- Delivery ----------------------------------------------------------------


def bundle_romfs(source: Path, image: Path, folder: Path, progress=None) -> Path:
    """Packages a matching external image without rebuilding the IPA.

    For nxnative builds that support <App>/romfs.img. The originals and
    their executable are kept; Cartouche signs the completed app when it
    installs it. A fixed hidden partial keeps incomplete IPAs out of the
    library, including on network storage. The caller holds batch_lock.
    """
    from .romfs import identity

    report = progress or (lambda message: None)
    info, app, wanted = _bundle_input(source)
    name = file_name((info.name or "Game") + " (with ROMFS)", info.title_id)
    target = folder / name
    if target.exists():
        raise ValueError(t("bundle.exists"))
    partial = folder / f".{name}{PARTIAL_SUFFIX}"
    if partial.exists():
        partial.unlink()

    def percent(key):
        last = -1

        def changed(done, total):
            nonlocal last
            value = min(100, done * 100 // max(1, total))
            if value != last:
                last = value
                report(t(key, percent=value))
        return changed

    with image.open("rb") as reader:
        image_stat = os.fstat(reader.fileno())
        if identity(reader) != wanted:
            raise ValueError(t("bundle.mismatch"))
        try:
            report(t("bundle.copy", percent=0))
            if not _clone(source, partial):
                _copy(source, partial, source.stat().st_size, None, percent("bundle.copy"))
            if _bundle_input(partial) != (info, app, wanted):
                raise ValueError(t("bundle.changed_ipa"))
            added = percent("bundle.add")
            with zipfile.ZipFile(partial, "a", allowZip64=True) as archive:
                entry = zipfile.ZipInfo(app + "romfs.img")
                entry.file_size = image_stat.st_size
                entry.external_attr = 0o100644 << 16
                reader.seek(0)
                done = 0
                with archive.open(entry, "w", force_zip64=True) as writer:
                    while block := reader.read(8 << 20):
                        writer.write(block)
                        done += len(block)
                        added(done, image_stat.st_size)
                after = os.fstat(reader.fileno())
                if done != image_stat.st_size or after.st_mtime_ns != image_stat.st_mtime_ns:
                    raise ValueError(t("bundle.changed"))
            report(t("bundle.check"))
            with zipfile.ZipFile(partial) as archive:
                if archive.testzip() is not None:
                    raise ValueError(t("bundle.bad_ipa"))
            try:
                target = _publish(partial, target)
            except FileExistsError:
                raise ValueError(t("bundle.exists")) from None
        except BaseException:
            try:
                partial.unlink()
            except OSError:
                pass
            raise
    return target


def _publish(source: Path, target: Path) -> Path:
    """Publish whole, preserving existing files on local and NAS storage.

    Prefer strict no-replace publication. On shares without exclusive
    rename support, recheck the target before renaming under the batch lock.
    """
    try:
        _rename_exclusive(source, target)
        return target
    except OSError as error:
        if error.errno not in (errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENOSYS):
            raise
    if os.path.lexists(target):
        raise FileExistsError(errno.EEXIST, os.strerror(errno.EEXIST), str(target))
    os.rename(source, target)
    return target


def _rename_exclusive(source: Path, target: Path) -> None:
    if sys.platform == "darwin":
        import ctypes

        rename = ctypes.CDLL(None, use_errno=True).renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(os.fsencode(source), os.fsencode(target), 0x00000004):  # RENAME_EXCL, stdio.h
            number = ctypes.get_errno()
            raise OSError(number, os.strerror(number), str(target))
    else:
        os.link(source, target)
        source.unlink()


def _bundle_input(source: Path) -> tuple[IpaInfo, str, tuple[int, str]]:
    info = read_info(source)
    if not info or not info.title_id:
        raise ValueError(t("bundle.bad_ipa"))
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        if len(set(names)) != len(names):
            raise ValueError(t("bundle.bad_ipa"))
        app = next(name[:-len("Info.plist")] for name in names if INFO_PLIST.match(name))
        if app + "romfs.img" in names or any(name.startswith(app + "romfs/") for name in names):
            raise ValueError(t("bundle.already"))
        expected = archive.getinfo(app + "romfs.id") if app + "romfs.id" in names else None
        if expected is None or expected.file_size > 512:
            raise ValueError(t("bundle.no_identity"))
        try:
            words = archive.read(expected).decode("ascii").split()
            if not words or words[0] != "DMROMFSID1":
                raise ValueError()
            fields = dict(word.split("=", 1) for word in words[1:])
            wanted = int(fields["size"]), fields["index"].lower()
        except (ValueError, KeyError, UnicodeError):
            raise ValueError(t("bundle.no_identity")) from None
    return info, app, wanted


def deliver(source: Path, folder: Path, name: str, stop=None, progress=None) -> Path:
    """Puts SOURCE in FOLDER as NAME, in place of the IPA there under that name.

    It is written as a hidden file first and renamed over the old one only
    once whole, so Cartouche never lists half an IPA and the old one stays
    playable until then. On the same Mac volume the copy is an APFS clone,
    whole at once: PROGRESS hears of it in one step, and a STOP before the
    rename keeps the old one, as it does during a copy.
    """
    target = folder / name
    partial = folder / f".{name}{PARTIAL_SUFFIX}"
    if partial.exists():
        partial.unlink()
    size = source.stat().st_size
    try:
        _check(stop)
        if _clone(source, partial):
            if progress and size:
                progress(size, size)
        else:
            _copy(source, partial, size, stop, progress)
        if partial.stat().st_size != size:
            raise OSError(f"{partial}: {partial.stat().st_size} bytes written of {size}")
        _check(stop)
        os.replace(partial, target)
    except BaseException:
        try:
            partial.unlink()
        except OSError:
            pass
        raise
    return target


def _check(stop) -> None:
    if stop is not None and stop.is_set():
        raise InterruptedError("stopped")


def _clone(source: Path, target: Path) -> bool:
    if sys.platform != "darwin":
        return False
    try:
        if os.stat(source).st_dev != os.stat(target.parent).st_dev:
            return False
        done = subprocess.run(["cp", "-c", str(source), str(target)], capture_output=True, timeout=600)
    except (OSError, subprocess.SubprocessError):
        return False
    if done.returncode != 0:
        try:
            target.unlink()
        except OSError:
            pass
        return False
    return True


def _copy(source: Path, target: Path, size: int, stop, progress) -> None:
    done = 0
    with open(source, "rb") as reader, open(target, "xb") as writer:
        while block := reader.read(8 << 20):
            _check(stop)
            writer.write(block)
            done += len(block)
            if progress:
                progress(done, size)
        writer.flush()
        os.fsync(writer.fileno())
    shutil.copystat(source, target)
