# Roadmap

Each phase ends with a gate: a result checked on a real iPhone, not only in CI. Dates are targets.

## Phase 0: framing (5 to 6 November 2026)

- Framing questionnaire answered, design document written, repository and CI set up.
- **Gate:** this base merged with CI green.

## Phase 1: v1, one app (target 12 November 2026)

- **S1, the memory spike:** Cartouche, installed with iloader on a free account under its own App ID, gets Increased Memory Limit on that App ID from its SideStore; the probe shows about 6 GiB.
- Branding: Cartouche's own bundle identifier, URL schemes and SideStore source, so that LiveContainer's links never reach it; LiveContainer+SideStore's app group and keychain groups, the ones iloader gives with its certificate ([app/README.md](../app/README.md#identity)); its name and icon.
- SideStore and SideSign patch: request the memory capability for free accounts.
- Install with the Cartouche Installer, our fork of iloader for macOS and Windows, which gives Cartouche its certificate and puts the pairing file in it, or with iloader, whose exported pairing file Cartouche takes when the player drops it on it ([installer/README.md](../installer/README.md)); a setup of three steps on the iPhone (pairing file, Apple ID, certificate handed to LiveContainer by itself), with no setting to change and SideStore's onboarding going on by itself; its SideStore never revokes or creates a certificate when the account already has one ([architecture.md](architecture.md#first-install)).
- First launcher: catalogue, import of an IPA built on a Mac, compatibility sheets, memory probe.
- The console's home (0.2): every game of nxnative's list, cartridges we draw, the player's games and the iPhone's on shelves, a game controller as well as touch, and screenshots of each screen on every pull request ([launcher/README.md](../launcher/README.md#screens)).
- The player's own storage (0.3): games and saves on a shared folder of their Mac, PC or NAS over SMB, or a folder in Files; the games there in the library, installed from there; saves copied after each game. Then S3, FTP and SFTP, a release each ([launcher/README.md](../launcher/README.md#what-the-first-build-does)).
- No page of LiveContainer or SideStore (0.3): Cartouche's screens only; the Apple ID signed in on Cartouche's own screen (0.5), SideStore working out of sight as it does for renewals.
- Layouts for every iPhone and the iPad, the iPhone Duo folded, unfolded and partly folded included ([launcher/README.md](../launcher/README.md#every-iphone-the-iphone-duo-included)). Built with Xcode 27.2 and the iOS 27.2 SDK since 0.2, so that the Duo gives Cartouche its whole display.
- On a Duo: touch controls clear of the camera and the fold, and a game folded and unfolded mid-race keeps running under its memory limit.
- Renewal in the background, with a warning before expiry.
- Updates of Cartouche from the iPhone: each release is listed in the source of the built-in SideStore, which installs it ([app/releases/README.md](../app/releases/README.md)).
- **Gate:** Mario Kart World starts from Cartouche on the reference iPhone with the 6 GiB limit, and Cartouche renews itself for a week without a computer.

## Phase 2: spikes for building on the iPhone

- **S2:** rewrite a game's modules on the phone (`patch_nso.py` on CPython for iOS, with capstone). The same files as a Mac in the iOS simulator in CI; on the iPhone, the lab of the System page rewrites the player's own game and compares with their Mac's build ([engine/spikes/s2](../engine/spikes/s2/README.md)).
- **S3:** read the dump and translate the shaders on the phone (.NET NativeAOT for LibHac and Ryujinx's translator, SPIRV-Cross, Metal at run time).
- **S4:** an engine host built by CI that loads the modules from a framework written and signed on the phone (`dm_set_game_image_header()`).
- **Gate:** for Mario Kart World, each spike gives the same result as the Mac build.

## Phase 3: v2, build on the iPhone

- The build pipeline in the app; engine builds per supported game from CI, updated automatically.
- **Gate:** Mario Kart World built on the iPhone from the player's own dump and played, with no computer.

## Phase 4: more games and testers

- More supported games and their sheets, starting with the next ones nxnative supports on iPhone.
- Opt-in telemetry; testers' iPhones measured and added to `catalog/devices.json`.
- Duo layouts for games proposed to nxnative, with measurements: touch controls over the picture, and on a table the game above the fold and the controls below.
- **Gate:** every supported game has a sheet with results from at least two iPhone models.
