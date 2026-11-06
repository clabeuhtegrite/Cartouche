#!/bin/bash
# Builds the launcher's gallery and saves a screenshot of each scenario of
# launcher/Gallery/scenarios.json into OUT. Needs a Mac with Xcode and
# XcodeGen (brew install xcodegen).
#
#     launcher/Gallery/capture.sh OUT
#
# A scenario with a size fits on the screen of the largest iPad simulator,
# upright: the gallery draws it in the top left corner, at its size in
# points, and screenshot.swift cuts it out. A scenario with a device runs on
# a simulator of that device, such as the iPhone Duo, which takes the newest
# iOS runtime made for it, and fills its screen; a sideways one turns the
# gallery itself, as a game does, and the screenshot is turned with it.
#
# simctl opens the gallery on each scenario and takes the screen once the
# gallery says it has settled (tmp/ready-<scenario>.json in its container).
# No XCTest: its UI test, which did this before, failed now and then to
# close the gallery between two scenarios ("Failed to terminate").
#
# A scenario that fails is named, with the screen as it was
# (failed-<scenario>.png in OUT), the others go on, and the script fails at
# the end. For each device simulator, <device>-notes.txt in OUT says what
# its displays are and how each screen came out.

set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 OUT" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
mkdir -p "$1"
OUT="$(cd "$1" && pwd)"
BUILD="$HERE/Build"

# The catalogue the launcher reads, as package.sh copies it into the app.
rm -rf "$BUILD"
mkdir -p "$BUILD/CartoucheCatalog/games" "$BUILD/raw"
cp "$ROOT/catalog/devices.json" "$ROOT/catalog/nxnative.json" "$BUILD/CartoucheCatalog/"
cp "$ROOT"/catalog/games/*.json "$BUILD/CartoucheCatalog/games/"

(cd "$HERE" && xcodegen generate --quiet)

# The tool that cuts a screen out of a screenshot, for this Mac.
xcrun --sdk macosx swiftc -O "$HERE/screenshot.swift" -o "$BUILD/screenshot"

python3 -u - "$HERE" "$OUT" "$BUILD" <<'PY'
import json, re, subprocess, sys, time
from pathlib import Path

HERE, OUT, BUILD = (Path(path) for path in sys.argv[1:4])
BUNDLE = "io.github.clabeuhtegrite.cartouche.gallery"
APP = BUILD / "DerivedData/Build/Products/Debug-iphonesimulator/CartoucheGallery.app"
document = json.loads((HERE / "scenarios.json").read_text())
failures = []


class Failure(Exception):
    pass


def run(*args, timeout=300):
    """Runs a command and returns what it printed."""
    try:
        result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise Failure(f"{' '.join(args[:4])}: no answer in {timeout} s")
    if result.returncode != 0:
        said = " ".join((result.stderr.strip() or result.stdout.strip()).split())
        raise Failure(f"{' '.join(args[:4])}: exit {result.returncode}: {said}")
    return result.stdout


def maybe(*args, timeout=60):
    """Runs a command that may fail: what it printed, or why it failed."""
    try:
        return run(*args, timeout=timeout)
    except Failure as error:
        return str(error)


def listing(*args):
    return json.loads(run("xcrun", "simctl", "list", "-j", *args))


def version(identifier):
    # com.apple.CoreSimulator.SimRuntime.iOS-27-2, or iOS-27-2-iPhone19-4 for
    # a runtime made for one device, which comes after the plain one.
    numbers = re.findall(r"iOS-(\d+)-(\d+)", identifier)
    return (tuple(int(n) for n in numbers[0]) if numbers else (0, 0), len(identifier))


def simulator(wanted):
    """The simulator for WANTED ("" for the iPad that draws the sized
    scenarios): (udid, name, runtime), created if none exists."""
    devices = [(runtime, d) for runtime, found in listing("devices", "available")["devices"].items()
               if ".iOS-" in runtime for d in found]
    if not wanted:
        for prefix in ("iPad Pro 13", "iPad Pro", "iPad Air 13", "iPad"):
            ipads = sorted((d for d in devices if d[1]["name"].startswith(prefix)), key=lambda d: version(d[0]))
            if ipads:
                runtime, device = ipads[-1]
                return device["udid"], device["name"], runtime
        raise Failure("no iPad simulator")

    # A runtime made for one device can bring its own device type of the
    # same name: every type of that name counts.
    kinds = {t["identifier"] for t in listing("devicetypes")["devicetypes"] if t["name"] == wanted}
    if not kinds:
        raise Failure(f"no simulator device type named {wanted!r}")
    runtimes = []
    for r in listing("runtimes")["runtimes"]:
        if not r.get("isAvailable", True) or r.get("platform", "iOS") != "iOS":
            continue
        runs = [t.get("identifier") for t in r.get("supportedDeviceTypes", [])
                if t.get("identifier") in kinds or t.get("name") == wanted]
        if runs:
            runtimes.append((r, runs[0]))
            print(f"   {r['identifier']}: iOS {r.get('version', '?')} ({r.get('buildversion', '?')}) runs {runs[0]}")
    if not runtimes:
        raise Failure(f"no iOS runtime runs {wanted!r}")

    def release(runtime):
        try:
            return tuple(int(n) for n in runtime.get("version", "").split("."))
        except ValueError:
            return version(runtime["identifier"])[0]

    newest, kind = max(runtimes, key=lambda found: (release(found[0]), len(found[0]["identifier"])))
    runtime = newest["identifier"]
    for found_runtime, device in devices:
        if found_runtime == runtime and device.get("deviceTypeIdentifier") == kind:
            return device["udid"], device["name"], runtime
    name = "Cartouche " + wanted
    return run("xcrun", "simctl", "create", name, kind, runtime).strip(), name, runtime


def arguments(scenario):
    """The gallery's launch arguments (Sources/GalleryApp.swift)."""
    language = document["language"]
    args = ["-AppleLanguages", f"({language})", "-AppleLocale", "fr_FR" if language == "fr" else "en_US",
            "-GalleryScreen", scenario["screen"],
            "-GallerySetup", "1" if scenario["setup"] else "0",
            "-GalleryController", "1" if scenario["controller"] else "0",
            "-GalleryReady", scenario["name"]]
    if scenario["owned"]:
        args += ["-GalleryOwned", ",".join(scenario["owned"])]
    if "device" not in scenario:
        args += ["-GalleryWidth", str(scenario["width"]), "-GalleryHeight", str(scenario["height"]),
                 "-GalleryInsets", ",".join(str(n) for n in scenario.get("insets", [0, 0, 0, 0]))]
    if scenario.get("orientation") == "landscape":
        args += ["-GalleryOrientation", "landscape"]
    if scenario.get("sheet"):
        args += ["-GallerySheet", scenario["sheet"]]
    if scenario.get("work"):
        args += ["-GalleryWork", scenario["work"]]
    return args


def capture(udid, scenario):
    """Opens the gallery on SCENARIO, waits for it to settle and saves its
    screen; returns what the gallery said about it."""
    name = scenario["name"]
    run("xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE, *arguments(scenario))
    container = Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data").strip())
    ready = container / "tmp" / f"ready-{name}.json"
    deadline = time.monotonic() + 90
    while not ready.exists():
        if time.monotonic() > deadline:
            raise Failure("the gallery did not say in 90 s that its screen had settled")
        time.sleep(0.5)
    raw = BUILD / "raw" / f"{name}.png"
    run("xcrun", "simctl", "io", udid, "screenshot", "--type=png", str(raw))
    size = [] if "device" in scenario else [str(scenario["width"]), str(scenario["height"])]
    run(str(BUILD / "screenshot"), str(raw), str(ready), str(OUT / f"{name}.png"), *size)
    said = json.loads(ready.read_text())
    if scenario.get("orientation") == "landscape" and not said.get("orientation", "").startswith("landscape"):
        raise Failure(f"the gallery stayed upright: {said}")
    return said


def crash_reports(since):
    """The first lines of the gallery's crash reports since SINCE."""
    reports = Path.home() / "Library/Logs/DiagnosticReports"
    try:
        found = sorted((p for p in reports.glob("CartoucheGallery*") if p.stat().st_mtime >= since),
                       key=lambda p: p.stat().st_mtime) if reports.is_dir() else []
        for report in found[-2:]:
            print(f"   == {report.name}")
            print("\n".join("   " + line for line in report.read_text(errors="replace").splitlines()[:40]))
    except OSError as error:
        print(f"   no crash report: {error}")


built = None
for device in sorted({s.get("device", "") for s in document["scenarios"]}):
    scenarios = [s for s in document["scenarios"] if s.get("device", "") == device]
    try:
        udid, name, runtime = simulator(device)
    except Failure as error:
        failures.append(f"{device}: {error}")
        continue
    print(f"== {device or 'sized scenarios'}: {name}, {runtime} ({udid})", flush=True)
    maybe("xcrun", "simctl", "boot", udid)
    if built is None:
        # Built once, for the simulators of this Mac.
        built = subprocess.run(["xcodebuild", "build", "-quiet", "-project", str(HERE / "CartoucheGallery.xcodeproj"),
                                "-scheme", "CartoucheGallery", "-destination", f"platform=iOS Simulator,id={udid}",
                                "-derivedDataPath", str(BUILD / "DerivedData")]).returncode == 0
    if not built:
        failures.append("the gallery does not build")
        break
    try:
        run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=900)
        run("xcrun", "simctl", "install", udid, str(APP))
    except Failure as error:
        failures.append(f"{name}: {error}")
        continue
    # The same time in every screenshot.
    maybe("xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41")

    notes = [f"{name}, {runtime}", "", "Its displays (simctl io enumerate):",
             maybe("xcrun", "simctl", "io", udid, "enumerate").rstrip(), ""]
    for scenario in scenarios:
        started = time.time()
        try:
            said = capture(udid, scenario)
            print(f"   {scenario['name']}: {said}", flush=True)
            notes.append(f"{scenario['name']}: {said}")
        except Failure as error:
            failures.append(f"{scenario['name']} on {name}: {error}")
            print(f"::error::{scenario['name']} on {name}: {error}", flush=True)
            maybe("xcrun", "simctl", "io", udid, "screenshot", "--type=png",
                  str(OUT / f"failed-{scenario['name']}.png"))
            crash_reports(started)
    if device:
        slug = device.lower().replace(" ", "-")
        (OUT / f"{slug}-notes.txt").write_text("\n".join(notes) + "\n")
    maybe("xcrun", "simctl", "terminate", udid, BUNDLE)
    maybe("xcrun", "simctl", "shutdown", udid, timeout=300)

missing = [s["name"] for s in document["scenarios"] if not (OUT / f"{s['name']}.png").exists()]
print(f"== {len(document['scenarios']) - len(missing)} of {len(document['scenarios'])} screens in {OUT}")
for failure in failures:
    print(f"::error::{failure}")
if missing:
    print("::error::no screen for " + ", ".join(missing))
sys.exit(1 if failures or missing else 0)
PY
