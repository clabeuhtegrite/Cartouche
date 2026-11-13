"""Why a game was not built, as one name the app's measurements may send.

A cause is a name the builder gives, never the error's words, a path or a
line of a log (docs/privacy.md). The player reads the error itself, which
the builder words for the causes the player can act on (words):

  no_space    a disk filled up (disks.py): skipped, tried again next time
  damaged     the game's files are damaged: nxnative's check of a NUP's or a
              dump's files, a NUP's SHA-256, an NSP's hashes
  app_build   nxnative's iOS app did not build (its "app build" stage, Xcode):
              what a commit of nxnative can break for every game (fallback.py)
  crashed     nxnative's script ended on an exception of its own
  signal      nxnative ended on a signal (killed, out of memory?)
  refused     nxnative refused the builder's options (exit code 2)
  no_start    nxnative's script did not start
  no_ipa      nxnative ended without an IPA
  nxnative    another error nxnative said
  zip         a zipped dump that could not be unpacked, or of another game
  no_room     less room for the build folders than the settings keep
  keys        packages, and no prod.keys
  stopped     stopped by the player
  builder     an error in the builder's own code
"""

from __future__ import annotations

import re
from pathlib import Path

from . import disks
from .failure import name
from .i18n import t

APP_BUILD = "app build"  # nxnative's stage that builds the iOS app with Xcode

# What nxnative says of damaged game files: its check of a NUP's or a dump's
# files (check_formats), a NUP's table of contents or files that do not match
# their SHA-256 or size (pack_nup.py), an NSP failing its NCA hashes.
DAMAGED = re.compile(
    r"the game files are damaged|Pack again from a good copy|\(damaged file\)|copied or downloaded partly|NCA hash",
    re.IGNORECASE,
)
# "v131072: 3 file(s) whose bytes do not start as their names promise": the
# version of the game (v0, its base) whose files are damaged.
DAMAGED_VERSION = re.compile(r"^(v\d+): \d+ file\(s\) whose bytes", re.MULTILINE)
TRACEBACK = "Traceback (most recent call last):"


def told(result) -> str:
    """What nxnative told of a build.Result that did not build: its last
    errors, the last lines of the step that failed, and of its stderr."""
    return "\n".join([*result.said[-3:], *([result.tail] if getattr(result, "tail", "") else []), *result.stderr[-20:]])


def of_build(result) -> str:
    """The cause of a build.Result that did not build."""
    if result.stopped:
        return "stopped"
    if not result.started:
        return "no_start"
    if result.code == 2:
        return "refused"
    said = told(result)
    if disks.is_full(said):
        return "no_space"
    if DAMAGED.search(said):
        return "damaged"
    if result.code < 0 or result.code == 143:
        return "signal"
    if result.stage == APP_BUILD and result.code == 1:
        return "app_build"
    if exception_in(result.stderr):
        return "crashed"
    return "nxnative"


def exception_in(lines: list[str]) -> str | None:
    """The class of the exception the last traceback of LINES ends on
    ("KeyError"), never its words."""
    starts = [i for i, line in enumerate(lines) if line.startswith(TRACEBACK)]
    if not starts:
        return None
    for line in lines[starts[-1] + 1 :]:
        if line and not line.startswith((" ", "\t")):
            head = line.split(":", 1)[0].strip()
            return name(head.rpartition(".")[2])
    return None


def words(cause: str, said: str, folder: Path | None = None) -> str | None:
    """The player's words for CAUSE, when the builder has some: SAID is what
    nxnative said, FOLDER where the build was writing."""
    if cause == "no_space":
        return disks.message(folder, said)
    if cause == "damaged":
        found = DAMAGED_VERSION.search(said or "")
        part = ""
        if found:
            part = t("cause.damaged_base") if found.group(1) == "v0" else t("cause.damaged_update", version=found.group(1))
        return t("cause.damaged", part=part)
    return None
