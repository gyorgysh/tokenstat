// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Durable, scoped unsent messages. Every transaction reads the latest file
//! under the process and filesystem locks before publishing an atomic update.
//! This store does not transmit; a persisted `sending` item needs a receipt.

use crate::{
    drafts::{Attachment, coordination::Registration, storage},
    work::{Reference, Scope, continuity::Date, text},
};
use anyhow::{Context, ensure};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet},
    fs::{File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
};

pub const CAPACITY: usize = 20;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Delivery {
    #[default]
    Waiting,
    Sending,
    DeliveryUnknown,
    Failed,
    NeedsReview,
    Ready,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    pub text: String,
    pub attachments: Vec<Attachment>,
    pub delivery: Delivery,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_attempt_at: Option<Date>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attempted_at: Option<Date>,
    #[serde(
        default,
        deserialize_with = "super::wire::number::u64_optional",
        skip_serializing_if = "Option::is_none"
    )]
    pub expected_revision: Option<u64>,
    pub when_connected: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_draft_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sign_in_backend: Option<String>,
}
fn option_equal(a: &Option<String>, b: &Option<String>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => text::equal(a, b),
        (None, None) => true,
        _ => false,
    }
}
impl PartialEq for Message {
    fn eq(&self, other: &Self) -> bool {
        self.same_writing(other)
            && self.delivery == other.delivery
            && self.first_attempt_at == other.first_attempt_at
            && self.attempted_at == other.attempted_at
            && self.expected_revision == other.expected_revision
            && self.when_connected == other.when_connected
            && option_equal(&self.source_draft_text, &other.source_draft_text)
            && option_equal(&self.sign_in_backend, &other.sign_in_backend)
    }
}
impl Message {
    pub fn needs_receipt(&self) -> bool {
        matches!(self.delivery, Delivery::Sending | Delivery::DeliveryUnknown)
    }
    pub fn can_edit(&self) -> bool {
        !self.needs_receipt()
    }
    pub fn same_writing(&self, other: &Self) -> bool {
        text::equal(&self.id, &other.id)
            && text::equal(&self.text, &other.text)
            && self.attachments == other.attachments
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Queue {
    pub reference: Reference,
    pub items: Vec<Message>,
}
#[derive(Default, Deserialize, Serialize)]
struct Envelope {
    version: u32,
    queues: BTreeMap<String, Queue>,
}
impl Envelope {
    fn empty() -> Self {
        Self {
            version: 1,
            queues: BTreeMap::new(),
        }
    }
}

/// A separate instance may use the same path. The process mutex is necessary:
/// POSIX record locks alone do not serialize threads in the same process.
#[derive(Clone)]
pub struct Store {
    directory: PathBuf,
    registration: Registration,
    limit: usize,
}
impl Store {
    pub fn at(directory: PathBuf, limit: usize) -> Self {
        Self {
            registration: Registration::new(directory.clone()),
            directory,
            limit: limit.clamp(1, storage::MAX_FILE_BYTES),
        }
    }
    fn locked<T>(&self, operation: impl FnOnce(&Self) -> anyhow::Result<T>) -> anyhow::Result<T> {
        static SERIAL: OnceLock<Mutex<()>> = OnceLock::new();
        let _serial = SERIAL
            .get_or_init(|| Mutex::new(()))
            .lock()
            .map_err(|_| anyhow::anyhow!("Outbox lock was poisoned"))?;
        self.registration.get()?;
        storage::private_directory(&self.directory)?;
        let lock = storage::open_regular(&self.directory.join("outbox.lock"), true)?;
        storage::record_lock(&lock, true)?;
        operation(self)
    }
    fn read(&self) -> anyhow::Result<Envelope> {
        let file = match storage::open_regular(&self.directory.join("outbox.v1.json"), false) {
            Ok(file) => file,
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
            {
                return Ok(Envelope::empty());
            }
            Err(error) => return Err(error),
        };
        let mut bytes = Vec::new();
        file.take(self.limit as u64 + 1).read_to_end(&mut bytes)?;
        ensure!(bytes.len() <= self.limit, "Outbox is too large");
        let envelope: Envelope = serde_json::from_slice(&bytes).context("Outbox is unreadable")?;
        ensure!(
            envelope.version == 1
                && envelope.queues.iter().all(|(key, queue)| {
                    queue
                        .reference
                        .conversation_key()
                        .is_some_and(|derived| text::equal(&derived, key))
                        && valid_items(&queue.items)
                }),
            "Outbox contains invalid records"
        );
        Ok(envelope)
    }
    pub fn items(&self, reference: &Reference) -> anyhow::Result<Vec<Message>> {
        let key = reference
            .conversation_key()
            .context("Invalid conversation reference")?;
        self.locked(|store| {
            Ok(store
                .read()?
                .queues
                .get(&key)
                .map(|queue| queue.items.clone())
                .unwrap_or_default())
        })
    }
    pub fn queues(&self, scope: &Scope) -> anyhow::Result<Vec<Queue>> {
        self.locked(|store| {
            Ok(store
                .read()?
                .queues
                .into_values()
                .filter(|queue| &queue.reference.scope == scope)
                .collect())
        })
    }
    /// Mutations run against the latest on-disk version and must finish before
    /// any send. A failure leaves the previous bytes and all other queues intact.
    pub fn update(
        &self,
        reference: &Reference,
        mutation: impl FnOnce(&mut Vec<Message>) -> anyhow::Result<()>,
    ) -> anyhow::Result<Vec<Message>> {
        let key = reference
            .conversation_key()
            .context("Invalid conversation reference")?;
        self.locked(|store| {
            let mut envelope = store.read()?;
            let mut items = envelope
                .queues
                .get(&key)
                .map(|q| q.items.clone())
                .unwrap_or_default();
            let original = items.clone();
            mutation(&mut items)?;
            if items == original {
                return Ok(items);
            }
            ensure!(items.len() <= CAPACITY, "Outbox queue is full");
            ensure!(
                valid_items(&items),
                "Outbox contains invalid message identities"
            );
            if items.is_empty() {
                envelope.queues.remove(&key);
            } else {
                let mut root = reference.clone();
                root.anchor = None;
                envelope.queues.insert(
                    key,
                    Queue {
                        reference: root,
                        items: items.clone(),
                    },
                );
            }
            let bytes = storage::encode_value(&envelope)?;
            ensure!(bytes.len() <= store.limit, "Outbox is too large");
            atomic_write(&store.directory, &bytes)?;
            Ok(items)
        })
    }
    pub fn prepare(
        &self,
        reference: &Reference,
        expected: &Message,
        revision: u64,
    ) -> anyhow::Result<Message> {
        let items = self.update(reference, |items| {
            let item = items
                .iter_mut()
                .find(|item| text::equal(&item.id, &expected.id))
                .context("Pending message changed")?;
            ensure!(
                item.same_writing(expected) && item.can_edit() && item.sign_in_backend.is_none(),
                "Pending message changed"
            );
            item.expected_revision = Some(revision);
            item.delivery = Delivery::Ready;
            Ok(())
        })?;
        items
            .into_iter()
            .find(|item| text::equal(&item.id, &expected.id))
            .context("Pending message changed")
    }
    pub fn accept(
        &self,
        reference: &Reference,
        item: &Message,
        revision: Option<u64>,
    ) -> anyhow::Result<Vec<Message>> {
        self.update(reference, |items| {
            items.retain(|current| !text::equal(&current.id, &item.id));
            if let Some(expected) = item.expected_revision
                && expected
                    .checked_add(1)
                    .is_some_and(|next| Some(next) == revision)
            {
                for successor in items.iter_mut().filter(|next| {
                    next.delivery == Delivery::Waiting && next.expected_revision == Some(expected)
                }) {
                    successor.expected_revision = revision;
                }
            }
            Ok(())
        })
    }
    pub fn reorder(
        &self,
        reference: &Reference,
        expected_ids: &[String],
        visible_order: &[String],
    ) -> anyhow::Result<Vec<Message>> {
        self.update(reference, |items| {
            ensure!(
                items.len() == expected_ids.len()
                    && items
                        .iter()
                        .zip(expected_ids)
                        .all(|(item, id)| text::equal(&item.id, id)),
                "Pending messages changed"
            );
            ensure!(
                unique(visible_order.iter().map(String::as_str))
                    && visible_order.iter().all(|id| expected_ids
                        .iter()
                        .any(|expected| text::equal(id, expected))),
                "Invalid visible order"
            );
            let old = items.clone();
            let mut ordered = visible_order.iter();
            for item in items
                .iter_mut()
                .filter(|item| visible_order.iter().any(|id| text::equal(id, &item.id)))
            {
                let id = ordered.next().context("Invalid visible order")?;
                *item = old
                    .iter()
                    .find(|item| text::equal(&item.id, id))
                    .context("Invalid visible order")?
                    .clone();
            }
            Ok(())
        })
    }
    /// A lease spans the complete asynchronous delivery in this process.
    pub fn begin_delivery(&self, reference: &Reference) -> anyhow::Result<Option<DeliveryLease>> {
        let key = reference
            .conversation_key()
            .context("Invalid conversation reference")?;
        let root = crate::drafts::coordination::normalized(&self.directory)?;
        let identity = (root, key);
        let mut active = active()
            .lock()
            .map_err(|_| anyhow::anyhow!("Outbox delivery lock was poisoned"))?;
        if active.insert(identity.clone()) {
            Ok(Some(DeliveryLease(identity)))
        } else {
            Ok(None)
        }
    }
}
fn active() -> &'static Mutex<HashSet<(PathBuf, String)>> {
    static ACTIVE: OnceLock<Mutex<HashSet<(PathBuf, String)>>> = OnceLock::new();
    ACTIVE.get_or_init(|| Mutex::new(HashSet::new()))
}
pub struct DeliveryLease((PathBuf, String));
impl Drop for DeliveryLease {
    fn drop(&mut self) {
        if let Ok(mut held) = active().lock() {
            held.remove(&self.0);
        }
    }
}
fn unique<'a>(values: impl IntoIterator<Item = &'a str>) -> bool {
    let mut seen: Vec<&str> = Vec::new();
    for value in values {
        if seen.iter().any(|old| text::equal(old, value)) {
            return false;
        }
        seen.push(value);
    }
    true
}
fn valid_items(items: &[Message]) -> bool {
    items.len() <= CAPACITY
        && items
            .iter()
            .all(|item| !item.id.is_empty() && item.id.len() <= 256)
        && unique(items.iter().map(|item| item.id.as_str()))
}
fn atomic_write(directory: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let temporary = directory.join(format!(
        ".outbox-{}-{}.tmp",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let mut created = false;
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&temporary)?;
        created = true;
        file.write_all(bytes)?;
        file.sync_all()?;
        std::fs::rename(&temporary, directory.join("outbox.v1.json"))?;
        File::open(directory)?.sync_all()?;
        Ok::<_, anyhow::Error>(())
    })();
    if created && result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}
#[cfg(test)]
#[path = "outbox_tests.rs"]
mod tests;
