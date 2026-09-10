// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Proof that a message was taken, so a lost answer cannot run a turn twice.
//!
//! A send that reaches the host and whose reply never reaches the client looks
//! exactly like a send that never arrived. Without a record the client has two
//! bad options: drop the words, or send them again and run the agent twice. A
//! receipt is what makes the second attempt free: the host recognises the
//! message it already accepted and answers with the conversation instead of
//! starting anything.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

/// Thirty days. A client returning later than this is starting again rather
/// than resending, and a receipt that is gone is not evidence that the turn
/// never ran, which is why the client is told to look at the conversation
/// rather than being allowed to replay into it.
pub const RETENTION_MS: i64 = 30 * 24 * 60 * 60 * 1000;

/// Per conversation. Long enough for a device that was away for a while,
/// short enough that the file is read and written whole beside every send.
const CAPACITY: usize = 4096;
const MAX_BYTES: u64 = 4 * 1024 * 1024;
const CLOCK_SKEW_MS: i64 = 5 * 60 * 1000;

/// The longest client message id accepted, and the alphabet it may use. A
/// UUID fits with room to spare. The bound matters because the id becomes
/// part of a key in a file this host writes.
const MAX_ID: usize = 128;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ReceiptState {
    /// The agent was started and the message is on the timeline.
    Accepted,
    /// The host reserved this message but did not durably confirm the launch.
    /// A missing timeline row cannot establish whether the agent started.
    Pending,
    /// A previous acceptance is unresolved and no runner is owned here.
    /// Returned for review, never permission to launch again.
    NeedsRecovery,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Receipt {
    pub state: ReceiptState,
    /// The words and files this id was used for. The same id arriving with
    /// something else is a mistake on the client, not a resend, and saying so
    /// is better than quietly dropping one of the two messages.
    pub digest: String,
    pub at_ms: i64,
    /// The timeline row this produced, once there is one.
    pub event_at_ms: Option<i64>,
}

/// One conversation's receipts, read and written whole.
pub struct Ledger {
    path: PathBuf,
    entries: HashMap<String, Receipt>,
}

impl Ledger {
    pub fn load(path: PathBuf, now_ms: i64) -> Result<Self, String> {
        let mut entries = match private_options().read(true).open(&path) {
            Ok(file) => {
                let metadata = file.metadata().map_err(|e| e.to_string())?;
                if !metadata.is_file() || metadata.len() > MAX_BYTES {
                    return Err("Message receipts are not a bounded regular file. Delivery cannot be verified.".into());
                }
                let mut bytes = Vec::new();
                file.take(MAX_BYTES + 1)
                    .read_to_end(&mut bytes)
                    .map_err(|e| e.to_string())?;
                if bytes.len() as u64 > MAX_BYTES {
                    return Err(
                        "Message receipts are too large. Delivery cannot be verified.".into(),
                    );
                }
                serde_json::from_slice::<HashMap<String, Receipt>>(&bytes).map_err(
                    |_| "Message receipts could not be read. Delivery cannot be verified.",
                )?
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => HashMap::new(),
            Err(error) => return Err(format!("Message receipts could not be opened: {error}")),
        };
        // Unresolved launches never become permission to replay merely because
        // time passed. Accepted records keep the entire advertised window.
        entries.retain(|_, receipt| {
            receipt.state != ReceiptState::Accepted
                || now_ms.saturating_sub(receipt.at_ms) < RETENTION_MS + CLOCK_SKEW_MS
        });
        Ok(Self { path, entries })
    }

    pub fn get(&self, key: &str) -> Option<&Receipt> {
        self.entries.get(key)
    }

    pub fn put(&mut self, key: String, receipt: Receipt) -> Result<(), String> {
        // Refuse a new acceptance instead of silently evicting proof of a turn
        // still inside the retention window. Existing receipts can settle.
        if !self.entries.contains_key(&key) && self.entries.len() >= CAPACITY {
            return Err("Message receipt storage is full. No new message was started. Older confirmed receipts are kept for thirty days.".into());
        }
        self.entries.insert(key, receipt);
        Ok(())
    }

    pub fn remove(&mut self, key: &str) {
        self.entries.remove(key);
    }

    pub fn save(&self) -> Result<(), String> {
        let parent = self.path.parent().ok_or("invalid receipts path")?;
        if !fs::symlink_metadata(parent)
            .map_err(|e| e.to_string())?
            .is_dir()
        {
            return Err("message receipt directory is unavailable".into());
        }
        let body = serde_json::to_vec(&self.entries).map_err(|e| e.to_string())?;
        if body.len() as u64 > MAX_BYTES {
            return Err("message receipt storage is full".into());
        }
        let temp = Temporary(parent.join(format!(".receipts-{:032x}.tmp", rand::random::<u128>())));
        let mut file = private_options()
            .write(true)
            .create_new(true)
            .open(&temp.0)
            .map_err(|e| e.to_string())?;
        file.write_all(&body).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        drop(file);
        fs::rename(&temp.0, &self.path).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|e| e.to_string())?;
        Ok(())
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

struct Temporary(PathBuf);
impl Drop for Temporary {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

/// A send holds a shared lifecycle lock and its own conversation lock. Removing
/// conversations takes the exclusive lifecycle lock first. Files live in the
/// chat root so deleting a conversation cannot replace a held lock's inode.
/// Separate file handles coordinate both threads and independently loaded hosts.
pub(crate) struct Operation {
    _conversation: Option<FileLock>,
    _lifecycle: FileLock,
}

impl Operation {
    pub(crate) fn conversation(root: &Path, id: &str) -> Result<Self, String> {
        let lifecycle = FileLock::acquire(&root.join("send-lifecycle.lock"), false)?;
        let name = digest(id, &[]).replace(':', "-");
        let conversation = FileLock::acquire(&root.join(format!("send-{name}.lock")), true)?;
        Ok(Self {
            _conversation: Some(conversation),
            _lifecycle: lifecycle,
        })
    }

    pub(crate) fn removal(root: &Path) -> Result<Self, String> {
        Ok(Self {
            _conversation: None,
            _lifecycle: FileLock::acquire(&root.join("send-lifecycle.lock"), true)?,
        })
    }
}

struct FileLock(File);
impl FileLock {
    fn acquire(path: &Path, exclusive: bool) -> Result<Self, String> {
        let file = private_options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)
            .map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            let operation = if exclusive {
                libc::LOCK_EX
            } else {
                libc::LOCK_SH
            };
            loop {
                if unsafe { libc::flock(file.as_raw_fd(), operation) } == 0 {
                    break;
                }
                let error = std::io::Error::last_os_error();
                if error.kind() != std::io::ErrorKind::Interrupted {
                    return Err(error.to_string());
                }
            }
        }
        #[cfg(windows)]
        if !crate::win32::try_lock(&file, true, exclusive) {
            return Err("message acceptance storage could not be locked".into());
        }
        Ok(Self(file))
    }
}
impl Drop for FileLock {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            unsafe {
                libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
            }
        }
        #[cfg(windows)]
        crate::win32::unlock(&self.0);
    }
}

/// The device that sent the message and the id it chose.
///
/// The device is the authenticated peer the transport installed, never
/// anything from the request body, so one phone cannot claim another's
/// receipt and skip its send.
pub fn key(device: Option<&str>, client_message_id: &str) -> String {
    format!("{}|{}", device.unwrap_or("local"), client_message_id)
}

/// What the id was used for. Reuse with other words is a conflict.
pub fn digest(text: &str, attachment_ids: &[String]) -> String {
    let mut hash = Sha256::new();
    hash.update((text.len() as u64).to_be_bytes());
    hash.update(text.as_bytes());
    hash.update((attachment_ids.len() as u64).to_be_bytes());
    for id in attachment_ids {
        hash.update((id.len() as u64).to_be_bytes());
        hash.update(id.as_bytes());
    }
    let bytes: String = hash
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    format!("v2:{bytes}")
}

/// An unseen id carries its original first-attempt time. A receipt that has
/// expired cannot turn a delayed retry into a new launch. A modest future skew
/// is allowed, but a clock far ahead must be corrected before sending.
pub fn validate_created_at(
    created_at_ms: Option<i64>,
    now_ms: i64,
) -> Result<(), crate::error::DispatchError> {
    let Some(created_at) = created_at_ms else {
        return Err(crate::error::DispatchError::new(
            "send_upgrade_required",
            "Update this client before sending. Message confirmation now requires the original attempt time.",
        ));
    };
    if created_at <= 0 || created_at.saturating_sub(now_ms) > CLOCK_SKEW_MS {
        return Err(
            "The message time could not be verified. Check this device’s clock before sending."
                .into(),
        );
    }
    if now_ms.saturating_sub(created_at) >= RETENTION_MS {
        return Err(crate::error::DispatchError::delivery_unknown(
            "This message is outside the confirmation window. Review the conversation before copying it into a new draft.",
        ));
    }
    Ok(())
}

/// A client message id has to be safe to put in a key in a file on this
/// machine, and small enough that a hostile one cannot grow the ledger.
pub fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ID
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
}

pub fn path_for(chat_root: &Path) -> PathBuf {
    chat_root.join("receipts.json")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn receipt(at_ms: i64) -> Receipt {
        Receipt {
            state: ReceiptState::Accepted,
            digest: digest("hello", &[]),
            at_ms,
            event_at_ms: Some(at_ms),
        }
    }

    #[test]
    fn a_receipt_survives_being_written_and_read_back() {
        let dir = tempfile::tempdir().unwrap();
        let path = path_for(dir.path());
        let mut ledger = Ledger::load(path.clone(), 1_000).unwrap();
        ledger.put(key(None, "m-1"), receipt(1_000)).unwrap();
        ledger.save().unwrap();
        let reloaded = Ledger::load(path, 2_000).unwrap();
        assert_eq!(reloaded.get(&key(None, "m-1")), Some(&receipt(1_000)));
        // One device's id is not another's.
        assert!(reloaded.get(&key(Some("phone"), "m-1")).is_none());
    }

    #[test]
    fn receipts_keep_the_full_window_and_refuse_overflow_without_eviction() {
        let dir = tempfile::tempdir().unwrap();
        let path = path_for(dir.path());
        let mut ledger = Ledger::load(path.clone(), 0).unwrap();
        for index in 0..CAPACITY {
            ledger
                .put(key(None, &format!("m-{index}")), receipt(index as i64 + 1))
                .unwrap();
        }
        assert!(ledger.put(key(None, "overflow"), receipt(10_000)).is_err());
        assert!(ledger.get(&key(None, "m-0")).is_some());
        let mut pending = receipt(0);
        pending.state = ReceiptState::Pending;
        ledger.put(key(None, "m-0"), pending).unwrap();
        ledger.save().unwrap();
        let expired =
            Ledger::load(path, RETENTION_MS + CLOCK_SKEW_MS + CAPACITY as i64 + 1).unwrap();
        assert_eq!(expired.entries.len(), 1);
        assert_eq!(
            expired.get(&key(None, "m-0")).unwrap().state,
            ReceiptState::Pending
        );
    }

    #[test]
    fn unreadable_receipts_are_not_missing_receipts() {
        let dir = tempfile::tempdir().unwrap();
        let path = path_for(dir.path());
        assert!(Ledger::load(path.clone(), 0).unwrap().entries.is_empty());
        fs::write(&path, b"{broken").unwrap();
        assert!(Ledger::load(path.clone(), 0).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"{broken");
        fs::remove_file(&path).unwrap();
        fs::create_dir(&path).unwrap();
        assert!(Ledger::load(path.clone(), 0).is_err());
        fs::remove_dir(&path).unwrap();
        let file = File::create(&path).unwrap();
        file.set_len(MAX_BYTES + 1).unwrap();
        assert!(Ledger::load(path, 0).is_err());
    }

    #[test]
    fn save_does_not_recreate_a_removed_conversation() {
        let dir = tempfile::tempdir().unwrap();
        let conversation = dir.path().join("conversation");
        fs::create_dir(&conversation).unwrap();
        let ledger = Ledger::load(path_for(&conversation), 0).unwrap();
        fs::remove_dir(&conversation).unwrap();
        assert!(ledger.save().is_err());
        assert!(!conversation.exists());
    }

    #[test]
    fn accepted_receipts_outlive_the_allowed_client_clock_skew() {
        let root = tempfile::tempdir().unwrap();
        let path = path_for(root.path());
        let at = RETENTION_MS;
        let mut ledger = Ledger::load(path.clone(), at).unwrap();
        ledger.put(key(None, "clock-ahead"), receipt(at)).unwrap();
        ledger.save().unwrap();
        let retry_at = at + RETENTION_MS + CLOCK_SKEW_MS - 1;
        assert!(validate_created_at(Some(at + CLOCK_SKEW_MS), retry_at).is_ok());
        assert!(
            Ledger::load(path, retry_at)
                .unwrap()
                .get(&key(None, "clock-ahead"))
                .is_some()
        );
    }

    #[test]
    fn age_checks_distinguish_expiry_from_a_new_attempt() {
        let now = RETENTION_MS * 2;
        assert!(validate_created_at(Some(now), now).is_ok());
        assert!(validate_created_at(Some(now - RETENTION_MS + 1), now).is_ok());
        assert_eq!(
            validate_created_at(Some(now - RETENTION_MS), now)
                .unwrap_err()
                .code,
            crate::error::DELIVERY_UNKNOWN
        );
        assert!(validate_created_at(Some(now + 5 * 60 * 1000 + 1), now).is_err());
        assert!(validate_created_at(None, now).is_err());
        assert!(validate_created_at(Some(i64::MIN), now).is_err());
    }

    #[test]
    fn acceptance_serializes_one_conversation_and_removal_but_not_other_work() {
        use std::sync::mpsc;
        use std::time::Duration;
        let root = tempfile::tempdir().unwrap();
        let held = Operation::conversation(root.path(), "one").unwrap();
        // Different conversations may prepare and accept independently.
        let other = Operation::conversation(root.path(), "two").unwrap();
        drop(other);
        let (ready, waiting) = mpsc::channel();
        let (entered, result) = mpsc::channel();
        std::thread::scope(|scope| {
            scope.spawn(|| {
                ready.send(()).unwrap();
                let _same = Operation::conversation(root.path(), "one").unwrap();
                entered.send(()).unwrap();
            });
            waiting.recv_timeout(Duration::from_secs(2)).unwrap();
            assert!(result.recv_timeout(Duration::from_millis(50)).is_err());
            drop(held);
            result.recv_timeout(Duration::from_secs(2)).unwrap();
        });
        let held = Operation::conversation(root.path(), "one").unwrap();
        let (entered, result) = mpsc::channel();
        std::thread::scope(|scope| {
            scope.spawn(|| {
                let _remove = Operation::removal(root.path()).unwrap();
                entered.send(()).unwrap();
            });
            assert!(result.recv_timeout(Duration::from_millis(50)).is_err());
            drop(held);
            result.recv_timeout(Duration::from_secs(2)).unwrap();
        });
    }

    #[test]
    fn the_digest_covers_the_files_as_well_as_the_words() {
        assert_eq!(digest("hello", &[]), digest("hello", &[]));
        assert_ne!(digest("hello", &[]), digest("hello!", &[]));
        // Delimiters in text must not masquerade as an attachment boundary.
        assert_ne!(
            digest("hello\u{1f}file", &[]),
            digest("hello", &["file".into()])
        );
        assert_ne!(digest("hello", &[]), digest("hello", &["file-1".into()]));
        assert_ne!(
            digest("hello", &["a".into(), "b".into()]),
            digest("hello", &["ab".into()])
        );
    }

    #[test]
    fn an_id_that_could_shape_a_key_is_refused() {
        assert!(valid_id("3F2504E0-4F89-11D3-9A0C-0305E82C3301"));
        assert!(!valid_id(""));
        assert!(!valid_id("has|a|separator"));
        assert!(!valid_id("../escape"));
        assert!(!valid_id(&"x".repeat(MAX_ID + 1)));
    }
}
