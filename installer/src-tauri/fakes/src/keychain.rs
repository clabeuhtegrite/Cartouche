//! A keychain in memory for the keyring crate, in place of the system's:
//! the tests never touch the computer's keychain, and can look at what the
//! installer kept, or make the keychain refuse everything.

use std::{
    any::Any,
    collections::{BTreeMap, BTreeSet},
    sync::{Arc, Mutex, OnceLock},
};

use keyring::{
    Error,
    credential::{Credential, CredentialApi, CredentialBuilderApi, CredentialPersistence},
};

#[derive(Default)]
struct Store {
    entries: BTreeMap<(String, String), Vec<u8>>,
    /// Services whose every call fails, as a keychain that is locked or a
    /// computer without one.
    broken: BTreeSet<String>,
}

#[derive(Clone, Default)]
pub struct MemoryKeychain(Arc<Mutex<Store>>);

static KEYCHAIN: OnceLock<MemoryKeychain> = OnceLock::new();

/// The process's keychain: the first call makes it keyring's default.
pub fn install() -> MemoryKeychain {
    KEYCHAIN
        .get_or_init(|| {
            let keychain = MemoryKeychain::default();
            keyring::set_default_credential_builder(Box::new(Builder(keychain.clone())));
            keychain
        })
        .clone()
}

impl MemoryKeychain {
    fn store(&self) -> std::sync::MutexGuard<'_, Store> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn get(&self, service: &str, user: &str) -> Option<Vec<u8>> {
        self.store().entries.get(&(service.to_string(), user.to_string())).cloned()
    }

    pub fn password(&self, service: &str, user: &str) -> Option<String> {
        self.get(service, user).and_then(|v| String::from_utf8(v).ok())
    }

    pub fn set(&self, service: &str, user: &str, secret: &[u8]) {
        self.store().entries.insert((service.to_string(), user.to_string()), secret.to_vec());
    }

    /// The users of every entry of the service.
    pub fn users(&self, service: &str) -> Vec<String> {
        self.store()
            .entries
            .keys()
            .filter(|(s, _)| s == service)
            .map(|(_, u)| u.clone())
            .collect()
    }

    pub fn break_service(&self, service: &str) {
        self.store().broken.insert(service.to_string());
    }
}

struct Builder(MemoryKeychain);

impl CredentialBuilderApi for Builder {
    fn build(&self, _target: Option<&str>, service: &str, user: &str) -> keyring::Result<Box<Credential>> {
        Ok(Box::new(Entry {
            keychain: self.0.clone(),
            service: service.to_string(),
            user: user.to_string(),
        }))
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn persistence(&self) -> CredentialPersistence {
        CredentialPersistence::ProcessOnly
    }
}

#[derive(Debug)]
struct Entry {
    keychain: MemoryKeychain,
    service: String,
    user: String,
}

impl std::fmt::Debug for MemoryKeychain {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("MemoryKeychain")
    }
}

#[derive(Debug)]
struct Broken;

impl std::fmt::Display for Broken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the keychain is not available")
    }
}

impl std::error::Error for Broken {}

impl Entry {
    fn check(&self) -> keyring::Result<()> {
        if self.keychain.store().broken.contains(&self.service) {
            return Err(Error::PlatformFailure(Box::new(Broken)));
        }
        Ok(())
    }

    fn key(&self) -> (String, String) {
        (self.service.clone(), self.user.clone())
    }
}

impl CredentialApi for Entry {
    fn set_secret(&self, secret: &[u8]) -> keyring::Result<()> {
        self.check()?;
        self.keychain.store().entries.insert(self.key(), secret.to_vec());
        Ok(())
    }

    fn get_secret(&self) -> keyring::Result<Vec<u8>> {
        self.check()?;
        self.keychain.store().entries.get(&self.key()).cloned().ok_or(Error::NoEntry)
    }

    fn delete_credential(&self) -> keyring::Result<()> {
        self.check()?;
        self.keychain.store().entries.remove(&self.key()).map(|_| ()).ok_or(Error::NoEntry)
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}
