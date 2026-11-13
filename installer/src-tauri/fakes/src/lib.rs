//! Fakes of everything the Cartouche Installer talks to, for its tests: an
//! iPhone behind usbmuxd, Apple's sign-in and developer services, an
//! anisette server, GitHub with Cartouche's source and IPA, and a keychain.

pub mod anisette;
pub mod apple;
pub mod github;
pub mod http;
pub mod iphone;
pub mod ipa;
pub mod keychain;
pub mod tls;
pub mod wire;

pub use anisette::FakeAnisette;
pub use apple::{AccountConfig, FakeApple, TwoFactor};
pub use github::FakeGithub;
pub use iphone::{FakeIphone, FakeUsbmuxd, IphoneConfig, Trust};
pub use keychain::MemoryKeychain;
