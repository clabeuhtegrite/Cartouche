//! GitHub as the installer reaches it: Cartouche's source on
//! raw.githubusercontent.com, and its IPA from the releases on github.com,
//! which redirect to the asset's host.
//!
//! The installer's HTTP client goes through this fake as an HTTPS proxy:
//! it asks to CONNECT to a GitHub host, then speaks TLS to it, and the fake
//! answers with certificates of the tests' own authority. The URLs stay the
//! installer's own, checks of their addresses included.

use std::{
    net::SocketAddr,
    sync::{Arc, Mutex, MutexGuard},
};

use sha2::Digest;
use tokio::{
    io::{AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
};
use tokio_rustls::TlsAcceptor;

use crate::{
    http::{self, Request, Response},
    tls::TestCa,
};

pub const SOURCE_PATH: &str = "/clabeuhtegrite/Cartouche/main/app/sidestore-source.json";
pub const BUNDLE_ID: &str = "io.github.clabeuhtegrite.cartouche";
const HOSTS: [&str; 3] = ["raw.githubusercontent.com", "github.com", "release-assets.githubusercontent.com"];

#[derive(Clone, Debug)]
pub struct Release {
    pub version: String,
    pub ipa: Vec<u8>,
}

#[derive(Debug, Default)]
pub struct GithubState {
    releases: Vec<Release>,
    /// Replaces the source the releases make, when set.
    pub source_override: Option<String>,
    /// HTTP status of the source, 200 unless a test says otherwise.
    pub source_status: Option<u16>,
    /// HTTP status of the IPA's download.
    pub asset_status: Option<u16>,
    /// Serves only this many bytes of the IPA, then closes.
    pub asset_truncate: Option<usize>,
    /// Serves these bytes in place of the IPA (same size, other content).
    pub asset_replace: Option<Vec<u8>>,
    /// Every request, as "host path".
    pub requests: Vec<String>,
    /// CONNECTs to hosts other than GitHub's, refused.
    pub refused: Vec<String>,
}

struct Shared {
    addr: SocketAddr,
    tls: TlsAcceptor,
    ca: TestCa,
    state: Mutex<GithubState>,
}

#[derive(Clone)]
pub struct FakeGithub(Arc<Shared>);

impl FakeGithub {
    pub async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind fake GitHub");
        let ca = TestCa::new();
        let tls = TlsAcceptor::from(ca.server(&HOSTS));
        let github = FakeGithub(Arc::new(Shared {
            addr: listener.local_addr().expect("address"),
            tls,
            ca,
            state: Mutex::new(GithubState::default()),
        }));
        let server = github.clone();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else { break };
                let _ = stream.set_nodelay(true);
                let github = server.clone();
                tokio::spawn(async move {
                    let _ = github.tunnel(stream).await;
                });
            }
        });
        github
    }

    /// The proxy the installer's HTTP client goes through.
    pub fn proxy_url(&self) -> String {
        format!("http://{}", self.0.addr)
    }

    /// The certificate (DER) the client trusts for GitHub in the tests.
    pub fn ca_der(&self) -> Vec<u8> {
        self.0.ca.cert_der.clone()
    }

    pub fn state(&self) -> MutexGuard<'_, GithubState> {
        self.0.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Publishes a release of Cartouche with this IPA.
    pub fn publish(&self, version: &str, ipa: Vec<u8>) {
        self.state().releases.push(Release { version: version.to_string(), ipa });
    }

    pub fn download_url(version: &str) -> String {
        format!("https://github.com/clabeuhtegrite/Cartouche/releases/download/v{version}/Cartouche-{version}.ipa")
    }

    /// The source as the release workflow writes it, for the releases
    /// published so far.
    pub fn source(&self) -> String {
        let state = self.state();
        if let Some(source) = &state.source_override {
            return source.clone();
        }
        let versions: Vec<serde_json::Value> = state
            .releases
            .iter()
            .rev()
            .map(|r| {
                serde_json::json!({
                    "version": r.version,
                    "date": "2026-11-12T10:00:00Z",
                    "downloadURL": Self::download_url(&r.version),
                    "size": r.ipa.len(),
                    "sha256": hex::encode(sha2::Sha256::digest(&r.ipa)),
                    "localizedDescription": format!("Cartouche {}", r.version),
                    "minOSVersion": "26.0"
                })
            })
            .collect();
        serde_json::json!({
            "name": "Cartouche",
            "identifier": "io.github.clabeuhtegrite.cartouche.source",
            "apps": [{
                "name": "Cartouche",
                "bundleIdentifier": BUNDLE_ID,
                "developerName": "Cartouche",
                "versions": versions
            }],
            "news": []
        })
        .to_string()
    }

    async fn tunnel(&self, stream: TcpStream) -> std::io::Result<()> {
        let mut reader = BufReader::new(stream);
        let Some(connect) = http::read_request(&mut reader).await? else {
            return Ok(());
        };
        let host = connect.target.split(':').next().unwrap_or("").to_string();
        if connect.method != "CONNECT" || !HOSTS.contains(&host.as_str()) || !connect.target.ends_with(":443") {
            self.state().refused.push(connect.target.clone());
            let mut stream = reader.into_inner();
            stream.write_all(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n").await?;
            return Ok(());
        }
        let mut stream = reader.into_inner();
        stream.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n").await?;
        let tls = self.0.tls.accept(stream).await?;
        let github = self.clone();
        let mut reader = BufReader::new(tls);
        while let Some(request) = http::read_request(&mut reader).await? {
            github.state().requests.push(format!("{host} {}", request.target));
            match github.answer(&host, &request) {
                Answer::Full(response) => http::write_response(reader.get_mut(), &response, false).await?,
                Answer::Truncated(head_len, bytes) => {
                    let stream = reader.get_mut();
                    stream
                        .write_all(
                            format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {head_len}\r\n\r\n"
                            )
                            .as_bytes(),
                        )
                        .await?;
                    stream.write_all(&bytes).await?;
                    stream.flush().await?;
                    let _ = stream.shutdown().await;
                    return Ok(());
                }
            }
        }
        Ok(())
    }

    fn answer(&self, host: &str, request: &Request) -> Answer {
        if request.method != "GET" {
            return Answer::Full(Response::text(405, "GET only"));
        }
        match host {
            "raw.githubusercontent.com" if request.path() == SOURCE_PATH => {
                let status = self.state().source_status.unwrap_or(200);
                Answer::Full(Response::new(status, "text/plain; charset=utf-8", self.source()))
            }
            "github.com" => {
                let prefix = "/clabeuhtegrite/Cartouche/releases/download/v";
                let Some(rest) = request.path().strip_prefix(prefix) else {
                    return Answer::Full(Response::text(404, "Not Found"));
                };
                let version = rest.split('/').next().unwrap_or("");
                if self.state().releases.iter().all(|r| r.version != version) {
                    return Answer::Full(Response::text(404, "Not Found"));
                }
                Answer::Full(Response::redirect(&format!(
                    "https://release-assets.githubusercontent.com/github-production-release-asset/1/{version}?sp=r&sig=fake"
                )))
            }
            "release-assets.githubusercontent.com" => {
                let version = request
                    .path()
                    .strip_prefix("/github-production-release-asset/1/")
                    .unwrap_or("")
                    .to_string();
                let state = self.state();
                let Some(release) = state.releases.iter().find(|r| r.version == version) else {
                    return Answer::Full(Response::text(404, "Not Found"));
                };
                if let Some(status) = state.asset_status {
                    return Answer::Full(Response::text(status, "fake failure"));
                }
                let bytes = state.asset_replace.clone().unwrap_or_else(|| release.ipa.clone());
                if let Some(n) = state.asset_truncate {
                    return Answer::Truncated(bytes.len(), bytes[..n.min(bytes.len())].to_vec());
                }
                Answer::Full(Response::new(200, "application/octet-stream", bytes))
            }
            _ => Answer::Full(Response::text(404, "Not Found")),
        }
    }
}

enum Answer {
    Full(Response),
    /// Announces the first number of bytes, sends the second, and closes.
    Truncated(usize, Vec<u8>),
}
