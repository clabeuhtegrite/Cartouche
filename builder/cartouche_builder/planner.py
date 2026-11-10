"""What to build, and why: one entry per game of the sources folder.

A game is built when:

- it was never built, or its IPA is gone from the games folder;
- its folder has other files than at its last build (an update, DLC, a new dump);
- a commit since its last build touches it (its profile, or a fix naming it:
  impact.py);
- nxnative's shared code changed since, and the policy says so: "weekly" (a
  game is built again for shared changes once its build is a week old),
  "always" or "never";
- Xcode or the iOS SDK changed since;
- its IPA was made from a commit nxnative's branch does not have (a fork's),
  so what changed since cannot be known.

A game whose last build failed at the current commit, with the same files and
tools, waits for one of these to change instead of failing again every night.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

from . import ipa as ipas
from .config import Config
from .engine import Commit, Engine, Profile
from .i18n import t
from .impact import Impact, Matcher, analyze
from .library import Game
from .state import Build, Record, Store, age_days


@dataclass
class Entry:
    game: Game
    build: bool
    reasons: list[str] = field(default_factory=list)
    detail: str = ""
    base: str | None = None  # the commit the game's IPA was made from
    origin: str = ""  # where that is known from: builder, legacy, ipa
    impact: Impact | None = None
    ipa: Path | None = None  # its IPA in the games folder
    ipa_name: str = ""  # the name its new IPA gets there
    record: Record | None = None
    selected: bool = True

    @property
    def title_id(self) -> str:
        return self.game.title_id


@dataclass
class Plan:
    head: str
    entries: list[Entry]
    notes: list[tuple[str, str, str]] = field(default_factory=list)
    issues: list[str] = field(default_factory=list)

    @property
    def to_build(self) -> list[Entry]:
        return [e for e in self.entries if e.build]


def plan(
    games: list[Game],
    engine: Engine,
    head: str,
    profiles: dict[str, Profile],
    store: Store,
    config: Config,
    games_folder: Path | None,
    toolchain: str = "",
    force: set[str] | None = None,
    now: float | None = None,
) -> Plan:
    force = {f.upper() for f in force or set()}
    prints: dict[str, str] = {}
    matcher = Matcher({tid: p.name for tid, p in profiles.items()}, config.aliases)
    commits_since: dict[str, list[Commit]] = {}
    entries: list[Entry] = []
    notes: dict[tuple[str, str, str], None] = {}
    for game in games:
        record = store.get(game.title_id)
        entry = Entry(game=game, build=False, record=record, selected=config.selected(game.title_id))
        entries.append(entry)
        _locate(entry, games_folder, profiles)
        if not entry.selected and game.title_id not in force:
            entry.reasons, entry.detail = ["not_selected"], t("plan.not_selected")
            continue
        if game.title_id not in profiles and not config.unprofiled and game.title_id not in force:
            entry.reasons, entry.detail = ["no_profile"], t("plan.no_profile")
            continue

        build = record.build
        if build is None and entry.ipa is not None:
            build = _from_ipa(entry.ipa)
            if build:
                record = store.built(game.title_id, build)
                entry.record = record
        reasons: list[str] = []
        details: list[str] = []
        if game.title_id in force:
            reasons.append("forced")
            details.append(t("plan.forced"))
        if build is None:
            reasons.append("new")
            details.append(t("plan.new"))
            _finish(entry, reasons, details, head, prints)
            continue
        entry.base, entry.origin = build.commit, build.origin
        if entry.ipa is None and games_folder is not None:
            reasons.append("missing")
            details.append(t("plan.missing", name=build.ipa or entry.ipa_name))
        if build.fingerprint and build.fingerprint != _cached(game, prints):
            reasons.append("source")
            details.append(t("plan.source"))
        if build.toolchain and toolchain and build.toolchain != toolchain:
            reasons.append("toolchain")
            details.append(t("plan.toolchain", old=build.toolchain, new=toolchain))

        base = engine.resolve(build.commit)
        if base is None or not engine.is_ancestor(base, head):
            reasons.append("unknown_base")
            details.append(t("plan.unknown_base", commit=build.commit[:12]))
        else:
            if base not in commits_since:
                commits_since[base] = engine.commits(base, head)
            impact = analyze(commits_since[base], [game.title_id], matcher)[game.title_id]
            entry.impact = impact
            for note in impact.notes:
                notes[note] = None
            if impact.profile:
                reasons.append("profile")
                details.append(t("plan.profile", count=len(impact.profile), subject=_subject(impact.profile[-1])))
            if impact.named:
                reasons.append("named")
                details.append(t("plan.named", count=len(impact.named), subject=_subject(impact.named[-1])))
            if impact.shared and not impact.touched:
                due = _shared_due(config, build, now)
                if due is True:
                    reasons.append("shared")
                    details.append(t("plan.shared", count=len(impact.shared), days=int(age_days(build, now))))
                elif not reasons:
                    entry.detail = (
                        t("plan.shared_never", count=len(impact.shared))
                        if due is None
                        else t("plan.shared_waiting", count=len(impact.shared), date=due.strftime("%Y-%m-%d"))
                    )
        _finish(entry, reasons, details, head, prints)
    return Plan(head=head, entries=entries, notes=list(notes))


def _finish(entry: Entry, reasons: list[str], details: list[str], head: str, prints: dict[str, str]) -> None:
    record = entry.record
    attempt = record.attempt if record else None
    if reasons and attempt and attempt.result == "failed" and "forced" not in reasons:
        same = (
            attempt.commit[:12] == head[:12]
            and (not attempt.fingerprint or attempt.fingerprint == _cached(entry.game, prints))
        )
        if same:
            entry.reasons = ["failed_here"]
            entry.detail = t("plan.failed_here", error=_first_line(attempt.error))
            return
    if reasons:
        entry.build = True
        entry.reasons = reasons
        entry.detail = "; ".join(details)
    elif not entry.detail:
        entry.reasons = ["up_to_date"]
        build = record.build if record else None
        entry.detail = t("plan.up_to_date", commit=(build.commit[:12] if build else head[:12]))


def _shared_due(config: Config, build: Build, now: float | None):
    """True when shared changes are a reason now, a date when they will be, None never."""
    if config.engine_policy == "always":
        return True
    if config.engine_policy == "never":
        return None
    if age_days(build, now) >= config.refresh_days:
        return True
    return datetime.fromtimestamp(build.time) + timedelta(days=config.refresh_days)


def fingerprint(game: Game) -> str:
    """The game's files as they are now ("" when they cannot be read)."""
    try:
        return game.fingerprint()
    except OSError:
        return ""


def _cached(game: Game, prints: dict[str, str]) -> str:
    if game.title_id not in prints:
        prints[game.title_id] = fingerprint(game)
    return prints[game.title_id]


def _locate(entry: Entry, games_folder: Path | None, profiles: dict[str, Profile]) -> None:
    """The game's IPA in the games folder, and the name its next one gets."""
    game, record = entry.game, entry.record
    recorded = record.build.ipa if record and record.build and record.build.ipa else ""
    if games_folder is None:
        entry.ipa_name = recorded or ipas.file_name(game.display_name, game.title_id)
        return
    if recorded and (games_folder / recorded).is_file():
        entry.ipa, entry.ipa_name = games_folder / recorded, recorded
        return
    found = ipas.find_in_folder(games_folder, game.title_id, read=not recorded)
    if found:
        tagged = [p for p in found if game.title_id in p.name.upper()]
        chosen = (tagged or sorted(found, key=lambda p: p.stat().st_mtime, reverse=True))[0]
        entry.ipa, entry.ipa_name = chosen, chosen.name
        return
    name = profiles[game.title_id].name if game.title_id in profiles and profiles[game.title_id].name else game.display_name
    entry.ipa_name = recorded or ipas.file_name(name, game.title_id)


def _from_ipa(path: Path) -> Build | None:
    """A build record from an IPA the builder did not make (NxNative Batch
    Builder's, or one built by hand): its commit and date are in it."""
    info = ipas.read_info(path)
    if not info or not info.commit:
        return None
    built = info.built or datetime.fromtimestamp(path.stat().st_mtime)
    return Build(
        commit=info.commit,
        built_at=built.astimezone().isoformat(),
        ipa=path.name,
        size=path.stat().st_size,
        chain=info.chain or "",
        version=info.version or "",
        name=info.name or "",
        origin="ipa",
        dirty=info.dirty,
    )


def _subject(commit: Commit) -> str:
    subject = commit.subject
    return subject if len(subject) <= 110 else subject[:107].rstrip() + "…"


def _first_line(text: str) -> str:
    line = (text or "").strip().splitlines()[0] if (text or "").strip() else ""
    return line if len(line) <= 160 else line[:157] + "…"
