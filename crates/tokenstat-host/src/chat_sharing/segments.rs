// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Canonical agent batches live in content-addressed payloads. `chain.ndjson`
//! stores one hash-linked reference per batch. The journal seals that chain.
//! A reader opens only the payloads a page needs.

use super::super::{invalid, paused, read_private};
use super::{Journal, Scope, agent::AgentRecord, digest, lower_hex};
use crate::work_transcript_identity::{UsageTotals, sequence};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::{Path, PathBuf};

const KIND: &str = "teamAgentSegment";
const DIRECTORY: &str = "team-output";
const CHAIN: &str = "chain.ndjson";
const ZERO: &str = "0000000000000000000000000000000000000000000000000000000000000000";
const PAYLOAD_LIMIT: u64 = 512 * 1024;
const CHAIN_LIMIT: u64 = 32 * 1024 * 1024;
const ARCHIVE_LIMIT: u64 = 2 * 1024 * 1024 * 1024;
const EXPAND_LIMIT: u64 = 32 * 1024 * 1024;
const MAX_ROWS: u32 = 128;

#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Head {
    hash: String,
    chunks: u64,
    rows: u64,
    bytes: u64,
}
impl Head {
    fn valid(&self) -> bool {
        lower_hex(&self.hash, 64)
            && self.chunks > 0
            && self.rows >= self.chunks
            && self.bytes > 0
            && self.bytes <= ARCHIVE_LIMIT
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Pending {
    before_bytes: u64,
    before_digest: String,
    after_bytes: u64,
    after_digest: String,
    head: Head,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Reference {
    kind: String,
    version: u8,
    first: u64,
    count: u32,
    bytes: u64,
    digest: String,
    previous: String,
    scope: Scope,
    run_id: String,
    batch: u32,
    request_digest: String,
    backend: String,
    usage: UsageTotals,
}

pub(crate) struct Prepared {
    pub canonical: Vec<u8>,
    pub pending: Pending,
}

struct Parsed {
    seq: u64,
    reference: Reference,
    line: Vec<u8>,
}

fn hex_name(name: &str) -> bool {
    lower_hex(name, 64)
}

pub(crate) fn read_chain(directory: &Path) -> Result<Vec<u8>, super::super::DispatchError> {
    let root = directory.join(DIRECTORY);
    match std::fs::symlink_metadata(&root) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(_) => return Err(paused()),
        Ok(metadata) if !metadata.is_dir() || super::super::reparse_or_link(&metadata) => {
            return Err(paused());
        }
        Ok(_) => {}
    }
    let path = root.join(CHAIN);
    match std::fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(_) => Err(paused()),
        Ok(_) => read_private(&path, CHAIN_LIMIT, false),
    }
}

pub(crate) fn next_shared(events: &[u8], chain: &[u8]) -> Result<u64, &'static str> {
    let events = crate::work_transcript_identity::next_sequence(events, 0)?;
    let chain = if chain.is_empty() {
        0
    } else {
        crate::work_transcript_identity::next_sequence(chain, 0)?
    };
    Ok(events.max(chain))
}

fn line_of(reference: &Reference, seq: u64) -> Result<Vec<u8>, &'static str> {
    let Value::Object(raw) =
        serde_json::to_value(reference).map_err(|_| "Output reference is invalid")?
    else {
        return Err("Output reference is invalid");
    };
    crate::work_transcript_identity::encoded(raw, seq).map_err(|_| "Output reference is invalid")
}

fn parsed(bytes: &[u8]) -> Result<Vec<Parsed>, super::super::DispatchError> {
    if !bytes.is_empty() && bytes.last() != Some(&b'\n') {
        return Err(paused());
    }
    let mut rows = Vec::new();
    let mut previous = ZERO.to_string();
    let mut last = None;
    for line in bytes.split_inclusive(|byte| *byte == b'\n') {
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let body = line.strip_suffix(b"\n").unwrap_or(line);
        let mut raw: Value = serde_json::from_slice(body).map_err(|_| paused())?;
        let seq = sequence(raw.as_object().ok_or_else(paused)?, 0).map_err(|_| paused())?;
        if last.is_some_and(|seen| seq <= seen) {
            return Err(paused());
        }
        raw.as_object_mut().ok_or_else(paused)?.remove("seq");
        let reference: Reference = serde_json::from_value(raw).map_err(|_| paused())?;
        let encoded = line_of(&reference, seq).map_err(|_| paused())?;
        if reference.kind != KIND
            || reference.version != 1
            || reference.count == 0
            || reference.count > MAX_ROWS
            || reference.first.checked_add(u64::from(reference.count) - 1) != Some(seq)
            || seq > 9_007_199_254_740_991
            || reference.bytes == 0
            || reference.bytes > PAYLOAD_LIMIT
            || !lower_hex(&reference.digest, 64)
            || reference.previous != previous
            || !reference.scope.valid()
            || reference
                .run_id
                .strip_prefix("run_")
                .is_none_or(|id| !lower_hex(id, 32))
            || reference.backend.is_empty()
            || reference.backend.len() > 64
            || !lower_hex(&reference.request_digest, 64)
            || encoded != line
        {
            return Err(paused());
        }
        previous = digest(&encoded);
        last = Some(seq);
        rows.push(Parsed {
            seq,
            reference,
            line: encoded,
        });
    }
    Ok(rows)
}

fn head_of(rows: &[Parsed]) -> Result<Option<Head>, super::super::DispatchError> {
    let Some(last) = rows.last() else {
        return Ok(None);
    };
    let mut count = 0u64;
    let mut size = 0u64;
    for row in rows {
        count = count
            .checked_add(u64::from(row.reference.count))
            .ok_or_else(paused)?;
        size = size.checked_add(row.reference.bytes).ok_or_else(paused)?;
    }
    let head = Head {
        hash: digest(&last.line),
        chunks: rows.len() as u64,
        rows: count,
        bytes: size,
    };
    if !head.valid() || head.bytes > ARCHIVE_LIMIT {
        return Err(paused());
    }
    Ok(Some(head))
}

pub(crate) fn recorded(
    chain: &[u8],
    scope: &Scope,
    run: &str,
    batch: u32,
    request_digest: &str,
    total: u32,
) -> Result<bool, &'static str> {
    for row in parsed(chain).map_err(|_| "Output chain could not be verified")? {
        let reference = &row.reference;
        if reference.run_id != run || reference.batch != batch || &reference.scope != scope {
            continue;
        }
        if reference.request_digest != request_digest || reference.count != total {
            return Err("Output batch changed");
        }
        return Ok(true);
    }
    Ok(false)
}

fn payload_path(directory: &Path, digest: &str) -> Result<PathBuf, super::super::DispatchError> {
    if !hex_name(digest) {
        return Err(paused());
    }
    Ok(directory.join(DIRECTORY).join(digest))
}

fn write_payload(directory: &Path, bytes: &[u8]) -> Result<String, super::super::DispatchError> {
    if bytes.is_empty() || bytes.len() as u64 > PAYLOAD_LIMIT {
        return Err(super::super::DispatchError::new(
            "team_history_limit",
            "This shared chat is full. Start another chat to continue.",
        ));
    }
    let root = directory.join(DIRECTORY);
    if !root.exists() {
        std::fs::create_dir(&root).map_err(|_| invalid())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
                .map_err(|_| invalid())?;
        }
    }
    let metadata = std::fs::symlink_metadata(&root).map_err(|_| invalid())?;
    if !metadata.is_dir() || super::super::reparse_or_link(&metadata) {
        return Err(invalid());
    }
    let hash = digest(bytes);
    let path = payload_path(directory, &hash)?;
    if path.exists() {
        if read_private(&path, PAYLOAD_LIMIT, false)? != bytes {
            return Err(paused());
        }
    } else {
        super::super::super::write_private_file(&path, bytes).map_err(|_| invalid())?;
    }
    Ok(hash)
}

pub(crate) fn prepare(
    directory: &Path,
    journal: &Journal,
    chain: &[u8],
    rows: &[AgentRecord],
    request_digest: &str,
) -> Result<Prepared, super::super::DispatchError> {
    let payload = super::agent::batch_bytes(rows).map_err(|_| invalid())?;
    let first = rows.first().ok_or_else(invalid)?;
    let last = rows.last().ok_or_else(invalid)?;
    let references = parsed(chain)?;
    let current = head_of(&references)?;
    if current.as_ref() != journal.segment_head() {
        return Err(paused());
    }
    let usage = row_usage(rows).map_err(|_| invalid())?;
    let digest = write_payload(directory, &payload)?;
    let reference = Reference {
        kind: KIND.into(),
        version: 1,
        first: first.sequence(),
        count: rows.len() as u32,
        bytes: payload.len() as u64,
        digest,
        previous: current
            .as_ref()
            .map(|head| head.hash.clone())
            .unwrap_or_else(|| ZERO.into()),
        scope: first.scope().clone(),
        run_id: first.run_id().into(),
        batch: first.batch(),
        request_digest: request_digest.into(),
        backend: first.backend().into(),
        usage,
    };
    let line = line_of(&reference, last.sequence()).map_err(|_| invalid())?;
    let mut canonical = chain.to_vec();
    canonical.extend(&line);
    if canonical.len() as u64 > CHAIN_LIMIT {
        return Err(super::super::DispatchError::new(
            "team_history_limit",
            "This shared chat is full. Start another chat to continue.",
        ));
    }
    let mut extended = references;
    extended.push(Parsed {
        seq: last.sequence(),
        reference,
        line,
    });
    let head = head_of(&extended)?.ok_or_else(invalid)?;
    if head.bytes > ARCHIVE_LIMIT {
        return Err(super::super::DispatchError::new(
            "team_history_limit",
            "This shared chat is full. Start another chat to continue.",
        ));
    }
    Ok(Prepared {
        pending: Pending {
            before_bytes: chain.len() as u64,
            before_digest: digest_bytes(chain),
            after_bytes: canonical.len() as u64,
            after_digest: digest_bytes(&canonical),
            head,
        },
        canonical,
    })
}

fn digest_bytes(bytes: &[u8]) -> String {
    digest(bytes)
}

fn row_usage(rows: &[AgentRecord]) -> Result<UsageTotals, &'static str> {
    let mut usage = UsageTotals::default();
    for row in rows {
        let encoded = row.encoded()?;
        let line = encoded.strip_suffix(b"\n").unwrap_or(&encoded);
        let Value::Object(raw) =
            serde_json::from_slice(line).map_err(|_| "Output row is invalid")?
        else {
            return Err("Output row is invalid");
        };
        usage.add(&UsageTotals::from_record(&raw)?)?;
    }
    Ok(usage)
}

fn project_payload(
    directory: &Path,
    reference: &Reference,
    seq: u64,
) -> Result<Vec<Value>, super::super::DispatchError> {
    let bytes = read_private(
        &payload_path(directory, &reference.digest)?,
        PAYLOAD_LIMIT,
        false,
    )?;
    if bytes.len() as u64 != reference.bytes || digest(&bytes) != reference.digest {
        return Err(paused());
    }
    let mut rows = Vec::new();
    let mut usage = UsageTotals::default();
    for (index, line) in bytes.split_inclusive(|byte| *byte == b'\n').enumerate() {
        if line.is_empty() {
            continue;
        }
        let raw = line.strip_suffix(b"\n").unwrap_or(line);
        let row: AgentRecord = serde_json::from_slice(raw).map_err(|_| paused())?;
        if row.sequence() != reference.first + index as u64
            || row.batch() != reference.batch
            || u32::from(row.index()) != index as u32
            || row.scope() != &reference.scope
            || row.run_id() != reference.run_id
            || row.backend() != reference.backend
        {
            return Err(paused());
        }
        let encoded = row.encoded().map_err(|_| paused())?;
        if encoded != line {
            return Err(paused());
        }
        let Value::Object(value) = serde_json::from_slice(raw).map_err(|_| paused())? else {
            return Err(paused());
        };
        usage
            .add(&UsageTotals::from_record(&value).map_err(|_| paused())?)
            .map_err(|_| paused())?;
        rows.push(row.projected().map_err(|_| paused())?);
    }
    if rows.len() != reference.count as usize
        || rows.last().and_then(|row| row["seq"].as_u64()) != Some(seq)
        || usage.value() != reference.usage.value()
    {
        return Err(paused());
    }
    Ok(rows)
}

pub(crate) fn accept_chain(
    chain: &[u8],
    journal: &Journal,
) -> Result<(), super::super::DispatchError> {
    let rows = parsed(chain)?;
    if head_of(&rows)? != journal.segment_head().cloned() {
        return Err(paused());
    }
    Ok(())
}

pub(crate) fn project_chain(
    directory: &Path,
    chain: &[u8],
    journal: &Journal,
) -> Result<Vec<Value>, super::super::DispatchError> {
    let rows = parsed(chain)?;
    if head_of(&rows)? != journal.segment_head().cloned() {
        return Err(paused());
    }
    let Some(head) = journal.segment_head() else {
        return Ok(Vec::new());
    };
    if head.bytes > EXPAND_LIMIT {
        return Err(super::super::DispatchError::new(
            "team_history_limit",
            "Open this shared chat to read its later history.",
        ));
    }
    let mut events = Vec::new();
    for row in &rows {
        events.extend(project_payload(directory, &row.reference, row.seq)?);
    }
    Ok(events)
}

pub(crate) struct Page {
    pub events: Vec<Value>,
    pub has_more: bool,
}

pub(crate) struct PageRequest {
    pub after: Option<u64>,
    pub older: bool,
    pub limit: usize,
    pub budget: usize,
}

/// An accepted chain prefix. Later appends are never consulted while an
/// agent reads this snapshot; each requested payload still verifies its hash.
pub(crate) struct Snapshot {
    directory: PathBuf,
    refs: Vec<Parsed>,
    head: Option<Head>,
}
impl Snapshot {
    pub(in crate::chat::sharing) fn capture(
        directory: &Path,
        chain: &[u8],
        journal: Option<&Journal>,
        inline: &[Value],
    ) -> Result<Self, super::super::DispatchError> {
        let refs = parsed(chain)?;
        let head = head_of(&refs)?;
        if head.as_ref() != journal.and_then(Journal::segment_head) {
            return Err(paused());
        }
        let mut previous = None;
        let mut at = 0;
        for event in inline {
            let seq = event["seq"].as_u64().ok_or_else(paused)?;
            if previous.is_some_and(|last| seq <= last) {
                return Err(paused());
            }
            previous = Some(seq);
            while at < refs.len() && refs[at].seq < seq {
                at += 1;
            }
            if refs.get(at).is_some_and(|row| row.reference.first <= seq) {
                return Err(paused());
            }
        }
        Ok(Self {
            directory: directory.to_owned(),
            refs,
            head,
        })
    }
    pub(crate) fn head(&self) -> Option<&Head> {
        self.head.as_ref()
    }
    pub(crate) fn archived_bytes(&self) -> u64 {
        self.head.as_ref().map_or(0, |head| head.bytes)
    }
    pub(crate) fn archived_rows(&self) -> u64 {
        self.head.as_ref().map_or(0, |head| head.rows)
    }
    pub(crate) fn page(
        &self,
        inline: &[Value],
        request: &PageRequest,
    ) -> Result<Page, super::super::DispatchError> {
        select_refs(&self.directory, &self.refs, inline, request)
    }
}

pub(in crate::chat::sharing) fn select_page(
    directory: &Path,
    chain: &[u8],
    journal: Option<&Journal>,
    inline: &[Value],
    request: &PageRequest,
) -> Result<Page, super::super::DispatchError> {
    let refs = match journal {
        Some(journal) => {
            let refs = parsed(chain)?;
            if head_of(&refs)? != journal.segment_head().cloned() {
                return Err(paused());
            }
            refs
        }
        None if chain.is_empty() => Vec::new(),
        None => return Err(paused()),
    };
    select_refs(directory, &refs, inline, request)
}

fn select_refs(
    directory: &Path,
    refs: &[Parsed],
    inline: &[Value],
    request: &PageRequest,
) -> Result<Page, super::super::DispatchError> {
    let latest = inline
        .last()
        .and_then(|event| event["seq"].as_u64())
        .into_iter()
        .chain(refs.last().map(|row| row.seq))
        .max();
    if request
        .after
        .is_some_and(|position| latest.is_none_or(|last| position > last))
    {
        return Err(super::super::DispatchError::new(
            "chat_cursor_invalid",
            "Refresh this shared chat's history.",
        ));
    }
    let mut cache: Vec<Option<Vec<Value>>> = (0..refs.len()).map(|_| None).collect();
    let load_event = |cache: &mut Vec<Option<Vec<Value>>>,
                      index: usize,
                      row: usize|
     -> Result<Value, super::super::DispatchError> {
        if cache[index].is_none() {
            cache[index] = Some(project_payload(
                directory,
                &refs[index].reference,
                refs[index].seq,
            )?);
        }
        // A page may select many rows from one sealed payload. Clone only the
        // chosen event, rather than its entire (up to 512 KiB) segment per row.
        cache[index]
            .as_ref()
            .and_then(|events| events.get(row))
            .cloned()
            .ok_or_else(paused)
    };
    let matches = |seq: u64| {
        request.after.is_none_or(|position| {
            if request.older {
                seq < position
            } else {
                seq > position
            }
        })
    };
    let mut chosen = Vec::new();
    let mut size = 0usize;
    let mut more = false;
    if request.older {
        let mut inline_at = inline.len();
        let mut chain_at = refs.len();
        let mut row_at = refs.last().map(|row| row.reference.count).unwrap_or(0);
        loop {
            let inline_seq = inline_at
                .checked_sub(1)
                .and_then(|index| inline[index]["seq"].as_u64());
            let chain_seq =
                (row_at > 0).then(|| refs[chain_at - 1].reference.first + u64::from(row_at - 1));
            let Some(seq) = (match (inline_seq, chain_seq) {
                (Some(left), Some(right)) if left == right => return Err(paused()),
                (Some(left), Some(right)) => Some(left.max(right)),
                (Some(left), None) => Some(left),
                (None, Some(right)) => Some(right),
                (None, None) => None,
            }) else {
                break;
            };
            let from_chain = chain_seq == Some(seq);
            if !matches(seq) {
                if from_chain {
                    row_at -= 1;
                    if row_at == 0 {
                        chain_at -= 1;
                        row_at = chain_at
                            .checked_sub(1)
                            .map(|index| refs[index].reference.count)
                            .unwrap_or(0);
                    }
                } else {
                    inline_at -= 1;
                }
                continue;
            }
            let event = if from_chain {
                let index = chain_at - 1;
                load_event(&mut cache, index, (row_at - 1) as usize)?
            } else {
                inline[inline_at - 1].clone()
            };
            let bytes = serde_json::to_vec(&event).map_err(|_| paused())?.len();
            if chosen.len() == request.limit || !chosen.is_empty() && size + bytes > request.budget
            {
                more = true;
                break;
            }
            size += bytes;
            chosen.push(event);
            if from_chain {
                row_at -= 1;
                if row_at == 0 {
                    chain_at -= 1;
                    row_at = chain_at
                        .checked_sub(1)
                        .map(|index| refs[index].reference.count)
                        .unwrap_or(0);
                }
            } else {
                inline_at -= 1;
            }
        }
        chosen.reverse();
    } else {
        let mut inline_at = 0usize;
        let mut chain_at = 0usize;
        let mut row_at = 0u32;
        loop {
            let inline_seq = inline
                .get(inline_at)
                .and_then(|event| event["seq"].as_u64());
            let chain_seq = refs
                .get(chain_at)
                .filter(|row| row_at < row.reference.count)
                .map(|row| row.reference.first + u64::from(row_at));
            let Some(seq) = (match (inline_seq, chain_seq) {
                (Some(left), Some(right)) if left == right => return Err(paused()),
                (Some(left), Some(right)) => Some(left.min(right)),
                (Some(left), None) => Some(left),
                (None, Some(right)) => Some(right),
                (None, None) => None,
            }) else {
                break;
            };
            let from_chain = chain_seq == Some(seq);
            if matches(seq) {
                let event = if from_chain {
                    load_event(&mut cache, chain_at, row_at as usize)?
                } else {
                    inline[inline_at].clone()
                };
                let bytes = serde_json::to_vec(&event).map_err(|_| paused())?.len();
                if chosen.len() == request.limit
                    || !chosen.is_empty() && size + bytes > request.budget
                {
                    more = true;
                    break;
                }
                size += bytes;
                chosen.push(event);
            }
            if from_chain {
                row_at += 1;
                if refs
                    .get(chain_at)
                    .is_some_and(|row| row_at >= row.reference.count)
                {
                    chain_at += 1;
                    row_at = 0;
                }
            } else {
                inline_at += 1;
            }
        }
    }
    Ok(Page {
        events: chosen,
        has_more: more,
    })
}

pub(crate) fn copy_tree(source: &Path, destination: &Path) -> Result<(), String> {
    let root = source.join(DIRECTORY);
    let metadata = match std::fs::symlink_metadata(&root) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.to_string()),
    };
    if !metadata.is_dir() || super::super::reparse_or_link(&metadata) {
        return Err("invalid agent history".into());
    }
    let copied = destination.join(DIRECTORY);
    std::fs::create_dir(&copied).map_err(|error| error.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&copied, std::fs::Permissions::from_mode(0o700))
            .map_err(|error| error.to_string())?;
    }
    let mut total = 0u64;
    for entry in std::fs::read_dir(&root).map_err(|error| error.to_string())? {
        let entry = entry.map_err(|error| error.to_string())?;
        let name = entry.file_name();
        let name = name.to_str().ok_or("invalid agent history")?;
        if name != CHAIN && !hex_name(name) {
            return Err("invalid agent history".into());
        }
        let metadata =
            std::fs::symlink_metadata(entry.path()).map_err(|error| error.to_string())?;
        if !metadata.is_file() || super::super::reparse_or_link(&metadata) {
            return Err("invalid agent history".into());
        }
        let limit = if name == CHAIN {
            CHAIN_LIMIT
        } else {
            PAYLOAD_LIMIT
        };
        let bytes = read_private(&entry.path(), limit, false).map_err(|error| error.to_string())?;
        total = total
            .checked_add(bytes.len() as u64)
            .ok_or("invalid agent history")?;
        if total > ARCHIVE_LIMIT + CHAIN_LIMIT {
            return Err("invalid agent history".into());
        }
        super::super::super::write_private_file(&copied.join(name), &bytes)
            .map_err(|_| "invalid agent history")?;
    }
    Ok(())
}

pub(crate) fn chain_usage(directory: &Path) -> Result<UsageTotals, String> {
    let chain = read_chain(directory).map_err(|error| error.to_string())?;
    let mut usage = UsageTotals::default();
    for row in parsed(&chain).map_err(|error| error.to_string())? {
        usage
            .add(&row.reference.usage)
            .map_err(|error| error.to_string())?;
    }
    Ok(usage)
}

impl Journal {
    pub(super) fn retire_unwritten_segments(&mut self, bytes: &[u8]) -> Result<(), &'static str> {
        let Some(pending) = &self.pending_segments else {
            return Ok(());
        };
        if bytes.len() as u64 != pending.before_bytes || digest(bytes) != pending.before_digest {
            return Err("Output reference changed during recovery");
        }
        self.pending_segments = None;
        Ok(())
    }
    pub(crate) fn segment_head(&self) -> Option<&Head> {
        self.segment_head.as_ref()
    }
    pub(crate) fn reserve_segments(&mut self, pending: Pending) -> Result<(), &'static str> {
        if self.busy()
            || !pending.head.valid()
            || !lower_hex(&pending.before_digest, 64)
            || !lower_hex(&pending.after_digest, 64)
            || pending.before_bytes > CHAIN_LIMIT
            || pending.after_bytes > CHAIN_LIMIT
            || pending.after_bytes <= pending.before_bytes
        {
            return Err("Earlier output needs recovery");
        }
        self.pending_segments = Some(pending);
        self.encoded()?;
        Ok(())
    }
    pub(crate) fn observe_chain(&mut self, bytes: &[u8]) -> Result<bool, &'static str> {
        let Some(pending) = &self.pending_segments else {
            return Ok(false);
        };
        if bytes.len() as u64 == pending.before_bytes && digest(bytes) == pending.before_digest {
            return Ok(false);
        }
        if bytes.len() as u64 != pending.after_bytes || digest(bytes) != pending.after_digest {
            return Err("Output reference changed during delivery");
        }
        let head = pending.head.clone();
        self.segment_head = Some(head);
        self.pending_segments = None;
        Ok(true)
    }
    pub(crate) fn validate_chain(&self) -> Result<(), &'static str> {
        if self.segment_head.as_ref().is_some_and(|head| !head.valid()) {
            return Err("Invalid output chain");
        }
        if let Some(pending) = &self.pending_segments
            && (!pending.head.valid()
                || !lower_hex(&pending.before_digest, 64)
                || !lower_hex(&pending.after_digest, 64)
                || pending.before_bytes > CHAIN_LIMIT
                || pending.after_bytes > CHAIN_LIMIT
                || pending.after_bytes <= pending.before_bytes)
        {
            return Err("Invalid output intent");
        }
        Ok(())
    }
}
