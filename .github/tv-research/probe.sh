#!/bin/bash
# Research only: what iOS 27's own scene classes say, read without running
# them (otool, from the Simulator's runtime) and then by running probe.m in
# the Simulator, each with a time limit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/out}"
mkdir -p "$OUT"
limit() { perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!"' "$@"; }

ROOT=$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rts = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
rts.sort(key=lambda r: r["version"])
print(rts[-1].get("runtimeRoot") or rts[-1]["bundlePath"] + "/Contents/Resources/RuntimeRoot")
')
echo "runtime root: $ROOT"
for lib in PrivateFrameworks/UIKitCore.framework/UIKitCore PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices \
           PrivateFrameworks/FrontBoard.framework/FrontBoard; do
  BIN="$ROOT/System/Library/$lib"
  echo "######## $lib"
  [ -f "$BIN" ] || { echo "missing"; continue; }
  limit 240 otool -ov "$BIN" > "$OUT/otool.txt" 2>/dev/null
  echo "otool lines: $(wc -l < "$OUT/otool.txt")"
  python3 "$HERE/classes.py" "$OUT/otool.txt"
done

echo "######## running probe.m in the Simulator"
xcrun -sdk iphonesimulator clang -target arm64-apple-ios18.0-simulator -fobjc-arc \
  -framework Foundation -framework UIKit "$HERE/probe.m" -o "$OUT/probe" || exit 0
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
for runtime in sorted(d, reverse=True):
    if "iOS" not in runtime: continue
    for dev in d[runtime]:
        if dev["name"].startswith("iPhone"):
            print(dev["udid"]); sys.exit()
')
echo "simulator $UDID $(date)"
limit 240 xcrun simctl boot "$UDID" || echo "boot: $?"
limit 300 xcrun simctl bootstatus "$UDID" -b > /dev/null || echo "bootstatus: $?"
echo "booted $(date)"
limit 120 xcrun simctl spawn "$UDID" "$OUT/probe" > "$OUT/probe.txt" 2>&1
echo "probe exit $? $(date)"
cat "$OUT/probe.txt"
