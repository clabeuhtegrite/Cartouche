Cartouche Builder 0.3.0 starts with a setup assistant, and takes nothing over from NxNative Batch Builder any more.

- **A setup assistant.** At the first start, step by step: this Mac's tools, your dumps (with the number of games found), your games folder, on this Mac or on a NAS, your keys, the builds at night and the iPhone, then a summary of every choice. Each choice is saved as you make it, so you can go on while Xcode downloads. **Settings › Advanced › Open the setup assistant** opens it again.
- **Nothing of NxNative Batch Builder's.** The app no longer reads that tool's settings, workspace or records: it starts from its own defaults.
- **From 0.2.0**, which updates itself to 0.3.0: at the first start, the settings 0.2.0 took over from NxNative Batch Builder go back to the defaults and the assistant opens; settings you chose yourself stay. The builds it took over are forgotten, but the app reads which nxnative commit built each IPA of your games folder, so nothing is rebuilt at once. The builds at night stop until you turn them on again. The old tool's build folders are no longer used: a game's next build starts from scratch, and the old folder stays on your Mac, to delete in the Finder if you want the room back.

Download `Cartouche-Builder-0.3.0.dmg`, for a Mac with Apple silicon (nxnative builds on macOS 26.6 or later), open it and drag **Cartouche Builder** onto **Applications**. The app is not notarized: the first time, open **System Settings › Privacy & Security** and click **Open Anyway**. Its updates then open without asking.

Your games are yours: the builder builds the dumps of your own Switch, and shares nothing. How it works: [builder/README.md](https://github.com/clabeuhtegrite/Cartouche/blob/main/builder/README.md).
