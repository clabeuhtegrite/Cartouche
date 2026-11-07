#!/usr/bin/env bash
# Build Cartouche.ipa, unsigned, from the pinned LiveContainer and SideStore sources.
#
# Needs a Mac with Xcode (CI uses the version in .github/workflows/app.yml),
# Homebrew's ldid, the network (for the Swift packages LiveContainer and
# SideStore resolve) and the submodules:
#
#     git submodule update --init --recursive
#     brew install ldid
#     app/scripts/build.sh            # writes build/app/Cartouche.ipa
#
# The submodules are never modified: app/scripts/prepare.sh copies the sources
# to build/app/work/src, applies the patches in app/patches/ and Cartouche's
# identity to the copies, and the copies are built.
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

for tool in xcodebuild ldid clang; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[ -n "$(ls -A "$APP/tools/dylibify" 2>/dev/null)" ] || {
  echo "app/tools/dylibify is empty: run git submodule update --init --recursive" >&2; exit 1; }

WORK="$OUT/work"
rm -rf "$WORK"
"$HERE/prepare.sh" --out "$OUT"

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
    -onlyUsePackageVersionsFromResolvedFile \
    LIVECONTAINER_BUNDLE_IDENTIFIER="$CARTOUCHE_BUNDLE_ID"
)

echo "== packaging"
COMMIT="$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
"$HERE/package.sh" \
  --archive "$WORK/LiveContainer.xcarchive" \
  --sidestore "$WORK/src/SideStore/SideStore.ipa" \
  --dylibify "$WORK/dylibify" \
  --resources "$WORK/src/LiveContainer/.github/sidelc" \
  --catalog "$ROOT/catalog" \
  --bundle-id "$CARTOUCHE_BUNDLE_ID" \
  --name "$CARTOUCHE_DISPLAY_NAME" \
  --url-scheme "$CARTOUCHE_URL_SCHEME" \
  --version "$CARTOUCHE_VERSION" \
  --source-url "$CARTOUCHE_SIDESTORE_SOURCE_URL" \
  --commit "$COMMIT" \
  --out "$OUT/Cartouche.ipa"

echo "== done: $OUT/Cartouche.ipa"
