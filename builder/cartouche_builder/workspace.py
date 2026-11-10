"""The games' build folders: <workspace>/<title ID>_build, as nxnative and
NxNative Batch Builder name them, so that a folder either made is reused.

nxnative keeps in a game's build folder what its next build reuses (the
extracted files, the shader cache, Xcode's derived data): a build after a
small change takes minutes instead of hours. The folders are large, so the
builder can keep the workspace under a size: the folders of the games built
longest ago go first, and only folders the builder has used (those it has a
note of, in <workspace>/.cartouche-builder/) are ever removed.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import time
from pathlib import Path

from .library import walk_size

NOTES = ".cartouche-builder"
# The only folders the builder makes there, and so the only ones it removes.
OWN_FOLDER = re.compile(r"[0-9A-F]{16}_(?:build|dump)")


class Workspace:
    def __init__(self, root: Path):
        self.root = root

    def build_folder(self, title_id: str) -> Path:
        return self.root / f"{title_id.upper()}_build"

    def dump_folder(self, title_id: str) -> Path:
        """Where a zipped dump is unpacked for its build."""
        return self.root / f"{title_id.upper()}_dump"

    def output(self, title_id: str, name: str) -> Path:
        return self.build_folder(title_id) / "out" / name

    def _note(self, folder: Path) -> Path:
        return self.root / NOTES / f"{folder.name}.json"

    def use(self, folder: Path) -> None:
        """Notes that the builder uses FOLDER now (it may remove it later)."""
        note = self._note(folder)
        note.parent.mkdir(parents=True, exist_ok=True)
        note.write_text(json.dumps({"folder": folder.name, "used": time.time()}) + "\n")

    def noted(self) -> list[tuple[float, Path]]:
        found = []
        notes = self.root / NOTES
        if not notes.is_dir():
            return found
        for note in notes.glob("*.json"):
            try:
                data = json.loads(note.read_text())
                name = str(data["folder"])
                used = float(data["used"])
            except (OSError, ValueError, KeyError, TypeError):
                continue
            if not OWN_FOLDER.fullmatch(name) or note.stem != name:
                continue
            folder = self.root / name
            if folder.is_dir() and not folder.is_symlink():
                found.append((used, folder))
        return sorted(found)

    def free_bytes(self) -> int:
        path = self.root
        while not path.exists() and path != path.parent:
            path = path.parent
        return shutil.disk_usage(path).free

    def size(self) -> int:
        return sum(walk_size(folder) for _, folder in self.noted())

    def trim(self, limit_bytes: int, keep: set[Path] | None = None, log=None) -> list[Path]:
        """Removes the least recently used noted folders until the noted ones
        take at most LIMIT_BYTES; never one of KEEP."""
        removed: list[Path] = []
        if limit_bytes <= 0:
            return removed
        folders = self.noted()
        sizes = {folder: walk_size(folder) for _, folder in folders}
        total = sum(sizes.values())
        for _used, folder in folders:
            if total <= limit_bytes:
                break
            if keep and folder in keep:
                continue
            if log:
                log(folder, sizes[folder])
            remove_tree(folder)
            try:
                self._note(folder).unlink()
            except OSError:
                pass
            total -= sizes[folder]
            removed.append(folder)
        return removed

    def forget(self, folder: Path) -> None:
        remove_tree(folder)
        try:
            self._note(folder).unlink()
        except OSError:
            pass


def remove_tree(path: Path) -> None:
    """Removes PATH; a file that went meanwhile (an AppleDouble "._" file a
    non-Apple drive drops with its twin) is no error."""

    def gone(function, name, error):
        if not isinstance(error, FileNotFoundError):
            raise error

    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.exists():
        shutil.rmtree(path, onexc=gone)


def free_gb(path: Path) -> float:
    while not path.exists() and path != path.parent:
        path = path.parent
    return shutil.disk_usage(path).free / 2**30


def same_volume(a: Path, b: Path) -> bool:
    try:
        return os.stat(a).st_dev == os.stat(b).st_dev
    except OSError:
        return False
