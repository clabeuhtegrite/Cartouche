//! A signing certificate and its provisioning profile that a player brings,
//! for the installer's "I have a signing certificate (.p12)": made on
//! Apple's developer website for a paid account, by the same authority as
//! the developer services' certificates, the .p12 under a password.

use std::{
    path::{Path, PathBuf},
    time::{Duration, SystemTime},
};

use rsa::pkcs8::{EncodePrivateKey, LineEnding};
use sha2::Digest;

use super::{FakeApple, random_id};
use crate::dict;

const YEAR: Duration = Duration::from_secs(365 * 24 * 3600);

pub struct OwnSigning {
    apple: FakeApple,
    pub team_id: String,
    pub password: String,
    key_pem: String,
    key_der: Vec<u8>,
    /// The certificate, in DER.
    pub certificate: Vec<u8>,
    /// What the profile says, to change before it is written: a wildcard
    /// App ID with the team's keychain groups and Increased Memory Limit,
    /// for the iPhones given and this certificate, for a year.
    pub profile: plist::Dictionary,
}

/// What the player picks and types in the installer.
#[derive(Clone, Debug)]
pub struct OwnFiles {
    pub p12: PathBuf,
    pub profile: PathBuf,
    pub password: String,
}

impl OwnSigning {
    pub(super) fn new(apple: &FakeApple, udids: &[&str]) -> Self {
        let team_id = random_id(10);
        let key = rsa::RsaPrivateKey::new(&mut rand::rngs::OsRng, 2048).expect("RSA key");
        let key_pem = key.to_pkcs8_pem(LineEnding::LF).expect("key").to_string();
        let key_der = key.to_pkcs8_der().expect("key").as_bytes().to_vec();
        let mut own = OwnSigning {
            apple: apple.clone(),
            password: format!("p12-{}", random_id(8)),
            key_pem,
            key_der,
            certificate: Vec::new(),
            profile: plist::Dictionary::new(),
            team_id,
        };
        let now = SystemTime::now();
        own.reissue(now - Duration::from_secs(3600), now + YEAR);
        let team = own.team_id.clone();
        own.profile = dict! {
            "AppIDName" => "Wildcard",
            "ApplicationIdentifierPrefix" => vec![plist::Value::from(team.clone())],
            "CreationDate" => plist::Value::Date(now.into()),
            "Platform" => vec![plist::Value::from("iOS")],
            "IsXcodeManaged" => false,
            "DeveloperCertificates" => vec![plist::Value::Data(own.certificate.clone())],
            "Entitlements" => dict! {
                "application-identifier" => format!("{team}.*"),
                "com.apple.developer.team-identifier" => team.clone(),
                "get-task-allow" => true,
                "keychain-access-groups" => vec![plist::Value::from(format!("{team}.*"))],
                "com.apple.developer.kernel.increased-memory-limit" => true
            },
            "ExpirationDate" => plist::Value::Date((now + YEAR).into()),
            "Name" => "Cartouche Development",
            "ProvisionedDevices" => udids.iter().map(|udid| plist::Value::from(*udid)).collect::<Vec<_>>(),
            "TeamIdentifier" => vec![plist::Value::from(team.clone())],
            "TeamName" => "Camille Testeur",
            "TimeToLive" => 365u64,
            "UUID" => uuid::Uuid::new_v4().to_string().to_uppercase(),
            "Version" => 1u64
        };
        own
    }

    /// Issues the certificate again, for the same key, valid from
    /// `not_before` to `not_after`, and puts it in the profile.
    pub fn reissue(&mut self, not_before: SystemTime, not_after: SystemTime) {
        let key = rcgen::KeyPair::from_pkcs8_pem_and_sign_algo(&self.key_pem, &rcgen::PKCS_RSA_SHA256).expect("key");
        let csr = rcgen::CertificateParams::new(Vec::<String>::new())
            .expect("params")
            .serialize_request(&key)
            .expect("csr")
            .pem()
            .expect("pem");
        let issued = self
            .apple
            .ca()
            .issue_development_between(&csr, &self.team_id, "Camille Testeur", not_before, not_after)
            .expect("certificate");
        self.certificate = issued.der;
        if self.profile.contains_key("DeveloperCertificates") {
            self.profile.insert(
                "DeveloperCertificates".into(),
                vec![plist::Value::Data(self.certificate.clone())].into(),
            );
        }
    }

    /// The entitlements the profile grants.
    pub fn entitlements(&mut self) -> &mut plist::Dictionary {
        self.profile
            .get_mut("Entitlements")
            .and_then(plist::Value::as_dictionary_mut)
            .expect("entitlements")
    }

    /// The .p12: the key and its certificate, under the password.
    pub fn p12(&self) -> Vec<u8> {
        let certificate = p12_keystore::Certificate::from_der(&self.certificate).expect("certificate");
        let key = p12_keystore::PrivateKey::from_der(&self.key_der).expect("key");
        let local_key_id = sha2::Sha256::digest(&self.key_der)[..8].to_vec();
        let mut store = p12_keystore::KeyStore::new();
        store.add_entry(
            "Camille Testeur",
            p12_keystore::KeyStoreEntry::PrivateKeyChain(p12_keystore::PrivateKeyChain::new(
                local_key_id,
                key,
                vec![certificate],
            )),
        );
        store.writer(&self.password).write().expect("p12")
    }

    /// The .mobileprovision, as Apple signs it.
    pub fn mobileprovision(&self) -> Vec<u8> {
        self.apple.ca().profile(&self.profile)
    }

    /// Writes both in `dir`, under names of their own.
    pub fn write(&self, dir: &Path) -> OwnFiles {
        let name = random_id(6);
        let files = OwnFiles {
            p12: dir.join(format!("Certificate-{name}.p12")),
            profile: dir.join(format!("Cartouche-{name}.mobileprovision")),
            password: self.password.clone(),
        };
        std::fs::write(&files.p12, self.p12()).expect("write the p12");
        std::fs::write(&files.profile, self.mobileprovision()).expect("write the profile");
        files
    }
}
