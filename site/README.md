# Showcase site

[`index.html`](index.html) is Cartouche's showcase page: one static page, in French and English, that shows the app's screens rebuilt in HTML and CSS at their sizes in points, around nine games of nxnative's list, and says how to install Cartouche. A visitor can move the console's focus, send the game behind the console and bring it back, and tap a cover on the unfolded iPhone Duo for its sheet.

| Screen | Where the page shows it |
| --- | --- |
| The home, landscape on an iPhone 17 Pro (upright on a phone) | The top of the page |
| All games, with a controller connected | The console |
| A game's sheet and its settings | A game's sheet |
| The game behind the console, paused or resumed | During a game |
| The home on the iPhone Duo folded, the home and the sheet unfolded | iPhone Duo |
| The System page | Behind the scenes |

## What it may show

- **Games of nxnative's list, with their covers from IGDB, as in the app.** Each game on the page is one of [`catalog/nxnative.json`](../catalog/nxnative.json), with where nxnative plays it and the colours Cartouche gives it. Its cover and artwork are IGDB's, by the IDs of [`catalog/covers.json`](../catalog/covers.json), loaded from IGDB's image server as the app loads them ([docs/decisions.md](../docs/decisions.md), 22 and 40): the repository holds no image of a game. Under each cover, the page draws the label Cartouche draws, which stays when an image cannot load (offline, or a preview that blocks other sites). The page credits IGDB, says the games belong to their publishers and that Cartouche provides none of them, and that play times and sizes are examples.
- **No game and no way to one.** No link to a game, a dump, an IPA, a catalog of games, keys or firmware: each player brings their own copy. The only download is the Cartouche Installer, from this repository's releases.
- **Nothing else third-party.** No font, script or analytics from another site, no cookie, no request but IGDB's images, sent without the page's address, and no address of a server of the project. The page links only to this repository, nxnative's and IGDB.

[`tests/test_site.py`](tests/test_site.py) checks all of this: each game, its status, its cover and artwork and its colours against the catalog and the app, and every text in French and English. CI runs it on every pull request (Showcase site); a catalog change that touches a game of the page fails it until the page's list follows.

## Working on it

```
python3 -m http.server -d site 8000        # then open http://localhost:8000
python3 -m unittest discover -s site/tests -v
```

The page has no build step: its styles, icons and script are inside it, and it uses the system's fonts. Each screen is a container whose sizes are numbers of points (`--pt`), so it is drawn as the app lays it out, at any width. The games are the list at the top of its script, `<script id="games">`: a game's title ID, name, platform, genre and where nxnative plays it as `catalog/nxnative.json` has them, its cover and artwork as `catalog/covers.json` has them, and its colours as `CartoucheTheme.colors(for:)` makes them from its title ID; the tests say what differs. [`favicon.svg`](favicon.svg) is the app's icon ([`app/icon/svg/light.svg`](../app/icon/svg/light.svg)) with the corners iOS gives it.

## Publishing

The page is on GitHub Pages, at <https://clabeuhtegrite.github.io/Cartouche/>, since the owner said so (2026-11-10). When `site/` changes on main, the [Showcase site](../.github/workflows/site.yml) workflow runs these tests, then keeps `index.html` and `favicon.svg` alone on the branch `gh-pages`, in one commit made again at each publication, with a `.nojekyll` so that Pages serves them as they are. Pages serves that branch: **Settings › Pages › Build and deployment**, *Deploy from a branch*, `gh-pages`, `/ (root)`. Nothing else of the repository is published. To publish main's page again, run the workflow from the Actions tab.
