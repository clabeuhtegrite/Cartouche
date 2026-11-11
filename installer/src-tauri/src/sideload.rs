use std::sync::Mutex;

use crate::{
    device::{DeviceInfoMutex, get_provider},
    error::AppError,
};
use isideload::{
    sideload::{application::SpecialApp, sideloader::Sideloader},
    util::callbacks::{ExtensionsBehaviorCallbackBox, MaxCertsCallbackBox},
};
use tauri::State;

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
/// Returns the detected special app and the exact installed bundle identifier.
pub async fn sideload<F, Fut>(
    device_state: &State<'_, DeviceInfoMutex>,
    sideloader_state: &State<'_, SideloaderMutex>,
    app_path: String,
    progress: Option<F>,
) -> Result<(Option<SpecialApp>, String), AppError>
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

    let provider = get_provider(&device.info).await?;

    let mut sideloader = SideloaderGuard::take(sideloader_state)?;
    let team = sideloader.get_mut().get_team().await?;
    let installed_bundle_id = format!("{}.{}", crate::cartouche::BUNDLE_ID, team.team_id);

    let special = sideloader
        .get_mut()
        .install_app(
            &provider,
            app_path.into(),
            true,
            progress,
            Some(&device.pairing),
        )
        .await?;

    Ok((special, installed_bundle_id))
}
