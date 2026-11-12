// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! How much a conversation's next turn has to read, and for which model.
//!
//! An agent resends the whole conversation on every request. The provider
//! keeps a prompt cache so a recent prefix costs little to read again, but the
//! cache belongs to one model and lives for a few minutes or an hour. After a
//! long pause, or on a different model, the next message reads everything at
//! full price. Clients use this record to say so before that happens.
//!
//! Only Claude reports enough to know: each request in its stream carries the
//! model, the tokens it put in front of that model, and which cache lifetime
//! it wrote. A turn's summed usage cannot stand in for that, because a turn of
//! many tool calls adds up the same context many times.

// The record is part of every conversation. Reading a stream into it only
// happens where turns run, which is the local host.
#![cfg_attr(not(feature = "local-host"), allow(dead_code))]

use serde::{Deserialize, Serialize};
use serde_json::Value;

const FIVE_MINUTES_MS: i64 = 5 * 60 * 1000;
const ONE_HOUR_MS: i64 = 60 * 60 * 1000;

/// The last request a conversation sent, stored on the conversation.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PromptCache {
    /// The backend that sent it. A different backend has no cache here.
    pub backend: String,
    /// Everything the last request put in front of the model: uncached input,
    /// cache reads and cache writes.
    pub tokens: u64,
    /// The model the provider says answered.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// The model setting the turn launched with, as the conversation stores
    /// it. Clients compare a new setting against this, not against `model`,
    /// because a setting can be an alias or empty for the default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection: Option<String>,
    /// When the last request's usage was observed.
    pub at_ms: i64,
    /// How long the provider keeps the cache after that.
    pub ttl_ms: i64,
}

/// One request's context, read from a stream record.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Reading {
    pub tokens: u64,
    pub model: Option<String>,
    pub ttl_ms: i64,
    pub at_ms: i64,
}

/// Read a Claude `assistant` stream record.
///
/// A subagent's request carries its own, smaller context, so only records of
/// the main conversation count. A request that wrote no cache says nothing
/// about the lifetime, so it keeps the one this turn already saw, or five
/// minutes, the shorter of the two. Guessing short warns early, never late.
pub(crate) fn claude_reading(value: &Value, previous: Option<&Reading>) -> Option<Reading> {
    if value["type"] != "assistant" || !value["parent_tool_use_id"].is_null() {
        return None;
    }
    let message = &value["message"];
    let usage = &message["usage"];
    let input = usage["input_tokens"].as_u64()?;
    let read = usage["cache_read_input_tokens"].as_u64().unwrap_or(0);
    let written = usage["cache_creation_input_tokens"].as_u64().unwrap_or(0);
    let hour = usage["cache_creation"]["ephemeral_1h_input_tokens"]
        .as_u64()
        .unwrap_or(0);
    let minutes = usage["cache_creation"]["ephemeral_5m_input_tokens"]
        .as_u64()
        .unwrap_or(0);
    let ttl_ms = if minutes > 0 {
        FIVE_MINUTES_MS
    } else if hour > 0 {
        ONE_HOUR_MS
    } else {
        previous.map_or(FIVE_MINUTES_MS, |reading| reading.ttl_ms)
    };
    Some(Reading {
        tokens: input.saturating_add(read).saturating_add(written),
        model: message["model"]
            .as_str()
            .filter(|model| !model.is_empty())
            .map(str::to_owned),
        ttl_ms,
        at_ms: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_millis().min(i64::MAX as u128) as i64)
            .unwrap_or(0),
    })
}

/// The text Claude Code prints when `--resume` names a session it no longer
/// keeps. It deletes old session transcripts on its own schedule.
pub(crate) const CLAUDE_MISSING_SESSION: &str = "No conversation found with session ID";

/// Whether Claude Code still keeps this session's transcript.
///
/// None when it cannot tell: an unusual session id, or no projects folder
/// to look in. A caller only drops a session on a definite no, so a guess
/// never throws away a conversation the agent still has.
pub(crate) fn claude_session_exists(session: &str) -> Option<bool> {
    if session.is_empty()
        || !session
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return None;
    }
    let base = std::env::var_os("CLAUDE_CONFIG_DIR")
        .filter(|dir| !dir.is_empty())
        .map(std::path::PathBuf::from)
        .or_else(|| tokenstat_paths::home_dir().map(|home| home.join(".claude")))?;
    session_in_projects(&base.join("projects"), session)
}

/// Claude Code files a session under a folder named after the working
/// directory. Looking in every project folder avoids re-deriving that name.
fn session_in_projects(projects: &std::path::Path, session: &str) -> Option<bool> {
    let entries = std::fs::read_dir(projects).ok()?;
    let name = format!("{session}.jsonl");
    for entry in entries.flatten() {
        if entry.path().join(&name).is_file() {
            return Some(true);
        }
    }
    Some(false)
}

/// The last main-conversation request in a stored Claude stream.
///
/// Used for chats whose turns predate the cache record. Reads forward so a
/// request that wrote no cache inherits the lifetime seen before it.
pub(crate) fn reading_from_stream(bytes: &[u8]) -> Option<Reading> {
    let mut reading = None;
    for line in bytes.split(|byte| *byte == b'\n') {
        if !line
            .windows(b"\"assistant\"".len())
            .any(|chunk| chunk == b"\"assistant\"")
        {
            continue;
        }
        let Ok(value) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        if let Some(next) = claude_reading(&value, reading.as_ref()) {
            reading = Some(next);
        }
    }
    reading
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn assistant(usage: Value) -> Value {
        json!({"type":"assistant","parent_tool_use_id":null,
            "message":{"model":"claude-opus-5-5","usage":usage}})
    }

    #[test]
    fn adds_every_input_bucket_and_reads_the_hour_cache() {
        let reading = claude_reading(
            &assistant(json!({"input_tokens":2,"cache_read_input_tokens":44634,
                "cache_creation_input_tokens":267,"output_tokens":334,
                "cache_creation":{"ephemeral_1h_input_tokens":267,"ephemeral_5m_input_tokens":0}})),
            None,
        )
        .unwrap();
        assert_eq!(reading.tokens, 44903);
        assert_eq!(reading.model.as_deref(), Some("claude-opus-5-5"));
        assert_eq!(reading.ttl_ms, ONE_HOUR_MS);
    }

    #[test]
    fn a_read_only_request_keeps_the_lifetime_already_seen() {
        let usage = json!({"input_tokens":1,"cache_read_input_tokens":10});
        let hour = Reading {
            tokens: 5,
            model: None,
            ttl_ms: ONE_HOUR_MS,
            at_ms: 0,
        };
        assert_eq!(
            claude_reading(&assistant(usage.clone()), Some(&hour))
                .unwrap()
                .ttl_ms,
            ONE_HOUR_MS
        );
        assert_eq!(
            claude_reading(&assistant(usage), None).unwrap().ttl_ms,
            FIVE_MINUTES_MS
        );
    }

    #[test]
    fn mixed_cache_lifetimes_use_the_shorter_one() {
        let reading = claude_reading(
            &assistant(json!({"input_tokens": 1, "cache_creation_input_tokens": 20,
                "cache_creation": {"ephemeral_1h_input_tokens": 10,
                    "ephemeral_5m_input_tokens": 10}})),
            None,
        )
        .unwrap();
        assert_eq!(reading.ttl_ms, FIVE_MINUTES_MS);
        assert!(reading.at_ms > 0);
    }

    #[test]
    fn a_stored_stream_gives_its_last_request_and_the_lifetime_before_it() {
        let first = assistant(json!({"input_tokens":1,"cache_read_input_tokens":100,
            "cache_creation_input_tokens":5,"cache_creation":{"ephemeral_1h_input_tokens":5}}));
        let last = assistant(json!({"input_tokens":2,"cache_read_input_tokens":300}));
        let stream = format!("{first}\nnot json\n{{\"type\":\"result\"}}\n{last}\n");
        let reading = reading_from_stream(stream.as_bytes()).unwrap();
        assert_eq!(reading.tokens, 302);
        assert_eq!(reading.ttl_ms, ONE_HOUR_MS);
        assert!(reading_from_stream(b"{\"type\":\"result\"}\n").is_none());
    }

    #[test]
    fn a_session_is_found_in_any_project_folder() {
        let root = tempfile::tempdir().unwrap();
        let projects = root.path().join("projects");
        assert_eq!(session_in_projects(&projects, "abc"), None);
        std::fs::create_dir_all(projects.join("-Users-me-one")).unwrap();
        std::fs::create_dir_all(projects.join("-Users-me-two")).unwrap();
        assert_eq!(session_in_projects(&projects, "abc"), Some(false));
        std::fs::write(projects.join("-Users-me-two/abc.jsonl"), "{}").unwrap();
        assert_eq!(session_in_projects(&projects, "abc"), Some(true));
        assert_eq!(claude_session_exists("../etc/passwd"), None);
    }

    #[test]
    fn subagents_and_records_without_usage_are_ignored() {
        let mut subagent = assistant(json!({"input_tokens":1}));
        subagent["parent_tool_use_id"] = json!("toolu_1");
        assert!(claude_reading(&subagent, None).is_none());
        assert!(claude_reading(&assistant(json!({})), None).is_none());
        assert!(
            claude_reading(&json!({"type":"result","usage":{"input_tokens":1}}), None).is_none()
        );
    }
}
