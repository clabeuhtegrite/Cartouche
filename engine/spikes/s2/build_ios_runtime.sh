#!/usr/bin/env bash
# Builds what Cartouche carries to rewrite a game's modules on the iPhone
# (spike S2, step 2): CPython for iOS, Capstone built for the iPhone, and the
# runner with the part of nxnative the rewriter reads, all as runtime.env and
# engine/nxnative.commit pin them. app/scripts/package.sh --python puts the
# result in the app:
#
#   OUT/Frameworks/Python.framework   CPython for iOS, without its headers
#   OUT/Frameworks/libcapstone.dylib  Capstone (the binding finds it through
#                                     LIBCAPSTONE_PATH, which the app sets)
#   OUT/python/lib/python3.X          the standard library, without its tests
#                                     and what an app cannot use; its extension
#                                     modules are still .so files
#   OUT/python/app                    layout_app.sh: cartouche_s2, Capstone's
#                                     binding, the LZ4 decoder, nxnative's dm
#   OUT/python/VERSIONS               Python-Apple-support's list of versions
#   OUT/python/licenses               the licences of Python, of the libraries
#                                     inside it (licenses/), Capstone, nxnative
#   OUT/dylib-Info-template.plist     its Info.plist for the extension modules,
#                                     which package.sh makes into frameworks
#
# Needs a Mac with Xcode and CMake, and the network.
# usage: build_ios_runtime.sh OUT
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:?usage: build_ios_runtime.sh OUT}"
# shellcheck source=SCRIPTDIR/runtime.env
source "$HERE/runtime.env"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$HERE/fetch_python_support.sh" "$WORK/support"
"$HERE/fetch_nxnative.sh" "$WORK/nxnative"
"$HERE/build_capstone_ios.sh" iphoneos "$WORK/capstone"

XCF="$WORK/support/Python.xcframework"
# The libraries inside this build of Python, whose licences licenses/ holds.
if ! sed -n '/^---/,$p' "$WORK/support/VERSIONS" | tail -n +2 | diff -u "$HERE/licenses/libraries.txt" - >&2; then
  echo "build_ios_runtime: the libraries inside Python $PYTHON_SUPPORT are not those of licenses/libraries.txt:" \
    "copy their licences into licenses/ first" >&2
  exit 1
fi
STDLIB="python$PYTHON_VERSION"
rm -rf "$OUT"
mkdir -p "$OUT/Frameworks" "$OUT/python/lib"
rsync -a --exclude Headers "$XCF/ios-arm64/Python.framework/" "$OUT/Frameworks/Python.framework/"
mv "$WORK/capstone/lib/libcapstone.dylib" "$OUT/Frameworks/libcapstone.dylib"
rmdir "$WORK/capstone/lib"

# The standard library: the part common to every platform, then the iPhone's
# (its configuration and its extension modules).
rsync -a --exclude 'libpython*.dylib' "$XCF/lib/" "$OUT/python/lib/"
rsync -a "$XCF/ios-arm64/lib-arm64/" "$OUT/python/lib/"
LIB="$OUT/python/lib/$STDLIB"
[ -f "$LIB/os.py" ] && [ -d "$LIB/lib-dynload" ] || { echo "build_ios_runtime: no standard library in $LIB" >&2; exit 1; }
rm -rf "$LIB/test" "$LIB/idlelib" "$LIB/tkinter" "$LIB/turtledemo" "$LIB/turtle.py" "$LIB/ensurepip" \
  "$LIB/pydoc_data" "$LIB/__phello__" "$LIB/lib2to3"
rm -f "$LIB"/lib-dynload/_test* "$LIB"/lib-dynload/_xxtestfuzz* "$LIB"/lib-dynload/xxlimited* \
  "$LIB"/lib-dynload/xxsubtype* "$LIB"/lib-dynload/_ctypes_test*
find "$OUT/python" -name __pycache__ -type d -prune -exec rm -rf {} +

"$HERE/layout_app.sh" "$WORK/nxnative" "$WORK/capstone" "$OUT/python/app"
cp "$WORK/support/VERSIONS" "$OUT/python/VERSIONS"
mkdir -p "$OUT/python/licenses"
cp "$LIB/LICENSE.txt" "$OUT/python/licenses/python.txt"
cp "$HERE"/licenses/*.txt "$OUT/python/licenses/"
rm "$OUT/python/licenses/libraries.txt"
cp "$WORK/capstone/LICENSE.TXT" "$OUT/python/licenses/capstone.txt"
cp "$WORK/nxnative/LICENSE" "$OUT/python/licenses/nxnative.txt"
cp "$XCF/build/iOS-dylib-Info-template.plist" "$OUT/dylib-Info-template.plist"
echo "build_ios_runtime: Python $(sed -n 's/^Python version: *//p' "$OUT/python/VERSIONS" | tr -d ' '), \
$(find "$LIB/lib-dynload" -name '*.so' | wc -l | tr -d ' ') extension modules, $(du -sh "$OUT" | cut -f1) in $OUT"
