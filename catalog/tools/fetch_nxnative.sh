#!/usr/bin/env bash
# Fetches nxnative's game profiles (dm/games) at the commit Cartouche pins
# (engine/nxnative.commit), without the rest of the repository, for
# nxnative_games.py.
# usage: fetch_nxnative.sh DIR
set -euo pipefail

DEST="${1:?usage: fetch_nxnative.sh DIR}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT="$(tr -d '[:space:]' < "$HERE/../../engine/nxnative.commit")"

git init -q "$DEST"
git -C "$DEST" remote add origin https://github.com/seedds/nxnative.git
git -C "$DEST" sparse-checkout set dm/games
git -C "$DEST" fetch -q --depth 1 --filter=blob:none origin "$COMMIT"
git -C "$DEST" checkout -q FETCH_HEAD
echo "nxnative $COMMIT: $(find "$DEST/dm/games" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') game profiles"
