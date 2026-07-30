//! Antigravity CLI conversation reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.gemini/antigravity-cli/conversations/<uuid>.db
//! ```
//!
//! Each `gen_metadata` row is one generation encoded as protobuf. There is no
//! vendor schema in this repo, so a small wire-format reader pulls only the
//! fields needed for counters. Field numbers were verified against real local
//! databases:
//!
//! - `gen_metadata.#1` → chatModel
//!   - `#19` string → model id
//!   - `#9.#4` `{#1 seconds, #2 nanos}` → per-turn wall clock
//!   - `#4` usage
//!     - `#1` + `#2` → billable fresh input (system + new tokens)
//!     - `#5` → cache read
//!     - `#9` → output text
//!     - `#10` → thinking (folded into `output`, also in extras)
//!     - `#11` → response id (dedup)
//! - `trajectory_metadata_blob.#2` → session created-at fallback
//! - `trajectory_metadata_blob.#1.#1` → workspace `file://` URI
//!
//! Brain transcripts under `~/.gemini/antigravity/brain/` are not read: they
//! have no token fields.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Locate the Antigravity CLI conversations directory.
pub fn discover(home: &Path) -> Option<PathBuf> {
    let root = home
        .join(".gemini")
        .join("antigravity-cli")
        .join("conversations");
    root.is_dir().then_some(root)
}

/// Every conversation database under the conversations root.
pub fn shards(conversations: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(conversations) else {
        return Vec::new();
    };
    let mut out: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("db"))
        .collect();
    out.sort();
    out
}

#[derive(Debug, Default)]
pub struct ParseOutput {
    pub events: Vec<UsageEvent>,
    pub warnings: Vec<Warning>,
    pub rows_seen: u64,
}

/// Read every generation that carries token counters from one conversation DB.
pub fn parse_db(path: &Path) -> ParseOutput {
    let mut out = ParseOutput::default();
    let conn = match rusqlite::Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(c) => c,
        Err(e) => {
            out.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return out;
        }
    };

    let session_id = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown")
        .to_string();

    let (session_ts_ms, project) = read_trajectory_meta(&conn, path);
    let project = project.unwrap_or_else(|| session_id.clone());

    let mut stmt = match conn.prepare("SELECT idx, data FROM gen_metadata ORDER BY idx") {
        Ok(s) => s,
        Err(e) => {
            out.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return out;
        }
    };

    let rows = match stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?))) {
        Ok(rows) => rows,
        Err(e) => {
            out.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return out;
        }
    };

    let mut seen_response_ids = HashSet::new();
    for row in rows {
        let Ok((idx, blob)) = row else {
            continue;
        };
        let Some(event) = parse_gen_metadata(
            &blob,
            &session_id,
            &project,
            session_ts_ms,
            idx,
            &mut seen_response_ids,
        ) else {
            continue;
        };
        out.rows_seen += 1;
        out.events.push(event);
    }

    out
}

fn parse_gen_metadata(
    blob: &[u8],
    session_id: &str,
    project: &str,
    session_timestamp: i64,
    idx: i64,
    seen_response_ids: &mut HashSet<String>,
) -> Option<UsageEvent> {
    let chat_model = message_field(blob, 1)?;
    let usage = message_field(chat_model, 4)?;

    let timestamp = message_field(chat_model, 9)
        .and_then(|start| message_field(start, 4))
        .and_then(proto_timestamp_ms)
        .filter(|&ms| ms > 0)
        .unwrap_or(session_timestamp);

    let to_u64 = |v: u64| v.min(i64::MAX as u64);
    let input = to_u64(varint_field(usage, 1).unwrap_or(0))
        .saturating_add(to_u64(varint_field(usage, 2).unwrap_or(0)));
    let cache_read = to_u64(varint_field(usage, 5).unwrap_or(0));
    let output_text = to_u64(varint_field(usage, 9).unwrap_or(0));
    let reasoning = to_u64(varint_field(usage, 10).unwrap_or(0));
    let output = output_text.saturating_add(reasoning);
    if input == 0 && output == 0 && cache_read == 0 {
        return None;
    }

    let response_id = string_field(usage, 11)
        .filter(|text| !text.trim().is_empty())
        .map(|text| text.to_string());
    if let Some(key) = &response_id {
        if !seen_response_ids.insert(key.clone()) {
            return None;
        }
    }

    let model = string_field(chat_model, 19)
        .filter(|text| !text.trim().is_empty())
        .unwrap_or("unknown")
        .to_string();

    let (id, confidence) = match &response_id {
        Some(rid) => (
            EventId::derive(&["antigravity", session_id, rid]),
            Confidence::Exact,
        ),
        None => (
            EventId::derive(&["antigravity", "cli", session_id, &idx.to_string()]),
            Confidence::Derived,
        ),
    };

    Some(UsageEvent {
        id,
        source: SourceId::Antigravity,
        ts: Timestamp::from_ms(timestamp),
        model,
        session: session_id.to_string(),
        project: project.to_string(),
        counters: Counters {
            input_fresh: Some(input),
            cache_read: Some(cache_read),
            cache_write_5m: None,
            cache_write_1h: None,
            output: Some(output),
        },
        extras: Extras {
            reasoning_within_output: (reasoning > 0).then_some(reasoning),
            ..Extras::default()
        },
        billing: BillingMode::Plan,
        confidence,
    })
}

fn read_trajectory_meta(conn: &rusqlite::Connection, path: &Path) -> (i64, Option<String>) {
    let blob: Option<Vec<u8>> = conn
        .query_row(
            "SELECT data FROM trajectory_metadata_blob LIMIT 1",
            [],
            |row| row.get(0),
        )
        .ok();

    let mut timestamp = file_modified_ms(path);
    let mut project = None;

    if let Some(blob) = &blob {
        if let Some(ms) = session_created_ms(blob).filter(|&ms| ms > 0) {
            timestamp = ms;
        }
        if let Some(uri) = message_field(blob, 1).and_then(|folder| string_field(folder, 1)) {
            if let Some(path_str) = file_uri_to_path(uri) {
                project = Some(project_label(&path_str));
            }
        }
    }

    (timestamp, project)
}

fn session_created_ms(blob: &[u8]) -> Option<i64> {
    proto_timestamp_ms(message_field(blob, 2)?)
}

fn proto_timestamp_ms(ts: &[u8]) -> Option<i64> {
    let seconds = i64::try_from(varint_field(ts, 1)?).ok()?;
    let nanos = i64::try_from(varint_field(ts, 2).unwrap_or(0)).ok()?;
    if !(0..=999_999_999).contains(&nanos) {
        return None;
    }
    seconds.checked_mul(1000)?.checked_add(nanos / 1_000_000)
}

fn file_modified_ms(path: &Path) -> i64 {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn file_uri_to_path(uri: &str) -> Option<String> {
    let decoded = percent_decode(uri.strip_prefix("file://")?);
    let bytes = decoded.as_bytes();
    let path = if bytes.first() == Some(&b'/') {
        if bytes.len() >= 3 && bytes[2] == b':' {
            decoded[1..].to_string()
        } else {
            decoded
        }
    } else {
        format!("//{decoded}")
    };
    Some(path)
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex_value(bytes[i + 1]), hex_value(bytes[i + 2])) {
                out.push((hi << 4) | lo);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn project_label(path: &str) -> String {
    path.rsplit(['/', '\\'])
        .find(|s| !s.is_empty())
        .unwrap_or("unknown")
        .to_string()
}

enum Wire<'a> {
    Varint(u64),
    Len(&'a [u8]),
    Fixed64,
    Fixed32,
}

struct ProtoReader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> ProtoReader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }

    fn read_varint(&mut self) -> Option<u64> {
        let mut result: u64 = 0;
        let mut shift = 0u32;
        loop {
            let byte = *self.buf.get(self.pos)?;
            self.pos += 1;
            result |= u64::from(byte & 0x7f) << shift;
            if byte & 0x80 == 0 {
                return Some(result);
            }
            shift += 7;
            if shift >= 64 {
                return None;
            }
        }
    }

    fn next_field(&mut self) -> Option<(u64, Wire<'a>)> {
        if self.pos >= self.buf.len() {
            return None;
        }
        let tag = self.read_varint()?;
        let field = tag >> 3;
        let wire = match tag & 0x7 {
            0 => Wire::Varint(self.read_varint()?),
            1 => {
                self.pos = self.pos.checked_add(8).filter(|&p| p <= self.buf.len())?;
                Wire::Fixed64
            }
            2 => {
                let len = self.read_varint()? as usize;
                let end = self.pos.checked_add(len).filter(|&p| p <= self.buf.len())?;
                let bytes = &self.buf[self.pos..end];
                self.pos = end;
                Wire::Len(bytes)
            }
            5 => {
                self.pos = self.pos.checked_add(4).filter(|&p| p <= self.buf.len())?;
                Wire::Fixed32
            }
            _ => return None,
        };
        Some((field, wire))
    }
}

fn message_field(buf: &[u8], field: u64) -> Option<&[u8]> {
    let mut reader = ProtoReader::new(buf);
    while let Some((found, wire)) = reader.next_field() {
        if found == field {
            if let Wire::Len(bytes) = wire {
                return Some(bytes);
            }
        }
    }
    None
}

fn varint_field(buf: &[u8], field: u64) -> Option<u64> {
    let mut reader = ProtoReader::new(buf);
    while let Some((found, wire)) = reader.next_field() {
        if found == field {
            if let Wire::Varint(value) = wire {
                return Some(value);
            }
        }
    }
    None
}

fn string_field(buf: &[u8], field: u64) -> Option<&str> {
    message_field(buf, field).and_then(|bytes| std::str::from_utf8(bytes).ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn enc_varint(field: u64, value: u64) -> Vec<u8> {
        let mut out = encode_varint(field << 3);
        out.extend(encode_varint(value));
        out
    }

    fn enc_len(field: u64, payload: &[u8]) -> Vec<u8> {
        let mut out = encode_varint((field << 3) | 2);
        out.extend(encode_varint(payload.len() as u64));
        out.extend_from_slice(payload);
        out
    }

    fn encode_varint(mut value: u64) -> Vec<u8> {
        let mut out = Vec::new();
        loop {
            let mut byte = (value & 0x7f) as u8;
            value >>= 7;
            if value != 0 {
                byte |= 0x80;
            }
            out.push(byte);
            if value == 0 {
                break;
            }
        }
        out
    }

    fn sample_gen(model: &str, response_id: &str) -> Vec<u8> {
        let mut usage = Vec::new();
        usage.extend(enc_varint(1, 100));
        usage.extend(enc_varint(2, 50));
        usage.extend(enc_varint(5, 20));
        usage.extend(enc_varint(9, 30));
        usage.extend(enc_varint(10, 7));
        usage.extend(enc_len(11, response_id.as_bytes()));

        let mut ts = Vec::new();
        ts.extend(enc_varint(1, 1_700_000_000));
        ts.extend(enc_varint(2, 0));
        let start_meta = enc_len(4, &ts);

        let mut chat = Vec::new();
        chat.extend(enc_len(4, &usage));
        chat.extend(start_meta);
        chat.extend(enc_len(19, model.as_bytes()));

        enc_len(1, &chat)
    }

    #[test]
    fn parses_gen_metadata_into_disjoint_counters() {
        let dir = tempfile_dir();
        let path = dir.join("sess.db");
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE gen_metadata (idx INTEGER, data BLOB);
             CREATE TABLE trajectory_metadata_blob (data BLOB);",
        )
        .unwrap();
        let blob = sample_gen("gemini-3-flash", "resp-1");
        conn.execute(
            "INSERT INTO gen_metadata (idx, data) VALUES (0, ?1)",
            rusqlite::params![blob],
        )
        .unwrap();

        let out = parse_db(&path);
        assert_eq!(out.events.len(), 1);
        let e = &out.events[0];
        assert_eq!(e.source, SourceId::Antigravity);
        assert_eq!(e.model, "gemini-3-flash");
        assert_eq!(e.counters.input_fresh, Some(150));
        assert_eq!(e.counters.cache_read, Some(20));
        assert_eq!(e.counters.output, Some(37));
        assert_eq!(e.extras.reasoning_within_output, Some(7));
        assert_eq!(e.confidence, Confidence::Exact);
        assert_eq!(e.billing, BillingMode::Plan);
    }

    #[test]
    fn duplicate_response_id_is_skipped() {
        let dir = tempfile_dir();
        let path = dir.join("dup.db");
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch("CREATE TABLE gen_metadata (idx INTEGER, data BLOB);")
            .unwrap();
        let blob = sample_gen("m", "same");
        conn.execute(
            "INSERT INTO gen_metadata (idx, data) VALUES (0, ?1), (1, ?1)",
            rusqlite::params![blob],
        )
        .unwrap();
        let out = parse_db(&path);
        assert_eq!(out.events.len(), 1);
        assert_eq!(out.rows_seen, 1);
    }

    #[test]
    fn proto_timestamp_rejects_bad_nanos() {
        let mut ts = Vec::new();
        ts.extend(enc_varint(1, 10));
        ts.extend(enc_varint(2, 2_000_000_000));
        assert!(proto_timestamp_ms(&ts).is_none());
    }

    fn tempfile_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-ag-cli-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
}
