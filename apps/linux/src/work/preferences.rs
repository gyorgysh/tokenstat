// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Device-local GUI metadata. Each mutation reads the current file under a
//! process-shared lock, so independent windows/processes cannot lose updates.

use anyhow::{Context, ensure};
use serde_json::{Map, Value, json};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

const MAX_BYTES: u64 = 16 * 1024 * 1024;

/// Memory mode is explicit for fixtures. A disk store performs no IO until
/// a worker calls read/update; constructing it never touches preferences.
#[derive(Clone, Default)]
pub struct Preferences {
    path: Option<PathBuf>,
    memory: Arc<Mutex<Map<String, Value>>>,
}
impl Preferences {
    /// Use one UUID for signed-out work across relaunches and windows. The
    /// identifier is GUI metadata, separate from the host's public identity.
    pub fn installation_id(&self) -> anyhow::Result<String> {
        self.update(|map| {
            const KEY: &str = "work.localInstallation.v1";
            if let Some(id) = map.get(KEY).and_then(Value::as_str) {
                return Ok(id.into());
            }
            let mut bytes = [0u8; 16];
            File::open("/dev/urandom")?.read_exact(&mut bytes)?;
            bytes[6] = (bytes[6] & 0x0f) | 0x40;
            bytes[8] = (bytes[8] & 0x3f) | 0x80;
            let hex: String = bytes.iter().map(|b| format!("{b:02X}")).collect();
            let id = format!(
                "{}-{}-{}-{}-{}",
                &hex[..8],
                &hex[8..12],
                &hex[12..16],
                &hex[16..20],
                &hex[20..]
            );
            map.insert(KEY.into(), Value::String(id.clone()));
            Ok(id)
        })
    }
    /// The caller chooses a Linux device-local path, never the host archive.
    pub fn at(path: PathBuf) -> Self {
        Self {
            path: Some(path),
            ..Self::default()
        }
    }
    /// Query a consistent snapshot without creating a missing store.
    pub fn read<T>(&self, read: impl FnOnce(&Map<String, Value>) -> T) -> anyhow::Result<T> {
        let Some(path) = &self.path else {
            let current = self
                .memory
                .lock()
                .map_err(|_| anyhow::anyhow!("Work preferences lock was poisoned"))?;
            return Ok(read(&current));
        };
        match std::fs::symlink_metadata(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(read(&Map::new())),
            Err(e) => return Err(e.into()),
            Ok(_) => {}
        }
        let _lock = lock(path)?;
        let root = load(path)?;
        Ok(read(values(&root)?))
    }
    /// Read-modify-write is serialized across every store handle. Callback
    /// errors preserve the previous bytes, as do malformed outer containers.
    pub fn update<T>(
        &self,
        update: impl FnOnce(&mut Map<String, Value>) -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        let Some(path) = &self.path else {
            let mut current = self
                .memory
                .lock()
                .map_err(|_| anyhow::anyhow!("Work preferences lock was poisoned"))?;
            let mut next = current.clone();
            let result = update(&mut next)?;
            *current = next;
            return Ok(result);
        };
        let parent = path
            .parent()
            .context("Work preferences need a parent directory")?;
        std::fs::create_dir_all(parent)?;
        let _lock = lock(path)?;
        let mut root = load(path)?;
        let previous = root.clone();
        let map = root
            .get_mut("values")
            .and_then(Value::as_object_mut)
            .context("Invalid work preferences values")?;
        let result = update(map)?;
        if root != previous {
            save(path, &root)?;
        }
        Ok(result)
    }
}
fn values(root: &Value) -> anyhow::Result<&Map<String, Value>> {
    root.get("values")
        .and_then(Value::as_object)
        .context("Invalid work preferences values")
}
fn load(path: &Path) -> anyhow::Result<Value> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    let file = match options.open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(json!({"version":1,"values":{}}));
        }
        Err(e) => return Err(e.into()),
    };
    ensure!(
        file.metadata()?.is_file(),
        "Work preferences must be a regular file"
    );
    let mut bytes = vec![];
    file.take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= MAX_BYTES,
        "Work preferences are too large"
    );
    let root: Value = serde_json::from_slice(&bytes)?;
    ensure!(
        root.get("version").and_then(Value::as_u64) == Some(1),
        "Unsupported work preferences version"
    );
    values(&root)?;
    Ok(root)
}
fn lock(path: &Path) -> anyhow::Result<File> {
    let name = path
        .file_name()
        .context("Work preferences need a file name")?;
    let mut name = name.to_os_string();
    name.push(".lock");
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    let file = options.open(path.with_file_name(name))?;
    ensure!(
        file.metadata()?.is_file(),
        "Work preferences lock must be a regular file"
    );
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        loop {
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
                break;
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(error.into());
            }
        }
    }
    Ok(file)
}
fn save(path: &Path, value: &Value) -> anyhow::Result<()> {
    let bytes = serde_json::to_vec(value)?;
    ensure!(
        bytes.len() as u64 <= MAX_BYTES,
        "Work preferences are too large"
    );
    let parent = path
        .parent()
        .context("Work preferences need a parent directory")?;
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let temporary = parent.join(format!(
        ".work-{}-{}.tmp",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let mut created = false;
    let result = (|| {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
        }
        let mut file = options.open(&temporary)?;
        created = true;
        file.write_all(&bytes)?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)?;
        File::open(parent)?.sync_all()?;
        Ok::<_, anyhow::Error>(())
    })();
    if created && result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}
