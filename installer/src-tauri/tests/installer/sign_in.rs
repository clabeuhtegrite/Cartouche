//! Signing in with the Apple ID: the password, the code, the anisette
//! machine, what the installer keeps, and every refusal Apple gives.

use std::time::Duration;

use serde_json::{Value, json};

use crate::harness::*;

fn with_account(change: impl FnOnce(&mut AccountConfig)) -> Setup {
    let mut setup = Setup::default();
    change(&mut setup.account);
    setup
}

#[test]
fn says_when_the_password_is_wrong() {
    let h = Harness::new();
    let error = h.sign_in_as(EMAIL, "Wrong-Horse-8", true).expect_err("signed in");
    assert_eq!(error_type(&error), "auth", "{error}");
    assert!(error["message"].as_str().unwrap().contains("-22406"), "{error}");
    assert_eq!(h.invoke("logged_in_as", json!({})), Ok(Value::Null));
    assert!(h.events("2fa-required").is_empty());
    assert_eq!(h.keychain.password(&h.keyring_service, EMAIL), None);
    assert!(h.saved_ids().is_empty());

    h.sign_in(false).expect("the right password");
}

#[test]
fn asks_for_the_code_again_after_a_wrong_one() {
    let h = Harness::new();
    h.type_codes(&["135791"]);
    h.sign_in(false).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let asked = h.events("2fa-required");
    assert_eq!(asked.len(), 2, "{asked:?}");
    assert_eq!(asked[0]["lastError"], Value::Null);
    assert!(asked[1]["lastError"].as_str().unwrap_or("").contains("-21669"), "{asked:?}");
}

/// The code reaches the installer even when it comes at the instant another
/// thread holds Tauri's event listeners, as when the installer logs a line
/// or starts listening for something: Tauri then sets an event aside until
/// a later one that has a listener in Rust, which may never come. The code
/// went as an event, lost that way the sign-in waited two minutes and
/// failed (seen in the window's tests on Windows). It goes by a command.
#[test]
fn takes_the_code_while_tauris_event_listeners_are_busy() {
    let h = Harness::new();
    h.answer_by_hand();
    // A code with no question: nothing takes it.
    assert!(!h.type_code_now("135791"));

    let signing_in = h.sign_in_later(EMAIL, PASSWORD, false);
    wait_until("the code asked", || h.events("2fa-required").len() == 1);
    {
        let _held = h.hold_event_listeners();
        assert!(h.type_code_now(&h.account.code), "the installer was not waiting for the code");
    }
    signing_in.wait_for(Duration::from_secs(20)).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(h.invoke("logged_in_as", json!({})), Ok(json!(EMAIL)));
    assert_eq!(h.events("2fa-required").len(), 1);
}

#[test]
fn signs_in_without_a_code_when_two_factor_is_off() {
    let h = Harness::start(with_account(|a| a.two_factor = TwoFactor::Off));
    h.sign_in(false).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert!(h.events("2fa-required").is_empty());
}

#[test]
fn signs_in_with_a_code_by_text_message() {
    let h = Harness::start(with_account(|a| a.two_factor = TwoFactor::Sms));
    h.sign_in(false).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let asked = h.events("2fa-required");
    assert_eq!(asked.len(), 1, "{asked:?}");
    assert_eq!(asked[0]["sms"], true);
    assert!(h.apple.log().iter().any(|l| l.contains("verified by text message")), "{}", h.report());
}

#[test]
fn signs_in_with_the_apple_id_typed_in_capitals() {
    let h = Harness::new();
    h.sign_in_as("Camille.Testeur@Example.COM", PASSWORD, true).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(h.invoke("logged_in_as", json!({})), Ok(json!(EMAIL)));
}

#[test]
fn says_when_the_account_is_locked() {
    let h = Harness::start(with_account(|a| a.locked = true));
    let error = h.sign_in(false).expect_err("signed in to a locked account");
    assert_eq!(error_type(&error), "account_locked", "{error}");
}

#[test]
fn says_when_the_account_is_under_18() {
    let h = Harness::start(with_account(|a| a.underage = true));
    h.publish_cartouche();
    let error = h
        .sign_in(false)
        .and_then(|_| h.select_device())
        .and_then(|_| h.install())
        .expect_err("installed with an under-18 account");
    assert_eq!(error_type(&error), "underage", "{error}");
}

#[test]
fn says_when_the_anisette_server_is_down() {
    let h = Harness::new();
    h.anisette.state().down = true;
    let error = h.sign_in(false).expect_err("signed in without anisette");
    assert_eq!(error_type(&error), "anisette", "{error}");

    h.anisette.state().down = false;
    h.sign_in(false).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
}

#[test]
fn says_when_the_anisette_server_is_not_one() {
    let h = Harness::new();
    let error = h
        .invoke(
            "login_new",
            json!({
                "email": EMAIL,
                "password": PASSWORD,
                // The person typed the address of something else.
                "anisetteServer": h.apple.proxy_url().trim_end_matches("/?url="),
                "saveCredentials": false,
            }),
        )
        .expect_err("signed in through a server that is not anisette");
    assert_eq!(error_type(&error), "anisette", "{error}");
}

#[test]
fn asks_for_the_code_once_on_this_computer() {
    let mut h = Harness::new();
    h.sign_in(false).expect("sign-in");
    h.invoke("invalidate_account", json!({})).expect("sign out");
    assert_eq!(h.invoke("logged_in_as", json!({})), Ok(Value::Null));
    h.sign_in(false).expect("sign-in again");
    h.restart();
    h.sign_in(false).expect("sign-in after a restart");
    // One anisette machine, trusted once: Apple sees one computer.
    assert_eq!(h.events("2fa-required").len(), 1, "asked again");
    assert_eq!(h.anisette.state().provisionings, 1);
    assert_eq!(h.apple.with_account(EMAIL, |a| a.trusted_machines.len()), 1);
}

#[test]
fn provisions_again_when_the_anisette_server_forgot_the_machine() {
    let h = Harness::new();
    h.sign_in(false).expect("sign-in");
    h.anisette.state().forget_next = true;
    h.sign_in(false).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(h.anisette.state().provisionings, 2);
}

#[test]
fn forgets_the_anisette_machine_on_reset() {
    let h = Harness::new();
    h.sign_in(false).expect("sign-in");
    assert!(h.keychain.get(&h.keyring_service, "anisette_state").is_some());
    assert_eq!(h.invoke("reset_anisette_state", json!({})), Ok(json!(true)));
    assert_eq!(h.keychain.get(&h.keyring_service, "anisette_state"), None);
    assert_eq!(h.invoke("reset_anisette_state", json!({})), Ok(json!(false)));

    // A new machine: provisioned, and the code asked again.
    h.sign_in(false).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(h.anisette.state().provisionings, 2);
    assert_eq!(h.events("2fa-required").len(), 2);
}

#[test]
fn keeps_the_password_in_the_keychain_when_asked() {
    let mut h = Harness::new();
    h.sign_in(true).expect("sign-in");
    assert_eq!(h.keychain.password(&h.keyring_service, EMAIL).as_deref(), Some(PASSWORD));
    assert_eq!(h.saved_ids(), [EMAIL]);

    // Never on disk.
    let leaked: Vec<_> = walk(&h.data_dir())
        .into_iter()
        .filter(|p| std::fs::read(p).is_ok_and(|bytes| contains(&bytes, PASSWORD.as_bytes())))
        .collect();
    assert!(leaked.is_empty(), "the password is in {leaked:?}");

    // The next time, the saved account signs in without the password.
    h.restart();
    assert_eq!(h.saved_ids(), [EMAIL]);
    h.invoke("login_stored", json!({ "email": EMAIL, "anisetteServer": h.anisette.url() }))
        .unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(h.invoke("logged_in_as", json!({})), Ok(json!(EMAIL)));

    // Signing in again does not list it twice.
    h.sign_in(true).expect("sign-in again");
    assert_eq!(h.saved_ids(), [EMAIL]);

    // Removed from the window: from the keychain too. Twice is nothing.
    h.invoke("delete_account", json!({ "email": EMAIL })).expect("delete");
    assert_eq!(h.keychain.password(&h.keyring_service, EMAIL), None);
    assert!(h.saved_ids().is_empty());
    h.invoke("delete_account", json!({ "email": EMAIL })).expect("delete again");
}

#[test]
fn keeps_no_password_unless_asked() {
    let h = Harness::new();
    h.sign_in(false).expect("sign-in");
    assert_eq!(h.keychain.password(&h.keyring_service, EMAIL), None);
    assert!(h.saved_ids().is_empty());
    let error = h
        .invoke("login_stored", json!({ "email": EMAIL, "anisetteServer": h.anisette.url() }))
        .expect_err("signed in with no password kept");
    assert_eq!(error_type(&error), "keyring_with_message", "{error}");
}

#[test]
fn signs_out() {
    let h = Harness::new();
    h.publish_cartouche();
    h.ready();
    h.invoke("invalidate_account", json!({})).expect("sign out");
    assert_eq!(h.invoke("logged_in_as", json!({})), Ok(Value::Null));
    let error = h.install().expect_err("installed signed out");
    assert_eq!(error_type(&error), "not_logged_in");
}

#[test]
fn lists_the_certificates_and_app_ids_of_the_account() {
    let h = Harness::new();
    h.publish_cartouche();
    let other = h.apple.add_foreign_certificate(EMAIL, "SideStore");
    h.ready();
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));

    let certificates = h.invoke("get_certificates", json!({})).expect("certificates");
    let machines: Vec<&str> = certificates.as_array().unwrap().iter().filter_map(|c| c["machineName"].as_str()).collect();
    assert_eq!(machines.len(), 2, "{certificates}");
    assert!(machines.contains(&"Cartouche") && machines.contains(&"SideStore"));

    h.invoke("revoke_certificate", json!({ "serialNumber": other })).expect("revoke");
    assert_eq!(h.apple.with_account(EMAIL, |a| a.team.certificates.len()), 1);

    let app_ids = h.invoke("list_app_ids", json!({})).expect("App IDs");
    let identifiers: Vec<&str> = app_ids["appIds"]
        .as_array()
        .unwrap_or_else(|| panic!("{app_ids}"))
        .iter()
        .filter_map(|id| id["identifier"].as_str())
        .collect();
    let ours = format!("{BUNDLE_ID}.{}", h.team_id);
    assert!(identifiers.contains(&ours.as_str()), "{app_ids}");
    let id = app_ids["appIds"]
        .as_array()
        .unwrap()
        .iter()
        .find(|id| id["identifier"] == ours.as_str())
        .unwrap()["appIdId"]
        .as_str()
        .unwrap()
        .to_string();
    h.invoke("delete_app_id", json!({ "appIdId": id })).expect("delete App ID");
    assert!(h.apple.with_account(EMAIL, |a| a.team.app_ids.iter().all(|id| id.identifier != ours)));
}

fn walk(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut files = Vec::new();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                files.extend(walk(&path));
            } else {
                files.push(path);
            }
        }
    }
    files
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

#[test]
fn says_when_apple_does_not_answer() {
    let h = Harness::new();
    h.apple.fail_next("init", Failure::Http(503));
    let error = h.sign_in(false).expect_err("signed in without Apple");
    assert!(!error_type(&error).is_empty(), "{error}");
    assert_eq!(h.invoke("logged_in_as", json!({})), Ok(Value::Null));
    h.sign_in(false).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
}

#[test]
fn signs_in_once_apple_stops_answering_too_many_requests() {
    // A 429 from Apple: the sign-in fails, and the next one after the wait
    // goes through, on the same anisette machine (resetting it would not
    // help, and costs a new code).
    let h = Harness::new();
    h.sign_in(false).expect("sign-in");
    h.invoke("invalidate_account", json!({})).expect("sign out");
    h.apple.state().too_many_requests = 1;
    h.sign_in(false).expect_err("signed in through a 429");
    h.sign_in(false).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(h.anisette.state().provisionings, 1);
    assert_eq!(h.events("2fa-required").len(), 1);
}
