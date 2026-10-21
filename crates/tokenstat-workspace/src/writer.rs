// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Process-owned coordination for managed workspace writers. These locks do
//! not confine an agent or prevent edits by other programs.

mod claim;
mod file;
#[cfg(test)]
mod tests;

use std::fs::File;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum Error {
    #[error("This checkout is in use by another agent or Git operation. Wait for it to finish.")]
    Busy,
    #[error("Could not lock this checkout. Check the folder and try again.")]
    Unavailable,
    #[error("This checkout changed while it was being prepared. Review it and try again.")]
    Changed,
    #[error(
        "This checkout has an unresolved Team run. Recover it on the publishing computer before making changes."
    )]
    RecoveryRequired,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct Identity {
    volume: u64,
    file: [u8; 16],
}
impl Identity {
    fn name(self) -> String {
        let mut hash = Sha256::new();
        hash.update(b"tokenstat-workspace-writer-v1\0");
        hash.update(self.volume.to_be_bytes());
        hash.update(self.file);
        let mut name = String::with_capacity(69);
        const HEX: &[u8; 16] = b"0123456789abcdef";
        for byte in hash.finalize() {
            name.push(HEX[usize::from(byte >> 4)] as char);
            name.push(HEX[usize::from(byte & 15)] as char);
        }
        name.push_str(".lock");
        name
    }
}

struct Folder {
    path: PathBuf,
    identity: Identity,
    _handle: File,
}
impl Folder {
    fn capture(path: &Path) -> Result<Self, Error> {
        let path = path.canonicalize().map_err(|_| Error::Unavailable)?;
        let handle = file::directory(&path)?;
        Ok(Self {
            identity: file::identity(&handle)?,
            path,
            _handle: handle,
        })
    }
}

struct Target {
    folder: Folder,
    common: Option<Folder>,
    ancestors: Vec<Folder>,
}
impl Target {
    fn capture(path: &Path) -> Result<Self, Error> {
        let folder = Folder::capture(path)?;
        let common = if git_marker(&folder.path)? {
            let path = common_directory(&folder.path)?;
            Some(Folder::capture(&path)?)
        } else {
            None
        };
        let mut ancestors: Vec<Folder> = Vec::new();
        for path in std::iter::once(&folder.path).chain(common.iter().map(|value| &value.path)) {
            for parent in path.ancestors().skip(1) {
                if ancestors.len() >= 128 {
                    return Err(Error::Unavailable);
                }
                let captured = Folder::capture(parent)?;
                if !ancestors
                    .iter()
                    .any(|value| value.identity == captured.identity)
                {
                    ancestors.push(captured);
                }
            }
        }
        Ok(Self {
            folder,
            common,
            ancestors,
        })
    }
    fn requests(&self) -> Vec<(Identity, bool)> {
        let mut values = vec![(self.folder.identity, true)];
        if let Some(common) = &self.common {
            values.push((common.identity, true));
        }
        values.extend(self.ancestors.iter().map(|value| (value.identity, false)));
        values.sort_unstable_by_key(|(identity, _)| *identity);
        let mut merged: Vec<(Identity, bool)> = Vec::new();
        for (identity, exclusive) in values {
            if let Some((previous, previous_exclusive)) = merged.last_mut()
                && *previous == identity
            {
                *previous_exclusive |= exclusive;
            } else {
                merged.push((identity, exclusive));
            }
        }
        merged
    }
    fn same(&self, other: &Self) -> bool {
        self.folder.path == other.folder.path
            && self.requests() == other.requests()
            && self.common.as_ref().map(|value| &value.path)
                == other.common.as_ref().map(|value| &value.path)
    }
}

/// Hold from launch preparation through process completion, or through one
/// explicit Git/editor operation. Never unlink its lock files on release.
pub struct Lease {
    original: PathBuf,
    target: Target,
    additional: Option<(PathBuf, Target)>,
    root: Folder,
    locks: Vec<(PathBuf, File)>,
    retired: AtomicBool,
    claim: Option<String>,
}
impl Lease {
    pub fn folder(&self) -> &Path {
        &self.target.folder.path
    }
    pub fn ensure_for(&self, folder: &Path) -> Result<(), Error> {
        self.ensure_current()?;
        let requested = Folder::capture(folder).map_err(|_| Error::Changed)?;
        if requested.identity != self.target.folder.identity {
            return Err(Error::Changed);
        }
        Ok(())
    }
    pub fn acquire(folder: &Path) -> Result<Self, Error> {
        Self::at(folder, &lock_root()?)
    }
    /// Coordinate a source and an existing destination parent atomically.
    /// Merging first avoids conflicting with this operation's own ancestors.
    pub fn acquire_pair(folder: &Path, destination_parent: &Path) -> Result<Self, Error> {
        Self::at_with_destination(folder, Some(destination_parent), &lock_root()?)
    }
    fn at(folder: &Path, root: &Path) -> Result<Self, Error> {
        Self::at_with_destination(folder, None, root)
    }
    fn at_with_destination(
        folder: &Path,
        destination: Option<&Path>,
        root: &Path,
    ) -> Result<Self, Error> {
        let target = Target::capture(folder)?;
        let additional = destination
            .map(|path| Target::capture(path).map(|target| (path.to_owned(), target)))
            .transpose()?;
        file::private_directory(root)?;
        let root = Folder::capture(root)?;
        let mut locks = Vec::new();
        // Nonblocking acquisition and a fixed order avoid deadlock between
        // linked checkouts. A partial failure drops every acquired handle.
        let mut requests = target.requests();
        if let Some((_, target)) = &additional {
            requests.extend(target.requests());
        }
        requests.sort_unstable_by_key(|(identity, _)| *identity);
        let mut merged: Vec<(Identity, bool)> = Vec::new();
        for (identity, exclusive) in requests {
            if let Some((prior, prior_exclusive)) = merged.last_mut()
                && *prior == identity
            {
                *prior_exclusive |= exclusive;
            } else {
                merged.push((identity, exclusive));
            }
        }
        for (identity, exclusive) in merged {
            let path = root.path.join(identity.name());
            let lock = file::lock(&path, exclusive)?;
            locks.push((path, lock));
        }
        let lease = Self {
            original: folder.to_owned(),
            target,
            additional,
            root,
            locks,
            retired: AtomicBool::new(false),
            claim: None,
        };
        lease.ensure_current()?;
        Ok(lease)
    }
    /// Recheck immediately before managed effects after asynchronous work or
    /// launch preparation. A replaced folder or lock retires this writer.
    pub fn ensure_current(&self) -> Result<(), Error> {
        if self.retired.load(Ordering::SeqCst) {
            return Err(Error::Changed);
        }
        let result = self.check_current();
        if result.is_err() {
            self.retired.store(true, Ordering::SeqCst);
        }
        if result.is_ok() && self.retired.load(Ordering::SeqCst) {
            return Err(Error::Changed);
        }
        result
    }
    fn check_current(&self) -> Result<(), Error> {
        let target = Target::capture(&self.original).map_err(|_| Error::Changed)?;
        let root = Folder::capture(&self.root.path).map_err(|_| Error::Changed)?;
        if !self.target.same(&target) || root.identity != self.root.identity {
            return Err(Error::Changed);
        }
        if let Some((path, target)) = &self.additional
            && !target.same(&Target::capture(path).map_err(|_| Error::Changed)?)
        {
            return Err(Error::Changed);
        }
        for (path, handle) in &self.locks {
            let current = file::existing_lock(path).map_err(|_| Error::Changed)?;
            if file::identity(&current)? != file::identity(handle)? {
                return Err(Error::Changed);
            }
        }
        claim::check(self)
    }
}

fn lock_root() -> Result<PathBuf, Error> {
    #[cfg(test)]
    {
        static ROOT: std::sync::OnceLock<tempfile::TempDir> = std::sync::OnceLock::new();
        let root = ROOT.get_or_init(|| tempfile::tempdir().expect("writer test directory"));
        Ok(root.path().join("writers"))
    }
    #[cfg(not(test))]
    {
        tokenstat_paths::data_dir()
            .map(|root| root.join("workspace-writers"))
            .ok_or(Error::Unavailable)
    }
}

// A missing Git executable or damaged .git must never turn a repository into
// an unfenced plain folder. Plain folders work without Git installed.
fn git_marker(folder: &Path) -> Result<bool, Error> {
    for path in folder.ancestors() {
        match std::fs::symlink_metadata(path.join(".git")) {
            Ok(_) => return Ok(true),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(Error::Unavailable),
        }
        // Bare repositories have no .git entry.
        if path.join("HEAD").is_file() && path.join("objects").is_dir() {
            return Ok(true);
        }
    }
    Ok(false)
}

fn common_directory(folder: &Path) -> Result<PathBuf, Error> {
    use std::io::Read;
    // A file avoids a blocked pipe-reader thread when a failed Git wrapper
    // leaves a descendant holding stdout. Only this owned child is stopped.
    let mut output = tempfile::tempfile().map_err(|_| Error::Unavailable)?;
    let mut command = crate::gitwrite::git_command(folder);
    command
        .args(["rev-parse", "--git-common-dir"])
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(Stdio::null())
        .stdout(output.try_clone().map_err(|_| Error::Unavailable)?)
        .stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command.spawn().map_err(|_| Error::Unavailable)?;
    let deadline = Instant::now() + Duration::from_secs(3);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Err(_) => return Err(Error::Unavailable),
            Ok(None)
                if Instant::now() < deadline
                    && output
                        .metadata()
                        .is_ok_and(|value| value.len() <= 64 * 1024) =>
            {
                std::thread::sleep(Duration::from_millis(10));
            }
            Ok(None) => {
                #[cfg(unix)]
                unsafe {
                    libc::kill(-(child.id() as i32), libc::SIGKILL);
                }
                let _ = child.kill();
                let _ = child.wait();
                return Err(Error::Unavailable);
            }
        }
    };
    if !status.success() {
        return Err(Error::Unavailable);
    }
    use std::io::Seek;
    output.rewind().map_err(|_| Error::Unavailable)?;
    let mut bytes = Vec::new();
    output
        .by_ref()
        .take(64 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::Unavailable)?;
    if bytes.len() > 64 * 1024 || bytes.pop() != Some(b'\n') || bytes.is_empty() {
        return Err(Error::Unavailable);
    }
    #[cfg(windows)]
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    #[cfg(unix)]
    let path = {
        use std::os::unix::ffi::OsStringExt;
        PathBuf::from(std::ffi::OsString::from_vec(bytes))
    };
    #[cfg(not(unix))]
    let path = PathBuf::from(String::from_utf8(bytes).map_err(|_| Error::Unavailable)?);
    // Leave leading/trailing whitespace in folder names intact.
    Ok(if path.is_absolute() {
        path
    } else {
        folder.join(path)
    })
}
