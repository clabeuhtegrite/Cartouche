//! The developer services, QH65B2 and the v1 API, for a free team.

use std::time::{Duration, SystemTime};

use super::{AppGroup, AppId, Certificate, Device, Failure, FakeApple, random_id};
use crate::{
    dict,
    http::{Request, Response},
    wire::get_str,
};

const WEEK: Duration = Duration::from_secs(7 * 24 * 3600);

pub(super) fn handle(apple: &FakeApple, request: &Request, path: &str, query: &str) -> Response {
    if let Some(id) = path.strip_prefix("/services/v1/bundleIds/") {
        return bundle_id_capability(apple, request, id);
    }
    let Some(action) = path
        .strip_prefix("/services/QH65B2/")
        .and_then(|a| a.strip_suffix(".action"))
    else {
        return Response::text(404, &format!("no developer service at {path}"));
    };
    if !query.contains("clientId=XABBG36SBA") {
        return Response::text(400, "no clientId");
    }
    let action = action.strip_prefix("ios/").unwrap_or(action).to_string();
    let Ok(body) = plist::from_bytes::<plist::Dictionary>(&request.body) else {
        return Response::text(400, "not a plist");
    };
    if get_str(&body, "protocolVersion") != Some("QH65B2") || get_str(&body, "clientId") != Some("XABBG36SBA") {
        return result(&body, 1, "Invalid protocol", plist::Dictionary::new());
    }
    // Out of the lock first: note() takes it again.

    let failure = apple.state().failure(&action);

    if let Some(failure) = failure {
        apple.note(format!("developer {action}: injected {failure:?}"));
        return match failure {
            Failure::Http(code) => Response::text(code, "fake failure"),
            Failure::Auth(code, text) | Failure::Developer(code, text) => {
                result(&body, code, &text, plist::Dictionary::new())
            }
        };
    }
    let machine = request.header("x-apple-i-md-m").unwrap_or("").to_string();
    if !apple.state().machines.contains(&machine) {
        return Response::text(401, "anisette of an unknown machine");
    }
    let (Some(token), Some(adsid)) = (request.header("x-apple-gs-token"), request.header("x-apple-i-identity-id")) else {
        return result(&body, 1100, "Your session has expired. Please log in.", plist::Dictionary::new());
    };
    let mut state = apple.state();
    let Some(email) = state
        .accounts
        .values()
        .find(|a| a.adsid == adsid && a.xcode_tokens.contains(token))
        .map(|a| a.config.email.clone())
    else {
        return result(&body, 1100, "Your session has expired. Please log in.", plist::Dictionary::new());
    };
    // App IDs are unique across all teams: another team's is taken.
    let taken: std::collections::BTreeSet<String> = state
        .accounts
        .values()
        .filter(|a| a.config.email != email)
        .flat_map(|a| a.team.app_ids.iter().map(|x| x.identifier.clone()))
        .collect();
    let account = state.accounts.get_mut(&email).expect("account");
    if account.config.underage {
        return result(
            &body,
            1102,
            "This Apple Account cannot be used with the Apple Developer Program: its holder is under 18.",
            plist::Dictionary::new(),
        );
    }
    let team_id = account.team.team_id.clone();
    if action != "listTeams" && get_str(&body, "teamId") != Some(team_id.as_str()) {
        return result(&body, 1101, "You are not a member of this team.", plist::Dictionary::new());
    }
    let holder = format!("{} {}", account.config.first_name, account.config.last_name);
    let team = &mut account.team;
    let answer: Result<plist::Dictionary, (i64, String)> = match action.as_str() {
        "listTeams" => Ok(dict! { "teams" => vec![plist::Value::Dictionary(dict! {
            "name" => team.name.clone(),
            "teamId" => team.team_id.clone(),
            "type" => "Individual",
            "status" => "active",
            "memberships" => vec![plist::Value::Dictionary(dict! {
                "name" => "Free Developer Program", "platform" => "ios", "status" => "active"
            })],
            "currentTeamMember" => dict! { "roles" => vec![plist::Value::from("TEAM_ADMIN")] }
        })] }),
        "listDevices" => Ok(dict! { "devices" => team.devices.iter().map(device).collect::<Vec<_>>() }),
        "addDevice" => {
            let name = get_str(&body, "name").unwrap_or("").to_string();
            let udid = get_str(&body, "deviceNumber").unwrap_or("").to_string();
            if udid.len() < 24 {
                Err((35, format!("An invalid value '{udid}' was provided for the parameter 'deviceNumber'.")))
            } else if team.devices.iter().any(|d| d.udid == udid) {
                Err((35, format!("A device with number '{udid}' already exists on this team.")))
            } else {
                let d = Device { device_id: random_id(10), name, udid };
                team.devices.push(d.clone());
                Ok(dict! { "device" => device(&d) })
            }
        }
        "listAllDevelopmentCerts" => Ok(dict! {
            "certificates" => team.certificates.iter().map(certificate).collect::<Vec<_>>()
        }),
        "submitDevelopmentCSR" => {
            let csr = get_str(&body, "csrContent").unwrap_or("").to_string();
            let machine_name = get_str(&body, "machineName").unwrap_or("").to_string();
            let machine_id = get_str(&body, "machineId").unwrap_or("").to_string();
            if team.certificates.len() >= team.max_certificates {
                Err((
                    7460,
                    "You already have a current iOS Development certificate or a pending certificate request.".into(),
                ))
            } else if machine_id.is_empty() || machine_name.is_empty() {
                Err((35, "The machine is missing.".into()))
            } else {
                match apple.0.ca.issue_development(&csr, &team.team_id, &holder) {
                    Err(e) => Err((7254, e)),
                    Ok(issued) => {
                        let cert = Certificate {
                            id: random_id(10),
                            serial: issued.serial,
                            machine_id,
                            machine_name,
                            der: issued.der,
                            expires: SystemTime::now() + Duration::from_secs(365 * 24 * 3600),
                        };
                        team.certificates.push(cert.clone());
                        Ok(dict! { "certRequest" => dict! {
                            "certRequestId" => cert.id.clone(),
                            "name" => format!("Apple Development: {holder}"),
                            "statusString" => "Issued",
                            "statusCode" => 1u64,
                            "csrPlatform" => "ios",
                            "machineName" => cert.machine_name.clone(),
                            "machineId" => cert.machine_id.clone()
                        } })
                    }
                }
            }
        }
        "revokeDevelopmentCert" => {
            let serial = get_str(&body, "serialNumber").unwrap_or("").to_string();
            match team.certificates.iter().position(|c| c.serial == serial) {
                None => Err((7252, format!("No certificate with serial number {serial}."))),
                Some(at) => {
                    let cert = team.certificates.remove(at);
                    Ok(dict! { "certRequests" => vec![plist::Value::Dictionary(dict! {
                        "certRequestId" => cert.id, "statusString" => "Revoked"
                    })] })
                }
            }
        }
        "listAppIds" => Ok(dict! {
            "appIds" => team.app_ids.iter().map(app_id).collect::<Vec<_>>(),
            "maxQuantity" => 10u64,
            "availableQuantity" => team.available_app_ids
        }),
        "addAppId" => {
            let identifier = get_str(&body, "identifier").unwrap_or("").to_string();
            let name = get_str(&body, "name").unwrap_or("").to_string();
            let taken_elsewhere = taken.contains(&identifier);
            if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == ' ') {
                Err((35, format!("An invalid value '{name}' was provided for the parameter 'appIdName'.")))
            } else if taken_elsewhere {
                Err((9401, format!("An App ID with Identifier '{identifier}' is not available. Please enter a different string.")))
            } else if team.app_ids.iter().any(|a| a.identifier == identifier) {
                Err((9401, format!("An App ID with Identifier '{identifier}' already exists on this team.")))
            } else if team.available_app_ids <= 0 {
                Err((9401, "You have reached the maximum number of App IDs for this week.".into()))
            } else {
                team.available_app_ids -= 1;
                let a = AppId {
                    app_id_id: random_id(10),
                    identifier,
                    name,
                    features: dict! {
                        "APG3427HIY" => false,
                        "SKC3T5S89Y" => false,
                        "push" => false,
                        "iad53f84" => false
                    },
                    groups: Vec::new(),
                    increased_memory_limit: false,
                    expires: SystemTime::now() + WEEK,
                };
                team.app_ids.push(a.clone());
                Ok(dict! { "appId" => app_id(&a) })
            }
        }
        "updateAppId" => {
            let id = get_str(&body, "appIdId").unwrap_or("").to_string();
            match team.app_ids.iter_mut().find(|a| a.app_id_id == id) {
                None => Err((9100, format!("No App ID {id}."))),
                Some(a) => {
                    for (key, value) in body.iter() {
                        if a.features.contains_key(key) || key == "APG3427HIY" {
                            a.features.insert(key.clone(), value.clone());
                        }
                    }
                    Ok(dict! { "appId" => app_id(a) })
                }
            }
        }
        "deleteAppId" => {
            let id = get_str(&body, "appIdId").unwrap_or("").to_string();
            match team.app_ids.iter().position(|a| a.app_id_id == id) {
                None => Err((9100, format!("No App ID {id}."))),
                Some(at) => {
                    team.app_ids.remove(at);
                    Ok(plist::Dictionary::new())
                }
            }
        }
        "listApplicationGroups" => Ok(dict! {
            "applicationGroupList" => team.groups.iter().map(|g| group(g, &team_id)).collect::<Vec<_>>()
        }),
        "addApplicationGroup" => {
            let identifier = get_str(&body, "identifier").unwrap_or("").to_string();
            let name = get_str(&body, "name").unwrap_or("").to_string();
            if !identifier.starts_with("group.") {
                Err((35, format!("An invalid value '{identifier}' was provided for the parameter 'identifier'.")))
            } else if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == ' ') {
                Err((35, format!("An invalid value '{name}' was provided for the parameter 'name'.")))
            } else if team.groups.iter().any(|g| g.identifier == identifier) {
                Err((35, format!("An App Group with Identifier '{identifier}' already exists.")))
            } else {
                let g = AppGroup { id: random_id(10), identifier, name };
                team.groups.push(g.clone());
                Ok(dict! { "applicationGroup" => group(&g, &team_id) })
            }
        }
        "assignApplicationGroupToAppId" => {
            let id = get_str(&body, "appIdId").unwrap_or("").to_string();
            let group_id = get_str(&body, "applicationGroups").unwrap_or("").to_string();
            let identifier = team.groups.iter().find(|g| g.id == group_id).map(|g| g.identifier.clone());
            match (team.app_ids.iter_mut().find(|a| a.app_id_id == id), identifier) {
                (None, _) => Err((9100, format!("No App ID {id}."))),
                (_, None) => Err((35, format!("No App Group {group_id}."))),
                (Some(a), Some(identifier)) => {
                    if a.features.get("APG3427HIY").and_then(|v| v.as_boolean()) != Some(true) {
                        Err((35, "App Groups is not enabled on this App ID.".into()))
                    } else {
                        if !a.groups.contains(&identifier) {
                            a.groups.push(identifier);
                        }
                        Ok(plist::Dictionary::new())
                    }
                }
            }
        }
        "downloadTeamProvisioningProfile" => {
            let id = get_str(&body, "appIdId").unwrap_or("").to_string();
            match team.app_ids.iter().find(|a| a.app_id_id == id).cloned() {
                None => Err((9100, format!("No App ID {id}."))),
                Some(a) if team.devices.is_empty() => {
                    Err((8100, format!("No devices are registered for {}. Register a device first.", a.identifier)))
                }
                Some(a) => Ok(dict! { "provisioningProfile" => profile(apple, team, &a, &holder) }),
            }
        }
        other => Err((9999, format!("The fake developer services have no {other}."))),
    };
    drop(state);
    match answer {
        Ok(fields) => {
            apple.note(format!("developer {action}"));
            result(&body, 0, "", fields)
        }
        Err((code, text)) => {
            apple.note(format!("developer {action}: {code} {text}"));
            result(&body, code, &text, plist::Dictionary::new())
        }
    }
}

fn result(body: &plist::Dictionary, code: i64, text: &str, fields: plist::Dictionary) -> Response {
    let mut d = dict! {
        "resultCode" => code,
        "protocolVersion" => "QH65B2",
        "requestId" => get_str(body, "requestId").unwrap_or("").to_string(),
        "userLocale" => "en_US",
        "creationTimestamp" => plist::Value::Date(SystemTime::now().into()),
        "responseId" => uuid::Uuid::new_v4().to_string()
    };
    if code != 0 {
        d.insert("resultString".into(), text.into());
        d.insert("userString".into(), text.into());
    }
    for (k, v) in fields {
        d.insert(k, v);
    }
    Response::plist(&d)
}

fn device(d: &Device) -> plist::Value {
    plist::Value::Dictionary(dict! {
        "name" => d.name.clone(),
        "deviceId" => d.device_id.clone(),
        "deviceNumber" => d.udid.clone(),
        "devicePlatform" => "ios",
        "deviceClass" => "iphone",
        "status" => "c"
    })
}

fn certificate(c: &Certificate) -> plist::Value {
    plist::Value::Dictionary(dict! {
        "name" => format!("Apple Development: {}", c.machine_name),
        "certificateId" => c.id.clone(),
        "serialNumber" => c.serial.clone(),
        "machineId" => c.machine_id.clone(),
        "machineName" => c.machine_name.clone(),
        "certContent" => plist::Value::Data(c.der.clone()),
        "certificatePlatform" => "ios",
        "certificateType" => dict! {
            "certificateTypeDisplayId" => "83Q87W3TGH",
            "name" => "Apple Development",
            "platform" => "ios",
            "permissionType" => "development"
        },
        "status" => "Issued",
        "statusCode" => 0u64,
        "expirationDate" => plist::Value::Date(c.expires.into())
    })
}

fn app_id(a: &AppId) -> plist::Value {
    plist::Value::Dictionary(dict! {
        "appIdId" => a.app_id_id.clone(),
        "identifier" => a.identifier.clone(),
        "name" => a.name.clone(),
        "features" => a.features.clone(),
        "expirationDate" => plist::Value::Date(a.expires.into())
    })
}

fn group(g: &AppGroup, team_id: &str) -> plist::Value {
    plist::Value::Dictionary(dict! {
        "name" => g.name.clone(),
        "identifier" => g.identifier.clone(),
        "applicationGroup" => g.id.clone(),
        "status" => "current",
        "prefix" => team_id
    })
}

/// A free team's provisioning profile for one App ID: its entitlements, the
/// team's iPhones, and every certificate the team holds.
fn profile(apple: &FakeApple, team: &super::Team, a: &AppId, holder: &str) -> plist::Dictionary {
    let team_id = &team.team_id;
    let mut entitlements = dict! {
        "application-identifier" => format!("{team_id}.{}", a.identifier),
        "com.apple.developer.team-identifier" => team_id.clone(),
        "get-task-allow" => true,
        "keychain-access-groups" => vec![plist::Value::from(format!("{team_id}.*")), plist::Value::from("com.apple.token")]
    };
    if !a.groups.is_empty() {
        entitlements.insert(
            "com.apple.security.application-groups".into(),
            plist::Value::Array(a.groups.iter().cloned().map(plist::Value::from).collect()),
        );
    }
    if a.increased_memory_limit {
        entitlements.insert("com.apple.developer.kernel.increased-memory-limit".into(), true.into());
    }
    let uuid = uuid::Uuid::new_v4().to_string().to_uppercase();
    let expires = SystemTime::now() + WEEK;
    let content = dict! {
        "AppIDName" => a.name.clone(),
        "ApplicationIdentifierPrefix" => vec![plist::Value::from(team_id.clone())],
        "CreationDate" => plist::Value::Date(SystemTime::now().into()),
        "Platform" => vec![plist::Value::from("iOS")],
        "IsXcodeManaged" => true,
        "DeveloperCertificates" => team.certificates.iter().map(|c| plist::Value::Data(c.der.clone())).collect::<Vec<_>>(),
        "Entitlements" => entitlements,
        "ExpirationDate" => plist::Value::Date(expires.into()),
        "Name" => format!("iOS Team Provisioning Profile: {}", a.identifier),
        "ProvisionedDevices" => team.devices.iter().map(|d| plist::Value::from(d.udid.clone())).collect::<Vec<_>>(),
        "LocalProvision" => true,
        "TeamIdentifier" => vec![plist::Value::from(team_id.clone())],
        "TeamName" => holder.to_string(),
        "TimeToLive" => 7u64,
        "UUID" => uuid.clone(),
        "Version" => 1u64
    };
    dict! {
        "encodedProfile" => plist::Value::Data(apple.0.ca.profile(&content)),
        "filename" => format!("iOS_Team_Provisioning_Profile_{}.mobileprovision", a.identifier.replace('.', "")),
        "provisioningProfileId" => random_id(10),
        "name" => format!("iOS Team Provisioning Profile: {}", a.identifier),
        "status" => "Active",
        "type" => "iOS Development",
        "distributionMethod" => "limited",
        "proProPlatform" => "ios",
        "UUID" => uuid,
        "dateExpire" => plist::Value::Date(expires.into()),
        "appIdId" => a.app_id_id.clone(),
        "isTemplateProfile" => false,
        "isTeamProfile" => true,
        "isFreeProvisioningProfile" => true
    }
}

/// PATCH /services/v1/bundleIds/{id}: isideload turns on Increased Memory
/// Limit for each App ID it registers.
fn bundle_id_capability(apple: &FakeApple, request: &Request, id: &str) -> Response {
    // Out of the lock first: note() takes it again.

    let failure = apple.state().failure("bundleIds");

    if let Some(failure) = failure {
        return match failure {
            Failure::Http(code) => Response::text(code, "fake failure"),
            _ => Response::text(409, "fake failure"),
        };
    }
    if request.method != "PATCH" {
        return Response::text(405, "PATCH only");
    }
    if request.header("content-type") != Some("application/vnd.api+json") {
        return Response::text(415, "application/vnd.api+json only");
    }
    let (Some(token), Some(adsid)) = (request.header("x-apple-gs-token"), request.header("x-apple-i-identity-id")) else {
        return Response::text(401, "not signed in");
    };
    let body: serde_json::Value = serde_json::from_slice(&request.body).unwrap_or_default();
    let capabilities: Vec<String> = body["data"]["relationships"]["bundleIdCapabilities"]["data"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|c| c["attributes"]["enabled"].as_bool() == Some(true))
                .filter_map(|c| c["relationships"]["capability"]["data"]["id"].as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    let mut state = apple.state();
    let Some(account) = state
        .accounts
        .values_mut()
        .find(|a| a.adsid == adsid && a.xcode_tokens.contains(token))
    else {
        return Response::text(401, "not signed in");
    };
    let team_id = account.team.team_id.clone();
    let Some(a) = account.team.app_ids.iter_mut().find(|a| a.app_id_id == id) else {
        return Response::text(404, "no such bundle ID");
    };
    if body["data"]["id"].as_str() != Some(id)
        || body["data"]["attributes"]["teamId"].as_str() != Some(team_id.as_str())
        || body["data"]["attributes"]["identifier"].as_str() != Some(a.identifier.as_str())
    {
        return Response::text(409, "the body is not this bundle ID's");
    }
    if capabilities.iter().any(|c| c == "INCREASED_MEMORY_LIMIT") {
        a.increased_memory_limit = true;
    }
    let identifier = a.identifier.clone();
    drop(state);
    apple.note(format!("developer v1: {capabilities:?} on {identifier}"));
    Response::new(200, "application/vnd.api+json", serde_json::json!({"data": {"id": id, "type": "bundleIds"}}).to_string())
}
