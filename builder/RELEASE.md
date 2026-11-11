Cartouche Builder 0.4.1 says where its errors come from, so that each one can be fixed sooner.

- **Errors that say where.** When its engine stops on an error, the usage measures it sends now say the kind of error, the part of the engine that met it and the system's error number, never the error's words, a path, a game's name or a line of a log. **Settings › General › Send usage measures** turns them off.
- **From 0.4.0**, which updates itself to 0.4.1: your settings, your games and their builds stay.
- **From 0.3.0**, which updates itself too, you also get 0.4.0's changes: no more quitting on macOS 27 when a game is chosen, and a game asked for while others build waits its turn in the batch. Until it has updated, open the app without choosing a game, and once the menu bar says the new version is ready, quit it.

Download `Cartouche-Builder-0.4.1.dmg`, for a Mac with Apple silicon (nxnative builds on macOS 26.6 or later), open it and drag **Cartouche Builder** onto **Applications**. The app is not notarized: the first time, open **System Settings › Privacy & Security** and click **Open Anyway**. Its updates then open without asking.

Your games are yours: the builder builds the dumps of your own Switch, and shares nothing. How it works: [builder/README.md](https://github.com/clabeuhtegrite/Cartouche/blob/main/builder/README.md).
