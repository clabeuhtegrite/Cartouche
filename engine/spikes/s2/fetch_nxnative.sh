#!/usr/bin/env bash
# Fetches nxnative's rewriter and its patch files (dm/tools, dm/games) at the
# commit Cartouche pins (engine/nxnative.commit), without the rest of the
# repository.
# usage: fetch_nxnative.sh DIR
set -euo pipefail

DEST="${1:?usage: fetch_nxnative.sh DIR}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT="$(tr -d '[:space:]' < "$HERE/../../nxnative.commit")"

git init -q "$DEST"
git -C "$DEST" remote add origin https://github.com/seedds/nxnative.git
git -C "$DEST" sparse-checkout set dm/tools dm/games
git -C "$DEST" fetch -q --depth 1 --filter=blob:none origin "$COMMIT"
git -C "$DEST" checkout -q FETCH_HEAD
echo "nxnative $COMMIT: $(find "$DEST/dm/tools" -name '*.py' | wc -l | tr -d ' ') tools"
