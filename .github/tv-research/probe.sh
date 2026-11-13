#!/bin/bash
# Research only: builds probe.m for the iOS Simulator and runs it there.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/out}"
mkdir -p "$OUT"
xcrun -sdk iphonesimulator clang -target arm64-apple-ios18.0-simulator -fobjc-arc \
  -framework Foundation -framework UIKit "$HERE/probe.m" -o "$OUT/probe" || exit 1
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
for runtime in sorted(d, reverse=True):
    if "iOS" not in runtime: continue
    for dev in d[runtime]:
        if dev["name"].startswith("iPhone"):
            print(dev["udid"]); sys.exit()
')
echo "simulator $UDID"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl spawn "$UDID" "$OUT/probe" > "$OUT/probe.txt" 2>&1
echo "exit $?"
wc -l "$OUT/probe.txt"
cat "$OUT/probe.txt"
