"""The games' Mac apps: the app nxnative makes of a game for this Mac
(build_ipa_from_nsp.py --platform mac-app), put in the Mac apps folder.

nxnative packs a self-contained app of the game (dm/mac/pack_app.py): its
launcher, its Mac host, the game's files, its shaders. Its Info.plist names
the game (DMTitleID), the commit it was made from (DMCommit, "+dirty" for a
checkout with changes), the shader chain it carries (DMChain) and the game's
version, as an IPA's does. On the build folder's disk its large files are
APFS clones of the extracted ones: the app takes no room of its own there.
Its save and its log are not in it, but in the player's Library, by the
game's title ID (~/Library/Application Support/nxnative/<title ID>/, its
log in ~/Library/Logs/nxnative/), so an app built again plays the same save.

The builder has nxnative write the app in the workspace, then keeps it in
the games folder, beside the game's IPA (Place):

- On a disk of this Mac's own kind (APFS, Mac OS Extended), the app is put
  there as it is, and played from there: whole, under a hidden name first,
  then in place of the game's app there. It never takes the place of an app
  that is not this game's (another app of the same name gets
  "<game> [<title ID>].app"), nor of the game's app while the game runs.
- On a NAS's share, or a disk formatted for Windows, which keep neither an
  app's links nor its modes, the app is kept in one file,
  "<game> [<title ID>].app.zip", as an IPA is (pack). This Mac plays a copy
  of it, put in the Mac apps folder (the Applications folder of the
  player's session unless the settings name another): unpacked when the
  game is first played (install), and made again of each new build while
  it is there, so that the Mac keeps only the games the player plays.
"""

from __future__ import annotations

import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import threading
import time
import unicodedata
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from . import titles
from .i18n import t
from .ipa import clean_name as file_name_of
from .library import walk_size
from .workspace import remove_tree, same_volume

PARTIAL_SUFFIX = ".builder-partial"
OLD_SUFFIX = ".builder-old"
# A game's app kept in one file, beside its IPA.
PACKED_SUFFIX = ".app.zip"
# "1" keeps the apps in one file whatever the games folder's disk, "0" never:
# for the tests, whose folders are all on one disk.
PACKED_ENV = "CARTOUCHE_BUILDER_MAC_PACKED"
# The filesystems an app lives on as it is, its links, modes and extended
# attributes with it.
APP_FILESYSTEMS = ("apfs", "hfs")


@dataclass
class AppInfo:
    title_id: str | None
    commit: str | None  # DMCommit without "+dirty"
    dirty: bool
    chain: str | None
    version: str | None
    bundle_id: str | None
    name: str | None


def read_info(app: Path) -> AppInfo | None:
    """What APP's Info.plist says, or None for a folder that is no app."""
    try:
        with open(app / "Contents" / "Info.plist", "rb") as stream:
            data = plistlib.loads(stream.read(4 << 20))
    except (OSError, plistlib.InvalidFileException, ValueError, EOFError):
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
    return AppInfo(
        title_id=title_id.upper() if title_id and titles.is_title_id(title_id) else None,
        commit=commit.lower() if commit and re.fullmatch(r"[0-9a-fA-F]{7,40}", commit) else None,
        dirty=dirty,
        chain=text("DMChain"),
        version=text("CFBundleShortVersionString"),
        bundle_id=text("CFBundleIdentifier"),
        name=text("CFBundleDisplayName") or text("CFBundleName"),
    )


def is_games(app: Path, title_id: str) -> bool:
    """Whether APP is an app of the game TITLE_ID, as nxnative makes them."""
    info = read_info(app)
    return bool(info and info.title_id == title_id.upper())


# ---- Names -------------------------------------------------------------------


def clean_name(name: str) -> str:
    """The game's name as nxnative names its app (mac_app_name): ":" and "/",
    which the Finder shows otherwise, as " - "; no control characters, no
    dot, dash or space at its ends, at most 120 characters."""
    cleaned = re.sub(r"\s*[:/]\s*", " - ", name)
    cleaned = "".join(" " if unicodedata.category(c) in ("Cc", "Cf") else c for c in cleaned)
    cleaned = " ".join(part for part in cleaned.split(" ") if part).strip(" .-")
    return cleaned[:120].rstrip(" .-") if cleaned else "Game"


def target_name(folder: Path, title_id: str, name: str, recorded: str = "") -> str:
    """The name the game's app gets in FOLDER: the one it had (RECORDED),
    while the app there is still the game's or is gone; else "<name>.app",
    unless another app has that name, then "<name> [<title ID>].app"."""
    title_id = title_id.upper()
    if recorded and _free_or_games(folder / recorded, title_id):
        return recorded
    plain = f"{clean_name(name)}.app"
    if _free_or_games(folder / plain, title_id):
        return plain
    return f"{clean_name(name)} [{title_id}].app"


def _free_or_games(path: Path, title_id: str) -> bool:
    if not os.path.lexists(path):
        return True
    return path.is_dir() and not path.is_symlink() and is_games(path, title_id)


def packed_name(name: str, title_id: str) -> str:
    """The name of the game's app kept in one file, as its IPA's beside it
    ("<game> [<title ID>].ipa"): "<game> [<title ID>].app.zip"."""
    return f"{file_name_of(name)} [{title_id.upper()}]{PACKED_SUFFIX}"


# ---- Where the apps are kept ------------------------------------------------------


@dataclass
class Place:
    """Where the games' Mac apps are: LIBRARY, the games folder, keeps each
    game's app, in one file when PACKED; this Mac then plays a copy of it,
    in INSTALLS, the Mac apps folder."""

    library: Path
    packed: bool
    installs: Path

    def find(self, title_id: str, recorded: str = "", kept: dict[str, Path] | None = None) -> Path | None:
        """The game's app as the games folder keeps it: its app, or its
        file when PACKED (KEPT: self.index(), when it was made already)."""
        if self.packed:
            if recorded.endswith(PACKED_SUFFIX):
                path = self.library / recorded
                if path.is_file():
                    return path
            return (index_packed(self.library) if kept is None else kept).get(title_id.upper())
        return find(self.library, title_id, recorded if recorded.endswith(".app") else "", kept)

    def index(self) -> dict[str, Path]:
        return index_packed(self.library) if self.packed else index(self.library)

    def copy(self, title_id: str, recorded: str = "", copies: dict[str, Path] | None = None) -> Path | None:
        """The app this Mac plays the game from: its copy in INSTALLS when
        the games folder keeps it PACKED, else the games folder's app."""
        if self.packed:
            return find(self.installs, title_id, recorded, copies)
        return find(self.library, title_id, recorded, copies)

    def copies(self) -> dict[str, Path]:
        return index(self.installs if self.packed else self.library)


def place(config) -> Place:
    """Where CONFIG's games keep their Mac apps: in the games folder (the Mac
    apps folder when none is chosen), packed unless it holds apps."""
    games = config.path("games")
    installs = config.mac_apps_path()
    if games is None:
        return Place(library=installs, packed=False, installs=installs)
    return Place(library=games, packed=not holds_apps(games, shares=config.shares), installs=installs)


# "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse)",
# "//player@nas.local/Games on /Volumes/Games (smbfs, nodev, nosuid, mounted by player)"
MOUNT_LINE = re.compile(r"^.+? on (?P<point>/.*?) \((?P<kind>[\w.-]+)")


def filesystem(folder: Path, mounted: str | None = None) -> str | None:
    """The filesystem FOLDER is on ("apfs", "smbfs", "exfat"…), as `mount`
    says (MOUNTED: what it said), or None when it cannot tell."""
    if mounted is None:
        if sys.platform != "darwin":
            return None
        try:
            mounted = subprocess.run(["mount"], capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            return None
    try:
        device = os.stat(folder).st_dev
    except OSError:
        return None
    for line in mounted.splitlines():
        match = MOUNT_LINE.match(line.strip())
        if not match:
            continue
        try:
            if os.stat(match.group("point")).st_dev == device:
                return match.group("kind").lower()
        except OSError:
            continue
    return None


def holds_apps(folder: Path, mounted: str | None = None, shares=()) -> bool:
    """Whether a Mac app can be kept in FOLDER as it is, and played from
    there: on a disk of this Mac's own kind (APFS, Mac OS Extended). Not on
    a NAS's share (SHARES: the mount points of the player's shares, mounted
    or not), nor on a disk formatted for Windows: the app is kept there in
    one file instead."""
    forced = os.environ.get(PACKED_ENV, "")
    if forced in ("0", "1"):
        return forced == "0"
    for point in shares:
        if _within(folder, Path(point)):
            return False
    kind = filesystem(folder, mounted)
    return kind is None or kind in APP_FILESYSTEMS


def _within(path: Path, folder: Path) -> bool:
    try:
        path.expanduser().relative_to(folder.expanduser())
        return True
    except ValueError:
        return False


def index_packed(folder: Path | None) -> dict[str, Path]:
    """The games' apps kept in one file in FOLDER, by the title ID their
    names end with: "<game> [<title ID>].app.zip"."""
    found: dict[str, Path] = {}
    if folder is None:
        return found
    try:
        candidates = sorted(p for p in folder.iterdir() if p.name.lower().endswith(PACKED_SUFFIX) and not p.name.startswith(".") and p.is_file())
    except OSError:
        return found
    for path in candidates:
        ids = [i for i in titles.ids_in_name(path.name[: -len(PACKED_SUFFIX)]) if titles.is_title_id(i)]
        if ids and ids[0] not in found:
            found[ids[0]] = path
    return found


def index(folder: Path | None) -> dict[str, Path]:
    """The games' apps in FOLDER, by title ID: the apps there whose
    Info.plist names a game, the first by name for a game with two."""
    found: dict[str, Path] = {}
    if folder is None:
        return found
    try:
        candidates = sorted(p for p in folder.iterdir() if p.suffix == ".app" and not p.name.startswith(".") and p.is_dir() and not p.is_symlink())
    except OSError:
        return found
    for path in candidates:
        info = read_info(path)
        if info and info.title_id and info.title_id not in found:
            found[info.title_id] = path
    return found


def find(folder: Path | None, title_id: str, recorded: str = "", apps: dict[str, Path] | None = None) -> Path | None:
    """The game's app in FOLDER: by the name it was given (RECORDED), else
    an app there whose Info.plist names the game (APPS: index(FOLDER),
    when it was made already)."""
    if folder is None:
        return None
    if recorded:
        path = folder / recorded
        if path.is_dir() and not path.is_symlink() and is_games(path, title_id):
            return path
    return (index(folder) if apps is None else apps).get(title_id.upper())


# ---- The game, running ----------------------------------------------------------


def running(app: Path) -> bool:
    """Whether a process runs from APP (its launcher or its host): its
    files must stay as they are until it ends."""
    marker = str(app).rstrip("/") + "/Contents/MacOS/"
    try:
        done = subprocess.run(["ps", "-axww", "-o", "args="], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    return any(marker in line for line in done.stdout.splitlines())


# ---- Delivery ------------------------------------------------------------------


def deliver(built: Path, folder: Path, name: str, stop=None) -> Path:
    """Puts BUILT, the app nxnative made in the workspace, in FOLDER as NAME,
    in place of the app there under that name (target_name chose it: none,
    or the game's own).

    On the same volume the app moves, whole at once, and its files keep the
    blocks they share with the build folder's; on another one it is copied
    under a hidden name first. Either way the old app stays until the new one
    is whole, and goes once the new one is in its place. Nothing of BUILT is
    left in the workspace."""
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / name
    staged = folder / f".{name}{PARTIAL_SUFFIX}"
    aside = folder / f".{name}{OLD_SUFFIX}"
    remove_tree(staged)
    remove_tree(aside)
    try:
        _check(stop)
        if same_volume(built.parent, folder):
            os.rename(built, staged)
        else:
            _copy_tree(built, staged, stop)
        _check(stop)
        if os.path.lexists(target):
            os.rename(target, aside)
            try:
                os.rename(staged, target)
            except BaseException:
                os.rename(aside, target)
                raise
        else:
            os.rename(staged, target)
    except BaseException:
        remove_tree(staged)
        raise
    remove_tree(aside)
    forget_built(built)
    return target


def forget_built(built: Path) -> None:
    """Removes what nxnative left of an app in the workspace (BUILT, and
    its packer's .partial, .old and .key beside it): delivered, or not to be
    delivered, an app there would keep the blocks it shares with the build
    folder's files after that folder is gone. The next build makes the app
    again (its packing takes a minute; the shaders and the host stay in the
    build folder)."""
    for path in (built, Path(f"{built}.partial"), Path(f"{built}.old"), Path(f"{built}.key"), _named_folder(built)):
        remove_tree(path)


def _copy_tree(source: Path, target: Path, stop) -> None:
    def copy(src: str, dst: str) -> str:
        _check(stop)
        return shutil.copy2(src, dst)

    shutil.copytree(source, target, symlinks=True, copy_function=copy)


def _check(stop) -> None:
    if stop is not None and stop.is_set():
        raise InterruptedError("stopped")


# ---- Kept in one file -------------------------------------------------------------


def named(built: Path, name: str) -> Path:
    """BUILT, which nxnative named after the title ID in the workspace, as
    "<NAME>.app" in a folder of its own beside it: the app kept in one file
    unpacks under the game's name, in the Finder too."""
    folder = _named_folder(built)
    remove_tree(folder)
    folder.mkdir(parents=True)
    target = folder / f"{clean_name(name)}.app"
    os.rename(built, target)
    return target


def _named_folder(built: Path) -> Path:
    return built.parent / f".{built.name}.named"


def pack(app: Path, target: Path, stop=None) -> int:
    """Writes APP whole in the file TARGET, as macOS zips an app (ditto):
    under a hidden name first, then in place of the file there, so that the
    folder never holds half of it and the old one stays until then. Returns
    its size."""
    folder = target.parent
    folder.mkdir(parents=True, exist_ok=True)
    partial = folder / f".{target.name}{PARTIAL_SUFFIX}"
    remove_tree(partial)
    try:
        _check(stop)
        if _ditto():
            # Barely compressed: the game's files are, and the NAS's network
            # is slower than the compression it would take.
            _run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", "--zlibCompressionLevel", "1", str(app), str(partial)], stop)
        else:
            _zip(app, partial, stop)
        _check(stop)
        os.replace(partial, target)
    except BaseException:
        remove_tree(partial)
        raise
    return target.stat().st_size


def unpacked_size(packed: Path) -> int:
    """The bytes the app kept in PACKED takes once unpacked."""
    try:
        with zipfile.ZipFile(packed) as archive:
            return sum(entry.file_size for entry in archive.infolist())
    except (OSError, zipfile.BadZipFile, ValueError) as error:
        raise ValueError(t("mac.not_packed", name=packed.name)) from error


def refuse_unsafe(packed: Path) -> None:
    """Refuses the zip PACKED when unpacking it could write outside the
    folder it is unpacked in: an absolute name, a "..", a name twice (the
    second written through the first, a link), or a name under a link.
    ditto, which unpacks it on macOS, does not refuse them all; nxnative's
    apps, which ditto zipped, have none."""
    with zipfile.ZipFile(packed) as archive:
        entries = archive.infolist()
        names: set[str] = set()
        links: set[str] = set()
        for entry in entries:
            parts = PurePosixPath(entry.filename).parts
            if not parts or entry.filename.startswith("/") or ".." in parts:
                raise ValueError(t("mac.not_packed", name=packed.name))
            name = "/".join(parts)
            if name in names:
                raise ValueError(t("mac.not_packed", name=packed.name))
            names.add(name)
            if stat.S_ISLNK(entry.external_attr >> 16):
                links.add(name)
        for name in names:
            parts = name.split("/")
            if any("/".join(parts[:depth]) in links for depth in range(1, len(parts))):
                raise ValueError(t("mac.not_packed", name=packed.name))


def install(packed: Path, folder: Path, title_id: str, name: str, stop=None, progress=None) -> Path:
    """Puts the game's app kept in PACKED in FOLDER as NAME, in place of the
    game's app there (target_name chose NAME): unpacked beside it under a
    hidden name, then moved in whole as a build is (deliver). PROGRESS hears
    of the bytes unpacked, and of all there are."""
    total = unpacked_size(packed)
    refuse_unsafe(packed)
    folder.mkdir(parents=True, exist_ok=True)
    staging = folder / f".{name}.builder-unpack"
    remove_tree(staging)
    staging.mkdir()
    try:
        if _ditto():
            _run(["ditto", "-x", "-k", str(packed), str(staging)], stop, progress, lambda: walk_size(staging), total)
        else:
            _unzip(packed, staging, stop, progress, total)
        _check(stop)
        apps = [p for p in staging.iterdir() if p.suffix == ".app" and p.is_dir() and not p.is_symlink()]
        if len(apps) != 1 or not is_games(apps[0], title_id):
            raise ValueError(t("mac.not_packed", name=packed.name))
        if progress:
            progress(total, total)
        return deliver(apps[0], folder, name, stop=stop)
    finally:
        remove_tree(staging)


def _ditto() -> bool:
    return sys.platform == "darwin" and os.path.exists("/usr/bin/ditto")


def _run(args: list[str], stop, progress=None, measure=None, total: int = 0) -> None:
    """Runs ARGS to its end, or stops it at STOP; PROGRESS hears every two
    seconds what MEASURE says is done."""
    process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    said = b""
    told = time.monotonic()
    try:
        while True:
            try:
                _, said = process.communicate(timeout=1.0)
                break
            except subprocess.TimeoutExpired:
                pass
            if stop is not None and stop.is_set():
                process.terminate()
                process.communicate()
                raise InterruptedError("stopped")
            if progress and measure and total and time.monotonic() - told >= 2:
                told = time.monotonic()
                progress(min(measure(), total), total)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    if process.returncode != 0:
        words = said.decode("utf-8", "replace").strip().splitlines()
        raise OSError(f"{args[0]}: {words[-1] if words else f'exit {process.returncode}'}")


def _zip(app: Path, target: Path, stop) -> None:
    """APP in the zip TARGET, its links and modes with it, as ditto keeps
    them: where ditto is not (the tests on Linux)."""
    root = app.parent
    with zipfile.ZipFile(target, "x", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
        for here, folders, files in os.walk(app):
            here_path = Path(here)
            _zip_entry(archive, here_path, root, folder=True)
            links = [n for n in folders if (here_path / n).is_symlink()]
            folders[:] = sorted(n for n in folders if n not in links)
            for name in sorted(files + links):
                _check(stop)
                _zip_entry(archive, here_path / name, root, stop=stop)


def _zip_entry(archive: zipfile.ZipFile, path: Path, root: Path, folder: bool = False, stop=None) -> None:
    info = os.lstat(path)
    name = path.relative_to(root).as_posix() + ("/" if folder else "")
    entry = zipfile.ZipInfo(name, date_time=max(time.localtime(info.st_mtime)[:6], (1980, 1, 1, 0, 0, 0)))
    entry.create_system = 3
    entry.external_attr = (info.st_mode & 0xFFFF) << 16
    if folder:
        entry.external_attr |= 0x10
        archive.writestr(entry, b"")
    elif stat.S_ISLNK(info.st_mode):
        archive.writestr(entry, os.readlink(path))
    elif stat.S_ISREG(info.st_mode):
        with open(path, "rb") as reader, archive.open(entry, "w", force_zip64=True) as writer:
            while block := reader.read(8 << 20):
                _check(stop)
                writer.write(block)


def _unzip(packed: Path, staging: Path, stop, progress, total: int) -> None:
    """The zip PACKED unpacked in STAGING, its links and modes with it: where
    ditto is not. Nothing goes outside STAGING."""
    inside = os.path.realpath(staging)
    done = 0
    modes: list[tuple[Path, int]] = []
    with zipfile.ZipFile(packed) as archive:
        for entry in archive.infolist():
            parts = PurePosixPath(entry.filename).parts
            if parts and parts[0] == "__MACOSX":
                continue
            if not parts or entry.filename.startswith("/") or ".." in parts:
                raise ValueError(t("mac.not_packed", name=packed.name))
            target = staging.joinpath(*parts)
            mode = entry.external_attr >> 16
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                if mode & 0o7777:
                    modes.append((target, mode & 0o7777))
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            if os.path.commonpath([inside, os.path.realpath(target.parent)]) != inside:
                raise ValueError(t("mac.not_packed", name=packed.name))
            if stat.S_ISLNK(mode):
                os.symlink(archive.read(entry).decode("utf-8"), target)
                continue
            with archive.open(entry) as reader, open(target, "xb") as writer:
                while block := reader.read(8 << 20):
                    _check(stop)
                    writer.write(block)
                    done += len(block)
                    if progress and total:
                        progress(min(done, total), total)
            if mode & 0o7777:
                os.chmod(target, mode & 0o7777)
    for path, mode in reversed(modes):
        os.chmod(path, mode)


def size(app: Path) -> int:
    return walk_size(app)
