#!/usr/bin/env bash
# Downloads CPython for iOS, the Python-Apple-support package that runtime.env
# pins, checks its SHA-256 and unpacks it into OUT (Python.xcframework,
# testbed, VERSIONS).
# usage: fetch_python_support.sh OUT
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:?usage: fetch_python_support.sh OUT}"
# shellcheck source=SCRIPTDIR/runtime.env
source "$HERE/runtime.env"

NAME="Python-$PYTHON_VERSION-iOS-support.${PYTHON_SUPPORT#*-}.tar.gz"
URL="https://github.com/beeware/Python-Apple-support/releases/download/$PYTHON_SUPPORT/$NAME"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl --fail --silent --show-error --location --retry 3 -o "$WORK/$NAME" "$URL"
echo "$PYTHON_SUPPORT_SHA256  $WORK/$NAME" | shasum -a 256 -c - >/dev/null || {
  echo "fetch_python_support: $NAME does not have the SHA-256 that runtime.env pins" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
tar -xzf "$WORK/$NAME" -C "$OUT"
echo "Python-Apple-support $PYTHON_SUPPORT: $(head -n 1 "$OUT/VERSIONS")"
