//! A fake usbmuxd on a TCP port: lists the fake iPhones plugged in, hands out
//! their pair records, and connects to their services.

use std::{
    io,
    net::SocketAddr,
    sync::{Arc, Mutex},
};

use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};

use super::{FakeIphone, Service};
use crate::dict;

/// usbmuxd on 127.0.0.1, with the iPhones plugged in.
#[derive(Clone)]
pub struct FakeUsbmuxd {
    addr: SocketAddr,
    iphones: Arc<Mutex<Vec<FakeIphone>>>,
    buid: String,
}

impl FakeUsbmuxd {
    pub async fn start() -> io::Result<Self> {
        Self::start_at("127.0.0.1:0".parse().expect("address")).await
    }

    /// On a port chosen beforehand: for USBMUXD_SOCKET_ADDRESS, set before
    /// anything runs.
    pub async fn start_at(addr: SocketAddr) -> io::Result<Self> {
        let listener = TcpListener::bind(addr).await?;
        let muxd = FakeUsbmuxd {
            addr: listener.local_addr()?,
            iphones: Arc::new(Mutex::new(Vec::new())),
            buid: uuid::Uuid::new_v4().to_string().to_uppercase(),
        };
        let accept = muxd.clone();
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                // Lockdown and AFC answer in small writes: without this, each
                // waits for the installer's delayed acknowledgement.
                let _ = stream.set_nodelay(true);
                let muxd = accept.clone();
                tokio::spawn(async move {
                    if let Err(e) = muxd.serve(stream).await {
                        tracing::debug!("fake usbmuxd: connection ended: {e}");
                    }
                });
            }
        });
        Ok(muxd)
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    pub fn plug(&self, iphone: &FakeIphone) {
        iphone.state().unplugged = false;
        let mut iphones = self.iphones.lock().unwrap();
        if !iphones.iter().any(|i| i.udid() == iphone.udid()) {
            iphones.push(iphone.clone());
        }
    }

    pub fn unplug(&self, iphone: &FakeIphone) {
        iphone.state().unplugged = true;
    }

    fn plugged(&self) -> Vec<FakeIphone> {
        self.iphones
            .lock()
            .unwrap()
            .iter()
            .filter(|i| !i.state().unplugged)
            .cloned()
            .collect()
    }

    async fn serve(&self, mut stream: TcpStream) -> io::Result<()> {
        loop {
            let mut header = [0u8; 16];
            match stream.read_exact(&mut header).await {
                Ok(_) => {}
                Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
                Err(e) => return Err(e),
            }
            let size = u32::from_le_bytes(header[0..4].try_into().unwrap()) as usize;
            let tag = u32::from_le_bytes(header[12..16].try_into().unwrap());
            if size < 16 {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "short usbmuxd packet"));
            }
            let mut body = vec![0u8; size - 16];
            stream.read_exact(&mut body).await?;
            let request: plist::Dictionary = plist::from_bytes(&body)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            let kind = request
                .get("MessageType")
                .and_then(|v| v.as_string())
                .unwrap_or("")
                .to_string();
            match kind.as_str() {
                "ListDevices" => {
                    let list: Vec<plist::Value> = self
                        .plugged()
                        .iter()
                        .map(|i| {
                            let c = i.config();
                            plist::Value::Dictionary(dict! {
                                "DeviceID" => c.device_id,
                                "MessageType" => "Attached",
                                "Properties" => plist::Value::Dictionary(dict! {
                                    "ConnectionSpeed" => 480000000u64,
                                    "ConnectionType" => "USB",
                                    "DeviceID" => c.device_id,
                                    "LocationID" => 0x0110_0000u64 + c.device_id as u64,
                                    "ProductID" => 0x12a8u64,
                                    "SerialNumber" => c.udid.clone(),
                                    "USBSerialNumber" => c.udid.replace('-', ""),
                                }),
                            })
                        })
                        .collect();
                    send(&mut stream, tag, dict! { "DeviceList" => list }).await?;
                }
                "Listen" => {
                    send(&mut stream, tag, dict! { "MessageType" => "Result", "Number" => 0u64 }).await?;
                }
                "ReadBUID" => {
                    send(&mut stream, tag, dict! { "BUID" => self.buid.clone() }).await?;
                }
                "ReadPairRecord" => {
                    let udid = request
                        .get("PairRecordID")
                        .and_then(|v| v.as_string())
                        .unwrap_or("");
                    let record = self
                        .plugged()
                        .into_iter()
                        .find(|i| i.udid() == udid)
                        .filter(|i| i.state().usbmuxd_pair_record)
                        .map(|i| i.pair_record());
                    match record {
                        Some(record) => {
                            let data = crate::wire::xml(&record);
                            send(&mut stream, tag, dict! { "PairRecordData" => plist::Value::Data(data) }).await?;
                        }
                        None => {
                            send(&mut stream, tag, dict! { "MessageType" => "Result", "Number" => 2u64 }).await?;
                        }
                    }
                }
                "Connect" => {
                    let device_id = request
                        .get("DeviceID")
                        .and_then(|v| v.as_unsigned_integer())
                        .unwrap_or(u64::MAX);
                    let port = request
                        .get("PortNumber")
                        .and_then(|v| v.as_unsigned_integer().or(v.as_signed_integer().map(|s| s as u64)))
                        .map(|p| u16::from_be(p as u16))
                        .unwrap_or(0);
                    let iphone = self
                        .plugged()
                        .into_iter()
                        .find(|i| i.config().device_id as u64 == device_id);
                    let Some(iphone) = iphone else {
                        send(&mut stream, tag, dict! { "MessageType" => "Result", "Number" => 2u64 }).await?;
                        continue;
                    };
                    let service = if port == 62078 {
                        None
                    } else {
                        match iphone.take_service(port) {
                            Some(s) => Some(s),
                            None => {
                                send(&mut stream, tag, dict! { "MessageType" => "Result", "Number" => 3u64 }).await?;
                                continue;
                            }
                        }
                    };
                    send(&mut stream, tag, dict! { "MessageType" => "Result", "Number" => 0u64 }).await?;
                    return match service {
                        None => super::lockdown::serve(iphone, stream).await,
                        Some(Service::Afc) => super::afc::serve_media(iphone, stream).await,
                        Some(Service::InstallationProxy) => super::instproxy::serve(iphone, stream).await,
                        Some(Service::HouseArrest) => super::instproxy::serve_house_arrest(iphone, stream).await,
                        Some(Service::RemotePairing) => super::rppairing::serve(iphone, stream).await,
                    };
                }
                other => {
                    tracing::debug!("fake usbmuxd: unknown message {other}");
                    send(&mut stream, tag, dict! { "MessageType" => "Result", "Number" => 1u64 }).await?;
                }
            }
        }
    }
}

async fn send(stream: &mut TcpStream, tag: u32, body: plist::Dictionary) -> io::Result<()> {
    let body = crate::wire::xml(&body);
    let mut packet = Vec::with_capacity(16 + body.len());
    packet.extend_from_slice(&(body.len() as u32 + 16).to_le_bytes());
    packet.extend_from_slice(&1u32.to_le_bytes());
    packet.extend_from_slice(&8u32.to_le_bytes());
    packet.extend_from_slice(&tag.to_le_bytes());
    packet.extend_from_slice(&body);
    stream.write_all(&packet).await?;
    stream.flush().await
}
