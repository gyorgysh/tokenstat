// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Durable unresolved ownership beside kernel writer locks. Identity requests
//! include shared ancestors, so a lost guardian also fences parent-folder
//! writers and linked checkouts without blocking independent siblings.

use super::{Error, Lease, file};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    io::{Read, Seek, Write},
    time::{Duration, Instant},
};

const MAX_BYTES: u64 = 4 * 1024 * 1024;
const CAPACITY: usize = 4096;

#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Index {
    version: u32,
    claims: BTreeMap<String, Vec<(String, bool)>>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    digest: String,
    payload: Index,
}
fn digest(index: &Index) -> Result<String, Error> {
    let bytes = serde_json::to_vec(index).map_err(|_| Error::Unavailable)?;
    Ok(Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}
fn valid(id: &str) -> bool {
    id.len() == 64
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn requests(lease: &Lease) -> Vec<(String, bool)> {
    let mut all = lease.target.requests();
    if let Some((_, target)) = &lease.additional {
        all.extend(target.requests());
    }
    let mut merged = BTreeMap::new();
    for (identity, exclusive) in all {
        let flag = merged.entry(identity.name()).or_insert(false);
        *flag |= exclusive;
    }
    merged.into_iter().collect()
}
fn marker_ready(lease: &Lease) -> Result<bool, Error> {
    match std::fs::symlink_metadata(lease.root.path.join("claims.initialized")) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        _ => Err(Error::RecoveryRequired),
    }
}
fn gate(lease: &Lease) -> Result<File, Error> {
    let path = lease.root.path.join("claims.lock");
    // A removed registry must not be recreated as an empty one. Creating the
    // file first would make the absence look like a fresh store.
    match std::fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            if marker_ready(lease)? {
                return Err(Error::RecoveryRequired);
            }
        }
        Ok(metadata) if !metadata.is_file() || metadata.file_type().is_symlink() => {
            return Err(Error::RecoveryRequired);
        }
        Ok(_) => {}
        Err(_) => return Err(Error::Unavailable),
    }
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match file::lock(&path, true) {
            Err(Error::Busy) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(5))
            }
            result => return result,
        }
    }
}
fn read(lease: &Lease, file: &mut File) -> Result<Index, Error> {
    let length = file.metadata().map_err(|_| Error::Unavailable)?.len();
    if length == 0 {
        return if marker_ready(lease)? {
            Err(Error::RecoveryRequired)
        } else {
            Ok(Index {
                version: 1,
                ..Index::default()
            })
        };
    }
    if length > MAX_BYTES {
        return Err(Error::RecoveryRequired);
    }
    file.rewind().map_err(|_| Error::Unavailable)?;
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::Unavailable)?;
    let stored: Stored = serde_json::from_slice(&bytes).map_err(|_| Error::RecoveryRequired)?;
    if !valid(&stored.digest) || digest(&stored.payload)? != stored.digest {
        return Err(Error::RecoveryRequired);
    }
    let index = stored.payload;
    if bytes.len() as u64 > MAX_BYTES
        || index.version != 1
        || index.claims.len() > CAPACITY
        || index.claims.iter().any(|(id, req)| {
            !valid(id)
                || req.is_empty()
                || req.len() > 260
                || !req.iter().any(|(_, exclusive)| *exclusive)
                || req.windows(2).any(|pair| pair[0].0 >= pair[1].0)
                || req
                    .iter()
                    .any(|(name, _)| !name.strip_suffix(".lock").is_some_and(valid))
        })
    {
        return Err(Error::RecoveryRequired);
    }
    Ok(index)
}
fn check_index(lease: &Lease, index: &Index) -> Result<(), Error> {
    let wanted = requests(lease);
    if let Some(id) = &lease.claim
        && index.claims.get(id) != Some(&wanted)
    {
        return Err(Error::Changed);
    }
    for (id, req) in &index.claims {
        if lease.claim.as_ref() == Some(id) {
            continue;
        }
        if wanted.iter().any(|(name, exclusive)| {
            req.binary_search_by(|(other, _)| other.cmp(name))
                .is_ok_and(|position| *exclusive || req[position].1)
        }) {
            return Err(Error::RecoveryRequired);
        }
    }
    Ok(())
}
pub(super) fn check(lease: &Lease) -> Result<(), Error> {
    let mut file = gate(lease)?;
    check_index(lease, &read(lease, &mut file)?)
}
fn write(lease: &Lease, file: &mut File, index: &Index) -> Result<(), Error> {
    let bytes = serde_json::to_vec(&serde_json::json!({"digest":digest(index)?,"payload":index}))
        .map_err(|_| Error::Unavailable)?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(Error::Unavailable);
    }
    // A torn in-place registry is intentionally unreadable. The independent
    // durable marker prevents a zero-length interruption becoming emptiness.
    let marker = lease.root.path.join("claims.initialized");
    match std::fs::symlink_metadata(&marker) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
            }
            let created = options.open(marker).map_err(|_| Error::Unavailable)?;
            created.sync_all().map_err(|_| Error::Unavailable)?;
            #[cfg(unix)]
            lease
                .root
                ._handle
                .sync_all()
                .map_err(|_| Error::Unavailable)?;
        }
        Ok(m) if m.is_file() && !m.file_type().is_symlink() => {}
        _ => return Err(Error::RecoveryRequired),
    }
    file.rewind().map_err(|_| Error::Unavailable)?;
    file.write_all(&bytes).map_err(|_| Error::Unavailable)?;
    file.set_len(bytes.len() as u64)
        .map_err(|_| Error::Unavailable)?;
    file.sync_all().map_err(|_| Error::Unavailable)
}
impl Lease {
    /// Persist before a Team backend can be born. Drop never clears a claim.
    /// Only opaque run incarnations and filesystem identity hashes are stored.
    pub fn claim_run(&mut self, id: &str) -> Result<(), Error> {
        if !valid(id) || self.claim.is_some() {
            return Err(Error::Changed);
        }
        self.ensure_current()?;
        let mut file = gate(self)?;
        let mut index = read(self, &mut file)?;
        check_index(self, &index)?;
        if index.claims.len() >= CAPACITY || index.claims.contains_key(id) {
            return Err(Error::RecoveryRequired);
        }
        index.claims.insert(id.into(), requests(self));
        self.claim = Some(id.into());
        write(self, &mut file, &index)
    }
    /// The caller must already prove exact process completion or definite
    /// failure before birth. This low-level storage method supplies no proof.
    pub fn clear_completed_run(&mut self, id: &str) -> Result<(), Error> {
        if self.claim.as_deref() != Some(id) {
            return Err(Error::Changed);
        }
        self.ensure_current()?;
        let mut file = gate(self)?;
        let mut index = read(self, &mut file)?;
        check_index(self, &index)?;
        index.claims.remove(id);
        write(self, &mut file, &index)?;
        self.claim = None;
        Ok(())
    }
}
