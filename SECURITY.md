# Security

Cartouche signs in to an Apple account (through its built-in SideStore), signs code on the device and updates itself from a signed manifest. A flaw in any of these can hurt its users, so please report it privately.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: the **Security** tab of this repository, then **Report a vulnerability**. Do not open a public issue for a vulnerability.

Include what an attacker can do, the steps to reproduce it and the version or commit you tested.

## Scope

- the update manifest and its signature checks, and the chunk downloads;
- how Cartouche and its SideStore store and use Apple account credentials and certificates;
- the publish guard in `server/` letting game content through.

Vulnerabilities in LiveContainer or SideStore themselves are best reported to those projects too.
