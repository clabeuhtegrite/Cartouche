#!/usr/bin/env bash
# Lays out the Python side of spike S2 as an iOS app carries it: the runner
# (cartouche_s2), Capstone's binding, the LZ4 decoder, and the part of
# nxnative's dm folder that the rewriter reads (dm/tools/*.py, and for each
# game profile its game.tsv and patches.py, with dm/games/game.py).
# run_simulator.sh puts it in the testbed app; build_ios_runtime.sh in
# Cartouche, as python/app.
# usage: layout_app.sh NXNATIVE CAPSTONE OUT
#   NXNATIVE  nxnative at the pinned commit (fetch_nxnative.sh)
#   CAPSTONE  Capstone's binding as build_capstone_ios.sh lays it out
#   OUT       the folder to write; it is emptied first
set -euo pipefail

USAGE="usage: layout_app.sh NXNATIVE CAPSTONE OUT"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NXNATIVE="${1:?$USAGE}"
CAPSTONE="${2:?$USAGE}"
OUT="${3:?$USAGE}"

rm -rf "$OUT"
mkdir -p "$OUT/dm/tools" "$OUT/dm/games"
rsync -a --exclude __pycache__ --exclude modules "$HERE/cartouche_s2/" "$OUT/cartouche_s2/"
rsync -a --exclude __pycache__ "$CAPSTONE/" "$OUT/capstone/"
rsync -a --exclude __pycache__ "$HERE/ios/lz4/" "$OUT/lz4/"
cp "$NXNATIVE"/dm/tools/*.py "$OUT/dm/tools/"
cp "$NXNATIVE/dm/games/game.py" "$OUT/dm/games/"
for profile in "$NXNATIVE"/dm/games/*/; do
  [ -f "$profile/game.tsv" ] || continue
  name="$(basename "$profile")"
  mkdir -p "$OUT/dm/games/$name"
  cp "$profile/game.tsv" "$OUT/dm/games/$name/"
  if [ -f "$profile/patches.py" ]; then cp "$profile/patches.py" "$OUT/dm/games/$name/"; fi
done
git -C "$NXNATIVE" rev-parse HEAD > "$OUT/dm/nxnative.commit"
echo "layout_app: $(find "$OUT" -type f | wc -l | tr -d ' ') files, $(du -sh "$OUT" | cut -f1), nxnative $(cut -c1-8 "$OUT/dm/nxnative.commit")"
