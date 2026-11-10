#!/bin/bash
# Checks IPAs as Cartouche reads them when it installs a game from the games
# folder, with the reader of 0.8.0 and of 0.9.0 (macOS, Xcode's swiftc).
# Reads only: nothing is written outside this folder, nothing is deleted.
#
#   ./run.sh build                  fetch CartoucheZip.swift of both, compile
#   ./run.sh list <ipa>...          central directories, a few reads per IPA
#   ./run.sh verify <ver> <ipa>...  every byte of each IPA with that version
set -u
cd "$(dirname "$0")" || exit 1
RAW=https://raw.githubusercontent.com/clabeuhtegrite/Cartouche
mkdir -p logs
case "${1:-}" in
  build)
    for pair in 0.8.0:f4391fa 0.9.0:50e8079; do
      v=${pair%%:*}; sha=${pair##*:}
      mkdir -p "v$v"
      curl -fsSL "$RAW/$sha/launcher/Sources/CartoucheZip.swift" -o "v$v/CartoucheZip.swift" || exit 1
      xcrun swiftc -swift-version 5 -O -o "zipcheck-$v" main.swift "v$v/CartoucheZip.swift" || exit 1
    done
    ls -l zipcheck-0.8.0 zipcheck-0.9.0 ;;
  list)
    shift
    ./zipcheck-0.9.0 list "$@" 2>&1 | tee -a logs/list.txt ;;
  verify)
    v=$2; shift 2
    ./zipcheck-"$v" verify "$@" 2>&1 | tee -a "logs/verify-$v.txt" ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac
