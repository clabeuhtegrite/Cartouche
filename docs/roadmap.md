# Roadmap

Each phase ends with a gate: a result checked on a real iPhone, not only in CI. Dates are targets.

## Phase 0: framing (5 to 6 November 2026)

- Framing questionnaire answered, design document written, repository and CI set up.
- **Gate:** this base merged with CI green.

## Phase 1: v1, one app (target 12 November 2026)

- **S1, the memory spike:** Cartouche, installed with iloader on a free account under its own App ID, gets Increased Memory Limit on that App ID from its SideStore; the probe shows about 6 GiB.
- Branding patch for LiveContainer: bundle identifier, name, icon, URL schemes, app group handling.
- SideStore and SideSign patch: request the memory capability for free accounts.
- First launcher: catalogue, import of an IPA built on a Mac, compatibility sheets, memory probe.
- Layouts for every iPhone and the iPad, the iPhone Duo folded, unfolded and partly folded included ([launcher/README.md](../launcher/README.md#every-iphone-the-iphone-duo-included)). Xcode 27.1 once LiveContainer and SideStore build with it.
- On a Duo: touch controls clear of the camera and the fold, and a game folded and unfolded mid-race keeps running under its memory limit.
- Renewal in the background, with a warning before expiry.
- **Gate:** Mario Kart World starts from Cartouche on the reference iPhone with the 6 GiB limit, and Cartouche renews itself for a week without a computer.

## Phase 2: spikes for building on the iPhone

- **S2:** rewrite a game's modules on the phone (`patch_nso.py` on CPython for iOS, with capstone).
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
