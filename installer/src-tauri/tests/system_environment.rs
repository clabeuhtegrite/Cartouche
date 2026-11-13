//! The environment the app itself runs with, Environment::system(): an
//! iPhone reached through USBMUXD_SOCKET_ADDRESS (usbmuxd over the network,
//! or a fake one) is listed and paired at that same address. Alone in its
//! own test binary, as it sets a variable of the process.

use std::time::Duration;

use cartouche_installer_fakes::{FakeIphone, FakeUsbmuxd, IphoneConfig};
use cartouche_installer_lib::Environment;
use serde_json::{Value, json};
use tauri::{
    ipc::{CallbackFn, InvokeBody, InvokeResponse},
    test::{INVOKE_KEY, MockRuntime, mock_builder, mock_context, noop_assets},
    webview::InvokeRequest,
};

fn invoke(window: &tauri::WebviewWindow<MockRuntime>, cmd: &str, args: Value) -> Result<Value, Value> {
    let (tx, rx) = std::sync::mpsc::channel();
    let webview: &tauri::Webview<MockRuntime> = window.as_ref();
    webview.clone().on_message(
        InvokeRequest {
            cmd: cmd.into(),
            callback: CallbackFn(0),
            error: CallbackFn(1),
            url: if cfg!(windows) { "http://tauri.localhost" } else { "tauri://localhost" }.parse().unwrap(),
            body: InvokeBody::Json(args),
            headers: Default::default(),
            invoke_key: INVOKE_KEY.to_string(),
        },
        Box::new(move |_, _, response, _, _| {
            let _ = tx.send(match response {
                InvokeResponse::Ok(body) => Ok(body.deserialize::<Value>().unwrap_or(Value::Null)),
                InvokeResponse::Err(error) => Err(error.0),
            });
        }),
    );
    rx.recv_timeout(Duration::from_secs(60)).expect("an answer")
}

#[test]
fn reaches_the_iphone_at_usbmuxd_socket_address() {
    // A port of its own, named before anything else runs: setting a
    // variable while other threads read the environment is undefined.
    let addr = std::net::TcpListener::bind("127.0.0.1:0").and_then(|l| l.local_addr()).expect("free port");
    unsafe { std::env::set_var("USBMUXD_SOCKET_ADDRESS", addr.to_string()) };

    // Never the computer's keychain.
    cartouche_installer_fakes::keychain::install();
    let usbmuxd = tauri::async_runtime::block_on(FakeUsbmuxd::start_at(addr)).expect("fake usbmuxd");
    let iphone = FakeIphone::new(IphoneConfig::iphone_17_pro(7));
    usbmuxd.plug(&iphone);

    let mut context = mock_context(noop_assets());
    context.config_mut().identifier =
        format!("io.github.clabeuhtegrite.cartouche.installer.tests.system{}", std::process::id());
    let app = cartouche_installer_lib::configure(mock_builder(), Environment::system())
        .build(context)
        .expect("installer");
    let window = tauri::WebviewWindowBuilder::new(&app, "main", Default::default()).build().expect("window");

    let listed = invoke(&window, "list_devices", json!({})).expect("list_devices");
    let device = listed[0]["Ok"].clone();
    assert_eq!(device["udid"], iphone.udid(), "{listed}");
    invoke(&window, "set_selected_device", json!({ "device": device })).expect("pairing");
    assert_eq!(iphone.state().pair_setups, 1);

    if let Ok(dir) = tauri::Manager::path(&app).app_data_dir() {
        let _ = std::fs::remove_dir_all(dir);
    }
}
