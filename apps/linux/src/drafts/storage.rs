// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Bounded private draft records, serialized current-file merges and durable
//! atomic replacement. A damaged store never becomes an empty write target.

use super::{Mutation, Records, coordination::Registration};
use anyhow::{Context, ensure};
use std::os::unix::{
    fs::{OpenOptionsExt, PermissionsExt},
    io::AsRawFd,
};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
};

/// The original store's hard read/write bound; never evict to fit this limit.
pub const MAX_FILE_BYTES: usize = 8 * 1024 * 1024;
/// Explicit memory mode is private to previews and tests, never Mac production data.
#[derive(Clone)]
pub struct Storage {
    directory: Option<PathBuf>,
    memory: Arc<Mutex<Records>>,
    pub byte_limit: usize,
    registration: Option<Registration>,
    unavailable: Option<String>,
}
impl Default for Storage {
    fn default() -> Self {
        Self {
            directory: None,
            memory: Arc::new(Mutex::new(Records::new())),
            byte_limit: MAX_FILE_BYTES,
            registration: None,
            unavailable: None,
        }
    }
}
impl Storage {
    /// Retain an explicit path-resolution failure rather than claiming a save.
    pub fn unavailable(error: String) -> Self {
        Self {
            unavailable: Some(error),
            ..Self::default()
        }
    }
    /// Constructing a disk handle performs no IO; only a worker prepares it.
    pub fn at(directory: PathBuf, byte_limit: usize) -> Self {
        Self {
            registration: Some(Registration::new(directory.clone())),
            directory: Some(directory),
            byte_limit: byte_limit.clamp(1, MAX_FILE_BYTES),
            ..Self::default()
        }
    }
    /// Register original-file participation for the complete handle lifetime.
    pub fn prepare(&self) -> anyhow::Result<()> {
        if let Some(error) = &self.unavailable {
            anyhow::bail!("{error}");
        }
        if let Some(directory) = &self.directory {
            private_directory(directory)?;
        }
        if let Some(registration) = &self.registration {
            registration.get()?;
        }
        Ok(())
    }
    /// Missing means empty; damaged, oversized or special files remain errors.
    pub fn read(&self) -> anyhow::Result<Records> {
        if let Some(error) = &self.unavailable {
            anyhow::bail!("{error}");
        }
        match &self.directory {
            Some(directory) => read(&directory.join("drafts.v1.json"), self.byte_limit),
            None => Ok(self
                .memory
                .lock()
                .map_err(|_| anyhow::anyhow!("Draft memory lock was poisoned"))?
                .clone()),
        }
    }
    /// Every attempt rereads the latest file under the persistent record lock.
    pub fn merge(
        &self,
        pending: &std::collections::BTreeMap<String, Mutation>,
    ) -> anyhow::Result<()> {
        if let Some(error) = &self.unavailable {
            anyhow::bail!("{error}");
        }
        static SERIAL: OnceLock<Mutex<()>> = OnceLock::new();
        let _serial = SERIAL
            .get_or_init(|| Mutex::new(()))
            .lock()
            .map_err(|_| anyhow::anyhow!("Draft writer lock was poisoned"))?;
        let Some(directory) = &self.directory else {
            let mut records = self
                .memory
                .lock()
                .map_err(|_| anyhow::anyhow!("Draft memory lock was poisoned"))?;
            let mut next = records.clone();
            for (key, change) in pending {
                change.apply(key, &mut next);
            }
            if !pending.is_empty() {
                ensure!(
                    encode(&next)?.len() <= self.byte_limit,
                    "Draft store is too large"
                );
                *records = next;
            }
            return Ok(());
        };
        private_directory(directory)?;
        let lock = open_regular(&directory.join("drafts.lock"), true)?;
        record_lock(&lock, true)?;
        let file = directory.join("drafts.v1.json");
        let mut records = read(&file, self.byte_limit)?;
        for (key, change) in pending {
            change.apply(key, &mut records);
        }
        if !pending.is_empty() {
            write(&file, directory, &records, self.byte_limit)?;
        }
        Ok(())
    }
}
/// Failed changes, including deletion, remain pending until the whole merge succeeds.
#[derive(Default)]
pub struct Writer {
    pub pending: std::collections::BTreeMap<String, Mutation>,
    pub failed: bool,
    pub error: Option<String>,
}
impl Writer {
    /// Clear pending changes only after a complete durable current-file merge.
    pub fn flush(&mut self, storage: &Storage) {
        match storage.merge(&self.pending) {
            Ok(()) => {
                self.pending.clear();
                self.failed = false;
                self.error = None;
            }
            Err(error) => {
                self.failed = true;
                self.error = Some(format!("{error:#}"));
            }
        }
    }
}
pub(crate) fn private_directory(path: &Path) -> anyhow::Result<()> {
    std::fs::create_dir_all(path)?;
    ensure!(
        std::fs::symlink_metadata(path)?.file_type().is_dir(),
        "Draft storage must be a directory"
    );
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}
pub(crate) fn open_regular(path: &Path, create: bool) -> anyhow::Result<File> {
    let mut options = OpenOptions::new();
    options
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    if create {
        options.write(true).create(true).truncate(false).mode(0o600);
    }
    let file = options.open(path)?;
    ensure!(
        file.metadata()?.is_file(),
        "Draft storage must be a regular file"
    );
    Ok(file)
}
pub(crate) fn record_lock(file: &File, wait: bool) -> anyhow::Result<()> {
    // SAFETY: flock is a plain C record and all unspecified fields must be zero.
    let mut region: libc::flock = unsafe { std::mem::zeroed() };
    region.l_type = libc::F_WRLCK as _;
    region.l_whence = libc::SEEK_SET as _;
    loop {
        // SAFETY: file owns the descriptor and region is valid for this call.
        if unsafe {
            libc::fcntl(
                file.as_raw_fd(),
                if wait { libc::F_SETLKW } else { libc::F_SETLK },
                &region,
            )
        } != -1
        {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error.into());
        }
    }
}
fn read(path: &Path, limit: usize) -> anyhow::Result<Records> {
    let file = match open_regular(path, false) {
        Ok(file) => file,
        Err(error)
            if error
                .downcast_ref::<std::io::Error>()
                .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
        {
            return Ok(Records::new());
        }
        Err(error) => return Err(error),
    };
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= limit, "Draft store is too large");
    let records: Records = serde_json::from_slice(&bytes)?;
    ensure!(
        records.iter().all(|(key, draft)| draft
            .reference
            .conversation_key()
            .is_some_and(|derived| crate::work::text::equal(&derived, key))
            && !draft.is_empty()),
        "Draft store contains an invalid record"
    );
    Ok(records)
}
/// Match Foundation's escaped solidus and compact date spelling so the same
/// byte quota applies to writing, including small scientific date values.
pub fn encode(records: &Records) -> anyhow::Result<Vec<u8>> {
    struct Formatter;
    impl serde_json::ser::Formatter for Formatter {
        fn write_string_fragment<W: ?Sized + Write>(
            &mut self,
            writer: &mut W,
            fragment: &str,
        ) -> std::io::Result<()> {
            let mut parts = fragment.split('/');
            if let Some(first) = parts.next() {
                writer.write_all(first.as_bytes())?;
            }
            for part in parts {
                writer.write_all(b"\\/")?;
                writer.write_all(part.as_bytes())?;
            }
            Ok(())
        }
        fn write_f64<W: ?Sized + Write>(
            &mut self,
            writer: &mut W,
            value: f64,
        ) -> std::io::Result<()> {
            if value != 0. && value.abs() < 0.0001 {
                let scientific = format!("{value:e}");
                let (mantissa, exponent) = scientific
                    .split_once('e')
                    .ok_or_else(|| std::io::Error::other("Missing scientific date exponent"))?;
                let exponent = exponent.parse::<i32>().map_err(std::io::Error::other)?;
                write!(writer, "{mantissa}e{exponent:+03}")
            } else if value.fract() == 0. && value.abs() < 1e16 {
                write!(writer, "{value:.0}")
            } else {
                serde_json::ser::CompactFormatter.write_f64(writer, value)
            }
        }
    }
    let mut bytes = Vec::new();
    let mut value = serde_json::to_value(records)?;
    fn omit_nulls(value: &mut serde_json::Value) {
        match value {
            serde_json::Value::Object(map) => {
                map.retain(|_, value| !value.is_null());
                for value in map.values_mut() {
                    omit_nulls(value);
                }
            }
            serde_json::Value::Array(values) => {
                for value in values {
                    omit_nulls(value);
                }
            }
            _ => {}
        }
    }
    omit_nulls(&mut value);
    let mut serializer = serde_json::Serializer::with_formatter(&mut bytes, Formatter);
    serde::Serialize::serialize(&value, &mut serializer)?;
    Ok(bytes)
}
fn write(file: &Path, directory: &Path, records: &Records, limit: usize) -> anyhow::Result<()> {
    private_directory(directory)?;
    if records.is_empty() {
        match std::fs::remove_file(file) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        File::open(directory)?.sync_all()?;
        return Ok(());
    }
    let bytes = encode(records)?;
    ensure!(bytes.len() <= limit, "Draft store is too large");
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let temporary = directory.join(format!(
        ".draft-{}-{}.tmp",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let mut created = false;
    let result = (|| {
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&temporary)?;
        created = true;
        output.write_all(&bytes)?;
        output.sync_all()?;
        std::fs::rename(&temporary, file)?;
        File::open(directory)?.sync_all()?;
        Ok::<_, anyhow::Error>(())
    })();
    if created && result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}
pub(crate) fn uuid() -> anyhow::Result<String> {
    let mut bytes = [0u8; 16];
    File::open("/dev/urandom")
        .context("A draft needs a delivery identity")?
        .read_exact(&mut bytes)?;
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    let value = bytes.iter().map(|b| format!("{b:02X}")).collect::<String>();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &value[..8],
        &value[8..12],
        &value[12..16],
        &value[16..20],
        &value[20..]
    ))
}
