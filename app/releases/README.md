# Releases

A release puts a new version of Cartouche on players' iPhones without a computer. Cartouche's built-in SideStore reads [`../sidestore-source.json`](../sidestore-source.json) from the main branch. When the source lists a higher version than the one installed ([app/README.md](../README.md#version)), SideStore offers the update in My Apps, downloads it, checks its size and SHA-256, signs it and installs it over the app. The games inside Cartouche and their data stay.

## Cutting a release

1. In a pull request, raise `CARTOUCHE_VERSION` in [`../config.env`](../config.env) and add the release notes as `<version>.md` in this folder, in plain text: SideStore shows them under the update. Merge it once the App build is green.
2. Tag the merge commit on main and push the tag:

   ```
   git fetch origin main
   git tag -a v0.1.1 -m "Cartouche 0.1.1" FETCH_HEAD
   git push origin v0.1.1
   ```

3. The [Release workflow](../../.github/workflows/release.yml) checks that the tag matches `CARTOUCHE_VERSION`, that it is on main and that its notes exist. It builds the IPA, runs the publish guard on it, and attaches it to the GitHub release `v0.1.1` as `Cartouche-0.1.1.ipa`. It then adds that version to the source with [`../scripts/add_release.py`](../scripts/add_release.py) and pushes the change to main, where SideStore finds it the next time it reads its sources.

The App workflow runs the publish guard and `add_release.py` on every build, so a build that a release would refuse shows up in its pull request.

## Rules

- A release is always higher than every version the source lists, since SideStore would not offer a lower or equal one.
- The source lists Cartouche and nothing else, and never a game ([LEGAL.md](../../LEGAL.md)). `add_release.py` refuses an IPA that is not Cartouche at the version being released.
- The source keeps the last ten versions, newest first.
- The source always lists Cartouche, as LiveContainer's and SideStore's own sources list themselves. Without that entry, the built-in SideStore drops its record of Cartouche's store entry each time it reads the source, then rebuilds it from the profile inside the app, the first install's, each time it starts: it would show the expiry of the first install instead of the last renewal.
- Versions 0.x are test builds, marked as pre-releases on GitHub.
