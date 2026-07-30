//! Reader for Claude Code's own rollup, `~/.claude/stats-cache.json`.
//!
//! This is not an event source and is never ingested as usage. It is a
//! reconciliation reference, used to answer one question honestly: does the
//! archive agree with what the tool itself reports?
//!
//! It matters because the two diverge for a real reason. Claude Code prunes
//! transcripts after `cleanupPeriodDays` (30 by default) but keeps accumulating
//! this rollup, so any tool parsing only the transcripts undercounts against
//! the figures a user sees in `/usage`. Measured on one real install, 63% of
//! lifetime tokens were no longer recoverable from the transcripts.
//!
//! Reporting that gap beats silently presenting a smaller number as the truth,
//! and it is the argument for running a scan before the cleanup window passes.

use std::collections::BTreeMap;
use std::path::Path;

use serde::Deserialize;

use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Per-model totals as the vendor rollup states them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ModelTotals {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_creation: u64,
}

impl ModelTotals {
    /// Input plus output, excluding cache. This is the definition Claude Code
    /// uses for the headline figure in its own usage view, so comparing like
    /// for like requires excluding cache here too.
    pub fn in_out(&self) -> u64 {
        self.input + self.output
    }
}

/// The parts of the rollup worth reading.
#[derive(Debug, Clone, Default)]
pub struct StatsCache {
    pub first_session_date: Option<String>,
    pub last_computed_date: Option<String>,
    pub total_sessions: u64,
    pub total_messages: u64,
    pub by_model: BTreeMap<String, ModelTotals>,
}

impl StatsCache {
    pub fn in_out_total(&self) -> u64 {
        self.by_model.values().map(|m| m.in_out()).sum()
    }
}

#[derive(Deserialize)]
struct Raw {
    #[serde(rename = "firstSessionDate")]
    first_session_date: Option<String>,
    #[serde(rename = "lastComputedDate")]
    last_computed_date: Option<String>,
    #[serde(rename = "totalSessions")]
    total_sessions: Option<u64>,
    #[serde(rename = "totalMessages")]
    total_messages: Option<u64>,
    #[serde(rename = "modelUsage")]
    model_usage: Option<BTreeMap<String, RawModel>>,
}

#[derive(Deserialize)]
struct RawModel {
    #[serde(rename = "inputTokens")]
    input_tokens: Option<u64>,
    #[serde(rename = "outputTokens")]
    output_tokens: Option<u64>,
    #[serde(rename = "cacheReadInputTokens")]
    cache_read_input_tokens: Option<u64>,
    #[serde(rename = "cacheCreationInputTokens")]
    cache_creation_input_tokens: Option<u64>,
}

/// Locate the rollup next to the projects directory.
pub fn path_for(projects_dir: &Path) -> Option<std::path::PathBuf> {
    let p = projects_dir.parent()?.join("stats-cache.json");
    p.is_file().then_some(p)
}

/// Parse the rollup. A malformed or unfamiliar file yields `None` rather than
/// an error, since this is a cross-check and its absence is not a failure.
pub fn parse(contents: &str) -> Option<StatsCache> {
    let raw: Raw = serde_json::from_str(contents).ok()?;
    let by_model = raw
        .model_usage
        .unwrap_or_default()
        .into_iter()
        .map(|(k, v)| {
            (
                k,
                ModelTotals {
                    input: v.input_tokens.unwrap_or(0),
                    output: v.output_tokens.unwrap_or(0),
                    cache_read: v.cache_read_input_tokens.unwrap_or(0),
                    cache_creation: v.cache_creation_input_tokens.unwrap_or(0),
                },
            )
        })
        .collect();
    Some(StatsCache {
        first_session_date: raw.first_session_date,
        last_computed_date: raw.last_computed_date,
        total_sessions: raw.total_sessions.unwrap_or(0),
        total_messages: raw.total_messages.unwrap_or(0),
        by_model,
    })
}

/// Build events for days the transcripts no longer cover.
///
/// The rollup outlives the transcripts, so it is the only way to recover history
/// past the cleanup window on a machine where tokenstat was installed late. It
/// is coarse: one event per day and model, with no session or project
/// attribution and no cache figures.
///
/// `have` maps `(date, model)` to the input plus output the transcripts already
/// account for. Only the shortfall is recovered, so a day whose transcripts
/// survive in full contributes nothing here and a partially pruned day is topped
/// up to the figure the vendor itself reports.
///
/// Pruning is not all or nothing. A day can keep some of its transcripts and
/// lose others, so an all-or-nothing rule per day leaves most of the gap open.
///
/// The daily figure is input plus output combined. Splitting it uses that
/// model's lifetime input to output ratio, which is an estimate, so these events
/// are recorded at [`Confidence::Derived`] and under a distinct source.
pub fn backfill_events(
    stats: &StatsCache,
    daily: &[(String, BTreeMap<String, u64>)],
    have: &BTreeMap<(String, String), u64>,
    tz: &jiff::tz::TimeZone,
) -> Vec<UsageEvent> {
    let mut out = Vec::new();
    for (date, by_model) in daily {
        for (model, vendor_tokens) in by_model {
            // Saturating: the archive can legitimately hold more than the
            // rollup, which is recomputed periodically and lags the current day.
            let already = have
                .get(&(date.clone(), model.clone()))
                .copied()
                .unwrap_or(0);
            let tokens = &vendor_tokens.saturating_sub(already);
            if *tokens == 0 {
                continue;
            }
            // Ratio from the model's own lifetime totals. Falling back to
            // all-output is deliberate: generated tokens dominate every model
            // observed, so it errs toward the larger, more expensive bucket
            // rather than flattering the number.
            let (input, output) = match stats.by_model.get(model) {
                Some(m) if m.in_out() > 0 => {
                    let in_share = m.input as f64 / m.in_out() as f64;
                    let i = (*tokens as f64 * in_share).round() as u64;
                    (i, tokens.saturating_sub(i))
                }
                _ => (0, *tokens),
            };

            // Midday local time, so the event cannot drift across a date
            // boundary when bucketed back into the same zone.
            let ts = date
                .parse::<jiff::civil::Date>()
                .ok()
                .and_then(|d| d.at(12, 0, 0, 0).to_zoned(tz.clone()).ok())
                .map(|z| z.timestamp().as_millisecond())
                .unwrap_or(0);

            out.push(UsageEvent {
                id: EventId::derive(&["claude_rollup", date, model]),
                source: SourceId::ClaudeCodeRollup,
                ts: Timestamp::from_ms(ts),
                model: model.clone(),
                session: String::new(),
                project: "(recovered)".to_string(),
                counters: Counters {
                    input_fresh: Some(input),
                    output: Some(output),
                    // The rollup does not break these down per day, and
                    // reporting zero would understate cache activity that
                    // certainly happened.
                    cache_read: None,
                    cache_write_5m: None,
                    cache_write_1h: None,
                },
                extras: Extras::default(),
                billing: BillingMode::Plan,
                confidence: Confidence::Derived,
            });
        }
    }
    out
}

/// Per-day, per-model token totals from the rollup.
pub fn daily_model_tokens(contents: &str) -> Vec<(String, BTreeMap<String, u64>)> {
    #[derive(Deserialize)]
    struct Day {
        date: String,
        #[serde(rename = "tokensByModel")]
        tokens_by_model: Option<BTreeMap<String, u64>>,
    }
    #[derive(Deserialize)]
    struct Root {
        #[serde(rename = "dailyModelTokens")]
        daily: Option<Vec<Day>>,
    }
    serde_json::from_str::<Root>(contents)
        .ok()
        .and_then(|r| r.daily)
        .unwrap_or_default()
        .into_iter()
        .map(|d| (d.date, d.tokens_by_model.unwrap_or_default()))
        .collect()
}

/// Difference between what the vendor reports and what the archive holds.
#[derive(Debug, Clone)]
pub struct Reconciliation {
    /// Input plus output according to the vendor rollup.
    pub vendor_in_out: u64,
    /// Input plus output according to the archive.
    pub archive_in_out: u64,
    pub vendor_sessions: u64,
    pub archive_sessions: u64,
    pub vendor_first_date: Option<String>,
    pub archive_first_date: Option<String>,
    /// When the vendor last recomputed its rollup. The archive legitimately
    /// runs ahead of this, because transcripts are current.
    pub vendor_last_computed: Option<String>,
}

impl Reconciliation {
    /// Tokens the archive holds beyond the rollup, normally the days since the
    /// rollup was last recomputed.
    pub fn ahead(&self) -> u64 {
        self.archive_in_out.saturating_sub(self.vendor_in_out)
    }
}

impl Reconciliation {
    /// Tokens the vendor counted that the archive cannot see, usually because
    /// the transcripts holding them were deleted before the first scan.
    pub fn missing(&self) -> u64 {
        self.vendor_in_out.saturating_sub(self.archive_in_out)
    }

    /// Share of vendor-reported usage the archive is missing.
    pub fn missing_ratio(&self) -> f64 {
        if self.vendor_in_out == 0 {
            return 0.0;
        }
        self.missing() as f64 / self.vendor_in_out as f64
    }

    /// True when the archive holds materially less than the tool reports.
    pub fn is_significant(&self) -> bool {
        self.missing_ratio() > 0.02
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"{
      "firstSessionDate": "2026-06-19T14:01:18.237Z",
      "lastComputedDate": "2026-07-26",
      "totalSessions": 1495,
      "totalMessages": 155767,
      "modelUsage": {
        "claude-opus-4-8": {
          "inputTokens": 4018543, "outputTokens": 40327792,
          "cacheReadInputTokens": 100, "cacheCreationInputTokens": 50
        },
        "claude-fable-5": { "inputTokens": 2127486, "outputTokens": 26218722 }
      }
    }"#;

    #[test]
    fn parses_the_vendor_rollup() {
        let s = parse(SAMPLE).unwrap();
        assert_eq!(s.total_sessions, 1495);
        assert_eq!(s.total_messages, 155767);
        let opus = &s.by_model["claude-opus-4-8"];
        assert_eq!(opus.input, 4_018_543);
        assert_eq!(opus.output, 40_327_792);
        assert_eq!(opus.in_out(), 44_346_335);
    }

    #[test]
    fn in_out_excludes_cache_to_match_the_vendor_definition() {
        let s = parse(SAMPLE).unwrap();
        // Cache tokens exist on the opus entry but must not inflate in_out,
        // because the figure being compared against excludes them.
        assert_eq!(s.in_out_total(), 44_346_335 + 28_346_208);
    }

    #[test]
    fn missing_fields_default_to_zero() {
        let s = parse(r#"{"modelUsage":{"m":{}}}"#).unwrap();
        assert_eq!(s.by_model["m"].in_out(), 0);
        assert_eq!(s.total_sessions, 0);
    }

    #[test]
    fn malformed_input_is_not_an_error() {
        assert!(parse("not json").is_none());
    }

    #[test]
    fn backfill_skips_days_the_transcripts_already_cover() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![
            (
                "2026-06-20".to_string(),
                BTreeMap::from([("claude-opus-4-8".to_string(), 1000u64)]),
            ),
            (
                "2026-06-21".to_string(),
                BTreeMap::from([("claude-opus-4-8".to_string(), 2000u64)]),
            ),
        ];
        // The 21st is fully accounted for by transcripts already.
        let have = BTreeMap::from([(
            ("2026-06-21".to_string(), "claude-opus-4-8".to_string()),
            2000u64,
        )]);
        let tz = jiff::tz::TimeZone::UTC;
        let ev = backfill_events(&stats, &daily, &have, &tz);
        assert_eq!(ev.len(), 1);
        assert_eq!(ev[0].source, SourceId::ClaudeCodeRollup);
        assert_eq!(ev[0].confidence, Confidence::Derived);
        // in + out must equal the day total exactly, whatever the split.
        assert_eq!(
            ev[0].counters.input_fresh.unwrap() + ev[0].counters.output.unwrap(),
            1000
        );
        // Cache is genuinely unknown here, not zero.
        assert_eq!(ev[0].counters.cache_read, None);
        assert!(ev[0].counters.has_unknown());
    }

    #[test]
    fn backfill_is_idempotent() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![(
            "2026-06-20".to_string(),
            BTreeMap::from([("claude-opus-4-8".to_string(), 1000u64)]),
        )];
        let none = BTreeMap::new();
        let tz = jiff::tz::TimeZone::UTC;
        let a = backfill_events(&stats, &daily, &none, &tz);
        let b = backfill_events(&stats, &daily, &none, &tz);
        assert_eq!(a[0].id, b[0].id);
    }

    #[test]
    fn backfill_splits_using_the_model_ratio() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![(
            "2026-06-20".to_string(),
            BTreeMap::from([("claude-opus-4-8".to_string(), 44_346_335u64)]),
        )];
        let tz = jiff::tz::TimeZone::UTC;
        let ev = backfill_events(&stats, &daily, &BTreeMap::new(), &tz);
        // Given the whole lifetime total for that model, the split should
        // reproduce its actual input and output almost exactly.
        assert_eq!(ev[0].counters.input_fresh.unwrap(), 4_018_543);
        assert_eq!(ev[0].counters.output.unwrap(), 40_327_792);
    }

    #[test]
    fn unknown_model_falls_back_to_output() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![(
            "2026-06-20".to_string(),
            BTreeMap::from([("brand-new-model".to_string(), 500u64)]),
        )];
        let tz = jiff::tz::TimeZone::UTC;
        let ev = backfill_events(&stats, &daily, &BTreeMap::new(), &tz);
        assert_eq!(ev[0].counters.output, Some(500));
        assert_eq!(ev[0].counters.input_fresh, Some(0));
    }

    #[test]
    fn partially_pruned_days_are_topped_up_not_skipped() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![(
            "2026-06-20".to_string(),
            BTreeMap::from([("claude-opus-4-8".to_string(), 1000u64)]),
        )];
        // Transcripts explain only 400 of the 1000 the vendor counted.
        let have = BTreeMap::from([(
            ("2026-06-20".to_string(), "claude-opus-4-8".to_string()),
            400u64,
        )]);
        let tz = jiff::tz::TimeZone::UTC;
        let ev = backfill_events(&stats, &daily, &have, &tz);
        assert_eq!(ev.len(), 1);
        assert_eq!(
            ev[0].counters.input_fresh.unwrap() + ev[0].counters.output.unwrap(),
            600
        );
    }

    #[test]
    fn an_archive_ahead_of_the_rollup_recovers_nothing() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![(
            "2026-06-20".to_string(),
            BTreeMap::from([("claude-opus-4-8".to_string(), 100u64)]),
        )];
        // Today's transcripts can exceed a rollup computed days ago.
        let have = BTreeMap::from([(
            ("2026-06-20".to_string(), "claude-opus-4-8".to_string()),
            999u64,
        )]);
        let tz = jiff::tz::TimeZone::UTC;
        assert!(backfill_events(&stats, &daily, &have, &tz).is_empty());
    }

    #[test]
    fn daily_model_tokens_parses() {
        let d = daily_model_tokens(
            r#"{"dailyModelTokens":[{"date":"2026-06-20","tokensByModel":{"m":5}}]}"#,
        );
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].0, "2026-06-20");
        assert_eq!(d[0].1["m"], 5);
    }

    #[test]
    fn reconciliation_reports_the_gap() {
        let r = Reconciliation {
            vendor_in_out: 89_636_563,
            archive_in_out: 33_522_676,
            vendor_sessions: 1495,
            archive_sessions: 902,
            vendor_first_date: None,
            archive_first_date: None,
            vendor_last_computed: None,
        };
        assert_eq!(r.missing(), 56_113_887);
        assert!((r.missing_ratio() - 0.626).abs() < 0.01);
        assert!(r.is_significant());
    }

    #[test]
    fn an_archive_ahead_of_the_rollup_reports_no_gap() {
        // The rollup is recomputed periodically, so the archive can legitimately
        // hold more. That must not underflow into a huge bogus number.
        let r = Reconciliation {
            vendor_in_out: 100,
            archive_in_out: 500,
            vendor_sessions: 1,
            archive_sessions: 2,
            vendor_first_date: None,
            archive_first_date: None,
            vendor_last_computed: None,
        };
        assert_eq!(r.missing(), 0);
        assert_eq!(r.ahead(), 400);
        assert!(!r.is_significant());
    }
}
