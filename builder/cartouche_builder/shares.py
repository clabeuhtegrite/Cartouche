"""Network shares the player's folders are on, connected again for a batch.

A games folder on a NAS is often not mounted at night. While a folder is
there, the builder notes the SMB share it is on (from `mount`); when it is
missing before a batch, it asks macOS to mount that share again, which uses
the password the player saved in the keychain and asks nothing.
"""

from __future__ import annotations

import re
import subprocess
import sys
import time
from pathlib import Path

# "//ad@nas.local/Games on /Volumes/Games (smbfs, nodev, nosuid, mounted by ad)"
MOUNT_LINE = re.compile(r"^//(?:(?P<user>[^@/]+)@)?(?P<host>[^/]+)/(?P<share>.+?) on (?P<point>/.+?) \(smbfs\b")


def mounts(text: str | None = None) -> dict[str, str]:
    """Mount point -> smb:// address of each SMB share mounted now."""
    if text is None:
        if sys.platform != "darwin":
            return {}
        try:
            text = subprocess.run(["mount"], capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            return {}
    found = {}
    for line in text.splitlines():
        match = MOUNT_LINE.match(line.strip())
        if match:
            user = f"{match.group('user')}@" if match.group("user") else ""
            found[match.group("point")] = f"smb://{user}{match.group('host')}/{match.group('share')}"
    return found


def share_of(path: Path, mounted: dict[str, str]) -> tuple[str, str] | None:
    """(mount point, address) of the share PATH is on."""
    text = str(path)
    for point in sorted(mounted, key=len, reverse=True):
        if text == point or text.startswith(point.rstrip("/") + "/"):
            return point, mounted[point]
    return None


def remember(paths: list[Path], known: dict[str, str], mounted: dict[str, str] | None = None) -> dict[str, str]:
    """KNOWN with the shares of PATHS that are mounted now."""
    mounted = mounts() if mounted is None else mounted
    updated = dict(known)
    for path in paths:
        found = share_of(path, mounted)
        if found:
            updated[found[0]] = found[1]
    return updated


def reconnect(paths: list[Path], known: dict[str, str], wait: float = 60.0, log=None) -> None:
    """Mounts again the known shares of the PATHS that are missing."""
    if sys.platform != "darwin":
        return
    for path in paths:
        if path.exists():
            continue
        for point, address in sorted(known.items(), key=lambda item: len(item[0]), reverse=True):
            if str(path) == point or str(path).startswith(point.rstrip("/") + "/"):
                if log:
                    log(address)
                script = f'mount volume "{address.replace(chr(34), "")}"'
                try:
                    subprocess.run(["osascript", "-e", script], capture_output=True, timeout=wait)
                except (OSError, subprocess.SubprocessError):
                    pass
                deadline = time.monotonic() + wait
                while not path.exists() and time.monotonic() < deadline:
                    time.sleep(1)
                break
