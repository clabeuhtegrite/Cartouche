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
# gallery says it has settled (tmp/ready-<scenario>.json in its container),
# on the display the gallery is on when the simulator has more than one, as
# the iPhone Duo has. No XCTest: its UI test, which did this before, failed
# now and then to close the gallery between two scenarios ("Failed to
# terminate"). The gallery is opened once on each simulator before its
# scenarios, with more time: its first launch after the install can take
# minutes.
#
# A scenario that fails is named, with the screen as it was
# (failed-<scenario>.png in OUT), the others go on, and the script fails at
# the end. When the gallery does not settle, the script prints its log and
# where its main thread was (failed-<scenario>-sample.txt in OUT). For each
# device simulator, <device>-notes.txt in OUT says what its displays are and
# how each screen came out.

set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 OUT" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
OUT="$(cd "$1" && pwd)"
BUILD="$HERE/Build"

# The catalogue the launcher reads, and the project. The build of the UI
# tests, when they ran first, stays (project.sh).
"$HERE/project.sh"
rm -rf "$BUILD/raw"
mkdir -p "$BUILD/raw"

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
    if scenario.get("model"):
        args += ["-GalleryModel", scenario["model"]]
    if "device" not in scenario:
        args += ["-GalleryWidth", str(scenario["width"]), "-GalleryHeight", str(scenario["height"]),
                 "-GalleryInsets", ",".join(str(n) for n in scenario.get("insets", [0, 0, 0, 0]))]
    if scenario.get("orientation") == "landscape":
        args += ["-GalleryOrientation", "landscape"]
    if "widthClass" in scenario:
        args += ["-GalleryWidthClass", scenario["widthClass"]]
    if scenario.get("sheet"):
        args += ["-GallerySheet", scenario["sheet"]]
    if scenario.get("work"):
        args += ["-GalleryWork", scenario["work"]]
    if scenario.get("category"):
        args += ["-GalleryCategory", scenario["category"]]
    if scenario.get("signing"):
        args += ["-GallerySigning", scenario["signing"]]
    return args


def displays(enumerated):
    """The simulator's built-in displays, from simctl io enumerate: screen ID
    -> size in pixels. simctl io screenshot needs one named when there are
    several."""
    found = {}
    for block in re.split(r"(?=Screen ID: )", enumerated)[1:]:
        kind = re.search(r"Screen Type: (\S+)", block)
        size = re.search(r"Pixel Size: \{(\d+), (\d+)\}", block)
        if kind and size and kind.group(1) == "Integrated":
            found[re.match(r"Screen ID: (\d+)", block).group(1)] = (int(size.group(1)), int(size.group(2)))
    return found


def listed_displays(said):
    """The displays simctl io screenshot lists when it cannot choose between
    several and none is named ("--display=3 LCD-1 (primary-1) 2007x2853
    --display=1 LCD (primary) 1398x2034"): screen ID -> size in pixels."""
    return {screen: (int(width), int(height))
            for screen, width, height in re.findall(r"--display=(\S+) .*?\b(\d+)x(\d+)\b", said)}


def find_displays(udid):
    """The simulator's built-in displays (displays()), and what simctl said
    of them, for the notes. simctl io enumerate can give no answer: on the
    iPhone Duo of run 42228000324, none in 60 s. When it finds fewer than two
    displays, simctl io screenshot is asked, with none named: it lists them
    when it cannot choose between several (listed_displays()). Both can stay
    silent right after the first launch, as on the iPhone Duo of run
    42260629195: capture() then learns the displays from its own screenshot."""
    enumerated = maybe("xcrun", "simctl", "io", udid, "enumerate", timeout=120)
    found = displays(enumerated)
    said = ["Its displays (simctl io enumerate):", enumerated.rstrip()]
    if len(found) < 2:
        tried = maybe("xcrun", "simctl", "io", udid, "screenshot", "--type=png", str(BUILD / "raw" / "displays.png"))
        listed = listed_displays(tried)
        if len(listed) > 1:
            found = listed
            said += ["", "Its displays (simctl io screenshot, with none named):", tried.strip()]
    return found, said


def explain(udid, pid, name):
    """Prints what the gallery was doing when it did not settle: its last log
    lines, and where its main thread was (sample, kept in OUT)."""
    log = maybe("xcrun", "simctl", "spawn", udid, "log", "show", "--last", "4m", "--style", "compact",
                "--predicate", 'process == "CartoucheGallery"', timeout=180).strip().splitlines()
    print(f"   == the gallery's log, its last {min(len(log), 80)} of {len(log)} lines")
    print("\n".join("   " + line for line in log[-80:]))
    if not pid:
        return
    sample = OUT / f"failed-{name}-sample.txt"
    said = maybe("sample", pid, "3", "-file", str(sample), timeout=120)
    if not sample.exists():
        print(f"   no sample of the gallery ({pid}): {said.strip()}")
        return
    lines = sample.read_text(errors="replace").splitlines()
    graph = next((i for i, line in enumerate(lines) if line.startswith("Call graph")), 0)
    print(f"   == where the gallery was ({sample.name}), first lines of its call graph")
    print("\n".join("   " + line for line in lines[graph:graph + 60]))


def launch(udid, scenario, name, timeout):
    """Opens the gallery on SCENARIO and waits until it says, as NAME, that
    its screen has settled; returns what it said and the file it wrote."""
    container = Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data").strip())
    ready = container / "tmp" / f"ready-{name}.json"
    ready.unlink(missing_ok=True)
    started = run("xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE,
                  *arguments(dict(scenario, name=name)))
    pid = re.search(r"(\d+)\s*$", started)
    deadline = time.monotonic() + timeout
    while not ready.exists():
        if time.monotonic() > deadline:
            explain(udid, pid.group(1) if pid else None, name)
            raise Failure(f"the gallery did not say in {timeout} s that its screen had settled")
        time.sleep(0.5)
    return json.loads(ready.read_text()), ready


def screenshot(udid, path, display=None):
    run("xcrun", "simctl", "io", udid, "screenshot", "--type=png",
        *([f"--display={display}"] if display else []), str(path))


def keep_failed_screen(udid, name, screens):
    """Saves the screen as it is, of each display, as failed-NAME.png."""
    for screen in screens if len(screens) > 1 else [None]:
        try:
            screenshot(udid, OUT / f"failed-{name}{f'-display-{screen}' if screen else ''}.png", screen)
        except Failure as error:
            print(f"   no screen: {error}")


def display_for(screens, said):
    """The display the gallery is on, by the size in pixels it says it has."""
    pixels = sorted(round(n) for n in said.get("pixels", []))
    found = [screen for screen, size in screens.items() if sorted(size) == pixels]
    if len(found) != 1:
        raise Failure(f"the gallery's screen, {said.get('pixels')} pixels, is not one of the displays {screens}")
    return found[0]


def capture(udid, scenario, screens):
    """Opens the gallery on SCENARIO, waits for it to settle and saves its
    screen; returns what the gallery said about it. SCREENS, the displays,
    takes the ones a screenshot lists when find_displays() had none."""
    name = scenario["name"]
    said, ready = launch(udid, scenario, name, 90)
    if scenario.get("orientation") == "landscape" and not said.get("orientation", "").startswith("landscape"):
        # Its log says whether iOS refused to turn it ("cannot turn sideways").
        explain(udid, None, name)
        raise Failure(f"the gallery stayed upright: {said}")
    display = None
    if len(screens) > 1:
        display = said["display"] = display_for(screens, said)
    raw = BUILD / "raw" / f"{name}.png"
    try:
        screenshot(udid, raw, display)
    except Failure as error:
        listed = listed_displays(str(error))
        if display or len(listed) < 2:
            raise
        screens.clear()
        screens.update(listed)
        display = said["display"] = display_for(screens, said)
        screenshot(udid, raw, display)
    size = [] if "device" in scenario else [str(scenario["width"]), str(scenario["height"])]
    run(str(BUILD / "screenshot"), str(raw), str(ready), str(OUT / f"{name}.png"), *size)
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
    # How long each part takes, for the run's log.
    since = time.monotonic()
    maybe("xcrun", "simctl", "boot", udid)
    if built is None:
        # Built once, for the simulators of this Mac.
        built = subprocess.run(["xcodebuild", "build", "-quiet", "-project", str(HERE / "CartoucheGallery.xcodeproj"),
                                "-scheme", "CartoucheGallery", "-destination", f"platform=iOS Simulator,id={udid}",
                                "-derivedDataPath", str(BUILD / "DerivedData")]).returncode == 0
        print(f"   gallery built in {time.monotonic() - since:.0f} s", flush=True)
    if not built:
        failures.append("the gallery does not build")
        break
    try:
        run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=900)
        print(f"   booted {time.monotonic() - since:.0f} s after asked", flush=True)
        run("xcrun", "simctl", "install", udid, str(APP))
    except Failure as error:
        failures.append(f"{name}: {error}")
        continue
    # The same time in every screenshot.
    maybe("xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41")

    # The first launch after the install takes longer: on the iPad of run
    # 42222954313 the gallery still showed its white launch screen after
    # 90 s, while every later launch settled in 8 to 24 s.
    warm = time.monotonic()
    try:
        launch(udid, scenarios[0], "warm-up", 300)
        print(f"   first launch: settled in {time.monotonic() - warm:.0f} s", flush=True)
        warmed = True
    except Failure as error:
        print(f"::warning::first launch on {name}: {error}", flush=True)
        warmed = False

    # Asked once the simulator has settled with the gallery open.
    screens, seen = find_displays(udid)
    print(f"   displays: {screens}", flush=True)
    if not warmed:
        keep_failed_screen(udid, "warm-up", screens)

    notes = [f"{name}, {runtime}", "", *seen, ""]
    shooting = time.monotonic()
    for scenario in scenarios:
        started = time.time()
        try:
            said = capture(udid, scenario, screens)
            print(f"   {scenario['name']}: {said}", flush=True)
            notes.append(f"{scenario['name']}: {said}")
        except Failure as error:
            failures.append(f"{scenario['name']} on {name}: {error}")
            print(f"::error::{scenario['name']} on {name}: {error}", flush=True)
            keep_failed_screen(udid, scenario["name"], screens)
            crash_reports(started)
    print(f"   {len(scenarios)} scenarios in {time.monotonic() - shooting:.0f} s, "
          f"{time.monotonic() - since:.0f} s on {name} in all", flush=True)
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
