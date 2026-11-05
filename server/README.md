# Server tools

`cartouche-server` publishes Cartouche's update channel: the app, engine builds, build tools, pipeline lists and compatibility sheets, as a signed manifest of content-addressed chunks. It works on a local folder laid out like the bucket; CI then syncs that folder to Cloudflare R2. The format is described in [docs/architecture.md](../docs/architecture.md#updates).

```
python3 -m venv .venv && .venv/bin/pip install -e "server[dev]"
.venv/bin/python -m unittest discover -s server/tests -t server/tests
```

## Commands

```
cartouche-server keygen --out manifest.key
cartouche-server check --kind engine-host build/engine/host
cartouche-server publish release.json --store out/ --key-env CARTOUCHE_MANIFEST_KEY
cartouche-server verify --store out/ --channel stable --public-key server/keys/stable.pub
```

- `keygen` writes a new Ed25519 private key (mode 600) and prints the public key. The private key goes into a CI secret, never into the repository; the public key is built into the app.
- `check` runs the publish guard on files.
- `publish` reads a release spec, runs the guard on every file, chunks the files into the store, carries over the other artifacts of the channel's current manifest, raises its sequence by one and signs it. If any file is refused, nothing is written to the channel.
- `verify` checks the signature and every chunk of a channel.

A release spec:

```json
{
  "channel": "stable",
  "artifacts": [
    { "id": "app", "kind": "app", "version": "0.1.0", "file": "build/app/Cartouche.ipa" },
    { "id": "catalog/0400C3F00006E000", "kind": "catalog", "version": "2026.11.05", "file": "catalog/games/0400C3F00006E000.json" }
  ]
}
```

## The publish guard

[`cartouche_server/guard.py`](cartouche_server/guard.py) refuses a file, or any file inside an archive, that:

- has the name or extension of game content or keys (`.nsp`, `.xci`, `.nca`, `.nso`, `prod.keys`, `romfs.img`...);
- carries the magic number of a Switch format (PFS0, HFS0, NSO0, NRO0, KIP1, IVFC, NCZ, game card and RomFS images);
- is a Mach-O image with a game's rewritten code (`__DM*` segments or `__dm*` sections, as nxnative's `gen_embed.py` makes them);
- is an IPA whose bundle identifier is not Cartouche's;
- is a catalog file with a URL, or a key that names a link or a download;
- is far larger than any build output of its kind.
