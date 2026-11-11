"""The player's games: what their sources folder holds, wherever it is in it.

nxnative's build script takes one game at a time:

- its packages (``.nsp``, ``.xci``, ``.nsz``, ``.xcz``: the base game, its update
  and DLC), which need the player's ``prod.keys``;
- a Switch 2 game's ``.nup`` container;
- a dump folder, as ``scripts/pack_dump.py`` lays it out (``base/exefs``,
  ``base/romfs``, ``updates/<version>/``, ``dlc/``, or ``exefs/`` and ``romfs/``);
- or a ``.zip`` holding such a dump, which the builder unpacks first.

They may be anywhere in the sources folder: one folder per game, as nxnative
lays a game out, all of them loose in one folder, or in folders of folders,
up to MAX_DEPTH levels down. A game is known by its title ID: the one its
folder's or its files' names carry ("[0100000000010000]"), else the one its
files hold (identify.py: a NUP's table of contents, a ticket's name, or with
prod.keys the header of its NCAs). The packages of one game in several
folders, or beside another game's, are built from a folder of links to them
alone (batch.py); a game's folder that holds only its own packages is given
to nxnative as it is. What keeps a file or a folder out is said in plain
words (Discovery.issues), and the app shows it. The sources are only read,
never written.
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

from . import identify, titles
from .i18n import t

PACKAGE_SUFFIXES = identify.PACKAGE_SUFFIXES
NUP_SUFFIX = identify.NUP_SUFFIX
ZIP_SUFFIX = ".zip"
# How deep in the sources folder games are looked for: sources/Switch/Zelda/
# is two levels down.
MAX_DEPTH = 4
# Folders that are never a game's: a build folder nxnative made beside a
# game's packages (its extraction looks like a dump), the builder's own, and
# what the Finder leaves in an archive.
NOT_GAMES = re.compile(r"(?i).*_(?:build|dump)|__MACOSX")


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
    # Its packages are not the only ones of their folder, or are in several
    # folders: it is built from a folder of links to them (batch.py).
    shared: bool = False
    base: bool = True  # holds the base game, not only an update or DLC

    @property
    def needs_keys(self) -> bool:
        return self.kind == "packages"

    @property
    def display_name(self) -> str:
        return self.name or self.label

    @property
    def source(self) -> Path:
        """What the player sees of it in the Finder: its folder, or its file."""
        return self.inputs[0] if self.kind in ("nup", "zip") or self.shared else self.folder

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


def discover(sources: Path, profiles: dict[str, str] | None = None, keys: Path | None = None, cache: Path | None = None) -> Discovery:
    """The games of SOURCES, sorted by size, and what kept other files out.

    PROFILES maps the title IDs nxnative has a profile for to the game's name.
    KEYS is the player's prod.keys, which tells the game of a package named
    without its title ID; CACHE keeps what files were found to hold
    (identify.Reader).
    """
    profiles = profiles or {}
    if not sources.is_dir():
        raise FileNotFoundError(t("library.no_sources", path=sources))
    look = _Look(sources, profiles, identify.Reader(keys, cache))
    look.folder(sources, 0)
    look.reader.save()
    found = Discovery(issues=look.issues)
    by_title: dict[str, list[Game]] = {}
    for game in look.games:
        by_title.setdefault(game.title_id, []).append(game)
    order = {id(g): i for i, g in enumerate(look.games)}
    for title_id, copies in by_title.items():
        # One game's packages in several folders, its base game in one and
        # its update or DLC in others: they are built together.
        whole = [g for g in copies if g.kind == "packages" and g.base]
        parts = [g for g in copies if g.kind == "packages" and not g.base]
        if whole and parts:
            into = min(whole, key=lambda g: (-g.size, order[id(g)]))
            into.inputs = into.inputs + [p for g in parts for p in g.inputs]
            into.size += sum(g.size for g in parts)
            into.shared = True
            copies = [g for g in copies if g not in parts]
        # Of the copies of one game, the most complete: one with the base
        # game, then the biggest, then the first found.
        best = min(copies, key=lambda g: (not g.base, -g.size, order[id(g)]))
        for other in copies:
            if other is not best:
                found.issues.append(t("library.duplicate", name=look.shown(other.source), title_id=title_id, other=look.shown(best.source)))
        best.name = profiles.get(title_id, "")
        found.games.append(best)
    found.games.sort(key=lambda g: (g.size, g.display_name.casefold()))
    return found


class _Look:
    """One look through the sources folder, folder after folder."""

    def __init__(self, sources: Path, profiles: dict[str, str], reader: identify.Reader):
        self.sources = sources
        self.profiles = profiles
        self.reader = reader
        self.games: list[Game] = []
        self.issues: list[str] = []
        self._visited: set[tuple[int, int]] = set()

    def shown(self, path: Path) -> str:
        """PATH as the player finds it in their sources folder."""
        try:
            relative = path.relative_to(self.sources).as_posix()
        except ValueError:
            return path.name
        return path.name if relative in ("", ".") else relative

    def folder(self, folder: Path, depth: int) -> None:
        try:
            info = folder.stat()
            if (info.st_dev, info.st_ino) in self._visited:
                return  # a link back to a folder already looked at
            self._visited.add((info.st_dev, info.st_ino))
            entries = sorted(folder.iterdir(), key=lambda p: p.name.casefold())
        except OSError as error:
            self.issues.append(t("library.unreadable", name=self.shown(folder), error=error))
            return
        # A game's files, as nxnative lists them: any letter case, none of the
        # hidden ones (the AppleDouble "._" file a non-Apple drive keeps
        # beside each).
        files, folders = [], []
        for entry in entries:
            if entry.name.startswith("."):
                continue
            try:
                if entry.is_file():
                    files.append(entry)
                elif entry.is_dir() and not NOT_GAMES.fullmatch(entry.name):
                    folders.append(entry)
            except OSError:
                continue
        packages = [p for p in files if p.suffix.lower() in PACKAGE_SUFFIXES]
        nups = [p for p in files if p.suffix.lower() == NUP_SUFFIX]
        top = folder == self.sources
        if packages:
            self._packages(folder, packages, top)
        for nup in nups:
            self._nup(folder, nup, alone=not top and not packages and len(nups) == 1)
        if not packages and not nups:
            if is_dump(folder):
                self._dump(folder)
                return  # a dump's own folders are no games
            zips = [p for p in files if p.suffix.lower() == ZIP_SUFFIX]
            for path in zips:
                self._zip(folder, path, alone=not top and len(zips) == 1)
        if depth >= MAX_DEPTH:
            return
        for sub in folders:
            before = (len(self.games), len(self.issues))
            self.folder(sub, depth + 1)
            if top and (len(self.games), len(self.issues)) == before:
                self.issues.append(t("library.nothing", name=sub.name))

    # ---- Each kind ------------------------------------------------------------

    def _name_id(self, names: list[str]) -> str | None:
        return _title_id_from_names(names, self.profiles)

    def _file_ids(self, path: Path) -> list[str] | None:
        """The title IDs PATH holds, read in it; None, and an issue, when it
        cannot tell."""
        try:
            ids = self.reader.ids(path)
            identify.game_of(ids)
            return ids
        except identify.NeedsKeys:
            self.issues.append(t("library.needs_keys", name=self.shown(path)))
        except identify.Unreadable as error:
            self.issues.append(t("library.not_a_game", name=self.shown(path), error=error))
        return None

    def _packages(self, folder: Path, packages: list[Path], top: bool) -> None:
        label = titles.label(folder.name)
        folder_id = None if top else self._name_id([folder.name])
        named = {p: titles.ids_in_name(p.name) for p in packages}
        games = {self._name_id([p.name]) for p in packages} - {None}
        if not top and (games <= {folder_id} if folder_id else len(games) == 1):
            # A game's folder, as nxnative takes it: its packages are its own,
            # as the folder's or their names say.
            title_id = folder_id or games.pop()
            raw = [i for ids in named.values() for i in ids[:1]]
            self.games.append(Game(title_id, folder, "packages", packages, _size(packages), label, base=_holds_base(raw)))
            return
        groups: dict[str, list[tuple[Path, list[str]]]] = {}
        for path in packages:
            title_id = self._name_id([path.name])
            ids = named[path][:1]
            if title_id is None:
                read = self._file_ids(path)
                if read is None:
                    continue
                title_id, ids = identify.game_of(read), read
            groups.setdefault(title_id, []).append((path, ids))
        for title_id, found in groups.items():
            files = [path for path, _ in found]
            raw = [i for _, ids in found for i in ids]
            # Its base game's file first: the one it is named after, and the
            # one the Finder shows.
            first = next((path for path, ids in found if any(int(i, 16) & 0xFFF == 0 for i in ids)), files[0])
            files = [first] + [path for path in files if path != first]
            self.games.append(Game(
                title_id, folder, "packages", files, _size(files),
                label if len(groups) == 1 and not top else titles.label(first.name),
                # Loose in the sources folder, or beside another game's: from links.
                shared=top or len(files) < len(packages), base=_holds_base(raw),
            ))

    def _nup(self, folder: Path, nup: Path, alone: bool) -> None:
        title_id = self._name_id([folder.name, nup.name] if alone else [nup.name])
        if title_id is None:
            read = self._file_ids(nup)
            if read is None:
                return
            title_id = identify.game_of(read)
        try:
            size = nup.stat().st_size
        except OSError as error:
            self.issues.append(t("library.unreadable", name=self.shown(nup), error=error))
            return
        self.games.append(Game(title_id, folder, "nup", [nup], size, titles.label(folder.name if alone else nup.name)))

    def _dump(self, folder: Path) -> None:
        title_id = dump_title_id(folder)
        if not title_id:
            self.issues.append(t("library.dump_without_id", name=self.shown(folder)))
            return
        size = sum(p.stat().st_size for p in folder.rglob("*") if p.is_file())
        self.games.append(Game(title_id, folder, "dump", [folder], size, titles.label(folder.name)))

    def _zip(self, folder: Path, path: Path, alone: bool) -> None:
        try:
            self.games.append(_zip_game(path, folder, titles.label(folder.name if alone else path.name)))
        except (OSError, ValueError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
            self.issues.append(t("library.bad_zip", name=self.shown(path), error=error))


def _size(paths: list[Path]) -> int:
    return sum(p.stat().st_size for p in paths)


def _holds_base(ids: list[str]) -> bool:
    """Whether the title IDs of a game's packages include its base game's;
    true when none is known."""
    return not ids or any(int(i, 16) & 0xFFF == 0 for i in ids if titles.is_title_id(i))


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
    """The game of a ZIP of a dump; ValueError (or zipfile's) when it holds none."""
    root, title_id, size = inspect_zip(path)
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
