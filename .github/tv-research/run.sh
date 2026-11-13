#!/bin/bash
# Research only (the TV mode's thread): the probe's variants on one
# simulator, with and without an external display (drive.py). Removed before
# the pull request.
#
#     run.sh UDID APP VARIANTS...
#
# A variant is NAME:SECONDS, run with the external display attached, or
# NAME:SECONDS:late, launched without it and attached 5 s later, or
# NAME:SECONDS:none, run without it.

set -uo pipefail
UDID="$1"
APP="$2"
shift 2
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== booting $UDID"
xcrun simctl boot "$UDID" 2>&1 || true
xcrun simctl bootstatus "$UDID" -b 2>&1 | tail -2
killall Simulator 2>/dev/null || true
sleep 2
open -a Simulator --args -CurrentDeviceUDID "$UDID"
sleep 15
xcrun simctl install "$UDID" "$APP"
echo "Simulator $(defaults read /Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo '?')"

# Each variant within 3 minutes, whatever hangs.
drive() { perl -e 'alarm shift; exec @ARGV' 180 python3 "$HERE/drive.py" "$@"; }

attached=no
for spec in "$@"; do
  IFS=: read -r name seconds how <<<"$spec"
  case "${how:-}" in
    none)
      drive "$UDID" "$name" "$seconds" --detach-first
      attached=no ;;
    late)
      drive "$UDID" "$name" "$seconds" --detach-first --attach-at 5
      attached=yes ;;
    *)
      if [ "$attached" = no ]; then
        echo "== attaching the external display"
        python3 - "$UDID" <<PY
import sys
sys.path.insert(0, "$HERE")
import drive
drive.display(sys.argv[1], "1920")
PY
        attached=yes
      fi
      drive "$UDID" "$name" "$seconds" ;;
  esac
done

python3 - "$UDID" <<PY
import sys
sys.path.insert(0, "$HERE")
import drive
drive.display(sys.argv[1], "Disabled")
PY
xcrun simctl shutdown "$UDID" 2>&1 || true
