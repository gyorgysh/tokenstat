// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Encrypted on-device copies of already-authorized work.
//!
//! A conversation opened on this device can be opened again while its machine
//! is asleep or unreachable, but only from a copy saved here earlier. This is
//! that copy: conversation pages, explicitly viewed diffs and small attachment
//! previews, each sealed with a per-scope key the caller holds. The key arrives
//! with every call that needs it and is never written beside the ciphertext,
//! so a leaked cache directory exposes sizes and timestamps, not words.
//!
//! What this deliberately cannot hold is defined by the methods that exist:
//! there is no call that stores terminal scrollback, secrets, environment
//! dumps, repositories or unopened file contents, so none of those can reach
//! the file no matter what a front end asks for. Unsent drafts are durable
//! user data with their own store and are never evicted with these entries.
//!
//! Quotas come with every mutating call and default to 100 MB kept for 30
//! days, with pins surviving age eviction inside a 500 MB hard budget. A front
//! end that offers settings passes its own numbers; the defaults are what a
//! device without settings gets. All sensitive operations refuse remote
//! dispatch: the daemon never answers these for another machine.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use getrandom::fill as os_fill;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::base64::{decode as b64decode, encode as b64encode};

/// Defaults for a device without its own settings. Recent opened work fits;
/// a full copy of everything does not, which is the point: this is a shelf
/// of what was already looked at, not an archive of the account.
pub const DEFAULT_BUDGET_BYTES: u64 = 100 * 1024 * 1024;
/// Pins survive age eviction, but not without bound. Past this the pin is
/// refused rather than silently dropping somebody else's kept work.
pub const HARD_BUDGET_BYTES: u64 = 500 * 1024 * 1024;
/// Unpinned entries older than this are evicted on the next mutating call.
pub const DEFAULT_RETENTION_MS: i64 = 30 * 24 * 60 * 60 * 1000;
/// One record's plaintext, sealed as one message. A conversation page with
/// rendered text fits; a repository never does, which is also enforcement.
const MAX_RECORD_BYTES: usize = 8 * 1024 * 1024;
const MAX_ID_LEN: usize = 256;
const MAX_SCOPE_LEN: usize = 160;

const KIND_CONVERSATION: &str = "conversation";
const KIND_DIFF: &str = "diff";
const KIND_ATTACHMENT: &str = "attachment";
const KIND_SEARCH_HISTORY: &str = "searchHistory";

fn valid_token(value: &str, max: usize) -> bool {
    !value.is_empty()
        && value.len() <= max
        && value.bytes().all(|b| {
            // Scopes and ids are JSON keys and associated data, never paths
            // or commands, so percent-encoded storage keys are harmless here.
            b.is_ascii_alphanumeric()
                || matches!(b, b'-' | b'_' | b'.' | b'|' | b':' | b'/' | b'@' | b'%')
        })
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    id: String,
    kind: String,
    item_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    revision: Option<String>,
    /// Ciphertext bytes. Quota counts what is stored, not what it decrypts to.
    bytes: u64,
    created_ms: i64,
    updated_ms: i64,
    pinned: bool,
    nonce: String,
    ciphertext: String,
}

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Store {
    #[serde(default)]
    schema_version: u32,
    #[serde(default)]
    scopes: HashMap<String, HashMap<String, Record>>,
}

fn lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

fn path() -> PathBuf {
    std::env::var_os("TOKENSTAT_WORK_CACHE_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            if cfg!(test) {
                return std::env::temp_dir().join(format!(
                    "tokenstat-work-cache-test-{}.json",
                    std::process::id()
                ));
            }
            tokenstat_paths::data_dir()
                .unwrap_or_else(|| PathBuf::from("."))
                .join("work-cache.v1.json")
        })
}

/// Read the store, quarantining a damaged file rather than failing forever.
///
/// A cache is reconstructible by re-opening the work, so a corrupt file is
/// moved aside and answered as empty. The move is the whole recovery: the
/// next call starts clean, and the quarantined copy keeps whatever was there
/// for inspection instead of being deleted. A one-shot marker records that a
/// quarantine happened, so the call that finds the empty store can say the
/// previous contents were lost rather than silently starting over.
fn load() -> Result<(Store, bool), String> {
    let path = path();
    let marker = path.with_extension("repaired");
    let take_marker = || fs::remove_file(&marker).is_ok();
    let body = match fs::read(&path) {
        Ok(body) => body,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok((Store::default(), take_marker()));
        }
        Err(e) => return Err(e.to_string()),
    };
    match serde_json::from_slice::<Store>(&body) {
        Ok(store)
            if store.schema_version == 1
                || (store.schema_version == 0 && store.scopes.is_empty()) =>
        {
            Ok((store, take_marker()))
        }
        Ok(_) => Err("unsupported work cache version".into()),
        Err(_) => {
            let quarantine = path.with_extension("corrupt.json");
            let _ = fs::rename(&path, &quarantine);
            let _ = fs::write(&marker, b"quarantined");
            Ok((Store::default(), true))
        }
    }
}

// Caller holds the transaction lock from before load through replacement.
fn save(store: &mut Store) -> Result<(), String> {
    store.schema_version = 1;
    let path = path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let temp = path.with_extension("tmp");
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    use std::io::Write;
    let mut file = options.open(&temp).map_err(|e| e.to_string())?;
    file.write_all(&serde_json::to_vec(store).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    drop(file);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temp, fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
    }
    fs::rename(temp, &path).map_err(|e| e.to_string())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis().try_into().unwrap_or(i64::MAX))
        .unwrap_or(0)
}

fn parse_key(encoded: &str) -> Result<[u8; 32], String> {
    let raw = b64decode(encoded).map_err(|_| "invalid cache key".to_string())?;
    if raw.len() != 32 {
        return Err("invalid cache key".into());
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&raw);
    Ok(key)
}

/// The slot a record is sealed into, as associated data. Ciphertext copied
/// into another scope or id does not open there.
fn context(scope: &str, id: &str) -> Vec<u8> {
    let mut context = Vec::with_capacity(scope.len() + id.len() + 1);
    context.extend_from_slice(scope.as_bytes());
    context.push(0x1f);
    context.extend_from_slice(id.as_bytes());
    context
}

fn seal(
    key: &[u8; 32],
    scope: &str,
    id: &str,
    plaintext: &[u8],
) -> Result<(String, String), String> {
    let mut nonce = [0u8; 24];
    os_fill(&mut nonce).map_err(|e| e.to_string())?;
    let sealed = XChaCha20Poly1305::new(key.into())
        .encrypt(
            &XNonce::from(nonce),
            chacha20poly1305::aead::Payload {
                msg: plaintext,
                aad: &context(scope, id),
            },
        )
        .map_err(|e| e.to_string())?;
    Ok((b64encode(&nonce), b64encode(&sealed)))
}

fn open(
    key: &[u8; 32],
    scope: &str,
    id: &str,
    nonce: &str,
    ciphertext: &str,
) -> Result<Vec<u8>, String> {
    let nonce_raw = b64decode(nonce).map_err(|_| "unreadable cache record".to_string())?;
    let cipher_raw = b64decode(ciphertext).map_err(|_| "unreadable cache record".to_string())?;
    if nonce_raw.len() != 24 {
        return Err("unreadable cache record".into());
    }
    let mut array = [0u8; 24];
    array.copy_from_slice(&nonce_raw);
    XChaCha20Poly1305::new(key.into())
        .decrypt(
            &XNonce::from(array),
            chacha20poly1305::aead::Payload {
                msg: &cipher_raw,
                aad: &context(scope, id),
            },
        )
        .map_err(|_| "wrong cache key or damaged record".to_string())
}

fn evict_expired(
    store: &mut Store,
    now: i64,
    retention_ms: i64,
    selected_scope: Option<&str>,
) -> Vec<String> {
    let mut evicted = Vec::new();
    for (scope, records) in store.scopes.iter_mut() {
        if selected_scope.is_some_and(|selected| selected != scope) {
            continue;
        }
        let stale: Vec<String> = records
            .iter()
            .filter(|(_, record)| {
                !record.pinned && now.saturating_sub(record.updated_ms) >= retention_ms
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in stale {
            records.remove(&id);
            evicted.push(format!("{scope}|{id}"));
        }
    }
    store.scopes.retain(|_, records| !records.is_empty());
    evicted.sort();
    evicted
}

fn total_bytes(store: &Store) -> u64 {
    store
        .scopes
        .values()
        .flat_map(|records| records.values())
        .map(|record| record.bytes)
        .sum()
}

fn pinned_bytes(store: &Store) -> u64 {
    store
        .scopes
        .values()
        .flat_map(|records| records.values())
        .filter(|record| record.pinned)
        .map(|record| record.bytes)
        .sum()
}

/// Make room for `need` bytes, oldest unpinned first, never touching pins or
/// the record being written. Returns the ids removed, or None when even an
/// empty store (besides pins and the new record) would exceed the budget.
fn make_room(
    store: &mut Store,
    need: u64,
    keep_scope: &str,
    keep_id: &str,
    budget: u64,
) -> Option<Vec<String>> {
    if need > budget {
        return None;
    }
    let mut evicted = Vec::new();
    loop {
        let total = total_bytes(store);
        if total.saturating_add(need) <= budget {
            evicted.sort();
            return Some(evicted);
        }
        let oldest = store
            .scopes
            .iter()
            .flat_map(|(scope, records)| {
                records
                    .iter()
                    .map(|(id, record)| (record.updated_ms, scope.clone(), id.clone()))
            })
            .filter(|(_, scope, id)| !(scope == keep_scope && id == keep_id))
            .filter(|(_, scope, id)| {
                store
                    .scopes
                    .get(scope)
                    .and_then(|records| records.get(id))
                    .is_some_and(|record| !record.pinned)
            })
            .min();
        let (_, scope, id) = oldest?;
        if let Some(records) = store.scopes.get_mut(&scope) {
            records.remove(&id);
            if records.is_empty() {
                store.scopes.remove(&scope);
            }
        }
        evicted.push(format!("{scope}|{id}"));
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PutParams {
    key: String,
    scope: String,
    id: String,
    kind: String,
    item_id: String,
    #[serde(default)]
    revision: Option<String>,
    payload: Value,
    #[serde(default)]
    now_ms: Option<i64>,
    #[serde(default)]
    budget_bytes: Option<u64>,
    #[serde(default)]
    hard_budget_bytes: Option<u64>,
    #[serde(default)]
    retention_ms: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyedParams {
    key: String,
    scope: String,
    id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScopeParams {
    scope: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PinParams {
    scope: String,
    id: String,
    pinned: bool,
    #[serde(default)]
    hard_budget_bytes: Option<u64>,
}

fn meta(scope: &str, record: &Record) -> Value {
    json!({
        "scope": scope,
        "id": record.id,
        "kind": record.kind,
        "itemId": record.item_id,
        "revision": record.revision,
        "bytes": record.bytes,
        "createdMs": record.created_ms,
        "updatedMs": record.updated_ms,
        "pinned": record.pinned,
    })
}

fn put(params: &PutParams) -> Result<Value, String> {
    let _transaction = crate::identity_storage::lock_at(&path().with_extension("lock"), lock())?;
    if !valid_token(&params.scope, MAX_SCOPE_LEN) {
        return Err("invalid cache scope".into());
    }
    if !valid_token(&params.id, MAX_ID_LEN) {
        return Err("invalid cache id".into());
    }
    if !matches!(
        params.kind.as_str(),
        KIND_CONVERSATION | KIND_DIFF | KIND_ATTACHMENT | KIND_SEARCH_HISTORY
    ) {
        return Err("unknown cache kind".into());
    }
    if !valid_token(&params.item_id, MAX_ID_LEN) {
        return Err("invalid cache item".into());
    }
    if !params.payload.is_object() {
        return Err("cache payload must be an object".into());
    }
    if let Some(revision) = &params.revision {
        if revision.len() > MAX_ID_LEN || revision.bytes().any(|b| b == 0) {
            return Err("invalid cache revision".into());
        }
    }
    let key = parse_key(&params.key)?;
    let plaintext = serde_json::to_vec(&params.payload).map_err(|e| e.to_string())?;
    if plaintext.len() > MAX_RECORD_BYTES {
        return Err("cache record too large".into());
    }
    let now = params.now_ms.unwrap_or_else(now_ms);
    let retention = params.retention_ms.unwrap_or(DEFAULT_RETENTION_MS);
    let budget = params.budget_bytes.unwrap_or(DEFAULT_BUDGET_BYTES);

    let (mut store, repaired) = load()?;
    let expired = evict_expired(&mut store, now, retention, None);

    let (nonce, ciphertext) = seal(&key, &params.scope, &params.id, &plaintext)?;
    let bytes = (b64decode(&ciphertext).map_err(|e| e.to_string())?.len()
        + b64decode(&nonce).map_err(|e| e.to_string())?.len()) as u64;

    // The record being replaced does not count against the room it needs:
    // measure without it, then put it back.
    let previous = store
        .scopes
        .get(&params.scope)
        .and_then(|records| records.get(&params.id))
        .cloned();
    if let Some(records) = store.scopes.get_mut(&params.scope) {
        records.remove(&params.id);
    }
    // New clients distinguish disposable recent work from explicitly kept
    // copies. Older callers retain their original total-budget semantics.
    let budget = if let Some(hard) = params.hard_budget_bytes {
        pinned_bytes(&store)
            .saturating_add(if previous.as_ref().is_some_and(|record| record.pinned) {
                bytes
            } else {
                0
            })
            .saturating_add(budget)
            .min(hard)
    } else {
        budget
    };
    let mut freed = expired;
    match make_room(&mut store, bytes, &params.scope, &params.id, budget) {
        Some(evicted) => freed.extend(evicted),
        None => {
            // Restore what was there rather than failing into deletion.
            if let Some(prev) = previous {
                store
                    .scopes
                    .entry(params.scope.clone())
                    .or_default()
                    .insert(params.id.clone(), prev);
            }
            return Err("cache quota exceeded".into());
        }
    }

    let created = previous
        .as_ref()
        .map(|record| record.created_ms)
        .unwrap_or(now);
    let was_pinned = previous
        .as_ref()
        .map(|record| record.pinned)
        .unwrap_or(false);
    store
        .scopes
        .entry(params.scope.clone())
        .or_default()
        .insert(
            params.id.clone(),
            Record {
                id: params.id.clone(),
                kind: params.kind.clone(),
                item_id: params.item_id.clone(),
                revision: params.revision.clone(),
                bytes,
                created_ms: created,
                updated_ms: now,
                pinned: was_pinned,
                nonce,
                ciphertext,
            },
        );
    save(&mut store)?;
    freed.sort();
    Ok(json!({
        "id": params.id,
        "bytes": bytes,
        "evicted": freed,
        "repaired": repaired,
    }))
}

fn get(params: &KeyedParams) -> Result<Value, String> {
    let _transaction = crate::identity_storage::lock_at(&path().with_extension("lock"), lock())?;
    if !valid_token(&params.scope, MAX_SCOPE_LEN) || !valid_token(&params.id, MAX_ID_LEN) {
        return Err("invalid cache scope".into());
    }
    let key = parse_key(&params.key)?;
    let (store, _) = load()?;
    let Some(record) = store
        .scopes
        .get(&params.scope)
        .and_then(|records| records.get(&params.id))
    else {
        return Err("cache miss".into());
    };
    let plaintext = open(
        &key,
        &params.scope,
        &params.id,
        &record.nonce,
        &record.ciphertext,
    )?;
    let payload: Value =
        serde_json::from_slice(&plaintext).map_err(|_| "unreadable cache record".to_string())?;
    let mut answer = meta(&params.scope, record);
    answer["payload"] = payload;
    Ok(answer)
}

fn list(scope: &str) -> Result<Value, String> {
    let _transaction = crate::identity_storage::lock_at(&path().with_extension("lock"), lock())?;
    if !valid_token(scope, MAX_SCOPE_LEN) {
        return Err("invalid cache scope".into());
    }
    let (store, repaired) = load()?;
    let mut records: Vec<Value> = store
        .scopes
        .get(scope)
        .map(|entries| entries.values().map(|record| meta(scope, record)).collect())
        .unwrap_or_default();
    records.sort_by(|a, b| {
        a["updatedMs"]
            .as_i64()
            .unwrap_or(0)
            .cmp(&b["updatedMs"].as_i64().unwrap_or(0))
            .then(
                a["id"]
                    .as_str()
                    .unwrap_or("")
                    .cmp(b["id"].as_str().unwrap_or("")),
            )
    });
    Ok(json!({"records": records, "repaired": repaired}))
}

fn remove(params: &ScopeParams, id: &str) -> Result<Value, String> {
    let _transaction = crate::identity_storage::lock_at(&path().with_extension("lock"), lock())?;
    if !valid_token(&params.scope, MAX_SCOPE_LEN) || !valid_token(id, MAX_ID_LEN) {
        return Err("invalid cache scope".into());
    }
    let (mut store, repaired) = load()?;
    let removed = store
        .scopes
        .get_mut(&params.scope)
        .and_then(|records| records.remove(id))
        .is_some();
    if store
        .scopes
        .get(&params.scope)
        .is_some_and(|records| records.is_empty())
    {
        store.scopes.remove(&params.scope);
    }
    save(&mut store)?;
    Ok(json!({"removed": removed, "repaired": repaired}))
}

fn pin(params: &PinParams) -> Result<Value, String> {
    let _transaction = crate::identity_storage::lock_at(&path().with_extension("lock"), lock())?;
    if !valid_token(&params.scope, MAX_SCOPE_LEN) {
        return Err("invalid cache scope".into());
    }
    let (mut store, repaired) = load()?;
    let hard = params.hard_budget_bytes.unwrap_or(HARD_BUDGET_BYTES);
    {
        let record = store
            .scopes
            .get(&params.scope)
            .and_then(|records| records.get(&params.id))
            .ok_or_else(|| "cache miss".to_string())?;
        if params.pinned
            && !record.pinned
            && pinned_bytes(&store).saturating_add(record.bytes) > hard
        {
            return Err("pinned cache quota exceeded".into());
        }
    }
    let pinned = params.pinned;
    let record = store
        .scopes
        .get_mut(&params.scope)
        .and_then(|records| records.get_mut(&params.id))
        .ok_or_else(|| "cache miss".to_string())?;
    record.pinned = pinned;
    save(&mut store)?;
    Ok(json!({"pinned": pinned, "repaired": repaired}))
}

fn stats(scope: Option<&str>) -> Result<Value, String> {
    let _transaction = crate::identity_storage::lock_at(&path().with_extension("lock"), lock())?;
    if let Some(scope) = scope {
        if !valid_token(scope, MAX_SCOPE_LEN) {
            return Err("invalid cache scope".into());
        }
    }
    let (store, repaired) = load()?;
    let selected: Vec<(&String, &HashMap<String, Record>)> = store
        .scopes
        .iter()
        .filter(|(name, _)| scope.is_none_or(|want| want == *name))
        .collect();
    let bytes: u64 = selected
        .iter()
        .flat_map(|(_, records)| records.values())
        .map(|record| record.bytes)
        .sum();
    let pinned: u64 = selected
        .iter()
        .flat_map(|(_, records)| records.values())
        .filter(|record| record.pinned)
        .map(|record| record.bytes)
        .sum();
    let records: u64 = selected
        .iter()
        .map(|(_, entries)| entries.len() as u64)
        .sum();
    let pinned_count: u64 = selected
        .iter()
        .flat_map(|(_, entries)| entries.values())
        .filter(|record| record.pinned)
        .count() as u64;
    Ok(json!({
        "bytes": bytes,
        "records": records,
        "pinned": pinned_count,
        "pinnedBytes": pinned,
        "repaired": repaired,
    }))
}

fn clear_scope(scope: &str) -> Result<Value, String> {
    let _transaction = crate::identity_storage::lock_at(&path().with_extension("lock"), lock())?;
    if !valid_token(scope, MAX_SCOPE_LEN) {
        return Err("invalid cache scope".into());
    }
    let (mut store, repaired) = load()?;
    let removed = store
        .scopes
        .remove(scope)
        .map(|records| records.len() as u64)
        .unwrap_or(0);
    save(&mut store)?;
    Ok(json!({"removed": removed, "repaired": repaired}))
}

fn evict(scope: Option<&str>, now: i64, retention_ms: i64) -> Result<Value, String> {
    let _transaction = crate::identity_storage::lock_at(&path().with_extension("lock"), lock())?;
    if let Some(scope) = scope {
        if !valid_token(scope, MAX_SCOPE_LEN) {
            return Err("invalid cache scope".into());
        }
    }
    let (mut store, repaired) = load()?;
    let evicted = evict_expired(&mut store, now, retention_ms, scope);
    save(&mut store)?;
    Ok(json!({"evicted": evicted, "repaired": repaired}))
}

/// Sensitive cache operations are local-client-only. A daemon answers these
/// for the device it runs on; a machine asking over the tunnel gets a refusal
/// rather than somebody else's saved work.
pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("cache.") {
        return None;
    }
    if let Err(e) = crate::request_context::refuse_remote("saved work cache") {
        return Some(Err(e));
    }
    let answer = match method {
        "cache.put" => serde_json::from_str::<PutParams>(params)
            .map_err(|e| e.to_string())
            .and_then(|p| put(&p)),
        "cache.get" => serde_json::from_str::<KeyedParams>(params)
            .map_err(|e| e.to_string())
            .and_then(|p| get(&p)),
        "cache.list" => serde_json::from_str::<ScopeParams>(params)
            .map_err(|e| e.to_string())
            .and_then(|p| list(&p.scope)),
        "cache.remove" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct RemoveParams {
                scope: String,
                id: String,
            }
            serde_json::from_str::<RemoveParams>(params)
                .map_err(|e| e.to_string())
                .and_then(|p| remove(&ScopeParams { scope: p.scope }, &p.id))
        }
        "cache.pin" => serde_json::from_str::<PinParams>(params)
            .map_err(|e| e.to_string())
            .and_then(|p| pin(&p)),
        "cache.stats" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct StatsParams {
                #[serde(default)]
                scope: Option<String>,
            }
            serde_json::from_str::<StatsParams>(params)
                .map_err(|e| e.to_string())
                .and_then(|p| stats(p.scope.as_deref()))
        }
        "cache.clearScope" => serde_json::from_str::<ScopeParams>(params)
            .map_err(|e| e.to_string())
            .and_then(|p| clear_scope(&p.scope)),
        "cache.evict" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct EvictParams {
                #[serde(default)]
                scope: Option<String>,
                #[serde(default)]
                now_ms: Option<i64>,
                #[serde(default)]
                retention_ms: Option<i64>,
            }
            serde_json::from_str::<EvictParams>(params)
                .map_err(|e| e.to_string())
                .and_then(|p| {
                    evict(
                        p.scope.as_deref(),
                        p.now_ms.unwrap_or_else(now_ms),
                        p.retention_ms.unwrap_or(DEFAULT_RETENTION_MS),
                    )
                })
        }
        _ => return None,
    };
    Some(answer)
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

    fn params(scope: &str, id: &str) -> PutParams {
        PutParams {
            key: KEY.into(),
            scope: scope.into(),
            id: id.into(),
            kind: KIND_CONVERSATION.into(),
            item_id: "chat-1".into(),
            revision: Some("r1".into()),
            payload: json!({"messages": [{"id": "s1", "role": "user", "text": "hello"}]}),
            now_ms: Some(1_000),
            budget_bytes: None,
            hard_budget_bytes: None,
            retention_ms: None,
        }
    }

    fn fresh_path() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tokenstat-work-cache-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        dir.join(format!("{}.json", uuid_like()))
    }

    fn uuid_like() -> String {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT: AtomicU64 = AtomicU64::new(0);
        format!("t{}", NEXT.fetch_add(1, Ordering::Relaxed))
    }

    /// Each test gets its own file, because the module path is process-wide.
    /// The lock holds across the run because tests share the process and the
    /// path override is an environment variable, not a parameter.
    fn with_path(path: PathBuf, run: impl FnOnce()) {
        static GUARD: OnceLock<Mutex<()>> = OnceLock::new();
        let _held = GUARD.get_or_init(|| Mutex::new(())).lock();
        unsafe { std::env::set_var("TOKENSTAT_WORK_CACHE_PATH", &path) };
        run();
        unsafe { std::env::remove_var("TOKENSTAT_WORK_CACHE_PATH") };
        let _ = fs::remove_file(&path);
        let _ = fs::remove_file(path.with_extension("corrupt.json"));
        let _ = fs::remove_file(path.with_extension("repaired"));
    }

    #[test]
    #[ignore = "child process entry point"]
    fn concurrent_cache_writer() {
        let writer = std::env::var("TOKENSTAT_CACHE_TEST_WRITER").expect("test writer");
        for index in 0..20 {
            put(&params("kept", &format!("writer-{writer}-{index}"))).unwrap();
            if index == 10 {
                clear_scope("removed").unwrap();
            }
        }
    }

    #[test]
    fn concurrent_processes_preserve_writes_and_scope_removal() {
        with_path(fresh_path(), || {
            put(&params("removed", "old")).unwrap();
            let mut children: Vec<_> = (0..4)
                .map(|writer| {
                    std::process::Command::new(std::env::current_exe().unwrap())
                        .args([
                            "--ignored",
                            "--exact",
                            "work_cache::tests::concurrent_cache_writer",
                        ])
                        .env("TOKENSTAT_CACHE_TEST_WRITER", writer.to_string())
                        .stdout(std::process::Stdio::null())
                        .spawn()
                        .unwrap()
                })
                .collect();
            for child in &mut children {
                assert!(child.wait().unwrap().success());
            }
            assert_eq!(stats(Some("kept")).unwrap()["records"], 80);
            assert_eq!(stats(Some("removed")).unwrap()["records"], 0);
            for writer in 0..4 {
                for index in 0..20 {
                    assert!(
                        get(&KeyedParams {
                            key: KEY.into(),
                            scope: "kept".into(),
                            id: format!("writer-{writer}-{index}"),
                        })
                        .is_ok()
                    );
                }
            }
        });
    }

    #[test]
    fn round_trip_keeps_labels_encrypted() {
        with_path(fresh_path(), || {
            let answer = put(&params("acc|alice", "c1")).expect("put");
            assert_eq!(answer["evicted"].as_array().unwrap().len(), 0);
            let stored: Store = serde_json::from_slice(&fs::read(path()).unwrap()).unwrap();
            let raw = serde_json::to_string(&stored).unwrap();
            assert!(
                !raw.contains("hello"),
                "message text must not appear beside the ciphertext"
            );
            let entry = &stored.scopes["acc|alice"]["c1"];
            assert_eq!(entry.kind, KIND_CONVERSATION);

            let got = get(&KeyedParams {
                key: KEY.into(),
                scope: "acc|alice".into(),
                id: "c1".into(),
            })
            .expect("get");
            assert_eq!(got["payload"]["messages"][0]["text"], json!("hello"));
            assert_eq!(got["revision"], json!("r1"));

            // A different scope's key does not open it, and the record survives.
            let wrong = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";
            assert!(
                get(&KeyedParams {
                    key: wrong.into(),
                    scope: "acc|alice".into(),
                    id: "c1".into()
                })
                .is_err()
            );
            assert!(
                get(&KeyedParams {
                    key: KEY.into(),
                    scope: "acc|alice".into(),
                    id: "c1".into()
                })
                .is_ok()
            );

            // Ciphertext copied into another scope does not open there.
            let mut moved_store = stored;
            let moved_record = moved_store.scopes["acc|alice"]["c1"].clone();
            moved_store
                .scopes
                .entry("acc|bob".into())
                .or_default()
                .insert("c1".into(), moved_record);
            save(&mut moved_store).unwrap();
            assert!(
                get(&KeyedParams {
                    key: KEY.into(),
                    scope: "acc|bob".into(),
                    id: "c1".into()
                })
                .is_err()
            );
        });
    }

    #[test]
    fn scoped_eviction_preserves_other_accounts_and_global_eviction_reports_them() {
        with_path(fresh_path(), || {
            for scope in ["account", "account|other", "another"] {
                put(&params(scope, "old")).unwrap();
            }
            let result = call(
                "cache.evict",
                &json!({"scope": "account", "nowMs": 2000, "retentionMs": 500}).to_string(),
            )
            .unwrap()
            .unwrap();
            assert_eq!(result["evicted"], json!(["account|old"]));
            assert!(
                list("account").unwrap()["records"]
                    .as_array()
                    .unwrap()
                    .is_empty()
            );
            for scope in ["account|other", "another"] {
                assert_eq!(list(scope).unwrap()["records"].as_array().unwrap().len(), 1);
                assert!(
                    get(&KeyedParams {
                        key: KEY.into(),
                        scope: scope.into(),
                        id: "old".into(),
                    })
                    .is_ok()
                );
            }
            let global = evict(None, 2000, 500).unwrap();
            assert_eq!(
                global["evicted"],
                json!(["account|other|old", "another|old"])
            );
        });
    }

    #[test]
    fn recent_allowance_is_separate_from_kept_copies_with_a_hard_ceiling() {
        with_path(fresh_path(), || {
            put(&params("s", "kept")).unwrap();
            let used = stats(Some("s")).unwrap()["bytes"].as_u64().unwrap();
            pin(&PinParams {
                scope: "s".into(),
                id: "kept".into(),
                pinned: true,
                hard_budget_bytes: Some(used * 4),
            })
            .unwrap();
            let mut recent = params("s", "recent");
            recent.budget_bytes = Some(used + 10);
            recent.hard_budget_bytes = Some(used * 4);
            put(&recent).expect("a kept copy does not consume the recent allowance");
            assert_eq!(stats(Some("s")).unwrap()["records"], 2);
            // Lowering the ceiling refuses new work without deleting a pin.
            recent.id = "refused".into();
            recent.hard_budget_bytes = Some(used);
            assert!(put(&recent).is_err());
            assert_eq!(stats(Some("s")).unwrap()["records"], 2);
            assert!(
                get(&KeyedParams {
                    key: KEY.into(),
                    scope: "s".into(),
                    id: "kept".into()
                })
                .is_ok()
            );
        });
    }

    #[test]
    fn quota_evicts_oldest_unpinned_first() {
        with_path(fresh_path(), || {
            let mut first = params("s", "old");
            first.now_ms = Some(1_000);
            put(&first).unwrap();
            // Room for one record plus a little slack, not two: the older
            // one has to go. Measured rather than guessed, because sealed
            // sizes are an implementation detail.
            let used = stats(Some("s")).expect("stats")["bytes"].as_u64().unwrap();
            let mut second = params("s", "new");
            second.now_ms = Some(2_000);
            second.budget_bytes = Some(used + 10);
            let answer = put(&second).expect("put");
            assert_eq!(answer["evicted"], json!(["s|old"]));
            assert!(
                get(&KeyedParams {
                    key: KEY.into(),
                    scope: "s".into(),
                    id: "old".into()
                })
                .is_err()
            );

            // Pins are never evicted for room; the put fails instead and the
            // pinned record is still there.
            pin(&PinParams {
                scope: "s".into(),
                id: "new".into(),
                pinned: true,
                hard_budget_bytes: None,
            })
            .unwrap();
            let mut third = params("s", "third");
            third.now_ms = Some(3_000);
            third.budget_bytes = Some(used + 10);
            assert!(put(&third).is_err());
            assert!(
                get(&KeyedParams {
                    key: KEY.into(),
                    scope: "s".into(),
                    id: "new".into()
                })
                .is_ok()
            );

            // A pin past the hard budget is refused rather than silently
            // dropping other kept work.
            pin(&PinParams {
                scope: "s".into(),
                id: "new".into(),
                pinned: false,
                hard_budget_bytes: None,
            })
            .unwrap();
            assert!(
                pin(&PinParams {
                    scope: "s".into(),
                    id: "new".into(),
                    pinned: true,
                    hard_budget_bytes: Some(1),
                })
                .is_err()
            );
            assert!(
                get(&KeyedParams {
                    key: KEY.into(),
                    scope: "s".into(),
                    id: "new".into()
                })
                .is_ok()
            );
        });
    }

    #[test]
    fn age_eviction_spares_pins_and_reports() {
        with_path(fresh_path(), || {
            let old = params("s", "old");
            put(&old).unwrap();
            pin(&PinParams {
                scope: "s".into(),
                id: "old".into(),
                pinned: true,
                hard_budget_bytes: None,
            })
            .unwrap();
            let mut fresh = params("s", "fresh");
            fresh.now_ms = Some(2_000);
            put(&fresh).unwrap();

            let far_future = DEFAULT_RETENTION_MS + 10_000;
            let answer = evict(Some("s"), far_future, DEFAULT_RETENTION_MS).expect("evict");
            assert_eq!(answer["evicted"], json!(["s|fresh"]));
            assert!(
                get(&KeyedParams {
                    key: KEY.into(),
                    scope: "s".into(),
                    id: "old".into()
                })
                .is_ok()
            );
        });
    }

    #[test]
    fn corruption_is_quarantined_not_deleted() {
        with_path(fresh_path(), || {
            put(&params("s", "c1")).unwrap();
            fs::write(path(), b"not json").unwrap();
            // The failing read reports corruption; the file is already moved
            // aside, so the next call starts clean and says so.
            assert!(
                get(&KeyedParams {
                    key: KEY.into(),
                    scope: "s".into(),
                    id: "c1".into()
                })
                .is_err()
            );
            assert!(path().with_extension("corrupt.json").exists());
            let listed = list("s").expect("list");
            assert_eq!(listed["repaired"], json!(true));
            assert_eq!(listed["records"].as_array().unwrap().len(), 0);
        });
    }

    #[test]
    fn sign_out_purge_removes_one_scope_only() {
        with_path(fresh_path(), || {
            put(&params("acc|alice", "c1")).unwrap();
            put(&params("acc|bob", "c1")).unwrap();
            let cleared = clear_scope("acc|alice").expect("clear");
            assert_eq!(cleared["removed"], json!(1));
            assert!(
                get(&KeyedParams {
                    key: KEY.into(),
                    scope: "acc|alice".into(),
                    id: "c1".into()
                })
                .is_err()
            );
            assert!(
                get(&KeyedParams {
                    key: KEY.into(),
                    scope: "acc|bob".into(),
                    id: "c1".into()
                })
                .is_ok()
            );
            let totals = stats(None).expect("stats");
            assert_eq!(totals["records"], json!(1));
        });
    }

    #[test]
    fn dispatch_answers_cache_methods_locally() {
        with_path(fresh_path(), || {
            let sessionless = |method: &str, params: Value| {
                crate::dispatch::call_sessionless(method, &params.to_string())
                    .expect("cache method answered")
            };
            let put = sessionless(
                "cache.put",
                json!({
                    "key": KEY, "scope": "s", "id": "c1", "kind": KIND_CONVERSATION,
                    "itemId": "chat-1", "payload": {"messages": []},
                }),
            );
            assert!(put.contains("\"ok\":true"), "put envelope: {put}");
            let got = sessionless("cache.get", json!({"key": KEY, "scope": "s", "id": "c1"}));
            assert!(got.contains("\"ok\":true"), "get envelope: {got}");
            let stats = sessionless("cache.stats", json!({"scope": "s"}));
            assert!(stats.contains("\"records\":1"), "stats envelope: {stats}");
            assert!(crate::dispatch::call_sessionless("cache.unknown", "{}").is_none());

            // A machine asking over the tunnel is refused, not answered.
            let refused = crate::request_context::with_remote_peer("phone", || {
                crate::dispatch::call_sessionless("cache.stats", "{}")
                    .expect("answered with refusal")
            });
            assert!(refused.contains("local-only"), "remote refusal: {refused}");
        });
    }

    #[test]
    fn rejects_what_it_cannot_hold() {
        with_path(fresh_path(), || {
            let mut bad_kind = params("s", "c1");
            bad_kind.kind = "terminal-scrollback".into();
            assert!(put(&bad_kind).is_err());
            // Scopes and ids are JSON keys, never paths, so dots, slashes
            // and percent-encoded storage keys are harmless. Control
            // characters, blanks and emptiness are not.
            assert!(put(&params("acc%7Calice", "c1")).is_ok());
            let mut bad_scope = params("s", "c1");
            bad_scope.scope = "has space".into();
            assert!(put(&bad_scope).is_err());
            let mut bad_id = params("s", "c1");
            bad_id.id = "".into();
            assert!(put(&bad_id).is_err());
            let mut huge = params("s", "c1");
            huge.payload = json!({"blob": "x".repeat(MAX_RECORD_BYTES + 1)});
            assert!(put(&huge).is_err());
            assert!(list("has space").is_err());
        });
    }
}
