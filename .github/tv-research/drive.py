#!/usr/bin/env python3
# Research only (the TV mode's thread): runs the probe app (Probe/) in a
# booted simulator, one variant at a time, and says every 2.5 s what each
# of the simulator's displays shows: red for the TV scene the probe asked
# iOS for, blue (the probe's screen) or green (its game window) for a copy
# of the iPhone's screen, black for nothing. Everything goes to the job's
# log: the session cannot download artifacts. Removed before the pull
# request.
#
#     drive.py UDID VARIANT SECONDS [--attach-at S] [--detach-first]

import re
import struct
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

BUNDLE = "io.github.clabeuhtegrite.research.tvprobe"
HERE = Path(__file__).resolve().parent
OUT = Path("build/tv-research").resolve()
OUT.mkdir(parents=True, exist_ok=True)


def run(*args, timeout=120):
    done = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return done.returncode, (done.stdout + done.stderr).strip()


def display(udid, wanted):
    """Picks WANTED in the Simulator's External Displays menu."""
    status, said = run("osascript", str(HERE / "display.applescript"), wanted)
    print(f"   [display {wanted}] status {status}: {said}")
    # The display comes or goes in the simulator a moment later.
    for _ in range(30):
        if (wanted == "Disabled") != ("External" in screens(udid, quiet=True)):
            break
        time.sleep(1)
    screens(udid)


def screens(udid, quiet=False):
    """The simulator's displays, from simctl io enumerate: screen ID -> type."""
    status, said = run("xcrun", "simctl", "io", udid, "enumerate", timeout=60)
    found = {}
    for block in re.split(r"(?=Screen ID: )", said)[1:]:
        ident = re.match(r"Screen ID: (\S+)", block).group(1)
        kind = re.search(r"Screen Type: (\S+)", block)
        size = re.search(r"Pixel Size: \{(\d+), (\d+)\}", block)
        found[ident] = f"{kind.group(1) if kind else '?'} {size.group(1) + 'x' + size.group(2) if size else '?'}"
    if not quiet:
        print(f"   [screens] {found}")
        if not found:
            print("   [enumerate] " + said.replace("\n", "\n   [enumerate] "))
    return " ".join(found.values()) if quiet else found


def classify(r, g, b):
    if max(r, g, b) < 40:
        return "black"
    if min(r, g, b) > 215:
        return "white"
    if r > 180 and g < 120 and b < 120:
        return "red"
    if b > 180 and r < 90 and g < 180:
        return "blue"
    if g > 150 and r < 130 and b < 150:
        return "green"
    return "other"


def colours(path):
    """The colours of a BMP screenshot: its size, and the share of each."""
    data = path.read_bytes()
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bits = struct.unpack_from("<H", data, 28)[0]
    compression = struct.unpack_from("<I", data, 30)[0]
    masks = (0xFF0000, 0x00FF00, 0x0000FF)
    if bits == 32 and compression in (3, 6):
        masks = struct.unpack_from("<III", data, 54)
    step = bits // 8
    row = ((width * bits + 31) // 32) * 4

    def channel(pixel, mask):
        return (pixel & mask) >> ((mask & -mask).bit_length() - 1) if mask else 0

    counts = Counter()
    for y in range(0, abs(height), 6):
        base = offset + y * row
        for x in range(0, width, 6):
            pixel = int.from_bytes(data[base + x * step: base + x * step + step], "little")
            counts[classify(*(channel(pixel, mask) for mask in masks))] += 1
    total = sum(counts.values()) or 1
    return f"{width}x{abs(height)} " + " ".join(f"{name} {100 * n // total}%" for name, n in counts.most_common(4))


def look(udid, ids, label):
    said = []
    for ident, kind in ids.items():
        path = OUT / f"{label}-{ident}.bmp"
        path.unlink(missing_ok=True)
        status, text = run("xcrun", "simctl", "io", udid, "screenshot", "--type=bmp", f"--display={ident}", str(path),
                           timeout=60)
        if status != 0 or not path.exists():
            said.append(f"{kind.split()[0]}#{ident}: no screenshot ({text[-160:]})")
            continue
        said.append(f"{kind.split()[0]}#{ident}: {colours(path)}")
    return " | ".join(said)


def main():
    udid, variant, seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
    attach_at = None
    if "--attach-at" in sys.argv:
        attach_at = float(sys.argv[sys.argv.index("--attach-at") + 1])
    if "--detach-first" in sys.argv:
        display(udid, "Disabled")
    run("xcrun", "simctl", "terminate", udid, BUNDLE)
    log = OUT / f"{variant}-{udid[:8]}.log"
    log.unlink(missing_ok=True)
    status, said = run("xcrun", "simctl", "launch", "--terminate-running-process", f"--stdout={log}",
                       f"--stderr={log}", udid, BUNDLE, variant)
    print(f"== {variant}: launched ({status}: {said})")
    start = time.monotonic()
    ids = screens(udid)
    printed = 0
    attached = False
    while time.monotonic() - start < seconds:
        now = time.monotonic() - start
        if attach_at is not None and not attached and now >= attach_at:
            print(f"   {now:5.1f} attaching the display")
            display(udid, "1920")
            ids = screens(udid)
            attached = True
        print(f"   {now:5.1f} {look(udid, ids, variant)}")
        lines = log.read_text(errors="replace").splitlines() if log.exists() else []
        for line in lines[printed:]:
            print("   app: " + line)
        printed = len(lines)
        if any(line.endswith(" done") for line in lines):
            break
        time.sleep(2.5)
    time.sleep(1)
    lines = log.read_text(errors="replace").splitlines() if log.exists() else []
    for line in lines[printed:]:
        print("   app: " + line)
    run("xcrun", "simctl", "terminate", udid, BUNDLE)


if __name__ == "__main__":
    main()
