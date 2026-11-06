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
| [`sidestore/0001`](sidestore/0001-sidesign-enable-capabilities-through-the-v1-api.patch) | SideSign: `DeveloperPortal.enableCapabilities` turns capabilities on for an App ID with the developer services v1 API (`PATCH services/v1/bundleIds/<id>`), the request Xcode sends | To offer to SideSign once S1 has worked on a phone |
| [`sidestore/0002`](sidestore/0002-request-increased-memory-limit-for-free-teams.patch) | SideStore: asks for `INCREASED_MEMORY_LIMIT` when a free team's app wants `com.apple.developer.kernel.increased-memory-limit`, before downloading its provisioning profile ([SideStore#1616](https://github.com/SideStore/SideStore/issues/1616)). A failure is logged and the install goes on with the default limit | To offer to SideStore with 0001 |

Cartouche asks for the entitlement through LiveContainer's `entitlements.xml`, so the first refresh by its own SideStore should give its App ID the capability, as GetMoreRam does for LiveContainer today. Spike S1 checks it on a phone.

## Planned

| Project | Patch | Phase |
| --- | --- | --- |
| LiveContainer | The launcher, in place of LiveContainer's app list, with Cartouche's icon | 1 |
