"""The player's games: one folder per game in their sources folder.

A game's folder holds what nxnative's build script takes for one game:

- its packages (``.nsp``, ``.xci``, ``.nsz``, ``.xcz``: the base game, its update
  and DLC), which need the player's ``prod.keys``;
- a Switch 2 game's ``.nup`` container;
- a dump folder, as ``scripts/pack_dump.py`` lays it out (``base/exefs``,
  ``base/romfs``, ``updates/<version>/``, ``dlc/``, or ``exefs/`` and ``romfs/``);
- or a ``.zip`` holding such a dump, which the builder unpacks first.

A ``.nup`` or ``.zip`` lying in the sources folder itself is a game too. The
sources are only read, never written.
"""

from __future__ import annotations

import hashlib
import os
import re
import stat
import time
import zipfile
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

from . import titles
from .i18n import t

PACKAGE_SUFFIXES = (".nsp", ".xci", ".nsz", ".xcz")
NUP_SUFFIX = ".nup"
ZIP_SUFFIX = ".zip"


@dataclass
class Game:
    """One game of the sources folder."""

    title_id: str
    folder: Path
    kind: str  # "packages", "nup", "dump" or "zip"
    inputs: list[Path]
    size: int
    label: str
    zip_root: str = ""  # the dump's folder inside a ZIP, "" for its root
    name: str = ""  # nxnative's name for the game, when it has a profile

    @property
    def needs_keys(self) -> bool:
        return self.kind == "packages"

    @property
    def display_name(self) -> str:
        return self.name or self.label

    def fingerprint(self) -> str:
        """What the game's files are, by name, size and modification time.

        A file changed in place keeps neither its size nor its time, so this
        tells a new dump or a new update from the same files without reading
        tens of gigabytes again.
        """
        digest = hashlib.sha256(self.kind.encode())
        for path in self._files():
            info = path.stat()
            relative = path.relative_to(self.folder).as_posix() if path.is_relative_to(self.folder) else path.name
            digest.update(f"\0{relative}\0{info.st_size}\0{info.st_mtime_ns}".encode())
        return digest.hexdigest()[:24]

    def _files(self) -> list[Path]:
        if self.kind != "dump":
            return sorted(self.inputs)
        return sorted(p for p in self.folder.rglob("*") if p.is_file() and not p.name.startswith("._"))


@dataclass
class Discovery:
    games: list[Game] = field(default_factory=list)
    issues: list[str] = field(default_factory=list)


def discover(sources: Path, profiles: dict[str, str] | None = None) -> Discovery:
    """The games of SOURCES, sorted by size, and what kept other folders out.

    PROFILES maps the title IDs nxnative has a profile for to the game's name.
    """
    profiles = profiles or {}
    found = Discovery()
    if not sources.is_dir():
        raise FileNotFoundError(t("library.no_sources", path=sources))
    seen: dict[str, Path] = {}
    entries = sorted(sources.iterdir(), key=lambda p: p.name.casefold())
    for entry in entries:
        if entry.name.startswith("."):
            continue
        try:
            game = _game_of(entry, profiles)
        except _Skip as skip:
            if skip.message:
                found.issues.append(skip.message)
            continue
        except OSError as error:
            found.issues.append(t("library.unreadable", name=entry.name, error=error))
            continue
        if game.title_id in seen:
            found.issues.append(t("library.duplicate", name=entry.name, title_id=game.title_id, other=seen[game.title_id].name))
            continue
        seen[game.title_id] = entry
        game.name = profiles.get(game.title_id, "")
        found.games.append(game)
    found.games.sort(key=lambda g: (g.size, g.display_name.casefold()))
    return found


class _Skip(Exception):
    def __init__(self, message: str = ""):
        super().__init__(message)
        self.message = message


def _top_files(folder: Path) -> list[Path]:
    # nxnative lists a game folder's own files, in any letter case, without
    # the AppleDouble "._" files a non-Apple drive keeps beside them.
    return sorted((p for p in folder.iterdir() if p.is_file() and not p.name.startswith("._")), key=lambda p: p.name.casefold())


def _game_of(entry: Path, profiles: dict[str, str]) -> Game:
    if entry.is_file():
        suffix = entry.suffix.lower()
        if suffix == NUP_SUFFIX:
            title_id = _title_id_from_names([entry.name], profiles)
            if not title_id:
                raise _Skip(t("library.no_title_id", name=entry.name))
            return Game(title_id, entry.parent, "nup", [entry], entry.stat().st_size, titles.label(entry.name))
        if suffix == ZIP_SUFFIX:
            return _zip_game(entry, entry.parent, titles.label(entry.name))
        if suffix in PACKAGE_SUFFIXES:
            raise _Skip(t("library.loose_package", name=entry.name))
        raise _Skip()
    if not entry.is_dir():
        raise _Skip()

    files = _top_files(entry)
    packages = [p for p in files if p.suffix.lower() in PACKAGE_SUFFIXES]
    nups = [p for p in files if p.suffix.lower() == NUP_SUFFIX]
    label = titles.label(entry.name)
    if packages:
        # nxnative takes the packages when a folder has both.
        title_id = _title_id_from_names([entry.name], profiles) or _packages_title_id(packages, entry.name)
        if not title_id:
            raise _Skip(t("library.no_title_id", name=entry.name))
        return Game(title_id, entry, "packages", packages, sum(p.stat().st_size for p in packages), label)
    if nups:
        if len(nups) > 1:
            raise _Skip(t("library.several_nups", name=entry.name))
        title_id = _title_id_from_names([entry.name, nups[0].name], profiles)
        if not title_id:
            raise _Skip(t("library.no_title_id", name=entry.name))
        return Game(title_id, entry, "nup", nups, nups[0].stat().st_size, label)
    if is_dump(entry):
        title_id = dump_title_id(entry)
        if not title_id:
            raise _Skip(t("library.dump_without_id", name=entry.name))
        size = sum(p.stat().st_size for p in entry.rglob("*") if p.is_file())
        return Game(title_id, entry, "dump", [entry], size, label)
    zips = [p for p in files if p.suffix.lower() == ZIP_SUFFIX]
    if len(zips) == 1:
        return _zip_game(zips[0], entry, label)
    if len(zips) > 1:
        raise _Skip(t("library.several_zips", name=entry.name))
    if any(p.suffix.lower() in PACKAGE_SUFFIXES for p in entry.rglob("*") if p.is_file()):
        raise _Skip(t("library.nested_packages", name=entry.name))
    raise _Skip(t("library.nothing", name=entry.name))


def _title_id_from_names(names: list[str], profiles: dict[str, str]) -> str | None:
    for name in names:
        ids = titles.ids_in_name(name)
        if ids:
            return titles.base_title_id(ids[0])
        for short in titles.SHORT_BRACKETED.findall(name):
            candidate = short.upper() + "0"
            if candidate in profiles:
                return candidate
    return None


def _packages_title_id(packages: list[Path], folder_name: str) -> str | None:
    bases = {titles.base_title_id(i) for p in packages for i in titles.ids_in_name(p.name)}
    if len(bases) > 1:
        raise _Skip(t("library.several_games", name=folder_name, ids=", ".join(sorted(bases))))
    return bases.pop() if bases else None


# ---- Dumps -------------------------------------------------------------------


def _npdm_candidates(folder: Path) -> list[Path]:
    found = [p for p in (folder / "base/exefs/main.npdm", folder / "exefs/main.npdm") if p.is_file()]
    updates = folder / "updates"
    if updates.is_dir():
        versions = sorted((p for p in updates.iterdir() if p.is_dir() and p.name.isdigit()), key=lambda p: int(p.name), reverse=True)
        found += [v / "exefs/main.npdm" for v in versions if (v / "exefs/main.npdm").is_file()]
    return found


def is_dump(folder: Path) -> bool:
    """Whether FOLDER is laid out as scripts/pack_dump.py takes a dump."""
    updates = folder / "updates"
    versions = [p for p in updates.iterdir() if p.is_dir() and p.name.isdigit()] if updates.is_dir() else []
    complete_update = any((v / "exefs/main.npdm").is_file() and (v / "romfs").is_dir() for v in versions)
    if (folder / "base/exefs/main.npdm").is_file():
        return (folder / "base/romfs").is_dir() or any((v / "romfs").is_dir() for v in versions)
    if (folder / "exefs/main.npdm").is_file() and (folder / "romfs").is_dir():
        return True
    return complete_update


def dump_title_id(folder: Path) -> str | None:
    """The program ID a dump's NPDM declares: the base game's, else the newest update's."""
    for npdm in _npdm_candidates(folder):
        try:
            title_id = titles.npdm_title_id(npdm.read_bytes()[: 1 << 20])
        except OSError:
            continue
        if title_id:
            return title_id
    return None


# ---- Dumps in a ZIP ----------------------------------------------------------


def mac_metadata(name: str) -> bool:
    """A Finder archive's __MACOSX/ copy or an AppleDouble "._" file: no part of a dump."""
    parts = name.split("/")
    return parts[0] == "__MACOSX" or parts[-1].startswith("._") or parts[-1] == ".DS_Store"


def safe_member(name: str) -> str:
    """A ZIP member's path, checked: relative, no "..", forward slashes."""
    name = name.replace("\\", "/")
    while name.startswith("./"):
        name = name[2:]
    if not name or name.startswith("/") or re.match(r"^[A-Za-z]:", name) or "\0" in name:
        raise ValueError(f"unsafe path in the archive: {name!r}")
    parts = [part for part in name.split("/") if part not in ("", ".")]
    if any(part == ".." for part in parts):
        raise ValueError(f"unsafe path in the archive: {name!r}")
    return "/".join(parts)


def inspect_zip(path: Path) -> tuple[str, str, int]:
    """(the dump's folder inside the ZIP, its title ID, the bytes it unpacks to).

    The dump may sit at the archive's root or in a folder of it (a game's
    name, usually). An archive with two games, links or unsafe paths is
    refused.
    """
    with zipfile.ZipFile(path) as archive:
        files: dict[str, zipfile.ZipInfo] = {}
        for info in archive.infolist():
            if info.is_dir():
                continue
            name = safe_member(info.filename)
            if mac_metadata(name):
                continue
            if stat.S_ISLNK((info.external_attr >> 16) & 0xFFFF):
                raise ValueError(f"link in the archive: {name}")
            if name in files:
                raise ValueError(f"duplicate path in the archive: {name}")
            files[name] = info
        roots = {""} | {"/".join(n.split("/")[:i]) for n in files for i in range(1, n.count("/") + 1)}
        candidates: list[tuple[str, str]] = []
        for root in roots:
            prefix = root + "/" if root else ""
            below = {n[len(prefix) :] for n in files if n.startswith(prefix)}

            def tree(relative: str) -> bool:
                return any(n.startswith(relative + "/") for n in below)

            updates = sorted(
                (int(m.group(1)) for n in below if (m := re.fullmatch(r"updates/(\d+)/exefs/main\.npdm", n))),
                reverse=True,
            )
            complete = [v for v in updates if tree(f"updates/{v}/romfs")]
            if "base/exefs/main.npdm" in below and (tree("base/romfs") or complete):
                candidates.append((root, prefix + "base/exefs/main.npdm"))
            elif "exefs/main.npdm" in below and tree("romfs"):
                candidates.append((root, prefix + "exefs/main.npdm"))
            elif complete:
                candidates.append((root, prefix + f"updates/{complete[0]}/exefs/main.npdm"))
        by_title: dict[str, list[str]] = {}
        for root, npdm in candidates:
            with archive.open(files[npdm]) as stream:
                title_id = titles.npdm_title_id(stream.read(1 << 20))
            if title_id:
                by_title.setdefault(title_id, []).append(root)
        if not by_title:
            raise ValueError("no dump in the archive (base/exefs and base/romfs, updates/<version>/, or exefs/ and romfs/)")
        if len(by_title) > 1:
            raise ValueError("the archive holds several games: " + ", ".join(sorted(by_title)))
        title_id, roots_of_title = next(iter(by_title.items()))
        root = min(roots_of_title, key=lambda r: (r.count("/"), len(r), r))
        prefix = root + "/" if root else ""
        size = sum(info.file_size for name, info in files.items() if name.startswith(prefix))
        return root, title_id, size


def _zip_game(path: Path, folder: Path, label: str) -> Game:
    try:
        root, title_id, size = inspect_zip(path)
    except (OSError, ValueError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        raise _Skip(t("library.bad_zip", name=path.name, error=error)) from error
    return Game(title_id, folder, "zip", [path], size, label, zip_root=root)


def unpack_zip(game: Game, destination: Path, progress=None, stop=None) -> Path:
    """Unpacks the dump of GAME's ZIP into DESTINATION, without its outer folder."""
    import shutil

    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    prefix = game.zip_root + "/" if game.zip_root else ""
    done = 0
    try:
        with zipfile.ZipFile(game.inputs[0]) as archive:
            members = []
            for info in archive.infolist():
                if info.is_dir():
                    continue
                name = safe_member(info.filename)
                if mac_metadata(name):
                    continue
                if stat.S_ISLNK((info.external_attr >> 16) & 0xFFFF):
                    raise ValueError(f"link in the archive: {name}")
                if not name.startswith(prefix) or name == prefix:
                    continue
                members.append((info, PurePosixPath(name[len(prefix) :])))
            total = sum(info.file_size for info, _ in members) or 1
            for info, relative in members:
                target = destination.joinpath(*relative.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(info) as source, open(target, "xb") as output:
                    while block := source.read(4 << 20):
                        if stop is not None and stop.is_set():
                            raise InterruptedError("stopped")
                        output.write(block)
                        done += len(block)
                        if progress:
                            progress(done, total)
                # The entry's own time, so that the same ZIP unpacked again
                # gives the same files to nxnative, which then reuses its
                # extraction instead of starting over.
                try:
                    stamp = time.mktime(info.date_time + (0, 0, -1))
                    os.utime(target, (stamp, stamp))
                except (OverflowError, ValueError, OSError):
                    pass
        if not is_dump(destination):
            raise ValueError("the archive did not unpack to a dump")
        return destination
    except BaseException:
        shutil.rmtree(destination, ignore_errors=True)
        raise


def walk_size(folder: Path) -> int:
    """The bytes the files under FOLDER take, links not followed."""
    total = 0
    for root, _dirs, files in os.walk(folder):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total
