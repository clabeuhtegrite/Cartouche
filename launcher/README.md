# Launcher

The interface players see: a console-style catalogue of every game Cartouche supports, with the player's own games first. It will be SwiftUI code built into the app through a patch to LiveContainer (see [`app/patches/`](../app/patches/)), in place of LiveContainer's app list. Planned for Phase 1.

## Screens

- **Catalogue, the home screen:** every game Cartouche supports, from the compatibility sheets in [`catalog/`](../catalog/).
  - The player's own games come first, large and featured, each with the icon from their own copy of the game and its state: ready, engine update in progress, not recommended on this iPhone.
  - The other supported games follow, smaller, with their status on this iPhone and one action, **Import my copy**, which opens Files. There is no download button and no hint of where to get a game.
  - A game the player does not have gets a tile we design (title, colours, platform), never official cover art, which is not ours to redistribute. The tile gives way to the icon of the player's copy once they import it.
- **Game sheet:** what the game needs against what this iPhone has (memory limit measured on the phone, iOS version, GPU features), recommended settings, testers' results.
- **Import:** an IPA built on a Mac (v1) or the player's own dump (v2), from Files, iCloud Drive, a USB-C drive or a network share.
- **System:** signature days left and renewal, updates, the memory probe, opt-in reports.

The catalogue shows what Cartouche can run, never where to get a game.
