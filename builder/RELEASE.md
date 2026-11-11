Cartouche Builder 0.4.0 no longer quits on macOS 27 when you choose a game, and takes the games you ask for while it builds.

- **No more quitting on macOS 27.** There, the app quit seconds after a game was chosen, and the library's covers ran under the window's title. A game's sheet is now a column of its own beside the covers, with a button that closes it, and each page fits a narrow window.
- **Builds wait their turn.** A game you ask for while others build joins the batch, after the games already in it, instead of every Build button staying off until the batch ends. A game waiting can be taken out, and the one building stopped alone: the batch goes on with the next. Add a game from its sheet, its card's menu, the card of the games to rebuild, Builds or the menu bar; the library says how many are building or waiting. `cartouche-builder build ID` in the Terminal queues a game too.
- **Why a game is to rebuild**, on its sheet, in plain words, with nxnative's commits cut to their first lines and the rest when you ask.
- **From 0.3.0**, which updates itself to 0.4.0: your settings, your games and their builds stay. Until it has, open the app without choosing a game, and once the menu bar says the new version is ready, quit it.

Download `Cartouche-Builder-0.4.0.dmg`, for a Mac with Apple silicon (nxnative builds on macOS 26.6 or later), open it and drag **Cartouche Builder** onto **Applications**. The app is not notarized: the first time, open **System Settings › Privacy & Security** and click **Open Anyway**. Its updates then open without asking.

Your games are yours: the builder builds the dumps of your own Switch, and shares nothing. How it works: [builder/README.md](https://github.com/clabeuhtegrite/Cartouche/blob/main/builder/README.md).
