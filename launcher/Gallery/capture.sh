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

types = [t for t in simctl("devicetypes")["devicetypes"] if t["name"] == wanted]
if not types:
    sys.exit(f"no simulator device type named {wanted!r}")
kind = types[0]["identifier"]
runtimes = [r for r in simctl("runtimes")["runtimes"]
            if r.get("isAvailable", True) and r.get("platform", "iOS") == "iOS"
            and any(t.get("identifier") == kind for t in r.get("supportedDeviceTypes", []))]
if not runtimes:
    sys.exit(f"no iOS runtime runs {wanted!r}")
runtime = max(runtimes, key=lambda r: version(r["identifier"]))["identifier"]
for found_runtime, device in devices:
    if found_runtime == runtime and device.get("deviceTypeIdentifier") == kind:
        print(device["udid"], device["name"], runtime, sep="|")
        sys.exit(0)
udid = subprocess.check_output(["xcrun", "simctl", "create", "Cartouche " + wanted, kind, runtime], text=True).strip()
print(udid, "Cartouche " + wanted, runtime, sep="|")
PY
}

DEVICES=$(python3 -c '
import json, sys
scenarios = json.load(open(sys.argv[1]))["scenarios"]
print("\n".join(sorted({s.get("device", "") for s in scenarios})))
' "$HERE/scenarios.json")

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
  TEST_RUNNER_GALLERY_OUT="$OUT" TEST_RUNNER_GALLERY_DEVICE="$DEVICE" xcodebuild test -quiet \
    -project "$HERE/CartoucheGallery.xcodeproj" -scheme CartoucheGallery \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$BUILD/DerivedData" -resultBundlePath "$RESULT"
  xcrun simctl shutdown "$UDID" 2>/dev/null || true

  # The simulator writes into OUT directly; the test's attachments are the
  # way back if it could not.
  MISSING=$(python3 -c '
import json, sys
from pathlib import Path
scenarios = json.load(open(sys.argv[1]))["scenarios"]
print(sum(1 for s in scenarios if s.get("device", "") == sys.argv[2] and not (Path(sys.argv[3]) / (s["name"] + ".png")).exists()))
' "$HERE/scenarios.json" "$DEVICE" "$OUT")
  if [ "$MISSING" -gt 0 ]; then
    echo "== no screen in $OUT: taking them from the test's attachments"
    xcrun xcresulttool export attachments --path "$RESULT" --output-path "$BUILD/Attachments-$SLUG"
    python3 - "$BUILD/Attachments-$SLUG" "$OUT" <<'PY'
import json, shutil, sys
from pathlib import Path

source, out = Path(sys.argv[1]), Path(sys.argv[2])
for test in json.loads((source / "manifest.json").read_text()):
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName", "").split("_")[0]
        if name:
            shutil.copy(source / attachment["exportedFileName"], out / (name.removesuffix(".png") + ".png"))
PY
  fi
done 3<<< "$DEVICES"

COUNT=$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["scenarios"]))' "$HERE/scenarios.json")
FOUND=$(find "$OUT" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')
echo "== $FOUND of $COUNT screens in $OUT"
[ "$FOUND" -eq "$COUNT" ]
