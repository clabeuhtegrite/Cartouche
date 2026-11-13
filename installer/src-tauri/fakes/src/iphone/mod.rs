//! A fake iPhone behind a fake usbmuxd: what the installer finds when an
//! iPhone is plugged in. It answers lockdown in TLS with the keys of its pair
//! record, asks "Trust This Computer?" for a remote pairing, stores files
//! sent over AFC, installs apps only once it has checked their signature and
//! provisioning profile as iOS does, and lets house_arrest into an app's
//! Documents.

mod afc;
mod instproxy;
mod lockdown;
mod rppairing;
mod usbmuxd;
pub mod verify;

use std::{
    collections::{BTreeMap, HashMap},
    sync::{Arc, Mutex, MutexGuard},
    time::Duration,
};

pub use afc::MemFs;
pub use usbmuxd::FakeUsbmuxd;

use crate::tls::PairKeys;

/// What the iPhone says about itself.
#[derive(Clone, Debug)]
pub struct IphoneConfig {
    pub udid: String,
    pub name: String,
    pub product_version: String,
    pub product_type: String,
    pub build_version: String,
    /// usbmuxd's number for the device.
    pub device_id: u32,
    pub wifi_mac: String,
}

impl IphoneConfig {
    /// An iPhone 17 Pro on iOS 26, as most players have.
    pub fn iphone_17_pro(device_id: u32) -> Self {
        IphoneConfig {
            udid: format!("00008150-{:016X}", 0x001A_2B3C_4D5E_6F00u64 + device_id as u64),
            name: format!("iPhone de Test {device_id}"),
            product_version: "26.1".into(),
            product_type: "iPhone18,1".into(),
            build_version: "23B85".into(),
            device_id,
            wifi_mac: format!("a4:83:e7:12:34:{:02x}", device_id & 0xff),
        }
    }

    /// An older iPhone on iOS 17.3, before remote pairing.
    pub fn ios_17_3(device_id: u32) -> Self {
        IphoneConfig {
            product_version: "17.3.1".into(),
            product_type: "iPhone15,2".into(),
            build_version: "21D61".into(),
            name: format!("Vieil iPhone {device_id}"),
            ..Self::iphone_17_pro(device_id)
        }
    }
}

/// How the person holding the iPhone answers "Trust This Computer?".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Trust {
    /// Taps Trust and types the passcode.
    Accept,
    /// Taps Don't Trust.
    Refuse,
    /// Never answers.
    Never,
}

/// An app as the iPhone keeps it once installed.
#[derive(Clone, Debug)]
pub struct InstalledApp {
    pub bundle_id: String,
    pub info: plist::Dictionary,
    /// Every file of the .app, by its path inside it.
    pub files: BTreeMap<String, Vec<u8>>,
    /// The app's container: Documents and the rest.
    pub container: MemFs,
    /// What the iPhone read from its signature and profile.
    pub signature: verify::VerifiedApp,
}

/// A computer the iPhone trusts through remote pairing.
#[derive(Clone, Debug)]
pub struct RpHost {
    pub identifier: String,
    pub public_key: [u8; 32],
    pub name: String,
}

#[derive(Clone, Copy, Debug)]
pub(crate) enum Service {
    Afc,
    InstallationProxy,
    HouseArrest,
    RemotePairing,
}

/// Everything about the iPhone a test may look at or change.
pub struct State {
    pub trust: Trust,
    /// Whether usbmuxd on the computer keeps a pair record for the iPhone:
    /// false for an iPhone that never trusted this computer.
    pub usbmuxd_pair_record: bool,
    /// Whether the iPhone still knows the computer of that pair record:
    /// false once it forgot it (Reset Location & Privacy).
    pub knows_host: bool,
    pub wifi_debugging: bool,
    /// /var/mobile/Media, which AFC serves.
    pub media: MemFs,
    pub apps: BTreeMap<String, InstalledApp>,
    pub rp_hosts: Vec<RpHost>,
    /// iOS lets a free Apple ID's apps on an iPhone up to this many.
    pub free_app_limit: usize,
    pub pair_setups: usize,
    pub pair_verifies: usize,
    /// When set, the next install fails with this lockdown error and description.
    pub fail_install: Option<(String, String)>,
    /// When true, the iPhone is unplugged: usbmuxd no longer lists it.
    pub unplugged: bool,
    /// How long the iPhone takes over each step of an install, to let a
    /// test see it in progress.
    pub install_delay: Duration,
    /// What happened, in order, for a test that fails to tell why.
    pub log: Vec<String>,
    pub(crate) services: HashMap<u16, Service>,
    pub(crate) next_port: u16,
}

pub(crate) struct Shared {
    pub config: IphoneConfig,
    pub keys: PairKeys,
    pub tls: Arc<rustls::ServerConfig>,
    /// The iPhone's remote-pairing identity.
    pub rp_identifier: String,
    pub rp_key: ed25519_dalek::SigningKey,
    pub alt_irk: [u8; 16],
    pub state: Mutex<State>,
}

/// A fake iPhone. Clones are the same iPhone.
#[derive(Clone)]
pub struct FakeIphone(pub(crate) Arc<Shared>);

impl FakeIphone {
    pub fn new(config: IphoneConfig) -> Self {
        let keys = PairKeys::generate();
        let tls = keys.device_tls();
        let mut seed = [0u8; 32];
        rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut seed);
        let mut alt_irk = [0u8; 16];
        rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut alt_irk);
        let mut media = MemFs::default();
        media.mkdir_p("PublicStaging").expect("staging");
        FakeIphone(Arc::new(Shared {
            rp_identifier: uuid::Uuid::new_v4().to_string().to_uppercase(),
            rp_key: ed25519_dalek::SigningKey::from_bytes(&seed),
            alt_irk,
            config,
            keys,
            tls,
            state: Mutex::new(State {
                trust: Trust::Accept,
                usbmuxd_pair_record: true,
                knows_host: true,
                wifi_debugging: false,
                media,
                apps: BTreeMap::new(),
                rp_hosts: Vec::new(),
                free_app_limit: 3,
                pair_setups: 0,
                pair_verifies: 0,
                fail_install: None,
                unplugged: false,
                install_delay: Duration::ZERO,
                log: Vec::new(),
                services: HashMap::new(),
                next_port: 49152,
            }),
        }))
    }

    pub fn config(&self) -> &IphoneConfig {
        &self.0.config
    }

    pub fn udid(&self) -> &str {
        &self.0.config.udid
    }

    /// The iPhone's state, to look at or change. Never hold it across an await.
    pub fn state(&self) -> MutexGuard<'_, State> {
        self.0.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn set_trust(&self, trust: Trust) {
        self.state().trust = trust;
    }

    /// The pair record usbmuxd keeps for this iPhone.
    pub fn pair_record(&self) -> plist::Dictionary {
        self.0.keys.pair_record(&self.0.config.udid, &self.0.config.wifi_mac)
    }

    /// The installed app whose identifier starts with `prefix`.
    pub fn app(&self, prefix: &str) -> Option<InstalledApp> {
        self.state()
            .apps
            .values()
            .find(|a| a.bundle_id.starts_with(prefix))
            .cloned()
    }

    /// A file in an installed app's container, such as
    /// `Documents/SideStore/Documents/ALTPairingFile.mobiledevicepairing`.
    pub fn container_file(&self, bundle_id: &str, path: &str) -> Option<Vec<u8>> {
        self.state()
            .apps
            .get(bundle_id)
            .and_then(|a| a.container.read(path).ok())
    }

    pub fn log(&self) -> Vec<String> {
        self.state().log.clone()
    }

    /// Puts an app on the iPhone as if another tool had installed it, to
    /// fill the free apps or to have Cartouche installed already.
    pub fn preinstall(&self, bundle_id: &str, version: &str, free: bool) {
        let mut info = plist::Dictionary::new();
        info.insert("CFBundleIdentifier".into(), bundle_id.into());
        info.insert("CFBundleShortVersionString".into(), version.into());
        info.insert("CFBundleVersion".into(), version.into());
        info.insert("CFBundleExecutable".into(), "App".into());
        info.insert("UIFileSharingEnabled".into(), true.into());
        let mut container = MemFs::default();
        for dir in ["Documents", "Library", "tmp"] {
            container.mkdir_p(dir).expect("container");
        }
        self.state().apps.insert(
            bundle_id.to_string(),
            InstalledApp {
                bundle_id: bundle_id.to_string(),
                info,
                files: BTreeMap::new(),
                container,
                signature: verify::VerifiedApp {
                    free_profile: free,
                    ..Default::default()
                },
            },
        );
    }

    pub(crate) fn note(&self, line: impl Into<String>) {
        let line = line.into();
        tracing::debug!("fake iPhone {}: {line}", self.0.config.name);
        self.state().log.push(line);
    }

    pub(crate) fn open_service(&self, service: Service) -> u16 {
        let mut state = self.state();
        let port = state.next_port;
        state.next_port = state.next_port.wrapping_add(1).max(49152);
        state.services.insert(port, service);
        port
    }

    pub(crate) fn take_service(&self, port: u16) -> Option<Service> {
        self.state().services.remove(&port)
    }

    /// Whether remote pairing exists on this iOS (17 and later).
    pub(crate) fn has_remote_pairing(&self) -> bool {
        self.0
            .config
            .product_version
            .split('.')
            .next()
            .and_then(|m| m.parse::<u32>().ok())
            .is_some_and(|major| major >= 17)
    }
}
