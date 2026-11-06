"""Spike S2, step 2: the rewrite that Cartouche runs on the iPhone.

The app (launcher/Sources/CartoucheLab.swift) copies the code modules of the
player's game, as their dump's ExeFS folder holds them (main, subsdk0, sdk...),
into a folder of its own and calls run_job() on its Python thread. The same
function runs on a Mac and in the iOS simulator in CI (python -m cartouche_s2).

run_job() finds the game by the build of its main module in nxnative's game
profiles, rewrites each module with patch_nso.py into one folder, as
scripts/build_ipa_from_nsp.py does on a Mac, and writes into its work folder:

- iphone.sha256, the SHA-256 of every file written, in the format of
  shasum -a 256;
- result.json, the game, each module with its time, and each file compared
  with the Mac's list, mac.sha256, when there is one;
- rewrite.log, what the rewriter prints;
- status.json, rewritten as the job goes, which the app reads.
"""

import codecs
import hashlib
import json
import locale
import os
import platform
import re
import shutil
import sys
import tempfile
import time
import traceback
from pathlib import Path, PurePath

from .rewriter import rewrite

# The code modules of a program, in load order: what the Mac build rewrites
# for a game that has no profile.
LOAD_ORDER = ["main"] + [f"subsdk{index}" for index in range(10)] + ["sdk"]
REFERENCE = "mac.sha256"
OWN = "iphone.sha256"
SHA256_LINE = re.compile(r"([0-9a-fA-F]{64}) [ *]?(.+)")


def build_id(path):
    """The module's build ID as nxnative's profiles write it (its first 16
    bytes, in hex), or None when the file is no NSO."""
    with open(path, "rb") as file:
        header = file.read(0x60)
    if len(header) < 0x60 or header[:4] != b"NSO0":
        return None
    return header[0x40:0x50].hex()


def module_files(folder):
    """{name: path} of the modules in a folder, named as in ExeFS (main,
    subsdk0, sdk...) or the same with .nso."""
    found = {}
    for path in sorted(Path(folder).iterdir()):
        name = path.stem if path.suffix == ".nso" else path.name
        if name in LOAD_ORDER and path.is_file() and build_id(path):
            found[name] = path
    return found


def identify(tools, folder):
    """(profile, [(name, path)]): nxnative's profile of the game whose main
    module this is (dm/games/game.py by_build), or None, and the modules to
    rewrite in load order: the profile's that the folder holds, as the Mac
    build takes them, or every module when no profile registers that build."""
    files = module_files(folder)
    if "main" not in files:
        raise ValueError(f"no main module in {folder}")
    games = Path(tools).resolve().parent / "games"
    profile = None
    if (games / "game.py").is_file():
        sys.path.insert(0, str(games))
        try:
            import game   # nxnative's dm/games/game.py

            profile = game.by_build(build_id(files["main"]))
        finally:
            sys.path.remove(str(games))
            sys.modules.pop("game", None)
    names = [name for name in profile.words("modules", "main") if name in files] if profile else \
        [name for name in LOAD_ORDER if name in files]
    return profile, [(name, files[name]) for name in names]


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def written(out):
    """[(name, SHA-256, size)] of the files in `out`, by name."""
    return [(path.name, sha256(path), path.stat().st_size) for path in sorted(Path(out).iterdir()) if path.is_file()]


def read_reference(path):
    """{file name: SHA-256} from a list in the format of shasum -a 256 or
    sha256sum ("<SHA-256>  <path>"); a path counts by its file name."""
    hashes = {}
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        match = SHA256_LINE.fullmatch(line.strip())
        if match:
            hashes[PurePath(match.group(2).strip()).name] = match.group(1).lower()
    return hashes


def compare(files, reference):
    """Each file written, with "same", "different" or "absent" from the Mac's
    list (None without a list), and the files only the Mac's list has."""
    rows = []
    for name, digest, size in files:
        theirs = reference.get(name) if reference is not None else None
        mac = None if reference is None else "same" if theirs == digest else "different" if theirs else "absent"
        rows.append({"name": name, "sha256": digest, "size": size, "mac": mac})
    mine = {name for name, _, _ in files}
    only = sorted(set(reference or {}) - mine - {REFERENCE, OWN})
    return rows, only


def _nxnative_commit(tools):
    try:
        return (Path(tools).resolve().parent / "nxnative.commit").read_text(encoding="utf-8").strip()
    except OSError:
        return None


def run_job(job):
    """Runs a job, a dict or the path of a JSON file:

    tools      nxnative's dm/tools
    modules    the folder that holds the game's modules
    reference  the Mac's list (shasum -a 256), or None
    work       where the job writes its files; None: a new temporary folder
    out        where the rewritten modules go; None: <work>/out
    env        environment variables for the job (LIBCAPSTONE_PATH on iOS)

    Returns the final status, which is also status.json."""
    if not isinstance(job, dict):
        job = json.loads(Path(job).read_text(encoding="utf-8"))
    work = Path(job.get("work") or tempfile.mkdtemp(prefix="cartouche-s2-"))
    out = Path(job.get("out") or work / "out")
    tools = Path(job["tools"]).resolve()
    work.mkdir(parents=True, exist_ok=True)
    status = {"state": "starting", "started": time.time(), "work": str(work), "out": str(out),
              "platform": f"{sys.platform} {platform.machine()}", "python": platform.python_version()}

    def publish(**changes):
        status.update(changes)
        partial = work / "status.json.partial"
        partial.write_text(json.dumps(status, indent=1), encoding="utf-8")
        os.replace(partial, work / "status.json")

    publish()
    saved_env = dict(os.environ)
    saved_streams = sys.stdout, sys.stderr
    log = open(work / "rewrite.log", "a", buffering=1, encoding="utf-8")
    sys.stdout = sys.stderr = log
    try:
        os.environ.update(job.get("env") or {})
        # nxnative's tools open their text files without naming an encoding,
        # as on a Mac, where that means UTF-8. On iOS it means ASCII unless the
        # app starts Python in UTF-8 mode (launcher/Sources/CartouchePython.swift):
        # stop here rather than on the first non-ASCII character of a module.
        encoding = locale.getpreferredencoding(False)
        if codecs.lookup(encoding).name != "utf-8":
            raise RuntimeError(f"Python writes text files in {encoding}, and nxnative's tools need UTF-8")
        import capstone   # what patch_nso.py imports first: a failure to load it shows here

        publish(capstone=capstone.__version__, nxnative=_nxnative_commit(tools))
        profile, modules = identify(tools, job["modules"])
        game = {"id": profile.id, "name": profile.get("name", "")} if profile else None
        publish(state="rewriting", game=game,
                modules=[{"name": name, "size": path.stat().st_size, "state": "waiting"} for name, path in modules])
        shutil.rmtree(out, ignore_errors=True)
        out.mkdir(parents=True)
        env = {"DM_GAME": profile.id} if profile else {}
        for index, (name, path) in enumerate(modules):
            status["modules"][index].update(state="rewriting", began=time.time())
            publish(current=name)
            print(f"== {name}: patch_nso.py {path.name}", flush=True)
            start = time.monotonic()
            restarts = rewrite(tools, path, out, name, env)
            status["modules"][index].update(state="done", seconds=round(time.monotonic() - start, 2), restarts=restarts)
            publish(current=None)

        files = written(out)
        (work / OWN).write_text("".join(f"{digest}  {name}\n" for name, digest, _ in files), encoding="utf-8")
        reference = job.get("reference")
        hashes = read_reference(reference) if reference and Path(reference).is_file() else None
        rows, only = compare(files, hashes)
        summary = {"files": len(rows)}
        if hashes is not None:
            summary.update({kind: sum(row["mac"] == kind for row in rows) for kind in ("same", "different", "absent")},
                           only_on_mac=len(only))
        result = dict(status, state="done", finished=time.time(), files=rows, only_on_mac=only, summary=summary)
        (work / "result.json").write_text(json.dumps(result, indent=1), encoding="utf-8")
        publish(state="done", finished=result["finished"], files=rows, only_on_mac=only, summary=summary)
    except BaseException as error:   # the app's thread must outlive any failure of a job
        traceback.print_exc()
        publish(state="failed", finished=time.time(), error=f"{type(error).__name__}: {error}")
    finally:
        sys.stdout, sys.stderr = saved_streams
        log.close()
        for key in [key for key in os.environ if key not in saved_env]:
            del os.environ[key]
        os.environ.update(saved_env)
    return status
