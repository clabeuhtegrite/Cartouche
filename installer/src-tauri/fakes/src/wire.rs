//! Framing shared by the fake iPhone's services: lockdown and its services
//! send a plist after its length, as four big-endian bytes.

use std::io;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Any stream a service can run on: a plain connection or one in TLS.
pub trait Stream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Stream for T {}

/// Reads one length-prefixed plist. `None` when the other side closed.
pub async fn read_plist<S: AsyncRead + Unpin>(stream: &mut S) -> io::Result<Option<plist::Dictionary>> {
    let mut len = [0u8; 4];
    match stream.read_exact(&mut len).await {
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes(len) as usize;
    if len > 64 * 1024 * 1024 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "plist too large"));
    }
    let mut body = vec![0u8; len];
    stream.read_exact(&mut body).await?;
    plist::from_bytes(&body)
        .map(Some)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

/// Writes one length-prefixed XML plist, as lockdownd does.
pub async fn write_plist<S: AsyncWrite + Unpin>(stream: &mut S, value: &plist::Dictionary) -> io::Result<()> {
    let body = xml(value);
    stream.write_all(&(body.len() as u32).to_be_bytes()).await?;
    stream.write_all(&body).await?;
    stream.flush().await
}

pub fn xml(value: &plist::Dictionary) -> Vec<u8> {
    let mut out = Vec::new();
    plist::Value::Dictionary(value.clone())
        .to_writer_xml(&mut out)
        .expect("a dictionary always writes");
    out
}

/// A dictionary from pairs, for answers.
#[macro_export]
macro_rules! dict {
    ($($key:expr => $value:expr),* $(,)?) => {{
        #[allow(unused_mut)]
        let mut d = plist::Dictionary::new();
        $(d.insert(String::from($key), plist::Value::from($value));)*
        d
    }};
}

pub fn get_str<'a>(d: &'a plist::Dictionary, key: &str) -> Option<&'a str> {
    d.get(key).and_then(|v| v.as_string())
}
