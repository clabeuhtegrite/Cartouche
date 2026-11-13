//! GrandSlam: the URL bag, SRP sign-in, the second factor, app tokens and
//! anisette provisioning.

use aes::cipher::{block_padding::Pkcs7, consts::U16};
use aes_gcm::{AeadInOut, AesGcm, KeyInit, Nonce};
use base64::{Engine, prelude::BASE64_STANDARD};
use cbc::cipher::{BlockModeEncrypt, KeyIvInit};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use srp::groups::G2048;

use super::{Failure, FakeApple, cpim_for, machine_id, random_bytes, random_id};
use crate::{
    dict,
    http::{Request, Response},
    wire::get_str,
};

const GS: &str = "https://gsa.apple.com/grandslam/GsService2";

#[derive(Debug)]
pub(super) struct PendingLogin {
    email: String,
    b: Vec<u8>,
    a_pub: Vec<u8>,
}

pub(super) fn handle(apple: &FakeApple, request: &Request, path: &str) -> Response {
    match (request.method.as_str(), path) {
        ("GET", "/grandslam/GsService2/lookup") => url_bag(),
        ("POST", "/grandslam/GsService2") => gs_service(apple, request),
        ("GET", "/grandslam/GsService2/lookup/v2/trusteddevice") => send_device_code(apple, request),
        ("GET", "/grandslam/GsService2/validate") => validate_code(apple, request),
        ("POST", "/grandslam/MidService/startMachineProvisioning") => start_provisioning(apple, request),
        ("POST", "/grandslam/MidService/finishMachineProvisioning") => finish_provisioning(apple, request),
        ("GET", "/auth") => trusted_numbers(apple, request),
        ("PUT", "/auth/verify/phone") => send_sms(apple, request),
        ("POST", "/auth/verify/phone/securitycode") => verify_sms(apple, request),
        (method, path) => Response::text(404, &format!("GrandSlam has no {method} {path}")),
    }
}

fn url_bag() -> Response {
    let urls = dict! {
        "gsService" => GS,
        "trustedDeviceSecondaryAuth" => format!("{GS}/lookup/v2/trusteddevice"),
        "secondaryAuth" => "https://gsa.apple.com/auth",
        "validateCode" => format!("{GS}/validate"),
        "midStartProvisioning" => "https://gsa.apple.com/grandslam/MidService/startMachineProvisioning",
        "midFinishProvisioning" => "https://gsa.apple.com/grandslam/MidService/finishMachineProvisioning"
    };
    Response::plist(&dict! { "urls" => urls })
}

fn status(ec: i64, em: &str) -> plist::Dictionary {
    dict! { "ec" => ec, "em" => em }
}

fn wrap(response: plist::Dictionary) -> Response {
    Response::plist(&dict! { "Response" => response })
}

fn error(ec: i64, em: &str) -> Response {
    wrap(dict! { "Status" => status(ec, em) })
}

fn failure_response(failure: Failure) -> Response {
    match failure {
        Failure::Http(code) => Response::text(code, "fake failure"),
        Failure::Auth(ec, em) | Failure::Developer(ec, em) => error(ec, &em),
    }
}

const WRONG_PASSWORD: (i64, &str) = (-22406, "Your Apple Account or password was entered incorrectly.");

fn gs_service(apple: &FakeApple, request: &Request) -> Response {
    let Ok(body) = plist::from_bytes::<plist::Dictionary>(&request.body) else {
        return Response::text(400, "not a plist");
    };
    let Some(req) = body.get("Request").and_then(|v| v.as_dictionary()).cloned() else {
        return Response::text(400, "no Request");
    };
    let op = get_str(&req, "o").unwrap_or("").to_string();
    // Out of the lock first: note() takes it again.

    let failure = apple.state().failure(&op);

    if let Some(failure) = failure {
        apple.note(format!("GrandSlam {op}: injected {failure:?}"));
        return failure_response(failure);
    }
    let machine = req
        .get("cpd")
        .and_then(|v| v.as_dictionary())
        .and_then(|cpd| get_str(cpd, "X-Apple-I-MD-M"))
        .unwrap_or("")
        .to_string();
    if !apple.state().machines.contains(&machine) {
        apple.note(format!("GrandSlam {op}: anisette of an unknown machine"));
        return error(-22421, "This action could not be completed. Try again.");
    }
    match op.as_str() {
        "init" => init(apple, &req),
        "complete" => complete(apple, &req, &machine),
        "apptokens" => app_tokens(apple, &req),
        other => error(-1, &format!("unknown operation {other}")),
    }
}

fn init(apple: &FakeApple, req: &plist::Dictionary) -> Response {
    let email = get_str(req, "u").unwrap_or("").to_lowercase();
    let a_pub = req.get("A2k").and_then(|v| v.as_data()).unwrap_or(&[]).to_vec();
    let protocols: Vec<String> = req
        .get("ps")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_string().map(str::to_string)).collect())
        .unwrap_or_default();
    let mut state = apple.state();
    let Some(account) = state.accounts.get(&email) else {
        drop(state);
        apple.note(format!("sign-in init: no account {email}"));
        return error(WRONG_PASSWORD.0, WRONG_PASSWORD.1);
    };
    if !protocols.iter().any(|p| p == account.config.protocol) {
        return error(-22401, "Unsupported protocol");
    }
    let b = random_bytes(32);
    let b_pub = srp::Server::<G2048, Sha256>::new().compute_public_ephemeral(&b, &account.verifier);
    let response = dict! {
        "Status" => status(0, ""),
        "s" => plist::Value::Data(account.salt.clone()),
        "B" => plist::Value::Data(b_pub),
        "i" => account.iterations as u64,
        "c" => format!("c-{}", random_id(24)),
        "sp" => account.config.protocol
    };
    let c = get_str(&response, "c").unwrap_or("").to_string();
    state.pending.insert(c, PendingLogin { email: email.clone(), b, a_pub });
    drop(state);
    apple.note(format!("sign-in init: {email}"));
    wrap(response)
}

fn session_key(key: &[u8], name: &str) -> Vec<u8> {
    <Hmac<Sha256> as KeyInit>::new_from_slice(key)
        .expect("hmac")
        .chain_update(name.as_bytes())
        .finalize()
        .into_bytes()
        .to_vec()
}

fn complete(apple: &FakeApple, req: &plist::Dictionary, machine: &str) -> Response {
    let c = get_str(req, "c").unwrap_or("").to_string();
    let m1 = req.get("M1").and_then(|v| v.as_data()).unwrap_or(&[]).to_vec();
    let mut state = apple.state();
    let Some(pending) = state.pending.remove(&c) else {
        return error(-22406, "Your session has expired.");
    };
    let Some(account) = state.accounts.get_mut(&pending.email) else {
        return error(WRONG_PASSWORD.0, WRONG_PASSWORD.1);
    };
    let server = srp::Server::<G2048, Sha256>::new();
    let verified = server
        .process_reply(pending.email.as_bytes(), &account.salt, &pending.b, &account.verifier, &pending.a_pub)
        .ok()
        .filter(|v| v.verify_client(&m1).is_ok());
    let Some(verified) = verified else {
        account.failed_logins += 1;
        drop(state);
        apple.note(format!("sign-in: wrong password for {}", pending.email));
        return error(WRONG_PASSWORD.0, WRONG_PASSWORD.1);
    };
    if account.config.locked {
        drop(state);
        apple.note(format!("sign-in: {} is locked", pending.email));
        return error(
            -20209,
            "This Apple Account has been locked for security reasons. Visit iForgot to reset your account (https://iforgot.apple.com).",
        );
    }
    let spd = dict! {
        "adsid" => account.adsid.clone(),
        "GsIdmsToken" => account.idms_token.clone(),
        "sk" => plist::Value::Data(account.sk.clone()),
        "c" => plist::Value::Data(account.c.clone()),
        "fn" => account.config.first_name.clone(),
        "ln" => account.config.last_name.clone(),
        "acname" => account.config.email.clone(),
        "DsPrsId" => 1234567890u64,
        "t" => dict! { "com.apple.gs.idms.pet" => dict! { "token" => random_id(32), "duration" => 300u64 } }
    };
    let key = session_key(verified.key(), "extra data key:");
    let iv = session_key(verified.key(), "extra data iv:");
    let sealed = cbc::Encryptor::<aes::Aes256>::new_from_slices(&key, &iv[..16])
        .expect("cbc")
        .encrypt_padded_vec::<Pkcs7>(&crate::wire::xml(&spd));
    let mut st = status(0, "");
    let second_factor = match account.config.two_factor {
        super::TwoFactor::Off => None,
        _ if account.trusted_machines.contains(machine) => None,
        super::TwoFactor::TrustedDevice => Some("trustedDeviceSecondaryAuth"),
        super::TwoFactor::Sms => Some("secondaryAuth"),
    };
    match second_factor {
        Some(au) => {
            st.insert("au".into(), au.into());
            st.insert("hsc".into(), 409u64.into());
        }
        None => {
            st.insert("hsc".into(), 200u64.into());
        }
    }
    account.failed_logins = 0;
    let email = pending.email.clone();
    drop(state);
    apple.note(format!("sign-in: {email} {}", second_factor.unwrap_or("signed in")));
    wrap(dict! {
        "Status" => st,
        "M2" => plist::Value::Data(verified.proof().to_vec()),
        "spd" => plist::Value::Data(sealed)
    })
}

fn app_tokens(apple: &FakeApple, req: &plist::Dictionary) -> Response {
    let adsid = get_str(req, "u").unwrap_or("").to_string();
    let token = get_str(req, "t").unwrap_or("").to_string();
    let checksum = req.get("checksum").and_then(|v| v.as_data()).unwrap_or(&[]).to_vec();
    let apps: Vec<String> = req
        .get("app")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_string().map(str::to_string)).collect())
        .unwrap_or_default();
    let mut state = apple.state();
    let Some(account) = state.account_by_adsid(&adsid) else {
        return error(-22406, "Unknown account");
    };
    if token != account.idms_token {
        return error(-22406, "Your session has expired.");
    }
    let Some(app) = apps.first().cloned() else {
        return error(-1, "no app");
    };
    let expected = <Hmac<Sha256> as KeyInit>::new_from_slice(&account.sk)
        .expect("hmac")
        .chain_update(b"apptokens")
        .chain_update(adsid.as_bytes())
        .chain_update(app.as_bytes())
        .finalize()
        .into_bytes()
        .to_vec();
    if checksum != expected {
        return error(-22406, "Bad checksum");
    }
    let xcode = format!("xcode-{}", random_id(40));
    account.xcode_tokens.insert(xcode.clone());
    let expiry_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
        + 365 * 24 * 3600 * 1000;
    let mut tokens = plist::Dictionary::new();
    tokens.insert(app.clone(), plist::Value::Dictionary(dict! { "token" => xcode, "duration" => 31536000u64, "expiry" => expiry_ms }));
    let sealed_plist = crate::wire::xml(&dict! { "status-code" => 200u64, "t" => tokens });
    let iv = random_bytes(16);
    let key = aes_gcm::Key::<AesGcm<aes::Aes256, U16>>::try_from(account.sk.as_slice()).expect("key");
    let cipher = AesGcm::<aes::Aes256, U16>::new(&key);
    let nonce = Nonce::<U16>::try_from(iv.as_slice()).expect("nonce");
    let mut buf = sealed_plist;
    cipher.encrypt_in_place(&nonce, b"XYZ", &mut buf).expect("gcm");
    let mut et = b"XYZ".to_vec();
    et.extend_from_slice(&iv);
    et.extend_from_slice(&buf);
    drop(state);
    apple.note(format!("app token: {app}"));
    wrap(dict! { "Status" => status(0, ""), "et" => plist::Value::Data(et) })
}

/// The account and anisette machine of a two-factor request, from its
/// X-Apple-Identity-Token and X-Apple-I-MD-M.
fn identity(request: &Request) -> Option<(String, String, String)> {
    let token = BASE64_STANDARD.decode(request.header("x-apple-identity-token")?).ok()?;
    let token = String::from_utf8(token).ok()?;
    let (adsid, idms) = token.split_once(':')?;
    let machine = request.header("x-apple-i-md-m")?.to_string();
    Some((adsid.to_string(), idms.to_string(), machine))
}

fn send_device_code(apple: &FakeApple, request: &Request) -> Response {
    // Out of the lock first: note() takes it again.

    let failure = apple.state().failure("trusteddevice");

    if let Some(failure) = failure {
        return failure_response(failure);
    }
    let Some((adsid, idms, machine)) = identity(request) else {
        return Response::text(401, "no identity");
    };
    let mut state = apple.state();
    let Some(account) = state.account_by_adsid(&adsid).filter(|a| a.idms_token == idms) else {
        return Response::text(401, "unknown identity");
    };
    account.code_sent.insert(machine);
    let email = account.config.email.clone();
    drop(state);
    apple.note(format!("two-factor: code shown on {email}'s devices"));
    Response::new(200, "text/html", b"<html></html>".to_vec())
}

fn validate_code(apple: &FakeApple, request: &Request) -> Response {
    // Out of the lock first: note() takes it again.

    let failure = apple.state().failure("validate");

    if let Some(failure) = failure {
        return failure_response(failure);
    }
    let Some((adsid, idms, machine)) = identity(request) else {
        return Response::text(401, "no identity");
    };
    let code = request.header("security-code").unwrap_or("").to_string();
    let mut state = apple.state();
    let Some(account) = state.account_by_adsid(&adsid).filter(|a| a.idms_token == idms) else {
        return Response::text(401, "unknown identity");
    };
    let email = account.config.email.clone();
    if !account.code_sent.contains(&machine) || code != account.config.code {
        drop(state);
        apple.note(format!("two-factor: wrong code {code:?} for {email}"));
        return Response::plist(&dict! { "Status" => status(-21669, "Incorrect verification code.") });
    }
    account.trusted_machines.insert(machine);
    drop(state);
    apple.note(format!("two-factor: {email} verified"));
    Response::plist(&dict! { "Status" => status(0, "") })
}

fn trusted_numbers(apple: &FakeApple, request: &Request) -> Response {
    let Some((adsid, _, _)) = identity(request) else {
        return Response::text(401, "no identity");
    };
    if apple.state().account_by_adsid(&adsid).is_none() {
        return Response::text(401, "unknown identity");
    }
    Response::json(&serde_json::json!({
        "trustedPhoneNumbers": [{
            "numberWithDialCode": "+33 •• •• •• •• 42",
            "lastTwoDigits": "42",
            "pushMode": "sms",
            "id": 1
        }]
    }))
}

fn send_sms(apple: &FakeApple, request: &Request) -> Response {
    let Some((adsid, _, machine)) = identity(request) else {
        return Response::text(401, "no identity");
    };
    let mut state = apple.state();
    let Some(account) = state.account_by_adsid(&adsid) else {
        return Response::text(401, "unknown identity");
    };
    account.code_sent.insert(machine);
    let email = account.config.email.clone();
    drop(state);
    apple.note(format!("two-factor: text message sent for {email}"));
    Response::json(&serde_json::json!({}))
}

fn verify_sms(apple: &FakeApple, request: &Request) -> Response {
    let Some((adsid, _, machine)) = identity(request) else {
        return Response::text(401, "no identity");
    };
    let body: serde_json::Value = serde_json::from_slice(&request.body).unwrap_or_default();
    let code = body["securityCode"]["code"].as_str().unwrap_or("").to_string();
    let mut state = apple.state();
    let Some(account) = state.account_by_adsid(&adsid) else {
        return Response::text(401, "unknown identity");
    };
    let email = account.config.email.clone();
    if !account.code_sent.contains(&machine) || code != account.config.code {
        drop(state);
        apple.note(format!("two-factor: wrong text message code {code:?} for {email}"));
        return Response::json(&serde_json::json!({
            "serviceErrors": [{"code": "-21669", "title": "Incorrect verification code", "message": "Please try again."}]
        }))
        .with_status(400);
    }
    account.trusted_machines.insert(machine);
    drop(state);
    apple.note(format!("two-factor: {email} verified by text message"));
    Response::json(&serde_json::json!({}))
}

fn start_provisioning(apple: &FakeApple, request: &Request) -> Response {
    if request.header("x-mme-device-id").is_none() || request.header("x-apple-i-md-lu").is_none() {
        return error(-45001, "Missing device headers");
    }
    let spim = BASE64_STANDARD.encode(random_bytes(32));
    apple.state().spims.insert(spim.clone());
    apple.note("anisette: provisioning started");
    wrap(dict! { "Status" => status(0, ""), "spim" => spim })
}

fn finish_provisioning(apple: &FakeApple, request: &Request) -> Response {
    let cpim = plist::from_bytes::<plist::Dictionary>(&request.body)
        .ok()
        .and_then(|b| b.get("Request").and_then(|v| v.as_dictionary()).cloned())
        .and_then(|r| get_str(&r, "cpim").map(str::to_string))
        .unwrap_or_default();
    let mut state = apple.state();
    let Some(spim) = state.spims.iter().find(|s| cpim_for(s) == cpim).cloned() else {
        return error(-45061, "Provisioning failed");
    };
    state.spims.remove(&spim);
    let tk = BASE64_STANDARD.encode(random_bytes(32));
    state.machines.insert(machine_id(&tk));
    drop(state);
    apple.note("anisette: machine provisioned");
    wrap(dict! {
        "Status" => status(0, ""),
        "ptm" => BASE64_STANDARD.encode(random_bytes(64)),
        "tk" => tk
    })
}
