#!/bin/bash
# Builds the launcher's harness (launcher/Harness) for the iOS Simulator and
# runs its tests there: the launcher's own code on top of LiveContainer, with
# test games built as nxnative builds them (Tests/HarnessIPA.swift), never a
# real game. Needs a Mac with Xcode and XcodeGen (brew install xcodegen),
# and LiveContainer's submodule (git submodule update --init app/LiveContainer).
#
#     launcher/Harness/harness.sh [--ipad] OUT [TEST...]
#
# TEST runs only those tests, as xcodebuild's -only-testing names them:
# CartoucheHarnessTests/InstallTests, or
# CartoucheHarnessTests/InstallTests/testReplacingAGameKeepsItsData.
# --ipad runs them on an iPad, the 13-inch iPad Pro, rather than an iPhone,
# for what an iPad does of a game behind the console (Tests/IPadTests.swift).
#
# OUT receives the results (CartoucheHarness.xcresult), xcodebuild's log
# (test.log), what the app wrote to its standard error (console.txt: the
# launcher's NSLog lines among them, which never go to Xcode, see
# Sources/HarnessStandardError.swift), and failures.txt, the tests that
# failed and why, which also goes to the run's summary on GitHub.
#
# LiveContainer's files the harness builds are copied as app/scripts/
# prepare.sh leaves them in Cartouche: from the submodule, with every patch
# of app/patches/livecontainer applied in name order. brand.py renames
# nothing in them. The catalogue goes in as package.sh copies it.

set -euo pipefail

DEVICE=iPhone
if [ "${1:-}" = "--ipad" ]; then
  DEVICE=iPad
  shift
fi
[ $# -ge 1 ] || { echo "usage: $0 [--ipad] OUT [TEST...]" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
mkdir -p "$1"
OUT="$(cd "$1" && pwd)"
shift
BUILD="$HERE/Build"
LC="$ROOT/app/LiveContainer"

for tool in xcodebuild xcodegen tar patch python3; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[ -f "$LC/LiveContainerSwiftUI/Models/LCAppModel.swift" ] || {
  echo "app/LiveContainer is empty: run git submodule update --init app/LiveContainer" >&2; exit 1; }

echo "== LiveContainer's files, with Cartouche's patches"
rm -rf "$BUILD/LiveContainer" "$BUILD/CartoucheCatalog" "$BUILD/patched"
mkdir -p "$BUILD/patched"
(cd "$LC" && tar --exclude .git -cf - .) | (cd "$BUILD/patched" && tar -xf -)
for patch in "$ROOT"/app/patches/livecontainer/*.patch; do
  [ -e "$patch" ] || continue
  patch -s -N -t -p1 -d "$BUILD/patched" -i "$patch"
done
for file in \
  LiveContainerSwiftUI/Models/LCAppModel.swift \
  LiveContainerSwiftUI/Models/LCContainer.swift \
  LiveContainerSwiftUI/Utilities/unarchive.h \
  LiveContainerSwiftUI/Utilities/unarchive.m \
  LiveContainerSwiftUI/Utilities/archive.h \
  LiveContainerSwiftUI/Utilities/archive_entry.h \
  Resources/Localizable.xcstrings; do
  mkdir -p "$BUILD/LiveContainer/$(dirname "$file")"
  cp "$BUILD/patched/$file" "$BUILD/LiveContainer/$file"
done
rm -rf "$BUILD/patched"

echo "== the catalogue"
mkdir -p "$BUILD/CartoucheCatalog/games"
cp "$ROOT/catalog/devices.json" "$ROOT/catalog/nxnative.json" "$ROOT/catalog/covers.json" "$BUILD/CartoucheCatalog/"
cp "$ROOT"/catalog/games/*.json "$BUILD/CartoucheCatalog/games/"

(cd "$HERE" && xcodegen generate --quiet)

# The iPhone the tests run on: an iPhone 17 Pro with the newest iOS of this
# Xcode, created if there is none, or else the newest iPhone that iOS runs;
# with --ipad, a 13-inch iPad Pro (M5), or else the newest iPad.
UDID="$(HARNESS_DEVICE="$DEVICE" python3 - <<'PY'
import json, os, subprocess, sys

def listing(*args):
    return json.loads(subprocess.run(["xcrun", "simctl", "list", "-j", *args], check=True,
                                     capture_output=True, text=True).stdout)

def release(runtime):
    try:
        return tuple(int(n) for n in runtime.get("version", "0").split("."))
    except ValueError:
        return (0,)

runtimes = [r for r in listing("runtimes")["runtimes"]
            if r.get("isAvailable", True) and r.get("platform", "iOS") == "iOS"]
if not runtimes:
    sys.exit("no iOS runtime")
runtime = max(runtimes, key=lambda r: (release(r), -len(r["identifier"])))
family = os.environ.get("HARNESS_DEVICE", "iPhone")
preferred = {"iPhone": "iPhone 17 Pro", "iPad": "iPad Pro 13-inch (M5)"}[family]
models = [t for t in runtime.get("supportedDeviceTypes", []) if t.get("productFamily", family) == family
          and t.get("name", "").startswith(family)]
wanted = next((t for t in models if t["name"] == preferred), models[-1] if models else None)
if wanted is None:
    sys.exit(f"{runtime['identifier']} runs no {family}")
for device in listing("devices", "available")["devices"].get(runtime["identifier"], []):
    if device.get("deviceTypeIdentifier") == wanted["identifier"]:
        print(device["udid"])
        break
else:
    print(subprocess.run(["xcrun", "simctl", "create", "Cartouche Harness " + wanted["name"], wanted["identifier"],
                          runtime["identifier"]], check=True, capture_output=True, text=True).stdout.strip())
print(f"   {wanted['name']}, iOS {runtime.get('version', '?')} ({runtime.get('buildversion', '?')})", file=sys.stderr)
PY
)"

VERSION="$(sed -n 's/^CARTOUCHE_VERSION=//p' "$ROOT/app/config.env")"
ONLY=()
for test in "$@"; do
  ONLY+=("-only-testing:$test")
done

echo "== building the harness and running its tests"
rm -rf "$OUT/CartoucheHarness.xcresult"
# xcodebuild's whole log goes to test.log, its errors, the tests' results,
# what the harness says of a test that took long and what iPadOS made of the
# game's screen to the screen. Its own status is the script's.
#
# That leaves the step without a word for minutes: 5 on the iPhone and 11 on
# the iPad before its first line, in run 43578975230. The iPad's was taken
# for a stuck run and cancelled by hand, 10 minutes in (#175, run
# 43574954111, 14 November). So a line every minute says that it goes on,
# beside test.log and the filter, until xcodebuild ends, as launcher/Gallery/
# heartbeat.py says it of the gallery's builds, with what the Mac has left of
# its memory (memory_pressure) and disk: runs went on being cancelled in
# their iPad step that morning, lines or not, by no one known.
# HEARTBEAT_SECONDS sets another time, for the tests
# (launcher/Gallery/test_heartbeat.py).
heartbeat() {
  local since=$SECONDS free disk said
  while sleep "${HEARTBEAT_SECONDS:-60}" >/dev/null 2>&1 && kill -0 $$ 2>/dev/null; do
    free="$(memory_pressure 2>/dev/null | sed -n 's/^System-wide memory free percentage: \([0-9]*%\).*/\1/p')"
    disk="$(df -Pk . 2>/dev/null | awk 'NR == 2 { printf "%.1f GB", $4 * 1024 / 1e9 }')"
    said=""
    if [ -n "$free" ]; then said="memory free $free"; fi
    if [ -n "$disk" ]; then said="${said:+$said, }disk free $disk"; fi
    echo "   still building the harness and running its tests: $((SECONDS - since)) s${said:+ ($said)}"
  done
}
heartbeat 2>/dev/null &
HEARTBEAT=$!
set +e
xcodebuild test \
  -project "$HERE/CartoucheHarness.xcodeproj" \
  -scheme CartoucheHarness \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$BUILD/DerivedData" \
  -resultBundlePath "$OUT/CartoucheHarness.xcresult" \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 300 \
  ${ONLY[@]+"${ONLY[@]}"} \
  MARKETING_VERSION="$VERSION" \
  2>&1 | tee "$OUT/test.log" | grep -E --line-buffered \
    "error:|Test Case .* (passed|failed)|Executed [0-9]+ test|\*\* (BUILD|TEST) |harness: -\[[^]]+\] took |harness: iPadOS "
STATUSES=("${PIPESTATUS[@]}")
kill "$HEARTBEAT" 2>/dev/null
wait "$HEARTBEAT" 2>/dev/null
set -e
STATUS="${STATUSES[0]}"

# What the app wrote to its standard error, from its container.
rm -f "$OUT/console.txt"
DATA="$(xcrun simctl get_app_container "$UDID" io.github.clabeuhtegrite.cartouche.harness data 2>/dev/null || true)"
if [ -n "$DATA" ] && [ -f "$DATA/Library/Logs/console.txt" ]; then
  cp "$DATA/Library/Logs/console.txt" "$OUT/console.txt"
fi

# The simulator off, as uitests.sh and capture.sh leave theirs: the iPad's
# tests run next on the same Mac, which would otherwise hold this iPhone's
# simulator beside the iPad's. On 14 November runs on GitHub's Macs were
# cancelled in their iPad step, by no one known, some on a Mac slow to answer
# even once cancelled (heartbeat above).
xcrun simctl shutdown "$UDID" 2>/dev/null || true

# The tests that failed and why, from the results; when xcodebuild failed
# with no test that failed, as when the build did, its errors in the log.
python3 - "$OUT" "$STATUS" "$DEVICE" <<'PY' || true
import json, re, subprocess, sys
from pathlib import Path

out = Path(sys.argv[1])
status = int(sys.argv[2])
device = sys.argv[3]
lines = []
note = ""
try:
    tree = json.loads(subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path",
                                      str(out / "CartoucheHarness.xcresult")],
                                     check=True, capture_output=True, text=True).stdout)

    def walk(node, suite=""):
        kind = node.get("nodeType", "")
        if kind == "Test Case" and node.get("result") == "Failed":
            lines.append(f"{suite}/{node.get('name', '?')}")
            for child in node.get("children", []):
                if child.get("nodeType") == "Failure Message":
                    lines.append("    " + child.get("name", ""))
        for child in node.get("children", []):
            walk(child, node.get("name", suite) if kind == "Test Suite" else suite)

    for node in tree.get("testNodes", []):
        walk(node)
except Exception as error:
    note = f" (no results to read: {error})"
if status != 0 and not lines:
    log = (out / "test.log").read_text(errors="replace") if (out / "test.log").exists() else ""
    found = [line for line in log.splitlines() if re.search(r": error: |Test Case .* failed", line)]
    lines = [f"xcodebuild failed with status {status}{note}, from test.log:"] + list(dict.fromkeys(found))[:100]
(out / "failures.txt").write_text("\n".join(lines) + ("\n" if lines else ""))
if lines:
    print("== failed")
    print("\n".join(lines))
summary = Path(__import__("os").environ.get("GITHUB_STEP_SUMMARY", "/dev/null"))
with summary.open("a") as file:
    if lines:
        file.write(f"### Harness tests that failed on the {device}\n\n```\n" + "\n".join(lines) + "\n```\n")
    else:
        file.write(f"No harness test failed on the {device}.\n")
PY

exit "$STATUS"
