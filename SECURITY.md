# Security

Cartouche signs in to an Apple account (through its built-in SideStore), signs code on the device and updates itself from its GitHub releases. A flaw in any of these can hurt its users, so please report it privately.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: the **Security** tab of this repository, then **Report a vulnerability**. Do not open a public issue for a vulnerability.

Include what an attacker can do, the steps to reproduce it and the version or commit you tested.

## Scope

- how Cartouche and its SideStore store and use Apple account credentials and certificates;
- the publish guard in `guard/` letting game content through;
- the releases and the source the built-in SideStore installs them from (`app/sidestore-source.json`), and the workflows that make them;
- the covers Cartouche reads every day from the branch `live-covers`, and the workflow that writes them.

Vulnerabilities in LiveContainer or SideStore themselves are best reported to those projects too.

## How this repository is protected

- main takes changes only through pull requests, squashed, once CI has passed ([`.github/rulesets`](.github/rulesets)). Nobody pushes to it, the release workflow included: a release proposes its source entry in a pull request of its own ([app/releases/README.md](app/releases/README.md)).
- Release tags can't be moved or deleted, and a version the source lists never gets another IPA.
- Workflows get a read-only token. Only the jobs that publish Cartouche's release and push its branch, publish the installer's release, and push the covers and the screenshots to their branches can write, and none of them runs anything installed from a package index.
- Workflows pin each action to a commit, which Dependabot updates, and keep no credentials in their checkouts. The Workflow audit, [zizmor](https://docs.zizmor.sh), fails a pull request that breaks one of these rules.
- Two Mac jobs of a pull request, the app's build and the screenshots, can run on the maintainer's Mac, as an account of its own that reads nothing else there and cannot use sudo. Its runner's job started hook, which no workflow can skip or change, fails any job but a pull request from one of this repository's branches by its owner, or a run from the Actions tab, before its first step: a fork's pull request never runs there, even when its workflow asks for that Mac ([.github/mac](.github/mac/README.md)).
- The repository never holds games, keys, firmware, pairing files, certificates or provisioning profiles ([LEGAL.md](LEGAL.md), [.gitignore](.gitignore)).
