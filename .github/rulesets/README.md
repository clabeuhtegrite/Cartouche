# Rulesets

The rules GitHub enforces on this repository, kept here so that they are reviewed like code. GitHub does not read these files: a repository admin imports each one in **Settings › Rules › Rulesets › New ruleset › Import a ruleset**, and imports it again after a change here, in place of the old one.

- [`main.json`](main.json): main takes changes only through pull requests, squashed, once the checks below have passed. Nobody pushes to main, admins and workflows included, and nobody can force-push or delete it. The checks: `Server tools and catalog`, `App sources`, `Shell scripts` and `Workflow audit` from the [CI workflow](../workflows/ci.yml), `Build Cartouche.ipa` and `Publish guard and source entry` from the [App workflow](../workflows/app.yml), which skips them, and so passes them, when a pull request changes none of the app's files.
- [`release-tags.json`](release-tags.json): a release tag `v*` can be made, by the [Release workflow](../workflows/release.yml), but never moved or deleted.

[`check_rulesets.py`](check_rulesets.py), in the Workflow audit, fails when main requires a check that some pull request would not report, which would block every pull request.
