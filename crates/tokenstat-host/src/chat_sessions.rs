// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Copyable native identifiers are references, never arbitrary resume credentials.
//! The complete private ledger survives timeline retention; only 64 recent,
//! deduplicated references travel in an inspection reply.

use std::collections::{HashMap, VecDeque};
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

use crate::chat::Conversation;

pub(crate) const VISIBLE_LIMIT: usize = 64;
const RECORD_BYTES: u64 = 2048;
const ARCHIVE: &str = "session-history.ndjson";

#[derive(PartialEq, Eq)]
enum LegacyFileIdentity {
    #[cfg(unix)]
    Unix(u64, u64),
    #[cfg(windows)]
    Windows(u64, [u8; 16]),
}

#[derive(PartialEq, Eq)]
struct LegacyKey {
    path: PathBuf,
    length: u64,
    modified: Option<SystemTime>,
    created: Option<SystemTime>,
    identity: Option<LegacyFileIdentity>,
    chat_id: String,
    backend: String,
    chat_created: i64,
    chat_updated: i64,
    resume: Vec<(String, String)>,
}

type LegacyCache = VecDeque<(LegacyKey, SessionInventory)>;
static LEGACY_CACHE: OnceLock<Mutex<LegacyCache>> = OnceLock::new();

fn legacy_file_identity(_file: &fs::File, _metadata: &fs::Metadata) -> Option<LegacyFileIdentity> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Some(LegacyFileIdentity::Unix(_metadata.dev(), _metadata.ino()))
    }
    #[cfg(windows)]
    {
        crate::win32::file_identity(_file)
            .map(|(volume, id)| LegacyFileIdentity::Windows(volume, id))
    }
    #[cfg(not(any(unix, windows)))]
    None
}

fn legacy_projection(directory: &Path, chat: &Conversation) -> Result<SessionInventory, String> {
    let path = directory.join("events.ndjson");
    let Some(file) = open_legacy_transcript(&path)? else {
        return Ok(SessionInventory::default());
    };
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    let candidates = candidates(chat);
    let key = LegacyKey {
        path,
        length: metadata.len(),
        modified: metadata.modified().ok(),
        created: metadata.created().ok(),
        identity: legacy_file_identity(&file, &metadata),
        chat_id: chat.id.clone(),
        backend: chat.backend.clone(),
        chat_created: chat.created_at_ms,
        chat_updated: chat.updated_at_ms,
        resume: candidates
            .iter()
            .map(|entry| (entry.backend.clone(), entry.id.clone()))
            .collect(),
    };
    // Some remote filesystems do not report stable IDs. Re-read those files
    // rather than treating matching timestamps as proof of identity.
    let cacheable = key.identity.is_some() && key.modified.is_some();
    let cache = LEGACY_CACHE.get_or_init(|| Mutex::new(VecDeque::new()));
    if cacheable
        && let Some((_, inventory)) = cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .find(|(stored, _)| *stored == key)
    {
        return Ok(inventory.clone());
    }
    let legacy = legacy_entries_from_file(file, chat)?;
    let mut inventory = SessionInventory {
        total: legacy.len() as u64,
        entries: legacy.iter().rev().take(VISIBLE_LIMIT).cloned().collect(),
        ..Default::default()
    };
    inventory.entries.reverse();
    // An older still-saved candidate must remain visible without double-counting
    // its identity. Cache only the bounded projection, never the entire ledger.
    for candidate in candidates {
        if !inventory
            .entries
            .iter()
            .any(|entry| same_identity(entry, &candidate))
            && let Some(entry) = legacy.iter().find(|entry| same_identity(entry, &candidate))
        {
            inventory.entries.push(entry.clone());
            if inventory.entries.len() > VISIBLE_LIMIT {
                inventory.entries.remove(0);
            }
        }
    }
    if cacheable {
        let mut cache = cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        cache.push_back((key, inventory.clone()));
        while cache.len() > 16 {
            cache.pop_front();
        }
    }
    Ok(inventory)
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SessionReference {
    pub backend: String,
    pub id: String,
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_conversation_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub first_seen_at_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_seen_at_ms: Option<i64>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SessionInventory {
    pub entries: Vec<SessionReference>,
    pub total: u64,
    pub truncated: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archive_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript_path: Option<String>,
}

/// These are the session/thread identifiers emitted by each native CLI, not
/// its auth token, serialized state or an arbitrary launcher resume argument.
pub(crate) fn valid_native_id(backend: &str, id: &str) -> bool {
    match backend {
        "claude" | "codex" | "cursor" | "muse" | "grok" | "agy" => {
            id.len() == 36
                && id.bytes().enumerate().all(|(at, byte)| {
                    if matches!(at, 8 | 13 | 18 | 23) {
                        byte == b'-'
                    } else {
                        byte.is_ascii_hexdigit()
                    }
                })
                && id.bytes().any(|byte| byte != b'0' && byte != b'-')
        }
        // OpenCode's Identifier generator uses a 12-hex timestamp followed by
        // 14 base62 characters, with the session-specific `ses_` prefix.
        "opencode" | "opencode2" => id.strip_prefix("ses_").is_some_and(|tail| {
            tail.len() == 26
                && tail.bytes().take(12).all(|byte| byte.is_ascii_hexdigit())
                && tail
                    .bytes()
                    .skip(12)
                    .all(|byte| byte.is_ascii_alphanumeric())
        }),
        _ => false,
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct Record {
    /// True exactly once for this backend/id/source identity, so the complete
    /// total can be counted while keeping memory bounded to the visible tail.
    first: bool,
    #[serde(flatten)]
    entry: SessionReference,
}

fn same_identity(a: &SessionReference, b: &SessionReference) -> bool {
    a.backend == b.backend && a.id == b.id && a.source_conversation_id == b.source_conversation_id
}

fn read_records(path: &Path, mut visit: impl FnMut(Record)) -> Result<u64, String> {
    if fs::symlink_metadata(path)
        .is_ok_and(|metadata| !metadata.is_file() || metadata.file_type().is_symlink())
    {
        return Err("session history is not a regular private file".into());
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let file = match options.open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error.to_string()),
    };
    let mut verified = 0;
    let mut input = BufReader::new(file);
    loop {
        let mut line = Vec::new();
        let size = input
            .by_ref()
            .take(RECORD_BYTES + 1)
            .read_until(b'\n', &mut line)
            .map_err(|error| error.to_string())?;
        if size == 0 {
            break;
        }
        if !line.ends_with(b"\n")
            && size as u64 <= RECORD_BYTES
            && input
                .fill_buf()
                .map_err(|error| error.to_string())?
                .is_empty()
        {
            // An append interrupted before its final newline is uncommitted.
            // Readers retain the verified prefix; the next writer truncates
            // only this trailing fragment before appending a complete record.
            break;
        }
        if size as u64 > RECORD_BYTES || !line.ends_with(b"\n") {
            return Err("session history contains an incomplete record".into());
        }
        let record: Record =
            serde_json::from_slice(&line).map_err(|_| "session history could not be verified")?;
        if valid_native_id(&record.entry.backend, &record.entry.id) {
            visit(record);
        }
        verified += size as u64;
    }
    Ok(verified)
}

fn tail(directory: &Path) -> Result<SessionInventory, String> {
    let mut inventory = SessionInventory::default();
    read_records(&directory.join(ARCHIVE), |record| {
        inventory.total = inventory.total.saturating_add(u64::from(record.first));
        if let Some(at) = inventory
            .entries
            .iter()
            .position(|entry| same_identity(entry, &record.entry))
        {
            inventory.entries.remove(at);
        }
        inventory.entries.push(record.entry);
        if inventory.entries.len() > VISIBLE_LIMIT {
            inventory.entries.remove(0);
        }
    })?;
    Ok(inventory)
}

fn find(directory: &Path, entry: &SessionReference) -> Result<Option<SessionReference>, String> {
    let mut found = None;
    read_records(&directory.join(ARCHIVE), |record| {
        if same_identity(&record.entry, entry) {
            found = Some(record.entry);
        }
    })?;
    Ok(found)
}

fn append(directory: &Path, record: Record) -> Result<(), String> {
    fs::create_dir_all(directory).map_err(|error| error.to_string())?;
    let path = directory.join(ARCHIVE);
    let verified = read_records(&path, |_| {})?;
    let mut options = OpenOptions::new();
    options.create(true).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    if fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        return Err("session history is not a regular private file".into());
    }
    let mut file = options.open(&path).map_err(|error| error.to_string())?;
    if file.metadata().map_err(|error| error.to_string())?.len() > verified {
        file.set_len(verified).map_err(|error| error.to_string())?;
    }
    file.seek(SeekFrom::End(0))
        .map_err(|error| error.to_string())?;
    let mut bytes = serde_json::to_vec(&record).map_err(|error| error.to_string())?;
    bytes.push(b'\n');
    file.write_all(&bytes)
        .and_then(|()| file.sync_data())
        .map_err(|error| error.to_string())
}

fn candidate(chat: &Conversation, backend: &str, id: &str) -> Option<SessionReference> {
    valid_native_id(backend, id).then(|| SessionReference {
        backend: backend.into(),
        id: id.into(),
        status: "saved".into(),
        source_conversation_id: Some(chat.id.clone()),
        first_seen_at_ms: Some(chat.created_at_ms),
        last_seen_at_ms: Some(chat.updated_at_ms),
    })
}

fn candidates(chat: &Conversation) -> Vec<SessionReference> {
    let mut tokens: HashMap<&str, &str> = chat
        .resume_tokens
        .iter()
        .map(|(backend, id)| (backend.as_str(), id.as_str()))
        .collect();
    if chat.resume_tokens.is_empty()
        && let Some(id) = chat.resume_token.as_deref()
    {
        tokens.entry(&chat.backend).or_insert(id);
    }
    let mut entries: Vec<_> = tokens
        .into_iter()
        .filter_map(|(backend, id)| candidate(chat, backend, id))
        .collect();
    entries.sort_by(|a, b| a.backend.cmp(&b.backend));
    entries
}

/// Call while holding chat's cross-process lifecycle lock, before replacing
/// any old resume value. Legacy credentials are filtered, never copied raw.
pub(crate) fn remember(directory: &Path, chat: &Conversation) -> Result<(), String> {
    if !directory.join(ARCHIVE).exists() {
        // Publishing a partially migrated ledger would make the remaining
        // legacy IDs invisible on every subsequent read. Commit the complete
        // initial projection together, then use append-only updates below.
        let legacy = legacy_entries(directory, chat)?;
        fs::create_dir_all(directory).map_err(|error| error.to_string())?;
        let mut initial =
            tempfile::NamedTempFile::new_in(directory).map_err(|error| error.to_string())?;
        for entry in legacy {
            serde_json::to_writer(&mut initial, &Record { first: true, entry })
                .map_err(|error| error.to_string())?;
            initial
                .write_all(b"\n")
                .map_err(|error| error.to_string())?;
        }
        initial
            .as_file()
            .sync_all()
            .map_err(|error| error.to_string())?;
        initial
            .persist_noclobber(directory.join(ARCHIVE))
            .map_err(|error| error.to_string())?;
        #[cfg(unix)]
        fs::File::open(directory)
            .and_then(|file| file.sync_all())
            .map_err(|error| error.to_string())?;
    }
    for entry in candidates(chat) {
        if find(directory, &entry)?.is_none() {
            append(directory, Record { first: true, entry })?;
        }
    }
    Ok(())
}

pub(crate) fn observed(
    directory: &Path,
    chat: &Conversation,
    backend: &str,
    id: &str,
    at_ms: i64,
) -> Result<(), String> {
    let Some(mut entry) = candidate(chat, backend, id) else {
        return Ok(());
    };
    let previous = find(directory, &entry)?;
    entry.first_seen_at_ms = previous
        .as_ref()
        .and_then(|entry| entry.first_seen_at_ms)
        .or(Some(at_ms));
    entry.last_seen_at_ms = Some(at_ms);
    if previous.as_ref() != Some(&entry) {
        append(
            directory,
            Record {
                first: previous.is_none(),
                entry,
            },
        )?;
    }
    Ok(())
}

pub(crate) fn invalidated(
    directory: &Path,
    chat: &Conversation,
    backend: &str,
    id: &str,
    at_ms: i64,
) -> Result<(), String> {
    let Some(mut entry) = candidate(chat, backend, id) else {
        return Ok(());
    };
    let previous = find(directory, &entry)?;
    if previous
        .as_ref()
        .is_some_and(|entry| entry.status == "historical")
    {
        return Ok(());
    }
    entry.first_seen_at_ms = previous
        .as_ref()
        .and_then(|entry| entry.first_seen_at_ms)
        .or(Some(at_ms));
    entry.last_seen_at_ms = Some(at_ms);
    entry.status = "historical".into();
    append(
        directory,
        Record {
            first: previous.is_none(),
            entry,
        },
    )
}

/// No disk writes or CLI probes from an inspector read. A legacy current
/// token can be displayed before its first ledger migration on a mutation.
pub(crate) fn inventory(directory: &Path, chat: &Conversation) -> SessionInventory {
    let loaded = tail(directory);
    let corrupt = loaded.is_err();
    let mut inventory = loaded.unwrap_or_default();
    if !directory.join(ARCHIVE).exists()
        && let Ok(legacy) = legacy_projection(directory, chat)
    {
        inventory = legacy;
    }
    let candidates = candidates(chat);
    for candidate in &candidates {
        if !inventory
            .entries
            .iter()
            .any(|entry| same_identity(entry, candidate))
        {
            let saved = find(directory, candidate).ok().flatten();
            if saved.is_none() {
                inventory.total = inventory.total.saturating_add(1);
            }
            inventory
                .entries
                .push(saved.unwrap_or_else(|| candidate.clone()));
            if inventory.entries.len() > VISIBLE_LIMIT {
                inventory.entries.remove(0);
            }
        }
    }
    for entry in &mut inventory.entries {
        let resumable = entry.status != "historical"
            && entry.source_conversation_id.as_deref() == Some(chat.id.as_str())
            && candidates
                .iter()
                .any(|candidate| same_identity(entry, candidate));
        entry.status = if resumable {
            if entry.backend == chat.backend {
                "current"
            } else {
                "saved"
            }
        } else {
            "historical"
        }
        .into();
    }
    inventory.entries.reverse();
    inventory
        .entries
        .sort_by_key(|entry| match entry.status.as_str() {
            "current" => 0,
            "saved" => 1,
            _ => 2,
        });
    inventory.truncated = corrupt || inventory.total > inventory.entries.len() as u64;
    inventory.archive_path = directory
        .join(ARCHIVE)
        .is_file()
        .then(|| directory.join(ARCHIVE).display().to_string());
    inventory.transcript_path = directory
        .join("events.ndjson")
        .is_file()
        .then(|| directory.join("events.ndjson").display().to_string());
    inventory
}

fn open_legacy_transcript(path: &Path) -> Result<Option<fs::File>, String> {
    if fs::symlink_metadata(path)
        .is_ok_and(|metadata| !metadata.is_file() || metadata.file_type().is_symlink())
    {
        return Err("session transcript is not a regular private file".into());
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000); // FILE_FLAG_OPEN_REPARSE_POINT
    }
    let file = match options.open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.to_string()),
    };
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err("session transcript is not a regular private file".into());
    }
    Ok(Some(file))
}

fn legacy_entries(directory: &Path, chat: &Conversation) -> Result<Vec<SessionReference>, String> {
    let Some(file) = open_legacy_transcript(&directory.join("events.ndjson"))? else {
        return Ok(Vec::new());
    };
    legacy_entries_from_file(file, chat)
}

fn legacy_entries_from_file(
    file: fs::File,
    chat: &Conversation,
) -> Result<Vec<SessionReference>, String> {
    let mut input = BufReader::new(file);
    let mut entries: Vec<SessionReference> = Vec::new();
    loop {
        let mut line = Vec::new();
        let size = input
            .by_ref()
            .take(16 * 1024 * 1024 + 1)
            .read_until(b'\n', &mut line)
            .map_err(|error| error.to_string())?;
        if size == 0 {
            break;
        }
        if !line.ends_with(b"\n") {
            loop {
                let buffer = input.fill_buf().map_err(|error| error.to_string())?;
                if buffer.is_empty() {
                    break;
                }
                let newline = buffer.iter().position(|byte| *byte == b'\n');
                let consume = newline.map_or(buffer.len(), |at| at + 1);
                input.consume(consume);
                if newline.is_some() {
                    break;
                }
            }
            continue;
        }
        let Ok(record) = serde_json::from_slice::<serde_json::Value>(&line) else {
            continue;
        };
        if record["kind"] != "agent" || record["event"]["kind"] != "session" {
            continue;
        }
        let (Some(backend), Some(id)) =
            (record["backend"].as_str(), record["event"]["id"].as_str())
        else {
            continue;
        };
        let Some(mut entry) = candidate(chat, backend, id) else {
            continue;
        };
        let at_ms = record["at_ms"].as_i64().or_else(|| record["atMs"].as_i64());
        entry.first_seen_at_ms = at_ms;
        entry.last_seen_at_ms = at_ms;
        if let Some(at) = entries
            .iter()
            .position(|previous| same_identity(previous, &entry))
        {
            let previous = entries.remove(at);
            entry.first_seen_at_ms = previous.first_seen_at_ms;
        }
        entries.push(entry);
    }
    Ok(entries)
}

/// A fork inherits references to the old transcript, never resume authority.
pub(crate) fn inherit(source: &Path, destination: &Path) -> Result<(), String> {
    let mut failure = None;
    read_records(&source.join(ARCHIVE), |mut record| {
        if failure.is_none() {
            record.entry.status = "historical".into();
            failure = append(destination, record).err();
        }
    })?;
    failure.map_or(Ok(()), Err)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const FIRST: &str = "11111111-1111-4111-8111-111111111111";
    const SECOND: &str = "22222222-2222-4222-8222-222222222222";

    fn chat() -> Conversation {
        serde_json::from_value(json!({"id":"chat-test","workspaceId":"test","title":"Test","backend":"claude","createdAtMs":1,"updatedAtMs":2})).unwrap()
    }

    #[test]
    fn only_known_native_identifiers_are_copyable() {
        for backend in ["claude", "codex", "cursor", "muse", "grok", "agy"] {
            assert!(valid_native_id(backend, FIRST));
            for id in [
                "session-name",
                "eyJhbGciOiJIUzI1NiJ9.secret",
                "/private/session.json",
                "00000000-0000-0000-0000-000000000000",
            ] {
                assert!(!valid_native_id(backend, id));
            }
        }
        assert!(valid_native_id(
            "opencode",
            "ses_012345abcdef0123456789abcd"
        ));
        assert!(!valid_native_id("opencode2", "ses_secret"));
        assert!(!valid_native_id("sh", FIRST));
    }

    #[test]
    fn replacement_and_invalidation_preserve_history_without_resume_authority() {
        let temp = tempfile::tempdir().unwrap();
        let mut chat = chat();
        chat.resume_token = Some(FIRST.into());
        remember(temp.path(), &chat).unwrap();
        observed(temp.path(), &chat, "claude", SECOND, 5).unwrap();
        chat.resume_tokens.insert("claude".into(), SECOND.into());
        let inventory = inventory(temp.path(), &chat);
        assert_eq!(inventory.total, 2);
        assert_eq!(inventory.entries[0].id, SECOND);
        assert_eq!(inventory.entries[0].status, "current");
        assert_eq!(inventory.entries[1].status, "historical");
        invalidated(temp.path(), &chat, "claude", SECOND, 6).unwrap();
        // Durable resume credentials may remain until a replacement reports.
        assert!(
            super::inventory(temp.path(), &chat)
                .entries
                .iter()
                .all(|entry| entry.status == "historical")
        );
        observed(temp.path(), &chat, "claude", SECOND, 7).unwrap();
        assert_eq!(
            super::inventory(temp.path(), &chat).entries[0].status,
            "current"
        );
    }

    #[test]
    fn legacy_sessions_bootstrap_read_only_and_deduplicate_current_id() {
        let temp = tempfile::tempdir().unwrap();
        let mut chat = chat();
        let events = (1..=70).map(|number| {
            json!({"kind":"agent","backend":"claude","at_ms":number,"event":{"kind":"session","id":format!("{number:08x}-1111-4111-8111-111111111111")}}).to_string() + "\n"
        }).collect::<String>();
        fs::write(temp.path().join("events.ndjson"), events).unwrap();
        chat.resume_token = Some("00000001-1111-4111-8111-111111111111".into());
        let loaded = inventory(temp.path(), &chat);
        assert_eq!(loaded.total, 70);
        assert_eq!(loaded.entries.len(), VISIBLE_LIMIT);
        assert_eq!(loaded.entries[0].status, "current");
        assert!(loaded.truncated);
        assert!(!temp.path().join(ARCHIVE).exists());
        remember(temp.path(), &chat).unwrap();
        assert_eq!(inventory(temp.path(), &chat).total, 70);
        assert_eq!(
            read_records(&temp.path().join(ARCHIVE), |_| {}).unwrap(),
            fs::metadata(temp.path().join(ARCHIVE)).unwrap().len()
        );
    }

    #[test]
    fn legacy_projection_cache_is_invalidated_by_transcript_and_owner_changes() {
        let temp = tempfile::tempdir().unwrap();
        let mut chat = chat();
        let path = temp.path().join("events.ndjson");
        let row = |id: &str| {
            json!({"kind":"agent","backend":"claude","at_ms":3,"event":{"kind":"session","id":id}})
                .to_string()
                + "\n"
        };
        fs::write(&path, row(FIRST)).unwrap();
        let original = open_legacy_transcript(&path).unwrap().unwrap();
        let original_identity = legacy_file_identity(&original, &original.metadata().unwrap());
        assert_eq!(inventory(temp.path(), &chat).entries[0].id, FIRST);
        // Atomic replacement can have the same length and timestamps. The
        // opened file's identity still retires the old projection.
        let previous_time = fs::metadata(&path).unwrap().modified().unwrap();
        let replacement = temp.path().join("replacement");
        fs::write(&replacement, row(SECOND)).unwrap();
        fs::File::options()
            .write(true)
            .open(&replacement)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(previous_time))
            .unwrap();
        fs::rename(replacement, &path).unwrap();
        assert_eq!(inventory(temp.path(), &chat).entries[0].id, SECOND);
        let replacement = open_legacy_transcript(&path).unwrap().unwrap();
        let replacement_identity =
            legacy_file_identity(&replacement, &replacement.metadata().unwrap());
        if original_identity.is_some() {
            assert!(original_identity != replacement_identity);
        }
        // Parse the same handle from which the identity and metadata came,
        // even if the name was replaced between opening and reading.
        assert_eq!(
            legacy_entries_from_file(original, &chat).unwrap()[0].id,
            FIRST
        );
        chat.id = "another-owner".into();
        let next = inventory(temp.path(), &chat);
        assert_eq!(
            next.entries[0].source_conversation_id.as_deref(),
            Some("another-owner")
        );
        OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(row(FIRST).as_bytes())
            .unwrap();
        assert_eq!(inventory(temp.path(), &chat).total, 2);
        assert!(!temp.path().join(ARCHIVE).exists());
    }

    #[test]
    fn interrupted_initial_migration_is_rebuilt_without_publishing_a_partial_ledger() {
        let temp = tempfile::tempdir().unwrap();
        let chat = chat();
        let row = |id: &str| {
            json!({"kind":"agent","backend":"claude","at_ms":3,"event":{"kind":"session","id":id}})
                .to_string()
                + "\n"
        };
        fs::write(temp.path().join("events.ndjson"), row(FIRST) + &row(SECOND)).unwrap();
        // A process that dies during migration can leave an unpublished
        // temporary file, but it must never leave a partially committed ledger.
        fs::write(
            temp.path().join(".tmp-interrupted-migration"),
            b"{\"first\":true",
        )
        .unwrap();
        remember(temp.path(), &chat).unwrap();
        let loaded = inventory(temp.path(), &chat);
        assert_eq!(loaded.total, 2);
        assert_eq!(loaded.entries.len(), 2);
        assert!(!loaded.truncated);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(temp.path().join(ARCHIVE))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn bounded_view_retains_full_private_archive_and_fork_references() {
        let source = tempfile::tempdir().unwrap();
        let destination = tempfile::tempdir().unwrap();
        let mut chat = chat();
        for number in 1..=70 {
            observed(
                source.path(),
                &chat,
                "codex",
                &format!("{number:08x}-1111-4111-8111-111111111111"),
                number,
            )
            .unwrap();
        }
        inherit(source.path(), destination.path()).unwrap();
        chat.id = "fork".into();
        let copied = inventory(destination.path(), &chat);
        assert_eq!(copied.total, 70);
        assert_eq!(copied.entries.len(), VISIBLE_LIMIT);
        assert!(
            copied
                .entries
                .iter()
                .all(|entry| entry.status == "historical"
                    && entry.source_conversation_id.as_deref() == Some("chat-test"))
        );
        let mut count = 0;
        read_records(&destination.path().join(ARCHIVE), |_| count += 1).unwrap();
        assert_eq!(count, 70);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(destination.path().join(ARCHIVE))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn torn_final_append_preserves_prefix_and_next_write_repairs_only_tail() {
        let temp = tempfile::tempdir().unwrap();
        let chat = chat();
        observed(temp.path(), &chat, "claude", FIRST, 2).unwrap();
        let path = temp.path().join(ARCHIVE);
        let prefix = fs::read(&path).unwrap();
        OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(b"{\"first\":true,\"backend\":")
            .unwrap();
        assert_eq!(inventory(temp.path(), &chat).total, 1);
        observed(temp.path(), &chat, "codex", SECOND, 3).unwrap();
        assert!(fs::read(&path).unwrap().starts_with(&prefix));
        assert_eq!(inventory(temp.path(), &chat).total, 2);
        let verified = fs::read(&path).unwrap();
        OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(b"bad-interior\n{}")
            .unwrap();
        assert!(observed(temp.path(), &chat, "muse", FIRST, 4).is_err());
        assert!(fs::read(&path).unwrap().starts_with(&verified));
        assert!(fs::read(&path).unwrap().ends_with(b"bad-interior\n{}"));
    }

    #[test]
    #[cfg(unix)]
    fn ledger_and_legacy_transcript_never_follow_symlinks() {
        let temp = tempfile::tempdir().unwrap();
        let outside = tempfile::NamedTempFile::new().unwrap();
        fs::write(outside.path(), b"untouched").unwrap();
        std::os::unix::fs::symlink(outside.path(), temp.path().join(ARCHIVE)).unwrap();
        assert!(observed(temp.path(), &chat(), "claude", FIRST, 1).is_err());
        assert_eq!(fs::read(outside.path()).unwrap(), b"untouched");
        fs::remove_file(temp.path().join(ARCHIVE)).unwrap();
        let absent = temp.path().join("absent-target");
        std::os::unix::fs::symlink(&absent, temp.path().join(ARCHIVE)).unwrap();
        assert!(remember(temp.path(), &chat()).is_err());
        assert!(!absent.exists());
        assert_eq!(fs::read_dir(temp.path()).unwrap().count(), 1);
        fs::remove_file(temp.path().join(ARCHIVE)).unwrap();
        std::os::unix::fs::symlink(outside.path(), temp.path().join("events.ndjson")).unwrap();
        assert!(remember(temp.path(), &chat()).is_err());
    }
}
