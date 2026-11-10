"""cartouche-builder: the window, or its commands in Terminal.

  cartouche-builder                    the window
  cartouche-builder plan               nxnative moved forward, and what is due and why
  cartouche-builder build [ID ...]     build what is due (or those games)
  cartouche-builder status             each game's last build, without moving nxnative
  cartouche-builder doctor             the Mac's tools
  cartouche-builder setup              nxnative's checkout and Python environment
  cartouche-builder schedule on|off    the nightly run
  cartouche-builder config [KEY [VALUE]]
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
import threading
from dataclasses import asdict, fields

from . import __version__, batch, config as configs, schedule, toolchain, titles
from .engine import EngineError
from .i18n import t
from .paths import Paths


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="cartouche-builder", description=t("cli.description"))
    parser.add_argument("--version", action="version", version=f"Cartouche Builder {__version__}")
    commands = parser.add_subparsers(dest="command")
    commands.add_parser("gui", help=t("cli.gui"))
    plan_parser = commands.add_parser("plan", help=t("cli.plan"))
    plan_parser.add_argument("--no-update", action="store_true", help=t("cli.no_update"))
    plan_parser.add_argument("--json", action="store_true", help=t("cli.json"))
    build_parser = commands.add_parser("build", help=t("cli.build"))
    build_parser.add_argument("games", nargs="*", metavar="ID", help=t("cli.games"))
    build_parser.add_argument("--force", action="store_true", help=t("cli.force"))
    build_parser.add_argument("--no-update", action="store_true", help=t("cli.no_update"))
    build_parser.add_argument("--scheduled", action="store_true", help=argparse.SUPPRESS)
    commands.add_parser("status", help=t("cli.status"))
    commands.add_parser("doctor", help=t("cli.doctor"))
    commands.add_parser("setup", help=t("cli.setup"))
    schedule_parser = commands.add_parser("schedule", help=t("cli.schedule"))
    schedule_parser.add_argument("state", choices=("on", "off", "status"))
    schedule_parser.add_argument("--at", metavar="HH:MM", help=t("cli.at"))
    config_parser = commands.add_parser("config", help=t("cli.config"))
    config_parser.add_argument("key", nargs="?")
    config_parser.add_argument("value", nargs="?")
    args = parser.parse_args(argv)
    paths = Paths.default()
    try:
        ctx = batch.context(paths)
        command = args.command or "gui"
        if command == "gui":
            from . import gui

            return gui.main(ctx)
        if command == "plan":
            return _plan(ctx, update=not args.no_update, as_json=args.json)
        if command == "build":
            return _build(ctx, args)
        if command == "status":
            return _plan(ctx, update=False, as_json=False)
        if command == "doctor":
            return _doctor(ctx)
        if command == "setup":
            return _setup(ctx)
        if command == "schedule":
            return _schedule(ctx, args)
        if command == "config":
            return _config(ctx, args.key, args.value)
    except (batch.Busy, batch.Blocked, EngineError) as error:
        print(str(error), file=sys.stderr)
        return 3
    except KeyboardInterrupt:
        return 130
    return 0


def _plan(ctx: batch.Context, update: bool, as_json: bool) -> int:
    say = (lambda message: print(message, file=sys.stderr)) if as_json else print
    with batch.batch_lock(ctx.paths):
        result = batch.survey(ctx, update=update, log=say)
    if as_json:
        print(json.dumps({
            "head": result.head,
            "games": [
                {"title_id": e.title_id, "name": e.game.display_name, "build": e.build, "reasons": e.reasons, "detail": e.detail, "base": e.base, "ipa": e.ipa_name}
                for e in result.entries
            ],
            "issues": result.issues,
            "notes": [list(n) for n in result.notes],
        }, ensure_ascii=False, indent=2))
        return 0
    print(t("cli.engine_at", commit=result.head[:12]))
    for entry in result.entries:
        mark = "▶" if entry.build else "·"
        print(f"{mark} {entry.game.display_name} [{entry.title_id}]: {entry.detail}")
    for issue in result.issues:
        print(f"! {issue}")
    for commit, kind, text in result.notes:
        print(f"Front-ends {kind} ({commit}): {text}")
    print(t("cli.due", count=len(result.to_build)))
    return 0


def _build(ctx: batch.Context, args) -> int:
    only = {g.upper() for g in args.games}
    bad = [g for g in only if not titles.is_title_id(g)]
    if bad:
        print(t("cli.bad_ids", ids=", ".join(bad)), file=sys.stderr)
        return 2
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    last: dict[str, str] = {}

    def follow(kind: str, title_id: str, value) -> None:
        if kind == "start":
            print(t("cli.building", name=value.game.display_name, title_id=title_id, why=value.detail), flush=True)
        elif kind == "progress":
            text = value.text()
            if last.get(title_id) != value.stage:
                last[title_id] = value.stage
                print(f"  {text}", flush=True)
        elif kind == "message" and value.startswith("[RED] "):
            print(f"  {value}", flush=True)
        elif kind == "built":
            print(t("cli.built", name=value.ipa, minutes=int(value.duration // 60)), flush=True)
        elif kind == "failed":
            print(t("cli.failed", error=value), flush=True)
        elif kind == "log":
            print(f"  {value}", flush=True)

    try:
        plan, summary = batch.run_due(ctx, update=not args.no_update, force=only if args.force else None, only=only or None, on_event=follow, stop=stop, log=print)
    except batch.Busy as error:
        # The nightly run finds the window's batch running: nothing to do.
        print(str(error), file=sys.stderr)
        return 0 if args.scheduled else 3
    if not plan.to_build:
        print(t("cli.nothing_due"))
    if summary.report:
        print(t("cli.report", path=summary.report))
    if summary.stopped:
        return 130
    return 1 if summary.failed else 0


def _doctor(ctx: batch.Context) -> int:
    checks = toolchain.doctor(ctx.paths, ctx.engine.root if ctx.engine.present else None)
    for check in checks:
        mark = "✓" if check.ok else ("✗" if check.blocking else "·")
        print(f"{mark} {t(f'check.{check.key}')}: {check.found or t('cli.ok' if check.ok else 'cli.not_found')}")
        if not check.ok:
            print(f"    {check.fix}")
            if check.command:
                print(f"    $ {check.command}")
    return 0 if not toolchain.blocking(checks) else 1


def _setup(ctx: batch.Context) -> int:
    with batch.batch_lock(ctx.paths):
        print(t("batch.cloning_engine") if not ctx.engine.present else t("batch.updating_engine"))
        ctx.engine.update()
        toolchain.ensure_python(ctx.paths, ctx.engine.requirements, log=print)
        toolchain.write_dotnet_lock(ctx.paths)
    print(t("cli.setup_done"))
    return _doctor(ctx)


def _schedule(ctx: batch.Context, args) -> int:
    config = ctx.config
    if args.at:
        try:
            hour, minute = (int(x) for x in args.at.split(":"))
        except ValueError:
            print(t("cli.bad_time"), file=sys.stderr)
            return 2
        config.schedule_hour, config.schedule_minute = hour, minute
    if args.state != "status":
        config.schedule = args.state == "on"
        configs.save(ctx.paths, config)
        schedule.sync(ctx.paths, config.schedule, config.schedule_hour, config.schedule_minute)
    agent = schedule.installed()
    if agent:
        when = agent.get("StartCalendarInterval", {})
        print(t("cli.schedule_on", time=f"{when.get('Hour', 0):02d}:{when.get('Minute', 0):02d}"))
    else:
        print(t("cli.schedule_off"))
    return 0


def _config(ctx: batch.Context, key: str | None, value: str | None) -> int:
    config = ctx.config
    data = asdict(config)
    if key is None:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return 0
    if key not in data:
        print(t("cli.unknown_key", key=key, keys=", ".join(f.name for f in fields(config))), file=sys.stderr)
        return 2
    if value is None:
        print(json.dumps(data[key], ensure_ascii=False))
        return 0
    current = data[key]
    try:
        if isinstance(current, bool):
            parsed = value.lower() in ("1", "true", "yes", "on", "oui")
        elif isinstance(current, int):
            parsed = int(value)
        elif isinstance(current, (list, dict)):
            parsed = json.loads(value)
        else:
            parsed = value
    except ValueError:
        print(t("cli.bad_value", key=key), file=sys.stderr)
        return 2
    setattr(config, key, parsed)
    try:
        configs.save(ctx.paths, config)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    if key.startswith("schedule"):
        schedule.sync(ctx.paths, config.schedule, config.schedule_hour, config.schedule_minute)
    return 0
