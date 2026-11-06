# Security

Cartouche signs in to an Apple account (through its built-in SideStore), signs code on the device and updates itself from a signed manifest. A flaw in any of these can hurt its users, so please report it privately.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: the **Security** tab of this repository, then **Report a vulnerability**. Do not open a public issue for a vulnerability.

Include what an attacker can do, the steps to reproduce it and the version or commit you tested.

## Scope

- the update manifest and its signature checks, and the chunk downloads;
- how Cartouche and its SideStore store and use Apple account credentials and certificates;
- the publish guard in `server/` letting game content through;
- the releases and the source the built-in SideStore installs them from (`app/sidestore-source.json`), and the workflows that make them.

Vulnerabilities in LiveContainer or SideStore themselves are best reported to those projects too.

## How this repository is protected

- main takes changes only through pull requests, squashed, once CI has passed ([`.github/rulesets`](.github/rulesets)). Nobody pushes to it, the release workflow included: a release proposes its source entry in a pull request of its own ([app/releases/README.md](app/releases/README.md)).
- Release tags can't be moved or deleted, and a version the source lists never gets another IPA.
- Workflows get a read-only token. Only the release's last job can write, to publish the release and push its branch, and it runs nothing installed from a package index.
- Workflows pin each action to a commit, which Dependabot updates, and keep no credentials in their checkouts. The Workflow audit, [zizmor](https://docs.zizmor.sh), fails a pull request that breaks one of these rules.
- The repository never holds games, keys, firmware, pairing files, certificates or provisioning profiles ([LEGAL.md](LEGAL.md), [.gitignore](.gitignore)).
