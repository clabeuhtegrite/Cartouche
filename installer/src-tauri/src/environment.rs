//! What the installer reaches outside itself, and where it keeps its
//! secrets: the system's in the app, fakes in the tests (tests/README.md).

use idevice::usbmuxd::UsbmuxdAddr;

use crate::error::AppError;

pub struct Environment {
    /// usbmuxd, which reaches the iPhone: where USBMUXD_SOCKET_ADDRESS says,
    /// as idevice reads it, otherwise the system's. Listing the iPhones and
    /// connecting to one both go there.
    usbmuxd: Result<UsbmuxdAddr, String>,
    /// The client for Cartouche's source and IPA, on GitHub.
    pub http: reqwest::Client,
    /// The proxy isideload sends Apple's requests through: none in the app.
    pub apple_proxy: Option<String>,
    /// The keychain service the installer's entries are under.
    pub keyring_service: String,
}

impl Environment {
    pub fn system() -> Self {
        Environment {
            usbmuxd: UsbmuxdAddr::from_env_var().map_err(|e| e.to_string()),
            http: reqwest::Client::new(),
            apple_proxy: None,
            keyring_service: crate::KEYRING_SERVICE.to_string(),
        }
    }

    /// For the tests: the fakes' addresses.
    pub fn new(
        usbmuxd: UsbmuxdAddr,
        http: reqwest::Client,
        apple_proxy: Option<String>,
        keyring_service: String,
    ) -> Self {
        Environment {
            usbmuxd: Ok(usbmuxd),
            http,
            apple_proxy,
            keyring_service,
        }
    }

    pub fn usbmuxd(&self) -> Result<UsbmuxdAddr, AppError> {
        self.usbmuxd.clone().map_err(|e| {
            AppError::Usbmuxd("Invalid usbmuxd address from environment".into(), e)
        })
    }
}
