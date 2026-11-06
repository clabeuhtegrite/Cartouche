#!/usr/bin/env bash
# Prepare the sources Cartouche is built from, on macOS or Linux.
#
#     git submodule update --init --recursive
#     app/scripts/prepare.sh            # writes build/app/work/src/{LiveContainer,SideStore}
#
# The submodules are never modified: their sources are copied, the patches in
# app/patches/<project>/ are applied to the copies in name order, and
# app/scripts/brand.py gives the copies Cartouche's identity (app/config.env).
# app/scripts/build.sh runs this first; CI also runs it on Linux.
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

for tool in rsync patch python3; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
for module in LiveContainer SideStore; do
  [ -n "$(ls -A "$APP/$module" 2>/dev/null)" ] || {
    echo "app/$module is empty: run git submodule update --init --recursive" >&2; exit 1; }
done

SRC="$OUT/work/src"
rm -rf "$SRC"
mkdir -p "$SRC"

copy_and_patch() {  # <name> <patch folder>
  local name="$1" patches="$APP/patches/$2" dst="$SRC/$1"
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

python3 "$HERE/brand.py" \
  --config "$APP/config.env" \
  --livecontainer "$SRC/LiveContainer" \
  --sidestore "$SRC/SideStore"

echo "== sources ready in $SRC"
