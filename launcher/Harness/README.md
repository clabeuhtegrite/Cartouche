# Launcher harness

The launcher's own code, all of [`launcher/Sources`](../Sources) but the root view, built into a small app of the iOS Simulator on top of LiveContainer, where its tests do what a player does: install a game from an IPA, from Files, from another app or from the games folder, replace it with another build, start it, behind the console or in Cartouche's place, pause it, quit it, have iOS stop it, copy it to the games folder, and uninstall it, with Cartouche's setup, its telemetry and the saves along the way. Each test then checks what the launcher and LiveContainer left: the files, the preferences, the data folder, what the console shows, what the player reads.

No real game is involved, nor any file of one: the IPAs are written by the tests, byte for byte, as nxnative and zip make them, with their `romfs.img` or with the `romfs.id` of a game built with its files apart ([`Tests/HarnessIPA.swift`](Tests/HarnessIPA.swift)).

## What is real, and what is stood in

Real, as Cartouche builds them:

- every file of `launcher/Sources` but `CartoucheRootView.swift`, compiled with `CARTOUCHE_HARNESS`;
- LiveContainer's `LCAppModel.swift`, `LCContainer.swift`, its unpacker (`unarchive.m`, on the iPhone's libarchive) and its texts (`Localizable.xcstrings`), which [`harness.sh`](harness.sh) copies from `app/LiveContainer` with every patch of [`app/patches/livecontainer`](../../app/patches/livecontainer) applied, as `app/scripts/prepare.sh` does;
- the catalogue, as `package.sh` copies it into the app.

Stood in, in [`Sources/`](Sources):

- LiveContainer's Objective-C, in Swift, line for line where the launcher reads or writes what it leaves: `LCAppInfo` with its `Info.plist` and `LCAppInfo.plist` and the steps of `patchExecAndSignIfNeed` ([`HarnessAppInfo.swift`](Sources/HarnessAppInfo.swift)), its folders, its list of apps as it reads it at launch, its preferences and where it keeps its certificate ([`HarnessLiveContainer.swift`](Sources/HarnessLiveContainer.swift));
- what the Simulator cannot do, which the harness does its own way and records: zsign's signature, and whether iOS accepts the certificate; a start in Cartouche's place, which quits the app (`HarnessLC.launches`); the game's process behind the console, whose `AppSceneViewController` goes through LiveContainer's steps on its threads, writes the game's memory where Cartouche reads it and posts a controller's Home button, opens the game's scene on a TV, and which iOS may kill ([`HarnessScenes.swift`](Sources/HarnessScenes.swift));
- the network: every request of the app goes to [`HarnessNetwork.swift`](Sources/HarnessNetwork.swift), which records it and answers as each test says, or not at all, as without network. The [`Info.plist`](Info.plist) points Cartouche's servers at addresses of the harness's own;
- the iPhone: one whose GPU reads BC-compressed textures and whose signature carries Increased Memory Limit, with no TV, unless a test says otherwise. A test hands Cartouche a TV as iOS does, a window with Cartouche's TV screen in the harness's own scene; it says that iOS captures the iPhone's screen, as iOS 27 does to copy it to a TV it has not handed Cartouche or to record it, with the capture state of that scene, and where the sound goes.

The knobs a test sets are in `HarnessLC` (signing, the certificate, the game's process, the GPU, the sound on a TV), and are reset before each test, with LiveContainer's folders, the app group and the launcher's own state ([`Tests/HarnessCase.swift`](Tests/HarnessCase.swift)). The main thread must never be held more than 1.5 s, where the console draws: a watchdog fails the test that held it, and says what the launcher was doing as the wait began and ended, and where the main thread was a second into it, its frames read from another thread. Before the first test, the harness has iOS make a bookmark of a folder once: the simulator's first one waits on a file provider starting up, which an iPhone did long before the player picks a folder, and the watchdog watches Cartouche, not the simulator. For the same reason the app writes its standard error to a file of its own ([`Sources/HarnessStandardError.swift`](Sources/HarnessStandardError.swift)), as an app the player starts writes it to `/dev/null`: as Xcode runs an app, os_log mirrors every line, NSLog's included, to standard error, which Xcode reads, and a line logged from the main thread waited there 19.8 s once, at the start of a run on a busy Mac of the CI, until Xcode read it ([`Tests/LoggingTests.swift`](Tests/LoggingTests.swift)). A test that takes more than 20 seconds says in the log where its time went: setting up, waiting for what the test before left, its longest wait and what for, cleaning up.

## The tests

- [`InstallTests`](Tests/InstallTests.swift): an install from an IPA, step by step, a game installed again over another build with its saves and settings, uninstalled with or without its saves, an app that is no game, signing that fails or leaves files out, an encrypted app, IPAs that are no IPA, cut short or damaged, without an app or without `Payload`, an app whose `Info.plist` cannot be read or gives no bundle identifier, and the question before an install on a GPU nxnative refuses.
- [`PlayTests`](Tests/PlayTests.swift): a start in Cartouche's place: the data folder, nxnative's switch for its settings screen in `env.txt`, the game's language, a game signed with an old certificate, a certificate iOS no longer accepts.
- [`BehindConsoleTests`](Tests/BehindConsoleTests.swift): a game behind the console, the Home button, Quit, a game iOS stops, near its memory limit or without Increased Memory Limit, LiveProcess missing or refusing, which leaves nothing of the start there, the iPhone that may lock again as the console shows or kept awake by an install, another game in its place.
- [`UprightTests`](Tests/UprightTests.swift): which ways the screen of a game behind the console turns on an iPhone: upright too for a game that lays itself out upright, as nxnative's built since 4 November 2026, sideways only for one built before, after a pause too.
- [`TVTests`](Tests/TVTests.swift): a TV while a game runs behind the console: the game's own scene there over its card, never the iPhone's screen, the game's screen sideways only while the game's picture is there, the card alone while the game is paused, a game without a scene for the TV, Cartouche in the background, the TV plugged in during the game and unplugged, the TV given back to iOS as the game ends, and the game hidden as soon as iOS copies the iPhone's screen, to a TV it has not handed Cartouche or to a recording, each said for what it is, unless the player shows it anyway; each step goes in the journal of a player's report.
- [`SetupTests`](Tests/SetupTests.swift): the built-in SideStore's certificate handed to LiveContainer, whether iOS accepts it, the Apple ID, the pairing file.
- [`TelemetryTests`](Tests/TelemetryTests.swift): what leaves the iPhone, what each answer of the server does, the player's switch, which stops a report already on its way, erasing what was sent, Cartouche's own events.
- [`UnpackTests`](Tests/UnpackTests.swift): LiveContainer's unpacker and Cartouche's reader on the same IPAs, in Zip64 or not, stored or deflated, with links, and what each does with an IPA cut short or damaged.
- [`StorageTests`](Tests/StorageTests.swift): the games folder and the saves folder, as a folder of the iPhone: the games listed, a game installed from there, copied there and installed again, its saves sent after a game and back with its next install.
- [`GameFilesApartTests`](Tests/GameFilesApartTests.swift): a game nxnative built with its files apart, `romfs.id` in its app and its `romfs.img` beside the IPA, installed from the games folder or from Files, without its image or with another, and a new build of it, which keeps the image the installed one holds, or needs another.
- [`LoggingTests`](Tests/LoggingTests.swift): the harness itself: what Cartouche logs never waits for Xcode to read it, its standard error being a file.

The storage servers themselves are tested against real ones by [`launcher/StorageTests`](../StorageTests/README.md), and the launcher's rules on their own by `swift test --package-path launcher`.

## Running it

On a Mac with Xcode and XcodeGen (`brew install xcodegen`), after `git submodule update --init app/LiveContainer`:

    launcher/Harness/harness.sh OUT                                     # every test
    launcher/Harness/harness.sh OUT CartoucheHarnessTests/InstallTests  # one class, or one test

It runs on an iPhone 17 Pro of the newest iOS of that Xcode, made if there is none. `OUT` receives the results (`CartoucheHarness.xcresult`), Xcode's log (`test.log`), what the app wrote to its standard error (`console.txt`, the launcher's NSLog lines among them) and `failures.txt`, the tests that failed and why. The [Launcher harness](../../.github/workflows/harness.yml) workflow runs it on every pull request that changes the launcher's sources, the harness, LiveContainer or its patches, or the catalogue, once for what the pull request changes in them, and on main after each merge that changes them.

## Adding a test

A test subclasses `HarnessCase`, runs on the main actor, and waits with `waitUntil`, never with a sleep on the main thread. Make the IPAs it needs with `HarnessIPA` and `HarnessZip`, never from a real game. A fix of the launcher comes with the test that failed without it.
