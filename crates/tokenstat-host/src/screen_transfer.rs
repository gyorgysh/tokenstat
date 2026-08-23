// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Resumable files attached to an authorized screen relationship.

use std::collections::{HashMap, hash_map::Entry};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const CHUNK_BYTES: usize = 256 * 1024;
const MAX_FILE_BYTES: u64 = 10 * 1024 * 1024 * 1024;

#[derive(Clone)]
struct Transfer {
    temporary: PathBuf,
    destination: PathBuf,
    size: u64,
    digest: String,
}

fn transfers() -> &'static Mutex<HashMap<String, Arc<Mutex<Transfer>>>> {
    static VALUE: OnceLock<Mutex<HashMap<String, Arc<Mutex<Transfer>>>>> = OnceLock::new();
    VALUE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn setting_path() -> Result<PathBuf, String> {
    tokenstat_identity::identity_dir()
        .map(|path| path.join("screen-transfer-destination"))
        .map_err(|error| error.to_string())
}

fn destination() -> Result<PathBuf, String> {
    let value = fs::read_to_string(setting_path()?)
        .map_err(|_| "Choose an incoming-file destination on the host first".to_string())?;
    let path = PathBuf::from(value.trim())
        .canonicalize()
        .map_err(|e| e.to_string())?;
    if !path.is_dir() {
        return Err("The incoming-file destination is no longer a directory".into());
    }
    Ok(path)
}

fn safe_name(name: &str) -> Result<&str, String> {
    let name = name.trim();
    let path = Path::new(name);
    if name.is_empty()
        || name.len() > 255
        || matches!(name, "." | "..")
        || path.components().count() != 1
        || path.file_name().and_then(|value| value.to_str()) != Some(name)
    {
        return Err("file name must be a plain name without a path".into());
    }
    Ok(name)
}

fn safe_id(id: &str) -> Result<&str, String> {
    if id.is_empty()
        || id.len() > 64
        || !id
            .bytes()
            .all(|value| value.is_ascii_alphanumeric() || value == b'-')
    {
        return Err("transfer id is invalid".into());
    }
    Ok(id)
}

fn remote_peer() -> Result<String, String> {
    let peer = crate::request_context::remote_peer()
        .ok_or("file transfer must arrive over an authenticated remote connection")?;
    crate::screen_policy::verify_transfer_peer(&peer)?;
    Ok(peer)
}

fn transfer_key(peer: &str, id: &str) -> String {
    format!("{peer}\0{id}")
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DestinationParams {
    path: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OpenParams {
    id: String,
    name: String,
    size: u64,
    digest: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChunkParams {
    id: String,
    offset: u64,
    data: String,
}
#[derive(Deserialize)]
struct IdParams {
    id: String,
}

pub(crate) fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("screen.transfer.") {
        return None;
    }
    Some(match method {
        "screen.transfer.destination.get" => destination_get(),
        "screen.transfer.destination.set" => destination_set(params),
        "screen.transfer.open" => open(params),
        "screen.transfer.chunk" => chunk(params),
        "screen.transfer.finish" => finish(params),
        "screen.transfer.cancel" => cancel(params),
        _ => Err(format!("unknown screen transfer method: {method}")),
    })
}

fn destination_get() -> Result<Value, String> {
    if crate::request_context::remote_peer().is_some() {
        return Err("destination settings are local-only".into());
    }
    Ok(json!({"path":destination().ok().map(|path| path.to_string_lossy().into_owned())}))
}

fn destination_set(params: &str) -> Result<Value, String> {
    if crate::request_context::remote_peer().is_some() {
        return Err("destination settings are local-only".into());
    }
    let p: DestinationParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
    let path = PathBuf::from(p.path)
        .canonicalize()
        .map_err(|e| e.to_string())?;
    if !path.is_dir() {
        return Err("incoming-file destination must be a directory".into());
    }
    fs::write(setting_path()?, path.to_string_lossy().as_bytes()).map_err(|e| e.to_string())?;
    Ok(json!({"path":path}))
}

fn open(params: &str) -> Result<Value, String> {
    let peer = remote_peer()?;
    let p: OpenParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
    safe_id(&p.id)?;
    let name = safe_name(&p.name)?;
    if p.size > MAX_FILE_BYTES
        || p.digest.len() != 64
        || !p.digest.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err("file size or SHA-256 digest is invalid".into());
    }
    let directory = destination()?;
    let destination = directory.join(name);
    if destination.exists() {
        return Err("a file with that name already exists at the destination".into());
    }
    let key = Sha256::digest(format!("{}:{}", peer, p.id).as_bytes());
    let temporary = directory.join(format!(
        ".tokenstat-{}.part",
        &tokenstat_identity::hex(key.as_slice())[..24]
    ));
    let metadata = fs::symlink_metadata(&temporary).ok();
    if metadata
        .as_ref()
        .is_some_and(|value| !value.file_type().is_file() || value.file_type().is_symlink())
    {
        return Err("partial transfer path is not a regular file".into());
    }
    let offset = metadata.map(|value| value.len()).unwrap_or(0);
    if offset > p.size {
        return Err("partial file is larger than the offered file".into());
    }
    if offset == 0 && !temporary.exists() {
        OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .map_err(|e| e.to_string())?;
    }
    let offered = Transfer {
        temporary,
        destination,
        size: p.size,
        digest: p.digest.to_ascii_lowercase(),
    };
    let mut registry = transfers()
        .lock()
        .map_err(|_| "transfer registry poisoned")?;
    match registry.entry(transfer_key(&peer, &p.id)) {
        Entry::Vacant(entry) => {
            entry.insert(Arc::new(Mutex::new(offered)));
        }
        Entry::Occupied(entry) => {
            let existing = entry.get().lock().map_err(|_| "transfer poisoned")?;
            if existing.temporary != offered.temporary
                || existing.destination != offered.destination
                || existing.size != offered.size
                || existing.digest != offered.digest
            {
                return Err("transfer id is already open for a different file".into());
            }
        }
    }
    Ok(json!({"id":p.id,"offset":offset,"chunkBytes":CHUNK_BYTES}))
}

fn transfer(id: &str) -> Result<(String, Arc<Mutex<Transfer>>), String> {
    safe_id(id)?;
    let peer = remote_peer()?;
    let key = transfer_key(&peer, id);
    let value = transfers()
        .lock()
        .map_err(|_| "transfer registry poisoned")?
        .get(&key)
        .cloned()
        .ok_or("transfer is not open")?;
    Ok((key, value))
}

fn chunk(params: &str) -> Result<Value, String> {
    let p: ChunkParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
    let (_, transfer) = transfer(&p.id)?;
    let transfer = transfer.lock().map_err(|_| "transfer poisoned")?;
    let bytes = crate::base64::decode(&p.data)?;
    if bytes.is_empty() || bytes.len() > CHUNK_BYTES {
        return Err("file chunk is empty or exceeds 256 KiB".into());
    }
    let offset = fs::metadata(&transfer.temporary)
        .map_err(|e| e.to_string())?
        .len();
    if p.offset != offset || offset.saturating_add(bytes.len() as u64) > transfer.size {
        return Err("file chunk offset or length does not match the receiver".into());
    }
    OpenOptions::new()
        .append(true)
        .open(&transfer.temporary)
        .map_err(|e| e.to_string())?
        .write_all(&bytes)
        .map_err(|e| e.to_string())?;
    Ok(json!({"offset":offset + bytes.len() as u64}))
}

fn finish(params: &str) -> Result<Value, String> {
    let p: IdParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
    let (key, transfer) = transfer(&p.id)?;
    let transfer = transfer.lock().map_err(|_| "transfer poisoned")?;
    if fs::metadata(&transfer.temporary)
        .map_err(|e| e.to_string())?
        .len()
        != transfer.size
    {
        return Err("file transfer is incomplete".into());
    }
    if digest_file(&transfer.temporary)? != transfer.digest {
        return Err("file digest does not match; the partial file was kept for retry".into());
    }
    fs::hard_link(&transfer.temporary, &transfer.destination).map_err(|e| e.to_string())?;
    fs::remove_file(&transfer.temporary).map_err(|e| e.to_string())?;
    let destination = transfer.destination.clone();
    drop(transfer);
    transfers()
        .lock()
        .map_err(|_| "transfer registry poisoned")?
        .remove(&key);
    Ok(json!({"saved":true,"path":destination}))
}

fn digest_file(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; CHUNK_BYTES];
    loop {
        let count = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(tokenstat_identity::hex(hash.finalize().as_slice()))
}

fn cancel(params: &str) -> Result<Value, String> {
    let p: IdParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
    let (key, transfer) = transfer(&p.id)?;
    let transfer = transfer.lock().map_err(|_| "transfer poisoned")?;
    let temporary = transfer.temporary.clone();
    drop(transfer);
    transfers()
        .lock()
        .map_err(|_| "transfer registry poisoned")?
        .remove(&key);
    let removed = match fs::remove_file(&temporary) {
        Ok(()) => true,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
        Err(e) => return Err(e.to_string()),
    };
    Ok(json!({"cancelled":true,"removed":removed}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn names_cannot_escape_destination() {
        assert!(safe_name("report.zip").is_ok());
        assert!(safe_name("../report.zip").is_err());
        assert!(safe_name("folder/report.zip").is_err());
        assert!(safe_name("..").is_err());
    }
    #[test]
    fn ids_are_safe_for_temporary_names() {
        assert!(safe_id("7f8a-transfer-1").is_ok());
        assert!(safe_id("../../escape").is_err());
    }

    #[test]
    fn transfer_ids_are_scoped_to_the_authenticated_peer() {
        assert_ne!(
            transfer_key("phone-a", "same"),
            transfer_key("phone-b", "same")
        );
    }

    #[test]
    fn digest_is_streamed_and_exact() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("payload");
        fs::write(&path, b"abc").unwrap();
        assert_eq!(
            digest_file(&path).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
