# The installer's tests

Everything the Cartouche Installer does with an iPhone, Apple, GitHub and the computer's keychain is tested here, with none of them: each test starts the installer against fakes of all of them, in memory and on `127.0.0.1`. No test signs in to an Apple ID, reaches the network, needs an iPhone or touches the computer's keychain, so they all run on any computer and in CI, on a Mac and on Windows ([installer.yml](../../../.github/workflows/installer.yml)).

```
cd installer
npm ci && npm run build                                  # the window, which the window's tests build in
cd src-tauri
cargo test --locked                                      # everything but the window, about 20 s
cargo test --locked --test installer pairing::           # one part
CARTOUCHE_TEST_LOG=1 cargo test --test installer <name>  # with what the installer and the fakes did
cargo test --locked --features ui-tests --test ui        # the window, clicked through, about 15 s
cargo test --features ui-tests --test ui first_install   # one scenario
CARTOUCHE_UI_CAPTURES=/tmp/captures cargo test --features ui-tests --test ui   # with pictures of the window
```

On Linux, the window's tests need a display, `xvfb-run -a cargo test --features ui-tests --test ui` on a computer without one, and the WebKitGTK libraries of [the installer's README](../../README.md#developing); their pictures, ImageMagick's `import`.

## What is tested

| Where | What |
| --- | --- |
| [`installer/`](installer) | The installer as its window drives it: each test calls the commands the window calls, with the same arguments, answers the two-factor code and the certificates to revoke as a person does in the window, by the same commands, and looks at what the iPhone, Apple, GitHub and the keychain were left with. By step: [`pairing.rs`](installer/pairing.rs) (listing the iPhones, *Trust This Computer?*, the pairing kept), [`sign_in.rs`](installer/sign_in.rs) (passwords, codes, a code typed while another thread holds Tauri's event listeners, locked and under-18 accounts, the anisette server, Apple not answering), [`download.rs`](installer/download.rs) (Cartouche's source and its IPA, checked against it), [`install.rs`](installer/install.rs) (signed and installed as iOS checks it, with its App ID, Increased Memory Limit, certificate and pairing file, the certificates to revoke, updated, refused, cut short), [`keychain.rs`](installer/keychain.rs) (a computer without a keychain, and the setting that keeps nothing in it), [`own_certificate.rs`](installer/own_certificate.rs) (the player's own certificate and profile in place of an Apple ID: signed on the computer, the certificate handed to Cartouche sealed, and each certificate, profile or password refused before anything is installed). |
| [`ui/`](ui/main.rs) | The window itself, built as it ships, in the system's webview: scenarios clicked through as a person does, in English and in French, the texts read from the window's own translations. The first install, an install where everything goes wrong once (no iPhone, GitHub down, *Don't Trust*, a wrong password, a wrong code, a download cut), a computer without a keychain, and an install with the player's own certificate, its file dialogs answering with the files the scenario chose (`ui.choose_files`). Each scenario runs in a process of its own, while another thread keeps Tauri's event listeners busy, and each step reports through a command of the tests' own plugin. With `CARTOUCHE_UI_CAPTURES` set to a folder, the scenarios also take pictures of the window as the system draws it (`ui.capture`): of the Apple Account's step in the first install, and of the certificate's, as it opens and with both files chosen, in the install with the player's own; [installer.yml](../../../.github/workflows/installer.yml) keeps them with the run, *installer-window-captures-macOS* and *-Windows*, and for a branch of this repository on the branch `installer-captures/<branch>`, in `macOS/` and `Windows/`, for a change to the window to be seen on both before it merges. |
| [`translations.rs`](translations.rs) | Every text the window names exists in English, and French has each with the same `{{values}}`, links and platforms. |
| [`system_environment.rs`](system_environment.rs) | The app's own environment lists the iPhones and connects to them through the same usbmuxd, `USBMUXD_SOCKET_ADDRESS` included. |
| `src/` | Cartouche's source read and checked, the bundle identifier of an IPA, and each error the installer gives known to the window ([`errors.tsx`](../../src/errors.tsx)) as it serializes it. |

## The fakes

They are the crate [`cartouche-installer-fakes`](../fakes), built only for the tests, of crates the installer already builds with.

- **The iPhone** (`FakeIphone`, behind `FakeUsbmuxd`): usbmuxd's protocol, on a port of its own; lockdown in TLS with the keys of its pair record; the remote pairing of iOS 17.4 and later, which asks *Trust This Computer?* (`Trust::Accept`, `Refuse` or `Never`, for a person who never answers); AFC, house_arrest into an app's Documents, and an installation proxy that installs an app only once it has checked its signature, its provisioning profile (one for this iPhone, or an enterprise one for every iPhone) and its entitlements as iOS does ([`verify.rs`](../fakes/src/iphone/verify.rs)). An iPhone 17 Pro on iOS 26, or one on iOS 17.3, before the remote pairing.
- **Apple** (`FakeApple`): GrandSlam's sign-in with SRP, the two-factor code on a trusted device or by text message, app tokens and anisette provisioning, and the developer services: teams, devices, certificates, App IDs, app groups, profiles and Increased Memory Limit. isideload reaches it through its proxy setting, every request sent to `{proxy}{the request's URL}`. A failure can be given to the next request of an operation (`fail_next`): a developer error code, or an HTTP status. And what a paid account's developer website gives a player who signs with a certificate of their own (`own_signing`): a .p12 under a password and its profile, a wildcard App ID with the team's keychain groups and Increased Memory Limit, each part of them to change (an expired certificate, another iPhone, a profile for another app…).
- **The anisette server** (`FakeAnisette`): the remote v3 protocol, a machine provisioned with Apple over a WebSocket, then the headers it signs Apple's requests with.
- **GitHub** (`FakeGithub`): Cartouche's source on raw.githubusercontent.com and its IPA in the releases on github.com, redirected to the assets' host. It is an HTTPS proxy with certificates of the tests' own authority, which only the tests' HTTP client trusts, so the installer keeps its own URLs and the checks of their addresses. Its IPAs are Cartouche as `app/scripts/package.sh` assembles it, or any other app, with small Mach-O executables isideload signs and the iPhone checks ([`ipa.rs`](../fakes/src/ipa.rs)).
- **The keychain** (`MemoryKeychain`): the keyring crate's credentials in memory. A service can be broken, as on a computer without a keychain or with a locked one.

The installer takes what it reaches from an [`Environment`](../src/environment.rs): usbmuxd's address, the HTTP client, the proxy to Apple and the keychain service. The app runs with the system's (`Environment::system()`), the tests with the fakes', built by [`configure`](../src/lib.rs) on Tauri's mock runtime, or on the real one for the window.

## Adding a test

Add it to the file of its step, from a [`Harness`](installer/harness.rs): `Harness::new()` is a computer with a keychain, an iPhone 17 Pro plugged in, which trusts it over USB and has no pairing with the installer yet, and the Apple ID of a free account that asks for a code; `Harness::start(Setup { .. })` changes them, and `h.publish_cartouche()` puts a new release of Cartouche on GitHub. Then do what the window does, `h.select_device()`, `h.sign_in(false)`, both with `h.ready()`, `h.install()` (or `h.sign_in_later(..)`, `h.install_later()`, to answer the installer's questions yourself after `h.answer_by_hand()`: `h.type_code_now(..)`, `h.choose_certificates_now(..)`), `h.install_own(&files)` with the player's own certificate (`h.own_signing().write(&h.dir)`), or any command with `h.invoke(..)`, and check what came of it: the answer (`error_type(&error)` for an error), the steps and progress the window showed (`h.steps(..)`, `h.progress(..)`), and the fakes' state (`h.iphone.state()`, `h.apple.state()`, `h.github.state()`, `h.keychain`). `h.report()` tells all that, for a failure's message.

- A fix comes with a test that fails without it.
- What the window sends to the installer goes by a command, never an event: Tauri hands an event to Rust only when no other thread holds its event listeners at that instant, else sets it aside until a later event that has a listener in Rust, which may never come ([`questions.rs`](../src/questions.rs)). `h.hold_event_listeners()` holds them, for a test of such an instant.
- Take what a test needs from a fake's `state()` in a statement of its own: it holds the fake's lock until the statement ends, and two in the same statement wait for each other.
- The window's scenarios find what to click by its text in the translations (`ui.t("…")`), never by their English words, so that they run in both languages.
- On Windows, the tests take the app's resources, its manifest among them, from [`build.rs`](../build.rs): without the common controls it asks for, Windows does not start them.
