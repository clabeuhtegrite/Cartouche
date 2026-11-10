"""python -m cartouche_builder: the app, or a command (cli.py)."""

import sys

from .cli import main

sys.exit(main())
