#!/usr/bin/env python3
"""Sums up, for nxnative's developers, what Cartouche's players measured of
nxnative's games in the last 28 days: the page the nxnative page workflow
puts on the branch nxnative-measurements each Thursday
(.github/workflows/nxnative.yml, telemetry/README.md#nxnatives-page).

By game, by game and model, and by game and nxnative commit: installs,
sessions and hours, the frame rate, the frame time, the stutters and what
they waited for, the shader stall, the preparation before the first frame,
the memory peak, the heat, and how the sessions ended; the crashes several
installs shared; the devices players have; and the builds on players' Macs,
by nxnative commit. Every line, and every figure, sums up at least three
installs, as everything the project publishes does (docs/privacy.md): a
smaller group is left out, and no install's or session's number is ever
written. Beside the page, for Cartouche Builder, unbuilt.json: the games at
least three Macs tried and none built, which the app warns of before one is
built (builder/mac/Sources/BuilderKit/Unbuilt.swift). Set apart, so that they do not read as nxnative's: the sessions on
iPhones whose GPU reads no BC texture, which nxnative refuses; those whose
game process ran without Increased Memory Limit, which is Cartouche's doing;
and those of builds with changes of their own.

It reads the D1 database through Cloudflare's API, with the secrets
CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID, and does nothing without
them. It writes the page as README.md, and unbuilt.json, into --out, says
what it found in the job's summary, and sets the job's output written to
true or false.

    python3 telemetry/nxnative.py --catalog catalog --out build/nxnative

Python's standard library only.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sheets import (  # noqa: E402
    API, DATABASE, MIN_IPHONES, PAGE, SLOWEST_READER, WINDOW_DAYS, Cloudflare, Refused, figure_of, number,
)

# A line, and each of its figures, needs this many installs, as the sheets do.
MIN_INSTALLS = MIN_IPHONES
BRANCH = "nxnative-measurements"

# iPhones whose GPU reads no BC texture: the A16 and older ones, iPhone15,x
# and before. nxnative's iOS check refuses them for every game.
IPHONE = re.compile(r"^iPhone([0-9]+),[0-9]+$")
LAST_WITHOUT_BC = 15

# A game process with this limit or less, while Cartouche had more, ran
# without Increased Memory Limit (CartoucheGuest.m): Cartouche's doing, not
# nxnative's.
WITHOUT_IML_MIB = 3376

SIGNALS = {4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS",
           11: "SIGSEGV", 12: "SIGSYS"}

# The sessions one day received, a page at a time, with D1's parameters as
# text. A session sent again because its log grew is the same session with
# a higher seq.
SESSIONS = (
    "SELECT id, install, session, seq, day, device, ios, game, "
    "json_extract(body, '$.nxnative') AS nxnative, "
    "json_extract(body, '$.nxnativeChanged') AS changed, "
    "json_extract(body, '$.gameVersion') AS version, "
    "json_extract(body, '$.minutes') AS minutes, "
    "json_extract(body, '$.frames') AS frames, "
    "json_extract(body, '$.targetFps') AS target, "
    "json_extract(body, '$.fps.median') AS fps, "
    "json_extract(body, '$.fps.low5') AS slowest, "
    "json_extract(body, '$.frameMs.p99') AS p99, "
    "json_extract(body, '$.stutters.perMinute') AS stutters, "
    "json_extract(body, '$.stutters.count') AS stutterCount, "
    "json_extract(body, '$.stutters.shaders') AS stutterShaders, "
    "json_extract(body, '$.shaderStallMsPerMinute') AS stall, "
    "json_extract(body, '$.prepare.seconds') AS prepare, "
    "json_extract(body, '$.memory.peakMiB') AS peak, "
    "json_extract(body, '$.thermal.seriousAfterMinutes') AS serious, "
    "json_extract(body, '$.end.kind') AS ending, "
    "json_extract(body, '$.end.signal') AS signal, "
    "json_extract(body, '$.end.pc') AS pc, "
    "json_extract(body, '$.end.lr') AS lr, "
    "json_extract(body, '$.process.limitMiB') AS processLimit, "
    "json_extract(body, '$.memoryLimitMiB') AS limitMiB, "
    "json_extract(body, '$.reader') AS reader "
    f"FROM reports WHERE kind = 'session' AND day = ?1 AND id > ?2 ORDER BY id LIMIT {PAGE}"
)

# The events the page reads: Cartouche's starts, for the devices, and
# Cartouche Builder's starts and builds, for the builds by commit.
EVENTS = (
    "SELECT id, install, seq, day, device, ios, name, "
    "json_extract(body, '$.memoryLimitMiB') AS limitMiB, "
    "json_extract(body, '$.increasedMemoryLimit') AS iml, "
    "json_extract(body, '$.fields.nxnative') AS nxnative, "
    "json_extract(body, '$.fields.stage') AS stage, "
    "json_extract(body, '$.fields.cause') AS cause, "
    "json_extract(body, '$.fields.forkOfNxnative') AS fork, "
    "json_extract(body, '$.fields.seconds') AS seconds, game "
    "FROM reports WHERE kind = 'event' "
    "AND name IN ('app.opened', 'builder.opened', 'builder.built', 'builder.failed') "
    f"AND day = ?1 AND id > ?2 ORDER BY id LIMIT {PAGE}"
)


def read(cloudflare: Cloudflare, database: str, sql: str, first: dt.date, last: dt.date) -> list[dict]:
    """The rows of SQL for each day from first to last."""
    rows: list[dict] = []
    day = first
    while day <= last:
        after = ""
        while True:
            page = cloudflare.query(database, sql, [day.isoformat(), after])
            rows += page
            if len(page) < PAGE:
                break
            after = page[-1]["id"]
        day += dt.timedelta(days=1)
    return rows


def once(rows: list[dict], key) -> list[dict]:
    """Each row of rows once by key, the one with the highest seq."""
    kept: dict = {}
    for row in rows:
        k = key(row)
        if k not in kept or (row.get("seq") or 0) > (kept[k].get("seq") or 0):
            kept[k] = row
    return list(kept.values())


# MARK: Sessions


def reads_bc(device: str | None) -> bool:
    found = IPHONE.match(device or "")
    return not found or int(found.group(1)) > LAST_WITHOUT_BC


def set_apart(session: dict) -> str | None:
    """Why the session does not count for nxnative, if it does not."""
    if not reads_bc(session.get("device")):
        return "gpu"
    process, limit = number(session.get("processLimit")), number(session.get("limitMiB"))
    if process is not None and process <= WITHOUT_IML_MIB and (limit or 0) > process:
        return "memory"
    if session.get("changed") in (1, True):
        return "changed"
    return None


def drew_frames(session: dict) -> bool:
    """Whether the session got into the game: it drew a frame."""
    return (number(session.get("frames")) or 0) > 0 or number(session.get("fps")) is not None


def ending(session: dict) -> str | None:
    """How a session ended badly: it crashed, failed to boot, ran out of
    memory, or ended before it drew a frame."""
    kind = session.get("ending")
    if kind in ("crash", "boot-failed", "memory-likely"):
        return kind
    return None if drew_frames(session) else "no-frame"


class Group:
    """Sessions summed up together, each install counting once."""

    def __init__(self, sessions: list[dict]):
        self.sessions = sessions

    @property
    def installs(self) -> set[str]:
        return {s["install"] for s in self.sessions}

    def figure(self, key: str, sessions: list[dict] | None = None, highest: bool = False) -> float | None:
        """The median of each install's own median, or of its highest; none
        when fewer than MIN_INSTALLS installs gave the value. The slowest 5%
        counts only from the reading of the log that takes pauses out, as in
        the game sheets (sheets.SLOWEST_READER)."""
        by: dict[str, list[float]] = defaultdict(list)
        for s in self.sessions if sessions is None else sessions:
            value = figure_of(s, key)
            if value is not None:
                by[s["install"]].append(value)
        if len(by) < MIN_INSTALLS:
            return None
        return statistics.median(max(v) if highest else statistics.median(v) for v in by.values())

    @property
    def peak(self) -> float | None:
        """Each install's highest peak of its sessions that drew a frame."""
        return self.figure("peak", [s for s in self.sessions if drew_frames(s)], highest=True)

    @property
    def shader_share(self) -> float | None:
        """The share of the stutters that waited for shaders, of the
        installs that counted stutters."""
        counted = [s for s in self.sessions if (number(s.get("stutterCount")) or 0) > 0]
        if len({s["install"] for s in counted}) < MIN_INSTALLS:
            return None
        return sum(number(s.get("stutterShaders")) or 0 for s in counted) / sum(number(s["stutterCount"]) for s in counted)

    @property
    def hours(self) -> float:
        return sum(number(s.get("minutes")) or 0 for s in self.sessions) / 60

    @property
    def target(self) -> int | None:
        targets = Counter(int(t) for t in (number(s.get("target")) for s in self.sessions) if t)
        return targets.most_common(1)[0][0] if targets else None

    @property
    def hot(self) -> int:
        return sum(1 for s in self.sessions if number(s.get("serious")) is not None)

    @property
    def endings(self) -> Counter:
        return Counter(e for e in (ending(s) for s in self.sessions) if e)



def fmt(value: float | None, digits: int = 0) -> str:
    if value is None:
        return "–"
    return f"{value:,.{digits}f}"


def listed(items) -> str:
    items = list(items)
    return ", ".join(items) if items else f"none on {MIN_INSTALLS} installs or more"


def installs_text(n: int) -> str:
    return f"{n} installs" if n >= MIN_INSTALLS or n == 0 else f"fewer than {MIN_INSTALLS} installs"


def shared(pairs) -> tuple[list[tuple[str, int]], int]:
    """Of (value, install) pairs, the values at least MIN_INSTALLS installs
    share, with how many share each, most first; and how many other values
    there are, which fewer installs share."""
    by: dict[str, set] = defaultdict(set)
    for value, install in pairs:
        if value:
            by[value].add(install)
    kept = sorted(((v, len(i)) for v, i in by.items() if len(i) >= MIN_INSTALLS), key=lambda vi: (-vi[1], vi[0]))
    return kept, len(by) - len(kept)


def most_shared(pairs, what: str) -> str:
    """The value most installs share, when at least MIN_INSTALLS do, and
    how many others; or only how many values, or "not said"."""
    kept, others = shared(pairs)
    if not kept:
        return f"{others} {what}{'s' if others > 1 else ''}" if others else "not said"
    rest = len(kept) - 1 + others
    return f"`{kept[0][0]}`" + (f" (+{rest})" if rest else "")


class Catalog:
    """The names of the games, a copy of another region under its game."""

    def __init__(self, catalog: Path):
        games = json.loads((catalog / "nxnative.json").read_text(encoding="utf-8"))["games"]
        self.names = {g["titleId"]: g["name"] for g in games}
        self.main = {v["titleId"]: g["titleId"] for g in games for v in g.get("variants", [])}
        covers = catalog / "covers.json"
        if covers.exists():
            for cover in json.loads(covers.read_text(encoding="utf-8")).get("covers", []):
                if cover.get("name"):
                    self.names.setdefault(cover["titleId"], cover["name"])

    def game(self, title: str | None) -> str | None:
        return self.main.get(title, title) if title else None

    def name(self, title: str) -> str:
        name = self.names.get(title)
        return f"{name} `{title}`" if name else f"`{title}`"


def commits_text(group: Group) -> str:
    """The nxnative commit most installs of the group ran, and how many others."""
    return most_shared(((s.get("nxnative"), s["install"]) for s in group.sessions), "commit")


FIGURES = ("Installs | Sessions | Hours | Target fps | FPS median | FPS slowest 5% | Frame p99 ms | Stutters a minute "
           "| Waiting for shaders | Shader stall ms a minute | Prepare s | Peak MiB | Reached serious heat | Crashed "
           "| Failed to boot | Out of memory | Drew no frame")


def figures(group: Group) -> str:
    endings = group.endings
    share = group.shader_share
    return " | ".join([
        str(len(group.installs)), str(len(group.sessions)), fmt(group.hours, 1), fmt(group.target),
        fmt(group.figure("fps"), 1), fmt(group.figure("slowest"), 1), fmt(group.figure("p99"), 1),
        fmt(group.figure("stutters")), "–" if share is None else f"{share:.0%}", fmt(group.figure("stall")),
        fmt(group.figure("prepare"), 1), fmt(group.peak), f"{group.hot} of {len(group.sessions)}",
        str(endings["crash"]), str(endings["boot-failed"]), str(endings["memory-likely"]), str(endings["no-frame"]),
    ])


def table(title: str, keys: list[str], groups: dict[tuple, Group], cells, empty: str) -> list[str]:
    kept = sorted(((key, group) for key, group in groups.items() if len(group.installs) >= MIN_INSTALLS),
                  key=lambda kv: (-len(kv[1].installs), -len(kv[1].sessions), kv[0]))
    lines = [f"## {title}", ""]
    if not kept:
        return lines + [empty, ""]
    lines += ["| " + " | ".join(keys) + " | " + FIGURES + " |",
              "|" + " --- |" * (len(keys) + FIGURES.count("|") + 1)]
    for key, group in kept:
        lines.append("| " + " | ".join(cells(key, group)) + " | " + figures(group) + " |")
    return lines + [""]


# MARK: The page


def page(catalog: Catalog, sessions: list[dict], events: list[dict], first: dt.date, last: dt.date) -> tuple[str, list[str]]:
    """The page, and the lines of the job's summary."""
    sessions = once(sessions, lambda s: (s["install"], s["session"]))
    for s in sessions:
        s["game"] = catalog.game(s.get("game"))
    apart = Counter()
    apart_installs: dict[str, set] = defaultdict(set)
    kept = []
    for s in sessions:
        reason = set_apart(s)
        if reason:
            apart[reason] += 1
            apart_installs[reason].add(s["install"])
        elif s.get("game"):
            kept.append(s)

    by_game: dict[tuple, Group] = defaultdict(lambda: Group([]))
    by_model: dict[tuple, Group] = defaultdict(lambda: Group([]))
    by_commit: dict[tuple, Group] = defaultdict(lambda: Group([]))
    for s in kept:
        by_game[(s["game"],)].sessions.append(s)
        by_model[(s["game"], s.get("device") or "")].sessions.append(s)
        if s.get("nxnative"):
            by_commit[(s["game"], s["nxnative"])].sessions.append(s)

    installs = {s["install"] for s in sessions}
    named = sum(1 for s in kept if s.get("nxnative"))
    hours = sum(number(s.get("minutes")) or 0 for s in sessions) / 60
    # The page says the days it has measurements of, within the 28.
    days = sorted(r["day"] for r in sessions + events if r.get("day"))
    since = days[0] if days else first.isoformat()
    lines = [
        "# nxnative's games on players' iPhones",
        "",
        f"What the players of [Cartouche](https://github.com/clabeuhtegrite/Cartouche) measured of nxnative's games "
        f"from {since} to {last}, summed up for nxnative's developers each Thursday. How, and what is left out: "
        "[telemetry/README.md](https://github.com/clabeuhtegrite/Cartouche/blob/main/telemetry/README.md#nxnatives-page).",
        "",
        f"{len(sessions)} game sessions from {installs_text(len(installs))}, {hours:,.1f} hours of play. "
        f"{named} of the {len(kept)} sessions that count name their nxnative commit. "
        f"Every line, and every figure, sums up at least {MIN_INSTALLS} installs: a smaller group is left out, "
        "and a figure fewer installs gave shows –.",
        "",
    ]
    if apart:
        said = {"gpu": "on iPhones whose GPU reads no BC texture (A16 and older), which nxnative refuses",
                "memory": "whose game process ran without Increased Memory Limit, which is Cartouche's doing",
                "changed": "of builds with changes of their own"}
        lines += ["Set apart: " + "; ".join(
            f"{apart[reason]} sessions {said[reason]}, from {installs_text(len(apart_installs[reason]))}"
            if len(apart_installs[reason]) >= MIN_INSTALLS else f"sessions {said[reason]}, from {installs_text(1)}"
            for reason in ("gpu", "memory", "changed") if apart[reason]) + ".", ""]

    lines += table("By game", ["Game", "nxnative"], by_game,
                   lambda key, group: [catalog.name(key[0]), commits_text(group)],
                   f"No game was played on {MIN_INSTALLS} installs or more.")
    lines += table("By game and model", ["Game", "Model", "nxnative"], by_model,
                   lambda key, group: [catalog.name(key[0]), f"`{key[1]}`", commits_text(group)],
                   f"No game was played on {MIN_INSTALLS} installs or more of one model.")
    lines += table("By game and nxnative commit", ["Game", "nxnative"], by_commit,
                   lambda key, group: [catalog.name(key[0]), f"`{key[1]}`"],
                   f"No game was played from one nxnative commit on {MIN_INSTALLS} installs or more.")
    lines += crashes(catalog, kept)
    lines += devices(events)
    lines += builds(events)
    lines += [
        "## How it is summed up",
        "",
        "- An install is one copy of Cartouche on one iPhone or iPad, under a random number it changes every 13 months "
        "or when its player erases what it sent: a player who installs Cartouche again is a new install. A Mac is one "
        "copy of Cartouche Builder. Neither number is ever written here.",
        "- Each figure is the median of each install's own median, so that each install counts once however much it "
        "played; the peak is each install's highest, of its sessions that drew a frame. Stutters waiting for shaders "
        "are a share of all the stutters of the line.",
        "- FPS slowest 5% is the rate of the slowest 5% of a session's time: the frame rate of each `[nvn] power` "
        "line, over its 300 frames, weighted by how long they lasted. nxnative times them by the clock, so a stretch "
        "that held a pause, the game left behind Cartouche's console or Cartouche in the background counts at the "
        f"rate that pause brought it to: it counts only from the sessions Cartouche read with its reading {SLOWEST_READER} "
        "of the log or a later one, which leaves such a stretch out, and shows – before. Stutters and the shader "
        "stall are per minute of the whole session.",
        "- The figures come from the lines nxnative writes in `log.txt`, which Cartouche reads after each session "
        "([CartoucheGameLog.swift](https://github.com/clabeuhtegrite/Cartouche/blob/main/launcher/Sources/"
        "CartoucheGameLog.swift)): the `[nvn]` timing, on-screen and power lines, `[longframe]`, `pipeline prepare`, "
        "the memory and thermal lines, `CRASH sig=` and `[RED] boot:`. "
        "A session's commit is the first 12 digits of `DMCommit` in the game's `Info.plist`; Cartouche 0.11.2 and "
        "before did not send it. Target fps is the rate most of the line's sessions asked for.",
        "- Reached serious heat: the sessions iOS put in its serious thermal state. Drew no frame: the session ended "
        "before nxnative's first summary line, whatever its end.",
        "- A session counts once, as last sent; a copy of another region counts for its game.",
        "- nxnative, Models: the commit, or the model, most installs of the line ran, when at least 3 did, and how "
        "many others; else only how many. A Mac counts as an install does: a step of a build shows when at least 3 "
        "Macs failed at it.",
        "- Builds: the Macs whose Cartouche Builder follows a fork of nxnative are left out, and so are the builds "
        "the player stopped and the errors of Cartouche Builder's own code. Where they failed is nxnative's stage.",
        "",
    ]
    summary = [f"## nxnative's page, {first} to {last}", "",
               f"{len(sessions)} game sessions from {len(installs)} installs; "
               f"{sum(1 for g in by_game.values() if len(g.installs) >= MIN_INSTALLS)} games, "
               f"{sum(1 for g in by_model.values() if len(g.installs) >= MIN_INSTALLS)} lines by model and "
               f"{sum(1 for g in by_commit.values() if len(g.installs) >= MIN_INSTALLS)} by commit "
               f"on {MIN_INSTALLS} installs or more; {named} sessions name their nxnative commit.", ""]
    return "\n".join(lines), summary


def crashes(catalog: Catalog, kept: list[dict]) -> list[str]:
    crashed = [s for s in kept if s.get("ending") == "crash"]
    by_signal: dict[tuple, Group] = defaultdict(lambda: Group([]))
    exact: dict[tuple, Group] = defaultdict(lambda: Group([]))
    for s in crashed:
        signal = int(number(s.get("signal")) or 0)
        by_signal[(s["game"], signal)].sessions.append(s)
        if s.get("pc") and s.get("nxnative"):
            exact[(s["game"], s.get("version") or "", s["nxnative"], signal, s["pc"], s.get("lr") or "")].sessions.append(s)
    lines = ["## Crashes", ""]
    rows = sorted(((k, g) for k, g in by_signal.items() if len(g.installs) >= MIN_INSTALLS),
                  key=lambda kv: (-len(kv[1].installs), kv[0]))
    if rows:
        lines += ["| Game | Signal | Installs | Sessions | Models | nxnative | Minutes in |",
                  "| --- | --- | --- | --- | --- | --- | --- |"]
        for (game, signal), group in rows:
            models = most_shared(((s.get("device"), s["install"]) for s in group.sessions), "model")
            lines.append(f"| {catalog.name(game)} | {SIGNALS.get(signal, signal or '–')} | {len(group.installs)} | "
                         f"{len(group.sessions)} | {models} | {commits_text(group)} | "
                         f"{fmt(group.figure('minutes'), 1)} |")
        lines.append("")
    else:
        lines += [f"No game crashed with one signal on {MIN_INSTALLS} installs or more.", ""]
    rows = sorted(((k, g) for k, g in exact.items() if len(g.installs) >= MIN_INSTALLS),
                  key=lambda kv: (-len(kv[1].installs), kv[0]))
    if rows:
        lines += ["The same crash, at the same place of the same build, on several installs:", "",
                  "| Game | Version | nxnative | Signal | pc | lr | Installs | Sessions | Minutes in |",
                  "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
        for (game, version, commit, signal, pc, lr), group in rows:
            lines.append(f"| {catalog.name(game)} | {version or '–'} | `{commit}` | {SIGNALS.get(signal, signal)} | "
                         f"`{pc}` | `{lr}` | {len(group.installs)} | {len(group.sessions)} | "
                         f"{fmt(group.figure('minutes'), 1)} |")
        lines.append("")
    return lines


def devices(events: list[dict]) -> list[str]:
    """The devices of the installs that started Cartouche, as each last did."""
    last = once([e for e in events if e.get("name") == "app.opened"], lambda e: e["install"])
    lines = ["## Devices", "", f"The installs that started Cartouche, as each last did: {installs_text(len(last))}.", ""]
    if len(last) < MIN_INSTALLS:
        return lines
    models = Counter(e.get("device") or "" for e in last)
    shown = sorted(((m, n) for m, n in models.items() if n >= MIN_INSTALLS), key=lambda mn: (-mn[1], mn[0]))
    rest = sum(n for _, n in models.items()) - sum(n for _, n in shown)
    others = len(models) - len(shown)
    lines.append("- Models: " + listed(f"`{m}` {n}" for m, n in shown)
                 + (f"; {installs_text(rest)} on {others} other model{'s' if others > 1 else ''}" if rest else "") + ".")
    ios = Counter(".".join((e.get("ios") or "").split(".")[:2]) for e in last)
    lines.append("- iOS: " + listed(
        f"{v} {n}" for v, n in sorted(ios.items(), key=lambda vn: [int(x) for x in vn[0].split(".") if x.isdigit()])
        if n >= MIN_INSTALLS and v) + ".")
    limits = Counter((int(number(e.get("limitMiB")) or 0), e.get("iml") in (1, True)) for e in last)
    lines.append("- The memory limit iOS sets for Cartouche: " + listed(
        f"{limit:,} MiB{'' if iml else ' without Increased Memory Limit'} on {n}"
        for (limit, iml), n in sorted(limits.items(), key=lambda kn: (-kn[1], -kn[0][0], not kn[0][1]))
        if n >= MIN_INSTALLS and limit) + ".")
    no_bc = sum(1 for e in last if not reads_bc(e.get("device")))
    lines += [f"- iPhones whose GPU reads no BC texture (A16 and older): {installs_text(no_bc)}.", ""]
    return lines


# Failures that are not nxnative's: the player stopped the build, or
# Cartouche Builder's own code failed (builder/cartouche_builder/causes.py).
NOT_NXNATIVES = ("stopped", "builder")


def builds(events: list[dict]) -> list[str]:
    """Cartouche Builder's builds on players' Macs, by nxnative commit, but
    those of a fork of nxnative and the failures that are not nxnative's."""
    forks = {e["install"] for e in once([e for e in events if e.get("name") == "builder.opened"], lambda e: e["install"])
             if e.get("fork") in (1, True)}
    by: dict[str, dict] = defaultdict(lambda: {"macs": set(), "built": 0, "failed": []})
    for e in events:
        if e.get("name") not in ("builder.built", "builder.failed") or e["install"] in forks or not e.get("nxnative"):
            continue
        if e["name"] == "builder.failed" and e.get("cause") in NOT_NXNATIVES:
            continue
        commit = by[e["nxnative"]]
        commit["macs"].add(e["install"])
        if e["name"] == "builder.built":
            commit["built"] += 1
        else:
            commit["failed"].append((e.get("stage") or "a step not said", e["install"]))
    rows = sorted(((c, b) for c, b in by.items() if len(b["macs"]) >= MIN_INSTALLS),
                  key=lambda kv: (-len(kv[1]["macs"]), kv[0]))
    lines = ["## Builds on players' Macs, by nxnative commit", "",
             "Cartouche Builder builds players' games with nxnative's build script, on their Macs.", ""]
    if not rows:
        return lines + [f"No nxnative commit was built on {MIN_INSTALLS} Macs or more.", ""]
    lines += ["| nxnative | Macs | Built | Failed | Where they failed |", "| --- | --- | --- | --- | --- |"]
    for commit, b in rows:
        # The steps at least MIN_INSTALLS Macs failed at, with how many
        # failures each; the others together.
        stages, _ = shared(b["failed"])
        counts = Counter(stage for stage, _ in b["failed"])
        where = [f"{stage} {counts[stage]}" for stage, _ in stages]
        rest = len(b["failed"]) - sum(counts[stage] for stage, _ in stages)
        if rest:
            where.append(f"other steps {rest}")
        lines.append(f"| `{commit}` | {len(b['macs'])} | {b['built']} | {len(b['failed'])} | {', '.join(where) or '–'} |")
    return lines + [""]


# A game's own failures, as Cartouche Builder names their causes
# (builder/cartouche_builder/causes.py), and those of a builder older than
# 0.5.0, which named none: not the player's files (damaged, zip, keys), nor
# the Mac's (no_space, no_room, metal), nor a commit of nxnative that breaks
# every game's app build (app_build), nor a stop or the builder's own code.
GAMES_OWN = (None, "", "nxnative", "crashed", "signal", "no_ipa")


def unbuilt(events: list[dict], first: dt.date, last: dt.date) -> dict:
    """unbuilt.json, for Cartouche Builder: the games at least MIN_INSTALLS
    Macs tried in the window, failing for reasons of the game's own, and
    none built, those of a fork of nxnative left out. For each, how many
    Macs tried and how many builds failed; the median of each Mac's longest
    attempt, in hours, when MIN_INSTALLS Macs said how long it took; and the
    step the most Macs failed at, when MIN_INSTALLS share it."""
    forks = {e["install"] for e in once([e for e in events if e.get("name") == "builder.opened"], lambda e: e["install"])
             if e.get("fork") in (1, True)}
    built = {e["game"] for e in events if e.get("name") == "builder.built" and e.get("game") and e["install"] not in forks}
    tried: dict[str, dict] = defaultdict(lambda: {"macs": {}, "failures": 0, "stages": []})
    for e in events:
        if e.get("name") != "builder.failed" or e["install"] in forks or not e.get("game") or e.get("cause") not in GAMES_OWN:
            continue
        game = tried[e["game"]]
        game["failures"] += 1
        seconds = e.get("seconds") if isinstance(e.get("seconds"), (int, float)) else 0
        game["macs"][e["install"]] = max(game["macs"].get(e["install"], 0), seconds)
        # A step not said counts for none: the app shows the step as is.
        game["stages"].append((e.get("stage") or "", e["install"]))
    games = []
    for title, game in sorted(tried.items()):
        if title in built or len(game["macs"]) < MIN_INSTALLS:
            continue
        entry: dict = {"titleId": title, "macs": len(game["macs"]), "failures": game["failures"]}
        longest = [seconds for seconds in game["macs"].values() if seconds > 0]
        if len(longest) >= MIN_INSTALLS:
            entry["hours"] = round(statistics.median(longest) / 3600, 1)
        stages, _ = shared(game["stages"])
        if stages:
            entry["stage"] = stages[0][0]
        games.append(entry)
    return {"schema": 1, "from": first.isoformat(), "to": last.isoformat(), "games": games}


def run(catalog: Path, out: Path, today: dt.date, cloudflare: Cloudflare) -> list[str]:
    """Writes the page and unbuilt.json into out; returns the lines of the
    job's summary."""
    first, last = today - dt.timedelta(days=WINDOW_DAYS), today - dt.timedelta(days=1)
    database = cloudflare.database(DATABASE)
    sessions = read(cloudflare, database, SESSIONS, first, last)
    events = read(cloudflare, database, EVENTS, first, last)
    text, summary = page(Catalog(catalog), sessions, events, first, last)
    out.mkdir(parents=True, exist_ok=True)
    (out / "README.md").write_text(text, encoding="utf-8")
    never = unbuilt(events, first, last)
    (out / "unbuilt.json").write_text(json.dumps(never, indent=2) + "\n", encoding="utf-8")
    return summary + [f"Games no Mac built, of {MIN_INSTALLS} Macs or more: {len(never['games'])}, in unbuilt.json.",
                      f"The page goes on the branch `{BRANCH}`."]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--catalog", type=Path, default=Path("catalog"))
    parser.add_argument("--out", type=Path, required=True, help="where the page is written, as README.md")
    parser.add_argument("--today", type=dt.date.fromisoformat, default=dt.datetime.now(dt.timezone.utc).date(),
                        help="the day of the run, in UTC: the sessions of the 28 days before it count")
    args = parser.parse_args(argv)

    def output(written: bool) -> None:
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as file:
                file.write(f"written={'true' if written else 'false'}\n")

    token, account = os.environ.get("CLOUDFLARE_API_TOKEN"), os.environ.get("CLOUDFLARE_ACCOUNT_ID")
    if not token or not account:
        print("::notice::CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID are not set: no measurement was read.")
        output(False)
        return 0
    cloudflare = Cloudflare(account, token, os.environ.get("CLOUDFLARE_API") or API)
    try:
        lines = run(args.catalog, args.out, args.today, cloudflare)
    except Refused as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    print("\n".join(lines))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as file:
            file.write("\n".join(lines) + "\n")
    output(True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
