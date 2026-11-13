#!/bin/bash
# Research only: what iOS 27's own scene classes say, by running probe.m in
# the Simulator's runtime: first straight on the Mac with the runtime as its
# root, then in a booted Simulator, each with a time limit.
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
xcrun -sdk iphonesimulator clang -target arm64-apple-ios18.0-simulator -fobjc-arc \
  -framework Foundation "$HERE/probe.m" -o "$OUT/probe" || exit 0
codesign -s - -f "$OUT/probe" || true

echo "######## straight, with the runtime as root $(date)"
DYLD_ROOT_PATH="$ROOT" limit 90 "$OUT/probe" > "$OUT/direct.txt" 2>&1
echo "exit $? $(date), $(wc -l < "$OUT/direct.txt") lines"
if grep -q "#### done" "$OUT/direct.txt"; then cat "$OUT/direct.txt"; exit 0; fi
head -50 "$OUT/direct.txt"

echo "######## in a booted Simulator"
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
limit 300 xcrun simctl boot "$UDID" || echo "boot: $?"
limit 300 xcrun simctl bootstatus "$UDID" -b > /dev/null || echo "bootstatus: $?"
echo "booted $(date)"
limit 150 xcrun simctl spawn "$UDID" "$OUT/probe" > "$OUT/probe.txt" 2>&1
echo "probe exit $? $(date)"
cat "$OUT/probe.txt"
