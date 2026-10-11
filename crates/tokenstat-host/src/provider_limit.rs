// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Refusals from provider-owned error envelopes, never assistant/tool prose.
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Limit {
    pub provider: String,
    pub kind: String,
    pub reason: String,
    pub resets_at_ms: Option<i64>,
    pub observed_at_ms: i64,
}

pub fn from_record(provider: &str, value: &Value, now: i64) -> Option<Limit> {
    let kind = value.get("type")?.as_str()?;
    let error = match (provider, kind) {
        ("codex", "turn.failed") => value.get("error")?,
        ("codex" | "grok" | "claude" | "cursor", "error") => value.get("error").unwrap_or(value),
        ("claude", "result") if value.get("is_error").and_then(Value::as_bool) == Some(true) => {
            value
        }
        // Unknown vendor error formats stay manual until verified.
        _ => return None,
    };
    let text = error
        .get("message")
        .or_else(|| error.get("result"))
        .and_then(Value::as_str)
        .or_else(|| error.as_str())
        .unwrap_or("");
    let code = error
        .get("code")
        .or_else(|| error.get("type"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let lower = text.to_lowercase();
    // Codex exec 0.162 emits its protocol UsageLimitReached Display in its
    // own error/turn.failed envelope. No timestamp is inferred from prose.
    let exhausted = matches!(
        code,
        "usage_limit_reached" | "usage_limit_exceeded" | "quota_exceeded" | "insufficient_quota"
    ) || (provider == "codex"
        && (lower.starts_with("you’ve hit your usage limit")
            || lower.starts_with("you've hit your usage limit")
            || lower.starts_with("your workspace is out of credits")
            || lower.starts_with("you hit your spend cap")))
        || (provider == "claude"
            && (lower.starts_with("you've hit your limit")
                || lower.starts_with("you’ve hit your limit")
                || lower.starts_with("usage limit reached")));
    let throttle = matches!(code, "rate_limit_error" | "rate_limit_exceeded")
        || (!exhausted && lower.starts_with("rate limit exceeded"));
    if !exhausted && !throttle {
        return None;
    }
    let reset = error
        .get("resets_at")
        .or_else(|| error.get("reset_at"))
        .and_then(|v| {
            v.as_i64()
                .and_then(|n| {
                    if n > 1_000_000_000_000 {
                        Some(n)
                    } else {
                        n.checked_mul(1000)
                    }
                })
                .or_else(|| {
                    v.as_str()?
                        .parse::<jiff::Timestamp>()
                        .ok()
                        .map(|t| t.as_millisecond())
                })
        })
        .filter(|n| *n > now && *n < now.saturating_add(366 * 86400 * 1000));
    Some(Limit {
        provider: provider.into(),
        kind: if exhausted { "usage" } else { "throttle" }.into(),
        reason: text.chars().take(1000).collect(),
        resets_at_ms: reset,
        observed_at_ms: now,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn only_provider_error_envelopes_trigger_routes() {
        let text = "You've hit your usage limit. Try again at 8:00 AM.";
        assert!(from_record("codex", &json!({"type":"error","message":text}), 1000).is_some());
        for kind in ["assistant", "item.completed", "text", "tool_result"] {
            assert!(
                from_record(
                    "codex",
                    &json!({"type":kind,"message":text,"error":{"code":"usage_limit_reached"}}),
                    1000
                )
                .is_none()
            );
        }
        assert!(
            from_record(
                "codex",
                &json!({"type":"error","message":"Codex tool rejected: usage limit reached"}),
                1000
            )
            .is_none()
        );
        assert!(
            from_record(
                "muse",
                &json!({"type":"error","code":"quota_exceeded"}),
                1000
            )
            .is_none()
        );
    }
    #[test]
    fn reset_is_an_instant_and_throttling_is_distinct() {
        let e = json!({"type":"turn.failed","error":{"code":"usage_limit_reached","message":"limit","resets_at":1700000000}});
        let limit = from_record("codex", &e, 1000).unwrap();
        assert_eq!(limit.resets_at_ms, None); // unreasonable distant future
        let limit = from_record("codex", &e, 1699999999000).unwrap();
        assert_eq!(limit.resets_at_ms, Some(1700000000000));
        assert_eq!(limit.kind, "usage");
        let throttle = from_record(
            "claude",
            &json!({"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}),
            1000,
        )
        .unwrap();
        assert_eq!(throttle.kind, "throttle");
        assert_eq!(throttle.resets_at_ms, None);
        assert!(
            from_record(
                "claude",
                &json!({"type":"error","error":{"type":"authentication_error"}}),
                1000
            )
            .is_none()
        );
    }
}

#[cfg(test)]
mod stream_tests {
    use crate::transcript::{Event, Parser};
    use serde_json::json;
    #[test]
    fn a_real_turn_failure_is_displayed_and_its_limit_is_consumed_once() {
        let reset = crate::chat::now_ms() + 60000;
        let mut parser = Parser::new("codex");
        let record=json!({"type":"turn.failed","error":{"code":"usage_limit_reached","message":"You've hit your usage limit.","resets_at":reset}}).to_string()+"\n";
        let events = parser.push_events(record.as_bytes());
        assert!(
            events
                .iter()
                .any(|e| matches!(e,Event::Failed{text} if text=="You've hit your usage limit."))
        );
        assert_eq!(parser.take_limit().unwrap().resets_at_ms, Some(reset));
        assert!(parser.take_limit().is_none());
        let quoted=json!({"type":"item.completed","item":{"type":"agent_message","text":"You've hit your usage limit."}}).to_string()+"\n";
        let events = parser.push_events(quoted.as_bytes());
        assert!(events.iter().any(|e| matches!(e, Event::Text { .. })));
        assert!(parser.take_limit().is_none());
    }
}
