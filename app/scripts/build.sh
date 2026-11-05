#!/usr/bin/env bash
# Build Cartouche.ipa, unsigned, from the pinned LiveContainer and SideStore sources.
#
# Needs a Mac with Xcode (CI uses the version in .github/workflows/app.yml),
# Homebrew's ldid, and the submodules:
#
#     git submodule update --init --recursive
#     brew install ldid
#     app/scripts/build.sh            # writes build/app/Cartouche.ipa
#
# The submodules are never modified: the sources are copied to build/app/work,
# the patches in app/patches/<project>/ are applied to the copies in name
# order, and the copies are built.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(dirname "$HERE")"
ROOT="$(dirname "$APP")"
OUT="$ROOT/build/app"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    *) echo "usage: $0 [--out DIR]" >&2; exit 2 ;;
  esac
done

# shellcheck source=SCRIPTDIR/../config.env
source "$APP/config.env"

for tool in xcodebuild ldid rsync clang; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
for module in LiveContainer SideStore tools/dylibify; do
  [ -n "$(ls -A "$APP/$module" 2>/dev/null)" ] || {
    echo "app/$module is empty: run git submodule update --init --recursive" >&2; exit 1; }
done

WORK="$OUT/work"
rm -rf "$WORK"
mkdir -p "$WORK/src"

copy_and_patch() {  # <name> <patch folder>
  local name="$1" patches="$APP/patches/$2" dst="$WORK/src/$1"
  rsync -a --delete --exclude .git "$APP/$name/" "$dst/"
  for patch in "$patches"/*.patch; do
    [ -e "$patch" ] || continue
    echo "== applying $2/$(basename "$patch")"
    patch -s -N -t -p1 -d "$dst" -i "$patch"
  done
}

echo "== copying and patching the sources"
copy_and_patch LiveContainer livecontainer
copy_and_patch SideStore sidestore

echo "== building dylibify"
clang "$APP/tools/dylibify/main.m" -framework Foundation -fobjc-arc -o "$WORK/dylibify"

echo "== building SideStore"
(
  cd "$WORK/src/SideStore"
  rm -rf AltStore/Resources/Icons.xcassets/Modern/*
  NSUnbufferedIO=YES make -B build
  make fakesign
  make ipa
)

echo "== building LiveContainer"
(
  cd "$WORK/src/LiveContainer"
  xcodebuild archive \
    -project LiveContainer.xcodeproj \
    -scheme LiveContainer \
    -sdk iphoneos -arch arm64 \
    -configuration Release \
    -archivePath "$WORK/LiveContainer" \
    LIVECONTAINER_BUNDLE_IDENTIFIER="$CARTOUCHE_BUNDLE_ID"
)

echo "== packaging"
"$HERE/package.sh" \
  --archive "$WORK/LiveContainer.xcarchive" \
  --sidestore "$WORK/src/SideStore/SideStore.ipa" \
  --dylibify "$WORK/dylibify" \
  --resources "$WORK/src/LiveContainer/.github/sidelc" \
  --bundle-id "$CARTOUCHE_BUNDLE_ID" \
  --name "$CARTOUCHE_DISPLAY_NAME" \
  --out "$OUT/Cartouche.ipa"

echo "== done: $OUT/Cartouche.ipa"
