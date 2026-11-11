Cartouche Builder 0.4.2 finds your games wherever they are in your dumps folder, and stays usable while it builds.

- **Games found anywhere.** Your games may now lie loose in your dumps folder, one folder per game as before, or in folders of folders, four levels down at most. A file named without its title ID is read for it, with your `prod.keys` for an `.xci`, and a game's update may sit in another folder than its base game. Games already built are not built again.
- **What was left aside, and why.** When something in your dumps is not a game the builder can build, the library says what and why, with buttons to your dumps folder and to Settings.
- **A build waits instead of failing.** A build asked for while the app checks nxnative now waits for the check, then starts, instead of saying that a batch is already running, and its games show as waiting from the click. At its start, the app checks nxnative only when the last check is six hours old.
- **The window stays in place.** A message above the page takes the lines it needs and no longer pushes the rest of the window out of reach. **Stop** before a batch has started ends it.
- **From 0.4.1 or 0.4.0**, which update themselves to 0.4.2: your settings, your games and their builds stay.
- **From 0.3.0**, which updates itself too, you also get 0.4.0's and 0.4.1's changes: no more quitting on macOS 27 when a game is chosen, a game asked for while others build waits its turn, and errors that say where they come from. Until it has updated, open the app without choosing a game, and once the menu bar says the new version is ready, quit it.

Download `Cartouche-Builder-0.4.2.dmg`, for a Mac with Apple silicon (nxnative builds on macOS 26.6 or later), open it and drag **Cartouche Builder** onto **Applications**. The app is not notarized: the first time, open **System Settings › Privacy & Security** and click **Open Anyway**. Its updates then open without asking.

Your games are yours: the builder builds the dumps of your own Switch, and shares nothing. How it works: [builder/README.md](https://github.com/clabeuhtegrite/Cartouche/blob/main/builder/README.md).
