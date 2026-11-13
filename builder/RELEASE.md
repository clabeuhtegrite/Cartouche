Cartouche Builder 0.5.0 completes an IPA built without its game files with its romfs.img, and goes on building when nxnative's newest commit does not.

- **An IPA and its romfs.img.** **Import IPA + ROMFS…** in the library adds the matching `romfs.img` to an nxnative IPA built without its game data, once its size and index match the IPA's, without compiling, and puts the complete IPA in your games folder. Your own files stay as they are. Thanks to javi11, who wrote it.
- **What lies in your dumps folder.** An IPA or a `romfs.img` left in your dumps folder is explained in the library, instead of being counted as nothing, and the app reads your dumps and your games folder again when it comes to the front.
- **When nxnative's newest commit does not build.** A game that nxnative's newest commit cannot build is built again from the last commit that built on this Mac, and the next batches stay there until a newer commit. Each game not built says why; a full disk says which disk and what is left on it; damaged game files say to copy the game again.
- **Pairing an iPhone.** The Mac keeps a new iPhone before it tells it that it is paired, so the iPhone's first visit, right after the pairing, no longer finds a Mac that does not know it yet.
- **What the new end-to-end tests found.** A zipped dump beside another game's files is found; a build that says nothing no longer shows the step before it; a full disk is named as such, not by nxnative's error; and **Stop** keeps the IPA you had, which the app now hears about.
- **From 0.4.2, 0.4.1 or 0.4.0**, which update themselves to 0.5.0: your settings, your games and their builds stay.

Download `Cartouche-Builder-0.5.0.dmg`, for a Mac with Apple silicon (nxnative builds on macOS 26.6 or later), open it and drag **Cartouche Builder** onto **Applications**. The app is not notarized: the first time, open **System Settings › Privacy & Security** and click **Open Anyway**. Its updates then open without asking.

Your games are yours: the builder builds the dumps of your own Switch, and shares nothing. How it works: [builder/README.md](https://github.com/clabeuhtegrite/Cartouche/blob/main/builder/README.md).
