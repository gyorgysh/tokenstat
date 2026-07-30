//! Codex CLI rollout reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.codex/sessions/YYYY/MM/DD/rollout-<iso-timestamp>-<uuid>.jsonl
//! ```
//!
//! Every line is `{type, timestamp, payload}`. Usage lives on `event_msg`
//! records whose payload type is `token_count`.
//!
//! # Two ways this source differs from Claude Code
//!
//! **Cached tokens are a subset here, not a separate bucket.** Anthropic reports
//! `cache_read_input_tokens` alongside `input_tokens`, so the two add up.
//! OpenAI reports `cached_input_tokens` as part of `input_tokens`. Adding them
//! would count the cached portion twice, so the fresh figure is the difference.
//!
//! **There is no request identifier.** Identity is the position of the record
//! within its rollout file. That is deterministic, so re-reading a file produces
//! the same identities and ingestion stays idempotent, but it cannot survive the
//! file being rewritten with different early content. Recorded as
//! [`Confidence::Derived`] to say so.

use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, Cumulative, Delta, EventId, Extras, SourceId, Timestamp,
    UsageEvent,
};

/// Locate the Codex session directory.
pub fn discover(home: &Path) -> Option<PathBuf> {
    let root = match std::env::var_os("CODEX_HOME") {
        Some(dir) => PathBuf::from(dir),
        None => home.join(".codex"),
    };
    let sessions = root.join("sessions");
    sessions.is_dir().then_some(sessions)
}

pub fn shards(sessions: &Path) -> Vec<PathBuf> {
    walkdir::WalkDir::new(sessions)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
        .map(|e| e.into_path())
        .filter(|p| {
            p.extension().is_some_and(|x| x == "jsonl")
                && p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("rollout-"))
        })
        .collect()
}

#[derive(Deserialize)]
struct Row<'a> {
    #[serde(rename = "type")]
    kind: Option<&'a str>,
    timestamp: Option<&'a str>,
    payload: Option<Payload<'a>>,
}

#[derive(Deserialize)]
struct Payload<'a> {
    #[serde(rename = "type")]
    kind: Option<&'a str>,
    // session_meta
    id: Option<&'a str>,
    cwd: Option<&'a str>,
    // turn_context
    model: Option<&'a str>,
    // token_count
    info: Option<Info>,
    rate_limits: Option<RateLimits<'a>>,
}

#[derive(Deserialize)]
struct Info {
    total_token_usage: Option<Usage>,
    last_token_usage: Option<Usage>,
}

#[derive(Deserialize, Clone, Copy, Default)]
struct Usage {
    input_tokens: Option<u64>,
    cached_input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    reasoning_output_tokens: Option<u64>,
}

#[derive(Deserialize)]
struct RateLimits<'a> {
    plan_type: Option<&'a str>,
}

impl Usage {
    /// Map onto disjoint buckets, undoing the subset relationship.
    fn counters(&self) -> Counters {
        let input = self.input_tokens.unwrap_or(0);
        let cached = self.cached_input_tokens.unwrap_or(0);
        Counters {
            // Clamped: a vendor bug or schema change that made cached exceed
            // input would otherwise underflow into an enormous number.
            input_fresh: Some(input.saturating_sub(cached)),
            cache_read: self.cached_input_tokens,
            // Codex does not bill or report cache writes. Reporting zero would
            // claim knowledge this source does not have.
            cache_write_5m: None,
            cache_write_1h: None,
            output: self.output_tokens,
        }
    }
}

#[derive(Debug, Default)]
pub struct ParseOutput {
    pub events: Vec<UsageEvent>,
    pub warnings: Vec<Warning>,
    pub rows_seen: u64,
}

/// Parse one rollout file.
pub fn parse_file(path: &Path, contents: &str) -> ParseOutput {
    let mut out = ParseOutput::default();

    let mut session = String::new();
    let mut project = String::from("unknown");
    let mut model = String::from("unknown");
    let mut billing = BillingMode::Unknown;
    let mut ordinal: u32 = 0;

    // Both figures are tracked so they can be checked against each other at the
    // end of the file. Trusting the vendor's delta without verifying it against
    // its own running total would mean a regression in either one goes unseen.
    let mut summed_deltas = Delta(Counters::default());
    let mut final_total: Option<Cumulative> = None;
    let mut first_index = out.events.len();

    for (i, line) in contents.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(row) = serde_json::from_str::<Row>(line) else {
            out.warnings.push(Warning::MalformedLine {
                path: path.to_path_buf(),
                line: i + 1,
            });
            continue;
        };
        let Some(payload) = row.payload else { continue };

        match row.kind {
            Some("session_meta") => {
                if let Some(id) = payload.id {
                    session = id.to_string();
                }
                if let Some(cwd) = payload.cwd {
                    project = cwd
                        .rsplit(['/', '\\'])
                        .find(|s| !s.is_empty())
                        .unwrap_or("unknown")
                        .to_string();
                }
                first_index = out.events.len();
            }
            // The model can change mid-session, so it is tracked as the file is
            // walked rather than read once.
            Some("turn_context") => {
                if let Some(m) = payload.model {
                    model = m.to_string();
                }
            }
            _ => {}
        }

        if payload.kind != Some("token_count") {
            continue;
        }
        let Some(info) = payload.info else { continue };

        if let Some(rl) = &payload.rate_limits {
            if rl.plan_type.is_some() {
                // A plan is in force, so this usage was not billed per token.
                billing = BillingMode::Plan;
            }
        }

        if let Some(total) = info.total_token_usage {
            final_total = Some(Cumulative(total.counters()));
        }

        // The vendor states the per-request delta directly, which is better than
        // differencing the running total because it survives a gap in the file.
        let Some(last) = info.last_token_usage else {
            continue;
        };
        let counters = last.counters();
        if counters.total() == 0 {
            // Heartbeat records that restate a total without new usage.
            continue;
        }
        out.rows_seen += 1;
        summed_deltas = summed_deltas + Delta(counters);

        let ts = row
            .timestamp
            .and_then(|s| s.parse::<jiff::Timestamp>().ok())
            .map(|t| Timestamp::from_ms(t.as_millisecond()))
            .unwrap_or(Timestamp::from_ms(0));

        out.events.push(UsageEvent {
            id: EventId::derive(&["codex", &session, &ordinal.to_string()]),
            source: SourceId::Codex,
            ts,
            model: model.clone(),
            session: session.clone(),
            project: project.clone(),
            counters,
            extras: Extras {
                reasoning_within_output: last.reasoning_output_tokens,
                web_search_requests: None,
                web_fetch_requests: None,
            },
            billing,
            confidence: Confidence::Derived,
        });
        ordinal += 1;
    }

    // The deltas should reconstruct the running total. If they do not, the file
    // is missing records or the vendor changed what these fields mean, and the
    // running total is the more trustworthy of the two.
    if let Some(Cumulative(total)) = final_total {
        let summed = summed_deltas.0;
        if summed.total() != total.total() && total.total() > 0 {
            out.warnings.push(Warning::DeltaMismatch {
                path: path.to_path_buf(),
                summed: summed.total(),
                reported: total.total(),
            });
            // Replace the per-request rows with a single record carrying the
            // vendor's own total, rather than publishing a figure known to
            // disagree with the source.
            out.events.truncate(first_index);
            out.events.push(UsageEvent {
                id: EventId::derive(&["codex", &session, "total"]),
                source: SourceId::Codex,
                ts: Timestamp::from_ms(0),
                model: model.clone(),
                session: session.clone(),
                project: project.clone(),
                counters: total,
                extras: Extras::default(),
                billing,
                confidence: Confidence::Derived,
            });
        }
    }

    // Timestamps only exist on the records themselves, so a rebuilt total row
    // inherits the last one seen rather than the epoch.
    if let Some(last_ts) = contents
        .lines()
        .rev()
        .filter_map(|l| serde_json::from_str::<Row>(l).ok())
        .find_map(|r| r.timestamp.and_then(|s| s.parse::<jiff::Timestamp>().ok()))
    {
        for e in out.events.iter_mut().filter(|e| e.ts.utc_ms == 0) {
            e.ts = Timestamp::from_ms(last_ts.as_millisecond());
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p() -> PathBuf {
        PathBuf::from("/h/.codex/sessions/2026/07/02/rollout-x.jsonl")
    }

    const META: &str = r#"{"type":"session_meta","timestamp":"2026-07-01T18:28:00.000Z","payload":{"id":"sess-1","cwd":"/Users/me/git/tokenstat"}}"#;
    const CTX: &str = r#"{"type":"turn_context","timestamp":"2026-07-01T18:28:01.000Z","payload":{"model":"gpt-5.5","timezone":"Australia/Perth"}}"#;

    fn tc(input: u64, cached: u64, output: u64, t_in: u64, t_cached: u64, t_out: u64) -> String {
        format!(
            r#"{{"type":"event_msg","timestamp":"2026-07-01T18:28:30.711Z","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":{input},"cached_input_tokens":{cached},"output_tokens":{output},"reasoning_output_tokens":0}},"total_token_usage":{{"input_tokens":{t_in},"cached_input_tokens":{t_cached},"output_tokens":{t_out},"reasoning_output_tokens":0}}}},"rate_limits":{{"plan_type":"free"}}}}}}"#
        )
    }

    #[test]
    fn cached_tokens_are_subtracted_from_input_not_added() {
        let input = format!(
            "{META}\n{CTX}\n{}\n",
            tc(12454, 4992, 277, 12454, 4992, 277)
        );
        let out = parse_file(&p(), &input);
        assert_eq!(out.events.len(), 1);
        let c = out.events[0].counters;
        // The cached portion is inside input_tokens here, unlike Anthropic.
        assert_eq!(c.input_fresh, Some(12454 - 4992));
        assert_eq!(c.cache_read, Some(4992));
        // Adding them back must reproduce the vendor's own input figure.
        assert_eq!(c.input_fresh.unwrap() + c.cache_read.unwrap(), 12454);
        assert_eq!(c.output, Some(277));
    }

    #[test]
    fn cache_writes_are_unknown_rather_than_zero() {
        let input = format!("{META}\n{CTX}\n{}\n", tc(10, 0, 5, 10, 0, 5));
        let c = parse_file(&p(), &input).events[0].counters;
        assert_eq!(c.cache_write_5m, None);
        assert_eq!(c.cache_write_1h, None);
        assert!(c.has_unknown());
    }

    #[test]
    fn deltas_are_used_rather_than_the_running_total() {
        // Two requests: totals grow, deltas do not.
        let input = format!(
            "{META}\n{CTX}\n{}\n{}\n",
            tc(12454, 4992, 277, 12454, 4992, 277),
            tc(12939, 12160, 30, 25393, 17152, 307)
        );
        let out = parse_file(&p(), &input);
        assert_eq!(out.events.len(), 2);
        assert!(out.warnings.is_empty());
        // Summing must give the running total, not double it.
        let total: u64 = out.events.iter().map(|e| e.counters.total()).sum();
        assert_eq!(total, 25393 + 307);
    }

    #[test]
    fn a_delta_that_disagrees_with_the_total_falls_back_to_the_total() {
        // Second delta understates: the file is missing a record.
        let input = format!(
            "{META}\n{CTX}\n{}\n{}\n",
            tc(100, 0, 10, 100, 0, 10),
            tc(1, 0, 1, 900, 0, 90)
        );
        let out = parse_file(&p(), &input);
        assert!(matches!(
            out.warnings.as_slice(),
            [Warning::DeltaMismatch { .. }]
        ));
        assert_eq!(out.events.len(), 1);
        assert_eq!(out.events[0].counters.total(), 990);
    }

    #[test]
    fn model_and_project_come_from_the_surrounding_records() {
        let input = format!("{META}\n{CTX}\n{}\n", tc(10, 0, 5, 10, 0, 5));
        let e = &parse_file(&p(), &input).events[0];
        assert_eq!(e.model, "gpt-5.5");
        assert_eq!(e.project, "tokenstat");
        assert_eq!(e.session, "sess-1");
    }

    #[test]
    fn a_model_change_mid_session_applies_to_later_requests() {
        let switch = r#"{"type":"turn_context","timestamp":"2026-07-01T18:29:00.000Z","payload":{"model":"gpt-5.5-mini"}}"#;
        let input = format!(
            "{META}\n{CTX}\n{}\n{switch}\n{}\n",
            tc(10, 0, 5, 10, 0, 5),
            tc(10, 0, 5, 20, 0, 10)
        );
        let out = parse_file(&p(), &input);
        assert_eq!(out.events[0].model, "gpt-5.5");
        assert_eq!(out.events[1].model, "gpt-5.5-mini");
    }

    #[test]
    fn a_plan_marks_usage_as_not_billed_per_token() {
        let input = format!("{META}\n{CTX}\n{}\n", tc(10, 0, 5, 10, 0, 5));
        assert_eq!(
            parse_file(&p(), &input).events[0].billing,
            BillingMode::Plan
        );
    }

    #[test]
    fn identities_are_stable_across_reparses() {
        let input = format!(
            "{META}\n{CTX}\n{}\n{}\n",
            tc(10, 0, 5, 10, 0, 5),
            tc(10, 0, 5, 20, 0, 10)
        );
        let a = parse_file(&p(), &input);
        let b = parse_file(&p(), &input);
        assert_eq!(a.events[0].id, b.events[0].id);
        assert_eq!(a.events[1].id, b.events[1].id);
        // Distinct requests must not collide.
        assert_ne!(a.events[0].id, a.events[1].id);
    }

    #[test]
    fn zero_usage_records_are_ignored() {
        let input = format!("{META}\n{CTX}\n{}\n", tc(0, 0, 0, 0, 0, 0));
        assert!(parse_file(&p(), &input).events.is_empty());
    }

    #[test]
    fn malformed_lines_warn_without_aborting() {
        let input = format!("{META}\n{{bad\n{CTX}\n{}\n", tc(10, 0, 5, 10, 0, 5));
        let out = parse_file(&p(), &input);
        assert_eq!(out.events.len(), 1);
        assert_eq!(out.warnings.len(), 1);
    }

    #[test]
    fn cached_exceeding_input_clamps_instead_of_underflowing() {
        let input = format!("{META}\n{CTX}\n{}\n", tc(5, 999, 1, 5, 999, 1));
        let c = parse_file(&p(), &input).events[0].counters;
        assert_eq!(c.input_fresh, Some(0));
    }
}
