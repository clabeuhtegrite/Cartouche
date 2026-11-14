"""The app's way into the builder: `cartouche-builder api <command>`, JSON out.

Cartouche Builder's Mac app runs these with the builder's Python and reads
one JSON object on stdout; what a command says along the way goes to
stderr. A command that cannot be done answers {"error": {"kind", "message"}}
with exit code 3 (2 for a request it does not understand); when the cause
is not one the builder knows ("engine", "failed", "unexpected"), the error
also says the exception's class, where the builder's code met it and its
errno (failure.py), which the app's measurements send. A full disk is
"no_space", in the player's words (disks.py). The batches
themselves run as `cartouche-builder build`, which the app starts and
follows through status.json (status.py).

  library [--update]     the games, what is due and why, nxnative's commits
  status                 the batch running now, or the last one
  storage                what the builder keeps on the Mac, by size
  clean WHAT [PATH ...]  frees extracted files, IPA copies, folders or logs
  doctor                 this Mac's tools
  setup                  nxnative's checkout and its Python environment
  config [--set JSON]    the settings, changed by the keys of JSON
  follow ID on|off       follows a game, or leaves it out
  mount                  connects the shares of the folders again
  bundle-romfs --ipa IPA --romfs IMAGE
                         packages matching external game data without compiling
  queue                  the games asked for while a batch runs (queue.py)
  queue add [--force] ID ...
                         adds games to the batch running, after its own; it
                         answers "queued": false when none runs, for the app
                         to start one
  queue remove ID ...    takes games out of the queue, or of the batch: one
                         waiting is left out, one building stops
"""

from __future__ import annotations

import argparse
import json
import sys
import traceback
import zipfile
from dataclasses import asdict, fields
from pathlib import Path

from . import __version__, batch, config as configs, disks, failure, fallback, ipa as ipas, schedule, shares, storage, titles, toolchain
from . import queue as queues
from . import status as statuses
from .engine import Commit, EngineError
from .i18n import language, t
from .impact import Matcher, analyze
from .paths import Paths
from .state import now_iso

API_VERSION = 1
CHANGES_SHOWN = 40  # the newest commits shown for a game, of each kind


class BadRequest(Exception):
    pass


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="cartouche-builder api", add_help=True)
    commands = parser.add_subparsers(dest="command", required=True)
    library_parser = commands.add_parser("library")
    library_parser.add_argument("--update", action="store_true")
    commands.add_parser("status")
    commands.add_parser("storage")
    clean_parser = commands.add_parser("clean")
    clean_parser.add_argument("what", choices=("extracted", "ipa_copies", "folders", "logs"))
    clean_parser.add_argument("paths", nargs="*")
    commands.add_parser("doctor")
    commands.add_parser("setup")
    config_parser = commands.add_parser("config")
    config_parser.add_argument("--set", metavar="JSON")
    follow_parser = commands.add_parser("follow")
    follow_parser.add_argument("title_id")
    follow_parser.add_argument("state", choices=("on", "off"))
    commands.add_parser("mount")
    bundle_parser = commands.add_parser("bundle-romfs")
    bundle_parser.add_argument("--ipa", required=True, type=Path)
    bundle_parser.add_argument("--romfs", required=True, type=Path)
    queue_parser = commands.add_parser("queue")
    queue_actions = queue_parser.add_subparsers(dest="action")
    add_parser = queue_actions.add_parser("add")
    add_parser.add_argument("--force", action="store_true")
    add_parser.add_argument("title_ids", nargs="+")
    remove_parser = queue_actions.add_parser("remove")
    remove_parser.add_argument("title_ids", nargs="+")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exit_:
        if exit_.code:
            return _answer({"error": {"kind": "bad_request", "message": "usage: cartouche-builder api " + " ".join(argv)}}, 2)
        return 0
    try:
        ctx = batch.context()
        handler = {
            "library": lambda: library(ctx, update=args.update),
            "status": lambda: {"status": statuses.read(ctx.paths)},
            "storage": lambda: survey_storage(ctx),
            "clean": lambda: clean(ctx, args.what, args.paths),
            "doctor": lambda: doctor(ctx),
            "setup": lambda: setup(ctx),
            "config": lambda: config(ctx, args.set),
            "follow": lambda: follow(ctx, args.title_id, args.state == "on"),
            "mount": lambda: mount(ctx),
            "bundle-romfs": lambda: bundle_romfs(ctx, args.ipa, args.romfs),
            "queue": lambda: queue(ctx, args.action, getattr(args, "title_ids", []), getattr(args, "force", False)),
        }[args.command]
        return _answer({"api": API_VERSION, **handler()})
    except BadRequest as error:
        return _answer({"error": {"kind": "bad_request", "message": str(error)}}, 2)
    except batch.Busy as error:
        return _answer({"error": {"kind": "busy", "message": str(error)}}, 3)
    except batch.Blocked as error:
        return _answer({"error": {"kind": "blocked", "message": str(error)}}, 3)
    except EngineError as error:
        if disks.is_full(error):
            return _no_space(error, Paths.default().engine)
        return _answer({"error": {"kind": "engine", "message": str(error), **failure.describe(error)}}, 3)
    except storage.Refused as error:
        return _answer({"error": {"kind": "refused", "message": t("api.refused", path=error)}}, 3)
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as error:
        if disks.is_full(error):
            return _no_space(error, Paths.default().root)
        return _answer({"error": {"kind": "failed", "message": f"{type(error).__name__}: {error}", **failure.describe(error)}}, 3)
    except Exception as error:  # noqa: BLE001 - the app reads an answer whatever went wrong
        # Its traceback goes where the app keeps what the engine says.
        traceback.print_exc(file=sys.stderr)
        return _answer({"error": {"kind": "unexpected", "message": f"{type(error).__name__}: {error}", **failure.describe(error)}}, 3)


def _no_space(error: BaseException, where: Path) -> int:
    """A full disk, in the player's words: which disk, and what is left on
    it. WHERE is what the builder was writing, when the error names nothing."""
    return _answer({"error": {"kind": "no_space", "message": disks.describe(error, where), **failure.describe(error)}}, 3)


def _answer(data: dict, code: int = 0) -> int:
    sys.stdout.write(json.dumps(data, ensure_ascii=False, default=str) + "\n")
    sys.stdout.flush()
    return code


def _say(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def bundle_romfs(ctx: batch.Context, source: Path, image: Path) -> dict:
    """Import without a sources folder, nxnative checkout or build tools."""
    folder = ctx.config.path("games")
    if not folder:
        raise batch.Blocked(t("bundle.no_folder"))
    with batch.batch_lock(ctx.paths):
        shares.reconnect([folder], ctx.config.shares, log=lambda address: _say(t("batch.mounting", share=address)))
        if not folder.is_dir():
            raise ValueError(t("bundle.no_folder"))
        target = ipas.bundle_romfs(source, image, folder, progress=_say)
    # For the app's measurements: the game by its title ID, the nxnative it
    # was built with and the complete IPA's size, never its name or path.
    info = ipas.read_info(target)
    try:
        size = target.stat().st_size
    except OSError:
        size = None
    return {"ipa": str(target), "title_id": info.title_id if info else None,
            "nxnative": info.short_commit if info else None, "bytes": size}


# ---- The games ------------------------------------------------------------------


def library(ctx: batch.Context, update: bool = False) -> dict:
    """Every game of the sources and of the games folder, as the app shows them."""
    status = statuses.read(ctx.paths)
    running = bool(status and status.get("running"))
    workspace = ctx.workspace
    data: dict = {
        "checked": now_iso(),
        "updated": False,
        "language": language(),
        "folders": folders(ctx),
        # The room the next build has, which says before a game is skipped
        # for it what is missing (batch.py, _make_room).
        "room": disks.room(workspace.root, ctx.config.min_free_gb, len(workspace.noted())),
        "engine": None,
        "problems": [],
        "issues": [],
        "notes": [],
        "games": [],
    }
    try:
        if update and not running:
            try:
                with batch.batch_lock(ctx.paths):
                    plan = batch.survey(ctx, update=True, log=_say)
                data["updated"] = True
            except batch.Busy:
                plan = batch.survey(ctx, update=False, log=_say)
        else:
            plan = batch.survey(ctx, update=False, log=_say)
    except batch.Blocked as blocked:
        data["problems"] = str(blocked).splitlines()
        data["engine"] = engine_info(ctx, ctx.engine.head())
        data["games"] = ipa_only(ctx, set(), {}) if ctx.config.path("games") and ctx.config.path("games").is_dir() else []
        _keep(ctx, data)
        return data
    data["engine"] = engine_info(ctx, plan.head)
    data["issues"] = plan.issues
    data["notes"] = [{"commit": c, "kind": k, "text": x} for c, k, x in plan.notes]
    building = {g["title_id"]: g for g in (status or {}).get("games", [])} if running else {}
    waiting: set[str] = set()
    if running:
        # The queue: games asked for wait their turn, and those taken out no longer do.
        asked = queues.read(ctx.paths)
        for title_id in asked["stop"]:
            if building.get(title_id, {}).get("state") == "queued":
                del building[title_id]
        waiting = {g["title_id"] for g in asked["games"] if g["batch"] == status.get("pid")} - set(building)
    for entry in plan.entries:
        progress = building.get(entry.title_id)
        if progress is None and entry.title_id in waiting:
            progress = {"title_id": entry.title_id, "name": entry.game.display_name, "state": "queued"}
        data["games"].append(game_json(ctx, entry, progress, plan.profiles))
    data["games"] += ipa_only(ctx, {e.title_id for e in plan.entries}, plan.profiles, plan.head)
    data["games"].sort(key=lambda g: g["name"].casefold())
    _keep(ctx, data)
    return data


def _keep(ctx: batch.Context, data: dict) -> None:
    """library.json: what the app shows at once when it opens."""
    try:
        configs.write_json(ctx.paths.library, {"api": API_VERSION, **data}, mode=0o644)
    except OSError:
        pass


def engine_info(ctx: batch.Context, head: str | None) -> dict | None:
    if not head:
        return None
    when, subject = 0, ""
    try:
        out = ctx.engine.git("log", "-1", "--format=%ct%x1f%s", head, check=False).strip()
        stamp, _, subject = out.partition("\x1f")
        when = int(stamp) if stamp.isdigit() else 0
    except EngineError:
        pass
    info = {"head": head, "short": head[:12], "time": when, "subject": subject, "url": ctx.config.engine_url, "branch": ctx.config.engine_branch, "commit_url": commit_url(ctx.config.engine_url)}
    # The branch's newest commit, when the checkout stays on an older one
    # because the newest does not build (fallback.py).
    latest = ctx.engine.latest()
    if latest and latest != head and latest in fallback.broken(ctx.paths):
        info.update({"latest": latest, "latest_short": latest[:12], "held": True})
    return info


def commit_url(url: str) -> str:
    """The web page of a commit, "{sha}" in place of its SHA, for a GitHub remote."""
    address = url.strip()
    if address.startswith("git@github.com:"):
        address = "https://github.com/" + address[len("git@github.com:") :]
    if not address.startswith("https://github.com/"):
        return ""
    return address.removesuffix(".git").rstrip("/") + "/commit/{sha}"


def folders(ctx: batch.Context) -> dict:
    config = ctx.config
    mounted = shares.mounts()
    found = {}
    for name in ("sources", "games", "keys", "workspace"):
        path = config.workspace_path(ctx.paths) if name == "workspace" else config.path(name)
        share = shares.share_of(path, mounted) if path else None
        known = next((address for point, address in config.shares.items() if path and (str(path) == point or str(path).startswith(point.rstrip("/") + "/"))), "")
        found[name] = {
            "path": str(path) if path else "",
            "present": bool(path and path.exists()),
            "share": share[1] if share else known,
            "mounted": bool(share),
        }
    found["remote"] = any(found[n]["share"] for n in ("sources", "games"))
    return found


def _commit(commit: Commit, kind: str) -> dict:
    return {"sha": commit.sha, "short": commit.short, "subject": commit.subject, "time": commit.time, "kind": kind}


def changes(impact) -> tuple[list[dict], dict]:
    if impact is None:
        return [], {"profile": 0, "named": 0, "shared": 0}
    shown: list[dict] = []
    seen: set[str] = set()
    for kind, commits in (("profile", impact.profile), ("named", impact.named), ("shared", impact.shared)):
        for commit in reversed(commits[-CHANGES_SHOWN:]):
            if commit.sha not in seen:
                seen.add(commit.sha)
                shown.append(_commit(commit, kind))
    shown.sort(key=lambda c: c["time"], reverse=True)
    return shown, {"profile": len(impact.profile), "named": len(impact.named), "shared": len(impact.shared)}


def icon(ctx: batch.Context, title_id: str) -> str:
    found = sorted(ctx.paths.icons.glob(f"{title_id}.*")) if ctx.paths.icons.is_dir() else []
    return str(found[0]) if found else ""


def state_of(entry, running: dict | None) -> str:
    if running and running.get("state") in ("building", "queued"):
        return running["state"]
    reason = entry.reasons[0] if entry.reasons else ""
    if entry.build:
        return "due"
    return {"failed_here": "failed", "not_selected": "not_followed", "no_profile": "no_profile"}.get(reason, "up_to_date")


def game_json(ctx: batch.Context, entry, running: dict | None, profiles: dict) -> dict:
    game, record = entry.game, entry.record
    build = record.build if record else None
    attempt = record.attempt if record else None
    shown, counts = changes(entry.impact)
    ipa = entry.ipa
    return {
        "title_id": entry.title_id,
        "name": game.display_name,
        "kind": game.kind,
        "source": str(game.source),
        "source_size": game.size,
        "followed": entry.selected,
        "profile": entry.title_id in profiles,
        "state": state_of(entry, running),
        "due": entry.build,
        "reasons": entry.reasons,
        "detail": entry.detail,
        "ipa": _ipa(ipa, entry.ipa_name, build),
        "build": _build(build),
        "attempt": asdict(attempt) if attempt else None,
        "changes": shown,
        "change_counts": counts,
        "aliases": ctx.config.aliases.get(entry.title_id, []),
        "icon": icon(ctx, entry.title_id),
        "progress": running,
    }


def _ipa(path: Path | None, name: str, build) -> dict | None:
    if path is None:
        return {"name": name, "path": "", "size": 0, "present": False} if name else None
    try:
        size = path.stat().st_size
    except OSError:
        size = build.size if build else 0
    return {"name": path.name, "path": str(path), "size": size, "present": True}


def _build(build) -> dict | None:
    if build is None:
        return None
    return {
        "commit": build.commit,
        "built_at": build.built_at,
        "version": build.version,
        "duration": build.duration,
        "origin": build.origin,
        "toolchain": build.toolchain,
        "chain": build.chain,
        "size": build.size,
        "dirty": build.dirty,
    }


def ipa_only(ctx: batch.Context, known: set[str], profiles: dict, head: str | None = None) -> list[dict]:
    """The games of the games folder whose sources are not in the sources
    folder (moved, or never there): shown, never built, with what nxnative
    changed since their IPA."""
    games = ctx.config.path("games")
    if games is None or not games.is_dir():
        return []
    try:
        candidates = sorted(p for p in games.iterdir() if p.suffix.lower() == ".ipa" and p.is_file() and not p.name.startswith("."))
    except OSError:
        return []
    found: dict[str, dict] = {}
    matcher = Matcher({tid: p.name for tid, p in profiles.items()}, ctx.config.aliases)
    for path in candidates:
        ids = [i for i in titles.ids_in_name(path.name) if titles.is_title_id(i)]
        if ids and (ids[0] in known or ids[0] in found):
            continue
        info = ipas.read_info(path)
        title_id = (info.title_id if info and info.title_id else (ids[0] if ids else None))
        if not title_id or title_id in known or title_id in found:
            continue
        record = ctx.store.get(title_id)
        build = record.build
        commit = (info.commit if info else None) or (build.commit if build else "")
        shown, counts = [], {"profile": 0, "named": 0, "shared": 0}
        if head and commit:
            base = ctx.engine.resolve(commit)
            if base and ctx.engine.is_ancestor(base, head):
                impact = analyze(ctx.engine.commits(base, head), [title_id], matcher)[title_id]
                shown, counts = changes(impact)
        name = (profiles[title_id].name if title_id in profiles and profiles[title_id].name else "") or (info.name if info and info.name else titles.label(path.name))
        built_at = build.built_at if build else (info.built.astimezone().isoformat() if info and info.built else "")
        found[title_id] = {
            "title_id": title_id,
            "name": name,
            "kind": "ipa",
            "source": "",
            "source_size": 0,
            "followed": ctx.config.selected(title_id),
            "profile": title_id in profiles,
            "state": "no_source",
            "due": False,
            "reasons": ["no_source"],
            "detail": t("api.no_source"),
            "ipa": {"name": path.name, "path": str(path), "size": path.stat().st_size, "present": True},
            "build": _build(build) or {"commit": commit or "", "built_at": built_at, "version": (info.version if info else "") or "", "duration": 0, "origin": "ipa", "toolchain": "", "chain": (info.chain if info else "") or "", "size": path.stat().st_size, "dirty": bool(info and info.dirty)},
            "attempt": None,
            "changes": shown,
            "change_counts": counts,
            "aliases": ctx.config.aliases.get(title_id, []),
            "icon": icon(ctx, title_id),
            "progress": None,
        }
    return list(found.values())


# ---- The rest -------------------------------------------------------------------


def survey_storage(ctx: batch.Context) -> dict:
    names = {tid: r.build.name for tid, r in ctx.store.all().items() if r.build and r.build.name}
    try:
        cached = json.loads(ctx.paths.library.read_text(encoding="utf-8"))
        names.update({g["title_id"]: g["name"] for g in cached.get("games", []) if isinstance(g, dict) and g.get("name")})
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return {"storage": storage.survey(ctx.config, ctx.paths, names)}


def clean(ctx: batch.Context, what: str, paths: list[str]) -> dict:
    # Never while a batch runs: it may be using the folders.
    with batch.batch_lock(ctx.paths):
        result = storage.clean(ctx.config, ctx.paths, what, paths)
    return {"cleaned": result}


def doctor(ctx: batch.Context) -> dict:
    root = ctx.engine.root if ctx.engine.present else None
    checks = toolchain.doctor(ctx.paths, root)
    return {
        "checks": [
            {"key": c.key, "label": t(f"check.{c.key}"), "ok": c.ok, "found": c.found, "fix": c.fix, "command": c.command, "blocking": c.blocking}
            for c in checks
        ],
        "ready": not toolchain.blocking(checks),
        "engine": ctx.engine.present,
        # The Xcode nxnative builds the shaders with: the app's setup asks
        # to update an older one before any build (MacSetup.swift).
        "xcode": toolchain.wanted_xcode(root),
    }


def setup(ctx: batch.Context) -> dict:
    with batch.batch_lock(ctx.paths):
        _say(t("batch.cloning_engine") if not ctx.engine.present else t("batch.updating_engine"))
        batch.update_engine(ctx)
        toolchain.ensure_python(ctx.paths, ctx.engine.requirements, log=_say)
        toolchain.write_dotnet_lock(ctx.paths)
    return doctor(ctx)


def config(ctx: batch.Context, changes_json: str | None) -> dict:
    config = ctx.config
    if changes_json:
        try:
            changes = json.loads(changes_json)
        except ValueError as error:
            raise BadRequest(f"--set: {error}") from error
        if not isinstance(changes, dict):
            raise BadRequest("--set: a JSON object of settings")
        known = {f.name: f for f in fields(configs.Config)}
        before = (config.schedule, config.schedule_hour, config.schedule_minute)
        for key, value in changes.items():
            if key not in known or key == "version":
                raise BadRequest(t("cli.unknown_key", key=key, keys=", ".join(sorted(known))))
            current = getattr(config, key)
            if isinstance(current, bool) != isinstance(value, bool) or (isinstance(current, (str, int, list, dict)) and not isinstance(value, type(current))):
                raise BadRequest(t("cli.bad_value", key=key))
            setattr(config, key, value)
        configs.save(ctx.paths, config)
        if (config.schedule, config.schedule_hour, config.schedule_minute) != before:
            schedule.sync(ctx.paths, config.schedule, config.schedule_hour, config.schedule_minute)
    elif config.schedule:
        # The app reads its settings as it opens: the nightly run then follows
        # the app and its Python wherever they are now. The agent is written
        # only when it changed.
        schedule.sync(ctx.paths, True, config.schedule_hour, config.schedule_minute)
    agent = schedule.installed()
    return {
        "config": asdict(config),
        "builder": {
            "version": __version__,
            "home": str(ctx.paths.root),
            "workspace": str(config.workspace_path(ctx.paths)),
            "default_workspace": str(ctx.paths.workspace),
            "python": sys.executable,
            "scheduled": bool(agent),
            "problems": config.problems(ctx.paths),
        },
    }


def follow(ctx: batch.Context, title_id: str, followed: bool) -> dict:
    if not titles.is_title_id(title_id):
        raise BadRequest(t("cli.bad_ids", ids=title_id))
    ctx.config.follow(title_id, followed)
    configs.save(ctx.paths, ctx.config)
    return {"followed": followed, "title_id": title_id.upper()}


def queue(ctx: batch.Context, action: str | None, title_ids: list[str], force: bool) -> dict:
    ids = [i.upper() for i in title_ids]
    bad = [i for i in ids if not titles.is_title_id(i)]
    if bad:
        raise BadRequest(t("cli.bad_ids", ids=", ".join(bad)))
    answer: dict = {}
    if action == "add":
        answer["queued"] = queues.add(ctx.paths, ids, force=force)
    elif action == "remove":
        queues.remove(ctx.paths, ids)
    answer["queue"] = queues.read(ctx.paths)
    answer["running"] = bool(queues.running(ctx.paths))
    return answer


def mount(ctx: batch.Context) -> dict:
    found = [p for p in (ctx.config.path("sources"), ctx.config.path("games")) if p]
    shares.reconnect(found, ctx.config.shares, log=lambda address: _say(t("batch.mounting", share=address)))
    return {"folders": folders(ctx)}
