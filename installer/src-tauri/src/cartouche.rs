//! What iloader does not do: download Cartouche itself, check it, and put the
//! pairing file in Cartouche once it is installed.

use std::{
    io::Read,
    path::{Path, PathBuf},
};

use idevice::{IdeviceService, installation_proxy::InstallationProxyClient};
use isideload::sideload::application::SpecialApp;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Manager, State, Window};
use tokio::io::AsyncWriteExt;
use tracing::{info, warn};

use crate::{
    device::{DeviceInfo, DeviceInfoMutex, get_provider},
    error::AppError,
    operation::Operation,
    pairing::place_file,
    sideload::{SideloaderMutex, sideload},
    imported_signing::{ImportedSigning, HANDOFF_FILE},
};

/// Cartouche's bundle identifier, CARTOUCHE_BUNDLE_ID in app/config.env.
/// isideload installs it as this identifier followed by the team's.
pub const BUNDLE_ID: &str = "io.github.clabeuhtegrite.cartouche";

/// The source Cartouche's built-in SideStore reads for Cartouche's updates,
/// CARTOUCHE_SIDESTORE_SOURCE_URL in app/config.env: every release of
/// Cartouche with its IPA's address, size and SHA-256, and nothing else.
const SOURCE_URL: &str =
    "https://raw.githubusercontent.com/clabeuhtegrite/Cartouche/main/app/sidestore-source.json";

/// Where Cartouche's built-in SideStore reads its pairing file, in Cartouche's
/// Documents: the place iloader uses for a LiveContainer+SideStore.
const PAIRING_PATH: &str = "SideStore/Documents/ALTPairingFile.mobiledevicepairing";

/// Only GitHub serves Cartouche's IPA, from the repository's releases.
const DOWNLOAD_PREFIX: &str = "https://github.com/clabeuhtegrite/Cartouche/releases/download/";

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Release {
    pub version: String,
    #[serde(default)]
    pub date: String,
    #[serde(rename(deserialize = "downloadURL"))]
    pub download_url: String,
    pub size: u64,
    pub sha256: String,
    #[serde(default, rename(deserialize = "localizedDescription"))]
    pub notes: String,
}

#[derive(Deserialize)]
struct Source {
    apps: Vec<SourceApp>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SourceApp {
    bundle_identifier: String,
    versions: Vec<Release>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledCartouche {
    pub bundle_id: String,
    pub version: Option<String>,
}

fn version_key(version: &str) -> Vec<u64> {
    version
        .split('.')
        .map(|part| {
            part.chars()
                .take_while(|c| c.is_ascii_digit())
                .collect::<String>()
                .parse()
                .unwrap_or(0)
        })
        .collect()
}

/// The highest version the source lists.
fn latest_in(source: &str) -> Result<Release, AppError> {
    let source: Source = serde_json::from_str(source)
        .map_err(|e| AppError::Download(format!("Cartouche's source does not read: {e}")))?;
    let release = source
        .apps
        .into_iter()
        .filter(|app| app.bundle_identifier == BUNDLE_ID)
        .flat_map(|app| app.versions)
        .max_by_key(|release| version_key(&release.version))
        .ok_or_else(|| AppError::Download("Cartouche's source lists no release".into()))?;
    if !release.download_url.starts_with(DOWNLOAD_PREFIX) {
        return Err(AppError::Download(format!(
            "Cartouche's source gives an IPA outside its GitHub releases: {}",
            release.download_url
        )));
    }
    Ok(release)
}

pub async fn latest_release() -> Result<Release, AppError> {
    let response = reqwest::get(SOURCE_URL)
        .await
        .map_err(|e| AppError::Download(e.to_string()))?;
    if !response.status().is_success() {
        return Err(AppError::Download(format!(
            "Cartouche's source answered HTTP {}",
            response.status()
        )));
    }
    let text = response
        .text()
        .await
        .map_err(|e| AppError::Download(e.to_string()))?;
    latest_in(&text)
}

/// The newest Cartouche, for the window to name before it installs it.
#[tauri::command]
pub async fn cartouche_release() -> Result<Release, AppError> {
    latest_release().await
}

/// Downloads the release's IPA to `dest`, and checks its size and SHA-256
/// against the source's.
async fn download(
    release: &Release,
    dest: &Path,
    progress: impl Fn(f32) -> std::future::Ready<()>,
) -> Result<(), AppError> {
    let mut response = reqwest::get(&release.download_url)
        .await
        .map_err(|e| AppError::Download(e.to_string()))?;
    if !response.status().is_success() {
        return Err(AppError::Download(format!(
            "The download of Cartouche {} answered HTTP {}",
            release.version,
            response.status()
        )));
    }
    let mut file = tokio::fs::File::create(dest).await.map_err(|e| {
        AppError::Filesystem("Failed to create the downloaded file".into(), e.to_string())
    })?;
    let mut hasher = Sha256::new();
    let mut received: u64 = 0;
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|e| AppError::Download(e.to_string()))?
    {
        received += chunk.len() as u64;
        if received > release.size {
            return Err(AppError::Download(format!(
                "Cartouche {} is larger than its source says ({} bytes)",
                release.version, release.size
            )));
        }
        hasher.update(&chunk);
        file.write_all(&chunk).await.map_err(|e| {
            AppError::Filesystem("Failed to write the downloaded file".into(), e.to_string())
        })?;
        progress(received as f32 / release.size.max(1) as f32).await;
    }
    file.flush().await.map_err(|e| {
        AppError::Filesystem("Failed to write the downloaded file".into(), e.to_string())
    })?;
    if received != release.size {
        return Err(AppError::Download(format!(
            "Cartouche {} came short: {received} bytes of {}",
            release.version, release.size
        )));
    }
    let digest = hex::encode(hasher.finalize());
    if !digest.eq_ignore_ascii_case(&release.sha256) {
        return Err(AppError::Download(format!(
            "Cartouche {} is not the file its source lists: SHA-256 {digest}, expected {}",
            release.version, release.sha256
        )));
    }
    Ok(())
}

/// The bundle identifier of the app in an IPA, from its Payload/<name>.app/Info.plist.
pub fn ipa_bundle_id(path: &Path) -> Result<String, AppError> {
    let file = std::fs::File::open(path)
        .map_err(|e| AppError::Filesystem("Failed to open the IPA".into(), e.to_string()))?;
    let mut archive = zip::ZipArchive::new(file)
        .map_err(|e| AppError::NotCartouche(format!("The file is not an IPA: {e}")))?;
    let name = archive
        .file_names()
        .find(|name| {
            let parts: Vec<&str> = name.split('/').collect();
            parts.len() == 3
                && parts[0] == "Payload"
                && parts[1].ends_with(".app")
                && parts[2] == "Info.plist"
        })
        .map(str::to_string)
        .ok_or_else(|| AppError::NotCartouche("The IPA holds no app".into()))?;
    let mut data = Vec::new();
    archive
        .by_name(&name)
        .map_err(|e| AppError::NotCartouche(e.to_string()))?
        .read_to_end(&mut data)
        .map_err(|e| AppError::NotCartouche(e.to_string()))?;
    let info = plist::Value::from_reader(std::io::Cursor::new(data))
        .map_err(|e| AppError::NotCartouche(format!("The app's Info.plist does not read: {e}")))?;
    info.as_dictionary()
        .and_then(|d| d.get("CFBundleIdentifier"))
        .and_then(|v| v.as_string())
        .map(str::to_string)
        .ok_or_else(|| AppError::NotCartouche("The app has no bundle identifier".into()))
}

/// Whether an installed app's identifier is Cartouche's: Cartouche's own, or
/// Cartouche's followed by a team identifier, as isideload installs it.
fn is_cartouche(bundle_id: &str) -> bool {
    bundle_id == BUNDLE_ID
        || bundle_id
            .strip_prefix(BUNDLE_ID)
            .and_then(|rest| rest.strip_prefix('.'))
            .is_some_and(|team| !team.is_empty() && team.chars().all(|c| c.is_ascii_alphanumeric()))
}

/// Cartouche as the iPhone lists it, if it is installed.
pub async fn find_installed(device: &DeviceInfo) -> Result<Option<InstalledCartouche>, AppError> {
    let provider = get_provider(device).await?;
    let mut installation_proxy = InstallationProxyClient::connect(&provider)
        .await
        .map_err(|e| {
            AppError::DeviceComsWithMessage(
                "Failed to connect to installation proxy".into(),
                e.to_string(),
            )
        })?;
    let apps = installation_proxy
        .get_apps(Some("User"), None)
        .await
        .map_err(|e| {
            AppError::DeviceComsWithMessage("Failed to get installed apps".into(), e.to_string())
        })?;
    // More than one when two Apple IDs installed it: the iPhone runs either.
    let mut found: Vec<InstalledCartouche> = apps
        .into_iter()
        .filter(|(bundle_id, _)| is_cartouche(bundle_id))
        .map(|(bundle_id, app)| InstalledCartouche {
            version: app
                .as_dictionary()
                .and_then(|d| d.get("CFBundleShortVersionString"))
                .and_then(|v| v.as_string())
                .map(str::to_string),
            bundle_id,
        })
        .collect();
    found.sort_by_key(|app| std::cmp::Reverse(version_key(app.version.as_deref().unwrap_or(""))));
    Ok(found.into_iter().next())
}

fn selected_device(device_state: &State<'_, DeviceInfoMutex>) -> Result<crate::device::DeviceInfoWithPairing, AppError> {
    let guard = device_state.lock().unwrap();
    guard.clone().ok_or(AppError::NoDeviceSelected)
}

/// The Cartouche installed on the selected iPhone, if any.
#[tauri::command]
pub async fn installed_cartouche(
    device_state: State<'_, DeviceInfoMutex>,
) -> Result<Option<InstalledCartouche>, AppError> {
    let device = selected_device(&device_state)?;
    find_installed(&device.info).await
}

/// Puts the selected iPhone's pairing file where Cartouche's built-in
/// SideStore reads it. Cartouche sees it there on its next start.
async fn place_pairing(device_state: &State<'_, DeviceInfoMutex>) -> Result<(), AppError> {
    let device = selected_device(device_state)?;
    let installed = find_installed(&device.info).await?.ok_or_else(|| {
        AppError::CartoucheMissing("The iPhone does not list Cartouche among its apps".into())
    })?;
    info!("Placing the pairing file in {}", installed.bundle_id);
    let provider = get_provider(&device.info).await?;
    place_file(device.pairing, &provider, installed.bundle_id, PAIRING_PATH.into()).await
}

/// Downloads the newest Cartouche, or takes the IPA of Cartouche at
/// `ipa_path`, signs and installs it with the imported identity or Apple ID.
/// Account signing requests Increased Memory Limit and transfers pairing;
/// imported signing uses only the supplied profile's permissions and hands
/// the identity to Cartouche for game signing.
#[tauri::command]
pub async fn install_cartouche_operation(
    handle: AppHandle,
    window: Window,
    device_state: State<'_, DeviceInfoMutex>,
    sideloader_state: State<'_, SideloaderMutex>,
    ipa_path: Option<String>,
    imported_signing: Option<ImportedSigning>,
) -> Result<(), AppError> {
    let op = Operation::new("install_cartouche".to_string(), &window);
    op.start("download")?;
    if device_state.lock().unwrap().is_none() {
        return op.fail("download", AppError::NoDeviceSelected);
    }
    if imported_signing.is_none() && sideloader_state.lock().unwrap().is_none() {
        return op.fail("download", AppError::NotLoggedIn);
    }
    let (path, downloaded): (PathBuf, bool) = match ipa_path {
        Some(path) => {
            let path = PathBuf::from(path);
            let bundle_id = op.fail_if_err("download", ipa_bundle_id(&path))?;
            if bundle_id != BUNDLE_ID {
                return op.fail(
                    "download",
                    AppError::NotCartouche(format!(
                        "This IPA holds {bundle_id}, not Cartouche: games go into Cartouche, from its Import"
                    )),
                );
            }
            (path, false)
        }
        None => {
            let release = op.fail_if_err("download", latest_release().await)?;
            let dir = op.fail_if_err(
                "download",
                handle
                    .path()
                    .temp_dir()
                    .map_err(|e| AppError::Filesystem("Failed to get temp dir".into(), e.to_string())),
            )?;
            let dest = dir.join(format!("Cartouche-{}.ipa", release.version));
            info!("Downloading Cartouche {} from {}", release.version, release.download_url);
            if let Err(e) = download(&release, &dest, op.progress_reporter("download")).await {
                let _ = tokio::fs::remove_file(&dest).await;
                return op.fail("download", e);
            }
            (dest, true)
        }
    };
    op.move_on("download", "install")?;
    if let Some(signing) = imported_signing {
        let device = op.fail_if_err("install", selected_device(&device_state))?;
        let signing_path = path.clone();
        let udid = device.info.udid.clone();
        let signed = tokio::task::spawn_blocking(move || signing.sign(&signing_path, &udid)).await;
        if downloaded { let _ = tokio::fs::remove_file(&path).await; }
        let signed = op.fail_if_err("install", signed.map_err(|_| AppError::Misc("Local signing stopped unexpectedly.".into())).and_then(|result| result))?;
        let provider = op.fail_if_err("install", get_provider(&device.info).await)?;
        let progress = op.progress_reporter("install");
        // Keep the private temporary workspace alive until upload completes.
        let installed = isideload::sideload::install::install_app(&provider, &signed.app_path, |percent| { drop(progress(percent as f32 / 100.0)); }).await;
        op.fail_if_err("install", installed.map_err(AppError::from))?;
        progress(1.0).await;
        op.move_on("install", "pairing")?;
        op.fail_if_err("pairing", place_file(signed.handoff, &provider, BUNDLE_ID.into(), HANDOFF_FILE.into()).await)?;
        drop(signed.workspace);
        op.complete("pairing")?;
        return Ok(());
    }
    let installed = sideload(
        &device_state,
        &sideloader_state,
        path.to_string_lossy().to_string(),
        Some(op.progress_reporter("install")),
    )
    .await;
    if downloaded {
        let _ = tokio::fs::remove_file(&path).await;
    }
    let special = op.fail_if_err("install", installed)?;
    if special != Some(SpecialApp::SideStoreLc) {
        // isideload gives SideStore's certificate only to an app it takes for
        // a LiveContainer+SideStore: Cartouche, by its SideStore framework.
        warn!("isideload did not take the IPA for a LiveContainer+SideStore: {special:?}");
    }
    op.move_on("install", "pairing")?;
    op.fail_if_err("pairing", place_pairing(&device_state).await)?;
    op.complete("pairing")?;
    Ok(())
}

/// Puts the pairing file in the Cartouche already installed, for an iPhone
/// whose pairing changed: after Delete Stored Pairing, or an iPhone erased.
#[tauri::command]
pub async fn place_cartouche_pairing_operation(
    window: Window,
    device_state: State<'_, DeviceInfoMutex>,
) -> Result<(), AppError> {
    let op = Operation::new("place_cartouche_pairing".to_string(), &window);
    op.start("pairing")?;
    op.fail_if_err("pairing", place_pairing(&device_state).await)?;
    op.complete("pairing")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &str = r#"{
      "name": "Cartouche",
      "apps": [{
        "name": "Cartouche",
        "bundleIdentifier": "io.github.clabeuhtegrite.cartouche",
        "versions": [
          {"version": "0.2.0", "date": "2026-11-06T14:58:29Z",
           "downloadURL": "https://github.com/clabeuhtegrite/Cartouche/releases/download/v0.2.0/Cartouche-0.2.0.ipa",
           "size": 36526590, "sha256": "19d4", "localizedDescription": "Home"},
          {"version": "0.10.0", "date": "2026-12-01T00:00:00Z",
           "downloadURL": "https://github.com/clabeuhtegrite/Cartouche/releases/download/v0.10.0/Cartouche-0.10.0.ipa",
           "size": 1, "sha256": "ab"},
          {"version": "0.1.3", "date": "2026-11-06T10:41:49Z",
           "downloadURL": "https://github.com/clabeuhtegrite/Cartouche/releases/download/v0.1.3/Cartouche-0.1.3.ipa",
           "size": 2, "sha256": "cd"}
        ]
      }]
    }"#;

    #[test]
    fn takes_the_highest_version() {
        let release = latest_in(SOURCE).unwrap();
        assert_eq!(release.version, "0.10.0");
        assert_eq!(release.size, 1);
        assert!(release.notes.is_empty());
    }

    #[test]
    fn reads_cartouches_own_source() {
        // The source the release workflow writes, as the installer reads it
        // from main: a change of its shape shows up here first.
        let release = latest_in(include_str!("../../../app/sidestore-source.json")).unwrap();
        assert!(release.download_url.ends_with(&format!("/v{0}/Cartouche-{0}.ipa", release.version)));
        assert_eq!(release.sha256.len(), 64);
        assert!(release.sha256.chars().all(|c| c.is_ascii_hexdigit()));
        assert!(release.size > 1_000_000);
    }

    #[test]
    fn refuses_an_ipa_outside_the_releases() {
        let source = SOURCE.replace(
            "https://github.com/clabeuhtegrite/Cartouche/releases/download/v0.10.0/",
            "https://example.com/",
        );
        assert!(matches!(latest_in(&source), Err(AppError::Download(_))));
    }

    #[test]
    fn refuses_a_source_without_cartouche() {
        let source = SOURCE.replace("io.github.clabeuhtegrite.cartouche", "com.example.other");
        assert!(latest_in(&source).is_err());
    }

    #[test]
    fn knows_cartouche_by_its_identifier() {
        assert!(is_cartouche("io.github.clabeuhtegrite.cartouche"));
        assert!(is_cartouche("io.github.clabeuhtegrite.cartouche.ABCDE12345"));
        assert!(!is_cartouche("io.github.clabeuhtegrite.cartouche.installer.X"));
        assert!(!is_cartouche("io.github.clabeuhtegrite.cartouchex"));
        assert!(!is_cartouche("io.github.clabeuhtegrite.cartouche."));
        assert!(!is_cartouche("com.kdt.livecontainer"));
    }

    #[test]
    fn reads_the_bundle_identifier_of_an_ipa() {
        let dir = std::env::temp_dir().join(format!("cartouche-installer-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("Cartouche.ipa");
        let mut writer = zip::ZipWriter::new(std::fs::File::create(&path).unwrap());
        let options = zip::write::SimpleFileOptions::default();
        writer.add_directory("Payload/LiveContainer.app/", options).unwrap();
        writer
            .start_file("Payload/LiveContainer.app/Frameworks/SideStore.framework/Info.plist", options)
            .unwrap();
        std::io::Write::write_all(&mut writer, b"not this one").unwrap();
        writer.start_file("Payload/LiveContainer.app/Info.plist", options).unwrap();
        let mut info = plist::Dictionary::new();
        info.insert("CFBundleIdentifier".into(), BUNDLE_ID.into());
        plist::Value::Dictionary(info).to_writer_binary(&mut writer).unwrap();
        writer.finish().unwrap();
        assert_eq!(ipa_bundle_id(&path).unwrap(), BUNDLE_ID);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
