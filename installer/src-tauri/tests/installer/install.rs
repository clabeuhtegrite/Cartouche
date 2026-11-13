//! Installing Cartouche: from the Install button, from a file, again over
//! itself, and everything iOS or Apple can refuse on the way.

use serde_json::{Value, json};

use crate::harness::*;

/// The steps of an install that goes through, as the window shows them.
fn all_steps(steps: &[&str]) -> Vec<(String, String)> {
    steps
        .iter()
        .flat_map(|s| [("started".to_string(), s.to_string()), ("finished".to_string(), s.to_string())])
        .collect()
}

fn increasing(values: &[f64]) -> bool {
    values.windows(2).all(|w| w[0] <= w[1]) && values.iter().all(|v| (0.0..=1.0).contains(v))
}

#[test]
fn installs_cartouche_on_a_new_iphone() {
    let h = Harness::new();
    let version = h.publish_cartouche();
    let team = h.team_id.clone();

    // The window lists the iPhone by its name, with its iOS.
    let device = h.device();
    assert_eq!(device["name"], h.iphone.config().name);
    assert_eq!(device["version"], "26.1");
    assert_eq!(device["connectionType"], "USB");

    // Picked, it asks "Trust This Computer?" once, turns on what
    // Cartouche's SideStore needs, and the installer keeps the pairing.
    assert!(!h.has_stored_pairing());
    h.select_device().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert!(h.has_stored_pairing());
    let (setups, wifi, hosts) = {
        let state = h.iphone.state();
        (state.pair_setups, state.wifi_debugging, state.rp_hosts.clone())
    };
    assert_eq!(setups, 1);
    assert!(wifi, "Wi-Fi debugging stays off");
    assert_eq!(hosts.len(), 1);
    assert!(hosts[0].name.starts_with("cartouche-"), "{}", hosts[0].name);

    // A code from a trusted device, once.
    h.sign_in(false).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(h.events("2fa-required").len(), 1);
    assert_eq!(h.invoke("logged_in_as", json!({})), Ok(json!(EMAIL)));

    // The window names the release before it installs it.
    let release = h.invoke("cartouche_release", json!({})).expect("release");
    assert_eq!(release["version"], version);
    assert_eq!(h.invoke("installed_cartouche", json!({})), Ok(Value::Null));

    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(h.steps("install_cartouche"), all_steps(&["download", "install", "pairing"]));
    let download = h.progress("install_cartouche", "download");
    assert!(increasing(&download) && download.last() == Some(&1.0), "{download:?}");
    let install = h.progress("install_cartouche", "install");
    assert!(!install.is_empty() && increasing(&install), "{install:?}");

    // On the iPhone: Cartouche, signed for the team, as iOS checks it.
    let app = h.iphone.app(BUNDLE_ID).expect("Cartouche on the iPhone");
    assert_eq!(app.bundle_id, format!("{BUNDLE_ID}.{team}"));
    assert_eq!(app.info.get("CFBundleShortVersionString"), Some(&version.clone().into()));
    assert_eq!(app.signature.team_id, team);
    assert!(app.signature.free_profile);
    let entitlements = &app.signature.entitlements;
    assert_eq!(
        entitlements.get("application-identifier"),
        Some(&format!("{team}.{BUNDLE_ID}.{team}").into())
    );
    // Increased Memory Limit: without it, the games get 3 GB.
    assert_eq!(entitlements.get("com.apple.developer.kernel.increased-memory-limit"), Some(&true.into()));
    let group = format!("group.com.SideStore.SideStore.{team}");
    let groups = entitlements["com.apple.security.application-groups"].as_array().expect("groups");
    assert!(groups.contains(&group.clone().into()), "{groups:?}");
    let keychain_groups = entitlements["keychain-access-groups"].as_array().expect("keychain groups");
    assert!(keychain_groups.contains(&format!("{team}.com.kdt.livecontainer.shared").into()));
    assert_eq!(app.signature.info.get("ALTAppGroups"), Some(&vec![plist::Value::from(group.clone())].into()));

    // The certificate SideStore renews with, in SideStore's framework.
    let serial = h
        .apple
        .with_account(EMAIL, |a| {
            a.team.certificates.iter().find(|c| c.machine_name == "Cartouche").map(|c| c.serial.clone())
        })
        .expect("the installer's certificate");
    let sidestore = app
        .signature
        .bundles
        .iter()
        .find(|b| b.path == "Frameworks/SideStoreApp.framework")
        .expect("SideStore's framework");
    assert_eq!(sidestore.info.get("ALTCertificateID"), Some(&serial.clone().into()));
    let p12 = app.files.get("Frameworks/SideStoreApp.framework/ALTCertificate.p12").expect("ALTCertificate.p12");
    assert_eq!(p12.first(), Some(&0x30), "a PKCS #12");

    // LiveProcess and the widget, each under the team's identifier, with
    // the app's profile.
    for extension in ["LiveProcess", "LiveWidget"] {
        let bundle = app
            .signature
            .bundles
            .iter()
            .find(|b| b.bundle_id == format!("{BUNDLE_ID}.{team}.{extension}"))
            .unwrap_or_else(|| panic!("{extension} not signed for the team"));
        assert!(bundle.has_profile);
        assert_eq!(bundle.team_id, team);
    }

    // Apple: the App ID, with Increased Memory Limit and the group; the
    // iPhone; one certificate, the installer's.
    let (app_id, devices, certificates) = h.apple.with_account(EMAIL, |a| {
        (
            a.team.app_ids.iter().find(|id| id.identifier == app.bundle_id).cloned(),
            a.team.devices.iter().map(|d| d.udid.clone()).collect::<Vec<_>>(),
            a.team.certificates.len(),
        )
    });
    let app_id = app_id.expect("Cartouche's App ID");
    assert!(app_id.increased_memory_limit);
    assert!(app_id.groups.contains(&group));
    assert_eq!(devices, [h.iphone.udid()]);
    assert_eq!(certificates, 1);

    // The pairing file where Cartouche's SideStore reads it: lockdown's,
    // and the remote pairing the iPhone trusts.
    let pairing = read_plist(
        &h.iphone
            .container_file(&app.bundle_id, PAIRING_FILE)
            .unwrap_or_else(|| panic!("no pairing file\n{}", h.report())),
    );
    assert_eq!(pairing.get("UDID"), Some(&h.iphone.udid().into()));
    for key in [
        "HostID",
        "SystemBUID",
        "HostCertificate",
        "HostPrivateKey",
        "RootCertificate",
        "DeviceCertificate",
        "WiFiMACAddress",
        "public_key",
        "private_key",
        "identifier",
    ] {
        assert!(pairing.contains_key(key), "the pairing file has no {key}");
    }
    let host = pairing["identifier"].as_string().expect("identifier");
    assert!(hosts.iter().any(|h| h.identifier == host), "{host} is not a host the iPhone trusts");

    // The window shows Cartouche installed, at that version.
    assert_eq!(
        h.invoke("installed_cartouche", json!({})),
        Ok(json!({ "bundleId": app.bundle_id, "version": version }))
    );

    // Nothing left of it in the temporary folder.
    let temp = std::env::temp_dir();
    assert!(!temp.join(format!("Cartouche-{version}.ipa")).exists());
    assert!(!temp.join(format!("Cartouche-{version}.ipa_extracted")).exists());
}

#[test]
fn installs_cartouche_from_a_file() {
    let h = Harness::new();
    let version = h.new_version();
    let ipa = h.write_ipa("Cartouche", &CartoucheIpa::new(&version).build());
    h.ready();

    h.install_file(&ipa).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(h.steps("install_cartouche"), all_steps(&["download", "install", "pairing"]));
    let app = h.iphone.app(BUNDLE_ID).expect("Cartouche on the iPhone");
    assert_eq!(app.info.get("CFBundleShortVersionString"), Some(&version.into()));
    assert!(h.iphone.container_file(&app.bundle_id, PAIRING_FILE).is_some());
    // Nothing from GitHub, and the player's file stays.
    assert!(h.github.state().requests.is_empty());
    assert!(ipa.exists());
    let unpacked = std::env::temp_dir().join(format!("{}_extracted", ipa.file_name().unwrap().to_string_lossy()));
    assert!(!unpacked.exists());
}

#[test]
fn refuses_the_ipa_of_another_app() {
    let h = Harness::new();
    let ipa = h.write_ipa("Mario", &other_app_ipa("com.example.mario", "Mario"));
    h.ready();

    let error = h.install_file(&ipa).expect_err("installed another app");
    assert_eq!(error_type(&error), "not_cartouche");
    assert!(error["message"].as_str().unwrap().contains("com.example.mario"), "{error}");
    let (step, shown) = h.failure("install_cartouche").expect("a failed step");
    assert_eq!(step, "download");
    assert_eq!(shown, error);
    assert!(h.iphone.state().apps.is_empty());
    // Not even an App ID asked for.
    assert!(h.apple.with_account(EMAIL, |a| a.team.app_ids.is_empty()));
}

#[test]
fn refuses_a_file_that_is_not_an_ipa() {
    let h = Harness::new();
    let file = h.write_ipa("Notes", b"not a zip at all");
    h.ready();

    let error = h.install_file(&file).expect_err("installed a text file");
    assert_eq!(error_type(&error), "not_cartouche");
    assert!(h.iphone.state().apps.is_empty());
}

#[test]
fn asks_for_the_iphone_and_the_account_first() {
    let h = Harness::new();
    h.publish_cartouche();

    let error = h.install().expect_err("installed without an iPhone");
    assert_eq!(error_type(&error), "no_device_selected");
    assert_eq!(h.failure("install_cartouche").map(|f| f.0).as_deref(), Some("download"));

    h.select_device().expect("pairing");
    let error = h.install().expect_err("installed without an account");
    assert_eq!(error_type(&error), "not_logged_in");
    assert!(h.github.state().requests.is_empty(), "downloaded for nothing");

    assert_eq!(h.invoke("logged_in_as", json!({})), Ok(Value::Null));
    assert!(h.iphone.state().apps.is_empty());
}

#[test]
fn updates_the_cartouche_installed() {
    let h = Harness::new();
    let first = h.publish_cartouche();
    h.ready();
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let installed = h.iphone.app(BUNDLE_ID).expect("Cartouche");
    // What Cartouche keeps in its Documents stays through the update.
    {
        let mut state = h.iphone.state();
        let container = &mut state.apps.get_mut(&installed.bundle_id).unwrap().container;
        container.mkdir_p("Documents/Games").expect("folder");
        container.write("Documents/Games/save.dat", b"progress".to_vec()).expect("write");
    }

    let second = h.publish_cartouche();
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));

    let app = h.iphone.app(BUNDLE_ID).expect("Cartouche");
    assert_eq!(app.bundle_id, installed.bundle_id);
    assert_eq!(app.info.get("CFBundleShortVersionString"), Some(&second.clone().into()));
    assert_ne!(first, second);
    assert_eq!(h.iphone.state().apps.len(), 1);
    assert_eq!(
        h.iphone.container_file(&app.bundle_id, "Documents/Games/save.dat").as_deref(),
        Some(&b"progress"[..])
    );
    assert!(h.iphone.container_file(&app.bundle_id, PAIRING_FILE).is_some());
    // The same certificate, the same App IDs: an update takes none of the
    // ten App IDs a week a free account has.
    let (certificates, app_ids, available) = h.apple.with_account(EMAIL, |a| {
        (a.team.certificates.len(), a.team.app_ids.len(), a.team.available_app_ids)
    });
    assert_eq!(certificates, 1);
    let after_first = 10 - available;
    assert_eq!(app_ids as i64, after_first, "App IDs registered again");
    assert_eq!(
        h.invoke("installed_cartouche", json!({})).unwrap()["version"],
        json!(second)
    );
}

#[test]
fn installs_cartouche_on_an_iphone_before_ios_17_4() {
    // No remote pairing before iOS 17.4: lockdown's pairing only.
    let h = Harness::start(Setup { iphone: IphoneConfig::ios_17_3(1), ..Setup::default() });
    h.publish_cartouche();
    assert!(h.has_stored_pairing(), "the window picks it at once");
    h.ready();
    assert_eq!(h.iphone.state().pair_setups, 0);
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));

    let app = h.iphone.app(BUNDLE_ID).expect("Cartouche");
    let pairing = read_plist(&h.iphone.container_file(&app.bundle_id, PAIRING_FILE).expect("pairing file"));
    assert_eq!(pairing.get("UDID"), Some(&h.iphone.udid().into()));
    assert!(pairing.contains_key("HostID"));
    assert!(!pairing.contains_key("public_key"));
}

#[test]
fn says_when_the_iphone_has_three_free_apps_already() {
    let h = Harness::new();
    h.publish_cartouche();
    for app in ["com.example.one", "com.example.two", "com.example.three"] {
        h.iphone.preinstall(app, "1.0", true);
    }
    h.ready();

    let error = h.install().expect_err("a fourth free app");
    assert_eq!(error_type(&error), "max_apps", "{error}");
    assert_eq!(h.failure("install_cartouche").map(|f| f.0).as_deref(), Some("install"));
    assert!(h.iphone.app(BUNDLE_ID).is_none());
}

#[test]
fn says_when_the_account_has_no_app_ids_left() {
    let h = Harness::new();
    h.publish_cartouche();
    h.apple.with_account(EMAIL, |a| a.team.available_app_ids = 0);
    h.ready();

    let error = h.install().expect_err("installed without App IDs");
    assert_eq!(error_type(&error), "not_enough_app_ids", "{error}");
    assert!(h.iphone.app(BUNDLE_ID).is_none());
}

#[test]
fn says_what_ios_refused_and_leaves_nothing_behind() {
    let h = Harness::new();
    let version = h.publish_cartouche();
    h.ready();
    h.iphone.state().fail_install = Some((
        "ApplicationVerificationFailed".into(),
        "Failed to verify code signature of /private/var/installd/Cartouche.app".into(),
    ));

    let error = h.install().expect_err("iOS refused it");
    assert!(error["message"].as_str().unwrap().contains("Failed to verify code signature"), "{error}");
    assert_eq!(h.failure("install_cartouche").map(|f| f.0).as_deref(), Some("install"));
    assert!(h.iphone.app(BUNDLE_ID).is_none());
    let temp = std::env::temp_dir();
    assert!(!temp.join(format!("Cartouche-{version}.ipa")).exists(), "the download stays");
    assert!(
        !temp.join(format!("Cartouche-{version}.ipa_extracted")).exists(),
        "the unpacked IPA stays in the temporary folder"
    );

    // Once iOS takes it, the same install goes through.
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert!(h.iphone.app(BUNDLE_ID).is_some());
}

#[test]
fn says_when_the_iphone_is_unplugged() {
    let h = Harness::new();
    h.publish_cartouche();
    h.ready();
    h.usbmuxd.unplug(&h.iphone);

    let error = h.install().expect_err("installed on an unplugged iPhone");
    assert_eq!(error_type(&error), "device_coms_with_message", "{error}");
    assert_eq!(h.failure("install_cartouche").map(|f| f.0).as_deref(), Some("install"));
    assert!(h.devices().is_empty());

    h.usbmuxd.plug(&h.iphone);
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
}

#[test]
fn revokes_the_certificate_the_player_picks() {
    let h = Harness::new();
    h.publish_cartouche();
    // SideStore and Xcode on other computers: the two a free account has.
    let sidestore = h.apple.add_foreign_certificate(EMAIL, "SideStore");
    let xcode = h.apple.add_foreign_certificate(EMAIL, "MacBook de Camille");
    h.answer_certificates(Some(vec![xcode.clone()]));
    h.ready();

    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));

    let asked = h.events("max-certs-reached");
    assert_eq!(asked.len(), 1);
    let listed: Vec<&str> = asked[0].as_array().unwrap().iter().filter_map(|c| c["serialNumber"].as_str()).collect();
    assert!(listed.contains(&sidestore.as_str()) && listed.contains(&xcode.as_str()), "{listed:?}");
    let machines: Vec<&str> = asked[0].as_array().unwrap().iter().filter_map(|c| c["machineName"].as_str()).collect();
    assert!(machines.contains(&"MacBook de Camille"), "{machines:?}");
    let serials = h.apple.with_account(EMAIL, |a| {
        a.team.certificates.iter().map(|c| (c.serial.clone(), c.machine_name.clone())).collect::<Vec<_>>()
    });
    assert!(serials.iter().any(|(s, _)| *s == sidestore), "revoked the one kept");
    assert!(serials.iter().all(|(s, _)| *s != xcode), "kept the one picked");
    assert!(serials.iter().any(|(_, m)| m == "Cartouche"));
    assert!(h.iphone.app(BUNDLE_ID).is_some());
}

#[test]
fn keeps_every_certificate_when_the_player_cancels() {
    let h = Harness::new();
    h.publish_cartouche();
    h.apple.add_foreign_certificate(EMAIL, "SideStore");
    h.apple.add_foreign_certificate(EMAIL, "MacBook de Camille");
    h.answer_certificates(None);
    h.ready();

    let error = h.install().expect_err("installed without a certificate");
    assert_eq!(h.failure("install_cartouche").map(|f| f.0).as_deref(), Some("install"), "{error}");
    assert_eq!(h.events("max-certs-reached").len(), 1);
    assert_eq!(h.apple.with_account(EMAIL, |a| a.team.certificates.len()), 2);
    assert!(h.iphone.app(BUNDLE_ID).is_none());
}

#[test]
fn puts_the_pairing_file_in_cartouche_again() {
    let h = Harness::new();
    h.publish_cartouche();
    h.ready();
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let app = h.iphone.app(BUNDLE_ID).expect("Cartouche");
    let first = h.iphone.container_file(&app.bundle_id, PAIRING_FILE).expect("pairing file");

    // Settings' "Delete stored pairing", then the iPhone picked again: a new
    // pairing, which Cartouche needs too.
    h.invoke("delete_stored_rppairing", json!({})).expect("delete");
    h.invoke("set_selected_device", json!({})).expect("deselect");
    h.select_device().expect("pairing again");
    assert_eq!(h.iphone.state().pair_setups, 2);

    h.invoke("place_cartouche_pairing_operation", json!({}))
        .unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(h.steps("place_cartouche_pairing"), all_steps(&["pairing"]));
    let second = h.iphone.container_file(&app.bundle_id, PAIRING_FILE).expect("pairing file");
    assert_ne!(first, second);
    let identifier = read_plist(&second)["identifier"].as_string().unwrap().to_string();
    let newest = h.iphone.state().rp_hosts.last().map(|h| h.identifier.clone());
    assert_eq!(Some(identifier), newest);
}

#[test]
fn says_when_cartouche_is_not_there_for_its_pairing_file() {
    let h = Harness::new();
    h.select_device().expect("pairing");
    let error = h.invoke("place_cartouche_pairing_operation", json!({})).expect_err("no Cartouche");
    assert_eq!(error_type(&error), "cartouche_missing");
    assert_eq!(h.failure("place_cartouche_pairing").map(|f| f.0).as_deref(), Some("pairing"));
}

#[test]
fn says_when_cartouche_cannot_take_its_pairing_file() {
    // A Cartouche whose Documents the Files app cannot reach: house_arrest
    // refuses it too.
    let h = Harness::new();
    let version = h.new_version();
    let ipa = h.write_ipa("Cartouche", &CartoucheIpa { file_sharing: false, ..CartoucheIpa::new(&version) }.build());
    h.ready();

    let error = h.install_file(&ipa).expect_err("placed the pairing file");
    assert_eq!(error_type(&error), "house_arrest", "{error}");
    assert_eq!(h.failure("install_cartouche").map(|f| f.0).as_deref(), Some("pairing"));
    assert!(h.iphone.app(BUNDLE_ID).is_some(), "installed all the same");
}

#[test]
fn finds_the_newest_of_two_cartouches() {
    // Cartouche installed by another Apple ID before: the iPhone keeps both.
    let h = Harness::new();
    h.iphone.preinstall(&format!("{BUNDLE_ID}.OTHERTEAM1"), "0.1.0", true);
    h.publish_cartouche();
    h.select_device().expect("pairing");
    assert_eq!(
        h.invoke("installed_cartouche", json!({})),
        Ok(json!({ "bundleId": format!("{BUNDLE_ID}.OTHERTEAM1"), "version": "0.1.0" }))
    );
    h.sign_in(false).expect("sign-in");
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));

    let ours = format!("{BUNDLE_ID}.{}", h.team_id);
    assert_eq!(h.invoke("installed_cartouche", json!({})).unwrap()["bundleId"], json!(ours));
    assert!(h.iphone.container_file(&ours, PAIRING_FILE).is_some());
    assert!(h.iphone.container_file(&format!("{BUNDLE_ID}.OTHERTEAM1"), PAIRING_FILE).is_none());
}

#[test]
fn installs_on_the_iphone_picked_of_two() {
    let h = Harness::new();
    let other = FakeIphone::new(IphoneConfig::iphone_17_pro(2));
    h.usbmuxd.plug(&other);
    h.publish_cartouche();

    let devices = h.devices();
    assert_eq!(devices.len(), 2, "{devices:?}");
    let second = devices.iter().find(|d| d["udid"] == other.udid()).cloned().expect("the second iPhone");
    h.invoke("set_selected_device", json!({ "device": second })).expect("pairing");
    h.sign_in(false).expect("sign-in");
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));

    assert!(other.app(BUNDLE_ID).is_some());
    assert!(h.iphone.app(BUNDLE_ID).is_none());
    assert_eq!(h.iphone.state().pair_setups, 0);
    assert_eq!(h.apple.with_account(EMAIL, |a| a.team.devices.iter().map(|d| d.udid.clone()).collect::<Vec<_>>()), [other.udid()]);
}

#[test]
fn says_what_apple_refused_and_tries_again() {
    let h = Harness::new();
    h.publish_cartouche();
    h.ready();
    h.apple.fail_next(
        "addAppId",
        Failure::Developer(
            9401,
            "An App ID with Identifier 'io.github.clabeuhtegrite.cartouche' is not available. Please enter a different string.".into(),
        ),
    );
    let error = h.install().expect_err("installed without an App ID");
    assert_eq!(error_type(&error), "developer", "{error}");
    assert!(error["message"].as_str().unwrap().contains("is not available"), "{error}");
    assert_eq!(h.failure("install_cartouche").map(|f| f.0).as_deref(), Some("install"));

    // Nothing half done stands in the way of the next try.
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert!(h.iphone.app(BUNDLE_ID).is_some());
}
