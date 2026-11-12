//! The installer's window itself, built as it ships (the frontend of
//! ../dist, in the system's webview), clicked through as a person does,
//! against the fakes: in English and in French, the texts read from the
//! window's own translations.
//!
//!     npm run build    # in installer/
//!     cargo test --features ui-tests --test ui [scenario]
//!
//! Each scenario runs in a process of its own (a webview's event loop
//! starts once per process), the window on the screen: on Linux, under
//! xvfb-run. See ../README.md.

use std::{
    io::Write,
    panic::AssertUnwindSafe,
    process::{Command, ExitCode},
    sync::mpsc,
    time::{Duration, Instant},
};

use cartouche_installer_fakes::{
    AccountConfig, FakeAnisette, FakeApple, FakeGithub, FakeIphone, FakeUsbmuxd, IphoneConfig, Trust,
    github::BUNDLE_ID, ipa::CartoucheIpa,
};
use cartouche_installer_lib::Environment;
use idevice::usbmuxd::UsbmuxdAddr;
use serde_json::{Value, json};
use tauri::{AppHandle, Listener, Manager, Wry};

const EMAIL: &str = "camille.testeur@example.com";
const PASSWORD: &str = "Correct-Horse-7";
const PAIRING_FILE: &str = "Documents/SideStore/Documents/ALTPairingFile.mobiledevicepairing";
/// How long a scenario may take, start to end, before it counts as failed.
const SCENARIO_TIMEOUT: Duration = Duration::from_secs(300);

struct Scenario {
    name: &'static str,
    language: &'static str,
    /// What the fakes are before the window opens.
    prepare: fn(&Fakes),
    run: fn(&Ui, &Fakes),
}

const SCENARIOS: &[Scenario] = &[
    Scenario { name: "first_install_en", language: "en", prepare: publish, run: first_install },
    Scenario { name: "first_install_fr", language: "fr", prepare: publish, run: first_install },
    Scenario { name: "everything_goes_wrong_fr", language: "fr", prepare: github_down, run: everything_goes_wrong },
    Scenario { name: "without_a_keychain_en", language: "en", prepare: no_keychain, run: without_a_keychain },
];

/// The version every scenario installs.
const VERSION: &str = "0.12.0";

fn publish(f: &Fakes) {
    f.github.publish(VERSION, CartoucheIpa::new(VERSION).build());
}

fn github_down(f: &Fakes) {
    publish(f);
    f.github.state().source_status = Some(503);
    f.usbmuxd.unplug(&f.iphone);
}

fn no_keychain(f: &Fakes) {
    publish(f);
    f.keychain.break_service(&f.keyring_service);
}

fn main() -> ExitCode {
    if let Ok(name) = std::env::var("CARTOUCHE_UI_SCENARIO") {
        let scenario = SCENARIOS
            .iter()
            .find(|s| s.name == name)
            .unwrap_or_else(|| panic!("no scenario {name}"));
        run_in_window(scenario);
    }
    let filter: Option<String> = std::env::args().skip(1).find(|a| !a.starts_with('-'));
    let mut failed = Vec::new();
    let mut ran = 0;
    for Scenario { name, .. } in SCENARIOS {
        if filter.as_deref().is_some_and(|f| !name.contains(f)) {
            continue;
        }
        ran += 1;
        println!("ui scenario {name} …");
        let started = Instant::now();
        let ok = run_child(name);
        println!(
            "ui scenario {name}: {} in {:.1} s",
            if ok { "ok" } else { "FAILED" },
            started.elapsed().as_secs_f64()
        );
        if !ok {
            failed.push(*name);
        }
    }
    println!("\nui scenarios: {} ran, {} failed {failed:?}", ran, failed.len());
    if failed.is_empty() { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}

fn run_child(name: &str) -> bool {
    let mut command = Command::new(std::env::current_exe().expect("this test"));
    command.env("CARTOUCHE_UI_SCENARIO", name);
    if cfg!(target_os = "linux") {
        // WebKitGTK under Xvfb, without a GPU.
        command.env("WEBKIT_DISABLE_COMPOSITING_MODE", "1");
        command.env("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    }
    let mut child = command.spawn().expect("start the scenario");
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait().expect("scenario status") {
            return status.success();
        }
        if started.elapsed() > SCENARIO_TIMEOUT {
            let _ = child.kill();
            eprintln!("ui scenario {name}: no end after {SCENARIO_TIMEOUT:?}");
            return false;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// The fakes around the window, as in the other tests.
struct Fakes {
    iphone: FakeIphone,
    usbmuxd: FakeUsbmuxd,
    apple: FakeApple,
    github: FakeGithub,
    keychain: cartouche_installer_fakes::MemoryKeychain,
    keyring_service: String,
    code: String,
    team_id: String,
}

impl Fakes {
    fn installed(&self) -> Option<String> {
        self.iphone.app(BUNDLE_ID).and_then(|app| {
            app.info.get("CFBundleShortVersionString").and_then(|v| v.as_string()).map(str::to_string)
        })
    }
}

/// The window, as a test drives it: JavaScript sent with eval, its answer
/// back as an event.
struct Ui {
    handle: AppHandle<Wry>,
    answers: mpsc::Receiver<Value>,
    next: std::cell::Cell<u64>,
    texts: Value,
}

/// What every step's script can use: waiting for a text, clicking a button
/// by its label, typing into a field as React expects.
const DRIVER: &str = r#"
if (!window.__ui) window.__ui = {
  sleep(ms) { return new Promise((r) => setTimeout(r, ms)); },
  text() { return document.body ? document.body.textContent.replace(/\s+/g, " ") : ""; },
  // French puts a no-break space before ":": every space counts as one.
  has(t) { return __ui.text().includes(t.replace(/\s+/g, " ")); },
  async waitFor(fn, what, timeout) {
    const start = Date.now();
    for (;;) {
      let v = null;
      try { v = fn(); } catch (e) {}
      if (v) return v;
      if (Date.now() - start > (timeout || 30000))
        throw new Error("waited for " + what + " in: " + __ui.text().slice(0, 4000));
      await __ui.sleep(50);
    }
  },
  clickables() { return [...document.querySelectorAll("button, [role=button]")]; },
  find(label) {
    const all = __ui.clickables();
    return all.find((b) => b.textContent.trim() === label) || all.find((b) => b.textContent.includes(label));
  },
  async click(label) {
    const b = await __ui.waitFor(() => { const b = __ui.find(label); return b && !b.disabled ? b : null; },
      "an enabled button " + JSON.stringify(label));
    b.click();
    return true;
  },
  async type(placeholder, value) {
    const input = await __ui.waitFor(() => [...document.querySelectorAll("input")].find((i) =>
      placeholder === "password" ? i.type === "password" : i.placeholder === placeholder), "the field " + placeholder);
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
    return true;
  },
  closeModal() {
    const z = (c) => Number(getComputedStyle(c).zIndex) || 0;
    const top = [...document.querySelectorAll(".modal-container")].sort((a, b) => z(a) - z(b)).pop();
    const close = top && top.querySelector(".modal-close");
    if (!close) throw new Error("no dialog to close");
    close.click();
    return true;
  },
  value(placeholder) {
    const input = [...document.querySelectorAll("input")].find((i) => i.placeholder === placeholder);
    return input ? input.value : null;
  },
  report(id, result) {
    return window.__TAURI_INTERNALS__.invoke("plugin:event|emit", { event: "ui-test", payload: Object.assign({ id }, result) });
  },
  async run(id, step) {
    try {
      const value = await step();
      await __ui.report(id, { ok: true, value: value === undefined ? null : value });
    } catch (e) {
      await __ui.report(id, { ok: false, error: String((e && e.message) || e) });
    }
  },
};
"#;

impl Ui {
    /// Runs `body`, an async function's body, in the window: its value, or
    /// the error it threw.
    fn run(&self, body: &str, timeout: Duration) -> Result<Value, String> {
        let id = self.next.get();
        self.next.set(id + 1);
        let window = self.handle.get_webview_window("main").expect("the window");
        window
            .eval(format!("{DRIVER}\n__ui.run({id}, async () => {{ {body} }});"))
            .expect("eval");
        let deadline = Instant::now() + timeout;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.answers.recv_timeout(left) {
                Ok(answer) if answer["id"] == id => {
                    return if answer["ok"] == true {
                        Ok(answer["value"].clone())
                    } else {
                        Err(answer["error"].as_str().unwrap_or("").to_string())
                    };
                }
                Ok(_) => continue,
                Err(_) => return Err(format!("no answer from the window in {timeout:?} to: {body}")),
            }
        }
    }

    fn step(&self, body: &str) -> Value {
        self.run(body, Duration::from_secs(60)).unwrap_or_else(|e| panic!("{e}"))
    }

    /// Waits until the window is there and its page answers.
    fn wait_ready(&self) {
        let start = Instant::now();
        loop {
            if self.handle.get_webview_window("main").is_some()
                && self.run("return !!document.querySelector('.workspace');", Duration::from_millis(1500)) == Ok(json!(true))
            {
                return;
            }
            assert!(start.elapsed() < Duration::from_secs(60), "the window did not open");
            std::thread::sleep(Duration::from_millis(200));
        }
    }

    fn wait_text(&self, text: &str) {
        self.step(&format!(
            "await __ui.waitFor(() => __ui.has({0}), {0});",
            js(text)
        ));
    }

    fn has_text(&self, text: &str) -> bool {
        self.step(&format!("return __ui.has({});", js(text))) == json!(true)
    }

    fn click(&self, label: &str) {
        self.step(&format!("return await __ui.click({});", js(label)));
    }

    fn type_into(&self, placeholder: &str, value: &str) {
        self.step(&format!("return await __ui.type({}, {});", js(placeholder), js(value)));
    }

    fn close_dialog(&self) {
        self.step("return __ui.closeModal();");
    }

    /// The text of `key` in the window's language.
    fn t(&self, key: &str) -> String {
        self.t_with(key, &[])
    }

    fn t_with(&self, key: &str, values: &[(&str, &str)]) -> String {
        let mut text = key
            .split('.')
            .fold(&self.texts, |v, part| &v[part])
            .as_str()
            .unwrap_or_else(|| panic!("no text {key}"))
            .to_string();
        for (name, value) in values {
            text = text.replace(&format!("{{{{{name}}}}}"), value);
        }
        text
    }

    /// The first suggestion for an error, up to its first link.
    fn suggestion(&self, kind: &str) -> String {
        let first = self.texts["error"]["suggestions"][kind][0].as_str().unwrap_or_else(|| panic!("no suggestion {kind}"));
        first.split("((").next().unwrap().trim().to_string()
    }

    /// No key shows instead of its text: every text the window shows is
    /// in its language's file.
    fn no_raw_keys(&self) {
        // innerText, which keeps the blocks apart: "…an app." then "Settings"
        // is not a key.
        let found = self.step(
            r#"return document.body.innerText.match(/\b(common|dropdown|app|steps|install|apple_id|device|operations?|certificates|app_ids|settings|dialog|error)\.[a-z_]+(\.[a-z_]+)*\b/gi);"#,
        );
        assert_eq!(found, Value::Null, "keys shown instead of texts");
    }
}

fn js(text: &str) -> String {
    serde_json::to_string(text).expect("JSON")
}

fn run_in_window(scenario: &Scenario) -> ! {
    let Scenario { name, language, .. } = scenario;
    let keychain = cartouche_installer_fakes::keychain::install();
    let keyring_service = format!("cartouche-installer-uitest-{name}");
    let (usbmuxd, apple, anisette, github) = tauri::async_runtime::block_on(async {
        (
            FakeUsbmuxd::start().await.expect("fake usbmuxd"),
            FakeApple::start().await,
            FakeAnisette::start().await,
            FakeGithub::start().await,
        )
    });
    let iphone = FakeIphone::new(IphoneConfig::iphone_17_pro(1));
    usbmuxd.plug(&iphone);
    let account = AccountConfig::new(EMAIL, PASSWORD);
    let code = account.code.clone();
    let team_id = apple.add_account(account);
    let http = reqwest::Client::builder()
        .proxy(reqwest::Proxy::all(github.proxy_url()).expect("proxy"))
        .tls_certs_only([reqwest::Certificate::from_der(&github.ca_der()).expect("certificate")])
        .build()
        .expect("HTTP client");
    let environment = Environment::new(
        UsbmuxdAddr::TcpSocket(usbmuxd.addr()),
        http,
        Some(apple.proxy_url()),
        keyring_service.clone(),
    );

    let fakes = Fakes { iphone, usbmuxd, apple, github, keychain, keyring_service: keyring_service.clone(), code, team_id };
    (scenario.prepare)(&fakes);

    let mut context = cartouche_installer_lib::context();
    // A data folder of its own, never the installer's.
    context.config_mut().identifier = format!("io.github.clabeuhtegrite.cartouche.installer.uitests.{name}");
    let app = cartouche_installer_lib::configure(tauri::Builder::default(), environment)
        .build(context)
        .expect("installer");
    let data_dir = app.path().app_data_dir().expect("data folder");
    let _ = std::fs::remove_dir_all(&data_dir);
    std::fs::create_dir_all(&data_dir).expect("data folder");
    // Settings as the person left them: the anisette server (the fake) and
    // the language.
    std::fs::write(
        data_dir.join("preferences.json"),
        json!({ "anisetteServer3-1": anisette.url(), "lang": language }).to_string(),
    )
    .expect("preferences");

    let texts: Value = serde_json::from_str(
        &std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../src/locales/{language}.json")),
        )
        .expect("translations"),
    )
    .expect("translations");

    let (tx, answers) = mpsc::channel();
    app.listen_any("ui-test", move |event| {
        if let Ok(answer) = serde_json::from_str::<Value>(event.payload()) {
            let _ = tx.send(answer);
        }
    });
    let handle = app.handle().clone();
    let run = scenario.run;
    std::thread::spawn(move || {
        let ui = Ui { handle: handle.clone(), answers, next: std::cell::Cell::new(0), texts };
        let outcome = std::panic::catch_unwind(AssertUnwindSafe(|| {
            ui.wait_ready();
            run(&ui, &fakes);
        }));
        if outcome.is_err() {
            eprintln!("iPhone: {:#?}\nApple: {:#?}", fakes.iphone.log(), fakes.apple.log());
        }
        let _ = std::fs::remove_dir_all(&data_dir);
        let _ = std::io::stderr().flush();
        let _ = std::io::stdout().flush();
        // Not handle.exit(code): the event loop ends the process with 0.
        std::process::exit(if outcome.is_ok() { 0 } else { 1 });
    });
    app.run(|_, _| {});
    unreachable!("the window's event loop returned");
}

/// The person's first time: picks the iPhone, taps Trust, signs in with a
/// code, installs, and sees Cartouche installed.
fn first_install(ui: &Ui, f: &Fakes) {
    let version = VERSION;
    let name = f.iphone.config().name.clone();

    ui.wait_text(&ui.t("steps.iphone_title"));
    ui.wait_text(&name);
    ui.wait_text(&ui.t_with("install.latest", &[("version", version)]));
    ui.wait_text(&ui.t("install.needs_both"));
    // Not paired yet: the window waits for the person to pick it.
    assert_eq!(f.iphone.state().pair_setups, 0);
    ui.click(&name);
    ui.wait_text(&ui.t("device.selected"));
    assert_eq!(f.iphone.state().pair_setups, 1);
    ui.wait_text(&ui.t("install.not_installed"));

    ui.type_into(&ui.t("apple_id.email_placeholder"), EMAIL);
    ui.type_into("password", PASSWORD);
    ui.click(&ui.t("apple_id.login"));
    ui.wait_text(&ui.t("apple_id.two_factor_title"));
    ui.type_into(&ui.t("apple_id.verification_placeholder"), &f.code);
    ui.click(&ui.t("apple_id.submit"));
    ui.wait_text(&ui.t("apple_id.logged_in_as"));
    ui.wait_text(EMAIL);
    // Remembered, as the box is ticked by default.
    ui.wait_text(&ui.t("apple_id.saved_logins"));
    assert_eq!(f.keychain.password(&f.keyring_service, EMAIL).as_deref(), Some(PASSWORD));

    ui.click(&ui.t_with("install.button", &[("version", version)]));
    ui.wait_text(&ui.t("operations.install_success_title"));
    ui.wait_text(&ui.t("operations.install_success_message"));
    for step in ["install_step_download", "install_step_install", "install_step_pairing"] {
        assert!(ui.has_text(&ui.t(&format!("operations.{step}"))), "{step}");
    }
    assert_eq!(f.installed().as_deref(), Some(version));
    let bundle_id = format!("{BUNDLE_ID}.{}", f.team_id);
    assert!(f.iphone.container_file(&bundle_id, PAIRING_FILE).is_some(), "no pairing file in Cartouche");
    ui.no_raw_keys();

    ui.close_dialog();
    ui.wait_text(&ui.t_with("install.installed", &[("version", version)]));
    ui.wait_text(&ui.t_with("install.update_button", &[("version", version)]));
    ui.no_raw_keys();
}

/// Every failure the person can meet on the way, each shown with what to
/// try, then the install going through.
fn everything_goes_wrong(ui: &Ui, f: &Fakes) {
    let version = VERSION;
    let name = f.iphone.config().name.clone();

    // No iPhone plugged in, then one, and Refresh.
    ui.wait_text(&ui.t("device.no_devices_found_period"));
    f.usbmuxd.plug(&f.iphone);
    ui.click(&ui.t("common.refresh"));
    ui.wait_text(&name);

    // GitHub does not answer, then does.
    ui.wait_text(&ui.t("install.release_failed"));
    f.github.state().source_status = None;
    ui.click(&ui.t("common.retry"));
    ui.wait_text(&ui.t_with("install.latest", &[("version", version)]));

    // Don't Trust, then Trust.
    f.iphone.set_trust(Trust::Refuse);
    ui.click(&name);
    ui.wait_text(&ui.t_with("error.title", &[("msg", &ui.t("device.failed_select"))]));
    ui.wait_text(&ui.suggestion("trust"));
    ui.no_raw_keys();
    ui.close_dialog();
    f.iphone.set_trust(Trust::Accept);
    ui.click(&name);
    ui.wait_text(&ui.t("device.selected"));

    // A wrong password, then the right one; a wrong code, then the right one.
    ui.type_into(&ui.t("apple_id.email_placeholder"), EMAIL);
    ui.type_into("password", "Wrong-Horse-8");
    ui.click(&ui.t("apple_id.login"));
    ui.wait_text(&ui.t_with("error.title", &[("msg", &ui.t("apple_id.login_failed"))]));
    ui.wait_text(&ui.suggestion("auth"));
    ui.no_raw_keys();
    ui.close_dialog();
    ui.type_into("password", PASSWORD);
    ui.click(&ui.t("apple_id.login"));
    ui.wait_text(&ui.t("apple_id.two_factor_title"));
    ui.type_into(&ui.t("apple_id.verification_placeholder"), "135791");
    ui.click(&ui.t("apple_id.submit"));
    // Asked again, once Apple has refused the code and the field is empty.
    let start = Instant::now();
    while !f.apple.log().iter().any(|l| l.contains("wrong code")) {
        assert!(start.elapsed() < Duration::from_secs(30), "Apple never saw the wrong code");
        std::thread::sleep(Duration::from_millis(50));
    }
    ui.step(&format!(
        "await __ui.waitFor(() => __ui.value({0}) === '', 'an empty code field'); return true;",
        js(&ui.t("apple_id.verification_placeholder"))
    ));
    ui.wait_text(&ui.t("apple_id.two_factor_title"));
    ui.type_into(&ui.t("apple_id.verification_placeholder"), &f.code);
    ui.click(&ui.t("apple_id.submit"));
    ui.wait_text(&ui.t("apple_id.logged_in_as"));

    // The download fails: the step says so, with what to try.
    f.github.state().asset_status = Some(500);
    ui.click(&ui.t_with("install.button", &[("version", version)]));
    ui.wait_text(&ui.t("operation.failed"));
    ui.wait_text(&ui.suggestion("download"));
    ui.no_raw_keys();
    assert!(f.installed().is_none());
    ui.close_dialog();

    // Then it goes through.
    f.github.state().asset_status = None;
    ui.click(&ui.t_with("install.button", &[("version", version)]));
    ui.wait_text(&ui.t("operations.install_success_title"));
    assert_eq!(f.installed().as_deref(), Some(version));
    ui.close_dialog();
    ui.wait_text(&ui.t_with("install.installed", &[("version", version)]));
}

/// A computer whose keychain refuses everything: the window says the
/// password will not be kept, and installs all the same.
fn without_a_keychain(ui: &Ui, f: &Fakes) {
    let version = VERSION;
    let name = f.iphone.config().name.clone();

    ui.wait_text(&ui.t("apple_id.no_keyring_available"));
    assert!(!ui.has_text(&ui.t("apple_id.save_credentials")));
    ui.click(&name);
    ui.wait_text(&ui.t("device.selected"));
    ui.type_into(&ui.t("apple_id.email_placeholder"), EMAIL);
    ui.type_into("password", PASSWORD);
    ui.click(&ui.t("apple_id.login"));
    ui.type_into(&ui.t("apple_id.verification_placeholder"), &f.code);
    ui.click(&ui.t("apple_id.submit"));
    ui.wait_text(&ui.t("apple_id.logged_in_as"));
    assert!(!ui.has_text(&ui.t("apple_id.saved_logins")), "listed as saved without a keychain");
    assert!(f.keychain.users(&f.keyring_service).is_empty());

    ui.click(&ui.t_with("install.button", &[("version", version)]));
    ui.wait_text(&ui.t("operations.install_success_title"));
    assert_eq!(f.installed().as_deref(), Some(version));
}
