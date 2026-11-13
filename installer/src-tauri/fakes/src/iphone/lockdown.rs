//! lockdownd on port 62078: values about the iPhone, a session in TLS for
//! the computer of the pair record, and the services it starts.

use std::io;

use tokio::net::TcpStream;
use tokio_rustls::TlsAcceptor;

use super::{FakeIphone, Service};
use crate::{
    dict,
    wire::{Stream, get_str, read_plist, write_plist},
};

enum Answer {
    Reply(plist::Dictionary),
    /// Reply, then go on in TLS.
    StartTls(plist::Dictionary),
}

pub async fn serve(iphone: FakeIphone, mut stream: TcpStream) -> io::Result<()> {
    loop {
        let Some(request) = read_plist(&mut stream).await? else {
            return Ok(());
        };
        match answer(&iphone, &request, false) {
            Answer::Reply(reply) => write_plist(&mut stream, &reply).await?,
            Answer::StartTls(reply) => {
                write_plist(&mut stream, &reply).await?;
                let acceptor = TlsAcceptor::from(iphone.0.tls.clone());
                let tls = match acceptor.accept(stream).await {
                    Ok(tls) => tls,
                    Err(e) => {
                        iphone.note(format!("lockdown: TLS refused: {e}"));
                        return Err(e);
                    }
                };
                iphone.note("lockdown: session started");
                return session(iphone, tls).await;
            }
        }
    }
}

async fn session<S: Stream>(iphone: FakeIphone, mut stream: S) -> io::Result<()> {
    loop {
        let Some(request) = read_plist(&mut stream).await? else {
            return Ok(());
        };
        match answer(&iphone, &request, true) {
            Answer::Reply(reply) | Answer::StartTls(reply) => write_plist(&mut stream, &reply).await?,
        }
        if get_str(&request, "Request") == Some("StopSession") {
            // lockdownd goes back to plain text after StopSession; nothing
            // the installer does needs it.
            return Ok(());
        }
    }
}

fn error(request: &str, error: &str) -> Answer {
    Answer::Reply(dict! { "Request" => request, "Error" => error })
}

fn answer(iphone: &FakeIphone, request: &plist::Dictionary, in_session: bool) -> Answer {
    let kind = get_str(request, "Request").unwrap_or("").to_string();
    let config = iphone.config().clone();
    match kind.as_str() {
        "QueryType" => Answer::Reply(dict! { "Request" => "QueryType", "Type" => "com.apple.mobile.lockdown" }),
        "GetValue" => {
            let key = get_str(request, "Key");
            let domain = get_str(request, "Domain");
            let value = match (domain, key) {
                (Some("com.apple.mobile.wireless_lockdown"), Some("EnableWifiDebugging")) => {
                    Some(plist::Value::Boolean(iphone.state().wifi_debugging))
                }
                (Some(_), _) => None,
                (None, None) => Some(plist::Value::Dictionary(values(iphone))),
                (None, Some(key)) => values(iphone).get(key).cloned(),
            };
            match value {
                Some(value) => Answer::Reply(dict! {
                    "Request" => "GetValue",
                    "Key" => key.unwrap_or(""),
                    "Value" => value,
                }),
                None => error("GetValue", "MissingValue"),
            }
        }
        "SetValue" => {
            if !in_session {
                return error("SetValue", "SessionInactive");
            }
            let key = get_str(request, "Key");
            let domain = get_str(request, "Domain");
            match (domain, key) {
                (Some("com.apple.mobile.wireless_lockdown"), Some("EnableWifiDebugging")) => {
                    let on = request.get("Value").and_then(|v| v.as_boolean()).unwrap_or(false);
                    iphone.state().wifi_debugging = on;
                    iphone.note(format!("lockdown: Wi-Fi debugging {}", if on { "on" } else { "off" }));
                    Answer::Reply(dict! { "Request" => "SetValue" })
                }
                _ => error("SetValue", "MissingValue"),
            }
        }
        "StartSession" => {
            if in_session {
                return error("StartSession", "SessionActive");
            }
            let host_id = get_str(request, "HostID").unwrap_or("");
            let buid = get_str(request, "SystemBUID").unwrap_or("");
            let keys = &iphone.0.keys;
            if !iphone.state().knows_host || host_id != keys.host_id || buid != keys.system_buid {
                iphone.note(format!("lockdown: unknown host {host_id}"));
                return error("StartSession", "InvalidHostID");
            }
            Answer::StartTls(dict! {
                "Request" => "StartSession",
                "EnableSessionSSL" => true,
                "SessionID" => uuid::Uuid::new_v4().to_string().to_uppercase(),
            })
        }
        "StopSession" => Answer::Reply(dict! { "Request" => "StopSession" }),
        "StartService" => {
            if !in_session {
                return error("StartService", "SessionInactive");
            }
            let name = get_str(request, "Service").unwrap_or("").to_string();
            let service = match name.as_str() {
                "com.apple.afc" => Service::Afc,
                "com.apple.mobile.installation_proxy" => Service::InstallationProxy,
                "com.apple.mobile.house_arrest" => Service::HouseArrest,
                "com.apple.dt.remotepairingdeviced.lockdown" if iphone.has_remote_pairing() => {
                    Service::RemotePairing
                }
                _ => {
                    iphone.note(format!("lockdown: no service {name}"));
                    return error("StartService", "InvalidService");
                }
            };
            let port = iphone.open_service(service);
            iphone.note(format!("lockdown: started {name}"));
            Answer::Reply(dict! { "Request" => "StartService", "Service" => name, "Port" => port as u64 })
        }
        "Pair" | "ValidatePair" | "Unpair" => {
            // The installer never pairs over lockdown: usbmuxd already holds
            // the pair record, and newer iPhones pair remotely.
            error(&kind, "UserDeniedPairing")
        }
        _ => {
            let _ = config;
            error(&kind, "InvalidRequest")
        }
    }
}

fn values(iphone: &FakeIphone) -> plist::Dictionary {
    let c = iphone.config();
    dict! {
        "ActivationState" => "Activated",
        "BuildVersion" => c.build_version.clone(),
        "CPUArchitecture" => "arm64e",
        "DeviceClass" => "iPhone",
        "DeviceColor" => "1",
        "DeviceName" => c.name.clone(),
        "DevicePublicKey" => plist::Value::Data(iphone.0.keys.device_cert_pem.clone().into_bytes()),
        "HardwareModel" => "D93AP",
        "PasswordProtected" => true,
        "ProductName" => "iPhone OS",
        "ProductType" => c.product_type.clone(),
        "ProductVersion" => c.product_version.clone(),
        "SerialNumber" => "F2LZ1234ABCD",
        "TimeZone" => "Europe/Paris",
        "UniqueDeviceID" => c.udid.clone(),
        "WiFiAddress" => c.wifi_mac.clone(),
    }
}
