//! installation_proxy, which lists and installs apps, and house_arrest, which
//! opens an app's Documents to AFC.

use std::io;

use tokio::net::TcpStream;

use super::{FakeIphone, InstalledApp, MemFs, afc, verify};
use crate::{
    dict,
    wire::{Stream, get_str, read_plist, write_plist},
};

/// What iOS answers when a free Apple ID already has its apps on the iPhone.
pub const MAX_FREE_APPS: &str = "This device has reached the maximum number of installed apps using a free developer profile";

pub async fn serve(iphone: FakeIphone, mut stream: TcpStream) -> io::Result<()> {
    loop {
        let Some(request) = read_plist(&mut stream).await? else {
            return Ok(());
        };
        let command = get_str(&request, "Command").unwrap_or("").to_string();
        match command.as_str() {
            "Lookup" | "Browse" => {
                let options = request.get("ClientOptions").and_then(|v| v.as_dictionary());
                let kind = options
                    .and_then(|o| get_str(o, "ApplicationType"))
                    .unwrap_or("Any")
                    .to_string();
                let wanted: Option<Vec<String>> = options
                    .and_then(|o| o.get("BundleIDs"))
                    .and_then(|v| v.as_array())
                    .map(|a| a.iter().filter_map(|v| v.as_string().map(str::to_string)).collect());
                let apps: Vec<(String, plist::Dictionary)> = iphone
                    .state()
                    .apps
                    .values()
                    .filter(|_| kind == "Any" || kind == "User")
                    .filter(|a| wanted.as_ref().is_none_or(|w| w.contains(&a.bundle_id)))
                    .map(|a| (a.bundle_id.clone(), listing(a)))
                    .collect();
                if command == "Lookup" {
                    let mut result = plist::Dictionary::new();
                    for (id, info) in apps {
                        result.insert(id, plist::Value::Dictionary(info));
                    }
                    write_plist(&mut stream, &dict! { "LookupResult" => result, "Status" => "Complete" }).await?;
                } else {
                    let list: Vec<plist::Value> = apps.into_iter().map(|(_, i)| plist::Value::Dictionary(i)).collect();
                    let total = list.len() as u64;
                    write_plist(
                        &mut stream,
                        &dict! { "CurrentAmount" => total, "CurrentIndex" => 0u64, "CurrentList" => list, "Status" => "BrowsingApplications", "Total" => total },
                    )
                    .await?;
                    write_plist(&mut stream, &dict! { "Status" => "Complete" }).await?;
                }
            }
            "Install" | "Upgrade" => {
                let package = get_str(&request, "PackagePath").unwrap_or("").to_string();
                install(&iphone, &mut stream, &package).await?;
            }
            "Uninstall" => {
                let id = get_str(&request, "ApplicationIdentifier").unwrap_or("").to_string();
                let removed = iphone.state().apps.remove(&id).is_some();
                iphone.note(format!("installation_proxy: uninstall {id}: {removed}"));
                if removed {
                    write_plist(&mut stream, &dict! { "Status" => "Complete" }).await?;
                } else {
                    write_plist(&mut stream, &dict! { "Error" => "APIInternalError", "ErrorDescription" => format!("{id} is not installed") }).await?;
                }
            }
            other => {
                write_plist(&mut stream, &dict! { "Error" => "UnknownCommand", "ErrorDescription" => format!("Unknown command {other}") }).await?;
            }
        }
    }
}

fn listing(app: &InstalledApp) -> plist::Dictionary {
    let mut info = app.info.clone();
    info.insert("ApplicationType".into(), "User".into());
    info.insert(
        "Path".into(),
        format!("/private/var/containers/Bundle/Application/{}/App.app", app.bundle_id).into(),
    );
    info
}

async fn progress<S: Stream>(iphone: &FakeIphone, stream: &mut S, percent: u64, status: &str) -> io::Result<()> {
    let delay = iphone.state().install_delay;
    if !delay.is_zero() {
        tokio::time::sleep(delay).await;
    }
    write_plist(stream, &dict! { "PercentComplete" => percent, "Status" => status }).await
}

async fn fail<S: Stream>(iphone: &FakeIphone, stream: &mut S, error: String, description: String) -> io::Result<()> {
    iphone.note(format!("installation_proxy: refused: {error}: {description}"));
    write_plist(stream, &dict! { "Error" => error, "ErrorDescription" => description }).await
}

async fn install<S: Stream>(iphone: &FakeIphone, stream: &mut S, package: &str) -> io::Result<()> {
    iphone.note(format!("installation_proxy: install {package}"));
    for (percent, status) in [(5, "CreatingStagingDirectory"), (15, "ExtractingPackage"), (20, "InspectingPackage")] {
        progress(iphone, stream, percent, status).await?;
    }
    let injected = iphone.state().fail_install.take();
    if let Some((error, description)) = injected {
        return fail(iphone, stream, error, description).await;
    }
    let files = iphone.state().media.files_under(package);
    let udid = iphone.udid().to_string();
    let verified = match verify::verify_app(&files, &udid) {
        Ok(v) => v,
        Err(why) => {
            return fail(
                iphone,
                stream,
                "ApplicationVerificationFailed".into(),
                format!("Failed to verify code signature of {package} : 0xe8008001 ({why})"),
            )
            .await;
        }
    };
    let bundle_id = verified.bundle_id.clone();
    let over_limit = {
        let state = iphone.state();
        let others: Vec<String> = state
            .apps
            .values()
            .filter(|a| a.signature.free_profile && a.bundle_id != bundle_id)
            .map(|a| a.bundle_id.clone())
            .collect();
        (verified.free_profile && others.len() >= state.free_app_limit).then(|| {
            let list = others.iter().map(|id| format!("    \"{id}\"")).collect::<Vec<_>>().join(",\n");
            format!("{MAX_FREE_APPS}: {{(\n{list}\n)}}")
        })
    };
    if let Some(description) = over_limit {
        return fail(iphone, stream, "ApplicationVerificationFailed".into(), description).await;
    }
    for (percent, status) in [(30, "PreflightingApplication"), (40, "VerifyingApplication"), (60, "CreatingContainer"), (90, "InstallingApplication")] {
        progress(iphone, stream, percent, status).await?;
    }
    {
        let mut state = iphone.state();
        let container = state
            .apps
            .remove(&bundle_id)
            .map(|old| old.container)
            .unwrap_or_else(|| {
                let mut fs = MemFs::default();
                for dir in ["Documents", "Library", "tmp"] {
                    fs.mkdir_p(dir).expect("container");
                }
                fs
            });
        state.apps.insert(
            bundle_id.clone(),
            InstalledApp {
                bundle_id: bundle_id.clone(),
                info: verified.info.clone(),
                files,
                container,
                signature: verified,
            },
        );
        let _ = state.media.remove(package, true);
    }
    iphone.note(format!("installation_proxy: installed {bundle_id}"));
    write_plist(stream, &dict! { "PercentComplete" => 100u64, "Status" => "Complete" }).await
}

pub async fn serve_house_arrest(iphone: FakeIphone, mut stream: TcpStream) -> io::Result<()> {
    let Some(request) = read_plist(&mut stream).await? else {
        return Ok(());
    };
    let command = get_str(&request, "Command").unwrap_or("").to_string();
    let id = get_str(&request, "Identifier").unwrap_or("").to_string();
    let found = iphone.state().apps.get(&id).map(|a| {
        a.info
            .get("UIFileSharingEnabled")
            .and_then(|v| v.as_boolean())
            .unwrap_or(false)
    });
    let error = match (command.as_str(), found) {
        (_, None) => Some("ApplicationLookupFailed"),
        ("VendDocuments", Some(false)) => Some("InstallationLookupFailed"),
        ("VendDocuments", Some(true)) => None,
        // VendContainer needs a development app; Cartouche's container is
        // not what the installer opens.
        _ => Some("InstallationLookupFailed"),
    };
    if let Some(error) = error {
        iphone.note(format!("house_arrest: {command} {id}: {error}"));
        return write_plist(&mut stream, &dict! { "Error" => error }).await;
    }
    iphone.note(format!("house_arrest: {command} {id}"));
    write_plist(&mut stream, &dict! { "Status" => "Complete" }).await?;
    afc::serve(iphone, stream, afc::Root::Documents(id)).await
}
