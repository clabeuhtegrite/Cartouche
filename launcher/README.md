# Launcher

The interface players see: a console-style library of their games. It will be SwiftUI code built into the app through a patch to LiveContainer (see [`app/patches/`](../app/patches/)), in place of LiveContainer's app list. Planned for Phase 1.

## Screens

- **Library:** the player's games, each with the icon from their own copy of the game, and its state: ready, needs an update, will not run on this iPhone.
- **Game sheet:** what the game needs against what this iPhone has (memory limit measured on the phone, iOS version, GPU features), recommended settings, testers' results, from [`catalog/`](../catalog/).
- **Import:** an IPA built on a Mac (v1) or the player's own dump (v2), from Files, iCloud Drive, a USB-C drive or a network share.
- **System:** signature days left and renewal, updates, the memory probe, opt-in reports.

The launcher never offers to download a game and has no list of where to get one.
