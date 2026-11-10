#!/bin/sh
# Opens Cartouche Builder: double-click it in the Finder. It starts the
# builder with a Python 3.12 or later that has Tk, from this folder; nothing
# is installed. The builder makes its own Python environment for nxnative.
cd "$(dirname "$0")" || exit 1
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH
for candidate in python3.14 python3.13 python3.12 python3; do
  python=$(command -v "$candidate" 2>/dev/null) || continue
  if "$python" -c 'import sys, tkinter; sys.exit(sys.version_info < (3, 12))' 2>/dev/null; then
    PYTHONPATH="$(pwd)${PYTHONPATH:+:$PYTHONPATH}" exec "$python" -m cartouche_builder "$@"
  fi
done
echo "Cartouche Builder needs Python 3.12 or later with Tk:"
echo "  brew install python@3.13 python-tk@3.13"
printf "Press Return to close. "
read -r _
exit 1
