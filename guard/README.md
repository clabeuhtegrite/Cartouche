# Publish guard

`cartouche-guard` is the last check before Cartouche publishes anything: the IPA of each release and the catalog the app carries. It refuses a file, or any file inside an archive, that looks like game content, a console key or firmware, so that a mistake in a build script can never publish one. It fails closed: a file it cannot read is refused too.

```
python3 -m venv .venv && .venv/bin/pip install -e "guard[dev]"
.venv/bin/python -m unittest discover -s guard/tests -t guard/tests

.venv/bin/cartouche-guard --kind app build/app/Cartouche.ipa
.venv/bin/cartouche-guard --kind catalog catalog/devices.json catalog/games/*.json
```

CI runs it on the catalog in every pull request, and on the IPA in the App and Release workflows before anything is attached to a release.

## What it refuses

[`cartouche_guard/guard.py`](cartouche_guard/guard.py) refuses a file, or any file inside an archive, that:

- has the name or extension of game content or keys (`.nsp`, `.xci`, `.nca`, `.nso`, `prod.keys`, `romfs.img`...);
- carries the magic number of a Switch format (PFS0, HFS0, NSO0, NRO0, KIP1, IVFC, NCZ, game card and RomFS images);
- is a Mach-O image with a game's rewritten code (`__DM*` segments or `__dm*` sections, as nxnative's `gen_embed.py` makes them);
- is an IPA whose bundle identifier is not Cartouche's;
- is a catalog file with a URL, or a key that names a link or a download;
- is far larger than any build output of its kind.
