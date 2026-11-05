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

## Every iPhone, the iPhone Duo included

The launcher lays itself out from the space it is given, never from the iPhone model, as Apple asks of apps for the iPhone Duo ([Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)). One design then serves every iPhone, both displays of the Duo and the iPad. The model matters only to the game sheets, for memory.

| Where | Width class | Catalogue |
| --- | --- | --- |
| Any other iPhone, portrait | compact | One column: the player's games large at the top, then the grid. A game's sheet opens over the catalogue. |
| iPhone Duo folded: outer display, 5.4 in | compact | As on the other iPhones. iOS moves the bars to the side of the display. |
| iPhone Duo unfolded: inner display, 7.6 in | regular | The catalogue and the selected game's sheet together, one on each side of the fold. |
| iPad | regular | As on the unfolded Duo; one column in a narrow window. |

- **Size classes and our own bounds, not the screen.** Layout follows `horizontalSizeClass` and the bounds of the scene or the containing view, never `UIScreen.main.bounds`, `userInterfaceIdiom` or the interface orientation.
- **System containers and bars.** `NavigationStack`, `toolbar(content:)` and the bars iOS provides, which it presents vertically on the side of the Duo's outer display, and for some views on the inner one. Every bar item has an icon and a title: iOS does not present a title-only item or a custom view vertically. The banner of the player's games extends under a vertical bar with `backgroundExtensionEffect()`.
- **Regular width.** A split `ArrangementView` (iOS 27.1; a `NavigationSplitView` on iOS 26) holds the catalogue and the game sheet: side by side when the display is wider than tall, the catalogue above and the sheet below when it is taller than wide, and iOS places them around the fold. It sits at the top level, not inside a split view, list or scroll view, as Apple advises.
- **Nothing in the fold or under a camera.** Views we draw ourselves read `reservedRegions(kind:options:layoutDirectionBehavior:)` and keep text and controls out of the fold while the Duo is partly folded, and out of the outer front camera, which always covers part of the outer display. System views move on their own.
- **Folding loses nothing.** Folding, unfolding or rotating keeps the selected game, the scroll position and any import in progress; imports run outside the views.
- **Built with Xcode 27.1 or later.** Apple: an app built with Xcode 26 or earlier does not extend under the Duo's status bar and camera. CI builds with Xcode 26.4 today, and GitHub's macOS runners offer Xcode 27 only as a public preview ([runner-images#14404](https://github.com/actions/runner-images/issues/14404)). Cartouche moves to it once LiveContainer and SideStore build with it. Until then it works on the Duo without using the whole display.
- **Tested** in the Duo simulator, then on a Duo closed, open and partly folded, rotated in each pose, as Apple recommends.

### Games on the Duo

A game's picture and its touch controls are drawn by nxnative's iOS app, which runs inside Cartouche. We do not patch it: what follows goes to nxnative as proposals, with measurements, like our other fixes.

- **A 16:9 picture on near-square displays.** The Duo's displays are about 1.4:1, against 2.2:1 for the other iPhones ([specifications](https://www.apple.com/uk/iphone-duo/specs/): 1878 × 2670 inside, 1398 × 2034 outside). In landscape, a 16:9 game leaves bands above and below rather than at the sides: 2670 × 1502 unfolded, 2034 × 1144 folded. Touch controls therefore sit over the picture, out of the fold and the camera.
- **On a table, the game above the fold and the controls below,** like a two-screen console. Apple's overlay `ArrangementView` does this: it shows the primary view, the controls, over the secondary view, the game, when the Duo is closed or flat, and below the fold when it is partly open on a table. The upper half then shows the picture at 1878 × 1056, nearly pixel for pixel for the 1080p of handheld mode.
- **Handheld mode at 1080p stays the rule.** Unfolded, the picture is scaled up to 2670 × 1502.
- **A game sees Cartouche's SDK version.** Inside Cartouche, system libraries work to the SDK version Cartouche was built with, not the game's, unless LiveContainer's per-app *Spoof SDK Version* setting is on ([`Dyld.m`](https://github.com/LiveContainer/LiveContainer/blob/9108ae624ea001f7d7696d48407f890b48fa2653/LiveContainer/Tweaks/Dyld.m)). Once Cartouche is built with Xcode 27.1, games will likely use the whole display too, the camera area included. Phase 1 checks on a Duo that the touch controls stay clear of the camera and the fold, and that folding or unfolding mid-race neither restarts the game nor pushes it over its memory limit.
