#!/bin/bash
# Research, removed before the pull request: builds InPlaceGame (project.yml)
# for the iOS Simulator with launcher/Guest/CartoucheUprightGame.m, starts it
# on an iPhone 17 Pro held upright, without the file's calls
# (-CartoucheControl YES, as in Cartouche's own screens) and with them (a
# game in Cartouche's place), and keeps in OUT what the screen showed
# (<name>.png, the Simulator's screenshot), which way the game's screen
# turned (<name>.json) and the lines the game logged.
#
#     research/inplace/run.sh OUT

set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 OUT" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
mkdir -p "$1"
OUT="$(cd "$1" && pwd)"
BUILD="$HERE/Build"
BUNDLE=io.github.clabeuhtegrite.cartouche.inplace-game

# The file where prepare.sh puts it, beside LiveContainer's utils.h.
rm -rf "$BUILD"
mkdir -p "$BUILD/LiveContainer/LiveContainer/Tweaks/Cartouche"
cp "$ROOT/launcher/Guest/CartoucheUprightGame.m" "$BUILD/LiveContainer/LiveContainer/Tweaks/Cartouche/"
cp "$ROOT/app/LiveContainer/LiveContainer/utils.h" "$BUILD/LiveContainer/LiveContainer/"
(cd "$HERE" && xcodegen generate --quiet)

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
runtime = max(runtimes, key=lambda r: (release(r), -len(r["identifier"])))
iphones = [t for t in runtime.get("supportedDeviceTypes", []) if t.get("productFamily", "iPhone") == "iPhone"
           and t.get("name", "").startswith("iPhone")]
wanted = next((t for t in iphones if t["name"] == "iPhone 17 Pro"), iphones[-1])
for device in listing("devices", "available")["devices"].get(runtime["identifier"], []):
    if device.get("deviceTypeIdentifier") == wanted["identifier"]:
        print(device["udid"])
        break
else:
    print(subprocess.run(["xcrun", "simctl", "create", "InPlaceGame " + wanted["name"], wanted["identifier"],
                          runtime["identifier"]], check=True, capture_output=True, text=True).stdout.strip())
print(f"   {wanted['name']}, iOS {runtime.get('version', '?')}", file=sys.stderr)
PY
)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

echo "== building InPlaceGame"
xcodebuild build \
  -project "$HERE/InPlaceGame.xcodeproj" \
  -scheme InPlaceGame \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "$BUILD/DerivedData" > "$OUT/build.log" 2>&1 || { tail -60 "$OUT/build.log"; exit 1; }
APP="$(find "$BUILD/DerivedData/Build/Products" -maxdepth 2 -name InPlaceGame.app | head -1)"
xcrun simctl install "$UDID" "$APP"

start() {  # <name> [launch arguments...]
  local name="$1"
  shift
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  local data
  data="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
  rm -f "$data/Documents/status.json"
  echo "== $name: started with ${*:-no argument}"
  xcrun simctl launch "$UDID" "$BUNDLE" "$@" >/dev/null
  for _ in $(seq 1 30); do
    [ -f "$data/Documents/status.json" ] && break
    sleep 1
  done
  sleep 1
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null
  cp "$data/Documents/status.json" "$OUT/$name.json" 2>/dev/null || echo '{"orientation": "none"}' > "$OUT/$name.json"
  cat "$OUT/$name.json"
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
}

start 1-avant -CartoucheControl YES
start 2-apres
xcrun simctl spawn "$UDID" log show --last 5m --style compact \
  --predicate 'eventMessage CONTAINS "[Cartouche]" OR eventMessage CONTAINS "[InPlaceGame]"' > "$OUT/log.txt" 2>&1 || true
grep -h "\[Cartouche\]\|\[InPlaceGame\]" "$OUT/log.txt" | tail -20 || true
