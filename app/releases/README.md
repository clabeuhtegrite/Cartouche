# Releases

A release puts a new version of Cartouche on players' iPhones without a computer. Cartouche's built-in SideStore reads [`../sidestore-source.json`](../sidestore-source.json) from the main branch. When the source lists a higher version than the one installed ([app/README.md](../README.md#version)), Cartouche offers the update over its console and on its System page, and its built-in SideStore downloads it, checks its size and SHA-256, signs it and installs it over the app, without showing SideStore ([launcher/README.md](../../launcher/README.md)). The games inside Cartouche and their data stay.

## Cutting a release

1. In a pull request, raise `CARTOUCHE_VERSION` in [`../config.env`](../config.env) and add the release notes as `<version>.md` in this folder, in plain text: the System page shows them under the update, as **What’s new**. Merge it once the App build is green. Its merge starts the [Full test pass](../../.github/full-pass/README.md), every test of the repository, on main's new commit.
2. Start the release, from a phone or from a computer:
   - On GitHub, open **Actions › Release › Run workflow**, keep the branch `main`, and enter the version, such as `0.1.1`. The release then makes the tag `v0.1.1` on main's last commit.
   - Or tag the merge commit on main and push the tag:

     ```
     git fetch origin main
     git tag -a v0.1.1 -m "Cartouche 0.1.1" FETCH_HEAD
     git push origin v0.1.1
     ```

3. The [Release workflow](../../.github/workflows/release.yml) checks that the tag matches `CARTOUCHE_VERSION`, that it is on main, that its notes exist and that the source does not list that version yet. Run from the Actions tab, it also refuses a tag that already names another commit. It builds the IPA and runs the publish guard on it; then its job **Full test pass on this commit** waits for the pass the merge started, or starts one when none has run on the commit. Only once the pass has passed does it attach the IPA to the GitHub release `v0.1.1` as `Cartouche-0.1.1.ipa`; a pass that fails stops the release, with the pass's link ([what to do](../../.github/full-pass/README.md#how-a-release-waits-for-it)). It then adds that version to the source with [`../scripts/add_release.py`](../scripts/add_release.py), on the branch `release/v0.1.1`: main takes no push, the workflow's included.
4. Open the pull request from `release/v0.1.1`, "Source: Cartouche 0.1.1", from the link in the run's summary, and merge it once CI is green. Cartouche finds the version the next time it opens, or when it comes back after an hour.

The App workflow runs the publish guard and `add_release.py` on every build, so a build that a release would refuse shows up in its pull request.

## Rules

- A release is always higher than every version the source lists, since SideStore would not offer a lower or equal one.
- The source lists Cartouche and nothing else, and never a game ([LEGAL.md](../../LEGAL.md)). `add_release.py` refuses an IPA that is not Cartouche at the version being released.
- The source keeps the last ten versions, newest first.
- The source always lists Cartouche, as LiveContainer's and SideStore's own sources list themselves. Without that entry, the built-in SideStore drops its record of Cartouche's store entry each time it reads the source, then rebuilds it from the profile inside the app, the first install's, each time it starts: it would show the expiry of the first install instead of the last renewal.
- Versions 0.x are test builds, marked as pre-releases on GitHub.
- Once the source lists a version, its IPA never changes: SideStore checks the size and SHA-256 the source gives. A fix is a new version.
- Cartouche installs its updates without showing SideStore, so SideStore cannot ask the player anything on the way: a version that adds an entitlement stops at the review of its new permissions, and one that adds an app extension is installed without it. Such a version is installed once with the [Cartouche Installer](../../installer/README.md), and its notes say so, as 0.4.0's do: it is the first version that updates itself.
