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

The builder has nxnative write the app in the workspace, then moves it into
the Mac apps folder (the Applications folder of the player's session unless
the settings name another), whole: under a hidden name first, then in place
of the game's app there. It never takes the place of an app that is not
this game's (another app of the same name gets "<game> [<title ID>].app"),
nor of the game's app while the game runs from it.
"""

from __future__ import annotations

import os
import plistlib
import re
import shutil
import subprocess
import unicodedata
from dataclasses import dataclass
from pathlib import Path

from . import titles
from .library import walk_size
from .workspace import remove_tree, same_volume

PARTIAL_SUFFIX = ".builder-partial"
OLD_SUFFIX = ".builder-old"


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
    for path in (built, Path(f"{built}.partial"), Path(f"{built}.old"), Path(f"{built}.key")):
        remove_tree(path)


def _copy_tree(source: Path, target: Path, stop) -> None:
    def copy(src: str, dst: str) -> str:
        _check(stop)
        return shutil.copy2(src, dst)

    shutil.copytree(source, target, symlinks=True, copy_function=copy)


def _check(stop) -> None:
    if stop is not None and stop.is_set():
        raise InterruptedError("stopped")


def size(app: Path) -> int:
    return walk_size(app)
