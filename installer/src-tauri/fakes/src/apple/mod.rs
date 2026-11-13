//! Apple's servers as isideload reaches them through its proxy: GrandSlam
//! (sign-in with SRP, two-factor, app tokens, anisette provisioning) and the
//! developer services (teams, devices, certificates, App IDs, app groups,
//! profiles, Increased Memory Limit).
//!
//! isideload sends every request to `{proxy_url}{the request's URL,
//! percent-encoded}`; the fake answers on 127.0.0.1 and routes on the URL
//! it decodes.

mod ca;
mod developer;
mod gsa;
mod own;

use std::{
    collections::{BTreeMap, BTreeSet},
    net::SocketAddr,
    sync::{Arc, Mutex, MutexGuard},
    time::{Duration, SystemTime},
};

use base64::{Engine, prelude::BASE64_STANDARD};
use tokio::net::TcpListener;

pub use ca::AppleCa;
pub use own::{OwnFiles, OwnSigning};

use crate::http::{self, Request, Response};

/// How the account asks for a second factor.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TwoFactor {
    /// Two-factor authentication is off (an old account).
    Off,
    /// A code shows on the account's iPhone, iPad or Mac.
    TrustedDevice,
    /// A code comes by text message.
    Sms,
}

#[derive(Clone, Debug)]
pub struct AccountConfig {
    pub email: String,
    pub password: String,
    pub first_name: String,
    pub last_name: String,
    pub two_factor: TwoFactor,
    /// The code the trusted device shows, or the text message brings.
    pub code: String,
    pub team_id: String,
    /// "s2k" (the password's SHA-256) or "s2k_fo" (its hexadecimal).
    pub protocol: &'static str,
    pub locked: bool,
    /// Apple refuses developer services to under 18s, with result 1102.
    pub underage: bool,
}

impl AccountConfig {
    pub fn new(email: &str, password: &str) -> Self {
        AccountConfig {
            email: email.to_lowercase(),
            password: password.to_string(),
            first_name: "Camille".into(),
            last_name: "Testeur".into(),
            two_factor: TwoFactor::TrustedDevice,
            code: "246810".into(),
            team_id: random_id(10),
            protocol: "s2k",
            locked: false,
            underage: false,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Device {
    pub device_id: String,
    pub name: String,
    pub udid: String,
}

#[derive(Clone, Debug)]
pub struct Certificate {
    pub id: String,
    pub serial: String,
    pub machine_id: String,
    pub machine_name: String,
    pub der: Vec<u8>,
    pub expires: SystemTime,
}

#[derive(Clone, Debug)]
pub struct AppId {
    pub app_id_id: String,
    pub identifier: String,
    pub name: String,
    pub features: plist::Dictionary,
    /// Group identifiers (group.…) assigned to it.
    pub groups: Vec<String>,
    pub increased_memory_limit: bool,
    pub expires: SystemTime,
}

#[derive(Clone, Debug)]
pub struct AppGroup {
    pub id: String,
    pub identifier: String,
    pub name: String,
}

/// A free developer team: one person's, with Apple's limits.
#[derive(Clone, Debug)]
pub struct Team {
    pub team_id: String,
    pub name: String,
    pub devices: Vec<Device>,
    pub certificates: Vec<Certificate>,
    pub app_ids: Vec<AppId>,
    pub groups: Vec<AppGroup>,
    /// Development certificates the team can hold at once.
    pub max_certificates: usize,
    /// App IDs it can still register in the current 7 days.
    pub available_app_ids: i64,
}

#[derive(Debug)]
pub struct Account {
    pub config: AccountConfig,
    salt: Vec<u8>,
    iterations: u32,
    verifier: Vec<u8>,
    pub adsid: String,
    idms_token: String,
    /// The session key app tokens are sealed with.
    sk: Vec<u8>,
    c: Vec<u8>,
    /// The anisette machines that passed the second factor.
    pub trusted_machines: BTreeSet<String>,
    code_sent: BTreeSet<String>,
    xcode_tokens: BTreeSet<String>,
    pub team: Team,
    pub failed_logins: u32,
}

impl Account {
    fn new(config: AccountConfig) -> Self {
        let salt = random_bytes(16);
        let iterations = 2000;
        let password_key = password_key(&config.password, config.protocol, &salt, iterations);
        let verifier = srp::Client::<srp::groups::G2048, sha2::Sha256>::new_with_options(false)
            .compute_verifier(config.email.as_bytes(), &password_key, &salt);
        let team = Team {
            team_id: config.team_id.clone(),
            name: format!("{} {}", config.first_name, config.last_name),
            devices: Vec::new(),
            certificates: Vec::new(),
            app_ids: Vec::new(),
            groups: Vec::new(),
            max_certificates: 2,
            available_app_ids: 10,
        };
        Account {
            adsid: format!("000{}-08-{}", random_digits(3), uuid::Uuid::new_v4()),
            idms_token: BASE64_STANDARD.encode(random_bytes(48)),
            sk: random_bytes(32),
            c: random_bytes(32),
            salt,
            iterations,
            verifier,
            trusted_machines: BTreeSet::new(),
            code_sent: BTreeSet::new(),
            xcode_tokens: BTreeSet::new(),
            team,
            failed_logins: 0,
            config,
        }
    }
}

/// What the installer derives from the password, as Apple expects it.
fn password_key(password: &str, protocol: &str, salt: &[u8], iterations: u32) -> Vec<u8> {
    use sha2::Digest;
    let hashed = sha2::Sha256::digest(password.as_bytes());
    let input = if protocol == "s2k_fo" { hex::encode(hashed).into_bytes() } else { hashed.to_vec() };
    let mut out = [0u8; 32];
    pbkdf2::pbkdf2::<hmac::Hmac<sha2::Sha256>>(&input, salt, iterations, &mut out).expect("pbkdf2");
    out.to_vec()
}

/// A failure to give, once, in place of an answer.
#[derive(Clone, Debug)]
pub enum Failure {
    /// An HTTP status with no plist.
    Http(u16),
    /// GrandSlam's Status with this `ec` and `em`.
    Auth(i64, String),
    /// The developer services' resultCode and userString.
    Developer(i64, String),
}

#[derive(Debug, Default)]
pub struct AppleState {
    pub accounts: BTreeMap<String, Account>,
    /// The anisette machines Apple provisioned (X-Apple-I-MD-M).
    pub machines: BTreeSet<String>,
    spims: BTreeSet<String>,
    pending: BTreeMap<String, gsa::PendingLogin>,
    failures: Vec<(String, Failure)>,
    /// Requests that get a 429 before Apple answers again.
    pub too_many_requests: u32,
    pub log: Vec<String>,
}

impl AppleState {
    /// The failure queued for `endpoint`, if any, taken.
    fn failure(&mut self, endpoint: &str) -> Option<Failure> {
        let at = self.failures.iter().position(|(e, _)| e == endpoint)?;
        Some(self.failures.remove(at).1)
    }

    fn account_by_adsid(&mut self, adsid: &str) -> Option<&mut Account> {
        self.accounts.values_mut().find(|a| a.adsid == adsid)
    }
}

struct Shared {
    addr: SocketAddr,
    ca: AppleCa,
    state: Mutex<AppleState>,
}

#[derive(Clone)]
pub struct FakeApple(Arc<Shared>);

impl FakeApple {
    pub async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind fake Apple");
        let apple = FakeApple(Arc::new(Shared {
            addr: listener.local_addr().expect("address"),
            ca: AppleCa::new(),
            state: Mutex::new(AppleState::default()),
        }));
        let server = apple.clone();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else { break };
                let _ = stream.set_nodelay(true);
                let apple = server.clone();
                tokio::spawn(async move {
                    let _ = http::serve(stream, |request| {
                        let apple = apple.clone();
                        async move { apple.handle(request) }
                    })
                    .await;
                });
            }
        });
        apple
    }

    /// The proxy URL to give isideload: requests go to this address with
    /// their own URL appended, percent-encoded.
    pub fn proxy_url(&self) -> String {
        format!("http://{}/?url=", self.0.addr)
    }

    pub fn state(&self) -> MutexGuard<'_, AppleState> {
        self.0.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn ca(&self) -> &AppleCa {
        &self.0.ca
    }

    pub fn add_account(&self, config: AccountConfig) -> String {
        let email = config.email.clone();
        let account = Account::new(config);
        let team = account.team.team_id.clone();
        self.state().accounts.insert(email, account);
        team
    }

    /// Runs `f` on the account's state, for a test to look or change.
    pub fn with_account<T>(&self, email: &str, f: impl FnOnce(&mut Account) -> T) -> T {
        let mut state = self.state();
        let account = state.accounts.get_mut(&email.to_lowercase()).expect("no such account");
        f(account)
    }

    /// Gives `failure` the next time `endpoint` is asked: "init",
    /// "complete", "apptokens", "validate", "trusteddevice", a developer
    /// service's action ("listTeams", "submitDevelopmentCSR", "addAppId"…)
    /// or "bundleIds" for Increased Memory Limit.
    pub fn fail_next(&self, endpoint: &str, failure: Failure) {
        self.state().failures.push((endpoint.to_string(), failure));
    }

    /// A development certificate made on another computer: the one
    /// SideStore, AltStore or Xcode left on the account.
    pub fn add_foreign_certificate(&self, email: &str, machine_name: &str) -> String {
        let key = rcgen::KeyPair::generate().expect("key");
        let csr = rcgen::CertificateParams::new(Vec::<String>::new())
            .expect("params")
            .serialize_request(&key)
            .expect("csr")
            .pem()
            .expect("pem");
        let mut state = self.state();
        let account = state.accounts.get_mut(&email.to_lowercase()).expect("no such account");
        let holder = format!("{} {}", account.config.first_name, account.config.last_name);
        let issued = self.0.ca.issue_development(&csr, &account.team.team_id, &holder).expect("certificate");
        account.team.certificates.push(Certificate {
            id: random_id(10),
            serial: issued.serial.clone(),
            machine_id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            machine_name: machine_name.to_string(),
            der: issued.der,
            expires: SystemTime::now() + Duration::from_secs(365 * 24 * 3600),
        });
        issued.serial
    }

    /// A certificate and its profile made on Apple's developer website, for
    /// a paid account of the player's own and these iPhones: what "I have a
    /// signing certificate (.p12)" installs with, without this Apple.
    pub fn own_signing(&self, udids: &[&str]) -> OwnSigning {
        OwnSigning::new(self, udids)
    }

    pub fn log(&self) -> Vec<String> {
        self.state().log.clone()
    }

    pub(crate) fn note(&self, line: impl Into<String>) {
        let line = line.into();
        tracing::debug!("fake Apple: {line}");
        self.state().log.push(line);
    }

    fn handle(&self, request: Request) -> Response {
        if request.path() != "/" {
            return Response::text(404, "not a proxied request");
        }
        let Some(url) = request.query("url") else {
            return Response::text(400, "no url");
        };
        let Some((host, path, query)) = split_url(&url) else {
            return Response::text(400, "bad url");
        };
        {
            let mut state = self.state();
            if state.too_many_requests > 0 {
                state.too_many_requests -= 1;
                drop(state);
                self.note(format!("429 for {host}{path}"));
                return Response::text(429, "Too Many Requests");
            }
        }
        match host.as_str() {
            "gsa.apple.com" => gsa::handle(self, &request, &path),
            "developerservices2.apple.com" => developer::handle(self, &request, &path, &query),
            _ => Response::text(404, &format!("the fake Apple does not serve {host}")),
        }
    }
}

/// (host, path, query) of an https URL.
fn split_url(url: &str) -> Option<(String, String, String)> {
    let rest = url.strip_prefix("https://")?;
    let (host, path_query) = rest.split_once('/').map(|(h, p)| (h, format!("/{p}"))).unwrap_or((rest, "/".into()));
    let (path, query) = path_query.split_once('?').map(|(p, q)| (p.to_string(), q.to_string())).unwrap_or((path_query.clone(), String::new()));
    Some((host.to_string(), path, query))
}

pub(crate) fn random_bytes(n: usize) -> Vec<u8> {
    let mut v = vec![0u8; n];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut v);
    v
}

pub(crate) fn random_id(n: usize) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ0123456789";
    random_bytes(n).iter().map(|b| ALPHABET[*b as usize % ALPHABET.len()] as char).collect()
}

fn random_digits(n: usize) -> String {
    random_bytes(n).iter().map(|b| (b'0' + b % 10) as char).collect()
}

/// The anisette machine identifier (X-Apple-I-MD-M) that provisioning with
/// this transport key gives: Apple and the anisette server derive the same.
pub fn machine_id(tk: &str) -> String {
    use sha2::Digest;
    BASE64_STANDARD.encode(sha2::Sha256::digest(format!("machine:{tk}").as_bytes()))
}

/// What the anisette server answers Apple's start of provisioning with.
pub fn cpim_for(spim: &str) -> String {
    use sha2::Digest;
    BASE64_STANDARD.encode(sha2::Sha256::digest(format!("cpim:{spim}").as_bytes()))
}
