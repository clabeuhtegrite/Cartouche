# The README's pictures

The pictures of the repository's [README](../../README.md), made from the app's own screenshots:

| File | What it shows | Made from |
| --- | --- | --- |
| `devices.png` | Cartouche Builder's library beside the sheet of a game, with Play on this Mac, on a MacBook Air; in front of it, the home beside the sheet of the game in focus, paused behind the console, landscape on an iPad Pro 13-inch, and the home, landscape on an iPhone 17 Pro | The Builder's gallery, `game-en-light`, and the app's, `ipad-home-paused-landscape` and `iphone-home-landscape`, in English; the iPad's status bar without the name of the gallery's app |
| `screens.png` | All games, a game paused behind the console, a game's settings | The gallery's `iphone-library`, `iphone-home-paused` and `iphone-game-settings`, in English |
| `builder.png` | Cartouche Builder's library, with a game's sheet: Play on this Mac, and what the game is built for | The Builder's gallery, `game-en-light` |
| `icon.png` | Cartouche's icon, with the corners iOS gives it | [`app/icon`](../../app/icon/) |
| `download-*.png` | The download buttons | Drawn for the README |

The screenshots are the ones CI takes of every screen: the Launcher screens workflow, with `"language": "en"` in [`launcher/Gallery/scenarios.json`](../../launcher/Gallery/scenarios.json), for the app, and the Builder workflow for Cartouche Builder. Each iPhone or iPad is drawn around its screenshot on Cartouche's colours, and the Mac around its window, on a desktop with its menu bar; the iPad and the iPhone of `devices.png` at the same size for their points.

The games show their official covers, as in the app, which loads them from IGDB ([decision 83](../decisions.md)). Never an image from inside a game: no capture of a game running, and no game's screenshot. The download buttons link to the [download page](https://clabeuhtegrite.github.io/Cartouche/download/), which gives the newest file, and say no version.
