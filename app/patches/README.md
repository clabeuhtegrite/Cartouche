# Patches

Our changes to LiveContainer (`livecontainer/`) and SideStore (`sidestore/`, which includes its `Dependencies/SideSign`). `app/scripts/prepare.sh` applies them in name order to copies of the pinned sources, with `patch -p1` from the root of each project, then `app/scripts/brand.py` renames LiveContainer's and SideStore's names to Cartouche's ([app/README.md](../README.md#identity)). A change that only renames a name goes into `brand.py`'s rules, not into a patch.

## Conventions

- Name: `NNNN-short-description.patch`, numbered in the order they apply.
- Make them with `git format-patch` from a checkout of the pinned commit, so that each keeps its author, date and explanation.
- One change per patch. A patch that would help the upstream project too should be offered to it; once upstream has it, move the submodule past it and drop the patch.

## Applied

| Patch | What it does | Upstream |
| --- | --- | --- |
| [`livecontainer/0001`](livecontainer/0001-use-the-built-in-sidestore-app-group-only.patch) | LiveContainer: signs with the built-in SideStore's app group only, without AltStore's, and recognizes that group by its prefix, since `brand.py` renames it | Cartouche only |
| [`livecontainer/0002`](livecontainer/0002-never-fall-back-to-another-apps-app-group.patch) | LiveContainer: never opens an app group other than the built-in SideStore's, even when the signature gives the app one (iloader gives every LiveContainer+SideStore of an account the same group) or an older launch cached one. Without its own group, the app stays without one | Cartouche only |
| [`livecontainer/0003`](livecontainer/0003-open-on-cartouches-games-with-its-system-page.patch) | LiveContainer: opens on Cartouche's games and adds its system page, the launcher in [`launcher/Sources`](../../launcher/Sources/), which `prepare.sh` adds to LiveContainer's SwiftUI sources; LiveContainer's app list and settings stay as tabs. Its Sources and Tweaks tabs go, and a source link is ignored: Cartouche downloads no app | Cartouche only |
| [`sidestore/0001`](sidestore/0001-sidesign-enable-capabilities-through-the-v1-api.patch) | SideSign: `DeveloperPortal.enableCapabilities` turns capabilities on for an App ID with the developer services v1 API (`PATCH services/v1/bundleIds/<id>`), the request Xcode sends | To offer to SideSign once S1 has worked on a phone |
| [`sidestore/0002`](sidestore/0002-request-increased-memory-limit-for-free-teams.patch) | SideStore: asks for `INCREASED_MEMORY_LIMIT` when a free team's app wants `com.apple.developer.kernel.increased-memory-limit`, before downloading its provisioning profile ([SideStore#1616](https://github.com/SideStore/SideStore/issues/1616)). A failure is logged and the install goes on with the default limit | To offer to SideStore with 0001 |
| [`sidestore/0003`](sidestore/0003-import-the-certificate-and-pairing-file-of-another-sidestore.patch) | SideStore: imports the certificate and the pairing file of another SideStore on the same iPhone, such as the one inside a LiveContainer+SideStore, with the links SideStore already answers (`sidestore://certificate` and `sidestore://pairing`); the answers come back to the app's own SideStore URL scheme. The other SideStore asks the player to confirm the export of its certificate; this one asks to confirm each import, and takes only a certificate with its private key, of the team the app is signed with. Buttons in the onboarding and in Settings → Advanced Settings → Certificate Management | To offer to SideStore once S1 has worked on a phone |
| [`sidestore/0004`](sidestore/0004-never-revoke-a-certificate.patch) | SideStore: never revokes a certificate, since every app signed with it stops opening, and creates one only when the account has none at all. When the account already has a certificate that this SideStore does not hold, signing in stops and says where to import it from. Revoking or creating one stays possible by hand, in Settings → Advanced Settings → Certificate Management | Cartouche only |

Cartouche asks for the entitlement through LiveContainer's `entitlements.xml`, so the first refresh by its own SideStore should give its App ID the capability, as GetMoreRam does for LiveContainer today. Spike S1 checks it on a phone.

## Planned

None for now. Renewal, from the System tab or every night from Shortcuts, needed no patch: the launcher reaches the built-in SideStore through its own bridge ([launcher/README.md](../../launcher/README.md#what-the-first-build-does)).
