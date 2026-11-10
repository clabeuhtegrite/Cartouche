"""What the builder keeps on the Mac, and freeing it: the app's Storage page.

The builder's own folder holds nxnative's checkout, its Python environment,
the logs and the games' icons, all small. What is large is in the
workspaces (the configured one, the builder's own and NxNative Batch
Builder's, when they are other folders): one build folder per game, and the
IPAs kept beside them for nxnative's packer.

A build folder is made of parts nxnative names (build_ipa_from_nsp.py):
extract/ (the game's files, as big as the game, made again in minutes),
nsp/ (NSZ and XCZ packages converted, as big as them), shader/ (the shader
caches: hours to make again for a large game), ipa/ (the app's build
products) and smaller ones. Only folders and files named as the builder and
nxnative name them, inside a workspace, are ever removed.
"""

from __future__ import annotations

import os
import shutil
import time
from pathlib import Path

from . import config as configs
from .library import walk_size
from .paths import Paths
from .workspace import NOTES, Workspace, remove_tree, same_volume

# A build folder's parts, by the name of its folder in it; any other is "other".
PARTS = {
    "extract": "extracted",
    "extract.partial": "extracted",
    "exefs.partial": "extracted",
    "nsp": "packages",
    "shader": "shaders",
    "ipa": "app",
    "xcode-derived-data": "app",
    "tmp": "temporary",
}
CATEGORIES = ("extracted", "packages", "shaders", "app", "temporary", "other")
# What "free the extracted files" removes from a build folder: made again by
# the next build, in minutes.
EXTRACTED = ("extract", "extract.partial", "exefs.partial", "tmp")
KEPT_IPA_SUFFIXES = (".ipa", ".ipa.idx", ".ipa.partial")


def workspaces(config: configs.Config, paths: Paths) -> list[Path]:
    """The workspaces the builder may have filled, each once."""
    found: list[Path] = []
    seen: set[str] = set()
    for root in (config.workspace_path(paths), paths.workspace, configs.legacy_workspace()):
        try:
            key = str(root.expanduser().resolve())
        except OSError:
            key = str(root)
        if key in seen or not root.is_dir():
            continue
        seen.add(key)
        found.append(root)
    return found


def disk(path: Path | None) -> dict | None:
    """The disk PATH is on: its room and its size."""
    if path is None:
        return None
    probe = path
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    try:
        usage = shutil.disk_usage(probe)
    except OSError:
        return None
    return {"path": str(path), "free": usage.free, "total": usage.total, "present": path.exists()}


def parts(folder: Path) -> dict[str, int]:
    """The bytes of each part of a build folder (CATEGORIES)."""
    sizes = dict.fromkeys(CATEGORIES, 0)
    try:
        entries = list(os.scandir(folder))
    except OSError:
        return sizes
    for entry in entries:
        category = PARTS.get(entry.name, "other")
        try:
            if entry.is_dir(follow_symlinks=False):
                sizes[category] += walk_size(Path(entry.path))
            else:
                sizes[category] += entry.stat(follow_symlinks=False).st_size
        except OSError:
            pass
    return sizes


def kept_ipas(root: Path) -> list[Path]:
    out = root / NOTES / "out"
    try:
        return sorted(p for p in out.iterdir() if p.is_file() and p.name.endswith(".ipa"))
    except OSError:
        return []


def survey(config: configs.Config, paths: Paths, names: dict[str, str] | None = None) -> dict:
    """Everything the builder keeps, with its size."""
    names = names or {}
    games = config.path("games")
    folders, copies = [], []
    totals = dict.fromkeys(CATEGORIES, 0)
    for root in workspaces(config, paths):
        workspace = Workspace(root)
        for folder in workspace.own_folders():
            title_id, _, kind = folder.name.partition("_")
            sizes = parts(folder)
            for category, size in sizes.items():
                totals[category] += size
            folders.append({
                "path": str(folder),
                "workspace": str(root),
                "title_id": title_id,
                "name": names.get(title_id, ""),
                "kind": kind,  # "build" or "dump"
                "size": sum(sizes.values()),
                "parts": sizes,
                "used": workspace.used(folder) or _mtime(folder),
            })
        for ipa in kept_ipas(root):
            title_id = ipa.name[: -len(".ipa")]
            size = _size(ipa) + _size(ipa.with_name(ipa.name + ".idx"))
            copies.append({
                "path": str(ipa),
                "workspace": str(root),
                "title_id": title_id,
                "name": names.get(title_id, ""),
                "size": size,
                # On the games folder's disk the copy shares its blocks with the
                # delivered IPA (an APFS clone): removing it frees little.
                "same_disk": bool(games and games.exists() and same_volume(ipa, games)),
                "used": _mtime(ipa),
            })
    folders.sort(key=lambda f: f["size"], reverse=True)
    copies.sort(key=lambda c: c["size"], reverse=True)
    builder = {
        "engine": walk_size(paths.engine) if paths.engine.exists() else 0,
        "python": walk_size(paths.python) if paths.python.exists() else 0,
        "logs": sum(walk_size(p) for p in (paths.logs, paths.reports) if p.exists()),
        "icons": walk_size(paths.icons) if paths.icons.exists() else 0,
    }
    workspace = config.workspace_path(paths)
    return {
        "workspace": str(workspace),
        "disks": {
            "workspace": disk(workspace),
            "games": disk(games),
            "sources": disk(config.path("sources")),
        },
        "folders": folders,
        "ipa_copies": copies,
        "totals": {
            **totals,
            "ipa_copies": sum(c["size"] for c in copies),
            "ipa_copies_freeable": sum(c["size"] for c in copies if not c["same_disk"]),
            **builder,
        },
        "settings": {
            "keep_extracted": config.keep_extracted,
            "keep_ipa": config.keep_ipa,
            "min_free_gb": config.min_free_gb,
            "workspace_limit_gb": config.workspace_limit_gb,
        },
    }


# ---- Freeing ------------------------------------------------------------------


class Refused(ValueError):
    """A path that is none of the builder's own."""


def _own_folder(path: Path, roots: list[Path]) -> Path:
    for root in roots:
        workspace = Workspace(root)
        for folder in workspace.own_folders():
            if folder == path:
                return folder
    raise Refused(str(path))


def _own_copy(path: Path, roots: list[Path]) -> Path:
    for root in roots:
        if path in kept_ipas(root):
            return path
    raise Refused(str(path))


def clean(config: configs.Config, paths: Paths, what: str, targets: list[str]) -> dict:
    """Frees WHAT ("extracted", "ipa_copies", "folders" or "logs") of TARGETS
    (paths from survey(); every one of its kind when empty, except folders)."""
    roots = workspaces(config, paths)
    removed: list[str] = []
    freed = 0
    if what == "extracted":
        folders = [_own_folder(Path(t), roots) for t in targets] if targets else [f for r in roots for f in Workspace(r).own_folders()]
        for folder in folders:
            for name in EXTRACTED:
                part = folder / name
                if part.exists() and not part.is_symlink():
                    size = walk_size(part) if part.is_dir() else _size(part)
                    remove_tree(part)
                    freed += size
                    removed.append(str(part))
    elif what == "ipa_copies":
        copies = [_own_copy(Path(t), roots) for t in targets] if targets else [c for r in roots for c in kept_ipas(r)]
        for ipa in copies:
            for suffix in KEPT_IPA_SUFFIXES:
                path = ipa.with_name(ipa.name[: -len(".ipa")] + suffix)
                if path.is_file():
                    freed += _size(path)
                    path.unlink(missing_ok=True)
                    removed.append(str(path))
    elif what == "folders":
        if not targets:
            raise Refused("no folder named")
        for target in targets:
            folder = _own_folder(Path(target), roots)
            workspace = Workspace(folder.parent)
            freed += workspace.forget_sized(folder)
            removed.append(str(folder))
    elif what == "logs":
        limit = time.time() - 7 * 86400
        for folder in (paths.logs, paths.reports):
            if not folder.is_dir():
                continue
            newest: dict[Path, Path] = {}
            files = [p for p in folder.rglob("*") if p.is_file() and p.suffix in (".log", ".md")]
            for path in files:
                if path.parent not in newest or path.stat().st_mtime > newest[path.parent].stat().st_mtime:
                    newest[path.parent] = path
            for path in files:
                if path.stat().st_mtime < limit and newest.get(path.parent) != path:
                    freed += _size(path)
                    path.unlink(missing_ok=True)
                    removed.append(str(path))
    else:
        raise Refused(what)
    return {"freed": freed, "removed": removed}


def _size(path: Path) -> int:
    try:
        return path.lstat().st_size
    except OSError:
        return 0


def _mtime(path: Path) -> float:
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0
