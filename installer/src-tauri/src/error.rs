use idevice::IdeviceError;
use isideload::SideloadError;
use rootcause::Report;
use serde::Serialize;
use serde::ser::{SerializeStruct, Serializer};

#[derive(Debug, thiserror::Error, Clone, strum::AsRefStr, strum::VariantNames)]
#[strum(serialize_all = "snake_case")]
pub enum AppError {
    #[error("{0}")]
    MaxApps(String),
    #[error("{0}")]
    NotEnoughAppIds(String),
    #[error("{0}")]
    DeviceComs(String),
    #[error("{0}")]
    Underage(String),
    #[error("{0}")]
    AccountLocked(String),
    #[error("{0}")]
    Developer(String),
    #[error("{0}")]
    Auth(String),
    #[error("{0}")]
    Download(String),
    #[error("{0}: {1}")]
    HouseArrest(String, String),
    #[error("{0}")]
    RemotePairing(String),
    #[error("{0}: {1}")]
    LockdownPairing(String, String),
    #[error("{0} canceled")]
    Canceled(String),
    #[error("Failed to emit status to frontend: {0}")]
    OperationUpdate(String),
    #[error("{0}: {1}")]
    DeviceComsWithMessage(String, String),
    #[error("{0}: {1}")]
    Usbmuxd(String, String),
    #[error("Not logged in")]
    NotLoggedIn,
    #[error("No device selected")]
    NoDeviceSelected,
    #[error("{0}")]
    Anisette(String),
    #[error("{0}")]
    Keyring(String),
    #[error("Keyring error: {0} - {1}")]
    KeyringWithMessage(String, String),
    #[error("{0}: {1}")]
    Storage(String, String),
    #[error("{0}")]
    Misc(String),
    #[error("{0}: {1}")]
    Filesystem(String, String),
    #[error("{0}")]
    NotCartouche(String),
    #[error("{0}")]
    CartoucheMissing(String),
}

impl Serialize for AppError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut state = serializer.serialize_struct("AppError", 2)?;
        state.serialize_field("type", self.as_ref())?;
        state.serialize_field("message", &self.to_string())?;
        state.end()
    }
}

// from rootcause report
impl From<Report> for AppError {
    fn from(report: Report) -> Self {
        let report_str = report.to_string();

        for cause in report.iter_reports() {
            if cause.downcast_current_context::<keyring::Error>().is_some() {
                return AppError::Keyring(report_str);
            }
            if let Some(err) = cause.downcast_current_context::<SideloadError>() {
                match err {
                    &SideloadError::AuthWithMessage(code, _) => match code {
                        -20209 => return AppError::AccountLocked(report_str),
                        _ => {
                            return AppError::Auth(report_str);
                        }
                    },
                    &SideloadError::DeveloperError(code, _) => match code {
                        1102 => return AppError::Underage(report_str),
                        _ => {
                            return AppError::Developer(report_str);
                        }
                    },
                    SideloadError::IdeviceError(idev_err) => match idev_err {
                        IdeviceError::Socket(_) => {
                            return AppError::DeviceComs(report_str);
                        }
                        IdeviceError::ApplicationVerificationFailed(e) => {
                            if e.contains("maximum number of installed apps") {
                                return AppError::MaxApps(report_str);
                            }
                        }
                        _ => {}
                    },
                    _ => {}
                }
            }
            let cause_str = cause.to_string();
            if cause_str.contains("Not enough available app IDs") {
                return AppError::NotEnoughAppIds(report_str);
            }
            if cause_str.contains("Failed to get anisette data for login")
                || cause_str.contains("Failed to get anisette client info")
                || cause_str.contains("Failed to get anisette headers")
            {
                return AppError::Anisette(report_str);
            }
        }

        AppError::Misc(report_str)
    }
}

#[cfg(test)]
mod tests {
    use strum::VariantNames;

    use super::*;

    /// The window picks what to suggest by the error's type: every type the
    /// installer gives has its entry in errors.tsx, and errors.tsx names no
    /// type the installer no longer gives.
    #[test]
    fn the_window_knows_every_error() {
        let errors = include_str!("../../src/errors.tsx");
        let start = errors.find("export const errorSuggestionKeys = {").expect("errorSuggestionKeys");
        let end = start + errors[start..].find("} as const;").expect("its end");
        let known: Vec<&str> = errors[start..end]
            .lines()
            .skip(1)
            .filter_map(|line| line.trim().split_once(':').map(|(key, _)| key))
            .filter(|key| !key.is_empty() && key.chars().all(|c| c.is_ascii_lowercase() || c == '_'))
            .collect();
        for variant in AppError::VARIANTS {
            assert!(known.contains(variant), "errors.tsx has no suggestions for {variant}");
        }
        for key in &known {
            assert!(AppError::VARIANTS.contains(key), "errors.tsx names {key}, which the installer never gives");
        }
    }

    #[test]
    fn serializes_as_the_window_reads_it() {
        let error = AppError::DeviceComsWithMessage("Failed to get device".into(), "gone".into());
        assert_eq!(
            serde_json::to_value(&error).unwrap(),
            serde_json::json!({ "type": "device_coms_with_message", "message": "Failed to get device: gone" })
        );
    }
}
