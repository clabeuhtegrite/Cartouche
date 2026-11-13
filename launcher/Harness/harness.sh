#!/bin/bash
# Builds the launcher's harness (launcher/Harness) for the iOS Simulator and
# runs its tests there: the launcher's own code on top of LiveContainer, with
# test games built as nxnative builds them (Tests/HarnessIPA.swift), never a
# real game. Needs a Mac with Xcode and XcodeGen (brew install xcodegen),
# and LiveContainer's submodule (git submodule update --init app/LiveContainer).
#
#     launcher/Harness/harness.sh OUT [TEST...]
#
# TEST runs only those tests, as xcodebuild's -only-testing names them:
# CartoucheHarnessTests/InstallTests, or
# CartoucheHarnessTests/InstallTests/testReplacingAGameKeepsItsData.
#
# OUT receives the results (CartoucheHarness.xcresult), xcodebuild's log
# (test.log), and failures.txt, the tests that failed and why, which also
# goes to the run's summary on GitHub.
#
# LiveContainer's files the harness builds are copied as app/scripts/
# prepare.sh leaves them in Cartouche: from the submodule, with every patch
# of app/patches/livecontainer applied in name order. brand.py renames
# nothing in them. The catalogue goes in as package.sh copies it.

set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 OUT [TEST...]" >&2; exit 2; }
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
# Xcode, created if there is none, or else the newest iPhone that iOS runs.
UDID="$(python3 - <<'PY'
import json, subprocess, sys

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
iphones = [t for t in runtime.get("supportedDeviceTypes", []) if t.get("productFamily", "iPhone") == "iPhone"
           and t.get("name", "").startswith("iPhone")]
wanted = next((t for t in iphones if t["name"] == "iPhone 17 Pro"), iphones[-1] if iphones else None)
if wanted is None:
    sys.exit(f"{runtime['identifier']} runs no iPhone")
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
# xcodebuild's whole log goes to test.log, its errors, the tests' results and
# what the harness says of a test that took long to the screen. Its own
# status is the script's.
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
    "error:|Test Case .* (passed|failed)|Executed [0-9]+ test|\*\* (BUILD|TEST) |harness: -\[[^]]+\] took "
STATUSES=("${PIPESTATUS[@]}")
set -e
STATUS="${STATUSES[0]}"

# The tests that failed and why, from the results; when xcodebuild failed
# with no test that failed, as when the build did, its errors in the log.
python3 - "$OUT" "$STATUS" <<'PY' || true
import json, re, subprocess, sys
from pathlib import Path

out = Path(sys.argv[1])
status = int(sys.argv[2])
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
        file.write("### Harness tests that failed\n\n```\n" + "\n".join(lines) + "\n```\n")
    else:
        file.write("No harness test failed.\n")
PY

exit "$STATUS"
