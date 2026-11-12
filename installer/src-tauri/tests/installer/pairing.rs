//! Listing and picking the iPhone: "Trust This Computer?", the pairing the
//! installer keeps, and what goes wrong on the way.

use serde_json::{Value, json};

use crate::harness::*;

#[test]
fn pairs_once_and_remembers_it_after_a_restart() {
    let mut h = Harness::new();
    h.select_device().expect("pairing");
    h.select_device().expect("picked again");
    assert_eq!(h.iphone.state().pair_setups, 1);

    h.restart();
    assert!(h.has_stored_pairing(), "the window would not pick the iPhone by itself");
    h.select_device().expect("after a restart");
    assert_eq!(h.iphone.state().pair_setups, 1, "asked to trust again");
    // The same computer for the iPhone: one host, not one per start.
    assert_eq!(h.iphone.state().rp_hosts.len(), 1);
}

#[test]
fn says_when_the_person_taps_dont_trust() {
    let h = Harness::new();
    h.iphone.set_trust(Trust::Refuse);
    let error = h.select_device().expect_err("paired without trust");
    assert_eq!(error_type(&error), "remote_pairing", "{error}");
    assert!(!h.has_stored_pairing());
    assert!(h.iphone.state().rp_hosts.is_empty());
    assert_eq!(h.invoke("installed_cartouche", json!({})).map_err(|e| error_type(&e).to_string()), Err("no_device_selected".into()));

    // Trust, the next time: it pairs.
    h.iphone.set_trust(Trust::Accept);
    h.select_device().expect("pairing");
    assert!(h.has_stored_pairing());
}

#[test]
fn stops_waiting_for_trust_when_the_window_cancels() {
    let h = Harness::new();
    h.iphone.set_trust(Trust::Never);
    let device = h.device();
    let pending = h.invoke_later("set_selected_device", json!({ "device": device }));
    wait_until("the iPhone to ask", || {
        h.iphone.log().iter().any(|line| line.contains("Trust This Computer?"))
    });
    assert!(pending.try_wait().is_none(), "answered before the person did");

    h.invoke("cancel_pairing", json!({})).expect("cancel");
    let error = pending.wait().expect_err("paired without an answer");
    assert_eq!(error_type(&error), "canceled", "{error}");
    assert!(!h.has_stored_pairing());

    // Canceling again, with nothing waiting, is nothing.
    h.invoke("cancel_pairing", json!({})).expect("cancel again");
    h.iphone.set_trust(Trust::Accept);
    h.select_device().expect("pairing");
}

#[test]
fn a_new_pick_cancels_the_one_waiting() {
    let h = Harness::new();
    let other = FakeIphone::new(IphoneConfig::iphone_17_pro(2));
    h.usbmuxd.plug(&other);
    h.iphone.set_trust(Trust::Never);
    let first = h.device();
    let pending = h.invoke_later("set_selected_device", json!({ "device": first }));
    wait_until("the iPhone to ask", || {
        h.iphone.log().iter().any(|line| line.contains("Trust This Computer?"))
    });

    // The person picks the other iPhone in the list meanwhile.
    let second = h.devices().into_iter().find(|d| d["udid"] == other.udid()).expect("second iPhone");
    h.invoke("set_selected_device", json!({ "device": second })).expect("pairing the other");
    assert_eq!(error_type(&pending.wait().expect_err("the first paired")), "canceled");
    assert_eq!(other.state().pair_setups, 1);
}

#[test]
fn says_when_the_computer_has_no_pair_record() {
    // An iPhone plugged in that never trusted this computer over USB.
    let h = Harness::new();
    h.iphone.state().usbmuxd_pair_record = false;
    let error = h.select_device().expect_err("paired without a pair record");
    assert_eq!(error_type(&error), "lockdown_pairing", "{error}");
    assert!(!h.has_stored_pairing());
}

#[test]
fn says_when_the_iphone_forgot_this_computer() {
    // Reset Location & Privacy: the iPhone no longer knows the record.
    let h = Harness::new();
    h.iphone.state().knows_host = false;
    let error = h.select_device().expect_err("paired with a forgotten record");
    assert_eq!(error_type(&error), "device_coms_with_message", "{error}");
    assert!(error["message"].as_str().unwrap().contains("lockdown session"), "{error}");
}

#[test]
fn pairs_again_after_delete_stored_pairing() {
    let h = Harness::new();
    h.select_device().expect("pairing");
    let first_host = h.iphone.state().rp_hosts[0].name.clone();

    h.invoke("delete_stored_rppairing", json!({})).expect("delete");
    assert!(!h.has_stored_pairing());
    h.select_device().expect("pairing again");
    assert!(h.has_stored_pairing());
    let hosts: Vec<String> = h.iphone.state().rp_hosts.iter().map(|h| h.name.clone()).collect();
    assert_eq!(h.iphone.state().pair_setups, 2);
    // Under a new name: the iPhone shows a new computer to trust.
    assert_eq!(hosts.len(), 2);
    assert_ne!(hosts[1], first_host);
}

#[test]
fn pairs_again_when_the_pairing_kept_is_damaged() {
    let h = Harness::new();
    h.select_device().expect("pairing");
    let key = format!("rppairing1.1_file_{}", h.iphone.udid());
    let kept = h.keychain.password(&h.keyring_service, &key).expect("kept elsewhere than the keychain");
    // The first bytes only, still base64: a plist cut short.
    h.keychain.set(&h.keyring_service, &key, kept[..40].as_bytes());

    h.select_device().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(h.iphone.state().pair_setups, 2);
    assert_ne!(h.keychain.password(&h.keyring_service, &key).as_deref(), Some(&kept[..40]));
    assert!(h.has_stored_pairing());
}

#[test]
fn pairs_again_when_the_pairing_kept_does_not_read() {
    // An entry that is not the installer's encoding at all: picking the
    // iPhone must not fail on it each time.
    let h = Harness::new();
    h.select_device().expect("pairing");
    let pairing = format!("rppairing1.1_file_{}", h.iphone.udid());
    let label = format!("host_label_{}", h.iphone.udid());
    h.keychain.set(&h.keyring_service, &pairing, b"<plist>not base64");
    h.keychain.set(&h.keyring_service, &label, b"%%%");
    assert!(!h.has_stored_pairing());

    h.select_device().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(h.iphone.state().pair_setups, 2);
    assert!(h.has_stored_pairing());
}

#[test]
fn forgets_the_iphone_deselected() {
    let h = Harness::new();
    h.select_device().expect("pairing");
    h.invoke("set_selected_device", json!({})).expect("deselect");
    for cmd in ["installed_cartouche", "delete_stored_rppairing", "place_cartouche_pairing_operation"] {
        let error = h.invoke(cmd, json!({})).expect_err(cmd);
        assert_eq!(error_type(&error), "no_device_selected", "{cmd}: {error}");
    }
}

#[test]
fn lists_no_iphone_when_none_is_plugged_in() {
    let h = Harness::new();
    h.usbmuxd.unplug(&h.iphone);
    assert_eq!(h.invoke("list_devices", json!({})), Ok(json!([])));
    h.usbmuxd.plug(&h.iphone);
    assert_eq!(h.devices().len(), 1);
}

#[test]
fn says_when_apples_drivers_are_missing() {
    // A PC without iTunes or Apple Devices: nothing at usbmuxd's address.
    let h = Harness::start(Setup { usbmuxd_running: false, ..Setup::default() });
    let error = h.invoke("list_devices", json!({})).expect_err("listed without usbmuxd");
    assert_eq!(error_type(&error), "usbmuxd", "{error}");
}

#[test]
fn lists_every_iphone_plugged_in() {
    let h = Harness::new();
    let old = FakeIphone::new(IphoneConfig::ios_17_3(2));
    h.usbmuxd.plug(&old);
    let devices = h.devices();
    let mut names: Vec<&str> = devices.iter().filter_map(|d| d["name"].as_str()).collect();
    names.sort();
    assert_eq!(names, ["Vieil iPhone 2", "iPhone de Test 1"]);
    let old_one = devices.iter().find(|d| d["udid"] == old.udid()).unwrap();
    assert_eq!(old_one["version"], "17.3.1");
    // Before iOS 17.4, nothing to keep: the window may pick it at once.
    assert_eq!(h.invoke("has_stored_rppairing", json!({ "device": old_one })), Ok(Value::Bool(true)));
}
