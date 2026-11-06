#!/bin/bash
# Builds the launcher's gallery and saves a screenshot of each scenario of
# launcher/Gallery/scenarios.json into OUT. Needs a Mac with Xcode and
# XcodeGen (brew install xcodegen).
#
#     launcher/Gallery/capture.sh OUT
#
# A scenario with a size fits on the screen of the largest iPad simulator,
# upright: the gallery draws it in the top left corner, at its size in
# points. A scenario with a device runs on a simulator of that device, such
# as the iPhone Duo, which takes the newest iOS runtime made for it, and
# fills its screen.
#
# When the test fails on a simulator, the script prints what failed and the
# test's steps, each scenario's included, saves the screens taken until then,
# goes on with the next simulator and fails at the end.

set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 OUT" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
mkdir -p "$1"
OUT="$(cd "$1" && pwd)"
BUILD="$HERE/Build"

# The catalogue the launcher reads, as package.sh copies it into the app.
rm -rf "$BUILD"
mkdir -p "$BUILD/CartoucheCatalog/games"
cp "$ROOT/catalog/devices.json" "$ROOT/catalog/nxnative.json" "$BUILD/CartoucheCatalog/"
cp "$ROOT"/catalog/games/*.json "$BUILD/CartoucheCatalog/games/"

(cd "$HERE" && xcodegen generate --quiet)

# The simulator for DEVICE ("" for the iPad that draws the sized scenarios):
# prints "<udid>|<name>|<runtime>", creating the device if none exists.
simulator() {
  python3 - "$1" <<'PY'
import json, re, subprocess, sys

wanted = sys.argv[1]

def simctl(*args):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", *args]))

def version(identifier):
    # com.apple.CoreSimulator.SimRuntime.iOS-27-2, or iOS-27-2-iPhone19-4 for
    # a runtime made for one device, which comes after the plain one.
    numbers = re.findall(r"iOS-(\d+)-(\d+)", identifier)
    return (tuple(int(n) for n in numbers[0]) if numbers else (0, 0), len(identifier))

devices = [(runtime, d) for runtime, found in simctl("devices", "available")["devices"].items()
           if ".iOS-" in runtime for d in found]
if not wanted:
    for prefix in ("iPad Pro 13", "iPad Pro", "iPad Air 13", "iPad"):
        ipads = sorted((d for d in devices if d[1]["name"].startswith(prefix)), key=lambda d: version(d[0]))
        if ipads:
            runtime, device = ipads[-1]
            print(device["udid"], device["name"], runtime, sep="|")
            sys.exit(0)
    sys.exit("no iPad simulator")

# A runtime made for one device can bring its own device type of the same
# name: every type of that name counts.
kinds = {t["identifier"] for t in simctl("devicetypes")["devicetypes"] if t["name"] == wanted}
if not kinds:
    sys.exit(f"no simulator device type named {wanted!r}")
runtimes = []
for r in simctl("runtimes")["runtimes"]:
    if not r.get("isAvailable", True) or r.get("platform", "iOS") != "iOS":
        continue
    runs = [t.get("identifier") for t in r.get("supportedDeviceTypes", [])
            if t.get("identifier") in kinds or t.get("name") == wanted]
    if runs:
        runtimes.append((r, runs[0]))
        print(f"   {r['identifier']}: iOS {r.get('version', '?')} ({r.get('buildversion', '?')}) runs {runs[0]}",
              file=sys.stderr)
if not runtimes:
    sys.exit(f"no iOS runtime runs {wanted!r}")

def release(runtime):
    try:
        return tuple(int(n) for n in runtime.get("version", "").split("."))
    except ValueError:
        return version(runtime["identifier"])[0]

newest, kind = max(runtimes, key=lambda found: (release(found[0]), len(found[0]["identifier"])))
runtime = newest["identifier"]
for found_runtime, device in devices:
    if found_runtime == runtime and device.get("deviceTypeIdentifier") == kind:
        print(device["udid"], device["name"], runtime, sep="|")
        sys.exit(0)
udid = subprocess.check_output(["xcrun", "simctl", "create", "Cartouche " + wanted, kind, runtime], text=True).strip()
print(udid, "Cartouche " + wanted, runtime, sep="|")
PY
}

# What failed in the result bundle $1, then the test's steps up to there:
# each scenario is an activity of its own (Tests/GalleryScreens.swift).
failures() {
  xcrun xcresulttool get test-results summary --path "$1" > "$1.summary.json" 2>&1 || true
  xcrun xcresulttool get test-results activities --test-id "GalleryScreens/testScreens()" \
    --path "$1" > "$1.activities.json" 2>&1 || true
  python3 - "$1.summary.json" "$1.activities.json" <<'PY'
import json, sys

def load(path):
    try:
        with open(path) as file:
            return json.load(file)
    except (OSError, ValueError) as error:
        print(f"   no {path}: {error}")
        return {}

for failure in load(sys.argv[1]).get("testFailures", []):
    print(f"::error::{failure.get('testName', 'test')}: {' '.join(failure.get('failureText', '').split())}")

steps = []
def walk(activity, depth):
    failed = "   <- failed" if activity.get("isAssociatedWithFailure") else ""
    steps.append("   " + "  " * depth + " ".join(activity.get("title", "?").split()) + failed)
    for child in activity.get("childActivities", []):
        walk(child, depth + 1)

for run in load(sys.argv[2]).get("testRuns", []):
    for activity in run.get("activities", []):
        walk(activity, 0)
print("== the test's steps" + (", the last 150" if len(steps) > 150 else "") + ":")
print("\n".join(steps[-150:]))
PY
}

DEVICES=$(python3 -c '
import json, sys
scenarios = json.load(open(sys.argv[1]))["scenarios"]
print("\n".join(sorted({s.get("device", "") for s in scenarios})))
' "$HERE/scenarios.json")

# The simulators whose test failed.
FAILED=""

# fd 3, so that nothing in the loop reads the list.
while IFS= read -r DEVICE <&3; do
  FOUND_DEVICE=$(simulator "$DEVICE") || { xcrun simctl list devices available >&2; exit 1; }
  IFS='|' read -r UDID NAME RUNTIME <<< "$FOUND_DEVICE"
  echo "== ${DEVICE:-sized scenarios}: $NAME, $RUNTIME ($UDID)"
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  if [ -n "$DEVICE" ]; then
    # What this Xcode's simctl offers to put a foldable simulator in a pose.
    xcrun simctl help 2>&1 | grep -i -E 'pose|fold|postur|hinge' || echo "simctl: no subcommand about poses"
  fi

  SLUG=$(echo "${DEVICE:-ipad}" | tr 'A-Z ' 'a-z-')
  RESULT="$BUILD/Screens-$SLUG.xcresult"
  STATUS=0
  TEST_RUNNER_GALLERY_OUT="$OUT" TEST_RUNNER_GALLERY_DEVICE="$DEVICE" xcodebuild test -quiet \
    -project "$HERE/CartoucheGallery.xcodeproj" -scheme CartoucheGallery \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$BUILD/DerivedData" -resultBundlePath "$RESULT" || STATUS=$?
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
  if [ "$STATUS" -ne 0 ]; then
    FAILED="$FAILED, $NAME"
    echo "::error::the gallery's test failed on $NAME (xcodebuild exit $STATUS)"
    failures "$RESULT"
  fi

  # The simulator writes into OUT directly; the test's attachments are the
  # way back if it could not.
  MISSING=$(python3 -c '
import json, sys
from pathlib import Path
scenarios = json.load(open(sys.argv[1]))["scenarios"]
print(sum(1 for s in scenarios if s.get("device", "") == sys.argv[2] and not (Path(sys.argv[3]) / (s["name"] + ".png")).exists()))
' "$HERE/scenarios.json" "$DEVICE" "$OUT")
  if [ "$MISSING" -gt 0 ]; then
    echo "== $MISSING screens missing in $OUT: taking them from the test's attachments"
    if xcrun xcresulttool export attachments --path "$RESULT" --output-path "$BUILD/Attachments-$SLUG"; then
      python3 - "$BUILD/Attachments-$SLUG" "$OUT" "$HERE/scenarios.json" <<'PY'
import json, shutil, sys
from pathlib import Path

source, out = Path(sys.argv[1]), Path(sys.argv[2])
scenarios = {s["name"] for s in json.loads(Path(sys.argv[3]).read_text())["scenarios"]}
for test in json.loads((source / "manifest.json").read_text()):
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName", "").split("_")[0].removesuffix(".png")
        # A screenshot XCTest takes when a step fails is no scenario's.
        if name in scenarios:
            shutil.copy(source / attachment["exportedFileName"], out / (name + ".png"))
PY
    fi
  fi
done 3<<< "$DEVICES"

COUNT=$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["scenarios"]))' "$HERE/scenarios.json")
FOUND=$(find "$OUT" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')
echo "== $FOUND of $COUNT screens in $OUT"
if [ -n "$FAILED" ]; then
  echo "::error::the gallery's test failed on ${FAILED#, }"
  exit 1
fi
[ "$FOUND" -eq "$COUNT" ]
