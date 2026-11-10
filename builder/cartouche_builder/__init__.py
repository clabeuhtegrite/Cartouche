"""Cartouche Builder: builds the player's own games into IPAs with nxnative on
their Mac, and builds again the ones a change to nxnative touches.

The package needs only Python's standard library (3.12 or later); its window
needs Tk. nxnative itself, its Python packages and the Apple tools it needs are
checked and set up by the builder (toolchain.py), never bundled.
"""

__version__ = "0.1.0"
