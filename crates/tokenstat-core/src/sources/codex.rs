// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
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

/// Ordinary Codex logs and the private homes tokenstat creates for its chats.
/// Keep CODEX_HOME's override semantics for the ordinary CLI home, while always
/// including this install's chats. Use the host's shared data-root resolver so
/// portable installs and every desktop platform discover the same locations.
pub fn discover_all(home: &Path) -> Vec<PathBuf> {
    session_dirs(discover(home), tokenstat_paths::data_dir().as_deref())
}

fn session_dirs(primary: Option<PathBuf>, data: Option<&Path>) -> Vec<PathBuf> {
    let mut candidates: Vec<_> = primary.into_iter().collect();
    if let Some(data) = data
        && let Ok(chats) = std::fs::read_dir(data.join("chat"))
    {
        for chat in chats.filter_map(Result::ok) {
            if chat.file_type().is_ok_and(|kind| kind.is_dir()) {
                let sessions = chat.path().join("codex-hook").join("sessions");
                if sessions.is_dir() {
                    candidates.push(sessions);
                }
            }
        }
    }
    let mut seen = std::collections::HashSet::new();
    // The chosen spelling must be stable too: watermark keys use the path.
    // An override, dot segment or Windows verbatim prefix must not rename a
    // previously discovered shard just because it becomes the primary home.
    let mut roots: Vec<_> = candidates
        .into_iter()
        .map(|path| std::fs::canonicalize(&path).unwrap_or(path))
        .filter(|path| seen.insert(path.clone()))
        .collect();
    roots.sort();
    roots
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
    id: Option<&'a str>,
    cwd: Option<&'a str>,
    model_provider: Option<&'a str>,
    model: Option<&'a str>,
    info: Option<Info>,
    rate_limits: Option<RateLimits<'a>>,
}

#[derive(Deserialize)]
struct Info {
    total_token_usage: Option<Usage>,
    last_token_usage: Option<Usage>,
}

#[derive(Deserialize, Clone, Copy, Default, PartialEq, Eq)]
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
    fn counters(&self) -> Counters {
        Counters {
            // Clamped: a vendor bug or schema change that made cached exceed
            // input would otherwise underflow into an enormous number. And
            // when the vendor reported no input figure at all the fresh part
            // is unknown, not a zero the subtraction invented.
            input_fresh: self
                .input_tokens
                .map(|input| input.saturating_sub(self.cached_input_tokens.unwrap_or(0))),
            cache_read: self.cached_input_tokens,
            // Codex does not bill or report cache writes. Reporting zero would
            // claim knowledge this source does not have.
            cache_write_5m: None,
            cache_write_1h: None,
            output: self.output_tokens,
        }
    }

    fn reasoning(&self) -> Option<u64> {
        self.reasoning_output_tokens
            .filter(|&r| r > 0)
            .map(|r| match self.output_tokens {
                Some(output) => r.min(output),
                None => r,
            })
    }
}

#[derive(Debug, Default)]
pub struct ParseOutput {
    pub events: Vec<UsageEvent>,
    pub warnings: Vec<Warning>,
    pub rows_seen: u64,
}

/// Parse one rollout file.
/// The working directory a rollout was recorded in, from its `session_meta`.
///
/// The live session meter needs to know which rollout belongs to a folder, and
/// the rollout says so itself on its first records. Reads the head of the file
/// only: a long rollout is megabytes and the answer is in the first few lines.
pub fn session_cwd(contents: &str) -> Option<String> {
    for line in contents.lines().take(20) {
        let Ok(row) = serde_json::from_str::<Row>(line) else {
            continue;
        };
        if let Some(cwd) = row.payload.and_then(|p| p.cwd)
            && !cwd.is_empty()
        {
            return Some(cwd.to_string());
        }
    }
    None
}

/// Id of the one cumulative row this parser falls back to when the per-request
/// deltas disagree with the vendor's own total.
///
/// A reader has to be able to recognize that row: its counters are the whole
/// session, so anything that treats a row as one turn (a live context bar, for
/// instance) has to leave it alone. Deriving the id in one place is what keeps
/// the two sides from drifting apart.
pub fn rollup_event_id(session: &str) -> EventId {
    EventId::derive(&["codex", session, "total"])
}

pub fn parse_file(path: &Path, contents: &str) -> ParseOutput {
    let mut out = ParseOutput::default();

    let mut session = String::new();
    let mut project = String::from("unknown");
    let mut model = String::from("unknown");
    let mut provider = None;
    let mut billing = BillingMode::Unknown;
    let mut ordinal: u32 = 0;

    let mut summed_deltas = Delta(Counters::default());
    let mut final_total: Option<Cumulative> = None;
    let mut previous_total: Option<Usage> = None;
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
                if let Some(id) = payload.id
                    && session != id
                {
                    session = id.to_string();
                    first_index = out.events.len();
                    provider = None;
                }
                if payload.model_provider.is_some() {
                    provider = payload.model_provider;
                }
                if let Some(cwd) = payload.cwd {
                    project = cwd
                        .rsplit(['/', '\\'])
                        .find(|s| !s.is_empty())
                        .unwrap_or("unknown")
                        .to_string();
                }
            }
            Some("turn_context") => {
                if let Some(m) = payload.model {
                    model = match payload.model_provider.or(provider) {
                        Some(provider @ ("ollama" | "lmstudio")) => format!("{provider}/{m}"),
                        _ => m.to_owned(),
                    };
                }
            }
            _ => {}
        }

        if payload.kind != Some("token_count") {
            continue;
        }
        let Some(info) = payload.info else { continue };

        if let Some(rl) = &payload.rate_limits
            && rl.plan_type.is_some()
        {
            billing = BillingMode::Plan;
        }

        if let Some(total) = info.total_token_usage {
            // Rate-limit updates can repeat the previous request's nonzero
            // last_token_usage. An unchanged cumulative total is no new work,
            // including when a turn_context has switched models in between.
            if previous_total == Some(total) {
                continue;
            }
            previous_total = Some(total);
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
            profile_id: None,
            id: EventId::derive(&["codex", &session, &ordinal.to_string()]),
            source: SourceId::Codex,
            ts,
            model: model.clone(),
            session: session.clone(),
            project: project.clone(),
            counters,
            extras: Extras {
                reasoning_within_output: last.reasoning(),
                web_search_requests: None,
                web_fetch_requests: None,
            },
            billing,
            confidence: Confidence::Derived,
        });
        ordinal += 1;
    }

    if let Some(Cumulative(total)) = final_total {
        let summed = summed_deltas.0;
        if summed.total() != total.total() && total.total() > 0 {
            out.warnings.push(Warning::DeltaMismatch {
                path: path.to_path_buf(),
                summed: summed.total(),
                reported: total.total(),
            });
            out.events.truncate(first_index);
            out.events.push(UsageEvent {
                profile_id: None,
                id: rollup_event_id(&session),
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

    #[test]
    fn discovers_private_chats_even_without_an_ordinary_codex_home() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path();
        let first = data.join("chat/first/codex-hook/sessions");
        let second = data.join("chat/second/codex-hook/sessions");
        for path in [
            &first,
            &second,
            &data.join("chat/empty"),
            &data.join("other/codex-hook/sessions"),
        ] {
            std::fs::create_dir_all(path).unwrap();
        }
        assert_eq!(
            session_dirs(None, Some(data)),
            vec![
                std::fs::canonicalize(&first).unwrap(),
                std::fs::canonicalize(&second).unwrap()
            ]
        );
        assert_eq!(
            session_dirs(Some(first.clone()), Some(data)),
            vec![
                std::fs::canonicalize(first).unwrap(),
                std::fs::canonicalize(second).unwrap()
            ]
        );
        assert!(session_dirs(None, Some(&data.join("missing"))).is_empty());
    }

    #[test]
    fn ordinary_and_private_homes_are_both_discovered() {
        let dir = tempfile::tempdir().unwrap();
        let primary = dir.path().join("custom/sessions");
        let private = dir.path().join("data/chat/one/codex-hook/sessions");
        std::fs::create_dir_all(&primary).unwrap();
        std::fs::create_dir_all(&private).unwrap();
        assert_eq!(
            session_dirs(Some(primary.clone()), Some(&dir.path().join("data"))),
            vec![
                std::fs::canonicalize(primary).unwrap(),
                std::fs::canonicalize(private).unwrap()
            ]
        );
    }

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
        assert_eq!(c.input_fresh, Some(12454 - 4992));
        assert_eq!(c.cache_read, Some(4992));
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
        let input = format!(
            "{META}\n{CTX}\n{}\n{}\n",
            tc(12454, 4992, 277, 12454, 4992, 277),
            tc(12939, 12160, 30, 25393, 17152, 307)
        );
        let out = parse_file(&p(), &input);
        assert_eq!(out.events.len(), 2);
        assert!(out.warnings.is_empty());
        let total: u64 = out.events.iter().map(|e| e.counters.total()).sum();
        assert_eq!(total, 25393 + 307);
    }

    #[test]
    fn a_delta_that_disagrees_with_the_total_falls_back_to_the_total() {
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
    fn a_local_provider_remains_distinct_from_the_same_cloud_model() {
        let session = META.replace("\"cwd\":", "\"model_provider\":\"ollama\",\"cwd\":");
        let cloud = CTX.replace("\"model\":", "\"model_provider\":\"openai\",\"model\":");
        let input = format!(
            "{session}\n{CTX}\n{}\n{cloud}\n{}\n",
            tc(10, 0, 5, 10, 0, 5),
            tc(10, 0, 5, 20, 0, 10)
        );
        let out = parse_file(&p(), &input);
        assert_eq!(out.events[0].model, "ollama/gpt-5.5");
        assert_eq!(out.events[1].model, "gpt-5.5");
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
    fn repeated_usage_across_model_switches_preserves_each_models_turns() {
        let astra = CTX.replace("gpt-5.5", "gpt-6-astra");
        let sol = CTX.replace("gpt-5.5", "gpt-5.6-sol");
        let input = format!(
            "{META}\n{astra}\n{}\n{sol}\n{}\n{}\n{astra}\n{}\n{}\n",
            tc(10, 2, 5, 10, 2, 5),
            tc(10, 2, 5, 10, 2, 5),
            tc(20, 4, 6, 30, 6, 11),
            tc(20, 4, 6, 30, 6, 11),
            tc(30, 6, 7, 60, 12, 18),
        );
        let out = parse_file(&p(), &input);
        assert!(out.warnings.is_empty());
        assert_eq!(out.events.len(), 3);
        assert_eq!(out.events[0].model, "gpt-6-astra");
        assert_eq!(out.events[1].model, "gpt-5.6-sol");
        assert_eq!(out.events[2].model, "gpt-6-astra");
        assert_eq!(
            out.events.iter().map(|e| e.counters.total()).sum::<u64>(),
            78
        );
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

    #[test]
    fn reasoning_is_clamped_to_the_output_it_is_inside() {
        let line = r#"{"type":"event_msg","timestamp":"2026-07-01T18:28:30.711Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":99},"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":99}}}}"#;
        let input = format!("{META}\n{CTX}\n{line}\n");
        let e = &parse_file(&p(), &input).events[0];
        assert_eq!(e.counters.output, Some(5));
        assert_eq!(e.extras.reasoning_within_output, Some(5));
    }

    #[test]
    fn a_restated_session_header_does_not_narrow_the_fallback() {
        let input = format!(
            "{META}\n{CTX}\n{}\n{META}\n{}\n",
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
}
