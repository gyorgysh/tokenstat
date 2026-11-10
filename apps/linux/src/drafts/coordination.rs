// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! OriginalFileCoordination participation and in-flight-use protection. Record
//! locks are process-scoped, so same-process handles share a participant/gate.

use super::storage;
use anyhow::{Context, ensure};
use std::os::unix::fs::OpenOptionsExt;
use std::{
    collections::HashMap,
    fs::{File, OpenOptions},
    path::{Component, Path, PathBuf},
    sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, Weak},
    thread::ThreadId,
};

struct Gate {
    owner: ThreadId,
    depth: usize,
    _file: File,
}
#[derive(Default)]
struct State {
    participants: HashMap<PathBuf, Weak<Participant>>,
    gates: HashMap<PathBuf, Gate>,
    uses: HashMap<(PathBuf, PathBuf), usize>,
}
fn global() -> &'static (Mutex<State>, Condvar) {
    static STATE: OnceLock<(Mutex<State>, Condvar)> = OnceLock::new();
    STATE.get_or_init(|| (Mutex::new(State::default()), Condvar::new()))
}
fn lock_state() -> anyhow::Result<MutexGuard<'static, State>> {
    global()
        .0
        .lock()
        .map_err(|_| anyhow::anyhow!("Original-file coordination lock was poisoned"))
}
fn ready_state(root: &Path) -> anyhow::Result<MutexGuard<'static, State>> {
    let mut state = lock_state()?;
    while state
        .gates
        .get(root)
        .is_some_and(|gate| gate.owner != std::thread::current().id())
    {
        state = global()
            .1
            .wait(state)
            .map_err(|_| anyhow::anyhow!("Original-file coordination lock was poisoned"))?;
    }
    Ok(state)
}
struct HeldGate {
    root: PathBuf,
}
impl Drop for HeldGate {
    fn drop(&mut self) {
        let mut state = match global().0.lock() {
            Ok(state) => state,
            Err(error) => error.into_inner(),
        };
        if let Some(gate) = state.gates.get_mut(&self.root) {
            gate.depth -= 1;
            if gate.depth == 0 {
                // Close before another same-process descriptor can acquire the inode.
                drop(state.gates.remove(&self.root));
                global().1.notify_all();
            }
        }
    }
}
fn gate(root: &Path, wait: bool) -> anyhow::Result<HeldGate> {
    let owner = std::thread::current().id();
    let mut state = lock_state()?;
    loop {
        match state.gates.get_mut(root) {
            Some(held) if held.owner == owner => {
                held.depth += 1;
                return Ok(HeldGate { root: root.into() });
            }
            Some(_) => {
                state = global()
                    .1
                    .wait(state)
                    .map_err(|_| anyhow::anyhow!("Original-file coordination lock was poisoned"))?;
            }
            None => break,
        }
    }
    storage::private_directory(root)?;
    let file = storage::open_regular(&root.join("gate.lock"), true)?;
    storage::record_lock(&file, wait)?;
    state.gates.insert(
        root.into(),
        Gate {
            owner,
            depth: 1,
            _file: file,
        },
    );
    Ok(HeldGate { root: root.into() })
}
/// A failed registration may be retried after storage recovers.
#[derive(Clone)]
pub struct Registration {
    directory: PathBuf,
    held: Arc<Mutex<Option<Arc<Participant>>>>,
}
impl Registration {
    /// Construction is inert; joining happens only when a worker calls `get`.
    pub fn new(directory: PathBuf) -> Self {
        Self {
            directory,
            held: Arc::new(Mutex::new(None)),
        }
    }
    /// Retry failed participation and retain a successful locked lease.
    pub fn get(&self) -> anyhow::Result<Arc<Participant>> {
        let mut held = self
            .held
            .lock()
            .map_err(|_| anyhow::anyhow!("Original-file registration lock was poisoned"))?;
        if let Some(participant) = held.as_ref() {
            return Ok(participant.clone());
        }
        let participant = join(&self.directory)?;
        *held = Some(participant.clone());
        Ok(participant)
    }
}
/// The locked lease inode lives for the full lifetime of all local store handles.
pub struct Participant {
    root: PathBuf,
    file: PathBuf,
    _lease: File,
}
/// An activity holds participation while original bytes are being read or sent.
pub struct Activity {
    participant: Arc<Participant>,
    key: PathBuf,
}
impl Drop for Activity {
    fn drop(&mut self) {
        if let Ok(mut state) = ready_state(&self.participant.root) {
            let key = (self.participant.root.clone(), self.key.clone());
            if let Some(count) = state.uses.get_mut(&key) {
                *count -= 1;
                if *count == 0 {
                    state.uses.remove(&key);
                }
            }
        }
    }
}
/// Resolve existing symlink prefixes while retaining a missing file's full path.
pub fn normalized(path: &Path) -> anyhow::Result<PathBuf> {
    let absolute = if path.is_absolute() {
        path.into()
    } else {
        std::env::current_dir()?.join(path)
    };
    let mut lexical = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                lexical.pop();
            }
            _ => lexical.push(component.as_os_str()),
        }
    }
    let mut existing = lexical.as_path();
    let mut tail = Vec::new();
    while !existing.exists() {
        match std::fs::symlink_metadata(existing) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
            Ok(_) => anyhow::bail!("An original-file path is a broken link"),
        }
        tail.push(
            existing
                .file_name()
                .context("Original-file path has no existing parent")?
                .to_os_string(),
        );
        existing = existing
            .parent()
            .context("Original-file path has no parent")?;
    }
    let mut path = existing.canonicalize()?;
    for part in tail.into_iter().rev() {
        path.push(part);
    }
    Ok(path)
}
/// Share one participant per canonical directory inside the process.
pub fn join(directory: &Path) -> anyhow::Result<Arc<Participant>> {
    let root = normalized(directory)?.join(".original-file-owners");
    if let Some(held) = ready_state(&root)?
        .participants
        .get(&root)
        .and_then(Weak::upgrade)
    {
        return Ok(held);
    }
    let _gate = gate(&root, true)?;
    let mut state = ready_state(&root)?;
    if let Some(held) = state.participants.get(&root).and_then(Weak::upgrade) {
        return Ok(held);
    }
    let file = root.join(format!("{}.lease", storage::uuid()?));
    let lease = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(&file)?;
    storage::record_lock(&lease, false)?;
    let participant = Arc::new(Participant {
        root: root.clone(),
        file,
        _lease: lease,
    });
    state
        .participants
        .retain(|_, weak| weak.strong_count() != 0);
    state
        .participants
        .insert(root, Arc::downgrade(&participant));
    Ok(participant)
}
/// Hold a live use until the returned activity is dropped.
pub fn use_file(participant: &Arc<Participant>, file: &Path) -> anyhow::Result<Activity> {
    let mut state = ready_state(&participant.root)?;
    let key = normalized(file)?;
    *state
        .uses
        .entry((participant.root.clone(), key.clone()))
        .or_default() += 1;
    Ok(Activity {
        participant: participant.clone(),
        key,
    })
}
/// No participant may join while the reference check and explicit removal run.
/// The callback must be synchronous; no gate crosses an await.
pub fn while_sole<T>(
    participant: &Participant,
    file: &Path,
    work: impl FnOnce() -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let _gate = gate(&participant.root, false)?;
    let key = normalized(file)?;
    ensure!(
        !ready_state(&participant.root)?
            .uses
            .contains_key(&(participant.root.clone(), key)),
        "This original file is being used"
    );
    for entry in std::fs::read_dir(&participant.root)? {
        let file = entry?.path();
        if file.extension().is_none_or(|ext| ext != "lease") || file == participant.file {
            continue;
        }
        let lease = match OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(&file)
            .map_err(anyhow::Error::from)
        {
            Ok(file) => file,
            Err(e)
                if e.downcast_ref::<std::io::Error>()
                    .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
            {
                continue;
            }
            Err(e) => return Err(e),
        };
        ensure!(
            storage::record_lock(&lease, false).is_ok(),
            "Another running instance holds original-file references"
        );
        std::fs::remove_file(file)?;
    }
    work()
}
