"""The builder's own checkout of nxnative, and what its history says.

nxnative has no releases: the builder follows a branch (main), moves its
checkout forward before a batch and builds every game of the batch from that
one commit. The checkout is the builder's alone (paths.py): it is never one
the player works in, so moving it forward may discard what a build left
changed in it. It is a partial clone (no file contents of old commits), which
keeps it small while the whole history of commits and changed paths stays
readable.
"""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from . import titles
from .i18n import t

CHAIN_HEADER = "dm/gfx/nvn/dmsh_chain.h"
# "chain d403eb0683df" in a message: the shader translation chain it moved to.
CHAIN_IN_MESSAGE = re.compile(r"\bchain [0-9a-f]{12}\b")
FRONT_ENDS = re.compile(r"^Front-ends:\s*(break|interface|new)\s*:\s*(.+)$", re.IGNORECASE | re.MULTILINE)
COMMIT_IN_PLIST = re.compile(r"^([0-9a-fA-F]{7,40})(\+dirty)?$")


class EngineError(Exception):
    pass


@dataclass
class Commit:
    sha: str
    time: int
    message: str
    files: list[str] = field(default_factory=list)

    @property
    def subject(self) -> str:
        return self.message.strip().splitlines()[0] if self.message.strip() else ""

    @property
    def short(self) -> str:
        return self.sha[:12]

    @property
    def changes_chain(self) -> bool:
        return CHAIN_HEADER in self.files or bool(CHAIN_IN_MESSAGE.search(self.message))

    def front_end_notes(self) -> list[tuple[str, str]]:
        """("break" | "interface" | "new", what it says) for each Front-ends: line."""
        return [(kind.lower(), text.strip()) for kind, text in FRONT_ENDS.findall(self.message)]


@dataclass
class Profile:
    title_id: str
    name: str
    ipa: str = ""  # the profile's default IPA file name


class Engine:
    def __init__(self, root: Path, url: str, branch: str):
        self.root = root
        self.url = url
        self.branch = branch

    # ---- git -------------------------------------------------------------

    def git(self, *args: str, timeout: float = 600, check: bool = True, cwd: Path | None = None) -> str:
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0", LC_ALL="C")
        try:
            done = subprocess.run(
                ["git", *args],
                cwd=cwd or self.root,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
                env=env,
            )
        except FileNotFoundError as error:
            raise EngineError(t("engine.no_git")) from error
        except subprocess.TimeoutExpired as error:
            raise EngineError(t("engine.git_timeout", command=" ".join(args[:2]))) from error
        if check and done.returncode != 0:
            message = (done.stderr.strip() or done.stdout.strip()).splitlines()
            raise EngineError(t("engine.git_failed", command=" ".join(args[:2]), error=message[-1] if message else done.returncode))
        return done.stdout

    @property
    def present(self) -> bool:
        return (self.root / ".git").exists()

    def ensure(self) -> None:
        """Clones nxnative the first time."""
        if self.present:
            return
        if self.root.exists() and any(self.root.iterdir()):
            raise EngineError(t("engine.not_a_checkout", path=self.root))
        self.root.parent.mkdir(parents=True, exist_ok=True)
        self.git("clone", "--filter=blob:none", "--branch", self.branch, self.url, str(self.root), cwd=self.root.parent, timeout=3600)

    def update(self) -> tuple[str | None, str]:
        """Moves the checkout to the newest commit of the branch: (before, after)."""
        before = self.head()
        self.ensure()
        if self.git("remote", "get-url", "origin").strip() != self.url:
            self.git("remote", "set-url", "origin", self.url)
        self.git("fetch", "--prune", "origin", f"+refs/heads/{self.branch}:refs/remotes/origin/{self.branch}", timeout=3600)
        # --force: what an earlier build left changed in tracked files (the
        # chain header it may write) does not hold the checkout back.
        self.git("checkout", "--force", "-B", self.branch, f"origin/{self.branch}", timeout=3600)
        return before, self.head()

    def head(self) -> str | None:
        if not self.present:
            return None
        out = self.git("rev-parse", "--verify", "--quiet", "HEAD^{commit}", check=False).strip()
        return out or None

    def resolve(self, commit: str) -> str | None:
        """The full SHA of COMMIT ("abc123def456", "abc123def456+dirty"), or
        None when this checkout does not have it (a fork's commit)."""
        match = COMMIT_IN_PLIST.match(commit.strip()) if commit else None
        if not match or not self.present:
            return None
        out = self.git("rev-parse", "--verify", "--quiet", f"{match.group(1)}^{{commit}}", check=False).strip()
        return out or None

    def is_ancestor(self, older: str, newer: str) -> bool:
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
        try:
            done = subprocess.run(["git", "merge-base", "--is-ancestor", older, newer], cwd=self.root, capture_output=True, env=env, timeout=120)
        except (OSError, subprocess.SubprocessError):
            return False
        return done.returncode == 0

    def commits(self, older: str, newer: str) -> list[Commit]:
        """The commits after OLDER up to NEWER, oldest first, with the paths each changes."""
        if older == newer:
            return []
        out = self.git("log", "--reverse", "--format=%x1e%H%x1f%ct%x1f%B%x1f", "--name-only", "--no-renames", f"{older}..{newer}", timeout=600)
        found = []
        for record in out.split("\x1e")[1:]:
            parts = record.split("\x1f")
            if len(parts) < 4:
                continue
            sha, when, message, files = parts[0], parts[1], parts[2], parts[3]
            found.append(Commit(sha.strip(), int(when or 0), message, [f for f in files.splitlines() if f.strip()]))
        return found

    def commit_time(self, commit: str) -> int | None:
        out = self.git("show", "-s", "--format=%ct", commit, check=False).strip()
        return int(out) if out.isdigit() else None

    # ---- Profiles --------------------------------------------------------

    def profiles(self) -> dict[str, Profile]:
        """The games nxnative has a profile for, by title ID (dm/games/<ID>/game.tsv)."""
        games = self.root / "dm" / "games"
        found: dict[str, Profile] = {}
        if not games.is_dir():
            return found
        for folder in games.iterdir():
            if not titles.is_title_id(folder.name):
                continue
            values = read_tsv(folder / "game.tsv")
            title_id = folder.name.upper()
            found[title_id] = Profile(title_id, values.get("name", ""), values.get("ipa", ""))
        return found

    @property
    def build_script(self) -> Path:
        return self.root / "scripts" / "build_ipa_from_nsp.py"

    def supports(self, option: str) -> bool:
        """Whether this checkout's build script takes OPTION ("--keep-extracted")."""
        try:
            text = self.build_script.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return False
        return f"'{option}'" in text or f'"{option}"' in text

    @property
    def requirements(self) -> Path:
        return self.root / ".github" / "requirements" / "tools.txt"



def read_tsv(path: Path) -> dict[str, str]:
    """A profile's key<TAB>value rows (the first value of each key)."""
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return values
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, _, rest = line.partition("\t")
        if key and key not in values:
            values[key.strip()] = rest.split("\t")[0].strip()
    return values
