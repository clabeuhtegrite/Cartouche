"""The tools a build needs on the Mac, checked before a batch, and the Python
environment nxnative's scripts run in, which the builder makes itself.

nxnative needs Xcode 27.2 (its Metal compiler: the one its shader chain was
locked with), Xcode's iOS platform and Metal toolchain, xcodegen, zstd and
glslang from Homebrew, git, and a native (arm64) Python 3.12 or later with the
packages of its .github/requirements/tools.txt. A checkout older than its
641636e2 (10 November 2026) also needs the .NET 10 SDK. The engine installs
none of the Apple or Homebrew tools: its checks say what is missing and the
command that fixes it, and the Mac app (mac/Sources/BuilderKit/MacSetup.swift)
installs them without a Terminal. It makes the Python environment in its own
folder.
"""

from __future__ import annotations

import hashlib
import os
import platform
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from . import causes
from .i18n import t
from .paths import Paths

EXTRA_PATH = (
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "/usr/local/share/dotnet",
    str(Path.home() / ".dotnet"),
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
)
PYTHON_CANDIDATES = (
    "/opt/homebrew/bin/python3.14",
    "/opt/homebrew/bin/python3.13",
    "/opt/homebrew/bin/python3.12",
    "/opt/homebrew/bin/python3",
    "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3",
    "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
    "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
    "/usr/local/bin/python3",
)
STAMP = ".cartouche-builder-requirements"
# The Xcode whose Metal compiler nxnative's shader chain was locked with, as
# nxnative's own_compilers.py names it (XCODE_VERSION): what a checkout says
# comes first, this before the first clone.
XCODE = "27.2"
OWN_COMPILERS = "dm/gfx/tools/own_compilers.py"
XCODE_VERSION = re.compile(r"^XCODE_VERSION\s*=\s*['\"](\d+(?:\.\d+)*)['\"]", re.MULTILINE)
# nxnative's committed nx_extract: a checkout that has it builds without .NET.
NATIVE_NX_EXTRACT = "dm/tools/nx_extract_bin/nx_extract"


@dataclass
class Check:
    key: str
    ok: bool
    found: str  # what is there
    fix: str = ""  # what to do, in the player's words
    command: str = ""  # a Terminal command that fixes it
    blocking: bool = True


def search_path(paths: Paths, extra: tuple[str, ...] = ()) -> str:
    """The PATH builds run with: the dotnet lock, the Python environment, then
    the player's own PATH and where Homebrew and .NET install (a scheduled run
    starts with almost none)."""
    parts = [str(paths.bin), str(paths.python / "bin"), *extra]
    parts += [p for p in os.environ.get("PATH", "").split(os.pathsep) if p]
    parts += list(EXTRA_PATH)
    seen: list[str] = []
    for part in parts:
        if part not in seen:
            seen.append(part)
    return os.pathsep.join(seen)


def environment(paths: Paths) -> dict[str, str]:
    env = dict(os.environ)
    env["PATH"] = search_path(paths)
    env["PYTHONUNBUFFERED"] = "1"
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    env.pop("VIRTUAL_ENV", None)
    return env


def run(command: list[str], env: dict[str, str] | None = None, timeout: float = 60) -> tuple[int, str]:
    try:
        done = subprocess.run(command, capture_output=True, text=True, errors="replace", env=env, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as error:
        return 127, str(error)
    return done.returncode, (done.stdout + done.stderr).strip()


def which(name: str, env: dict[str, str]) -> str | None:
    return shutil.which(name, path=env.get("PATH"))


# ---- Apple tools ---------------------------------------------------------------


def xcode_version(env: dict[str, str]) -> str | None:
    """"27.2 (27C55)" from xcodebuild -version."""
    code, out = run(["xcodebuild", "-version"], env)
    if code:
        return None
    version = re.search(r"Xcode\s+(\S+)", out)
    build = re.search(r"Build version\s+(\S+)", out)
    if not version:
        return None
    return version.group(1) + (f" ({build.group(1)})" if build else "")


def wanted_xcode(engine_root: Path | None) -> str:
    """The Xcode nxnative builds the shaders with ("27.2"): an NVN game's
    build stops at once with another Xcode's Metal compiler (causes.py)."""
    if engine_root:
        try:
            found = XCODE_VERSION.search((engine_root / OWN_COMPILERS).read_text(encoding="utf-8", errors="replace"))
        except OSError:
            found = None
        if found:
            return found.group(1)
    return XCODE


def ios_sdk(env: dict[str, str]) -> str | None:
    code, out = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], env)
    return out.splitlines()[-1].strip() if code == 0 and out else None


def metal_version(env: dict[str, str]) -> str | None:
    """The first line metal --version writes, as nxnative's tool_lock.py reads it."""
    try:
        done = subprocess.run(["xcrun", "-sdk", "iphoneos", "metal", "--version"], capture_output=True, text=True, errors="replace", env=env, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    lines = done.stdout.splitlines()
    return lines[0] if done.returncode == 0 and lines else None


def locked_metal(engine_root: Path) -> str | None:
    """The Metal compiler nxnative's shader chain was locked with."""
    try:
        for line in (engine_root / "dm/gfx/tools/dmsh_chain.lock").read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("\t")
            if key == "metal_iphoneos":
                return value.strip()
    except OSError:
        pass
    return None


def identity(env: dict[str, str]) -> str:
    """The Apple tools a build is made with, as recorded with it."""
    return f"Xcode {xcode_version(env) or '?'}, iOS SDK {ios_sdk(env) or '?'}"


# ---- Python ----------------------------------------------------------------------


def python_info(python: str) -> tuple[tuple[int, int], str] | None:
    code, out = run([python, "-c", "import platform, sys; print(sys.version_info[0], sys.version_info[1], platform.machine())"], timeout=30)
    if code:
        return None
    try:
        major, minor, machine = out.splitlines()[-1].split()
        return (int(major), int(minor)), machine
    except ValueError:
        return None


def translated() -> bool:
    """Whether this process runs under Rosetta."""
    if sys.platform != "darwin":
        return False
    code, out = run(["sysctl", "-n", "sysctl.proc_translated"], timeout=10)
    return code == 0 and out.strip() == "1"


def base_python() -> str | None:
    """A native Python 3.12 or later to make the environment with."""
    candidates = [sys.executable, *PYTHON_CANDIDATES]
    for candidate in candidates:
        if not candidate or not os.access(candidate, os.X_OK):
            continue
        info = python_info(candidate)
        if not info:
            continue
        version, machine = info
        if version >= (3, 12) and (sys.platform != "darwin" or machine == "arm64"):
            return candidate
    return None


def venv_python(paths: Paths) -> Path:
    return paths.python / "bin" / "python3"


def requirements_stamp(requirements: Path, python: Path) -> str:
    digest = hashlib.sha256()
    try:
        digest.update(requirements.read_bytes())
    except OSError:
        digest.update(b"no requirements")
    info = python_info(str(python))
    digest.update(repr(info).encode())
    return digest.hexdigest()[:16]


def python_ready(paths: Paths, requirements: Path) -> bool:
    python = venv_python(paths)
    if not python.exists():
        return False
    try:
        stamp = (paths.python / STAMP).read_text().strip()
    except OSError:
        return False
    return stamp == requirements_stamp(requirements, python)


def ensure_python(paths: Paths, requirements: Path, log=print) -> Path:
    """Makes (or brings up to date) the environment nxnative's scripts run in."""
    python = venv_python(paths)
    if python_ready(paths, requirements):
        return python
    if not python.exists():
        base = base_python()
        if not base:
            raise RuntimeError(t("toolchain.no_python"))
        log(t("toolchain.making_venv", python=base))
        code, out = run([base, "-m", "venv", "--clear", str(paths.python)], timeout=600)
        if code:
            raise RuntimeError(t("toolchain.venv_failed", error=out.splitlines()[-1] if out else code))
    log(t("toolchain.installing_packages"))
    pip = [str(python), "-m", "pip", "install", "--disable-pip-version-check", "--quiet"]
    code, out = run(pip + ["--upgrade", "pip"], timeout=1800)
    code, out = run(pip + ["-r", str(requirements)], timeout=3600)
    if code:
        raise RuntimeError(t("toolchain.pip_failed", error=out.splitlines()[-1] if out else code))
    info = python_info(str(python))
    if info and info[0] < (3, 14):
        code, out = run(pip + ["backports.zstd"], timeout=1800)
        if code:
            raise RuntimeError(t("toolchain.pip_failed", error=out.splitlines()[-1] if out else code))
    (paths.python / STAMP).write_text(requirements_stamp(requirements, python) + "\n")
    return python


# ---- The dotnet lock ---------------------------------------------------------------

DOTNET_WRAPPER = '''#!{python}
# Cartouche Builder: one "dotnet build" at a time. Two games built at once
# build nxnative's nx_extract in the same obj/ folder, which breaks one of them.
import fcntl, os, shutil, sys
here = os.path.dirname(os.path.abspath(__file__))
path = os.pathsep.join(p for p in os.environ.get("PATH", "").split(os.pathsep) if p and os.path.abspath(p) != here)
real = shutil.which("dotnet", path=path)
if not real:
    for candidate in ("/usr/local/share/dotnet/dotnet", "/opt/homebrew/bin/dotnet", os.path.expanduser("~/.dotnet/dotnet")):
        if os.access(candidate, os.X_OK):
            real = candidate
            break
if not real:
    sys.exit("dotnet: not found (install the .NET 10 SDK: brew install --cask dotnet-sdk)")
if sys.argv[1:2] == ["build"]:
    fd = os.open({lock!r}, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    os.set_inheritable(fd, True)
os.execv(real, [real] + sys.argv[1:])
'''


def write_dotnet_lock(paths: Paths) -> Path:
    paths.bin.mkdir(parents=True, exist_ok=True)
    paths.locks.mkdir(parents=True, exist_ok=True)
    wrapper = paths.bin / "dotnet"
    text = DOTNET_WRAPPER.format(python=sys.executable, lock=str(paths.locks / "dotnet.lock"))
    if not wrapper.exists() or wrapper.read_text() != text:
        wrapper.write_text(text)
        wrapper.chmod(0o755)
    return wrapper


# ---- The checks ------------------------------------------------------------------------


def doctor(paths: Paths, engine_root: Path | None = None) -> list[Check]:
    """Whether this Mac can build, tool by tool."""
    env = environment(paths)
    checks: list[Check] = []
    on_mac = sys.platform == "darwin"
    if on_mac:
        release = platform.mac_ver()[0] or "?"
        try:
            parts = tuple(int(p) for p in release.split(".")[:2])
        except ValueError:
            parts = (0,)
        checks.append(Check("macos", parts >= (26, 6), release, t("fix.macos")))
        checks.append(Check("rosetta", not translated(), platform.machine(), t("fix.rosetta")))
    else:
        checks.append(Check("macos", False, platform.system(), t("fix.macos")))
    checks.append(Check("git", bool(which("git", env)), which("git", env) or "", t("fix.git"), "xcode-select --install"))
    xcode = xcode_version(env)
    # An older Xcode than nxnative's has an older Metal compiler, which
    # nxnative refuses for every NVN game: Xcode is updated first, in the App
    # Store. Another compiler of a newer Xcode is checked against the lock
    # below, and stops only an NVN game's build (nxnative checks it itself).
    wanted = wanted_xcode(engine_root)
    outdated = bool(xcode) and causes.older(xcode, wanted)
    fix = t("fix.xcode_update", found=(xcode or "").split(" ")[0], wanted=wanted) if outdated else t("fix.xcode", wanted=wanted)
    checks.append(Check("xcode", bool(xcode) and not outdated, xcode or "", fix, "" if outdated else f"sudo xcode-select -s /Applications/Xcode-{wanted}.app"))
    sdk = ios_sdk(env)
    checks.append(Check("ios_sdk", bool(sdk), sdk or "", t("fix.ios_sdk"), "xcodebuild -downloadPlatform iOS"))
    metal = metal_version(env)
    locked = locked_metal(engine_root) if engine_root else None
    metal_ok = bool(metal) and (not locked or metal == locked)
    # Another compiler stops only an NVN game's build (nxnative checks it
    # itself); a missing one stops every build.
    checks.append(Check("metal", metal_ok, metal or "", t("fix.metal", locked=locked or f"Xcode {wanted}"), "xcodebuild -downloadComponent MetalToolchain", blocking=not metal))
    tools = {name: which(command, env) for name, command in (("xcodegen", "xcodegen"), ("zstd", "zstd"), ("glslang", "glslangValidator"))}
    brew = [name for name, path in tools.items() if not path]
    # What is there: the folders the tools were found in ("/opt/homebrew/bin").
    where = ", ".join(sorted({str(Path(path).parent) for path in tools.values() if path}))
    checks.append(Check("homebrew_tools", not brew, where, t("fix.homebrew", tools=" ".join(brew)), f"brew install {' '.join(brew)}" if brew else ""))
    dotnet = which("dotnet", env)
    sdks = run([dotnet, "--list-sdks"], env)[1] if dotnet else ""
    dotnet_ok = bool(re.search(r"^1\d\.", sdks, re.MULTILINE))
    if needs_dotnet(engine_root):
        checks.append(Check("dotnet", dotnet_ok, (sdks.splitlines() or [""])[-1], t("fix.dotnet"), "brew install --cask dotnet-sdk"))
    else:
        checks.append(Check("dotnet", True, (sdks.splitlines() or [""])[-1] if dotnet_ok else t("check.dotnet_unneeded"), blocking=False))
    base = base_python()
    checks.append(Check("python", bool(base), base or "", t("fix.python"), "brew install python@3.13"))
    if engine_root:
        ready = python_ready(paths, engine_root / ".github/requirements/tools.txt")
        checks.append(Check("venv", ready, str(paths.python) if ready else "", t("fix.venv"), blocking=False))
    return checks


def needs_dotnet(engine_root: Path | None) -> bool:
    """Whether this nxnative checkout builds with .NET. Since nxnative 641636e2
    (10 November 2026) nx_extract and the shader translator are committed as
    native executables, and a build runs no dotnet; an older checkout builds
    nx_extract with dotnet at every run. Before the first clone, the newest
    nxnative is what will be cloned: no .NET."""
    if engine_root is None or not (engine_root / "dm").is_dir():
        return False
    return not (engine_root / NATIVE_NX_EXTRACT).is_file()


def blocking(checks: list[Check]) -> list[Check]:
    return [c for c in checks if not c.ok and c.blocking]
