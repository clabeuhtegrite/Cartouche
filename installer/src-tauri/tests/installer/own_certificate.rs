//! Installing Cartouche with the player's own signing certificate (.p12)
//! and its provisioning profile, in place of an Apple ID: signed on the
//! computer, checked by the iPhone as iOS checks it, the certificate handed
//! to Cartouche sealed, and everything the installer refuses before that.

use std::{
    path::{Path, PathBuf},
    time::{Duration, SystemTime},
};

use aes_gcm::{
    Aes256Gcm, Nonce,
    aead::{Aead, KeyInit, Payload},
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tauri_plugin_store::StoreExt;

use crate::harness::*;

/// Where the installer leaves the certificate for Cartouche, in its
/// container: Cartouche opens it at its first start, then deletes it.
const HANDOFF: &str = "Documents/CartoucheSigning.plist";
const DAY: Duration = Duration::from_secs(24 * 3600);

fn all_steps(steps: &[&str]) -> Vec<(String, String)> {
    steps
        .iter()
        .flat_map(|s| [("started".to_string(), s.to_string()), ("finished".to_string(), s.to_string())])
        .collect()
}

fn increasing(values: &[f64]) -> bool {
    values.windows(2).all(|w| w[0] <= w[1]) && values.iter().all(|v| (0.0..=1.0).contains(v))
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

/// The step and the error of the install that failed last.
fn last_failure(h: &Harness) -> (String, Value) {
    h.events("operation_install_cartouche")
        .iter()
        .rev()
        .find(|u| u["updateType"] == "failed")
        .map(|u| (u["stepId"].as_str().unwrap_or("").to_string(), u["extraDetails"].clone()))
        .expect("a step that failed")
}

/// What Cartouche opens at its first start: the file the installer left in
/// its Documents, opened with the key of its signed Info.plist, as
/// Cartouche opens it (launcher/Sources/CartoucheSigningMaterial.swift).
fn handoff(h: &Harness) -> Option<plist::Dictionary> {
    let app = h.iphone.app(BUNDLE_ID)?;
    let sealed = h.iphone.container_file(&app.bundle_id, HANDOFF)?;
    let key = app.info.get("CartoucheSigningHandoffKey")?.as_data()?.to_vec();
    let cipher = Aes256Gcm::new_from_slice(&key).expect("a 256-bit key");
    let nonce = Nonce::from(<[u8; 12]>::try_from(sealed.get(..12)?).ok()?);
    let opened = cipher
        .decrypt(&nonce, Payload { msg: &sealed[12..], aad: b"CartoucheSigningHandoff.v1" })
        .ok()?;
    Some(read_plist(&opened))
}

/// What installing this version left in the computer's temporary folder:
/// the IPA downloaded, or a copy of Cartouche signed there.
fn leftovers(version: &str) -> Vec<PathBuf> {
    let temp = std::env::temp_dir();
    let mut found: Vec<PathBuf> = [temp.join(format!("Cartouche-{version}.ipa"))]
        .into_iter()
        .filter(|ipa| ipa.exists())
        .collect();
    for entry in std::fs::read_dir(&temp).into_iter().flatten().flatten() {
        let Ok(info) = std::fs::read(entry.path().join("Payload/LiveContainer.app/Info.plist")) else {
            continue;
        };
        let this_version = plist::from_bytes::<plist::Dictionary>(&info)
            .ok()
            .and_then(|info| info.get("CFBundleShortVersionString").and_then(|v| v.as_string().map(str::to_string)));
        if this_version.as_deref() == Some(version) {
            found.push(entry.path());
        }
    }
    found
}

fn files_under(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.is_dir() {
            found.extend(files_under(&path));
        } else {
            found.push(path);
        }
    }
    found
}

/// Whether the installer kept `secret` anywhere on the computer: in the
/// keychain, its settings or its data folder.
fn kept_on_the_computer(h: &Harness, secret: &str) -> bool {
    let in_keychain = h.keychain.users(&h.keyring_service).iter().any(|user| {
        user.contains(secret)
            || h.keychain
                .get(&h.keyring_service, user)
                .is_some_and(|value| contains(&value, secret.as_bytes()))
    });
    let store = h.app.store("data.json").expect("store");
    let in_settings = serde_json::to_string(&store.entries()).expect("settings").contains(secret);
    let in_files = files_under(&h.data_dir())
        .iter()
        .any(|path| std::fs::read(path).is_ok_and(|bytes| contains(&bytes, secret.as_bytes())));
    in_keychain || in_settings || in_files
}

#[test]
fn installs_with_the_players_own_certificate_without_an_apple_id() {
    let h = Harness::new();
    let version = h.publish_cartouche();
    let own = h.own_signing();
    let files = own.write(&h.dir);

    // The window checks the profile as soon as it is chosen, and says
    // whether it has Increased Memory Limit.
    let checked = h.check_profile(&files).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(checked["increasedMemoryLimit"], true);
    let profile_bytes = std::fs::read(&files.profile).expect("profile");
    assert_eq!(checked["sha256"], hex::encode(Sha256::digest(&profile_bytes)));

    // An iPhone first, as with an Apple ID; then no sign-in.
    let error = h.install_checked(&files, &checked, None).expect_err("installed without an iPhone");
    assert_eq!(error_type(&error), "no_device_selected");
    h.select_device().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    h.install_checked(&files, &checked, None).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let steps = h.steps("install_cartouche");
    assert_eq!(steps[steps.len() - 6..], all_steps(&["download", "install", "pairing"]), "{steps:?}");
    let install = h.progress("install_cartouche", "install");
    assert!(increasing(&install) && install.last() == Some(&1.0), "{install:?}");

    // On the iPhone: Cartouche under its own identifier, signed with the
    // player's certificate and profile, as iOS checks it.
    let app = h.iphone.app(BUNDLE_ID).unwrap_or_else(|| panic!("Cartouche not installed\n{}", h.report()));
    let team = own.team_id.clone();
    assert_eq!(app.bundle_id, BUNDLE_ID);
    assert_eq!(app.info.get("CFBundleShortVersionString"), Some(&version.clone().into()));
    assert_eq!(app.info.get("CartoucheImportedSigning"), Some(&true.into()));
    assert_eq!(app.signature.team_id, team);
    assert_eq!(app.signature.signer_certificate, own.certificate);
    assert!(!app.signature.free_profile);
    assert_eq!(app.signature.profile.get("UUID"), own.profile.get("UUID"));
    assert_eq!(app.files.get("embedded.mobileprovision"), Some(&profile_bytes));
    let entitlements = &app.signature.entitlements;
    assert_eq!(entitlements.get("application-identifier"), Some(&format!("{team}.{BUNDLE_ID}").into()));
    assert_eq!(entitlements.get("com.apple.developer.team-identifier"), Some(&team.clone().into()));
    // Increased Memory Limit, which the profile grants: without it, the
    // games get 3 GB.
    assert_eq!(entitlements.get("com.apple.developer.kernel.increased-memory-limit"), Some(&true.into()));
    // No app group, and the keychain groups LiveContainer gives the games.
    assert!(!entitlements.contains_key("com.apple.security.application-groups"), "{entitlements:?}");
    let groups = entitlements["keychain-access-groups"].as_array().expect("keychain groups");
    for group in [
        format!("{team}.{BUNDLE_ID}"),
        format!("{team}.com.kdt.livecontainer.shared"),
        format!("{team}.com.kdt.livecontainer.shared.127"),
    ] {
        assert!(groups.contains(&group.clone().into()), "{group} not in {groups:?}");
    }
    // Its frameworks signed for the team, and no extension: one profile
    // does not cover theirs, and the games start in Cartouche's place.
    for framework in ["Frameworks/LiveContainerShared.framework", "Frameworks/SideStoreApp.framework"] {
        let bundle = app.signature.bundles.iter().find(|b| b.path == framework).expect(framework);
        assert_eq!(bundle.team_id, team, "{framework}");
    }
    assert!(app.files.keys().all(|path| !path.starts_with("PlugIns/")), "{:?}", app.files.keys());

    // In its Documents, the .p12, its password and the profile, sealed
    // with the key of its signed Info.plist; no pairing file, since
    // nothing renews such an install.
    let handoff = handoff(&h).unwrap_or_else(|| panic!("no certificate for Cartouche\n{}", h.report()));
    let p12 = std::fs::read(&files.p12).expect("p12");
    assert_eq!(handoff.get("certificate").and_then(|v| v.as_data()), Some(p12.as_slice()));
    assert_eq!(handoff.get("password").and_then(|v| v.as_string()), Some(files.password.as_str()));
    assert_eq!(handoff.get("profile").and_then(|v| v.as_data()), Some(profile_bytes.as_slice()));
    let sealed = h.iphone.container_file(BUNDLE_ID, HANDOFF).expect("sealed");
    assert!(!contains(&sealed, files.password.as_bytes()) && !contains(&sealed, &p12[..64]));
    assert_eq!(h.iphone.container_file(BUNDLE_ID, PAIRING_FILE), None);

    // Apple took no part: no sign-in, no anisette, no developer services.
    assert_eq!(h.apple.log(), Vec::<String>::new());
    assert!(h.anisette.state().log.is_empty(), "{:?}", h.anisette.state().log);

    // The window finds it installed and up to date.
    assert_eq!(
        h.invoke("installed_cartouche", json!({})),
        Ok(json!({ "bundleId": BUNDLE_ID, "version": version }))
    );

    // Nothing left on the computer: no IPA, no signed copy, and the
    // password nowhere.
    assert_eq!(leftovers(&version), Vec::<PathBuf>::new());
    assert!(!kept_on_the_computer(&h, &files.password));
}

#[test]
fn says_what_is_wrong_with_the_certificate_or_the_profile_before_installing() {
    let h = Harness::new();
    let version = h.publish_cartouche();
    h.select_device().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let now = SystemTime::now();
    let mut cases: Vec<(&str, OwnSigning, &str)> = Vec::new();

    let mut own = h.own_signing();
    own.profile.insert("ExpirationDate".into(), plist::Value::Date((now - DAY).into()));
    cases.push(("an expired profile", own, "The provisioning profile has expired."));

    let mut own = h.own_signing();
    own.reissue(now - 400 * DAY, now - DAY);
    cases.push(("an expired certificate", own, "The signing certificate is expired or is not yet valid."));

    let mut own = h.own_signing();
    own.reissue(now + DAY, now + 400 * DAY);
    cases.push(("a certificate not valid yet", own, "The signing certificate is expired or is not yet valid."));

    let mut own = h.own_signing();
    own.profile.insert(
        "ProvisionedDevices".into(),
        vec![plist::Value::from("00008150-000A1B2C3D4E5F60")].into(),
    );
    cases.push(("another iPhone's profile", own, "This provisioning profile does not include the selected iPhone."));

    let mut own = h.own_signing();
    let other = h.own_signing();
    own.profile.insert("DeveloperCertificates".into(), vec![plist::Value::Data(other.certificate.clone())].into());
    cases.push(("another certificate's profile", own, "The certificate does not match the provisioning profile."));

    let mut own = h.own_signing();
    let app_only = vec![plist::Value::from(format!("{}.{BUNDLE_ID}", own.team_id))];
    own.entitlements().insert("keychain-access-groups".into(), app_only.into());
    cases.push(("a profile without the games' keychain groups", own, "does not authorize all game keychain groups"));

    let mut own = h.own_signing();
    own.entitlements().remove("keychain-access-groups");
    cases.push(("a profile without keychain groups", own, "does not authorize the keychain groups games require"));

    for (case, own, says) in cases {
        let files = own.write(&h.dir);
        let error = h.install_own(&files).expect_err(case);
        let (step, shown) = last_failure(&h);
        assert_eq!(step, "install", "{case}");
        assert_eq!(shown, error, "{case}");
        assert!(error["message"].as_str().is_some_and(|m| m.contains(says)), "{case}: {error}");
        assert!(h.iphone.app(BUNDLE_ID).is_none(), "{case}: installed\n{}", h.report());
    }

    // A file that is no profile: the window says so when it is chosen.
    let files = h.own_signing().write(&h.dir);
    std::fs::write(&files.profile, b"<plist>not signed by Apple</plist>").expect("write");
    let error = h.check_profile(&files).expect_err("a profile that is none");
    assert_eq!(error["message"], "Cannot read this Apple provisioning profile.");

    assert_eq!(leftovers(&version), Vec::<PathBuf>::new());
    assert_eq!(h.apple.log(), Vec::<String>::new());
}

#[test]
fn refuses_a_wrong_password_without_repeating_it() {
    let h = Harness::new();
    let version = h.publish_cartouche();
    h.select_device().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let right = h.own_signing().write(&h.dir);
    let wrong = OwnFiles { password: "Tr0mpé-de-mot-de-passe".into(), ..right.clone() };

    let error = h.install_own(&wrong).expect_err("installed with a wrong password");
    assert_eq!(
        error["message"],
        "Cannot open the P12. Check its password and that it contains a private key."
    );
    assert!(h.iphone.app(BUNDLE_ID).is_none());
    let everything = format!("{:?}", h.events("operation_install_cartouche"));
    assert!(!everything.contains(&wrong.password) && !everything.contains(&right.password), "{everything}");

    // Typed again, right.
    h.install_own(&right).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert!(h.iphone.app(BUNDLE_ID).is_some());
    assert!(!kept_on_the_computer(&h, &right.password));
    assert_eq!(leftovers(&version), Vec::<PathBuf>::new());
}

#[test]
fn checks_a_profile_again_when_it_changed_after_it_was_chosen() {
    let h = Harness::new();
    h.publish_cartouche();
    h.select_device().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let mut own = h.own_signing();
    let files = own.write(&h.dir);
    let checked = h.check_profile(&files).expect("checked");
    assert_eq!(checked["increasedMemoryLimit"], true);

    // Another profile in its place, without Increased Memory Limit: the
    // window said it had it, so the installer does not take it.
    own.entitlements().remove("com.apple.developer.kernel.increased-memory-limit");
    std::fs::write(&files.profile, own.mobileprovision()).expect("write");
    let error = h.install_checked(&files, &checked, None).expect_err("installed with a profile not checked");
    assert_eq!(
        error["message"],
        "The provisioning profile changed. Choose it again to review its permissions before installing."
    );
    assert!(h.iphone.app(BUNDLE_ID).is_none());

    // Chosen again, the window says it has no Increased Memory Limit, and
    // Cartouche installs without it.
    let checked = h.check_profile(&files).expect("checked");
    assert_eq!(checked["increasedMemoryLimit"], false);
    h.install_checked(&files, &checked, None).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let app = h.iphone.app(BUNDLE_ID).expect("installed");
    assert!(
        !app.signature.entitlements.contains_key("com.apple.developer.kernel.increased-memory-limit"),
        "{:?}",
        app.signature.entitlements
    );
}

#[test]
fn installs_with_an_enterprise_profile_or_one_made_for_cartouche_alone() {
    let h = Harness::new();
    h.publish_cartouche();
    h.select_device().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));

    // An enterprise profile: every iPhone, none listed.
    let mut own = h.own_signing();
    own.profile.remove("ProvisionedDevices");
    own.profile.insert("ProvisionsAllDevices".into(), true.into());
    h.install_own(&own.write(&h.dir)).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let app = h.iphone.app(BUNDLE_ID).expect("installed");
    assert_eq!(app.signature.team_id, own.team_id);

    // An App ID made for Cartouche alone.
    let mut own = h.own_signing();
    let app_id = format!("{}.{BUNDLE_ID}", own.team_id);
    own.entitlements().insert("application-identifier".into(), app_id.clone().into());
    h.install_own(&own.write(&h.dir)).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let app = h.iphone.app(BUNDLE_ID).expect("installed");
    assert_eq!(app.signature.team_id, own.team_id);
    assert_eq!(app.signature.entitlements.get("application-identifier"), Some(&app_id.into()));
    assert!(handoff(&h).is_some());
}

#[test]
fn a_profile_for_another_app_is_refused_by_the_iphone_and_leaves_nothing_behind() {
    let h = Harness::new();
    let version = h.publish_cartouche();
    h.select_device().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let mut own = h.own_signing();
    let other = format!("{}.com.example.othergame", own.team_id);
    own.entitlements().insert("application-identifier".into(), other.into());

    h.install_own(&own.write(&h.dir)).expect_err("installed with another app's profile");
    let (step, error) = last_failure(&h);
    assert_eq!(step, "install", "{error}");
    assert!(h.iphone.app(BUNDLE_ID).is_none());
    let refused = h.iphone.log().iter().any(|line| line.contains("com.example.othergame"));
    assert!(refused, "the iPhone did not refuse it\n{}", h.report());
    assert_eq!(leftovers(&version), Vec::<PathBuf>::new());
}

#[test]
fn installs_an_ipa_file_with_the_players_own_certificate_and_keeps_the_file() {
    let h = Harness::new();
    h.select_device().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let files = h.own_signing().write(&h.dir);
    let checked = h.check_profile(&files).expect("checked");
    let version = h.new_version();
    let ipa = h.write_ipa("Cartouche", &CartoucheIpa::new(&version).build());

    h.install_checked(&files, &checked, Some(&ipa)).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    assert_eq!(
        h.steps("install_cartouche"),
        all_steps(&["download", "install", "pairing"]),
        "the file checked, installed, Cartouche given its certificate"
    );
    let app = h.iphone.app(BUNDLE_ID).expect("installed");
    assert_eq!(app.info.get("CFBundleShortVersionString"), Some(&version.clone().into()));
    assert!(ipa.exists(), "the player's file was deleted");
    assert!(h.github.state().requests.is_empty(), "{:?}", h.github.state().requests);
    assert_eq!(leftovers(&version), Vec::<PathBuf>::new());

    // Another app's IPA: refused before anything is signed.
    let game = h.write_ipa("Game", &other_app_ipa("com.example.game", "Game"));
    let error = h.install_checked(&files, &checked, Some(&game)).expect_err("installed another app");
    assert_eq!(error_type(&error), "not_cartouche");
    assert!(h.iphone.app("com.example.game").is_none());
}

#[test]
fn updates_cartouche_installed_with_the_players_own_certificate_and_keeps_its_games() {
    let h = Harness::new();
    let first = h.publish_cartouche();
    h.select_device().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let files = h.own_signing().write(&h.dir);
    h.install_own(&files).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let first_key = h.iphone.app(BUNDLE_ID).expect("installed").info["CartoucheSigningHandoffKey"].clone();

    // Cartouche started: it kept the certificate in the iPhone's keychain
    // and deleted the file; then the player added a game.
    {
        let mut state = h.iphone.state();
        let container = &mut state.apps.get_mut(BUNDLE_ID).expect("installed").container;
        container.remove(HANDOFF, false).expect("the certificate's file");
        container.mkdir_p("Documents/Games").expect("folder");
        container.write("Documents/Games/save.dat", b"chapter 3".to_vec()).expect("save");
    }

    let second = h.publish_cartouche();
    assert_eq!(h.invoke("installed_cartouche", json!({})).expect("installed")["version"], first);
    h.install_own(&files).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let app = h.iphone.app(BUNDLE_ID).expect("installed");
    assert_eq!(app.info.get("CFBundleShortVersionString"), Some(&second.clone().into()));
    assert_eq!(h.iphone.container_file(BUNDLE_ID, "Documents/Games/save.dat"), Some(b"chapter 3".to_vec()));
    // The certificate again, under a key of this install's own.
    assert_ne!(app.info["CartoucheSigningHandoffKey"], first_key);
    let handoff = handoff(&h).unwrap_or_else(|| panic!("no certificate for Cartouche\n{}", h.report()));
    assert_eq!(handoff.get("password").and_then(|v| v.as_string()), Some(files.password.as_str()));
    assert_eq!(h.invoke("installed_cartouche", json!({})).expect("installed")["version"], second);
    assert_eq!(leftovers(&first), Vec::<PathBuf>::new());
    assert_eq!(leftovers(&second), Vec::<PathBuf>::new());
}

#[test]
fn an_apple_id_signed_in_takes_no_part_in_an_install_with_the_players_certificate() {
    let h = Harness::new();
    h.publish_cartouche();
    h.ready();
    let asked = h.apple.log().len();
    let files = h.own_signing().write(&h.dir);

    h.install_own(&files).unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let log = h.apple.log();
    assert_eq!(log.len(), asked, "{:?}", &log[asked..]);
    assert_eq!(h.apple.with_account(EMAIL, |a| a.team.certificates.len()), 0);
    assert_eq!(h.iphone.app(BUNDLE_ID).expect("installed").bundle_id, BUNDLE_ID);

    // Installed with the Apple ID too, it is another app beside it, under
    // the team's identifier.
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let apps: Vec<String> = h.iphone.state().apps.keys().cloned().collect();
    assert!(apps.contains(&BUNDLE_ID.to_string()), "{apps:?}");
    assert!(apps.contains(&format!("{BUNDLE_ID}.{}", h.team_id)), "{apps:?}");
}
