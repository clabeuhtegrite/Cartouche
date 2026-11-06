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
| 8 | 2026-11-05 | Updates come from a Cloudflare R2 bucket, as a signed manifest of content-addressed chunks, and install automatically. Narrowed by 14: not Cartouche's own versions. | R2 has no egress fees; signing protects players if the bucket is ever tampered with; chunks keep updates small. |
| 9 | 2026-11-05 | Telemetry is opt-in. | Players decide what leaves their phone. |
| 10 | 2026-11-05 | Console-style interface. | A launcher for games, not a file manager. |
| 11 | 2026-11-05 | The repository is written in English. | Open source contributors and upstream projects work in English. |
| 12 | 2026-11-05 | The launcher's home screen is a catalogue of every supported game, the player's own first and featured; the others offer only "Import my copy". A game the player does not have gets a tile we design, not official cover art. | Players see at a glance what Cartouche can run on their iPhone. Cover art is not ours to redistribute; the icon of the player's own copy replaces the tile once imported. |
| 13 | 2026-11-05 | The interface follows the space it is given, never the iPhone model: one column on an iPhone or a folded iPhone Duo, the catalogue and a game's sheet together on an unfolded Duo or an iPad, nothing in the fold or under a camera. Duo layouts for games are proposed to nxnative, which draws them. | Apple's guidance for the Duo (size classes, system containers and bars, reserved regions) also covers every other iPhone and the iPad, so one design serves them all ([launcher/README.md](../launcher/README.md#every-iphone-the-iphone-duo-included)). |
| 14 | 2026-11-06 | Cartouche's own versions are published as GitHub releases of this repository, pre-releases while 0.x, and listed in the source of the built-in SideStore. R2 keeps the engine hosts, tools, pipeline lists and game sheets. | The built-in SideStore installs only a whole IPA from a direct link, not a manifest of chunks, and its source is already in this repository. Each release keeps its IPA next to its source code ([app/releases/README.md](../app/releases/README.md)). |
