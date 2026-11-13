//! Just enough HTTP/1.1 for the fake servers: one request at a time on a
//! connection, bodies by Content-Length, and the switch to a WebSocket.

use std::io;

use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

use crate::wire::Stream;

#[derive(Clone, Debug, Default)]
pub struct Request {
    pub method: String,
    /// The request target as sent: path and query.
    pub target: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    pub fn path(&self) -> &str {
        self.target.split('?').next().unwrap_or("")
    }

    /// A query parameter, percent-decoded.
    pub fn query(&self, key: &str) -> Option<String> {
        let query = self.target.split_once('?')?.1;
        query.split('&').find_map(|pair| {
            let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
            (k == key).then(|| urlencoding::decode(v).map(|v| v.into_owned()).unwrap_or_default())
        })
    }

    pub fn body_text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }

    pub fn wants_websocket(&self) -> bool {
        self.header("upgrade").is_some_and(|v| v.eq_ignore_ascii_case("websocket"))
    }
}

#[derive(Clone, Debug)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn new(status: u16, content_type: &str, body: impl Into<Vec<u8>>) -> Self {
        Response {
            status,
            headers: vec![("Content-Type".into(), content_type.into())],
            body: body.into(),
        }
    }

    pub fn plist(dict: &plist::Dictionary) -> Self {
        Response::new(200, "text/x-xml-plist", crate::wire::xml(dict))
    }

    pub fn json(value: &serde_json::Value) -> Self {
        Response::new(200, "application/json", value.to_string())
    }

    pub fn text(status: u16, text: &str) -> Self {
        Response::new(status, "text/plain", text.as_bytes().to_vec())
    }

    pub fn redirect(location: &str) -> Self {
        let mut r = Response::new(302, "text/html", Vec::new());
        r.headers.push(("Location".into(), location.into()));
        r
    }

    pub fn with_status(mut self, status: u16) -> Self {
        self.status = status;
        self
    }

    pub fn with_header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }
}

fn reason(status: u16) -> &'static str {
    match status {
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        302 => "Found",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        412 => "Precondition Failed",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        _ => "Status",
    }
}

/// Reads one request, or None when the client closed the connection.
pub async fn read_request<S: Stream>(reader: &mut BufReader<S>) -> io::Result<Option<Request>> {
    let mut line = String::new();
    if reader.read_line(&mut line).await? == 0 {
        return Ok(None);
    }
    let mut parts = line.trim_end().splitn(3, ' ');
    let method = parts.next().unwrap_or("").to_string();
    let target = parts.next().unwrap_or("").to_string();
    if method.is_empty() || target.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, format!("bad request line {line:?}")));
    }
    let mut headers = Vec::new();
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header).await? == 0 {
            return Ok(None);
        }
        let header = header.trim_end();
        if header.is_empty() {
            break;
        }
        if let Some((k, v)) = header.split_once(':') {
            headers.push((k.trim().to_string(), v.trim().to_string()));
        }
    }
    let mut request = Request { method, target, headers, body: Vec::new() };
    if request.header("transfer-encoding").is_some_and(|v| v.eq_ignore_ascii_case("chunked")) {
        loop {
            let mut size = String::new();
            reader.read_line(&mut size).await?;
            let size = usize::from_str_radix(size.trim().split(';').next().unwrap_or("0"), 16)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            let mut chunk = vec![0; size + 2];
            reader.read_exact(&mut chunk).await?;
            if size == 0 {
                break;
            }
            request.body.extend_from_slice(&chunk[..size]);
        }
    } else if let Some(len) = request.header("content-length").and_then(|v| v.parse::<usize>().ok()) {
        request.body = vec![0; len];
        reader.read_exact(&mut request.body).await?;
    }
    Ok(Some(request))
}

pub async fn write_response<S: Stream>(stream: &mut S, response: &Response, close: bool) -> io::Result<()> {
    let mut head = format!("HTTP/1.1 {} {}\r\n", response.status, reason(response.status));
    for (k, v) in &response.headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    head.push_str(&format!("Content-Length: {}\r\n", response.body.len()));
    if close {
        head.push_str("Connection: close\r\n");
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(&response.body).await?;
    stream.flush().await
}

/// Answers the switch to a WebSocket the client asked for in `request`.
pub async fn accept_websocket<S: Stream>(stream: &mut S, request: &Request) -> io::Result<()> {
    let key = request
        .header("sec-websocket-key")
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "no Sec-WebSocket-Key"))?;
    let accept = tokio_tungstenite::tungstenite::handshake::derive_accept_key(key.as_bytes());
    let head = format!(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
    );
    stream.write_all(head.as_bytes()).await?;
    stream.flush().await
}

/// Serves requests on one connection with `handler` until the client
/// closes it or asks to.
pub async fn serve<S, F, Fut>(stream: S, handler: F) -> io::Result<()>
where
    S: Stream,
    F: Fn(Request) -> Fut,
    Fut: std::future::Future<Output = Response>,
{
    let mut reader = BufReader::new(stream);
    while let Some(request) = read_request(&mut reader).await? {
        let close = request.header("connection").is_some_and(|v| v.eq_ignore_ascii_case("close"));
        let response = handler(request).await;
        write_response(reader.get_mut(), &response, close).await?;
        if close {
            break;
        }
    }
    Ok(())
}
