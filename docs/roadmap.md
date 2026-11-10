# Roadmap

Cartouche is a launcher: it installs, starts and keeps the games the player builds with nxnative, and signs, renews and updates itself. The app does not build games ([decision 28](decisions.md)); Cartouche Builder, a program of its own, builds them on the player's Mac ([decision 29](decisions.md)). Each release is checked on a real iPhone, not only in CI, and tested from a fresh install.

## Released

| Version | What it brought |
| --- | --- |
| 0.1 | One app, LiveContainer with SideStore built in, under Cartouche's own bundle identifier, name and icon. Increased Memory Limit on a free account. The certificate and the pairing file from iloader, and a setup of three steps with no setting to change. Renewal from the System page or every night from Shortcuts, with expiry alerts. |
| 0.2 | A console's home: the player's games and the games nxnative plays on the iPhone as cartridges, every game of nxnative's list, a game controller as well as touch, layouts for every iPhone and the iPhone Duo, built with Xcode 27.2. Games installed, started, set up and uninstalled in Cartouche. |
| 0.3 | The player's own storage over SMB or in Files, for their games and saves. The games' official covers from IGDB. No page of LiveContainer or SideStore, but for the Apple ID sign-in. Alongside it, the Cartouche Installer for macOS and Windows. |
| 0.4 | Updates offered in Cartouche and installed by the built-in SideStore out of sight. Large games copied to storage in bounded memory; read-only shared folders. |
| 0.5 | The Apple ID signed in on Cartouche's own screen, with the built-in SideStore out of sight: Cartouche shows no page of SideStore any more. 0.5.1 checks that iOS accepts the certificate games are signed with, and signs in again by itself for the new one when an install from another computer revoked it; 0.5.2 finds that certificate however its serial number is written. |
| 0.6 | The player's own S3 bucket for their games and saves, on Amazon S3 or a server of theirs such as MinIO, signed with their own keys. |
| 0.7 | An FTP server of the player's network for their games and saves, with their own account. |
| 0.8 | An SFTP server of the player's for their games and saves, with their own account, its key checked at each connection. 0.8.1 installs games whose IPA holds a large deflated file read in pieces, and leaves no badge on the icon. |
| 0.9 | A game updated from the player's games folder when it holds a newer build of it, such as one Cartouche Builder made again after a change to nxnative: Cartouche reads which build each IPA is and offers **Update** over the game. |
| 0.10 | A game behind the console: the Home button brings the console back and leaves the game paused behind it, to resume or quit. The player's Mac as storage, through Cartouche Builder, paired once with six digits. A guide from the install to the first game; each game's play time and size; games in the iPhone's language; Game Mode. A server out of reach shown offline within seconds, and installs that read on after a dropped connection. **Copy the report** under each error and **Report a problem** in System. Game measurements sent to the project's server unless the player turns them off. In the catalog, the 64 games nxnative plays on the iPhone, and new games' covers every day. |

Every release and its notes: [`app/releases`](../app/releases/). Beside the app, Cartouche Builder builds the player's games on their Mac and builds them again when nxnative changes for them; since 0.2, a Mac app from a disk image, it installs its own tools, updates itself, and serves the games and keeps the saves of the iPhones paired with it ([builder/README.md](../builder/README.md)).

## Next

- **0.10 on a phone and a Mac:** installed from inside Cartouche over 0.9, then each of its changes tried on a real iPhone and a real Mac: a game behind the console, the Mac paired, a server offline, an error report, a game in the iPhone's language.

## Then

- On an iPhone Duo: folding or unfolding mid-game keeps the game running under its memory limit, checked on a Duo closed, open and partly folded. The home and a game's sheet already stand on either side of the fold, in a split `ArrangementView` of iOS 27.1 ([launcher/README.md](../launcher/README.md#every-iphone-the-iphone-duo-included)).
- A week of renewals by the built-in SideStore alone, with Increased Memory Limit kept.
- More testers: their iPhones measured and added to [`catalog/devices.json`](../catalog/devices.json), and compatibility sheets from their reports.
- Game measurements from every iPhone, on unless the player turns them off ([decision 35](decisions.md)), sent from 0.10 on: the measurements of several iPhones in the game sheets, each Thursday.

## Not planned

- Building games on the iPhone from a dump ([decision 28](decisions.md)).
- Hosting, downloading or listing downloadable games, keys or firmware ([decision 1](decisions.md)).
