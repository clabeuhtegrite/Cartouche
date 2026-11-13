# Contributing

Thanks for helping. Cartouche is written in English: code, comments, docs and commit messages.

## Ground rules

- Never attach, commit or link games, keys, firmware or IPAs built from games, in code, issues, logs or screenshots. See [LEGAL.md](LEGAL.md).
- Logs and reports must not contain personal data: Apple account names, device identifiers that are not needed, file paths with your name.
- Changes to LiveContainer or SideStore go in `app/patches/` as patch files, never as edits to the submodules. A fix that helps those projects too should also be offered to them.

## Pull requests

- Every change to main goes through a pull request, squashed when it is merged: main takes no push ([.github/rulesets](.github/rulesets/README.md)).
- One change per pull request, with a description of what it does and how it was tested.
- Once a pull request is merged or closed, its branch is deleted, with the screenshots kept for it, by the [Branches workflow](.github/branches/README.md); **Restore branch** on the pull request brings it back. New work goes on a branch started again from main. A branch no pull request has stays until its author deletes it.
- A fix comes with a test that fails without it, where the bug was: a unit test of the launcher, a storage test against real servers, a UI test of the gallery, or a Python test. The pull request says which.
- CI must pass: the publish guard's tests, the catalog checks, the shell checks, the workflow audit and, when the app's files change, the app build. main requires them all. When the storage code changes, the storage tests against real servers must pass too ([launcher/StorageTests](launcher/StorageTests/README.md)).
- Before any release, of Cartouche, Cartouche Builder or the Installer, the [Full test pass](.github/full-pass/README.md) runs every test of the repository on its commit, whatever it changes, and nothing is published until it has passed.
- A compatibility sheet in `catalog/games/` needs a result measured on a real device; see the compatibility report issue form.

## Development

- App: `app/scripts/build.sh` on a Mac, see [app/README.md](app/README.md).
- Publish guard: see [guard/README.md](guard/README.md).
- Installer: see [installer/README.md](installer/README.md).

## Licence of contributions

By contributing, you agree that your contribution is licensed under the [GNU AGPL-3.0](LICENSE), like the rest of the project.
