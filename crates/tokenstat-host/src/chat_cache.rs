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
