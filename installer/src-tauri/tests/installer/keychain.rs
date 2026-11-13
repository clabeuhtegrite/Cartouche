//! The keychain (macOS), Credential Manager (Windows): what the installer
//! keeps there, and what it does without one, or when Settings says not to
//! use it.

use serde_json::json;

use crate::harness::*;

fn without_keychain() -> Setup {
    Setup { keychain_works: false, ..Setup::default() }
}

#[test]
fn installs_on_a_computer_without_a_keychain() {
    let h = Harness::start(without_keychain());
    h.publish_cartouche();
    assert_eq!(h.invoke("keyring_available", json!({})), Ok(json!(false)));

    // The window asks to remember the password, as its box is ticked by
    // default: the sign-in goes through, and nothing is kept.
    h.select_device().expect("pairing");
    assert!(h.has_stored_pairing(), "the pairing is not kept on disk");
    h.sign_in(true).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert!(h.saved_ids().is_empty());
    assert!(h.keychain.users(&h.keyring_service).is_empty());
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert!(h.iphone.app(BUNDLE_ID).is_some());
}

#[test]
fn keeps_nothing_in_the_keychain_when_settings_say_not_to() {
    let h = Harness::new();
    h.publish_cartouche();
    h.invoke("force_disable_keyring", json!({ "force": true })).expect("switch");
    assert_eq!(h.invoke("keyring_available", json!({})), Ok(json!(false)));

    h.select_device().expect("pairing");
    h.sign_in(true).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert!(h.keychain.users(&h.keyring_service).is_empty(), "{:?}", h.keychain.users(&h.keyring_service));
    assert!(h.saved_ids().is_empty());

    // Switched back on, the keychain is used again.
    h.invoke("force_disable_keyring", json!({ "force": false })).expect("switch");
    assert_eq!(h.invoke("keyring_available", json!({})), Ok(json!(true)));
    h.sign_in(true).expect("sign-in");
    assert_eq!(h.keychain.password(&h.keyring_service, EMAIL).as_deref(), Some(PASSWORD));
}

#[test]
fn forgets_the_pairing_kept_on_disk() {
    let h = Harness::start(without_keychain());
    h.select_device().expect("pairing");
    assert!(h.has_stored_pairing());
    h.invoke("delete_stored_rppairing", json!({})).expect("delete");
    assert!(!h.has_stored_pairing(), "still there after Delete stored pairing");
    h.select_device().expect("pairing again");
    assert_eq!(h.iphone.state().pair_setups, 2);
}

#[test]
fn forgets_the_anisette_machine_kept_on_disk() {
    let h = Harness::start(without_keychain());
    h.sign_in(false).expect("sign-in");
    assert_eq!(h.invoke("reset_anisette_state", json!({})), Ok(json!(true)));
    assert_eq!(h.invoke("reset_anisette_state", json!({})), Ok(json!(false)), "still there after a reset");
    h.sign_in(false).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(h.anisette.state().provisionings, 2);
}

#[test]
fn keeps_the_pairing_on_disk_across_restarts() {
    let mut h = Harness::start(without_keychain());
    h.select_device().expect("pairing");
    h.restart();
    assert!(h.has_stored_pairing());
    h.select_device().expect("after a restart");
    assert_eq!(h.iphone.state().pair_setups, 1);
}

#[test]
fn each_window_has_its_own_switch() {
    // Two installers in one process, as the tests run: Settings' switch in
    // one is not the other's.
    let one = Harness::new();
    let two = Harness::new();
    one.invoke("force_disable_keyring", json!({ "force": true })).expect("switch");
    assert_eq!(one.invoke("keyring_available", json!({})), Ok(json!(false)));
    assert_eq!(two.invoke("keyring_available", json!({})), Ok(json!(true)));
}
