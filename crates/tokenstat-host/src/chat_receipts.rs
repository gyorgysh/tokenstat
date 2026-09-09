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
use std::fs;
use std::path::{Path, PathBuf};

/// Thirty days. A client returning later than this is starting again rather
/// than resending, and a receipt that is gone is not evidence that the turn
/// never ran, which is why the client is told to look at the conversation
/// rather than being allowed to replay into it.
pub const RETENTION_MS: i64 = 30 * 24 * 60 * 60 * 1000;

/// Per conversation. Long enough for a device that was away for a while,
/// short enough that the file is read and written whole beside every send.
const CAPACITY: usize = 64;

/// The longest client message id accepted, and the alphabet it may use. A
/// UUID fits with room to spare. The bound matters because the id becomes
/// part of a key in a file this host writes.
const MAX_ID: usize = 128;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ReceiptState {
    /// The agent was started and the message is on the timeline.
    Accepted,
    /// The host got as far as starting the work and not as far as recording
    /// the end of it. Reconciled against the timeline, never replayed.
    Pending,
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
    pub fn load(path: PathBuf, now_ms: i64) -> Self {
        let mut entries = fs::read(&path)
            .ok()
            .and_then(|body| serde_json::from_slice::<HashMap<String, Receipt>>(&body).ok())
            .unwrap_or_default();
        entries.retain(|_, receipt| now_ms.saturating_sub(receipt.at_ms) < RETENTION_MS);
        Self { path, entries }
    }

    pub fn get(&self, key: &str) -> Option<&Receipt> {
        self.entries.get(key)
    }

    pub fn put(&mut self, key: String, receipt: Receipt) {
        self.entries.insert(key, receipt);
        while self.entries.len() > CAPACITY {
            let Some(oldest) = self
                .entries
                .iter()
                .min_by_key(|(key, receipt)| (receipt.at_ms, (*key).clone()))
                .map(|(key, _)| key.clone())
            else {
                break;
            };
            self.entries.remove(&oldest);
        }
    }

    pub fn remove(&mut self, key: &str) {
        self.entries.remove(key);
    }

    pub fn save(&self) -> Result<(), String> {
        let parent = self.path.parent().ok_or("invalid receipts path")?;
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        let body = serde_json::to_vec(&self.entries).map_err(|e| e.to_string())?;
        let temp = self.path.with_extension("tmp");
        fs::write(&temp, body).map_err(|e| e.to_string())?;
        fs::rename(&temp, &self.path).map_err(|e| e.to_string())
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
    hash.update(text.as_bytes());
    for id in attachment_ids {
        hash.update([0x1f]);
        hash.update(id.as_bytes());
    }
    hash.finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
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
        let mut ledger = Ledger::load(path.clone(), 1_000);
        ledger.put(key(None, "m-1"), receipt(1_000));
        ledger.save().unwrap();
        let reloaded = Ledger::load(path, 2_000);
        assert_eq!(reloaded.get(&key(None, "m-1")), Some(&receipt(1_000)));
        // One device's id is not another's.
        assert!(reloaded.get(&key(Some("phone"), "m-1")).is_none());
    }

    #[test]
    fn receipts_expire_and_stay_bounded() {
        let dir = tempfile::tempdir().unwrap();
        let path = path_for(dir.path());
        let mut ledger = Ledger::load(path.clone(), 0);
        for index in 0..(CAPACITY + 10) {
            ledger.put(key(None, &format!("m-{index}")), receipt(index as i64 + 1));
        }
        assert_eq!(ledger.entries.len(), CAPACITY);
        // The oldest went first.
        assert!(ledger.get(&key(None, "m-0")).is_none());
        assert!(ledger.get(&key(None, "m-73")).is_some());
        ledger.save().unwrap();
        let expired = Ledger::load(path, RETENTION_MS + 1_000);
        assert!(expired.get(&key(None, "m-73")).is_none());
    }

    #[test]
    fn the_digest_covers_the_files_as_well_as_the_words() {
        assert_eq!(digest("hello", &[]), digest("hello", &[]));
        assert_ne!(digest("hello", &[]), digest("hello!", &[]));
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
