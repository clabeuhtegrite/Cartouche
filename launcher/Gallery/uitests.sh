#!/bin/bash
# Builds the launcher's gallery with its UI tests (launcher/Gallery/UITests)
# and runs them on an iPhone simulator, keeping their results in OUT. Needs a
# Mac with Xcode and XcodeGen (brew install xcodegen).
#
#     launcher/Gallery/uitests.sh OUT
#
# The tests open the gallery on the whole console, as Cartouche shows it,
# and drive it as a player would (UITests/ConsoleTestCase.swift). They run on
# an iPhone 17 Pro, else the newest iPhone Pro, of the newest iOS runtime
# that has one, created should no simulator of it exist. simctl opens the
# gallery once first, with time: its first launch after the install can take
# minutes. A test that fails runs once more before it counts as failed. OUT
# keeps the results (UITests.xcresult), with the screen and the
# accessibility tree of each test that failed, which the log shows too.

set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 OUT" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
OUT="$(cd "$1" && pwd)"
BUILD="$HERE/Build"
PROJECT="$HERE/CartoucheGallery.xcodeproj"
BUNDLE="io.github.clabeuhtegrite.cartouche.gallery"
APP="$BUILD/DerivedData/Build/Products/Debug-iphonesimulator/CartoucheGallery.app"
started=$SECONDS

"$HERE/project.sh"

# The simulator: its UDID on the last line.
UDID="$(python3 -u - <<'PY' | tail -n 1
import json, re, subprocess, sys


def simctl(*args):
    return subprocess.run(["xcrun", "simctl", *args], check=True, capture_output=True, text=True).stdout


def listing(*args):
    return json.loads(simctl("list", "-j", *args))


def release(runtime):
    try:
        return tuple(int(n) for n in runtime.get("version", "").split("."))
    except ValueError:
        return (0,)


def pro(name):
    """17 for an iPhone 17 Pro; None for any other device."""
    found = re.fullmatch(r"iPhone (\d+) Pro", name)
    return int(found.group(1)) if found else None


kinds = listing("devicetypes")["devicetypes"]
wanted = [k for k in kinds if k["name"] == "iPhone 17 Pro"] + sorted(
    (k for k in kinds if pro(k["name"]) and k["name"] != "iPhone 17 Pro"), key=lambda k: -pro(k["name"]))
runtimes = sorted((r for r in listing("runtimes")["runtimes"]
                   if r.get("isAvailable", True) and r.get("platform", "iOS") == "iOS"), key=release, reverse=True)
devices = listing("devices", "available")["devices"]
for runtime in runtimes:
    runs = {k.get("identifier") for k in runtime.get("supportedDeviceTypes", [])}
    for kind in wanted:
        if kind["identifier"] not in runs:
            continue
        print(f"   {kind['name']}, iOS {runtime.get('version', '?')} ({runtime['identifier']})", file=sys.stderr)
        for device in devices.get(runtime["identifier"], []):
            if device.get("deviceTypeIdentifier") == kind["identifier"]:
                print(device["udid"])
                sys.exit(0)
        print(simctl("create", "Cartouche UI tests", kind["identifier"], runtime["identifier"]).strip())
        sys.exit(0)
sys.exit("no iOS runtime runs an iPhone Pro simulator")
PY
)"
echo "== UI tests on the simulator $UDID"

# It boots while the gallery builds.
xcrun simctl boot "$UDID" 2>/dev/null || true
xcodebuild build-for-testing -quiet -project "$PROJECT" -scheme CartoucheGallery \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$BUILD/DerivedData"
echo "   built in $((SECONDS - started)) s"
xcrun simctl bootstatus "$UDID" -b >/dev/null
echo "   booted $((SECONDS - started)) s after the start"

# The first launch after the install, which can take minutes, before the
# tests: until the console says it has settled (GalleryApp.swift, Ready).
xcrun simctl install "$UDID" "$APP"
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
READY="$CONTAINER/tmp/ready-warm-up.json"
rm -f "$READY"
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" \
  -GalleryScreen root -GallerySetup 1 -GalleryReady warm-up >/dev/null
warm=$SECONDS
while [ ! -f "$READY" ] && [ $((SECONDS - warm)) -lt 300 ]; do sleep 1; done
if [ -f "$READY" ]; then
  echo "   first launch: settled in $((SECONDS - warm)) s"
else
  echo "::warning::the gallery's first launch did not settle in 300 s"
fi
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true

rm -rf "$OUT/UITests.xcresult"
status=0
xcodebuild test-without-building -project "$PROJECT" -scheme CartoucheGallery \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$BUILD/DerivedData" \
  -resultBundlePath "$OUT/UITests.xcresult" \
  -retry-tests-on-failure -test-iterations 2 \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 300 -maximum-test-execution-time-allowance 600 \
  -parallel-testing-enabled NO -collect-test-diagnostics never || status=$?

echo "== UI tests: $((SECONDS - started)) s in all"
xcrun xcresulttool get test-results summary --path "$OUT/UITests.xcresult" 2>/dev/null || true
echo
xcrun simctl shutdown "$UDID" 2>/dev/null || true
if [ "$status" -ne 0 ]; then
  echo "::error::UI tests failed: the log above shows what each failed test found on the screen; launcher-ui-tests keeps the results"
fi
exit "$status"
