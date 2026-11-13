//! The iPhone's side of remote pairing (iOS 17 and later), over lockdown's
//! com.apple.dt.remotepairingdeviced.lockdown: pair-verify for a computer it
//! already trusts, otherwise "Trust This Computer?" and pair-setup (SRP with
//! the PIN 000000, then both sides' Ed25519 keys under ChaCha20-Poly1305).

use std::{io, time::Duration};

use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use chacha20poly1305::{
    ChaCha20Poly1305, Key, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use ed25519_dalek::{Signer, Verifier};
use hkdf::Hkdf;
use idevice::remote_pairing::{RpPairingSocket, RpPairingSocketProvider};
use idevice_srp::{client::SrpClient, groups::G_3072, server::SrpServer};
use sha2_010::Sha512;
use tokio::net::TcpStream;

use super::{FakeIphone, RpHost, Trust};

const T_METHOD: u8 = 0x00;
const T_IDENTIFIER: u8 = 0x01;
const T_SALT: u8 = 0x02;
const T_PUBLIC_KEY: u8 = 0x03;
const T_PROOF: u8 = 0x04;
const T_ENCRYPTED: u8 = 0x05;
const T_STATE: u8 = 0x06;
const T_ERROR: u8 = 0x07;
const T_SIGNATURE: u8 = 0x0a;
const T_INFO: u8 = 0x11;
const ERROR_AUTHENTICATION: u8 = 0x02;

fn io_err(e: impl std::fmt::Display) -> io::Error {
    io::Error::other(e.to_string())
}

/// TLV8, with long values split in 255-byte pieces.
fn tlv(entries: &[(u8, &[u8])]) -> Vec<u8> {
    let mut out = Vec::new();
    for (kind, data) in entries {
        if data.is_empty() {
            out.extend_from_slice(&[*kind, 0]);
        }
        for chunk in data.chunks(255) {
            out.push(*kind);
            out.push(chunk.len() as u8);
            out.extend_from_slice(chunk);
        }
    }
    out
}

/// The values of a TLV8 by type, pieces put back together.
fn untlv(data: &[u8]) -> Result<Vec<(u8, Vec<u8>)>, io::Error> {
    let mut out: Vec<(u8, Vec<u8>)> = Vec::new();
    let mut i = 0;
    let mut last: Option<u8> = None;
    while i + 2 <= data.len() {
        let kind = data[i];
        let len = data[i + 1] as usize;
        let value = data.get(i + 2..i + 2 + len).ok_or_else(|| io_err("truncated TLV8"))?;
        match (last, out.last_mut()) {
            (Some(k), Some((_, v))) if k == kind => v.extend_from_slice(value),
            _ => out.push((kind, value.to_vec())),
        }
        last = Some(kind);
        i += 2 + len;
    }
    Ok(out)
}

fn field(entries: &[(u8, Vec<u8>)], kind: u8) -> Option<&[u8]> {
    entries.iter().find(|(k, _)| *k == kind).map(|(_, v)| v.as_slice())
}

fn hkdf(key: &[u8], salt: &str, info: &str) -> [u8; 32] {
    let mut out = [0u8; 32];
    Hkdf::<Sha512>::new(Some(salt.as_bytes()), key)
        .expand(info.as_bytes(), &mut out)
        .expect("32 bytes");
    out
}

fn nonce(name: &str) -> [u8; 12] {
    let mut n = [0u8; 12];
    n[4..].copy_from_slice(name.as_bytes());
    n
}

fn seal(key: &[u8; 32], name: &str, plain: &[u8]) -> Vec<u8> {
    ChaCha20Poly1305::new(Key::from_slice(key))
        .encrypt(Nonce::from_slice(&nonce(name)), Payload { msg: plain, aad: b"" })
        .expect("encrypt")
}

fn open(key: &[u8; 32], name: &str, sealed: &[u8]) -> Option<Vec<u8>> {
    ChaCha20Poly1305::new(Key::from_slice(key))
        .decrypt(Nonce::from_slice(&nonce(name)), Payload { msg: sealed, aad: b"" })
        .ok()
}

/// OPACK, Apple's compact plist, for the few kinds pairing uses.
pub mod opack {
    pub enum V {
        Str(String),
        Data(Vec<u8>),
        Dict(Vec<(String, V)>),
    }

    pub fn encode(v: &V, out: &mut Vec<u8>) {
        match v {
            V::Str(s) => {
                let b = s.as_bytes();
                if b.len() <= 0x20 {
                    out.push(0x40 + b.len() as u8);
                } else {
                    out.push(0x61);
                    out.push(b.len() as u8);
                }
                out.extend_from_slice(b);
            }
            V::Data(b) => {
                if b.len() <= 0x20 {
                    out.push(0x70 + b.len() as u8);
                } else {
                    out.push(0x91);
                    out.push(b.len() as u8);
                }
                out.extend_from_slice(b);
            }
            V::Dict(items) => {
                if items.len() < 15 {
                    out.push(0xe0 + items.len() as u8);
                } else {
                    out.push(0xef);
                }
                for (k, v) in items {
                    encode(&V::Str(k.clone()), out);
                    encode(v, out);
                }
                if items.len() >= 15 {
                    out.push(0x03);
                }
            }
        }
    }

    /// Reads the strings of a dictionary; other values are skipped.
    pub fn strings(b: &[u8]) -> Vec<(String, String)> {
        let mut out = Vec::new();
        let mut i = 0usize;
        let Some(&tag) = b.first() else { return out };
        if !(0xe0..=0xef).contains(&tag) {
            return out;
        }
        let count = if tag == 0xef { usize::MAX } else { (tag - 0xe0) as usize };
        i += 1;
        let mut n = 0;
        while n < count && i < b.len() {
            if b[i] == 0x03 {
                break;
            }
            let Some((key, next)) = read(b, i) else { break };
            let Some((value, after)) = read(b, next) else { break };
            if let (Some(k), Some(v)) = (key, value) {
                out.push((k, v));
            }
            i = after;
            n += 1;
        }
        out
    }

    /// One value: Some(string) for a string, None for anything else.
    fn read(b: &[u8], i: usize) -> Option<(Option<String>, usize)> {
        let tag = *b.get(i)?;
        let (len, start, is_str) = match tag {
            0x01 | 0x02 | 0x08..=0x2f => return Some((None, i + 1)),
            0x30 => return Some((None, i + 2)),
            0x31 => return Some((None, i + 3)),
            0x32 => return Some((None, i + 5)),
            0x33 => return Some((None, i + 9)),
            0x40..=0x60 => ((tag - 0x40) as usize, i + 1, true),
            0x61 => (*b.get(i + 1)? as usize, i + 2, true),
            0x62 => (u16::from_le_bytes([*b.get(i + 1)?, *b.get(i + 2)?]) as usize, i + 3, true),
            0x70..=0x90 => ((tag - 0x70) as usize, i + 1, false),
            0x91 => (*b.get(i + 1)? as usize, i + 2, false),
            0x92 => (u16::from_le_bytes([*b.get(i + 1)?, *b.get(i + 2)?]) as usize, i + 3, false),
            _ => return None,
        };
        let bytes = b.get(start..start + len)?;
        let value = is_str.then(|| String::from_utf8_lossy(bytes).into_owned());
        Some((value, start + len))
    }
}

struct Conn {
    socket: RpPairingSocket<TcpStream>,
    seq: usize,
}

impl Conn {
    async fn recv(&mut self) -> io::Result<Option<plist::Value>> {
        match self.socket.recv_plain().await {
            Ok(v) => Ok(Some(v)),
            Err(idevice::IdeviceError::Socket(e)) if e.kind() == io::ErrorKind::UnexpectedEof => Ok(None),
            Err(e) => Err(io_err(e)),
        }
    }

    async fn send(&mut self, value: serde_json::Value) -> io::Result<()> {
        let seq = self.seq;
        self.seq += 1;
        self.socket.send_plain(value, seq).await.map_err(io_err)
    }

    async fn send_pairing_data(&mut self, kind: &str, data: &[u8]) -> io::Result<()> {
        self.send(serde_json::json!({
            "event": {"_0": {"pairingData": {"_0": {
                "data": B64.encode(data),
                "kind": kind,
                "startNewSession": false,
            }}}}
        }))
        .await
    }
}

fn get<'a>(v: &'a plist::Value, path: &[&str]) -> Option<&'a plist::Value> {
    let mut v = v;
    for key in path {
        v = v.as_dictionary()?.get(*key)?;
    }
    Some(v)
}

pub async fn serve(iphone: FakeIphone, stream: TcpStream) -> io::Result<()> {
    let mut conn = Conn {
        socket: RpPairingSocket::new_device(stream),
        seq: 0,
    };
    let Some(request) = conn.recv().await? else {
        return Ok(());
    };
    if get(&request, &["request", "_0", "handshake", "_0"]).is_none() {
        iphone.note("remote pairing: no handshake");
        return Ok(());
    }
    let c = iphone.config().clone();
    conn.send(serde_json::json!({
        "response": {
            "forRequestIdentifier": 0,
            "_1": {"handshake": {"_0": {
                "wireProtocolVersion": 26,
                "minimumSupportedWireProtocolVersion": 8,
                "deviceOptions": {
                    "allowsPairSetup": true,
                    "allowsPinlessPairing": false,
                    "allowsIncomingTunnelConnections": true,
                    "allowsUpgradeOfLockdownPairings": false,
                    "allowsSharingSensitiveInfo": true
                },
                "peerDeviceInfo": {
                    "udid": c.udid,
                    "identifier": iphone.0.rp_identifier,
                    "name": c.name,
                    "model": c.product_type,
                    "deviceKVSIncludesSensitiveInfo": false
                }
            }}}
        }
    }))
    .await?;

    let mut verify: Option<([u8; 32], [u8; 32], [u8; 32])> = None;
    let mut setup: Option<Setup> = None;
    loop {
        let Some(message) = conn.recv().await? else {
            return Ok(());
        };
        if get(&message, &["event", "_0", "pairVerifyFailed"]).is_some() {
            continue;
        }
        let Some(pairing) = get(&message, &["event", "_0", "pairingData", "_0"]) else {
            iphone.note("remote pairing: unexpected message");
            continue;
        };
        let kind = get(pairing, &["kind"]).and_then(|v| v.as_string()).unwrap_or("").to_string();
        let data = get(pairing, &["data"])
            .and_then(|v| v.as_string())
            .and_then(|s| B64.decode(s).ok())
            .unwrap_or_default();
        let entries = untlv(&data)?;
        let state = field(&entries, T_STATE).and_then(|s| s.first().copied()).unwrap_or(0);
        match (kind.as_str(), state) {
            ("verifyManualPairing", 1) => {
                let Some(theirs) = field(&entries, T_PUBLIC_KEY).and_then(|k| <[u8; 32]>::try_from(k).ok()) else {
                    conn.send_pairing_data(&kind, &tlv(&[(T_STATE, &[2]), (T_ERROR, &[ERROR_AUTHENTICATION])])).await?;
                    continue;
                };
                let mut secret = [0u8; 32];
                rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut secret);
                let secret = x25519_dalek::StaticSecret::from(secret);
                let ours = x25519_dalek::PublicKey::from(&secret).to_bytes();
                let shared = secret.diffie_hellman(&x25519_dalek::PublicKey::from(theirs));
                let key = hkdf(shared.as_bytes(), "Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info");
                let mut signed = ours.to_vec();
                signed.extend_from_slice(iphone.0.rp_identifier.as_bytes());
                signed.extend_from_slice(&theirs);
                let signature = iphone.0.rp_key.sign(&signed).to_bytes();
                let inner = tlv(&[(T_IDENTIFIER, iphone.0.rp_identifier.as_bytes()), (T_SIGNATURE, &signature)]);
                let sealed = seal(&key, "PV-Msg02", &inner);
                conn.send_pairing_data(&kind, &tlv(&[(T_STATE, &[2]), (T_PUBLIC_KEY, &ours), (T_ENCRYPTED, &sealed)]))
                    .await?;
                verify = Some((key, ours, theirs));
            }
            ("verifyManualPairing", 3) => {
                let ok = verify.take().and_then(|(key, ours, theirs)| {
                    let inner = untlv(&open(&key, "PV-Msg03", field(&entries, T_ENCRYPTED)?)?).ok()?;
                    let identifier = String::from_utf8(field(&inner, T_IDENTIFIER)?.to_vec()).ok()?;
                    let signature = ed25519_dalek::Signature::from_slice(field(&inner, T_SIGNATURE)?).ok()?;
                    let host = iphone.state().rp_hosts.iter().find(|h| h.identifier == identifier).cloned()?;
                    let mut signed = theirs.to_vec();
                    signed.extend_from_slice(identifier.as_bytes());
                    signed.extend_from_slice(&ours);
                    ed25519_dalek::VerifyingKey::from_bytes(&host.public_key)
                        .ok()?
                        .verify(&signed, &signature)
                        .ok()
                        .map(|_| host)
                });
                match ok {
                    Some(host) => {
                        iphone.state().pair_verifies += 1;
                        iphone.note(format!("remote pairing: verified {}", host.name));
                        conn.send_pairing_data(&kind, &tlv(&[(T_STATE, &[4])])).await?;
                    }
                    None => {
                        iphone.note("remote pairing: pair-verify of an unknown computer");
                        conn.send_pairing_data(&kind, &tlv(&[(T_STATE, &[4]), (T_ERROR, &[ERROR_AUTHENTICATION])]))
                            .await?;
                    }
                }
            }
            ("setupManualPairing", 1) => {
                if field(&entries, T_METHOD) != Some(&[0]) {
                    conn.send_pairing_data(&kind, &tlv(&[(T_STATE, &[2]), (T_ERROR, &[ERROR_AUTHENTICATION])])).await?;
                    continue;
                }
                let host = get(pairing, &["sendingHost"]).and_then(|v| v.as_string()).unwrap_or("").to_string();
                iphone.note(format!("remote pairing: asks \"Trust This Computer?\" for {host}"));
                conn.send(serde_json::json!({"event": {"_0": {"awaitingUserConsent": {}}}})).await?;
                loop {
                    let trust = iphone.state().trust;
                    match trust {
                        Trust::Accept => break,
                        Trust::Refuse => {
                            iphone.note("remote pairing: Don't Trust");
                            conn.send(serde_json::json!({"event": {"_0": {"pairingRejectedWithError": {
                                "wrappedError": {"userInfo": {"NSLocalizedDescription": "The user declined to trust this computer."}}
                            }}}}))
                            .await?;
                            return Ok(());
                        }
                        Trust::Never => tokio::time::sleep(Duration::from_millis(50)).await,
                    }
                }
                iphone.note("remote pairing: Trust");
                let s = Setup::new(host);
                conn.send_pairing_data(&kind, &tlv(&[(T_STATE, &[2]), (T_SALT, &s.salt), (T_PUBLIC_KEY, &s.b_pub)]))
                    .await?;
                setup = Some(s);
            }
            ("setupManualPairing", 3) => {
                let Some(s) = setup.as_mut() else { continue };
                let a_pub = field(&entries, T_PUBLIC_KEY).unwrap_or(&[]).to_vec();
                let proof = field(&entries, T_PROOF).unwrap_or(&[]).to_vec();
                let server = SrpServer::<Sha512>::new(&G_3072);
                let checked = server
                    .process_reply(&s.b, &s.verifier, &a_pub, b"Pair-Setup", &s.salt)
                    .ok()
                    .filter(|v| v.verify_client(&proof).is_ok());
                match checked {
                    Some(v) => {
                        s.session_key = v.key().to_vec();
                        conn.send_pairing_data(&kind, &tlv(&[(T_STATE, &[4]), (T_PROOF, v.proof())])).await?;
                    }
                    None => {
                        iphone.note("remote pairing: wrong PIN");
                        conn.send_pairing_data(&kind, &tlv(&[(T_STATE, &[4]), (T_ERROR, &[ERROR_AUTHENTICATION])]))
                            .await?;
                        setup = None;
                    }
                }
            }
            ("setupManualPairing", 5) => {
                let Some(s) = setup.take() else { continue };
                let key = hkdf(&s.session_key, "Pair-Setup-Encrypt-Salt", "Pair-Setup-Encrypt-Info");
                let host = field(&entries, T_ENCRYPTED)
                    .and_then(|sealed| open(&key, "PS-Msg05", sealed))
                    .and_then(|plain| untlv(&plain).ok())
                    .and_then(|inner| {
                        let identifier = String::from_utf8(field(&inner, T_IDENTIFIER)?.to_vec()).ok()?;
                        let ltpk = <[u8; 32]>::try_from(field(&inner, T_PUBLIC_KEY)?).ok()?;
                        let signature = ed25519_dalek::Signature::from_slice(field(&inner, T_SIGNATURE)?).ok()?;
                        let x = hkdf(&s.session_key, "Pair-Setup-Controller-Sign-Salt", "Pair-Setup-Controller-Sign-Info");
                        let mut signed = x.to_vec();
                        signed.extend_from_slice(identifier.as_bytes());
                        signed.extend_from_slice(&ltpk);
                        ed25519_dalek::VerifyingKey::from_bytes(&ltpk).ok()?.verify(&signed, &signature).ok()?;
                        let name = opack::strings(field(&inner, T_INFO).unwrap_or(&[]))
                            .into_iter()
                            .find(|(k, _)| k == "name")
                            .map(|(_, v)| v)
                            .unwrap_or_else(|| s.host.clone());
                        Some(RpHost { identifier, public_key: ltpk, name })
                    });
                let Some(host) = host else {
                    iphone.note("remote pairing: the computer's identity does not check");
                    conn.send_pairing_data(&kind, &tlv(&[(T_STATE, &[6]), (T_ERROR, &[ERROR_AUTHENTICATION])])).await?;
                    continue;
                };
                {
                    let mut state = iphone.state();
                    state.rp_hosts.retain(|h| h.identifier != host.identifier);
                    state.rp_hosts.push(host.clone());
                    state.pair_setups += 1;
                }
                iphone.note(format!("remote pairing: now trusts {}", host.name));

                let ltpk = iphone.0.rp_key.verifying_key().to_bytes();
                let x = hkdf(&s.session_key, "Pair-Setup-Accessory-Sign-Salt", "Pair-Setup-Accessory-Sign-Info");
                let mut signed = x.to_vec();
                signed.extend_from_slice(iphone.0.rp_identifier.as_bytes());
                signed.extend_from_slice(&ltpk);
                let signature = iphone.0.rp_key.sign(&signed).to_bytes();
                let mut info = Vec::new();
                opack::encode(
                    &opack::V::Dict(vec![
                        ("altIRK".into(), opack::V::Data(iphone.0.alt_irk.to_vec())),
                        ("btAddr".into(), opack::V::Str("AA:BB:CC:DD:EE:FF".into())),
                        ("mac".into(), opack::V::Data(vec![0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])),
                        ("remotepairing_serial_number".into(), opack::V::Str("F2LZ1234ABCD".into())),
                        ("accountID".into(), opack::V::Str(iphone.0.rp_identifier.clone())),
                        ("remotepairing_udid".into(), opack::V::Str(c.udid.clone())),
                        ("model".into(), opack::V::Str(c.product_type.clone())),
                        ("name".into(), opack::V::Str(c.name.clone())),
                    ]),
                    &mut info,
                );
                let inner = tlv(&[
                    (T_IDENTIFIER, iphone.0.rp_identifier.as_bytes()),
                    (T_PUBLIC_KEY, &ltpk),
                    (T_SIGNATURE, &signature),
                    (T_INFO, &info),
                ]);
                let sealed = seal(&key, "PS-Msg06", &inner);
                conn.send_pairing_data(&kind, &tlv(&[(T_ENCRYPTED, &sealed), (T_STATE, &[6])])).await?;
            }
            (kind, state) => {
                iphone.note(format!("remote pairing: unexpected {kind} M{state}"));
            }
        }
    }
}

struct Setup {
    host: String,
    salt: [u8; 16],
    b: [u8; 32],
    b_pub: Vec<u8>,
    verifier: Vec<u8>,
    session_key: Vec<u8>,
}

impl Setup {
    fn new(host: String) -> Self {
        let mut salt = [0u8; 16];
        rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut salt);
        let verifier = SrpClient::<Sha512>::new(&G_3072).compute_verifier(b"Pair-Setup", b"000000", &salt);
        let server = SrpServer::<Sha512>::new(&G_3072);
        loop {
            let mut b = [0u8; 32];
            rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut b);
            let b_pub = server.compute_public_ephemeral(&b, &verifier);
            if b_pub.len() == 384 {
                return Setup { host, salt, b, b_pub, verifier, session_key: Vec::new() };
            }
        }
    }
}
