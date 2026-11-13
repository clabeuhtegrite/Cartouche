//! What iOS checks before it installs an app, as far as a test can: every
//! executable carries a code signature whose code and sealed files match,
//! with the bundle's identifier and team; the profile names this iPhone (or
//! all of them, an enterprise profile), the team, the app and the
//! certificate that signed it; and the executable asks for no entitlement
//! the profile does not grant.

use std::collections::BTreeMap;

use der::{Decode, Encode};
use sha2::{Digest, Sha256};

#[derive(Clone, Debug, Default)]
pub struct VerifiedBundle {
    /// Its folder inside the .app, "" for the app itself.
    pub path: String,
    pub bundle_id: String,
    pub team_id: String,
    pub info: plist::Dictionary,
    pub entitlements: plist::Dictionary,
    pub has_profile: bool,
}

#[derive(Clone, Debug, Default)]
pub struct VerifiedApp {
    pub bundle_id: String,
    pub team_id: String,
    pub info: plist::Dictionary,
    /// The entitlements the app's executable was signed with.
    pub entitlements: plist::Dictionary,
    /// The embedded provisioning profile.
    pub profile: plist::Dictionary,
    /// The certificate that signed the app's executable, in DER.
    pub signer_certificate: Vec<u8>,
    /// Whether the profile comes from a free Apple ID.
    pub free_profile: bool,
    /// The app and every framework and extension in it.
    pub bundles: Vec<VerifiedBundle>,
}

/// A code signature, as read from a Mach-O.
#[derive(Debug)]
pub struct CodeSignature {
    pub identifier: String,
    pub team_id: String,
    pub entitlements: plist::Dictionary,
    /// Hashes of the special slots, by slot number: 1 Info.plist,
    /// 3 CodeResources, 5 entitlements.
    special: BTreeMap<u32, Vec<u8>>,
    pub certificates: Vec<Vec<u8>>,
    pub signer_serial: Option<Vec<u8>>,
}

fn be32(b: &[u8], at: usize) -> Result<u32, String> {
    b.get(at..at + 4)
        .map(|s| u32::from_be_bytes(s.try_into().unwrap()))
        .ok_or_else(|| "truncated signature".to_string())
}

fn le32(b: &[u8], at: usize) -> Result<u32, String> {
    b.get(at..at + 4)
        .map(|s| u32::from_le_bytes(s.try_into().unwrap()))
        .ok_or_else(|| "truncated Mach-O".to_string())
}

fn c_str(b: &[u8], at: usize) -> String {
    let rest = b.get(at..).unwrap_or(&[]);
    let end = rest.iter().position(|c| *c == 0).unwrap_or(rest.len());
    String::from_utf8_lossy(&rest[..end]).into_owned()
}

/// The length of the DER element at the start of `b`.
fn der_len(b: &[u8]) -> Option<usize> {
    let first = *b.get(1)? as usize;
    if first < 0x80 {
        return Some(2 + first);
    }
    let n = first & 0x7f;
    let mut len = 0usize;
    for i in 0..n {
        len = (len << 8) | *b.get(2 + i)? as usize;
    }
    Some(2 + n + len)
}

/// The thin slices of a Mach-O, fat or not.
fn slices(data: &[u8]) -> Result<Vec<&[u8]>, String> {
    let magic_be = be32(data, 0).map_err(|_| "not a Mach-O".to_string())?;
    match magic_be {
        0xcafe_babe | 0xcafe_babf => {
            let n = be32(data, 4)? as usize;
            let wide = magic_be == 0xcafe_babf;
            let entry = if wide { 32 } else { 20 };
            let mut out = Vec::new();
            for i in 0..n {
                let at = 8 + i * entry;
                let (offset, size) = if wide {
                    let o = u64::from_be_bytes(data.get(at + 8..at + 16).ok_or("truncated fat header")?.try_into().unwrap());
                    let s = u64::from_be_bytes(data.get(at + 16..at + 24).ok_or("truncated fat header")?.try_into().unwrap());
                    (o as usize, s as usize)
                } else {
                    (be32(data, at + 8)? as usize, be32(data, at + 12)? as usize)
                };
                out.push(data.get(offset..offset + size).ok_or("fat slice outside the file")?);
            }
            Ok(out)
        }
        _ => {
            let magic = le32(data, 0)?;
            if magic != 0xfeed_facf && magic != 0xfeed_face {
                return Err("not a Mach-O".into());
            }
            Ok(vec![data])
        }
    }
}

/// Reads and checks a Mach-O's code signature: its code pages must hash as
/// the code directory says.
pub fn read_signature(data: &[u8]) -> Result<CodeSignature, String> {
    let mut found = None;
    for slice in slices(data)? {
        let is_64 = le32(slice, 0)? == 0xfeed_facf;
        let ncmds = le32(slice, 16)? as usize;
        let mut at = if is_64 { 32 } else { 28 };
        let mut signature = None;
        for _ in 0..ncmds {
            let cmd = le32(slice, at)?;
            let size = le32(slice, at + 4)? as usize;
            if cmd == 0x1d {
                signature = Some((le32(slice, at + 8)? as usize, le32(slice, at + 12)? as usize));
            }
            at += size.max(8);
        }
        let (offset, size) = signature.ok_or("the executable is not signed (no LC_CODE_SIGNATURE)")?;
        let blob = slice.get(offset..offset + size).ok_or("code signature outside the file")?;
        found = Some(read_superblob(slice, blob)?);
    }
    found.ok_or_else(|| "empty Mach-O".to_string())
}

fn read_superblob(slice: &[u8], blob: &[u8]) -> Result<CodeSignature, String> {
    if be32(blob, 0)? != 0xfade_0cc0 {
        return Err("bad code signature magic".into());
    }
    let count = be32(blob, 8)? as usize;
    let mut directories = Vec::new();
    let mut entitlements_blob = None;
    let mut cms = None;
    for i in 0..count {
        let slot = be32(blob, 12 + i * 8)?;
        let offset = be32(blob, 16 + i * 8)? as usize;
        let magic = be32(blob, offset)?;
        let len = be32(blob, offset + 4)? as usize;
        let sub = blob.get(offset..offset + len).ok_or("blob outside the signature")?;
        match (slot, magic) {
            (0, 0xfade_0c02) | (0x1000..=0x1004, 0xfade_0c02) => directories.push(sub),
            (5, 0xfade_7171) => entitlements_blob = Some(sub),
            (0x10000, 0xfade_0b01) => cms = Some(&sub[8..]),
            _ => {}
        }
    }
    let directory = directories
        .iter()
        .find(|d| d.get(37) == Some(&2))
        .ok_or("no SHA-256 code directory")?;
    let hash_offset = be32(directory, 16)? as usize;
    let ident_offset = be32(directory, 20)? as usize;
    let n_special = be32(directory, 24)? as usize;
    let n_code = be32(directory, 28)? as usize;
    let code_limit = be32(directory, 32)? as usize;
    let hash_size = directory[36] as usize;
    let page_size = 1usize << directory[39];
    let version = be32(directory, 8)?;
    let team_offset = if version >= 0x20200 { be32(directory, 48)? as usize } else { 0 };

    let code = slice.get(..code_limit).ok_or("code limit beyond the file")?;
    let pages: Vec<&[u8]> = code.chunks(page_size).collect();
    if pages.len() != n_code {
        return Err(format!("{} code pages, the signature has {n_code}", pages.len()));
    }
    for (i, page) in pages.iter().enumerate() {
        let want = directory
            .get(hash_offset + i * hash_size..hash_offset + (i + 1) * hash_size)
            .ok_or("truncated code directory")?;
        if Sha256::digest(page).as_slice() != want {
            return Err(format!("code page {i} does not match its signature"));
        }
    }
    let mut special = BTreeMap::new();
    for k in 1..=n_special {
        let at = hash_offset - k * hash_size;
        special.insert(k as u32, directory[at..at + hash_size].to_vec());
    }

    let entitlements = match entitlements_blob {
        Some(e) => {
            if special.get(&5).map(|h| h.as_slice()) != Some(Sha256::digest(e).as_slice()) {
                return Err("the entitlements do not match their signature".into());
            }
            plist::from_bytes(&e[8..]).map_err(|e| format!("entitlements do not read: {e}"))?
        }
        None => plist::Dictionary::new(),
    };

    let (certificates, signer_serial) = match cms {
        Some(cms) => read_cms_certificates(cms)?,
        None => return Err("the signature has no CMS blob: not signed with a certificate".into()),
    };

    Ok(CodeSignature {
        identifier: c_str(directory, ident_offset),
        team_id: if team_offset > 0 { c_str(directory, team_offset) } else { String::new() },
        entitlements,
        special,
        certificates,
        signer_serial,
    })
}

fn read_cms_certificates(cms: &[u8]) -> Result<(Vec<Vec<u8>>, Option<Vec<u8>>), String> {
    let len = der_len(cms).ok_or("CMS blob does not read")?;
    let info = cms::content_info::ContentInfo::from_der(&cms[..len]).map_err(|e| format!("CMS: {e}"))?;
    let signed: cms::signed_data::SignedData = info.content.decode_as().map_err(|e| format!("CMS: {e}"))?;
    let mut certificates = Vec::new();
    if let Some(set) = &signed.certificates {
        for choice in set.0.iter() {
            if let cms::cert::CertificateChoices::Certificate(cert) = choice {
                certificates.push(cert.to_der().map_err(|e| e.to_string())?);
            }
        }
    }
    let serial = signed.signer_infos.0.iter().next().and_then(|si| match &si.sid {
        cms::signed_data::SignerIdentifier::IssuerAndSerialNumber(isn) => Some(isn.serial_number.as_bytes().to_vec()),
        _ => None,
    });
    Ok((certificates, serial))
}

/// The plist inside a provisioning profile.
pub fn read_profile(data: &[u8]) -> Result<plist::Dictionary, String> {
    let len = der_len(data).ok_or("the profile does not read")?;
    let info = cms::content_info::ContentInfo::from_der(&data[..len.min(data.len())]).map_err(|e| format!("profile: {e}"))?;
    let signed: cms::signed_data::SignedData = info.content.decode_as().map_err(|e| format!("profile: {e}"))?;
    let content = signed.encap_content_info.econtent.ok_or("the profile is empty")?;
    let bytes = content.decode_as::<der::asn1::OctetString>().map_err(|e| format!("profile: {e}"))?;
    plist::from_bytes(bytes.as_bytes()).map_err(|e| format!("the profile's plist does not read: {e}"))
}

fn serial_of(cert_der: &[u8]) -> Option<Vec<u8>> {
    x509_cert::Certificate::from_der(cert_der)
        .ok()
        .map(|c| c.tbs_certificate.serial_number.as_bytes().to_vec())
}

fn sha256(data: &[u8]) -> Vec<u8> {
    Sha256::digest(data).to_vec()
}

/// Whether an entitlement value is within what the profile grants.
fn granted(want: &plist::Value, have: &plist::Value) -> bool {
    fn string_ok(want: &str, have: &plist::Value) -> bool {
        match have {
            plist::Value::String(h) => h == want || h == "*" || (h.ends_with('*') && want.starts_with(&h[..h.len() - 1])),
            plist::Value::Array(items) => items.iter().any(|h| string_ok(want, h)),
            _ => false,
        }
    }
    match want {
        plist::Value::Boolean(false) => true,
        plist::Value::Boolean(true) => matches!(have, plist::Value::Boolean(true)),
        plist::Value::String(w) => string_ok(w, have),
        plist::Value::Array(items) => items.iter().all(|w| match w {
            plist::Value::String(s) => string_ok(s, have),
            other => granted(other, have),
        }),
        other => other == have,
    }
}

fn bundle_dirs(files: &BTreeMap<String, Vec<u8>>) -> Vec<String> {
    let mut dirs: Vec<String> = files
        .keys()
        .filter_map(|p| {
            let parts: Vec<&str> = p.split('/').collect();
            // Frameworks/X.framework/Info.plist, PlugIns/Y.appex/Info.plist,
            // and the same inside a framework.
            let n = parts.len();
            if n >= 3 && parts[n - 1] == "Info.plist" && (parts[n - 3] == "Frameworks" || parts[n - 3] == "PlugIns") {
                let dir = parts[..n - 1].join("/");
                (dir.ends_with(".framework") || dir.ends_with(".appex")).then_some(dir)
            } else {
                None
            }
        })
        .collect();
    dirs.sort();
    dirs.dedup();
    dirs
}

fn verify_bundle(
    files: &BTreeMap<String, Vec<u8>>,
    dir: &str,
    team_id: Option<&str>,
) -> Result<(VerifiedBundle, CodeSignature), String> {
    let prefix = if dir.is_empty() { String::new() } else { format!("{dir}/") };
    let name = if dir.is_empty() { "the app" } else { dir };
    let info_bytes = files
        .get(&format!("{prefix}Info.plist"))
        .ok_or_else(|| format!("{name} has no Info.plist"))?;
    let info: plist::Dictionary =
        plist::from_bytes(info_bytes).map_err(|e| format!("{name}'s Info.plist does not read: {e}"))?;
    let bundle_id = info
        .get("CFBundleIdentifier")
        .and_then(|v| v.as_string())
        .ok_or_else(|| format!("{name} has no CFBundleIdentifier"))?
        .to_string();
    let executable = info
        .get("CFBundleExecutable")
        .and_then(|v| v.as_string())
        .ok_or_else(|| format!("{name} has no CFBundleExecutable"))?
        .to_string();
    let binary = files
        .get(&format!("{prefix}{executable}"))
        .ok_or_else(|| format!("{name}'s executable {executable} is missing"))?;
    let signature = read_signature(binary).map_err(|e| format!("{name}: {e}"))?;
    if signature.identifier != bundle_id {
        return Err(format!(
            "{name} is signed as {} but is {bundle_id}",
            signature.identifier
        ));
    }
    if let Some(team) = team_id
        && signature.team_id != team
    {
        return Err(format!("{name} is signed by team {}, the app by {team}", signature.team_id));
    }
    if signature.special.get(&1) != Some(&sha256(info_bytes)) {
        return Err(format!("{name}'s Info.plist changed after signing"));
    }
    let resources_bytes = files
        .get(&format!("{prefix}_CodeSignature/CodeResources"))
        .ok_or_else(|| format!("{name} has no _CodeSignature/CodeResources"))?;
    if signature.special.get(&3) != Some(&sha256(resources_bytes)) {
        return Err(format!("{name}'s CodeResources changed after signing"));
    }
    let resources: plist::Dictionary = plist::from_bytes(resources_bytes)
        .map_err(|e| format!("{name}'s CodeResources does not read: {e}"))?;
    let sealed = resources
        .get("files2")
        .and_then(|v| v.as_dictionary())
        .cloned()
        .unwrap_or_default();
    for (path, entry) in &sealed {
        let entry = entry.as_dictionary();
        let optional = entry
            .and_then(|e| e.get("optional"))
            .and_then(|v| v.as_boolean())
            .unwrap_or(false);
        let want = entry.and_then(|e| e.get("hash2")).and_then(|v| v.as_data());
        match (files.get(&format!("{prefix}{path}")), want) {
            (Some(data), Some(want)) if sha256(data) != want => {
                return Err(format!("a sealed resource is missing or invalid: {prefix}{path}"));
            }
            (None, _) if !optional => {
                return Err(format!("a sealed resource is missing or invalid: {prefix}{path}"));
            }
            _ => {}
        }
    }
    for path in files.keys().filter_map(|p| p.strip_prefix(&prefix)) {
        // A nested bundle's files are sealed in its own CodeResources, and
        // again in this one by their path: every file is in files2 but the
        // executable, the CodeResources and the Info.plist, which the code
        // directory seals itself.
        let unsealed = path != executable
            && path != "_CodeSignature/CodeResources"
            && path != "Info.plist"
            && path != "PkgInfo"
            && !sealed.contains_key(path);
        if unsealed {
            return Err(format!("the bundle holds unsealed contents: {prefix}{path}"));
        }
    }
    let has_profile = files.contains_key(&format!("{prefix}embedded.mobileprovision"));
    Ok((
        VerifiedBundle {
            path: dir.to_string(),
            bundle_id,
            team_id: signature.team_id.clone(),
            info,
            entitlements: signature.entitlements.clone(),
            has_profile,
        },
        signature,
    ))
}

/// Checks an app staged for installation, by its files inside the .app.
/// What installd checks of a provisioning profile against the bundle it
/// sits in: dates, the iPhone, the team, the signing certificate, and that
/// every entitlement signed in is one the profile grants. `app_id` is
/// checked for the app itself only: with isideload's ReuseMain, extensions
/// carry the app's profile and entitlements, which iOS accepts.
fn check_profile(
    name: &str,
    profile_bytes: &[u8],
    udid: &str,
    team_id: &str,
    signature: &CodeSignature,
    app_id: Option<&str>,
) -> Result<(plist::Dictionary, Vec<u8>), String> {
    let profile = read_profile(profile_bytes).map_err(|e| format!("{name}: {e}"))?;
    let expires = profile
        .get("ExpirationDate")
        .and_then(|v| v.as_date())
        .map(std::time::SystemTime::from)
        .ok_or_else(|| format!("{name}: the profile has no expiration date"))?;
    if expires < std::time::SystemTime::now() {
        return Err(format!("{name}: the provisioning profile has expired"));
    }
    let devices: Vec<&str> = profile
        .get("ProvisionedDevices")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_string()).collect())
        .unwrap_or_default();
    // An enterprise profile provisions every iPhone, and lists none.
    let all_devices = profile.get("ProvisionsAllDevices").and_then(|v| v.as_boolean()) == Some(true);
    if !all_devices && !devices.contains(&udid) {
        return Err(format!("{name}: the provisioning profile does not list this iPhone ({udid})"));
    }
    let teams: Vec<&str> = profile
        .get("TeamIdentifier")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_string()).collect())
        .unwrap_or_default();
    if !teams.contains(&team_id) {
        return Err(format!("{name}: the provisioning profile is not team {team_id}'s"));
    }
    let granted_entitlements = profile
        .get("Entitlements")
        .and_then(|v| v.as_dictionary())
        .cloned()
        .ok_or_else(|| format!("{name}: the profile has no entitlements"))?;
    if let Some(app_id) = app_id {
        match granted_entitlements.get("application-identifier") {
            Some(have) if granted(&plist::Value::String(app_id.to_string()), have) => {}
            other => {
                return Err(format!("{name}: the profile is for {other:?}, not {app_id}"));
            }
        }
    }
    let profile_certs: Vec<Vec<u8>> = profile
        .get("DeveloperCertificates")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_data().map(<[u8]>::to_vec)).collect())
        .unwrap_or_default();
    let signer = signature
        .certificates
        .iter()
        .find(|c| serial_of(c).is_some() && serial_of(c) == signature.signer_serial)
        .cloned()
        .ok_or_else(|| format!("{name}: the signature's certificate is missing"))?;
    if !profile_certs.contains(&signer) {
        return Err(format!("{name}: signed with a certificate its profile does not list"));
    }
    for (key, want) in &signature.entitlements {
        match granted_entitlements.get(key) {
            Some(have) if granted(want, have) => {}
            _ => {
                return Err(format!(
                    "{name}: the executable was signed with invalid entitlements: {key} is not in the profile"
                ));
            }
        }
    }
    Ok((profile, signer))
}

pub fn verify_app(files: &BTreeMap<String, Vec<u8>>, udid: &str) -> Result<VerifiedApp, String> {
    if files.is_empty() {
        return Err("no app at that path".into());
    }
    let (main, signature) = verify_bundle(files, "", None)?;
    let team_id = signature.team_id.clone();
    if team_id.is_empty() {
        return Err("the app is signed without a team".into());
    }
    let profile_bytes = files
        .get("embedded.mobileprovision")
        .ok_or("the app has no embedded.mobileprovision")?;
    let app_id = format!("{team_id}.{}", main.bundle_id);
    let (profile, signer) = check_profile("the app", profile_bytes, udid, &team_id, &signature, Some(&app_id))?;

    let mut bundles = vec![main.clone()];
    for dir in bundle_dirs(files) {
        let (bundle, nested) = verify_bundle(files, &dir, Some(&team_id))?;
        if let Some(nested_profile) = files.get(&format!("{dir}/embedded.mobileprovision")) {
            check_profile(&dir, nested_profile, udid, &team_id, &nested, None)?;
        } else if !nested.entitlements.is_empty() && dir.ends_with(".appex") {
            return Err(format!("{dir} has entitlements but no provisioning profile"));
        }
        bundles.push(bundle);
    }

    Ok(VerifiedApp {
        bundle_id: main.bundle_id.clone(),
        team_id,
        info: main.info.clone(),
        entitlements: signature.entitlements.clone(),
        free_profile: profile
            .get("LocalProvision")
            .and_then(|v| v.as_boolean())
            .unwrap_or(false),
        profile,
        signer_certificate: signer,
        bundles,
    })
}
