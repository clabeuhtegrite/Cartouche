"""Cartouche Builder: builds the player's own games into IPAs with nxnative on
their Mac, and builds again the ones a change to nxnative touches.

This package is the builder's engine: it needs only Python's standard library
(3.12 or later). Its Mac app (mac/, SwiftUI) runs it through its JSON
commands (api.py) and follows its batches (status.py). nxnative itself, its
Python packages and the Apple tools it needs are checked and set up by the
builder (toolchain.py), never bundled.
"""

__version__ = "0.2.0"
