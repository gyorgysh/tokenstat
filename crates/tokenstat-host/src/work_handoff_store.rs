// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! A single continuation beside an existing host-owned conversation. Callers
//! authorize and resolve that conversation before supplying its directory.
//! This layer never creates a conversation directory or accepts client paths.

use crate::work_handoff::{Handoff, PutHandoff, PutResult, apply};
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

// JSON can escape one text byte to six bytes. The decoded text cap is enforced
// separately; even the most escaped valid draft fits this on-disk bound.
const MAX_RECORD_BYTES: u64 = 2 * 1024 * 1024;
const RECORD: &str = "handoff.json";
static OPERATIONS: Mutex<()> = Mutex::new(());
static LIFECYCLE: Mutex<()> = Mutex::new(());
static TRANSCRIPTS: Mutex<()> = Mutex::new(());

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: u32,
    handoff: Handoff,
}

pub(crate) struct Guard {
    _process: MutexGuard<'static, ()>,
    file: File,
}
impl Drop for Guard {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            unsafe {
                libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
            }
        }
        #[cfg(windows)]
        crate::win32::unlock(&self.file);
    }
}

fn private_options() -> OpenOptions {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut options = OpenOptions::new();
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        options
    }
    #[cfg(not(unix))]
    {
        OpenOptions::new()
    }
}

fn lock(directory: &Path) -> Result<Guard, String> {
    file_lock(directory, "handoff.lock", &OPERATIONS)
}

/// Serialize conversation removal with handoff verification and directory
/// initialization. Kept in the chat root so deleting a conversation cannot
/// replace the inode on which another process is waiting.
pub(crate) fn lifecycle_lock(root: &Path) -> Result<Guard, String> {
    file_lock(root, "handoff-lifecycle.lock", &LIFECYCLE)
}

/// Keep transcript allocation, reads and replacement on the same inode lock.
/// The root outlives individual conversation directories and archive rewrites.
pub(crate) fn transcript_lock(root: &Path) -> Result<Guard, String> {
    file_lock(root, "transcript.lock", &TRANSCRIPTS)
}

fn file_lock(directory: &Path, name: &str, mutex: &'static Mutex<()>) -> Result<Guard, String> {
    let process = mutex.lock().map_err(|_| "handoff lock is unavailable")?;
    // No create_dir_all: a deleted conversation must never be recreated here.
    if !fs::symlink_metadata(directory)
        .map_err(|e| e.to_string())?
        .is_dir()
    {
        return Err("handoff conversation directory is unavailable".into());
    }
    let file = private_options()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(directory.join(name))
        .map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
    }
    #[cfg(windows)]
    if !crate::win32::try_lock_exclusive(&file, true) {
        return Err("cannot lock handoff storage".into());
    }
    Ok(Guard {
        _process: process,
        file,
    })
}

fn read_locked(directory: &Path) -> Result<Option<Handoff>, String> {
    let path = directory.join(RECORD);
    let file = match private_options().read(true).open(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.to_string()),
    };
    let metadata = file.metadata().map_err(|e| e.to_string())?;
    if !metadata.is_file() || metadata.len() > MAX_RECORD_BYTES {
        return Err("saved handoff is not a bounded record".into());
    }
    let mut bytes = Vec::new();
    file.take(MAX_RECORD_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_RECORD_BYTES {
        return Err("saved handoff is too large".into());
    }
    let stored: Envelope =
        serde_json::from_slice(&bytes).map_err(|_| "saved handoff could not be read")?;
    if stored.version != 1 {
        return Err("saved handoff uses an unsupported format".into());
    }
    let current = stored.handoff;
    let expected_revision = current
        .revision
        .checked_sub(1)
        .ok_or("saved handoff revision is invalid")?;
    // Reuse the wire bounds, including authenticated identifier shape. This
    // validates a record; it does not accept device identity from an RPC body.
    let request = PutHandoff {
        request_id: current.request_id.clone(),
        expected_revision,
        device_name: current.device_name.clone(),
        draft: current.draft.clone(),
        anchor: current.anchor.clone(),
    };
    apply(
        Some(&current),
        &request,
        &current.device_id,
        current.updated_at_ms,
    )?;
    Ok(Some(current))
}

pub fn read(directory: &Path) -> Result<Option<Handoff>, String> {
    let _guard = lock(directory)?;
    read_locked(directory)
}

struct Temporary(PathBuf);
impl Drop for Temporary {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

pub fn put(
    directory: &Path,
    request: &PutHandoff,
    authenticated_device: &str,
    now_ms: i64,
) -> Result<PutResult, String> {
    let _guard = lock(directory)?;
    let current = read_locked(directory)?;
    let result = apply(current.as_ref(), request, authenticated_device, now_ms)?;
    let PutResult::Saved { handoff } = &result else {
        return Ok(result);
    };
    if current.as_ref() == Some(handoff) {
        return Ok(result);
    }
    let bytes = serde_json::to_vec(&Envelope {
        version: 1,
        handoff: handoff.clone(),
    })
    .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_RECORD_BYTES {
        return Err("handoff record is too large".into());
    }
    let temp = Temporary(directory.join(format!(".handoff-{:032x}.tmp", rand::random::<u128>())));
    let mut file = private_options()
        .write(true)
        .create_new(true)
        .open(&temp.0)
        .map_err(|e| e.to_string())?;
    file.write_all(&bytes).map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    drop(file);
    fs::rename(&temp.0, directory.join(RECORD)).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    File::open(directory)
        .and_then(|dir| dir.sync_all())
        .map_err(|e| e.to_string())?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::work_handoff::SharedDraft;

    fn request(id: &str, revision: u64, text: &str) -> PutHandoff {
        PutHandoff {
            request_id: id.into(),
            expected_revision: revision,
            device_name: "Studio".into(),
            draft: Some(SharedDraft {
                text: text.into(),
                attachment_ids: vec![],
            }),
            anchor: None,
        }
    }

    #[test]
    fn reopening_and_retries_preserve_the_committed_record() {
        let directory = tempfile::tempdir().unwrap();
        assert_eq!(read(directory.path()).unwrap(), None);
        let value = request("one", 0, "a draft");
        let first = put(directory.path(), &value, "device-a", 10).unwrap();
        assert_eq!(
            put(directory.path(), &value, "device-a", 20).unwrap(),
            first
        );
        let record = read(directory.path()).unwrap().unwrap();
        assert_eq!(record.revision, 1);
        assert_eq!(record.updated_at_ms, 10);
        // An unfinished temporary write cannot replace the committed version.
        fs::write(
            directory.path().join(".handoff-interrupted.tmp"),
            b"partial",
        )
        .unwrap();
        assert_eq!(read(directory.path()).unwrap(), Some(record));
    }

    #[test]
    fn invalid_writes_and_conflicts_leave_previous_bytes_untouched() {
        let directory = tempfile::tempdir().unwrap();
        put(
            directory.path(),
            &request("one", 0, "keep this"),
            "device-a",
            1,
        )
        .unwrap();
        let before = fs::read(directory.path().join(RECORD)).unwrap();
        assert!(matches!(
            put(directory.path(), &request("two", 0, "other"), "device-b", 2).unwrap(),
            PutResult::Conflict { .. }
        ));
        assert!(
            put(
                directory.path(),
                &request(
                    "three",
                    1,
                    &"x".repeat(crate::work_handoff::MAX_DRAFT_BYTES + 1)
                ),
                "device-a",
                3
            )
            .is_err()
        );
        assert_eq!(fs::read(directory.path().join(RECORD)).unwrap(), before);
    }

    #[test]
    fn corruption_is_not_an_empty_slot_and_deleted_directories_stay_deleted() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join(RECORD), b"broken").unwrap();
        assert!(read(directory.path()).is_err());
        assert!(put(directory.path(), &request("one", 0, "draft"), "device-a", 1).is_err());
        assert_eq!(fs::read(directory.path().join(RECORD)).unwrap(), b"broken");
        let missing = directory.path().join("deleted");
        assert!(put(&missing, &request("one", 0, "draft"), "device-a", 1).is_err());
        assert!(!missing.exists());
    }

    #[test]
    fn unsupported_or_invalid_records_cannot_be_replaced_as_empty() {
        let directory = tempfile::tempdir().unwrap();
        put(directory.path(), &request("one", 0, "keep"), "device-a", 1).unwrap();
        let path = directory.path().join(RECORD);
        let original = fs::read(&path).unwrap();
        let mut json: serde_json::Value = serde_json::from_slice(&original).unwrap();
        json["version"] = 2.into();
        fs::write(&path, serde_json::to_vec(&json).unwrap()).unwrap();
        assert!(read(directory.path()).is_err());
        assert!(put(directory.path(), &request("two", 0, "new"), "device-b", 2).is_err());
        json["version"] = 1.into();
        json["handoff"]["revision"] = 0.into();
        fs::write(&path, serde_json::to_vec(&json).unwrap()).unwrap();
        assert!(read(directory.path()).is_err());
        OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(MAX_RECORD_BYTES + 1)
            .unwrap();
        assert!(read(directory.path()).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn private_records_do_not_follow_symlinks() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let directory = tempfile::tempdir().unwrap();
        put(
            directory.path(),
            &request("one", 0, "private"),
            "device-a",
            1,
        )
        .unwrap();
        assert_eq!(
            fs::metadata(directory.path().join(RECORD))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        fs::remove_file(directory.path().join(RECORD)).unwrap();
        let victim = directory.path().join("other");
        fs::write(&victim, b"untouched").unwrap();
        symlink(&victim, directory.path().join(RECORD)).unwrap();
        assert!(put(directory.path(), &request("two", 0, "other"), "device-a", 2).is_err());
        assert_eq!(fs::read(victim).unwrap(), b"untouched");
    }

    #[test]
    fn independent_processes_cannot_both_accept_the_same_revision() {
        let directory = tempfile::tempdir().unwrap();
        let held = lock(directory.path()).unwrap();
        let mut children = Vec::new();
        for author in ["device-a", "device-b"] {
            children.push(
                std::process::Command::new(std::env::current_exe().unwrap())
                    .args([
                        "--exact",
                        "work_handoff_store::tests::process_writer",
                        "--ignored",
                    ])
                    .env("TOKENSTAT_HANDOFF_TEST_DIR", directory.path())
                    .env("TOKENSTAT_HANDOFF_WRITER", author)
                    .spawn()
                    .unwrap(),
            );
        }
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !["device-a", "device-b"]
            .iter()
            .all(|author| directory.path().join(format!("{author}.ready")).exists())
        {
            assert!(
                std::time::Instant::now() < deadline,
                "writers did not start"
            );
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        fs::write(directory.path().join("go"), b"go").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(100));
        assert!(!directory.path().join("device-a").exists());
        assert!(!directory.path().join("device-b").exists());
        drop(held);
        for mut child in children {
            assert!(child.wait().unwrap().success());
        }
        let wins = ["device-a", "device-b"]
            .iter()
            .filter(|author| fs::read_to_string(directory.path().join(author)).unwrap() == "saved")
            .count();
        assert_eq!(wins, 1);
        assert_eq!(read(directory.path()).unwrap().unwrap().revision, 1);
    }

    #[test]
    #[ignore = "subprocess helper, invoked by the cross-process test"]
    fn process_writer() {
        let directory = PathBuf::from(std::env::var_os("TOKENSTAT_HANDOFF_TEST_DIR").unwrap());
        let author = std::env::var("TOKENSTAT_HANDOFF_WRITER").unwrap();
        fs::write(directory.join(format!("{author}.ready")), b"ready").unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !directory.join("go").exists() {
            assert!(
                std::time::Instant::now() < deadline,
                "writer was not released"
            );
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        let result = put(&directory, &request(&author, 0, &author), &author, 1).unwrap();
        fs::write(
            directory.join(&author),
            if matches!(result, PutResult::Saved { .. }) {
                "saved"
            } else {
                "conflict"
            },
        )
        .unwrap();
    }
}
