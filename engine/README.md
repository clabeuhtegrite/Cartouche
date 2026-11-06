# Engine

Cartouche runs games with [nxnative](https://github.com/seedds/nxnative), which turns a game's code into native code for the Apple chip. nxnative has no releases, so Cartouche follows its `main` branch at a pinned commit, as its [front-end guide](https://github.com/seedds/nxnative/blob/main/docs/frontends.md) recommends, and reads the `Front-ends:` lines of its commit messages when it moves the pin.

Pinned commit: [`nxnative.commit`](nxnative.commit).

## v1

Players build their game on a Mac with nxnative's own `scripts/build_ipa_from_nsp.py` and import the IPA into Cartouche. Nothing is built here.

## v2 (planned)

iOS has no linker, so the engine host cannot be linked on the phone. CI will build it here from nxnative's source for each supported game (`make GAME=<title ID>`), with nothing of the game in it, and publish it as an `engine-host` artifact. On the phone, Cartouche writes the game's rewritten modules into a framework, signs it, and the host loads it through `dm_set_game_image_header()`. The publish guard refuses any engine build that contains a game's rewritten code. Spike S4 in the [roadmap](../docs/roadmap.md) tests this first.

Spikes in progress: [S2](spikes/s2/README.md), nxnative's rewriter under CPython for iOS.
