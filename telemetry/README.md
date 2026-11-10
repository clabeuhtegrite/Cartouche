# Telemetry server

Cartouche sends what its players' games measured to a server of the project's own: a Cloudflare Worker, [`worker.js`](worker.js), and its D1 database, [`schema.sql`](schema.sql), created in the EU jurisdiction, where it is stored and run. Telemetry is on unless the player turns off **Game measurements** on the System page ([decision 34](../docs/decisions.md)); what it sends, and what it never sends, is in [docs/privacy.md](../docs/privacy.md). The app's side is [`CartoucheTelemetry.swift`](../launcher/Sources/CartoucheTelemetry.swift), the report format [`CartoucheTelemetryReport.swift`](../launcher/Sources/CartoucheTelemetryReport.swift) and the reading of a game's log [`CartoucheGameLog.swift`](../launcher/Sources/CartoucheGameLog.swift).

The Worker has no dependency and no build: the file is deployed as it is.

## Routes

- `POST /v1/reports` takes `{"reports": [...]}`, up to 25 reports in 64 KiB, and answers `{"accepted": n, "refused": m}`. Cartouche then drops them from its queue, the refused ones too, which would never be taken.
  - 400 or 413: not a batch of reports. Cartouche drops it as well.
  - 429 with `Retry-After: 60`: the address sent more than 120 requests in the minute. The count is kept in the Worker's memory only, never written.
  - 503 with `Retry-After: 3600`: the database is unavailable, or past its daily limit. Cartouche keeps its reports and tries again later.
- `POST /v1/forget` takes `{"install": "<number>"}` and deletes every report of that copy of Cartouche, and its count of the day: **Erase what this iPhone sent** on Cartouche's Game measurements page. Cartouche then takes a new number.
- `GET /` answers `Cartouche telemetry`, to check that it runs.

## What the server keeps

Each report is checked field by field and kept as the server rebuilt it: a field it does not know, or whose value is not of the form it expects, is left out, and a report without what every report has is refused: `schema`, `kind`, `id`, `seq`, `install`, `cartouche`, `device` and `ios`, with `session`, `minutes` and `reader` for a session and `name` for an event. A report over 8 KiB is refused. So nothing the app did not mean to send can be kept, such as a path or a line of a log.

- `reports`: one row per report, its `id` once whatever the times it is sent. The report itself is `body`, and the columns beside it are what queries read: `kind`, `install`, `day`, `seq`, `cartouche`, `device`, `ios`, `game`, `name` and `session`. `day` is the day the server received it, in UTC: there is no time, and no address.
- `daily`: how many reports each copy of Cartouche sent each day, for its cap of 2,000 a day; the counts of the days before yesterday go.

Every day at 03:17 UTC, the reports older than 25 months go.

## Reports

Every report carries `schema` (1), `kind`, a random `id` of its own, `seq`, the number of the report from this copy of Cartouche, and its context: `install`, the random number of this copy of Cartouche, new every 13 months and when the player erases what it sent; `cartouche`, its version; `device`, the model identifier, such as `iPhone19,4`; `ios`; `language`, the one Cartouche shows; `memoryLimitMiB`, the limit iOS sets for Cartouche and its games; and `increasedMemoryLimit`.

**A session** (`"kind": "session"`), one for each game session, read from the log nxnative writes for it after the game ended:

| Field | What it is |
| --- | --- |
| `session` | A random number of the session. A log read again because it grew comes back as a new report with the same `session`: the one with the highest `seq` counts. |
| `game`, `gameVersion` | The title ID, and the game's version as its build says. |
| `nxnative`, `nxnativeChanged` | The nxnative commit the game was built from, its first 12 digits, and whether the build had changes of its own. |
| `settings` | The game's nxnative settings, `DM_` keys only, with values of up to 32 letters, digits and `._:+-`. |
| `minutes` | How long the session lasted: from when its log was created to its last line. |
| `reader` | Which reading of nxnative's log made the measures (`CartoucheGameLogReader.version`). |
| `frames`, `targetFps` | The last frame counted, and the frame rate the game asked for. |
| `fps` | `median` and `low5`, the frame rate of the slowest 5% of the time, weighted by time. |
| `frameMs`, `gpuMs` | Milliseconds per frame and of GPU work: `p50`, `p95`, `p99`. |
| `overTargetPercent`, `droppedPercent` | Frames longer than one frame at the target rate; frames shown late or not shown. |
| `stutters` | Frames clearly longer than those before them: `count`, `perMinute`, and what they waited for: `shaders`, `textures`, `other`. |
| `shaderStallMsPerMinute` | What the game waited for new pipelines and shader libraries. |
| `prepare` | The pipeline preparation before the first frame: `seconds`, `lines`. |
| `cpu`, `gpuBusyMsPerSecond` | `watts`, `percent` (100 is one core), `performanceCoresPercent`; the GPU's busy time. |
| `thermal`, `lowPowerMinutes` | Minutes in each thermal state iOS reports, `seriousAfterMinutes`; minutes in Low Power Mode. |
| `memory`, `guestFile` | `peakMiB` (and `exactPeak`, the system's own peak), `gpuPeakMiB`, `lowestHeadroomMiB`; whether nxnative kept the game's memory in a file. |
| `upscaler` | `metalfx` or `bilinear`, and its `gpuMs`. |
| `audioUnderrunsPerMinute`, `display`, `dlc` | Audio underruns; `tv` and `foldSplit`, the iPhone Duo's fold between picture and controls; whether the game loaded downloadable content. |
| `end` | How the session ended: `kind` (`crash`, `boot-failed`, `memory-likely`, `unknown`), and for a crash its `signal` and where, as module and offset: `pc`, `lr`. |

A value the log does not have is left out.

**An event** (`"kind": "event"`), from Cartouche itself: a `name`, the `game` it is about if any, and up to 24 `fields` of short text, numbers and yes or no.

| Name | When | Fields |
| --- | --- | --- |
| `app.opened` | Each start of Cartouche. | `games`, `setUp`, `storage` and `saves` (the kind of storage, or `none`), `signatureDays` |
| `app.updated` | The first start of a new version. | `from`, `to` |
| `signature.renewed` | The signature lasts longer than it did. | `daysLeft` |
| `game.installed` | A game installed or updated. | `version`, `nxnative` |
| `error` | An error Cartouche reported. | `origin`, what Cartouche was doing; `error`, the domains and codes of the error and those under it, never its words; `background` |

## Game sheets

Each Thursday, the Game measurements workflow ([`.github/workflows/measurements.yml`](../.github/workflows/measurements.yml)) sums up the sessions of the 28 days before into the results of the game sheets in [`catalog/games/`](../catalog/README.md), with [`sheets.py`](sheets.py), in time for Friday's version:

- For each sheet, and each iPhone model at least three iPhones played the game on, one result. A copy of another region counts for its game, and a session sent again counts once, at its highest `seq`. A model fewer iPhones played the game on gets no result, and a figure fewer than three iPhones measured is left out: the sheets show figures of several iPhones, never of one.
- Its figures are medians of each iPhone's own median, so that each iPhone counts once, however much it played: the frame rate, that of the slowest 5% of the time, the stutters a minute and the memory peak, each iPhone's highest. With them, how many sessions ended badly: crashed, never drew a frame, or ran out of memory. They are in its `measured`, and said in its note.
- Its status: `does-not-run` when no session drew a frame; `boots` when half of the sessions or more ended badly; `playable-with-issues` when a tenth of them or more did, or the frame rate is under 90% of the rate the game asks for, or that of the slowest 5% of the time under 75% of it; `playable` otherwise.
- Its engine is the nxnative build most sessions ran, and how many others did; its iOS the version most of the iPhones run.

The results testers wrote stay as they are. A measured result is replaced by its model's new one, and stays while its model has none. The sheets that changed go on the branch `catalog-measurements`, whose pull request goes through CI before it is merged; the job summary links it, with how many sessions and iPhones were summed up. The workflow reads the database with the same secrets as the deploy, and does nothing without them.

## Deploy

[`.github/workflows/telemetry.yml`](../.github/workflows/telemetry.yml) tests the server on each pull request that changes it, and deploys it from `main` with [`deploy.sh`](deploy.sh), which calls Cloudflare's API with curl and jq: the database, created in the EU jurisdiction if it is not there yet; `schema.sql`, whose every statement runs again without harm; the Worker, with the database bound as `DB` and no logs kept; its `workers.dev` address; and its daily run. The job summary gives the address, which goes in [`app/config.env`](../app/config.env) as `CARTOUCHE_TELEMETRY_URL`: a build with none sends nothing.

The deploy takes two secrets of the repository's environment `cloudflare`, and does nothing while they are not set:

- `CLOUDFLARE_API_TOKEN`: a token of the account with **Account › Workers Scripts › Edit** and **Account › D1 › Edit**;
- `CLOUDFLARE_ACCOUNT_ID`: the account's ID.

Run the workflow by hand for a first deploy once they are set. The free plan is enough: 100,000 requests and 100,000 rows written a day.

## Tests

```sh
node --test telemetry/test/worker.test.js            # the Worker, with a stand-in for D1
python3 -m unittest discover -s telemetry/test -v    # the database on SQLite; the deploy and the weekly sum against a stand-in for Cloudflare's API
```

[`test/app-reports.json`](test/app-reports.json) holds a report of each kind as Cartouche makes it, with every field: the launcher's tests check that Cartouche makes them so ([`CartoucheTelemetryReportTests.swift`](../launcher/Tests/CartoucheCoreTests/CartoucheTelemetryReportTests.swift)), and the Worker's that it keeps every field of them. [`app/tests/test_telemetry.py`](../app/tests/test_telemetry.py) checks that the server's address goes from `app/config.env` into the app, and that the app posts to the routes the Worker serves.
