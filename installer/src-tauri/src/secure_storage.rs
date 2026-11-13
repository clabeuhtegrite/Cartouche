use std::sync::atomic::{AtomicBool, Ordering};

use isideload::util::{
    fs_storage::FsStorage, keyring_storage::KeyringStorage, storage::SideloadingStorage,
};
use tauri::{AppHandle, Manager, Runtime};
use tracing::warn;

use crate::{environment::Environment, error::AppError};

/// Settings' "Don't use the keychain", for as long as the installer runs.
#[derive(Default)]
pub struct KeyringSwitch {
    forced_off: AtomicBool,
}

#[tauri::command]
pub fn force_disable_keyring<R: Runtime>(app: AppHandle<R>, force: bool) {
    app.state::<KeyringSwitch>()
        .forced_off
        .store(force, Ordering::Relaxed);

    if force {
        warn!("Keyring has been forcefully disabled by the user.");
    } else if !check_keyring_available(&app) {
        warn!("Keyring is not available and cannot be enabled.");
    }
}

#[tauri::command]
pub fn keyring_available<R: Runtime>(app: AppHandle<R>) -> bool {
    !app.state::<KeyringSwitch>().forced_off.load(Ordering::Relaxed)
        && check_keyring_available(&app)
}

fn check_keyring_available<R: Runtime>(app: &AppHandle<R>) -> bool {
    let service = &app.state::<Environment>().keyring_service;
    let entry = keyring::Entry::new(service, "test");
    if let Ok(entry) = entry {
        return entry.set_password("test").is_ok() && entry.get_password().is_ok();
    }
    false
}

pub fn create_sideloading_storage<R: Runtime>(
    app: &AppHandle<R>,
) -> Result<Box<dyn SideloadingStorage>, AppError> {
    if keyring_available(app.clone()) {
        Ok(Box::new(KeyringStorage::new(
            app.state::<Environment>().keyring_service.clone(),
        )))
    } else {
        warn!(
            "Keyring is not available, falling back to filesystem storage for sideloading data. The pairing record, anisette state and certificate are on disk."
        );
        Ok(Box::new(FsStorage::new(
            app.path().app_data_dir().map_err(|e| {
                AppError::Misc(format!("Failed to get app data directory: {:?}", e))
            })?,
        )))
    }
}
