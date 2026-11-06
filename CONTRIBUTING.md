# Contributing

Thanks for helping. Cartouche is written in English: code, comments, docs and commit messages.

## Ground rules

- Never attach, commit or link games, keys, firmware or IPAs built from games, in code, issues, logs or screenshots. See [LEGAL.md](LEGAL.md).
- Logs and reports must not contain personal data: Apple account names, device identifiers that are not needed, file paths with your name.
- Changes to LiveContainer or SideStore go in `app/patches/` as patch files, never as edits to the submodules. A fix that helps those projects too should also be offered to them.

## Pull requests

- Every change to main goes through a pull request, squashed when it is merged: main takes no push ([.github/rulesets](.github/rulesets/README.md)).
- One change per pull request, with a description of what it does and how it was tested.
- CI must pass: the publish guard's tests, the catalog checks, the shell checks, the workflow audit and, when the app's files change, the app build. main requires them all.
- A compatibility sheet in `catalog/games/` needs a result measured on a real device; see the compatibility report issue form.

## Development

- App: `app/scripts/build.sh` on a Mac, see [app/README.md](app/README.md).
- Publish guard: see [guard/README.md](guard/README.md).
- Installer: see [installer/README.md](installer/README.md).

## Licence of contributions

By contributing, you agree that your contribution is licensed under the [GNU AGPL-3.0](LICENSE), like the rest of the project.
