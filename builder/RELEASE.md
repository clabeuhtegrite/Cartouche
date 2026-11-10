Cartouche Builder becomes a Mac app: it follows the games you have, says when nxnative improved one, and builds it again for Cartouche on your iPhone.

- **Your games, followed.** Every game of your sources, with its cover, and the IPAs already in your games folder. When nxnative changes something a game uses, the game says it can be better, and **Rebuild** builds it again, now or at night. The menu bar shows what is being built and how far it is.
- **On this Mac or on your NAS.** The sources and the games folder can be on a share: the app connects it again when it needs it. What it keeps on the Mac (nxnative, its build tools, the last logs) is on its Storage page, with what each part takes and the button that frees it.
- **The Mac as Cartouche's storage.** Turned on, the iPhone page lets Cartouche on your iPhone add this Mac (**System › Storage › Add your Mac**), over your Wi-Fi, after a 6-digit code once: it installs your games from it and keeps your saves here, encrypted.
- **Nothing to type.** The app installs this Mac's tools itself (Xcode's parts, Homebrew, Python, nxnative and what it builds with), asks your password when macOS needs it, and every setting is in the app.
- **It updates itself** from this repository's releases: it downloads the new version, checks its SHA-256 and its signature, and installs it when it quits, or when the Mac is idle.
- **Measures**, as Cartouche sends them: what the app builds, how long it takes, what fails, and the Mac's model and macOS version, never a path, a key, a name or your Apple Account. **Send usage measures**, in **Settings › General**, turns them off. What is sent: [docs/privacy.md](https://github.com/clabeuhtegrite/Cartouche/blob/main/docs/privacy.md#cartouche-builder).
- In English and French.

Download `Cartouche-Builder-0.2.0.dmg`, for a Mac with Apple silicon (nxnative builds on macOS 26.6 or later), open it and drag **Cartouche Builder** onto **Applications**. The app is not notarized: the first time, open **System Settings › Privacy & Security** and click **Open Anyway**. Its updates then open without asking.

Your games are yours: the builder builds the dumps of your own Switch, and shares nothing. How it works: [builder/README.md](https://github.com/clabeuhtegrite/Cartouche/blob/main/builder/README.md).
