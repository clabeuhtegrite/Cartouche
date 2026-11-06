#!/usr/bin/env bash
# Builds Capstone for iOS from the sources of its Python package on PyPI, so
# that iOS disassembles with the same code as "pip install capstone==VERSION"
# on a Mac, and lays out the package as CPython for iOS imports it: the
# binding's Python files with Capstone's licence, and the library in lib/
# where the binding looks.
# The version, and the SHA-256 of its sources, are runtime.env's.
# usage: build_capstone_ios.sh SDK DIR   (SDK: iphonesimulator or iphoneos)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK="${1:?usage: build_capstone_ios.sh SDK DIR}"
OUT="${2:?usage: build_capstone_ios.sh SDK DIR}"
# shellcheck source=SCRIPTDIR/runtime.env
source "$HERE/runtime.env"
VERSION="$CAPSTONE_VERSION"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 -m pip download --quiet --no-binary :all: --no-deps "capstone==$VERSION" -d "$WORK"
echo "$CAPSTONE_SHA256  $WORK/capstone-$VERSION.tar.gz" | shasum -a 256 -c - >/dev/null || {
  echo "build_capstone_ios: capstone-$VERSION.tar.gz does not have the SHA-256 that runtime.env pins" >&2; exit 1; }
tar -xzf "$WORK/capstone-$VERSION.tar.gz" -C "$WORK"
SRC="$WORK/capstone-$VERSION"

# The options of the package's own build (setup.py), for iOS on arm64.
# Capstone builds for x86_64 and arm64 on any Apple system unless told to
# build thin, and its packaging settings need the target processor.
cmake -S "$SRC/src" -B "$WORK/build" -G "Unix Makefiles" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCAPSTONE_BUILD_MACOS_THIN=ON \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DCAPSTONE_BUILD_TESTS=OFF \
  -DCAPSTONE_BUILD_CSTOOL=OFF \
  -DCAPSTONE_INSTALL=OFF
cmake --build "$WORK/build" -j "$(sysctl -n hw.ncpu)"

LIBRARY="$(find "$WORK/build" -name 'libcapstone*.dylib' -type f | head -n 1)"
[ -n "$LIBRARY" ] || { echo "build_capstone_ios: no libcapstone dylib was built" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT/lib"
cp "$SRC"/capstone/*.py "$SRC/LICENSE.TXT" "$OUT/"
cp "$LIBRARY" "$OUT/lib/libcapstone.dylib"

# Capstone 5's binding names its library libcapstone.dylib on macOS only and
# libcapstone.so on every other platform, iOS (sys.platform "ios") included.
# It is a dylib on iOS too, and a .so file in an iOS app would be taken for a
# Python extension module and moved into a framework of its own.
python3 - "$OUT/__init__.py" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = "if sys.platform == 'darwin':"
new = "if sys.platform in ('darwin', 'ios'):   # Cartouche: a dylib on iOS too"
if text.count(old) != 1:
    sys.exit(f"build_capstone_ios: {path} no longer has {old!r} once: check the binding")
path.write_text(text.replace(old, new), encoding="utf-8")
PY
file "$OUT/lib/libcapstone.dylib"
