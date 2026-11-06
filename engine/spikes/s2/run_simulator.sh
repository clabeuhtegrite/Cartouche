#!/usr/bin/env bash
# Spike S2 on a Mac: nxnative's rewriter on the synthetic modules, first with
# this Mac's Python, then under CPython for iOS in the iOS simulator. Every
# file the two runs write must be the same, byte for byte.
# usage: run_simulator.sh SUPPORT NXNATIVE WORK
#   SUPPORT   an unpacked Python-Apple-support package for iOS (fetch_python_support.sh)
#   NXNATIVE  nxnative at the pinned commit (fetch_nxnative.sh)
#   WORK      where to build; SIMULATOR (default: the testbed's choice) can be set.
# The Mac rewrites with the whole of nxnative, iOS with the part of it that
# Cartouche carries (layout_app.sh), and the same runner as the app's.
set -euo pipefail

USAGE="usage: run_simulator.sh SUPPORT NXNATIVE WORK"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT="$(cd "${1:?$USAGE}" && pwd)"
NXNATIVE="$(cd "${2:?$USAGE}" && pwd)"
mkdir -p "${3:?$USAGE}"
WORK="$(cd "$3" && pwd)"
# shellcheck source=SCRIPTDIR/runtime.env
source "$HERE/runtime.env"

echo "== The Mac: Capstone $CAPSTONE_VERSION and lz4 from PyPI"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install --quiet "capstone==$CAPSTONE_VERSION" lz4
NXNATIVE="$NXNATIVE" "$WORK/venv/bin/python" -m unittest discover -s "$HERE/tests" -v
rm -rf "$WORK/modules"
"$WORK/venv/bin/python" "$HERE/make_test_nso.py" "$WORK/modules"
(cd "$HERE" && "$WORK/venv/bin/python" -m cartouche_s2 --tools "$NXNATIVE/dm/tools" --modules "$WORK/modules") | tee "$WORK/mac.log"

echo "== iOS: CPython for iOS in the simulator, Capstone built for it, LZ4 in pure Python"
"$HERE/build_capstone_ios.sh" iphonesimulator "$WORK/capstone"
"$HERE/layout_app.sh" "$NXNATIVE" "$WORK/capstone" "$WORK/app"
cp -R "$WORK/modules" "$WORK/app/cartouche_s2/modules"
rm -rf "$WORK/testbed"
python3 "$SUPPORT/testbed" clone --platform iOS --framework "$SUPPORT/Python.xcframework" "$WORK/testbed"
# The app code goes into iOSTestbed/app, the folder the Xcode project bundles
# and puts first on sys.path. (The testbed's own --app option copies into
# Testbed/app, which the project does not bundle.)
cp -R "$WORK/app/." "$WORK/testbed/iOSTestbed/app/"
RUN=(python3 "$WORK/testbed" run)
if [ -n "${SIMULATOR:-}" ]; then RUN+=(--simulator "$SIMULATOR"); fi
"${RUN[@]}" -- cartouche_s2 | tee "$WORK/ios.log"

echo "== The two runs"
grep -o 'S2 [^ ]* [0-9a-f]\{64\}' "$WORK/mac.log" > "$WORK/mac.txt"
grep -o 'S2 [^ ]* [0-9a-f]\{64\}' "$WORK/ios.log" > "$WORK/ios.txt" || true
if ! grep -q 'S2 done' "$WORK/ios.log"; then
  echo "spike S2: the iOS run did not finish" >&2
  exit 1
fi
if diff -u "$WORK/mac.txt" "$WORK/ios.txt"; then
  echo "spike S2: iOS wrote the same $(wc -l < "$WORK/mac.txt" | tr -d ' ') files as the Mac, byte for byte"
else
  echo "spike S2: iOS and the Mac wrote different files" >&2
  exit 1
fi
