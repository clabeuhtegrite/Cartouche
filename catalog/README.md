# Catalog

What the launcher knows about games and devices. These files are published as `catalog` artifacts: every game sheet is an entry in the launcher's catalogue, and its details fill the game's sheet.

- [`games/<title ID>.json`](games/): one sheet per supported game: what it needs (iOS version, GPU features, the memory capability, its measured memory peak), recommended settings, and results measured on real devices. Schema: [`schema/game.schema.json`](schema/game.schema.json).
- [`devices.json`](devices.json): memory limits measured on real devices, with and without Increased Memory Limit. Schema: [`schema/devices.schema.json`](schema/devices.schema.json).

Catalog files never say where to get a game: the schemas have no field for it, and the publish guard refuses any URL in them. Results come from compatibility reports (see the issue form) measured on real devices; nothing is filled in from guesses.
