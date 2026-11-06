# Roadmap

Cartouche is a launcher: it installs, starts and keeps the games the player builds with nxnative, and signs, renews and updates itself. It does not build games ([decision 28](decisions.md)). Each release is checked on a real iPhone, not only in CI, and tested from a fresh install.

## Released

| Version | What it brought |
| --- | --- |
| 0.1 | One app, LiveContainer with SideStore built in, under Cartouche's own bundle identifier, name and icon. Increased Memory Limit on a free account. The certificate and the pairing file from iloader, and a setup of three steps with no setting to change. Renewal from the System page or every night from Shortcuts, with expiry alerts. |
| 0.2 | A console's home: the player's games and the games nxnative plays on the iPhone as cartridges, every game of nxnative's list, a game controller as well as touch, layouts for every iPhone and the iPhone Duo, built with Xcode 27.2. Games installed, started, set up and uninstalled in Cartouche. |
| 0.3 | The player's own storage over SMB or in Files, for their games and saves. The games' official covers from IGDB. No page of LiveContainer or SideStore, but for the Apple ID sign-in. Alongside it, the Cartouche Installer for macOS and Windows. |
| 0.4 | Updates offered in Cartouche and installed by the built-in SideStore out of sight. Large games copied to storage in bounded memory; read-only shared folders. |
| 0.5 | The Apple ID signed in on Cartouche's own screen, with the built-in SideStore out of sight: Cartouche shows no page of SideStore any more. |

Every release and its notes: [`app/releases`](../app/releases/).

## Next

- **More storage:** S3, FTP and SFTP, a release each, with the player's own account ([decision 23](decisions.md)).
- **Updates on a phone:** 0.5, the first version 0.4 offers, checked end to end: the offer, the install and the return to the home screen.

## Then

- On an iPhone Duo: folding or unfolding mid-game keeps the game running under its memory limit, and the split `ArrangementView` of iOS 27.1 for the home and a game's sheet around the fold ([launcher/README.md](../launcher/README.md#every-iphone-the-iphone-duo-included)).
- A week of renewals by the built-in SideStore alone, with Increased Memory Limit kept.
- More testers: their iPhones measured and added to [`catalog/devices.json`](../catalog/devices.json), and compatibility sheets from their reports.
- Opt-in telemetry ([decision 9](decisions.md)).

## Not planned

- Building games on the iPhone from a dump ([decision 28](decisions.md)).
- Hosting, downloading or listing downloadable games, keys or firmware ([decision 1](decisions.md)).
