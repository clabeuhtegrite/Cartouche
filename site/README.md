# Showcase site

[`index.html`](index.html) is Cartouche's showcase page: one static page, in French and English, that shows the app's screens rebuilt in HTML and CSS at their sizes in points, and says how to install Cartouche. A visitor can move the console's focus, send the game behind the console and bring it back, and tap a cover on the unfolded iPhone Duo for its sheet.

| Screen | Where the page shows it |
| --- | --- |
| The home, landscape on an iPhone 17 Pro (upright on a phone) | The top of the page |
| All games, with a controller connected | The console |
| A game's sheet and its settings | A game's sheet |
| The game behind the console, paused or resumed | During a game |
| The home on the iPhone Duo folded, the home and the sheet unfolded | iPhone Duo |
| The System page | Behind the scenes |

## What it may show

- **Made-up games only.** The games on the page and their covers are invented: [`covers/make_covers.py`](covers/make_covers.py) draws the covers, and the page says so. A real game's cover art is not ours to publish ([docs/decisions.md](../docs/decisions.md), 12 and 37).
- **No game and no way to one.** No link to a game, a dump, an IPA, a catalog of games, keys or firmware: each player brings their own copy. The only download is the Cartouche Installer, from this repository's releases.
- **Nothing third-party.** No font, script, image or analytics from another site, no cookie, no request and no address of a server of the project. The page loads its own files only, and links only to this repository and nxnative's.

[`tests/test_site.py`](tests/test_site.py) checks all of this, and that every text has its French and English versions; CI runs it on every pull request (Showcase site).

## Working on it

```
python3 -m http.server -d site 8000        # then open http://localhost:8000
python3 site/covers/make_covers.py          # after changing a cover
python3 -m unittest discover -s site/tests -v
```

The page has no build step: its styles, icons and script are inside it, and it uses the system's fonts. Each screen is a container whose sizes are numbers of points (`--pt`), so it is drawn as the app lays it out, at any width. [`favicon.svg`](favicon.svg) is the app's icon ([`app/icon/svg/light.svg`](../app/icon/svg/light.svg)) with the corners iOS gives it.

## Publishing

Nothing publishes the site yet. It is meant for GitHub Pages, deployed from `site/` by a workflow when main changes; that workflow, and turning on Pages in the repository's settings, wait for the owner's go-ahead.
