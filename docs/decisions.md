# Decisions

Choices that shape the project, with their reasons. A new decision gets a new entry; a reversed one is marked as such rather than deleted.

| # | Date | Decision | Why |
| --- | --- | --- | --- |
| 1 | 2026-11-05 | The project never hosts, downloads or lists downloadable games, keys or firmware. Players import their own. | Legal: only players' own copies are lawful to use. The update server and its tools enforce it ([LEGAL.md](../LEGAL.md)). |
| 2 | 2026-11-05 | The app is a fork of LiveContainer with SideStore built in, under AGPL-3.0. | One standalone app that handles signing, installing and renewal in the background. A guest app inside an existing LiveContainer would be smaller but not standalone. |
| 3 | 2026-11-05 | Free Apple accounts only. | No player should need a paid developer account. Consequences: seven-day signatures, three apps, ten App IDs a week, and the memory capability requested through the developer services API. |
| 4 | 2026-11-05 | Fix SideStore so that it enables Increased Memory Limit, as GetMoreRam and AltStore 2.3 do, instead of shipping a separate tool. | The bigger games need about 6 GiB; one app must do it all. |
| 5 | 2026-11-05 | No StikDebug, no JIT. | nxnative runs games natively and needs no JIT. |
| 6 | 2026-11-05 | v1 plays games built on a Mac; v2 builds them on the iPhone. | v1 ships in a week on what already works; v2 needs the spikes S2 to S4. |
| 7 | 2026-11-05 | v2 accepts Switch games as NSP with the player's own `prod.keys`, and Switch 2 games as nxnative takes them. | The same inputs as nxnative's own script. Keys stay on the phone. |
| 8 | 2026-11-05 | Updates come from a Cloudflare R2 bucket, as a signed manifest of content-addressed chunks, and install automatically. | R2 has no egress fees; signing protects players if the bucket is ever tampered with; chunks keep updates small. |
| 9 | 2026-11-05 | Telemetry is opt-in. | Players decide what leaves their phone. |
| 10 | 2026-11-05 | Console-style interface. | A launcher for games, not a file manager. |
| 11 | 2026-11-05 | The repository is written in English. | Open source contributors and upstream projects work in English. |
