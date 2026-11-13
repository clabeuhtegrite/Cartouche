//! An anisette server in the remote v3 protocol: it provisions a machine
//! with Apple (through the client, over a WebSocket), then hands out the
//! headers that machine signs Apple's requests with.

use std::{
    collections::BTreeMap,
    net::SocketAddr,
    sync::{Arc, Mutex, MutexGuard},
};

use base64::{Engine, prelude::BASE64_STANDARD};
use futures::{SinkExt, StreamExt};
use tokio::{io::BufReader, net::TcpListener};
use tokio_tungstenite::{
    WebSocketStream,
    tungstenite::{Message, protocol::Role},
};

use crate::{
    apple::{cpim_for, machine_id, random_bytes},
    http::{self, Request, Response},
};

#[derive(Debug, Default)]
pub struct AnisetteState {
    /// identifier → (adi_pb, the transport key Apple gave the machine).
    provisioned: BTreeMap<String, (String, String)>,
    /// Answers 502 to everything, as an anisette server that is down.
    pub down: bool,
    /// Forgets every machine, as a server that lost its state: the client
    /// gets -45061 and must provision again.
    pub forget_next: bool,
    pub provisionings: u32,
    pub log: Vec<String>,
}

struct Shared {
    addr: SocketAddr,
    state: Mutex<AnisetteState>,
}

#[derive(Clone)]
pub struct FakeAnisette(Arc<Shared>);

impl FakeAnisette {
    pub async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind fake anisette");
        let anisette = FakeAnisette(Arc::new(Shared {
            addr: listener.local_addr().expect("address"),
            state: Mutex::new(AnisetteState::default()),
        }));
        let server = anisette.clone();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else { break };
                let _ = stream.set_nodelay(true);
                let anisette = server.clone();
                tokio::spawn(async move {
                    let _ = anisette.serve(stream).await;
                });
            }
        });
        anisette
    }

    /// What the player types as the anisette server.
    pub fn url(&self) -> String {
        format!("http://{}", self.0.addr)
    }

    pub fn state(&self) -> MutexGuard<'_, AnisetteState> {
        self.0.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn note(&self, line: impl Into<String>) {
        let line = line.into();
        tracing::debug!("fake anisette: {line}");
        self.state().log.push(line);
    }

    async fn serve(&self, stream: tokio::net::TcpStream) -> std::io::Result<()> {
        let mut reader = BufReader::new(stream);
        while let Some(request) = http::read_request(&mut reader).await? {
            if self.state().down {
                http::write_response(reader.get_mut(), &Response::text(502, "Bad Gateway"), true).await?;
                return Ok(());
            }
            if request.path() == "/v3/provisioning_session" && request.wants_websocket() {
                let mut stream = reader.into_inner();
                http::accept_websocket(&mut stream, &request).await?;
                let ws = WebSocketStream::from_raw_socket(stream, Role::Server, None).await;
                return self.provision(ws).await;
            }
            let response = self.answer(&request);
            http::write_response(reader.get_mut(), &response, false).await?;
        }
        Ok(())
    }

    fn answer(&self, request: &Request) -> Response {
        match (request.method.as_str(), request.path()) {
            ("GET", "/v3/client_info") => Response::json(&serde_json::json!({
                "client_info": "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>",
                "user_agent": "akd/1.0 CFNetwork/808.1.4"
            })),
            ("POST", "/v3/get_headers") => {
                let body: serde_json::Value = serde_json::from_slice(&request.body).unwrap_or_default();
                let identifier = body["identifier"].as_str().unwrap_or("").to_string();
                let adi_pb = body["adi_pb"].as_str().unwrap_or("").to_string();
                let mut state = self.state();
                if state.forget_next {
                    state.forget_next = false;
                    state.provisioned.clear();
                }
                match state.provisioned.get(&identifier) {
                    Some((pb, tk)) if *pb == adi_pb => {
                        let machine = machine_id(tk);
                        drop(state);
                        Response::json(&serde_json::json!({
                            "result": "Headers",
                            "X-Apple-I-MD-M": machine,
                            "X-Apple-I-MD": BASE64_STANDARD.encode(random_bytes(16)),
                            "X-Apple-I-MD-RINFO": "17106176"
                        }))
                    }
                    _ => {
                        drop(state);
                        self.note("headers for a machine it does not know: -45061");
                        Response::json(&serde_json::json!({
                            "result": "GetHeadersError",
                            "message": "ADIOTPRequest failed: -45061"
                        }))
                    }
                }
            }
            (method, path) => Response::text(404, &format!("no {method} {path}")),
        }
    }

    async fn provision(&self, mut ws: WebSocketStream<tokio::net::TcpStream>) -> std::io::Result<()> {
        async fn ask(
            ws: &mut WebSocketStream<tokio::net::TcpStream>,
            message: serde_json::Value,
        ) -> Option<serde_json::Value> {
            ws.send(Message::Text(message.to_string().into())).await.ok()?;
            loop {
                match ws.next().await? {
                    Ok(Message::Text(t)) => return serde_json::from_str(t.as_str()).ok(),
                    Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => continue,
                    _ => return None,
                }
            }
        }
        let Some(identifier) = ask(&mut ws, serde_json::json!({"result": "GiveIdentifier"})).await else {
            return Ok(());
        };
        let identifier = identifier["identifier"].as_str().unwrap_or("").to_string();
        if BASE64_STANDARD.decode(&identifier).map(|b| b.len()) != Ok(16) {
            let _ = ws.send(Message::Text(serde_json::json!({"result": "InvalidIdentifier"}).to_string().into())).await;
            return Ok(());
        }
        let Some(start) = ask(&mut ws, serde_json::json!({"result": "GiveStartProvisioningData"})).await else {
            return Ok(());
        };
        let spim = start["spim"].as_str().unwrap_or("").to_string();
        let Some(end) = ask(
            &mut ws,
            serde_json::json!({"result": "GiveEndProvisioningData", "cpim": cpim_for(&spim)}),
        )
        .await
        else {
            return Ok(());
        };
        let tk = end["tk"].as_str().unwrap_or("").to_string();
        if tk.is_empty() || end["ptm"].as_str().unwrap_or("").is_empty() {
            let _ = ws
                .send(Message::Text(
                    serde_json::json!({"result": "EndProvisioningError", "message": "no ptm or tk"}).to_string().into(),
                ))
                .await;
            return Ok(());
        }
        let adi_pb = BASE64_STANDARD.encode(random_bytes(48));
        {
            let mut state = self.state();
            state.provisioned.insert(identifier, (adi_pb.clone(), tk));
            state.provisionings += 1;
        }
        self.note("machine provisioned");
        let _ = ws
            .send(Message::Text(serde_json::json!({"result": "ProvisioningSuccess", "adi_pb": adi_pb}).to_string().into()))
            .await;
        // The client closes once it has its adi_pb.
        while let Some(Ok(message)) = ws.next().await {
            if message.is_close() {
                break;
            }
        }
        Ok(())
    }
}
