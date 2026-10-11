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
    let unavailable = matches!(
        code,
        "overloaded_error"
            | "api_error"
            | "internal_server_error"
            | "service_unavailable"
            | "server_error"
    );
    let authentication = matches!(
        code,
        "authentication_error" | "invalid_api_key" | "unauthorized"
    ) || (provider == "claude"
        && lower.starts_with("not logged in · please run /login"));
    // Other provider-owned errors are visible in routing history but stay manual.
    if !exhausted && !throttle && !unavailable && !authentication && text.is_empty() {
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
        kind: if exhausted {
            "usage"
        } else if throttle {
            "throttle"
        } else if unavailable {
            "error"
        } else if authentication {
            "auth"
        } else {
            "failure"
        }
        .into(),
        reason: if text.is_empty() { code } else { text }
            .chars()
            .take(1000)
            .collect(),
        resets_at_ms: reset,
        observed_at_ms: now,
    })
}

/// A proven terminal process failure is distinct from a provider quota reading.
/// It is only eligible for failover under a separate explicit policy switch.
pub fn from_exit(
    provider: &str,
    exit: Option<i32>,
    stopped: bool,
    sign_in: bool,
    now: i64,
) -> Option<Limit> {
    if stopped || (!sign_in && exit == Some(0)) {
        return None;
    }
    Some(Limit {
        provider: provider.into(),
        kind: if sign_in { "auth" } else { "failure" }.into(),
        reason: if sign_in {
            "This agent needs sign-in on this computer.".into()
        } else {
            format!(
                "Agent turn ended unsuccessfully (exit {}). See this turn’s error output for details.",
                exit.map(|code| code.to_string())
                    .unwrap_or_else(|| "unknown".into())
            )
        },
        resets_at_ms: None,
        observed_at_ms: now,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn observed_claude_login_refusal_is_authentication() {
        let record = json!({"type":"result", "is_error":true,
            "result":"Not logged in · Please run /login"});
        assert_eq!(from_record("claude", &record, 1).unwrap().kind, "auth");
        let prose = json!({"type":"assistant", "message":"Not logged in · Please run /login"});
        assert!(from_record("claude", &prose, 1).is_none());
        let success = json!({"type":"result", "is_error":false,
            "result":"Not logged in · Please run /login"});
        assert!(from_record("claude", &success, 1).is_none());
    }

    #[test]
    fn terminal_failures_are_manual_by_default_and_stop_is_never_a_failure() {
        assert!(from_exit("muse", Some(0), false, false, 1).is_none());
        assert!(from_exit("muse", Some(1), true, true, 1).is_none());
        assert_eq!(
            from_exit("muse", Some(1), false, true, 1).unwrap().kind,
            "auth"
        );
        assert_eq!(
            from_exit("opencode", Some(1), false, false, 1)
                .unwrap()
                .kind,
            "failure"
        );
        assert!(
            from_exit("opencode", None, false, false, 1)
                .unwrap()
                .resets_at_ms
                .is_none()
        );
    }
    #[test]
    fn service_auth_and_unknown_errors_have_distinct_manual_or_opt_in_kinds() {
        for (code, kind) in [
            ("overloaded_error", "error"),
            ("api_error", "error"),
            ("authentication_error", "auth"),
            ("invalid_request_error", "failure"),
        ] {
            let record = json!({"type":"error","error":{"type":code,"message":"Provider refused this request"}});
            assert_eq!(from_record("claude", &record, 1000).unwrap().kind, kind);
            assert!(
                from_record("claude", &json!({"type":"assistant","error":record}), 1000).is_none()
            );
        }
    }
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
            .is_some_and(|error| error.kind == "failure")
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
            .is_some_and(|error| error.kind == "auth")
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
