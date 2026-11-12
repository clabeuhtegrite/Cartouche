//! Cartouche from GitHub: the source, the release's IPA, and the checks
//! that keep any other file off the iPhone.

use serde_json::json;

use crate::harness::*;

/// A source as the release workflow writes it, with one release whose
/// fields a test changes.
fn source(version: &str, download_url: &str, size: usize, sha256: &str, bundle_id: &str) -> String {
    json!({
        "name": "Cartouche",
        "identifier": "io.github.clabeuhtegrite.cartouche.source",
        "apps": [{
            "name": "Cartouche",
            "bundleIdentifier": bundle_id,
            "developerName": "Cartouche",
            "versions": [{
                "version": version,
                "date": "2026-11-12T10:00:00Z",
                "downloadURL": download_url,
                "size": size,
                "sha256": sha256,
                "localizedDescription": "Cartouche",
                "minOSVersion": "26.0"
            }]
        }],
        "news": []
    })
    .to_string()
}

/// Installs, expects the download step to fail, and gives its error.
fn download_fails(h: &Harness) -> serde_json::Value {
    let error = h.install().expect_err("installed all the same");
    assert_eq!(error_type(&error), "download", "{error}");
    assert_eq!(h.failure("install_cartouche").map(|f| f.0).as_deref(), Some("download"));
    assert!(h.iphone.state().apps.is_empty(), "something reached the iPhone");
    error
}

fn no_download_left(version: &str) {
    let temp = std::env::temp_dir();
    assert!(!temp.join(format!("Cartouche-{version}.ipa")).exists(), "the download stays in the temporary folder");
}

#[test]
fn installs_the_newest_release() {
    let h = Harness::new();
    let old = h.publish_cartouche();
    let new = h.publish_cartouche();
    h.ready();
    assert_eq!(h.invoke("cartouche_release", json!({})).unwrap()["version"], json!(new));
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let app = h.iphone.app(BUNDLE_ID).expect("Cartouche");
    assert_eq!(app.info.get("CFBundleShortVersionString"), Some(&new.into()));
    assert!(!h.github.state().requests.iter().any(|r| r.contains(&format!("v{old}/"))));
}

#[test]
fn reaches_only_github() {
    let h = Harness::new();
    let version = h.publish_cartouche();
    h.ready();
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
    let github = h.github.state();
    assert!(github.refused.is_empty(), "{:?}", github.refused);
    assert_eq!(
        github.requests,
        [
            "raw.githubusercontent.com /clabeuhtegrite/Cartouche/main/app/sidestore-source.json".to_string(),
            format!("github.com /clabeuhtegrite/Cartouche/releases/download/v{version}/Cartouche-{version}.ipa"),
            format!("release-assets.githubusercontent.com /github-production-release-asset/1/{version}?sp=r&sig=fake"),
        ]
    );
}

#[test]
fn says_when_github_does_not_answer() {
    let h = Harness::new();
    h.publish_cartouche();
    h.github.state().source_status = Some(503);
    let error = h.invoke("cartouche_release", json!({})).expect_err("a release");
    assert_eq!(error_type(&error), "download");
    assert!(error["message"].as_str().unwrap().contains("503"), "{error}");
    h.ready();
    download_fails(&h);

    h.github.state().source_status = None;
    h.install().unwrap_or_else(|e| panic!("{e}\n{}", h.report()));
}

#[test]
fn says_when_the_ipa_does_not_download() {
    let h = Harness::new();
    let version = h.publish_cartouche();
    h.github.state().asset_status = Some(500);
    h.ready();
    let error = download_fails(&h);
    assert!(error["message"].as_str().unwrap().contains("500"), "{error}");
    no_download_left(&version);
}

#[test]
fn refuses_a_download_cut_short() {
    let h = Harness::new();
    let version = h.publish_cartouche();
    h.github.state().asset_truncate = Some(20_000);
    h.ready();
    download_fails(&h);
    no_download_left(&version);
}

#[test]
fn refuses_an_ipa_other_than_the_one_listed() {
    // Same size, other bytes: the SHA-256 tells.
    let h = Harness::new();
    let version = h.publish_cartouche();
    let mut other = CartoucheIpa::new(&version).build();
    let middle = other.len() / 2;
    other[middle] ^= 0xff;
    h.github.state().asset_replace = Some(other);
    h.ready();
    let error = download_fails(&h);
    assert!(error["message"].as_str().unwrap().contains("SHA-256"), "{error}");
    no_download_left(&version);
}

#[test]
fn refuses_an_ipa_larger_than_listed() {
    let h = Harness::new();
    let version = h.publish_cartouche();
    let mut larger = CartoucheIpa::new(&version).build();
    larger.extend_from_slice(&[0u8; 4096]);
    h.github.state().asset_replace = Some(larger);
    h.ready();
    let error = download_fails(&h);
    assert!(error["message"].as_str().unwrap().contains("larger"), "{error}");
    no_download_left(&version);
}

#[test]
fn never_downloads_from_outside_the_releases() {
    let h = Harness::new();
    let version = h.new_version();
    let ipa = CartoucheIpa::new(&version).build();
    let sha = {
        use sha2::Digest;
        hex::encode(sha2::Sha256::digest(&ipa))
    };
    h.github.state().source_override = Some(source(
        &version,
        "https://example.com/Cartouche.ipa",
        ipa.len(),
        &sha,
        BUNDLE_ID,
    ));
    let error = h.invoke("cartouche_release", json!({})).expect_err("a release outside GitHub's");
    assert_eq!(error_type(&error), "download");
    h.ready();
    download_fails(&h);
    let github = h.github.state();
    assert!(github.refused.is_empty(), "went to {:?}", github.refused);
    assert!(github.requests.iter().all(|r| r.starts_with("raw.githubusercontent.com ")), "{:?}", github.requests);
}

#[test]
fn says_when_the_source_has_no_cartouche() {
    let h = Harness::new();
    let version = h.new_version();
    h.github.state().source_override = Some(source(
        &version,
        &FakeGithub::download_url(&version),
        1000,
        "00",
        "com.example.other",
    ));
    let error = h.invoke("cartouche_release", json!({})).expect_err("a release");
    assert_eq!(error_type(&error), "download");
    h.github.state().source_override = Some("<html>Not the source</html>".into());
    let error = h.invoke("cartouche_release", json!({})).expect_err("a release");
    assert_eq!(error_type(&error), "download");
}

#[test]
fn names_the_release_it_installs() {
    let h = Harness::new();
    let version = h.publish_cartouche();
    let release = h.invoke("cartouche_release", json!({})).expect("release");
    let ipa = CartoucheIpa::new(&version).build();
    assert_eq!(release["version"], json!(version));
    assert_eq!(release["size"], json!(ipa.len()));
    assert_eq!(release["downloadUrl"], json!(FakeGithub::download_url(&version)));
    assert_eq!(release["notes"], json!(format!("Cartouche {version}")));
    assert_eq!(release["sha256"].as_str().map(str::len), Some(64));
}
