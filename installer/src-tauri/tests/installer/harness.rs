//! The installer as its window drives it, with fakes all around: an iPhone
//! behind usbmuxd, Apple, an anisette server, GitHub and a keychain in
//! memory (README.md). Every test starts its own, and calls the commands
//! the window calls, with the same arguments.

use std::{
    collections::VecDeque,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex, Once,
        atomic::{AtomicU32, Ordering},
        mpsc,
    },
    time::Duration,
};

pub use cartouche_installer_fakes::{
    AccountConfig, FakeAnisette, FakeApple, FakeGithub, FakeIphone, FakeUsbmuxd, IphoneConfig,
    MemoryKeychain, Trust, TwoFactor,
    apple::{Failure, OwnFiles, OwnSigning},
    github::BUNDLE_ID,
    ipa::{CartoucheIpa, other_app_ipa},
};
use cartouche_installer_lib::Environment;
use idevice::usbmuxd::UsbmuxdAddr;
use serde_json::{Value, json};
use tauri::{
    Emitter, Listener, Manager, WebviewWindow,
    ipc::{CallbackFn, InvokeBody, InvokeResponse},
    test::{INVOKE_KEY, MockRuntime, mock_builder, mock_context, noop_assets},
    webview::InvokeRequest,
};
use tauri_plugin_store::StoreExt;

pub const EMAIL: &str = "camille.testeur@example.com";
pub const PASSWORD: &str = "Correct-Horse-7";
/// Where Cartouche's built-in SideStore reads the pairing file, in
/// Cartouche's container.
pub const PAIRING_FILE: &str = "Documents/SideStore/Documents/ALTPairingFile.mobiledevicepairing";
/// How long one command may take before the test fails: far more than any
/// takes against the fakes, far less than the installer's own waits (two
/// minutes for a code, five for the certificates).
const COMMAND_TIMEOUT: Duration = Duration::from_secs(100);

static COUNTER: AtomicU32 = AtomicU32::new(0);

/// A number no other harness of this run has.
fn next() -> u32 {
    COUNTER.fetch_add(1, Ordering::Relaxed)
}

/// What a test starts with, before it changes anything.
pub struct Setup {
    pub iphone: IphoneConfig,
    pub account: AccountConfig,
    /// false: every call to the keychain fails, as on a computer without
    /// one or with it locked.
    pub keychain_works: bool,
    /// false: nothing answers at usbmuxd's address, as on a PC without
    /// Apple's drivers.
    pub usbmuxd_running: bool,
}

impl Default for Setup {
    fn default() -> Self {
        Setup {
            iphone: IphoneConfig::iphone_17_pro(1),
            account: AccountConfig::new(EMAIL, PASSWORD),
            keychain_works: true,
            usbmuxd_running: true,
        }
    }
}

/// What the person at the window answers, when the installer asks.
#[derive(Default)]
struct Answers {
    /// Two-factor codes, in order; then the account's own.
    codes: VecDeque<String>,
    /// Answers to "Too many certificates": the serials to revoke, or None
    /// to cancel; then None.
    certificates: VecDeque<Option<Vec<String>>>,
    /// The test answers itself, when it chooses (`answer_by_hand`).
    by_hand: bool,
}

pub struct Harness {
    pub app: tauri::App<MockRuntime>,
    pub window: WebviewWindow<MockRuntime>,
    pub usbmuxd: FakeUsbmuxd,
    pub iphone: FakeIphone,
    pub apple: FakeApple,
    pub anisette: FakeAnisette,
    pub github: FakeGithub,
    pub keychain: MemoryKeychain,
    /// The keychain service of this test's entries: no other test's.
    pub keyring_service: String,
    pub team_id: String,
    pub account: AccountConfig,
    /// A folder of this test's own, for the IPAs it makes.
    pub dir: PathBuf,
    /// The app's identifier, which names its data folder.
    identifier: String,
    usbmuxd_addr: std::net::SocketAddr,
    events: Arc<Mutex<Vec<(String, Value)>>>,
    answers: Arc<Mutex<Answers>>,
    versions: Mutex<Vec<String>>,
}

/// A command sent, whose answer comes later.
pub struct Pending {
    cmd: String,
    rx: mpsc::Receiver<Result<Value, Value>>,
}

impl Pending {
    pub fn wait(self) -> Result<Value, Value> {
        self.wait_for(COMMAND_TIMEOUT)
    }

    pub fn wait_for(self, timeout: Duration) -> Result<Value, Value> {
        self.rx
            .recv_timeout(timeout)
            .unwrap_or_else(|_| panic!("{} did not answer within {timeout:?}", self.cmd))
    }

    /// The answer, if it came already.
    pub fn try_wait(&self) -> Option<Result<Value, Value>> {
        self.rx.try_recv().ok()
    }
}

/// Calls a command as the window does: its answer comes later.
fn invoke_on(window: &WebviewWindow<MockRuntime>, cmd: &str, args: Value) -> Pending {
    let (tx, rx) = mpsc::channel();
    let request = InvokeRequest {
        cmd: cmd.into(),
        callback: CallbackFn(0),
        error: CallbackFn(1),
        url: if cfg!(windows) { "http://tauri.localhost" } else { "tauri://localhost" }
            .parse()
            .unwrap(),
        body: InvokeBody::Json(args),
        headers: Default::default(),
        invoke_key: INVOKE_KEY.to_string(),
    };
    let webview: &tauri::Webview<MockRuntime> = window.as_ref();
    webview.clone().on_message(
        request,
        Box::new(move |_webview, _cmd, response, _callback, _error| {
            let _ = tx.send(match response {
                InvokeResponse::Ok(body) => Ok(body.deserialize::<Value>().unwrap_or(Value::Null)),
                InvokeResponse::Err(error) => Err(error.0),
            });
        }),
    );
    Pending { cmd: cmd.to_string(), rx }
}

/// Tauri's event listeners held by another thread (`hold_event_listeners`),
/// until this is dropped.
pub struct HeldListeners {
    release: mpsc::Sender<()>,
    unlistening: Option<std::thread::JoinHandle<()>>,
}

impl Drop for HeldListeners {
    fn drop(&mut self) {
        let _ = self.release.send(());
        if let Some(thread) = self.unlistening.take() {
            let _ = thread.join();
        }
    }
}

fn init_logging() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        // CARTOUCHE_TEST_LOG=1 shows what the installer and the fakes did,
        // under each test that fails.
        if std::env::var_os("CARTOUCHE_TEST_LOG").is_some() {
            let _ = tracing_subscriber::fmt()
                .with_max_level(tracing::Level::DEBUG)
                .with_test_writer()
                .try_init();
        }
    });
}

impl Harness {
    pub fn start(setup: Setup) -> Harness {
        init_logging();
        let n = next();
        let keychain = cartouche_installer_fakes::keychain::install();
        let keyring_service = format!("cartouche-installer-test-{}-{n}", std::process::id());
        if !setup.keychain_works {
            keychain.break_service(&keyring_service);
        }
        let (usbmuxd, apple, anisette, github) = tauri::async_runtime::block_on(async {
            (
                FakeUsbmuxd::start().await.expect("fake usbmuxd"),
                FakeApple::start().await,
                FakeAnisette::start().await,
                FakeGithub::start().await,
            )
        });
        let iphone = FakeIphone::new(setup.iphone);
        usbmuxd.plug(&iphone);
        let team_id = apple.add_account(setup.account.clone());
        let usbmuxd_addr = if setup.usbmuxd_running {
            usbmuxd.addr()
        } else {
            // A port nothing listens on any more.
            std::net::TcpListener::bind("127.0.0.1:0").and_then(|l| l.local_addr()).expect("free port")
        };
        // Its own data folder (the store, and the files without a keychain).
        let identifier = format!(
            "io.github.clabeuhtegrite.cartouche.installer.tests.p{}n{n}",
            std::process::id()
        );
        let (app, window) = build(&identifier, environment(&github, &apple, usbmuxd_addr, &keyring_service));

        let dir = std::env::temp_dir().join(format!("cartouche-installer-tests-{}-{n}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("test folder");

        let harness = Harness {
            app,
            window,
            usbmuxd,
            iphone,
            apple,
            anisette,
            github,
            keychain,
            keyring_service,
            team_id,
            account: setup.account,
            dir,
            identifier,
            usbmuxd_addr,
            events: Arc::default(),
            answers: Arc::default(),
            versions: Mutex::default(),
        };
        harness.record_events();
        harness.answer_questions();
        harness
    }

    pub fn new() -> Harness {
        Self::start(Setup::default())
    }

    /// Quits the installer and opens it again: the same computer, its
    /// keychain and data folder, the same iPhone and Apple ID.
    pub fn restart(&mut self) {
        self.close_store();
        let (app, window) = build(
            &self.identifier,
            environment(&self.github, &self.apple, self.usbmuxd_addr, &self.keyring_service),
        );
        let old = std::mem::replace(&mut self.app, app);
        self.window = window;
        drop(old);
        self.record_events();
        self.answer_questions();
    }

    fn close_store(&self) {
        // The store writes data.json a moment after a change: write it now,
        // and close it.
        if let Ok(store) = self.app.store("data.json") {
            let _ = store.save();
            store.close_resource();
        }
    }

    /// The Apple IDs the window lists as saved, from the store.
    pub fn saved_ids(&self) -> Vec<String> {
        let store = self.app.store("data.json").expect("store");
        store
            .get("ids")
            .and_then(|v| v.as_array().cloned())
            .unwrap_or_default()
            .iter()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect()
    }

    fn record_events(&self) {
        for name in [
            "operation_install_cartouche",
            "operation_place_cartouche_pairing",
            "2fa-required",
            "max-certs-reached",
        ] {
            let events = self.events.clone();
            self.app.listen_any(name, move |event| {
                let payload = serde_json::from_str(event.payload()).unwrap_or(Value::Null);
                events.lock().unwrap().push((name.to_string(), payload));
            });
        }
    }

    /// Answers the installer's questions as the window does: a code when it
    /// asks for one, and the certificates to revoke, each by its command,
    /// as soon as the question comes.
    fn answer_questions(&self) {
        for question in ["2fa-required", "max-certs-reached"] {
            let answers = self.answers.clone();
            let window = self.window.clone();
            let default_code = self.account.code.clone();
            self.app.listen_any(question, move |_| {
                let (cmd, args) = {
                    let mut answers = answers.lock().unwrap();
                    if answers.by_hand {
                        return;
                    }
                    if question == "2fa-required" {
                        let code = answers.codes.pop_front().unwrap_or_else(|| default_code.clone());
                        ("answer_two_factor_code", json!({ "code": code }))
                    } else {
                        ("answer_max_certs", json!({ "revoke": answers.certificates.pop_front().unwrap_or(None) }))
                    }
                };
                // Its answer comes later, from the command.
                let _ = invoke_on(&window, cmd, args);
            });
        }
    }

    /// The two-factor codes the person types, in order, before the right one.
    pub fn type_codes(&self, codes: &[&str]) {
        self.answers.lock().unwrap().codes.extend(codes.iter().map(|c| c.to_string()));
    }

    /// What the person answers to "Too many certificates".
    pub fn answer_certificates(&self, answer: Option<Vec<String>>) {
        self.answers.lock().unwrap().certificates.push_back(answer);
    }

    /// From now on, the questions wait for the test's own answers:
    /// `type_code_now`, `choose_certificates_now`.
    pub fn answer_by_hand(&self) {
        self.answers.lock().unwrap().by_hand = true;
    }

    /// The window's Submit, with this code: whether the installer was
    /// waiting for one.
    pub fn type_code_now(&self, code: &str) -> bool {
        self.invoke("answer_two_factor_code", json!({ "code": code })) == Ok(json!(true))
    }

    /// The window's Continue under "Too many certificates", with these to
    /// revoke (None: Cancel): whether the installer was asking.
    pub fn choose_certificates_now(&self, revoke: Option<Vec<String>>) -> bool {
        self.invoke("answer_max_certs", json!({ "revoke": revoke })) == Ok(json!(true))
    }

    /// Tauri's table of the event listeners in Rust, held by another thread
    /// until the guard is dropped: as at any instant another thread listens,
    /// unlistens or sends an event, the installer each time it logs a line.
    /// While it is held, Tauri sets aside each event sent, until some later
    /// event that has a listener in Rust.
    pub fn hold_event_listeners(&self) -> HeldListeners {
        // A listener whose state takes until the release to drop: Tauri
        // drops it when it is unlistened, holding its table.
        struct SlowToDrop {
            held: mpsc::Sender<()>,
            release: mpsc::Receiver<()>,
        }
        impl Drop for SlowToDrop {
            fn drop(&mut self) {
                let _ = self.held.send(());
                let _ = self.release.recv_timeout(COMMAND_TIMEOUT);
            }
        }
        let (held, held_rx) = mpsc::channel();
        let (release, release_rx) = mpsc::channel();
        let state = SlowToDrop { held, release: release_rx };
        let id = self.app.listen_any("held-listeners", move |_| {
            let _ = &state;
        });
        let (probe, probe_rx) = mpsc::channel();
        self.app.listen_any("held-listeners-probe", move |_| {
            let _ = probe.send(());
        });
        let handle = self.app.handle().clone();
        let unlistening = std::thread::spawn(move || handle.unlisten(id));
        held_rx
            .recv_timeout(Duration::from_secs(10))
            .expect("Tauri's event listeners held by another thread");
        let held = HeldListeners { release, unlistening: Some(unlistening) };
        // Held indeed: an event sent now is set aside.
        self.app.emit("held-listeners-probe", ()).expect("the probe");
        assert!(
            probe_rx.recv_timeout(Duration::from_millis(200)).is_err(),
            "Tauri handed over an event while another thread held its listeners"
        );
        held
    }

    pub fn invoke_later(&self, cmd: &str, args: Value) -> Pending {
        invoke_on(&self.window, cmd, args)
    }

    /// Calls a command as the window does, and waits for its answer: its
    /// value, or the error the window shows ({type, message}).
    pub fn invoke(&self, cmd: &str, args: Value) -> Result<Value, Value> {
        self.invoke_later(cmd, args).wait()
    }

    /// The devices the window lists: those that answered.
    pub fn devices(&self) -> Vec<Value> {
        let listed = self.invoke("list_devices", json!({})).expect("list_devices");
        listed
            .as_array()
            .expect("a list")
            .iter()
            .filter_map(|entry| entry.get("Ok").cloned())
            .collect()
    }

    /// The fake iPhone, as the window lists it.
    pub fn device(&self) -> Value {
        self.devices()
            .into_iter()
            .find(|d| d["udid"] == self.iphone.udid())
            .unwrap_or_else(|| panic!("the iPhone is not listed\n{}", self.report()))
    }

    /// Picks the iPhone in the window: pairs with it if need be.
    pub fn select_device(&self) -> Result<Value, Value> {
        let device = self.device();
        self.invoke("set_selected_device", json!({ "device": device }))
    }

    pub fn has_stored_pairing(&self) -> bool {
        let device = self.device();
        self.invoke("has_stored_rppairing", json!({ "device": device }))
            .expect("has_stored_rppairing")
            .as_bool()
            .expect("a boolean")
    }

    /// Signs in with the account's own email and password.
    pub fn sign_in(&self, save: bool) -> Result<Value, Value> {
        self.sign_in_as(&self.account.email.clone(), &self.account.password.clone(), save)
    }

    pub fn sign_in_as(&self, email: &str, password: &str, save: bool) -> Result<Value, Value> {
        self.sign_in_later(email, password, save).wait()
    }

    /// The window's Sign in, whose answer comes later.
    pub fn sign_in_later(&self, email: &str, password: &str, save: bool) -> Pending {
        self.invoke_later(
            "login_new",
            json!({
                "email": email,
                "password": password,
                "anisetteServer": self.anisette.url(),
                "saveCredentials": save,
            }),
        )
    }

    /// The window's Install button: the newest Cartouche from GitHub.
    pub fn install(&self) -> Result<Value, Value> {
        self.install_later().wait()
    }

    /// The same, whose answer comes later.
    pub fn install_later(&self) -> Pending {
        self.invoke_later("install_cartouche_operation", json!({ "ipaPath": null, "importedSigning": null }))
    }

    /// "Install from a file", with this IPA.
    pub fn install_file(&self, path: &Path) -> Result<Value, Value> {
        self.invoke(
            "install_cartouche_operation",
            json!({ "ipaPath": path.to_string_lossy(), "importedSigning": null }),
        )
    }

    /// A signing certificate and a profile of the player's own, for this
    /// iPhone: a wildcard App ID with Increased Memory Limit, of a paid
    /// account Apple's developer website made them for.
    pub fn own_signing(&self) -> OwnSigning {
        self.apple.own_signing(&[self.iphone.udid()])
    }

    /// What the window does as soon as a profile is chosen, under "I have a
    /// signing certificate (.p12)": it checks it, and keeps what it said.
    pub fn check_profile(&self, files: &OwnFiles) -> Result<Value, Value> {
        self.invoke("inspect_signing_profile", json!({ "profilePath": files.profile.to_string_lossy() }))
    }

    /// The window's Install button with the player's own certificate: the
    /// profile checked, then installed with the .p12 and its password.
    pub fn install_own(&self, files: &OwnFiles) -> Result<Value, Value> {
        let checked = self.check_profile(files)?;
        self.install_checked(files, &checked, None)
    }

    /// The same, with the profile as `checked` said it was, from an IPA
    /// file with `ipa`.
    pub fn install_checked(&self, files: &OwnFiles, checked: &Value, ipa: Option<&Path>) -> Result<Value, Value> {
        self.invoke(
            "install_cartouche_operation",
            json!({
                "ipaPath": ipa.map(|path| path.to_string_lossy()),
                "importedSigning": {
                    "p12Path": files.p12.to_string_lossy(),
                    "profilePath": files.profile.to_string_lossy(),
                    "password": files.password,
                    "profileSha256": checked["sha256"],
                },
            }),
        )
    }

    /// The iPhone picked, signed in: what the window has before Install.
    pub fn ready(&self) {
        self.select_device()
            .unwrap_or_else(|e| panic!("pairing failed: {e}\n{}", self.report()));
        self.sign_in(false)
            .unwrap_or_else(|e| panic!("sign-in failed: {e}\n{}", self.report()));
    }

    /// A version of Cartouche no other test of this run publishes: isideload
    /// unpacks an IPA in the computer's temporary folder, by its name.
    pub fn new_version(&self) -> String {
        let version = format!("0.{}.{}", 100 + std::process::id() % 800, next());
        self.versions.lock().unwrap().push(version.clone());
        version
    }

    /// Publishes a new release of Cartouche on the fake GitHub, and gives
    /// its version.
    pub fn publish_cartouche(&self) -> String {
        let version = self.new_version();
        self.github.publish(&version, CartoucheIpa::new(&version).build());
        version
    }

    /// Writes an IPA in this test's folder, under a name of its own.
    pub fn write_ipa(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.dir.join(format!("{name}-{}.ipa", next()));
        std::fs::write(&path, bytes).expect("write IPA");
        path
    }

    /// The installer's own data folder.
    pub fn data_dir(&self) -> PathBuf {
        self.app.path().app_data_dir().expect("app data dir")
    }

    /// Every event of that name, in order.
    pub fn events(&self, name: &str) -> Vec<Value> {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter(|(n, _)| n == name)
            .map(|(_, payload)| payload.clone())
            .collect()
    }

    /// The steps of an operation as the window shows them: ("started",
    /// "download"), ("finished", "download")…, progress aside.
    pub fn steps(&self, operation: &str) -> Vec<(String, String)> {
        self.events(&format!("operation_{operation}"))
            .iter()
            .filter(|u| u["updateType"] != "progress")
            .map(|u| {
                (
                    u["updateType"].as_str().unwrap_or("").to_string(),
                    u["stepId"].as_str().unwrap_or("").to_string(),
                )
            })
            .collect()
    }

    /// The fraction done each "progress" of the step reported.
    pub fn progress(&self, operation: &str, step: &str) -> Vec<f64> {
        self.events(&format!("operation_{operation}"))
            .iter()
            .filter(|u| u["updateType"] == "progress" && u["stepId"] == step)
            .filter_map(|u| u["progress"].as_f64())
            .collect()
    }

    /// The error the operation's failed step shows.
    pub fn failure(&self, operation: &str) -> Option<(String, Value)> {
        self.events(&format!("operation_{operation}"))
            .iter()
            .find(|u| u["updateType"] == "failed")
            .map(|u| (u["stepId"].as_str().unwrap_or("").to_string(), u["extraDetails"].clone()))
    }

    /// Everything the fakes saw, for a test that fails to tell why.
    pub fn report(&self) -> String {
        let github = self.github.state();
        format!(
            "iPhone: {:#?}\nApple: {:#?}\nanisette: {:#?}\nGitHub: {:#?} (refused: {:?})\nevents: {:#?}",
            self.iphone.log(),
            self.apple.log(),
            self.anisette.state().log,
            github.requests,
            github.refused,
            self.events.lock().unwrap(),
        )
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.close_store();
        if let Ok(dir) = self.app.path().app_data_dir() {
            let _ = std::fs::remove_dir_all(dir);
        }
        let temp = std::env::temp_dir();
        for version in self.versions.lock().unwrap().iter() {
            let _ = std::fs::remove_file(temp.join(format!("Cartouche-{version}.ipa")));
            let _ = std::fs::remove_dir_all(temp.join(format!("Cartouche-{version}.ipa_extracted")));
        }
        if let Ok(entries) = std::fs::read_dir(&self.dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                let _ = std::fs::remove_dir_all(temp.join(format!("{name}_extracted")));
            }
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// The error's type, as the window reads it to pick its suggestions.
pub fn error_type(error: &Value) -> &str {
    error["type"].as_str().unwrap_or("")
}

/// A plist from its bytes, XML or binary.
pub fn read_plist(bytes: &[u8]) -> plist::Dictionary {
    plist::from_bytes::<plist::Dictionary>(bytes).expect("a plist dictionary")
}

/// The installer's environment in the tests: the fakes, and nothing else.
fn environment(
    github: &FakeGithub,
    apple: &FakeApple,
    usbmuxd: std::net::SocketAddr,
    keyring_service: &str,
) -> Environment {
    // GitHub through the fake, with the tests' authority only: nothing
    // leaves the computer.
    let http = reqwest::Client::builder()
        .proxy(reqwest::Proxy::all(github.proxy_url()).expect("proxy"))
        .tls_certs_only([reqwest::Certificate::from_der(&github.ca_der()).expect("certificate")])
        .build()
        .expect("HTTP client");
    Environment::new(
        UsbmuxdAddr::TcpSocket(usbmuxd),
        http,
        Some(apple.proxy_url()),
        keyring_service.to_string(),
    )
}

fn build(identifier: &str, environment: Environment) -> (tauri::App<MockRuntime>, WebviewWindow<MockRuntime>) {
    let mut context = mock_context(noop_assets());
    context.config_mut().identifier = identifier.to_string();
    let app = cartouche_installer_lib::configure(mock_builder(), environment)
        .build(context)
        .expect("installer");
    let window = tauri::WebviewWindowBuilder::new(&app, "main", Default::default())
        .build()
        .expect("window");
    (app, window)
}

/// Waits until `done` holds, for 20 s at most.
pub fn wait_until(what: &str, done: impl Fn() -> bool) {
    let start = std::time::Instant::now();
    while !done() {
        assert!(start.elapsed() < Duration::from_secs(20), "waited 20 s for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}
