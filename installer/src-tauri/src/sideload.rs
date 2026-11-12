use std::{path::Path, sync::Mutex};

use crate::{
    device::{DeviceInfoMutex, get_provider},
    environment::Environment,
    error::AppError,
};
use isideload::{
    sideload::{application::SpecialApp, sideloader::Sideloader},
    util::callbacks::{ExtensionsBehaviorCallbackBox, MaxCertsCallbackBox},
};
use tauri::State;
use tracing::warn;

pub type SideloaderMutex =
    Mutex<Option<Sideloader<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox>>>;

pub struct SideloaderGuard<'a> {
    state: &'a SideloaderMutex,
    sideloader: Option<Sideloader<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox>>,
}

impl<'a> SideloaderGuard<'a> {
    pub fn take(state: &'a SideloaderMutex) -> Result<Self, AppError> {
        let mut guard = state.lock().unwrap();
        let sideloader = guard.take().ok_or(AppError::NotLoggedIn)?;
        Ok(Self {
            state,
            sideloader: Some(sideloader),
        })
    }

    pub fn get_mut(
        &mut self,
    ) -> &mut Sideloader<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox> {
        self.sideloader
            .as_mut()
            .expect("Sideloader should be present")
    }
}

impl Drop for SideloaderGuard<'_> {
    fn drop(&mut self) {
        let mut guard = self.state.lock().unwrap();
        *guard = self.sideloader.take();
    }
}

/// Signs the IPA at `app_path` with the signed-in Apple ID and installs it on
/// the selected iPhone, with Increased Memory Limit on its App ID, as iloader
/// does for every app. `progress` gets the fraction done, from 0 to 1.
pub async fn sideload<F, Fut>(
    env: &Environment,
    device_state: &State<'_, DeviceInfoMutex>,
    sideloader_state: &State<'_, SideloaderMutex>,
    app_path: String,
    progress: Option<F>,
) -> Result<Option<SpecialApp>, AppError>
where
    F: Fn(f32) -> Fut,
    Fut: Future<Output = ()>,
{
    let device = {
        let device_lock = device_state.lock().unwrap();
        match &*device_lock {
            Some(d) => d.clone(),
            None => return Err(AppError::NoDeviceSelected),
        }
    };

    let provider = get_provider(env, &device.info).await?;

    let mut sideloader = SideloaderGuard::take(sideloader_state)?;

    let special = sideloader
        .get_mut()
        .install_app(
            &provider,
            app_path.clone().into(),
            true,
            progress,
            Some(&device.pairing),
        )
        .await;
    remove_unpacked(Path::new(&app_path));

    Ok(special?)
}

/// isideload unpacks the IPA in the temporary folder, as `<its name>_extracted`,
/// and leaves it there: a whole copy of Cartouche for each version installed.
fn remove_unpacked(ipa: &Path) {
    let Some(name) = ipa.file_name() else { return };
    let unpacked = std::env::temp_dir().join(format!("{}_extracted", name.to_string_lossy()));
    if unpacked.is_dir()
        && let Err(e) = std::fs::remove_dir_all(&unpacked)
    {
        warn!("Failed to remove {}: {e}", unpacked.display());
    }
}
