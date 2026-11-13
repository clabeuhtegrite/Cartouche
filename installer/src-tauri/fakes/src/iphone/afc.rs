//! AFC, the iPhone's file service: the media folder for com.apple.afc, an
//! app's container for house_arrest. Files live in memory.

use std::{
    collections::{BTreeMap, HashMap},
    io,
};

use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::FakeIphone;
use crate::wire::Stream;

const MAGIC: u64 = 0x4141_504c_3641_4643;

mod op {
    pub const STATUS: u64 = 0x01;
    pub const DATA: u64 = 0x02;
    pub const READ_DIR: u64 = 0x03;
    pub const REMOVE_PATH: u64 = 0x08;
    pub const MAKE_DIR: u64 = 0x09;
    pub const GET_FILE_INFO: u64 = 0x0a;
    pub const GET_DEV_INFO: u64 = 0x0b;
    pub const FILE_OPEN: u64 = 0x0d;
    pub const FILE_OPEN_RES: u64 = 0x0e;
    pub const READ: u64 = 0x0f;
    pub const WRITE: u64 = 0x10;
    pub const FILE_CLOSE: u64 = 0x14;
    pub const REMOVE_PATH_AND_CONTENTS: u64 = 0x22;
}

mod status {
    pub const SUCCESS: u64 = 0;
    pub const INVALID_ARG: u64 = 7;
    pub const OBJECT_NOT_FOUND: u64 = 8;
    pub const OBJECT_IS_DIR: u64 = 9;
    pub const PERM_DENIED: u64 = 10;
    pub const OP_NOT_SUPPORTED: u64 = 15;
    pub const OBJECT_EXISTS: u64 = 16;
    pub const DIR_NOT_EMPTY: u64 = 33;
}

#[derive(Clone, Debug)]
pub enum Node {
    Dir,
    File(Vec<u8>),
}

/// A filesystem in memory, by path without a leading slash.
#[derive(Clone, Debug, Default)]
pub struct MemFs {
    nodes: BTreeMap<String, Node>,
}

fn normalize(path: &str) -> Result<String, u64> {
    let mut parts = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => return Err(status::PERM_DENIED),
            p => parts.push(p),
        }
    }
    Ok(parts.join("/"))
}

fn parent(path: &str) -> &str {
    path.rsplit_once('/').map(|(p, _)| p).unwrap_or("")
}

impl MemFs {
    fn is_dir(&self, path: &str) -> bool {
        path.is_empty() || matches!(self.nodes.get(path), Some(Node::Dir))
    }

    /// Makes a folder and its parents, as AFC's MakeDir does.
    pub fn mkdir_p(&mut self, path: &str) -> Result<(), u64> {
        let path = normalize(path)?;
        let mut current = String::new();
        for part in path.split('/').filter(|p| !p.is_empty()) {
            if !current.is_empty() {
                current.push('/');
            }
            current.push_str(part);
            match self.nodes.get(&current) {
                Some(Node::Dir) => {}
                Some(Node::File(_)) => return Err(status::OBJECT_EXISTS),
                None => {
                    self.nodes.insert(current.clone(), Node::Dir);
                }
            }
        }
        Ok(())
    }

    pub fn write(&mut self, path: &str, data: Vec<u8>) -> Result<(), u64> {
        let path = normalize(path)?;
        if !self.is_dir(parent(&path)) {
            return Err(status::OBJECT_NOT_FOUND);
        }
        if matches!(self.nodes.get(&path), Some(Node::Dir)) {
            return Err(status::OBJECT_IS_DIR);
        }
        self.nodes.insert(path, Node::File(data));
        Ok(())
    }

    pub fn read(&self, path: &str) -> Result<Vec<u8>, u64> {
        match self.nodes.get(&normalize(path)?) {
            Some(Node::File(data)) => Ok(data.clone()),
            Some(Node::Dir) => Err(status::OBJECT_IS_DIR),
            None => Err(status::OBJECT_NOT_FOUND),
        }
    }

    fn file_mut(&mut self, path: &str) -> Result<&mut Vec<u8>, u64> {
        match self.nodes.get_mut(&normalize(path)?) {
            Some(Node::File(data)) => Ok(data),
            Some(Node::Dir) => Err(status::OBJECT_IS_DIR),
            None => Err(status::OBJECT_NOT_FOUND),
        }
    }

    pub fn exists(&self, path: &str) -> bool {
        normalize(path).is_ok_and(|p| p.is_empty() || self.nodes.contains_key(&p))
    }

    /// The files under a folder, by their path inside it.
    pub fn files_under(&self, dir: &str) -> BTreeMap<String, Vec<u8>> {
        let Ok(dir) = normalize(dir) else {
            return BTreeMap::new();
        };
        let prefix = if dir.is_empty() { String::new() } else { format!("{dir}/") };
        self.nodes
            .iter()
            .filter_map(|(path, node)| match node {
                Node::File(data) => path
                    .strip_prefix(&prefix)
                    .map(|rel| (rel.to_string(), data.clone())),
                Node::Dir => None,
            })
            .collect()
    }

    fn list(&self, dir: &str) -> Result<Vec<String>, u64> {
        let dir = normalize(dir)?;
        if !self.is_dir(&dir) {
            return Err(status::OBJECT_NOT_FOUND);
        }
        let prefix = if dir.is_empty() { String::new() } else { format!("{dir}/") };
        let mut names = vec![".".to_string(), "..".to_string()];
        names.extend(self.nodes.keys().filter_map(|path| {
            path.strip_prefix(&prefix)
                .filter(|rest| !rest.is_empty() && !rest.contains('/'))
                .map(str::to_string)
        }));
        Ok(names)
    }

    pub fn remove(&mut self, path: &str, recursive: bool) -> Result<(), u64> {
        let path = normalize(path)?;
        if !self.nodes.contains_key(&path) {
            return Err(status::OBJECT_NOT_FOUND);
        }
        let prefix = format!("{path}/");
        let children: Vec<String> = self
            .nodes
            .keys()
            .filter(|p| p.starts_with(&prefix))
            .cloned()
            .collect();
        if !children.is_empty() && !recursive {
            return Err(status::DIR_NOT_EMPTY);
        }
        for child in children {
            self.nodes.remove(&child);
        }
        self.nodes.remove(&path);
        Ok(())
    }
}

/// Which files an AFC connection reaches.
#[derive(Clone)]
pub enum Root {
    Media,
    /// An app's container, from house_arrest's VendDocuments: only its
    /// Documents can be written.
    Documents(String),
}

struct OpenFile {
    path: String,
    pos: usize,
    write: bool,
}

pub async fn serve_media<S: Stream>(iphone: FakeIphone, stream: S) -> io::Result<()> {
    serve(iphone, stream, Root::Media).await
}

fn with_fs<T>(iphone: &FakeIphone, root: &Root, f: impl FnOnce(&mut MemFs) -> Result<T, u64>) -> Result<T, u64> {
    let mut state = iphone.state();
    match root {
        Root::Media => f(&mut state.media),
        Root::Documents(bundle_id) => match state.apps.get_mut(bundle_id) {
            Some(app) => f(&mut app.container),
            None => Err(status::OBJECT_NOT_FOUND),
        },
    }
}

fn writable(root: &Root, path: &str) -> bool {
    match root {
        Root::Media => true,
        Root::Documents(_) => normalize(path).is_ok_and(|p| p == "Documents" || p.starts_with("Documents/")),
    }
}

fn c_string(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

fn u64_at(bytes: &[u8], at: usize) -> u64 {
    bytes
        .get(at..at + 8)
        .map(|b| u64::from_le_bytes(b.try_into().unwrap()))
        .unwrap_or(0)
}

pub async fn serve<S: Stream>(iphone: FakeIphone, mut stream: S, root: Root) -> io::Result<()> {
    let mut files: HashMap<u64, OpenFile> = HashMap::new();
    let mut next_fd = 3u64;
    loop {
        let mut header = [0u8; 40];
        match stream.read_exact(&mut header).await {
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(e) => return Err(e),
        }
        let magic = u64_at(&header, 0);
        let entire_len = u64_at(&header, 8) as usize;
        let header_len = u64_at(&header, 16) as usize;
        let packet_num = u64_at(&header, 24);
        let operation = u64_at(&header, 32);
        if magic != MAGIC || header_len < 40 || entire_len < header_len {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "bad AFC header"));
        }
        let mut header_payload = vec![0u8; header_len - 40];
        stream.read_exact(&mut header_payload).await?;
        let mut payload = vec![0u8; entire_len - header_len];
        stream.read_exact(&mut payload).await?;

        let reply: (u64, Vec<u8>, Vec<u8>) = match operation {
            op::MAKE_DIR => {
                let path = c_string(&header_payload);
                let result = if writable(&root, &path) {
                    with_fs(&iphone, &root, |fs| fs.mkdir_p(&path))
                } else {
                    Err(status::PERM_DENIED)
                };
                status_reply(result.err().unwrap_or(status::SUCCESS))
            }
            op::FILE_OPEN => {
                let mode = u64_at(&header_payload, 0);
                let path = c_string(header_payload.get(8..).unwrap_or(&[]));
                let write = mode != 1;
                let result = with_fs(&iphone, &root, |fs| {
                    if write && !writable(&root, &path) {
                        return Err(status::PERM_DENIED);
                    }
                    match mode {
                        1 => fs.read(&path).map(|_| 0),
                        2 | 5 | 6 => match fs.read(&path) {
                            Ok(data) => Ok(if mode == 2 { 0 } else { data.len() }),
                            Err(status::OBJECT_NOT_FOUND) => fs.write(&path, Vec::new()).map(|_| 0),
                            Err(e) => Err(e),
                        },
                        3 | 4 => fs.write(&path, Vec::new()).map(|_| 0),
                        _ => Err(status::INVALID_ARG),
                    }
                });
                match result {
                    Ok(pos) => {
                        let fd = next_fd;
                        next_fd += 1;
                        files.insert(fd, OpenFile { path: normalize(&path).unwrap_or_default(), pos, write });
                        (op::FILE_OPEN_RES, fd.to_le_bytes().to_vec(), Vec::new())
                    }
                    Err(code) => status_reply(code),
                }
            }
            op::WRITE => {
                let fd = u64_at(&header_payload, 0);
                match files.get_mut(&fd) {
                    Some(file) if file.write => {
                        let path = file.path.clone();
                        let pos = file.pos;
                        let result = with_fs(&iphone, &root, |fs| {
                            let data = fs.file_mut(&path)?;
                            if data.len() < pos + payload.len() {
                                data.resize(pos + payload.len(), 0);
                            }
                            data[pos..pos + payload.len()].copy_from_slice(&payload);
                            Ok(())
                        });
                        if result.is_ok() {
                            file.pos += payload.len();
                        }
                        status_reply(result.err().unwrap_or(status::SUCCESS))
                    }
                    Some(_) => status_reply(status::PERM_DENIED),
                    None => status_reply(status::INVALID_ARG),
                }
            }
            op::READ => {
                let fd = u64_at(&header_payload, 0);
                let len = u64_at(&header_payload, 8) as usize;
                match files.get_mut(&fd) {
                    Some(file) => {
                        let path = file.path.clone();
                        match with_fs(&iphone, &root, |fs| fs.read(&path)) {
                            Ok(data) => {
                                let start = file.pos.min(data.len());
                                let end = (start + len).min(data.len());
                                file.pos = end;
                                (op::DATA, Vec::new(), data[start..end].to_vec())
                            }
                            Err(code) => status_reply(code),
                        }
                    }
                    None => status_reply(status::INVALID_ARG),
                }
            }
            op::FILE_CLOSE => {
                let fd = u64_at(&header_payload, 0);
                status_reply(if files.remove(&fd).is_some() { status::SUCCESS } else { status::INVALID_ARG })
            }
            op::READ_DIR => {
                let path = c_string(&header_payload);
                match with_fs(&iphone, &root, |fs| fs.list(&path)) {
                    Ok(names) => {
                        let mut data = Vec::new();
                        for name in names {
                            data.extend_from_slice(name.as_bytes());
                            data.push(0);
                        }
                        (op::DATA, Vec::new(), data)
                    }
                    Err(code) => status_reply(code),
                }
            }
            op::GET_FILE_INFO => {
                let path = c_string(&header_payload);
                let info = with_fs(&iphone, &root, |fs| {
                    let p = normalize(&path)?;
                    if fs.is_dir(&p) {
                        Ok(("S_IFDIR", 0usize))
                    } else {
                        fs.read(&p).map(|d| ("S_IFREG", d.len()))
                    }
                });
                match info {
                    Ok((kind, size)) => {
                        let mut data = Vec::new();
                        for (k, v) in [
                            ("st_size", size.to_string()),
                            ("st_blocks", size.div_ceil(512).to_string()),
                            ("st_nlink", "1".to_string()),
                            ("st_ifmt", kind.to_string()),
                            ("st_mtime", "1762300000000000000".to_string()),
                            ("st_birthtime", "1762300000000000000".to_string()),
                        ] {
                            data.extend_from_slice(k.as_bytes());
                            data.push(0);
                            data.extend_from_slice(v.as_bytes());
                            data.push(0);
                        }
                        (op::DATA, Vec::new(), data)
                    }
                    Err(code) => status_reply(code),
                }
            }
            op::GET_DEV_INFO => {
                let mut data = Vec::new();
                for (k, v) in [
                    ("Model", iphone.config().product_type.clone()),
                    ("FSTotalBytes", "255000000000".to_string()),
                    ("FSFreeBytes", "100000000000".to_string()),
                    ("FSBlockSize", "4096".to_string()),
                ] {
                    data.extend_from_slice(k.as_bytes());
                    data.push(0);
                    data.extend_from_slice(v.as_bytes());
                    data.push(0);
                }
                (op::DATA, Vec::new(), data)
            }
            op::REMOVE_PATH | op::REMOVE_PATH_AND_CONTENTS => {
                let path = c_string(&header_payload);
                let result = if writable(&root, &path) {
                    with_fs(&iphone, &root, |fs| fs.remove(&path, operation == op::REMOVE_PATH_AND_CONTENTS))
                } else {
                    Err(status::PERM_DENIED)
                };
                status_reply(result.err().unwrap_or(status::SUCCESS))
            }
            other => {
                iphone.note(format!("afc: unsupported operation {other:#x}"));
                status_reply(status::OP_NOT_SUPPORTED)
            }
        };

        let (operation, header_payload, payload) = reply;
        let header_len = 40 + header_payload.len() as u64;
        let mut packet = Vec::with_capacity(header_len as usize + payload.len());
        packet.extend_from_slice(&MAGIC.to_le_bytes());
        packet.extend_from_slice(&(header_len + payload.len() as u64).to_le_bytes());
        packet.extend_from_slice(&header_len.to_le_bytes());
        packet.extend_from_slice(&packet_num.to_le_bytes());
        packet.extend_from_slice(&operation.to_le_bytes());
        packet.extend_from_slice(&header_payload);
        packet.extend_from_slice(&payload);
        stream.write_all(&packet).await?;
        stream.flush().await?;
    }
}

fn status_reply(code: u64) -> (u64, Vec<u8>, Vec<u8>) {
    (op::STATUS, code.to_le_bytes().to_vec(), Vec::new())
}
