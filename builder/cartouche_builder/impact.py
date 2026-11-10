"""Which of nxnative's commits touch a game.

nxnative gets dozens of commits a day, and almost every one changes code all
games share: building every game again for each would keep the Mac busy for
nothing. A commit touches a game when:

- it changes the game's profile (dm/games/<title ID>/), or
- its message names the game (its name in nxnative, a short form of it such as
  "Ocarina of Time", or a name the player gave it) and it changes code that
  goes into a build: most fixes say which game they were made for.

Any other change to that code is shared: what a game gets from it is not
known, and the planner builds it again on its own schedule (planner.py).
Documentation, tests and the repository's own tooling never touch a game.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field

from . import titles
from .engine import Commit

# Short names commit messages use beside nxnative's own, by title ID.
KNOWN_ALIASES: dict[str, tuple[str, ...]] = {
    "01007EF00011E000": ("BotW", "Breath of the Wild"),
    "0100F2C0115B6000": ("TotK", "Tears of the Kingdom"),
    "0400C3F00006E000": ("MKW",),
    "040074A01BF12000": ("Bananza", "DK Bananza"),
    "0100000000010000": ("SMO",),
    "01006A800016E000": ("Smash Ultimate", "SSBU"),
    "0400486024DEC000": ("OoT",),
}

MIN_ALIAS = 4  # a shorter derived name ("Z-A") is too likely to mean something else


def normalize(text: str) -> str:
    """Lower case, without accents, trademark signs or curly quotes."""
    text = text.replace("™", "").replace("®", "").replace("©", "")
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = text.replace("’", "'").replace("‘", "'").replace("–", "-").replace("—", "-")
    return re.sub(r"\s+", " ", text.lower()).strip()


def derived_names(name: str) -> set[str]:
    """The short forms of a game's name a message may use."""
    out = set()
    base = re.sub(r"\s*\([^)]*\)\s*$", "", name).strip()
    out.add(base)
    if ":" in base:
        head, _, tail = base.partition(":")
        out.update({head.strip(), tail.strip()})
    for part in list(out):
        if " - " in part:
            out.add(part.split(" - ", 1)[0].strip())
    for part in list(out):
        if part.lower().startswith("the "):
            out.add(part[4:])
    out.discard(name)
    return {n for n in out if len(normalize(n)) >= MIN_ALIAS}


class Matcher:
    """Finds the games a commit message names.

    It knows every profile's name, not only the player's games, so that a name
    inside a longer one ("OCTOPATH TRAVELER" in "OCTOPATH TRAVELER II") is
    the longer one's. A short form two games share ("The Legend of Zelda") is
    neither's.
    """

    def __init__(self, names: dict[str, str], extra: dict[str, list[str]] | None = None):
        # Exact names first: a game's own name beats another's short form.
        exact: dict[str, set[str]] = {}
        derived: dict[str, set[str]] = {}
        for title_id, name in names.items():
            if not name:
                continue
            exact.setdefault(normalize(name), set()).add(title_id)
            for short in derived_names(name):
                derived.setdefault(normalize(short), set()).add(title_id)
        for source in (KNOWN_ALIASES, extra or {}):
            for title_id, aliases in source.items():
                if title_id not in names and source is KNOWN_ALIASES:
                    continue
                for alias in aliases:
                    if alias.strip():
                        exact.setdefault(normalize(alias), set()).add(title_id.upper())
        self.table: dict[str, set[str]] = {}
        for alias, ids in derived.items():
            if alias not in exact and len(ids) == 1:
                self.table[alias] = ids
        self.table.update(exact)
        alternatives = sorted(self.table, key=len, reverse=True)
        self.pattern = (
            re.compile(r"(?<![a-z0-9])(?:" + "|".join(re.escape(a) for a in alternatives) + r")(?![a-z0-9])")
            if alternatives
            else None
        )

    def named(self, message: str) -> set[str]:
        text = normalize(message)
        found: set[str] = set()
        if self.pattern is not None:
            for match in self.pattern.finditer(text):
                found |= self.table[match.group(0)]
        found |= {i.upper() for i in titles.BARE.findall(message)}
        return found


# ---- Paths ---------------------------------------------------------------------

_DOC_NAMES = re.compile(r"^(readme|license|licence|notice|authors|changelog|contributing|agents|security)(\.[a-z]+)?$", re.IGNORECASE)
_TEST_PARTS = {"tests", "test", "fuzz", "testdata"}


def classify(path: str) -> tuple[str, str | None]:
    """("profile", title ID) | ("shared", None) | ("none", None) for a changed path."""
    parts = path.split("/")
    name = parts[-1]
    if parts[0] in (".github", "docs") or name.lower().endswith((".md", ".markdown", ".txt.md")) or _DOC_NAMES.match(name):
        return "none", None
    if any(part.lower() in _TEST_PARTS for part in parts[:-1]) or re.match(r"^test_.*\.py$", name):
        return "none", None
    if parts[0] in (".gitignore", ".gitattributes", ".editorconfig", ".pre-commit-config.yaml"):
        return "none", None
    if len(parts) >= 3 and parts[0] == "dm" and parts[1] == "games" and titles.is_title_id(parts[2]):
        return "profile", parts[2].upper()
    return "shared", None


@dataclass
class Impact:
    """What the commits since a game's build did to it."""

    profile: list[Commit] = field(default_factory=list)  # changed its profile
    named: list[Commit] = field(default_factory=list)  # named it and changed shared code
    shared: list[Commit] = field(default_factory=list)  # changed shared code without naming it
    chain: list[Commit] = field(default_factory=list)  # moved the shader chain (shaders rebuilt)
    notes: list[tuple[str, str, str]] = field(default_factory=list)  # (commit, kind, text) Front-ends lines

    @property
    def touched(self) -> bool:
        return bool(self.profile or self.named)

    @property
    def changed(self) -> bool:
        return bool(self.profile or self.named or self.shared)

    def touching(self) -> list[Commit]:
        seen = {c.sha for c in self.profile}
        return self.profile + [c for c in self.named if c.sha not in seen]


def analyze(commits: list[Commit], title_ids: list[str], matcher: Matcher) -> dict[str, Impact]:
    """The impact of COMMITS on each game of TITLE_IDS."""
    impacts = {title_id: Impact() for title_id in title_ids}
    for commit in commits:
        profiles: set[str] = set()
        shared = False
        for path in commit.files:
            kind, title_id = classify(path)
            if kind == "profile":
                profiles.add(title_id)
            elif kind == "shared":
                shared = True
        named = matcher.named(commit.message) if shared else set()
        notes = commit.front_end_notes()
        chain = shared and commit.changes_chain
        for title_id, impact in impacts.items():
            if title_id in profiles:
                impact.profile.append(commit)
            elif shared and title_id in named:
                impact.named.append(commit)
            elif shared:
                impact.shared.append(commit)
            if chain:
                impact.chain.append(commit)
            impact.notes.extend((commit.short, kind, text) for kind, text in notes)
    return impacts
