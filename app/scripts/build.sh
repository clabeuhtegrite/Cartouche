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
#
# The built-in SideStore changes only with its own sources, and takes about
# five minutes of the build. CI keeps the one it built
# (.github/workflows/app.yml):
#
#     app/scripts/prepare.sh
#     app/scripts/build.sh --prepared --sidestore-key       # prints its key
#     app/scripts/build.sh --prepared --sidestore-cache DIR
#
# --prepared builds the sources prepare.sh left in build/app/work/src.
# --sidestore-key prints the key of the SideStore they build: a digest of its
# prepared sources (tree_digest.py), of this script, of Xcode's version and of
# ldid. --sidestore-cache DIR takes DIR/SideStore.ipa when DIR/key is that
# key, and otherwise builds SideStore and keeps it there with its key.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(dirname "$HERE")"
ROOT="$(dirname "$APP")"
OUT="$ROOT/build/app"
PREPARED=false
PRINT_KEY=false
SIDESTORE_CACHE=""

usage() {
  echo "usage: $0 [--out DIR] [--prepared [--sidestore-key | --sidestore-cache DIR]]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --prepared) PREPARED=true; shift ;;
    --sidestore-key) PRINT_KEY=true; shift ;;
    --sidestore-cache) SIDESTORE_CACHE="$2"; shift 2 ;;
    *) usage ;;
  esac
done
if [ "$PREPARED" = false ] && { [ "$PRINT_KEY" = true ] || [ -n "$SIDESTORE_CACHE" ]; }; then usage; fi

# shellcheck source=SCRIPTDIR/../config.env
source "$APP/config.env"

for tool in xcodebuild ldid clang; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[ -n "$(ls -A "$APP/tools/dylibify" 2>/dev/null)" ] || {
  echo "app/tools/dylibify is empty: run git submodule update --init --recursive" >&2; exit 1; }

WORK="$OUT/work"
if [ "$PREPARED" = true ]; then
  for project in LiveContainer SideStore; do
    [ -d "$WORK/src/$project" ] || { echo "$WORK/src/$project is missing: run app/scripts/prepare.sh first" >&2; exit 1; }
  done
else
  rm -rf "$WORK"
  "$HERE/prepare.sh" --out "$OUT"
fi

# The key of the SideStore the prepared sources build, before the build
# below touches them: what goes into it, the recipe below, Xcode and ldid.
sidestore_key() {
  {
    echo "Cartouche's built-in SideStore"
    shasum -a 256 < "$HERE/build.sh"
    xcodebuild -version
    shasum -a 256 < "$(command -v ldid)"
    python3 "$HERE/tree_digest.py" "$WORK/src/SideStore"
  } | shasum -a 256 | cut -c1-64
}

if [ "$PRINT_KEY" = true ]; then
  sidestore_key
  exit 0
fi

echo "== building dylibify"
clang "$APP/tools/dylibify/main.m" -framework Foundation -fobjc-arc -o "$WORK/dylibify"

KEY=""
[ -z "$SIDESTORE_CACHE" ] || KEY="$(sidestore_key)"
if [ -n "$KEY" ] && [ -s "$SIDESTORE_CACHE/SideStore.ipa" ] && [ "$(cat "$SIDESTORE_CACHE/key" 2>/dev/null)" = "$KEY" ]; then
  echo "== SideStore from $SIDESTORE_CACHE, built from these very sources (key $KEY)"
  cp "$SIDESTORE_CACHE/SideStore.ipa" "$WORK/src/SideStore/SideStore.ipa"
else
  echo "== building SideStore"
  STARTED=$SECONDS
  (
    cd "$WORK/src/SideStore"
    rm -rf AltStore/Resources/Icons.xcassets/Modern/*
    NSUnbufferedIO=YES make -B build
    make fakesign
    make ipa
  )
  echo "== SideStore built in $((SECONDS - STARTED)) s"
  if [ -n "$KEY" ]; then
    mkdir -p "$SIDESTORE_CACHE"
    rm -f "$SIDESTORE_CACHE/key"
    cp "$WORK/src/SideStore/SideStore.ipa" "$SIDESTORE_CACHE/SideStore.ipa"
    echo "$KEY" > "$SIDESTORE_CACHE/key"
    echo "== SideStore kept in $SIDESTORE_CACHE (key $KEY)"
  fi
fi

echo "== building LiveContainer"
STARTED=$SECONDS
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
echo "== LiveContainer built in $((SECONDS - STARTED)) s"

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
  --covers-url "$CARTOUCHE_COVERS_URL" \
  --telemetry-url "${CARTOUCHE_TELEMETRY_URL:-}" \
  --commit "$COMMIT" \
  --out "$OUT/Cartouche.ipa"

echo "== done: $OUT/Cartouche.ipa"
