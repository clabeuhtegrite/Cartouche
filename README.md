# nxnative's games on players' iPhones

What the players of [Cartouche](https://github.com/clabeuhtegrite/Cartouche) measured of nxnative's games from 2026-11-10 to 2026-11-12, summed up for nxnative's developers each Thursday. How, and what is left out: [telemetry/README.md](https://github.com/clabeuhtegrite/Cartouche/blob/main/telemetry/README.md#nxnatives-page).

210 game sessions from 36 installs, 50.8 hours of play. 0 of the 177 sessions that count name their nxnative commit. Every line, and every figure, sums up at least 3 installs: a smaller group is left out, and a figure fewer installs gave shows –.

Set apart: 22 sessions on iPhones whose GPU reads no BC texture (A16 and older), which nxnative refuses, from 3 installs; sessions whose game process ran without Increased Memory Limit, which is Cartouche's doing, from fewer than 3 installs.

## By game

| Game | nxnative | Installs | Sessions | Hours | Target fps | FPS median | FPS slowest 5% | Frame p99 ms | Stutters a minute | Waiting for shaders | Shader stall ms a minute | Prepare s | Peak MiB | Reached serious heat | Crashed | Failed to boot | Out of memory | Drew no frame |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Mario Kart World `0400C3F00006E000` | not said | 7 | 14 | 0.7 | 60 | 32.2 | 23.9 | 147.5 | 159 | 41% | 12,375 | 0.1 | 4,977 | 2 of 14 | 3 | 1 | 0 | 3 |
| The Legend of Zelda: Ocarina of Time `0400486024DEC000` | not said | 6 | 26 | 2.8 | 60 | 38.1 | 24.4 | 41.3 | 21 | 9% | 119 | 78.6 | 4,860 | 10 of 26 | 0 | 0 | 0 | 4 |
| Super Mario Bros. Wonder `010015100B514000` | not said | 6 | 23 | 1.9 | 60 | 59.0 | 35.8 | 23.6 | 32 | 49% | 1,188 | 0.3 | 3,682 | 2 of 23 | 0 | 0 | 0 | 2 |
| Pokémon Legends: Z-A `0100F43008C44000` | not said | 3 | 8 | 1.0 | 30 | 29.8 | 28.0 | 42.2 | 29 | 19% | 1,067 | 0.6 | 2,563 | 0 of 8 | 0 | 0 | 0 | 2 |

## By game and model

| Game | Model | nxnative | Installs | Sessions | Hours | Target fps | FPS median | FPS slowest 5% | Frame p99 ms | Stutters a minute | Waiting for shaders | Shader stall ms a minute | Prepare s | Peak MiB | Reached serious heat | Crashed | Failed to boot | Out of memory | Drew no frame |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Mario Kart World `0400C3F00006E000` | `iPhone19,4` | not said | 4 | 9 | 0.6 | 60 | 32.2 | 23.9 | 147.2 | 83 | 42% | 5,933 | – | 5,018 | 2 of 9 | 3 | 0 | 0 | 1 |
| The Legend of Zelda: Ocarina of Time `0400486024DEC000` | `iPhone19,4` | not said | 3 | 20 | 1.9 | 60 | 39.8 | 22.9 | 31.0 | 25 | 7% | 239 | 0.9 | 4,888 | 10 of 20 | 0 | 0 | 0 | 4 |
| Super Mario Bros. Wonder `010015100B514000` | `iPhone19,4` | not said | 3 | 14 | 1.4 | 60 | 59.6 | 4.0 | 22.8 | 29 | 43% | 1,070 | – | 3,763 | 2 of 14 | 0 | 0 | 0 | 1 |
| Mario Kart World `0400C3F00006E000` | `iPhone18,2` | not said | 3 | 5 | 0.1 | 60 | – | – | – | – | – | – | – | – | 0 of 5 | 0 | 1 | 0 | 2 |

## By game and nxnative commit

No game was played from one nxnative commit on 3 installs or more.

## Crashes

No game crashed with one signal on 3 installs or more.

## Devices

The installs that started Cartouche, as each last did: 92 installs.

- Models: `iPhone19,4` 29, `iPhone18,2` 12, `iPhone18,3` 9, `iPhone15,4` 4, `iPhone16,2` 4, `iPhone18,1` 4, `iPhone19,2` 4, `iPad13,16` 3, `iPhone18,4` 3; 20 installs on 16 other models.
- iOS: 26.5 3, 26.6 4, 27.0 20, 27.2 48, 27.3 16.
- The memory limit iOS sets for Cartouche: 8,192 MiB on 42, 6,144 MiB on 34, 4,096 MiB on 7, 12,288 MiB on 4.
- iPhones whose GPU reads no BC texture (A16 and older): 9 installs.

## Builds on players' Macs, by nxnative commit

Cartouche Builder builds players' games with nxnative's build script, on their Macs.

| nxnative | Macs | Built | Failed | Where they failed |
| --- | --- | --- | --- | --- |
| `0c078130f6db` | 6 | 5 | 10 | other steps 10 |
| `786715256f37` | 6 | 0 | 10 | app build 7, other steps 3 |
| `547c5db647a2` | 4 | 14 | 3 | other steps 3 |
| `ccd834e06a39` | 4 | 0 | 24 | app build 17, other steps 7 |
| `5f6f162257f5` | 3 | 0 | 3 | other steps 3 |

## How it is summed up

- An install is one copy of Cartouche on one iPhone or iPad, under a random number it changes every 13 months or when its player erases what it sent: a player who installs Cartouche again is a new install. A Mac is one copy of Cartouche Builder. Neither number is ever written here.
- Each figure is the median of each install's own median, so that each install counts once however much it played; the peak is each install's highest, of its sessions that drew a frame. Stutters waiting for shaders are a share of all the stutters of the line.
- FPS slowest 5% is the rate of the slowest 5% of a session's time: the frame rate of each `[nvn] power` line, over its 300 frames, weighted by how long they lasted as nxnative timed them. A window that spans a loading, a pause or the time the game was left behind Cartouche's console counts at its own rate, so a few long sessions can bring it down: read it beside the median and the frame p99. Stutters and the shader stall are per minute of the whole session.
- The figures come from the lines nxnative writes in `log.txt`, which Cartouche reads after each session ([CartoucheGameLog.swift](https://github.com/clabeuhtegrite/Cartouche/blob/main/launcher/Sources/CartoucheGameLog.swift)): the `[nvn]` timing, on-screen and power lines, `[longframe]`, `pipeline prepare`, the memory and thermal lines, `CRASH sig=` and `[RED] boot:`. A session's commit is the first 12 digits of `DMCommit` in the game's `Info.plist`; Cartouche 0.11.2 and before did not send it. Target fps is the rate most of the line's sessions asked for.
- Reached serious heat: the sessions iOS put in its serious thermal state. Drew no frame: the session ended before nxnative's first summary line, whatever its end.
- A session counts once, as last sent; a copy of another region counts for its game.
- nxnative, Models: the commit, or the model, most installs of the line ran, when at least 3 did, and how many others; else only how many. A Mac counts as an install does: a step of a build shows when at least 3 Macs failed at it.
- Builds: the Macs whose Cartouche Builder follows a fork of nxnative are left out, and so are the builds the player stopped and the errors of Cartouche Builder's own code. Where they failed is nxnative's stage.
