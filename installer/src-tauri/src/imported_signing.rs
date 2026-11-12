//! Local signing with a supplied identity. This module never contacts Apple's
//! developer portal and never creates or revokes an account certificate.
use crate::{cartouche::BUNDLE_ID, error::AppError};
use aes_gcm::{
    Aes256Gcm, Nonce,
    aead::{Aead, Generate, KeyInit, Payload},
};
use apple_codesign_quick::{
    BundleSigningSettings, ProvisioningProfile, RustCryptoCmsSigner, sign_bundle,
};
use p12_keystore::{KeyStore, Pkcs12ImportPolicy};
use plist::{Dictionary, Value};
use rsa::{
    RsaPrivateKey, RsaPublicKey,
    pkcs8::{DecodePrivateKey, DecodePublicKey},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    io::Cursor,
    path::{Path, PathBuf},
    time::SystemTime,
};
use x509_cert::{
    Certificate,
    der::{Decode, Encode},
};

pub const HANDOFF_FILE: &str = "CartoucheSigning.plist";
const HANDOFF_AAD: &[u8] = b"CartoucheSigningHandoff.v1";

// Deliberately not Debug/Serialize: passwords must not reach logs or settings.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImportedSigning {
    p12_path: PathBuf,
    profile_path: PathBuf,
    password: String,
    profile_sha256: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SigningProfileSummary {
    increased_memory_limit: bool,
    sha256: String,
    /// The app the profile is for, when it is not Cartouche.
    other_app: Option<String>,
}

/// The app a profile is for, when it is not Cartouche: its App ID, fixed
/// or wildcard, does not cover Cartouche's identifier, and iOS installs an
/// app only under an App ID its profile covers.
fn other_app(entitlements: &Dictionary) -> Option<String> {
    let pattern = entitlements.get("application-identifier")?.as_string()?;
    let (prefix, app) = pattern.split_once('.')?;
    (!identifier_matches(pattern, &format!("{prefix}.{BUNDLE_ID}"))).then(|| app.to_string())
}

fn has_increased_memory_limit(entitlements: &Dictionary) -> bool {
    entitlements
        .get("com.apple.developer.kernel.increased-memory-limit")
        .and_then(Value::as_boolean)
        == Some(true)
}

fn profile_digest(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}

fn verify_profile_review(data: &[u8], reviewed_digest: &str) -> Result<(), AppError> {
    if reviewed_digest != profile_digest(data) {
        return Err(invalid(
            "The provisioning profile changed. Choose it again to review its permissions before installing.",
        ));
    }
    Ok(())
}

#[tauri::command]
pub fn inspect_signing_profile(profile_path: PathBuf) -> Result<SigningProfileSummary, AppError> {
    let data = read_small(&profile_path)?;
    let profile = ProvisioningProfile::parse(&data)
        .map_err(|_| invalid("Cannot read this Apple provisioning profile."))?;
    Ok(SigningProfileSummary {
        increased_memory_limit: has_increased_memory_limit(profile.entitlements()),
        sha256: profile_digest(&data),
        other_app: other_app(profile.entitlements()),
    })
}

fn encrypt_handoff(plaintext: &[u8]) -> Result<(Vec<u8>, Vec<u8>), AppError> {
    let key = aes_gcm::Key::<Aes256Gcm>::generate();
    let cipher = Aes256Gcm::new(&key);
    let nonce = Nonce::generate();
    let ciphertext = cipher
        .encrypt(
            &nonce,
            Payload {
                msg: plaintext,
                aad: HANDOFF_AAD,
            },
        )
        .map_err(|_| invalid("Cannot encrypt the signing handoff."))?;
    // CryptoKit's combined format: 12-byte nonce, ciphertext, 16-byte tag.
    let mut combined = nonce.to_vec();
    combined.extend_from_slice(&ciphertext);
    Ok((key.to_vec(), combined))
}

fn local_signing_failure(error: impl std::fmt::Display) -> AppError {
    tracing::error!(error = %error, "Local signing failed");
    invalid("Local signing failed. See the installer log for details.")
}

pub struct SignedImport {
    pub workspace: tempfile::TempDir,
    pub app_path: PathBuf,
    pub handoff: Vec<u8>,
}

fn invalid(message: impl Into<String>) -> AppError {
    AppError::Misc(message.into())
}

fn identifier_matches(allowed: &str, actual: &str) -> bool {
    if let Some(prefix) = allowed.strip_suffix('*') {
        !prefix.contains('*')
            && prefix.ends_with('.')
            && actual.starts_with(prefix)
            && actual.len() > prefix.len()
    } else {
        allowed == actual
    }
}

fn validate_profile(profile: &Dictionary, certificate: &[u8], udid: &str) -> Result<(), AppError> {
    let expiry = profile
        .get("ExpirationDate")
        .and_then(Value::as_date)
        .ok_or_else(|| invalid("The provisioning profile has no expiration date."))?;
    if SystemTime::from(expiry) <= SystemTime::now() {
        return Err(invalid("The provisioning profile has expired."));
    }
    let eligible = profile
        .get("ProvisionsAllDevices")
        .and_then(Value::as_boolean)
        == Some(true)
        || profile
            .get("ProvisionedDevices")
            .and_then(Value::as_array)
            .is_some_and(|devices| devices.iter().any(|value| value.as_string() == Some(udid)));
    if !eligible {
        return Err(invalid(
            "This provisioning profile does not include the selected iPhone.",
        ));
    }
    let matches = profile
        .get("DeveloperCertificates")
        .and_then(Value::as_array)
        .is_some_and(|certs| {
            certs
                .iter()
                .any(|value| value.as_data() == Some(certificate))
        });
    if !matches {
        return Err(invalid(
            "The certificate does not match the provisioning profile.",
        ));
    }
    Ok(())
}

fn validate_game_keychain(allowed: &Dictionary, team: &str) -> Result<(), AppError> {
    let groups = allowed.get("keychain-access-groups").and_then(Value::as_array)
        .ok_or_else(|| invalid("This profile does not authorize the keychain groups games require. Use a wildcard profile with keychain access for this team."))?;
    for suffix in std::iter::once(String::new()).chain((1..128).map(|n| format!(".{n}"))) {
        let group = format!("{team}.com.kdt.livecontainer.shared{suffix}");
        if !groups
            .iter()
            .filter_map(Value::as_string)
            .any(|pattern| identifier_matches(pattern, &group))
        {
            return Err(invalid(
                "This profile does not authorize all game keychain groups. Use a wildcard profile with keychain access for this team.",
            ));
        }
    }
    Ok(())
}

fn entitlements_for(
    allowed: &Dictionary,
    team: &str,
    bundle: &str,
) -> Result<Dictionary, AppError> {
    let pattern = allowed
        .get("application-identifier")
        .and_then(Value::as_string)
        .ok_or_else(|| invalid("The profile has no application identifier."))?;
    let (prefix, suffix) = pattern
        .split_once('.')
        .filter(|(prefix, suffix)| !prefix.is_empty() && !suffix.is_empty())
        .ok_or_else(|| invalid("Invalid profile application identifier."))?;
    let app_id = if suffix.contains('*') {
        let expanded = format!("{prefix}.{bundle}");
        if !identifier_matches(pattern, &expanded) {
            return Err(invalid(
                "The profile's wildcard application identifier cannot be expanded for Cartouche.",
            ));
        }
        expanded
    } else {
        // A fixed identifier is Cartouche's own here: sign() refuses the
        // others first (other_app), which iOS would not install.
        pattern.to_string()
    };
    if allowed
        .get("com.apple.developer.team-identifier")
        .and_then(Value::as_string)
        .is_some_and(|id| id != team)
    {
        return Err(invalid("The profile's team identifiers disagree."));
    }
    let mut result = allowed.clone();
    // Basic mode has no extensions and uses a private sandbox directory.
    // Profile group patterns are permissions, not concrete group identifiers.
    result.remove("com.apple.security.application-groups");
    result.insert("application-identifier".into(), app_id.clone().into());
    result.insert("com.apple.developer.team-identifier".into(), team.into());
    if let Some(groups) = allowed
        .get("keychain-access-groups")
        .and_then(Value::as_array)
    {
        let mut expanded: Vec<Value> = groups
            .iter()
            .filter_map(Value::as_string)
            .map(|group| {
                if let Some(group_prefix) = group.strip_suffix(".*") {
                    format!("{group_prefix}.{bundle}").into()
                } else {
                    group.into()
                }
            })
            .collect();
        // Games use LiveContainer's numbered keychain groups. Add them only
        // when the supplied profile explicitly permits them.
        for suffix in std::iter::once(String::new()).chain((1..128).map(|n| format!(".{n}"))) {
            let group = format!("{team}.com.kdt.livecontainer.shared{suffix}");
            if groups
                .iter()
                .filter_map(Value::as_string)
                .any(|pattern| identifier_matches(pattern, &group))
            {
                expanded.push(group.into());
            }
        }
        result.insert("keychain-access-groups".into(), expanded.into());
    }
    Ok(result)
}

struct Identity {
    key: Vec<u8>,
    certificate: Vec<u8>,
    chain: Vec<Vec<u8>>,
}

fn read_identity(data: &[u8], password: &str) -> Result<Identity, AppError> {
    let store =
        KeyStore::from_pkcs12(data, password, Pkcs12ImportPolicy::Strict).map_err(|_| {
            invalid("Cannot open the P12. Check its password and that it contains a private key.")
        })?;
    let (_, chain) = store
        .private_key_chain()
        .ok_or_else(|| invalid("The P12 contains no signing private key."))?;
    let leaf = chain
        .certs()
        .first()
        .ok_or_else(|| invalid("The P12 has no signing certificate."))?;
    let certificate = Certificate::from_der(leaf.as_der())
        .map_err(|_| invalid("Invalid signing certificate."))?;
    let validity = certificate.tbs_certificate.validity;
    let now = SystemTime::now();
    if validity.not_before.to_system_time() > now || validity.not_after.to_system_time() <= now {
        return Err(invalid(
            "The signing certificate is expired or is not yet valid.",
        ));
    }
    let key = RsaPrivateKey::from_pkcs8_der(chain.key().as_der())
        .map_err(|_| invalid("This signer requires an RSA signing private key."))?;
    let public_der = certificate
        .tbs_certificate
        .subject_public_key_info
        .to_der()
        .map_err(|_| invalid("Invalid certificate public key."))?;
    let public = RsaPublicKey::from_public_key_der(&public_der)
        .map_err(|_| invalid("Invalid RSA signing certificate."))?;
    if RsaPublicKey::from(&key) != public {
        return Err(invalid("The private key does not match the certificate."));
    }
    Ok(Identity {
        key: chain.key().as_der().to_vec(),
        certificate: leaf.as_der().to_vec(),
        chain: chain
            .certs()
            .iter()
            .skip(1)
            .map(|cert| cert.as_der().to_vec())
            .collect(),
    })
}

fn read_small(path: &Path) -> Result<Vec<u8>, AppError> {
    let file =
        std::fs::File::open(path).map_err(|_| invalid("Cannot read the selected signing file."))?;
    use std::io::Read;
    let mut bytes = Vec::new();
    file.take(4 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| invalid("Cannot read the signing file."))?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err(invalid("Signing files must be smaller than 4 MB."));
    }
    Ok(bytes)
}

impl ImportedSigning {
    pub fn sign(&self, ipa: &Path, udid: &str) -> Result<SignedImport, AppError> {
        let p12 = read_small(&self.p12_path)?;
        let profile_data = read_small(&self.profile_path)?;
        verify_profile_review(&profile_data, &self.profile_sha256)?;
        let identity = read_identity(&p12, &self.password)?;
        let profile = ProvisioningProfile::parse(&profile_data)
            .map_err(|_| invalid("Cannot read this Apple provisioning profile."))?;
        validate_profile(profile.plist(), &identity.certificate, udid)?;
        if let Some(app) = other_app(profile.entitlements()) {
            return Err(AppError::ProfileForAnotherApp(app));
        }
        validate_game_keychain(profile.entitlements(), profile.team_id())?;
        let entitlements = entitlements_for(profile.entitlements(), profile.team_id(), BUNDLE_ID)?;
        let workspace = tempfile::tempdir()
            .map_err(|_| invalid("Cannot create a private signing workspace."))?;
        let file =
            std::fs::File::open(ipa).map_err(|_| invalid("Cannot open the Cartouche IPA."))?;
        let mut archive =
            zip::ZipArchive::new(file).map_err(|_| invalid("Invalid Cartouche IPA."))?;
        archive
            .extract(workspace.path())
            .map_err(|_| invalid("Cannot extract the Cartouche IPA."))?;
        let apps: Vec<PathBuf> = std::fs::read_dir(workspace.path().join("Payload"))
            .map_err(|_| invalid("The IPA has no Payload folder."))?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.is_dir() && path.extension().is_some_and(|ext| ext == "app"))
            .collect();
        if apps.len() != 1 {
            return Err(invalid("The IPA must contain one app."));
        }
        let app_path = apps[0].clone();
        let info_path = app_path.join("Info.plist");
        let mut info = Value::from_file(&info_path)
            .map_err(|_| invalid("Invalid Cartouche Info.plist."))?
            .into_dictionary()
            .ok_or_else(|| invalid("Invalid Cartouche Info.plist."))?;
        if info.get("CFBundleIdentifier").and_then(Value::as_string) != Some(BUNDLE_ID) {
            return Err(invalid("The selected IPA is not Cartouche."));
        }
        // A single supplied app profile is not sufficient to authorize all
        // bundled extension IDs. Basic imported mode runs games in-place.
        for directory in ["PlugIns", "Watch"] {
            let path = app_path.join(directory);
            if path.exists() {
                std::fs::remove_dir_all(path)
                    .map_err(|_| invalid("Cannot remove unsupported app extensions."))?;
            }
        }
        info.insert("CartoucheImportedSigning".into(), true.into());
        let mut handoff = Dictionary::new();
        handoff.insert("certificate".into(), Value::Data(p12));
        handoff.insert("password".into(), self.password.clone().into());
        handoff.insert("profile".into(), Value::Data(profile_data.clone()));
        let mut bytes = Cursor::new(Vec::new());
        Value::Dictionary(handoff)
            .to_writer_binary(&mut bytes)
            .map_err(|_| invalid("Cannot prepare the signing handoff."))?;
        let (handoff_key, handoff) = encrypt_handoff(bytes.get_ref())?;
        info.insert(
            "CartoucheSigningHandoffKey".into(),
            Value::Data(handoff_key),
        );
        Value::Dictionary(info)
            .to_file_binary(&info_path)
            .map_err(|_| invalid("Cannot prepare Cartouche for imported signing."))?;
        let signer = RustCryptoCmsSigner::from_der(&identity.key, &identity.certificate,
            identity.chain.iter().chain(profile.certificate_chain_der().iter()))
            .map_err(|_| invalid("Cannot build the certificate chain. Include the Apple intermediate certificate in the P12."))?;
        let mut settings =
            BundleSigningSettings::new(profile.team_id(), entitlements, Some(&signer));
        settings.embedded_mobileprovision = Some(&profile_data);
        sign_bundle(&app_path, &settings).map_err(local_signing_failure)?;
        Ok(SignedImport {
            workspace,
            app_path,
            handoff,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_permission_requires_an_explicit_true_entitlement() {
        let mut entitlements = Dictionary::new();
        assert!(!has_increased_memory_limit(&entitlements));
        entitlements.insert(
            "com.apple.developer.kernel.increased-memory-limit".into(),
            false.into(),
        );
        assert!(!has_increased_memory_limit(&entitlements));
        entitlements.insert(
            "com.apple.developer.kernel.increased-memory-limit".into(),
            true.into(),
        );
        assert!(has_increased_memory_limit(&entitlements));
    }

    #[test]
    fn changed_profile_requires_a_new_review_before_signing() {
        assert!(verify_profile_review(b"profile", &profile_digest(b"profile")).is_ok());
        assert!(verify_profile_review(b"changed", &profile_digest(b"profile")).is_err());
        assert!(verify_profile_review(b"profile", "").is_err());
    }

    #[test]
    fn public_signing_error_does_not_include_local_paths() {
        let error = local_signing_failure(
            "cannot sign C:\\Users\\ExamplePlayer\\AppData\\Local\\Temp\\Cartouche.app",
        );
        assert_eq!(
            error.to_string(),
            "Local signing failed. See the installer log for details."
        );
        assert!(!error.to_string().contains("ExamplePlayer"));
    }

    #[test]
    fn handoff_is_authenticated_encryption_with_a_fresh_key() {
        use aes_gcm::{
            Aes256Gcm, Nonce,
            aead::{Aead, KeyInit, Payload},
        };
        let plaintext = b"private P12 and password";
        let (key, combined) = encrypt_handoff(plaintext).unwrap();
        let (other_key, other) = encrypt_handoff(plaintext).unwrap();
        assert_ne!(key, other_key);
        assert_ne!(combined, other);
        assert!(
            !combined
                .windows(plaintext.len())
                .any(|part| part == plaintext)
        );
        let cipher = Aes256Gcm::new_from_slice(&key).unwrap();
        let payload = Payload {
            msg: &combined[12..],
            aad: HANDOFF_AAD,
        };
        assert_eq!(
            cipher
                .decrypt(
                    &Nonce::from(<[u8; 12]>::try_from(&combined[..12]).unwrap()),
                    payload
                )
                .unwrap(),
            plaintext
        );
        let mut tampered = combined.clone();
        *tampered.last_mut().unwrap() ^= 1;
        assert!(
            cipher
                .decrypt(
                    &Nonce::from(<[u8; 12]>::try_from(&tampered[..12]).unwrap()),
                    Payload {
                        msg: &tampered[12..],
                        aad: HANDOFF_AAD
                    }
                )
                .is_err()
        );
    }

    fn profile() -> plist::Dictionary {
        let mut data = plist::Dictionary::new();
        data.insert(
            "ExpirationDate".into(),
            plist::Date::from(std::time::SystemTime::now() + std::time::Duration::from_secs(3600))
                .into(),
        );
        data.insert(
            "ProvisionedDevices".into(),
            vec![plist::Value::String("device".into())].into(),
        );
        data.insert(
            "DeveloperCertificates".into(),
            vec![plist::Value::Data(vec![1, 2])].into(),
        );
        data
    }

    #[test]
    fn validates_device_certificate_and_expiry() {
        let data = profile();
        assert!(validate_profile(&data, &[1, 2], "device").is_ok());
        assert!(validate_profile(&data, &[1, 2], "other-device").is_err());
        assert!(validate_profile(&data, &[3], "device").is_err());
        let mut expired = data.clone();
        expired.insert(
            "ExpirationDate".into(),
            plist::Date::from(std::time::UNIX_EPOCH).into(),
        );
        assert!(validate_profile(&expired, &[1, 2], "device").is_err());
        let mut missing = data.clone();
        missing.remove("ExpirationDate");
        assert!(validate_profile(&missing, &[1, 2], "device").is_err());
        let mut enterprise = data;
        enterprise.remove("ProvisionedDevices");
        enterprise.insert("ProvisionsAllDevices".into(), true.into());
        assert!(validate_profile(&enterprise, &[1, 2], "other-device").is_ok());
    }

    #[test]
    fn expands_only_authorized_identifiers() {
        assert!(identifier_matches("TEAM.*", "TEAM.io.github.cartouche"));
        assert!(identifier_matches("TEAM.io.*", "TEAM.io.github.cartouche"));
        assert!(!identifier_matches("TEAM.io.*", "TEAM.iota.app"));
        assert!(!identifier_matches("TEAM.*", "OTHER.app"));
        assert!(!identifier_matches("TEAM.a*b", "TEAM.axb"));
        assert!(identifier_matches("TEAM.app", "TEAM.app"));
        assert!(!identifier_matches("TEAM.app", "TEAM.app.extension"));
    }

    #[test]
    fn entitlements_expand_app_id_without_inventing_permissions() {
        let mut allowed = plist::Dictionary::new();
        allowed.insert("application-identifier".into(), "PREFIX.*".into());
        allowed.insert(
            "keychain-access-groups".into(),
            vec![plist::Value::String("PREFIX.*".into())].into(),
        );
        let entitlements = entitlements_for(&allowed, "TEAM", "io.github.cartouche").unwrap();
        assert_eq!(
            entitlements["application-identifier"].as_string(),
            Some("PREFIX.io.github.cartouche")
        );
        assert_eq!(
            entitlements["keychain-access-groups"].as_array().unwrap()[0].as_string(),
            Some("PREFIX.io.github.cartouche")
        );
        assert!(!entitlements.contains_key("com.apple.security.application-groups"));
        assert!(!entitlements.contains_key("com.apple.developer.kernel.increased-memory-limit"));
        allowed.insert("application-identifier".into(), "PREFIX.other".into());
        let fixed = entitlements_for(&allowed, "TEAM", "io.github.cartouche").unwrap();
        assert_eq!(
            fixed["application-identifier"].as_string(),
            Some("PREFIX.other")
        );
        allowed.insert("application-identifier".into(), "PREFIX.a*b".into());
        assert!(entitlements_for(&allowed, "TEAM", "io.github.cartouche").is_err());
    }

    #[test]
    fn names_the_app_a_profile_is_for_when_it_is_not_cartouche() {
        let profile = |app_id: &str| {
            let mut entitlements = Dictionary::new();
            entitlements.insert("application-identifier".into(), app_id.into());
            entitlements
        };
        assert_eq!(other_app(&profile("TEAM.*")), None);
        assert_eq!(other_app(&profile(&format!("TEAM.{BUNDLE_ID}"))), None);
        assert_eq!(other_app(&profile("TEAM.io.github.*")), None);
        assert_eq!(other_app(&profile("TEAM.com.example.game")), Some("com.example.game".into()));
        assert_eq!(other_app(&profile("TEAM.com.example.*")), Some("com.example.*".into()));
        assert_eq!(other_app(&profile(&format!("TEAM.{BUNDLE_ID}.extension"))), Some(format!("{BUNDLE_ID}.extension")));
    }

    #[test]
    fn rejects_invalid_p12_without_exposing_password() {
        let error = read_identity(b"invalid", "secret-password")
            .err()
            .unwrap()
            .to_string();
        assert!(!error.contains("secret-password"));
    }

    #[test]
    fn rejects_a_p12_without_a_private_key() {
        let archive = KeyStore::new().writer("test").write().unwrap();
        assert!(read_identity(&archive, "test").is_err());
        assert!(read_identity(&archive, "wrong").is_err());
    }

    #[test]
    fn basic_mode_does_not_claim_profile_app_groups() {
        let mut allowed = Dictionary::new();
        allowed.insert("application-identifier".into(), "TEAM.*".into());
        allowed.insert(
            "com.apple.security.application-groups".into(),
            vec![Value::String("group.*".into())].into(),
        );
        let entitlements = entitlements_for(&allowed, "TEAM", BUNDLE_ID).unwrap();
        assert!(!entitlements.contains_key("com.apple.security.application-groups"));
    }

    #[test]
    fn requires_every_guest_keychain_group_to_be_authorized() {
        let mut allowed = Dictionary::new();
        assert!(validate_game_keychain(&allowed, "TEAM").is_err());
        allowed.insert(
            "keychain-access-groups".into(),
            vec![Value::String("TEAM.app".into())].into(),
        );
        assert!(validate_game_keychain(&allowed, "TEAM").is_err());
        allowed.insert(
            "keychain-access-groups".into(),
            vec![Value::String("OTHER.*".into())].into(),
        );
        assert!(validate_game_keychain(&allowed, "TEAM").is_err());
        allowed.insert(
            "keychain-access-groups".into(),
            vec![Value::String("TEAM.*".into())].into(),
        );
        assert!(validate_game_keychain(&allowed, "TEAM").is_ok());
        // ApplicationIdentifierPrefix may differ from TeamIdentifier. The
        // engine uses TeamIdentifier for guest keychain groups.
        allowed.insert("application-identifier".into(), "PREFIX.*".into());
        let result = entitlements_for(&allowed, "TEAM", BUNDLE_ID).unwrap();
        assert_eq!(
            result["keychain-access-groups"].as_array().unwrap()[0].as_string(),
            Some(format!("TEAM.{BUNDLE_ID}").as_str())
        );
        assert!(
            result["keychain-access-groups"]
                .as_array()
                .unwrap()
                .contains(&Value::String(
                    "TEAM.com.kdt.livecontainer.shared.127".into()
                ))
        );
    }

    /// Exercise the real PKCS#12/CMS/bundle-signing path with throwaway
    /// self-signed material. iOS trust acceptance is a separate device check.
    #[test]
    #[cfg(target_os = "macos")]
    fn signs_a_bundle_and_prepares_a_matching_handoff_without_an_account() {
        use std::{io::Write, process::Command};
        fn openssl(dir: &Path, arguments: &[&str]) {
            let result = Command::new("openssl")
                .current_dir(dir)
                .args(arguments)
                .output()
                .unwrap();
            assert!(
                result.status.success(),
                "{}",
                String::from_utf8_lossy(&result.stderr)
            );
        }
        let input = tempfile::tempdir().unwrap();
        let dir = input.path();
        openssl(
            dir,
            &[
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-keyout",
                "key.pem",
                "-out",
                "cert.pem",
                "-subj",
                "/OU=TEAM/CN=Cartouche Test",
                "-days",
                "1",
            ],
        );
        openssl(
            dir,
            &[
                "pkcs12",
                "-export",
                "-inkey",
                "key.pem",
                "-in",
                "cert.pem",
                "-out",
                "cert.p12",
                "-passout",
                "pass:test",
            ],
        );
        let p12 = std::fs::read(dir.join("cert.p12")).unwrap();
        let identity = read_identity(&p12, "test").unwrap();
        assert!(read_identity(&p12, "wrong").is_err());
        let mut data = profile();
        data.insert(
            "DeveloperCertificates".into(),
            vec![Value::Data(identity.certificate)].into(),
        );
        data.insert(
            "TeamIdentifier".into(),
            vec![Value::String("TEAM".into())].into(),
        );
        let mut entitlements = Dictionary::new();
        entitlements.insert(
            "application-identifier".into(),
            "TEAM.fixed-profile-app".into(),
        );
        entitlements.insert(
            "keychain-access-groups".into(),
            vec![Value::String("TEAM.*".into())].into(),
        );
        data.insert("Entitlements".into(), entitlements.into());
        Value::Dictionary(data)
            .to_file_xml(dir.join("profile.xml"))
            .unwrap();
        openssl(
            dir,
            &[
                "cms",
                "-sign",
                "-binary",
                "-in",
                "profile.xml",
                "-signer",
                "cert.pem",
                "-inkey",
                "key.pem",
                "-outform",
                "DER",
                "-out",
                "profile.mobileprovision",
                "-nodetach",
            ],
        );
        let ipa = dir.join("Cartouche.ipa");
        let mut zip = zip::ZipWriter::new(std::fs::File::create(&ipa).unwrap());
        let options = zip::write::SimpleFileOptions::default().unix_permissions(0o755);
        let mut info = Dictionary::new();
        info.insert("CFBundleIdentifier".into(), BUNDLE_ID.into());
        info.insert("CFBundleExecutable".into(), "Cartouche".into());
        zip.start_file("Payload/Cartouche.app/Info.plist", options)
            .unwrap();
        Value::Dictionary(info).to_writer_binary(&mut zip).unwrap();
        zip.start_file("Payload/Cartouche.app/Cartouche", options)
            .unwrap();
        zip.write_all(&std::fs::read("/usr/bin/true").unwrap())
            .unwrap();
        zip.start_file(
            "Payload/Cartouche.app/PlugIns/Optional.appex/unused",
            options,
        )
        .unwrap();
        zip.write_all(b"not authorized by the profile").unwrap();
        zip.finish().unwrap();
        let before = std::fs::read(&ipa).unwrap();
        let signing = ImportedSigning {
            p12_path: dir.join("cert.p12"),
            profile_path: dir.join("profile.mobileprovision"),
            password: "test".into(),
            profile_sha256: profile_digest(
                &std::fs::read(dir.join("profile.mobileprovision")).unwrap(),
            ),
        };
        let summary = inspect_signing_profile(signing.profile_path.clone()).unwrap();
        assert!(!summary.increased_memory_limit);
        assert_eq!(summary.sha256, signing.profile_sha256);
        let signed = signing.sign(&ipa, "device").unwrap();
        assert!(!signed.app_path.join("PlugIns").exists());
        assert!(
            signed
                .app_path
                .join("_CodeSignature/CodeResources")
                .exists()
        );
        assert_eq!(
            std::fs::read(signed.app_path.join("embedded.mobileprovision")).unwrap(),
            std::fs::read(&signing.profile_path).unwrap()
        );
        let info = Value::from_file(signed.app_path.join("Info.plist")).unwrap();
        assert_eq!(
            info.as_dictionary().unwrap()["CFBundleIdentifier"].as_string(),
            Some(BUNDLE_ID)
        );
        assert_eq!(
            info.as_dictionary().unwrap()["CartoucheImportedSigning"].as_boolean(),
            Some(true)
        );
        let key = info.as_dictionary().unwrap()["CartoucheSigningHandoffKey"]
            .as_data()
            .unwrap();
        let cipher = Aes256Gcm::new_from_slice(key).unwrap();
        let nonce = Nonce::from(<[u8; 12]>::try_from(&signed.handoff[..12]).unwrap());
        let plaintext = cipher
            .decrypt(
                &nonce,
                Payload {
                    msg: &signed.handoff[12..],
                    aad: HANDOFF_AAD,
                },
            )
            .unwrap();
        let handoff = Value::from_reader(Cursor::new(plaintext)).unwrap();
        assert_eq!(
            handoff.as_dictionary().unwrap()["certificate"].as_data(),
            Some(p12.as_slice())
        );
        // Check the production Swift reader against the Rust-generated
        // envelope, including the per-install key read from signed Info.plist.
        let swift = dir.join("main.swift");
        std::fs::write(&swift, r#"
import Foundation
let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), format: nil) as! [String: Any]
let encrypted = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
let material = try CartoucheSigningMaterial.openHandoff(encrypted, key: info["CartoucheSigningHandoffKey"] as! Data)
assert(material.password == "test")
let expected = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
assert(material.certificate == expected)
"#).unwrap();
        let model = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../launcher/Sources/CartoucheSigningMaterial.swift");
        let executable = dir.join("handoff-check");
        let compile = Command::new("xcrun")
            .arg("swiftc")
            .arg(&model)
            .arg(&swift)
            .arg("-module-cache-path")
            .arg(dir.join("swift-cache"))
            .arg("-o")
            .arg(&executable)
            .output()
            .unwrap();
        assert!(
            compile.status.success(),
            "{}",
            String::from_utf8_lossy(&compile.stderr)
        );
        let handoff_file = dir.join("handoff.bin");
        std::fs::write(&handoff_file, &signed.handoff).unwrap();
        assert!(
            Command::new(executable)
                .arg(signed.app_path.join("Info.plist"))
                .arg(handoff_file)
                .arg(&signing.p12_path)
                .status()
                .unwrap()
                .success()
        );
        assert_eq!(std::fs::read(ipa).unwrap(), before);
    }
}
