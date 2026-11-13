#!/bin/bash
# Builds the launcher's gallery with its UI tests (launcher/Gallery/UITests)
# and runs them on an iPhone simulator, keeping their results in OUT. Needs a
# Mac with Xcode and XcodeGen (brew install xcodegen).
#
#     launcher/Gallery/uitests.sh [--ipad] OUT
#
# --ipad runs the iPad's tests alone (UITests/IPadUITests.swift), which the
# iPhone leaves out, on a 13-inch iPad Pro (M5), else the newest iPad, of
# the newest iOS runtime that has one: the console and a game's sheet side
# by side, as an iPad shows them.
#
# The tests open the gallery on the whole console, as Cartouche shows it,
# and drive it as a player would (UITests/ConsoleTestCase.swift). They run on
# an iPhone 17 Pro, else the newest iPhone Pro, of the newest iOS runtime
# that has one, created should no simulator of it exist. simctl opens the
# gallery once first, with time: its first launch after the install can take
# minutes. The import's tests pick an IPA in On My iPhone, which this script
# puts there. A test that fails runs once more before it counts as failed,
# and so do the tests when the test runner stops before the first one; a
# test has ten minutes, which a test that runs out of them does not get
# again. OUT keeps the results (UITests.xcresult), with the screen and the
# accessibility tree of each test that failed, and where the gallery's main
# thread was in each wait of a second or more of this run
# (gallery-main-thread.txt, GalleryWatch in Sources/GalleryTesting.swift).
# The log ends with what matters most, as a tool that reads a job's log on
# GitHub may get only its last few thousand lines: the main thread's waits
# test by test, where it was in those that counted a second or more, the
# longest first, the minutes XCTest waited for the gallery's animations to
# end, what the gallery's Documents and On My iPhone held, then each test
# that failed with what it found on the screen, each test's result, and the
# summary.

set -euo pipefail

DEVICE=iPhone
if [ "${1:-}" = "--ipad" ]; then
  DEVICE=iPad
  shift
fi
[ $# -eq 1 ] || { echo "usage: $0 [--ipad] OUT" >&2; exit 2; }
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
UDID="$(UITESTS_DEVICE="$DEVICE" python3 -u - <<'PY' | tail -n 1
import json, os, re, subprocess, sys


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
if os.environ.get("UITESTS_DEVICE") == "iPad":
    # The newest iPads come last in simctl's list.
    ipads = [k for k in kinds if k.get("productFamily") == "iPad"]
    wanted = [k for k in ipads if k["name"] == "iPad Pro 13-inch (M5)"] + ipads[::-1]
    name = "Cartouche UI tests iPad"
else:
    wanted = [k for k in kinds if k["name"] == "iPhone 17 Pro"] + sorted(
        (k for k in kinds if pro(k["name"]) and k["name"] != "iPhone 17 Pro"), key=lambda k: -pro(k["name"]))
    name = "Cartouche UI tests"
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
        print(simctl("create", name, kind["identifier"], runtime["identifier"]).strip())
        sys.exit(0)
sys.exit("no iOS runtime runs an iPad simulator" if os.environ.get("UITESTS_DEVICE") == "iPad"
         else "no iOS runtime runs an iPhone Pro simulator")
PY
)"
echo "== UI tests on the $DEVICE simulator $UDID"
# The iPad's tests on the iPad alone.
if [ "$DEVICE" = iPad ]; then
  TESTS=(-only-testing:CartoucheGalleryUITests/IPadUITests)
else
  TESTS=(-skip-testing:CartoucheGalleryUITests/IPadUITests)
fi

# It boots while the gallery builds.
xcrun simctl boot "$UDID" 2>/dev/null || true
xcodebuild build-for-testing -quiet -project "$PROJECT" -scheme CartoucheGallery \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$BUILD/DerivedData"
echo "   built in $((SECONDS - started)) s"
xcrun simctl bootstatus "$UDID" -b >/dev/null
echo "   booted $((SECONDS - started)) s after the start"

# The Files app sets up the simulator's local storage, what On My iPhone
# shows, as it first opens: while the gallery installs, well before the
# tests, which pick an IPA there.
xcrun simctl launch "$UDID" com.apple.DocumentsApp >/dev/null 2>&1 || true

# The first launch after the install, which can take minutes, before the
# tests: until the console says it has settled (GalleryApp.swift, Ready).
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" com.apple.DocumentsApp 2>/dev/null || true
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

# An IPA in On My iPhone, where a player keeps one, for the import's tests
# to pick (UITests/ConsoleTestCase.swift, FilesPicker): in the folder of the
# simulator's local storage.
LOCAL=""
if [ "$DEVICE" = iPhone ]; then
  for meta in "$HOME/Library/Developer/CoreSimulator/Devices/$UDID"/data/Containers/Shared/AppGroup/*/.com.apple.mobile_container_manager.metadata.plist; do
    [ -f "$meta" ] || continue
    if [ "$(plutil -extract MCMMetadataIdentifier raw -o - "$meta" 2>/dev/null)" = "group.com.apple.FileProvider.LocalStorage" ]; then
      LOCAL="$(dirname "$meta")/File Provider Storage"
    fi
  done
fi
if [ -n "$LOCAL" ]; then
  mkdir -p "$LOCAL"
  # An empty zip archive: the gallery's install reads none of it.
  { printf 'PK\005\006'; head -c 18 /dev/zero; } >"$LOCAL/Test Game.ipa"
  echo "   Test Game.ipa in On My iPhone"
elif [ "$DEVICE" = iPhone ]; then
  echo "::warning::the simulator has no local storage for On My iPhone: the IPA to pick is in the gallery's folder alone"
fi

# The main thread's waits of this run alone: on a Mac whose simulator stays
# from a run to the next, as Ad's, the gallery's container keeps those of
# the runs before, which pushed this run's out of the log.
rm -f "$CONTAINER/tmp/gallery-main-thread.txt"

# Ten minutes for a test, fifteen at most: a test that runs out of them is
# not run again. On Ad's Mac, where a query of the screen can take 3 to 5 s,
# tests that passed took up to 284 s, and one that XCTest held three times
# 60 s waiting for the gallery's animations to end ran out of five minutes
# (13 November).
run_tests() {
  rm -rf "$OUT/UITests.xcresult"
  xcodebuild test-without-building -project "$PROJECT" -scheme CartoucheGallery \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$BUILD/DerivedData" \
    -resultBundlePath "$OUT/UITests.xcresult" "${TESTS[@]}" \
    -retry-tests-on-failure -test-iterations 2 \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 600 -maximum-test-execution-time-allowance 900 \
    -parallel-testing-enabled NO -collect-test-diagnostics never 2>&1 | tee "$OUT/xcodebuild.log"
}
status=0
run_tests || status=$?
# A test runner that stopped before the first test, as on a Mac too busy
# for the simulator to answer it, has tested nothing: once more.
if [ "$status" -ne 0 ] && grep -q "crashed while preparing to run tests\|never began executing tests" "$OUT/xcodebuild.log"; then
  echo "::warning::the test runner stopped before the first test: once more"
  status=0
  run_tests || status=$?
fi

echo "== UI tests: $((SECONDS - started)) s in all"
# The tests installed the gallery again, in a container of its own.
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null || true)"
WAITS="$CONTAINER/tmp/gallery-main-thread.txt"
if [ -n "$CONTAINER" ] && [ -f "$WAITS" ]; then
  cp "$WAITS" "$OUT/"
  # Each wait is a paragraph: its first line, then where the main thread
  # was; each start of the gallery is one too, with the test's name
  # (-GalleryTestName). Swift's names, demangled.
  demangle() {
    if xcrun --find swift-demangle >/dev/null 2>&1; then xcrun swift-demangle --simplified; else cat; fi
  }
  echo "== The main thread's waits of a second or more, test by test"
  awk 'BEGIN { RS = ""; FS = "\n" }
    /^== The gallery started/ {
      if (match($1, /-GalleryTestName [^ ]+/)) print "== " substr($1, RSTART + 17, RLENGTH - 17); else print $1
      next
    }
    { print "  " $1 }' "$WAITS" | head -n 600 || true
  # Where it was: in the waits that counted two seconds or more first,
  # which fail their test, then in those that counted a second or more,
  # the longest first; then in those the tests' accessibility held ten
  # seconds or more, which count for nothing but can make a test run out
  # of time. Each is cut at its first lines.
  echo "== Where the main thread was in the waits that counted a second or more, the longest first"
  awk 'BEGIN { RS = ""; FS = "\n" }
    /^== The gallery started/ {
      test = $1
      if (match($1, /-GalleryTestName [^ ]+/)) test = "== " substr($1, RSTART + 17, RLENGTH - 17)
      next
    }
    {
      counted = 0; tests = 0
      if (match($1, /[0-9]+ ms counted/)) counted = substr($1, RSTART, RLENGTH) + 0
      if (match($1, /[0-9]+ ms for the tests/)) tests = substr($1, RSTART, RLENGTH) + 0
      if (counted >= 1000) most = 160; else if (tests >= 10000) most = 40; else next
      text = test
      for (i = 1; i <= NF && i <= most; i++) text = text "\037" $i
      if (NF > most) text = text "\037  … " (NF - most) " lines more in gallery-main-thread.txt"
      print counted "\t" text "\037"
    }' "$WAITS" | sort -t "$(printf '\t')" -k1,1nr | cut -f2- | tr '\037' '\n' | demangle | head -n 1800 || true
fi
# Before each tap or text it types, XCTest waits for the gallery to be idle,
# its animations ended: 60 s at most, after which it says so and goes on.
# Minutes a test loses without failing, until it runs out of time.
echo "== XCTest's waits of 60 s for the gallery's animations to end, test by test"
awk '
  match($0, /^Test Case .-\[[^]]+\]. started/) { test = substr($0, RSTART + 11, RLENGTH - 20); next }
  /App animations complete notification not received/ {
    at = $0; sub(/^ *t = */, "", at); sub(/s .*/, "", at)
    waits[test] = waits[test] sprintf(", from %.1f s", at - 60); count[test]++; found = 1
  }
  END {
    for (test in count) print "  " test ": " count[test] " times" waits[test]
    if (!found) print "  none"
  }' "$OUT/xcodebuild.log" | sed -E 's/CartoucheGalleryUITests\.//' || true
if [ "$status" -ne 0 ]; then
  # What the Files picker had to show.
  echo "== The gallery's Documents"
  (cd "$CONTAINER/Documents" && find . -maxdepth 3 | sort) || true
  if [ -n "$LOCAL" ]; then
    echo "== On My iPhone"
    ls -la "$LOCAL" || true
  fi
  # Each failure, with the screen's accessibility tree as the test found
  # it (ConsoleTestCase.expect), the first lines of each.
  echo "== What the tests that failed found"
  awk '
    / error: / || tolower($0) ~ /^test case .* failed/ { tree = 0; print; next }
    /^== .*The accessibility tree:$/ { tree = 1; lines = 0; print; next }
    tree && (tolower($0) ~ /^test case / || /^ *t = /) { tree = 0 }
    tree { if (lines < 400) print; else if (lines == 400) print "    … the rest of the tree in launcher-ui-tests"; lines++ }
  ' "$OUT/xcodebuild.log" | head -n 1800 || true
fi
# Each test's result, and what the main thread's watch said at its end.
echo "== Each test"
grep -iE "^Test Case '.*' (passed|failed|skipped|exceeded)|^== .*: Main thread: " "$OUT/xcodebuild.log" \
  | sed -E "s/^Test Case '-\[CartoucheGalleryUITests\.//; s/\]'//; s/(exceeded execution time allowance of [0-9]+ minutes)\..*/\1/" || true
echo "== The summary"
xcrun xcresulttool get test-results summary --path "$OUT/UITests.xcresult" 2>/dev/null || true
echo
xcrun simctl shutdown "$UDID" 2>/dev/null || true
if [ "$status" -ne 0 ]; then
  echo "::error::UI tests failed on the $DEVICE: the end of the log shows each failed test and what it found on the screen; launcher-ui-tests keeps the results"
fi
exit "$status"
