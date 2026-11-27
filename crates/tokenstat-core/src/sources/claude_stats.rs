// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
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
use crate::store::ArchiveDayTotals;

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
    /// for like requires excluding cache here too. Saturating: the figures
    /// come from a JSON file and a wrap here would flip a bound.
    pub fn in_out(&self) -> u64 {
        self.input.saturating_add(self.output)
    }

    /// Every billable token, cache included. Not the vendor's headline figure,
    /// but the basis its per-day `dailyModelTokens` numbers are stated on.
    pub fn total(&self) -> u64 {
        self.input
            .saturating_add(self.output)
            .saturating_add(self.cache_read)
            .saturating_add(self.cache_creation)
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
        self.by_model
            .values()
            .fold(0u64, |acc, m| acc.saturating_add(m.in_out()))
    }
}

/// Which measurement the per-day `dailyModelTokens` figures are stated on.
///
/// The rollup mixes two bases in one file: lifetime `modelUsage` breaks tokens
/// into four buckets and its headline excludes cache, while `dailyModelTokens`
/// (added in `dailyModelTokensVersion` 5) states a single number per model per
/// day that includes cache. Reading the second as if it were the first turns a
/// day that was 97% cache reads into a day of generated tokens, and generated
/// tokens are priced up to 50x a cache read.
///
/// So the basis is measured rather than assumed, and it is measurable: the
/// retained days are a subset of lifetime, so their sum cannot exceed the
/// lifetime figure on the same basis. A daily sum above lifetime input plus
/// output is therefore proof the daily numbers count something else, and the
/// only other thing in the file is cache. If a future version changes the
/// field back, this notices instead of repricing every recovered day.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DailyBasis {
    /// One number per day covering every bucket, cache included.
    Total,
    /// Input plus output only, matching the lifetime headline.
    InputOutput,
}

pub fn detect_basis(stats: &StatsCache, daily: &[(String, BTreeMap<String, u64>)]) -> DailyBasis {
    let daily_sum: u64 = daily
        .iter()
        .flat_map(|(_, by_model)| by_model.values())
        .fold(0u64, |acc, v| acc.saturating_add(*v));
    if daily_sum > stats.in_out_total() {
        DailyBasis::Total
    } else {
        DailyBasis::InputOutput
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
/// attribution.
///
/// `have` maps `(date, model)` to what the transcripts already account for, and
/// a day and model the archive has anything at all for is left alone.
///
/// This used to top up the difference instead, which sounds strictly better and
/// is not. The two sides are not the same measurement, and the evidence for that
/// is that the archive is sometimes *ahead* of the vendor for a day. Once that
/// is true, keeping only the differences that point one way turns disagreement
/// into spend: on one real install the top-up invented 4.74 billion tokens of
/// "missing" usage across days whose transcripts were still on disk, while
/// genuinely lost days accounted for 283 million. Recovery is for history that
/// is gone, and "gone" is something the archive can answer honestly.
///
/// The cost is that a day which lost only some of its transcripts is recovered
/// as far as the archive got and no further. That errs toward reporting less
/// than happened, which is the right direction for a number nobody can check.
///
/// The daily figure is one number per model, so recovering a day means splitting
/// it into buckets, and that depends on which basis the vendor stated it on.
/// [`detect_basis`] decides. The split uses that model's own lifetime
/// proportions, which is an estimate, so these events are recorded at
/// [`Confidence::Derived`] and under a distinct source.
///
/// A model with no lifetime totals to split by recovers nothing. There is no
/// safe guess: on the total basis a day is overwhelmingly cache, so assuming
/// output would invent spend, and assuming cache would invent a discount. A day
/// left unrecovered is already what happens without this file at all.
pub fn backfill_events(
    stats: &StatsCache,
    daily: &[(String, BTreeMap<String, u64>)],
    have: &BTreeMap<(String, String), ArchiveDayTotals>,
    tz: &jiff::tz::TimeZone,
) -> Recovery {
    let basis = detect_basis(stats, daily);
    let mut out = Vec::new();
    for (date, by_model) in daily {
        for (model, vendor_tokens) in by_model {
            let archive = have
                .get(&(date.clone(), model.clone()))
                .copied()
                .unwrap_or_default();
            let already = match basis {
                DailyBasis::Total => archive.total,
                DailyBasis::InputOutput => archive.in_out,
            };
            if already > 0 {
                continue;
            }
            let tokens = *vendor_tokens;
            if tokens == 0 {
                continue;
            }
            let Some(m) = stats.by_model.get(model) else {
                continue;
            };
            let denom = match basis {
                DailyBasis::Total => m.total(),
                DailyBasis::InputOutput => m.in_out(),
            };
            if denom == 0 {
                continue;
            }
            let share = |part: u64| {
                ((u128::from(tokens) * u128::from(part) + u128::from(denom / 2))
                    / u128::from(denom))
                .min(u128::from(tokens)) as u64
            };
            let input = share(m.input);
            let (cache_read, cache_write) = match basis {
                DailyBasis::Total => {
                    let read = share(m.cache_read).min(tokens - input);
                    let write = share(m.cache_creation).min(tokens - input - read);
                    (read, write)
                }
                DailyBasis::InputOutput => (0, 0),
            };
            let counted = input.saturating_add(cache_read).saturating_add(cache_write);
            let output = tokens.saturating_sub(counted);

            let Some(ts) = date
                .parse::<jiff::civil::Date>()
                .ok()
                .and_then(|d| d.at(12, 0, 0, 0).to_zoned_datetime(tz.clone()).ok())
                .map(|z| z.timestamp().as_millisecond())
            else {
                continue;
            };

            let counters = match basis {
                DailyBasis::Total => Counters {
                    input_fresh: Some(input),
                    output: Some(output),
                    cache_read: Some(cache_read),
                    cache_write_5m: Some(cache_write),
                    cache_write_1h: Some(0),
                },
                DailyBasis::InputOutput => Counters {
                    input_fresh: Some(input),
                    output: Some(output),
                    cache_read: None,
                    cache_write_5m: None,
                    cache_write_1h: None,
                },
            };

            out.push(UsageEvent {
                profile_id: None,
                id: EventId::derive(&["claude_rollup", date, model]),
                source: SourceId::ClaudeCodeRollup,
                ts: Timestamp::from_ms(ts),
                model: model.clone(),
                session: String::new(),
                project: "(recovered)".to_string(),
                counters,
                extras: Extras::default(),
                billing: BillingMode::Plan,
                confidence: Confidence::Derived,
            });
        }
    }
    keep_plausible(stats, out)
}

/// What a recovery pass produced, and anything it refused to produce.
#[derive(Debug, Default)]
pub struct Recovery {
    pub events: Vec<UsageEvent>,
    pub warnings: Vec<crate::error::Warning>,
}

fn keep_plausible(stats: &StatsCache, events: Vec<UsageEvent>) -> Recovery {
    let mut derived: BTreeMap<String, (u64, u64, u64)> = BTreeMap::new();
    for e in &events {
        let slot = derived.entry(e.model.clone()).or_default();
        slot.0 = slot.0.saturating_add(e.counters.output.unwrap_or(0));
        slot.1 = slot.1.saturating_add(e.counters.cache_read.unwrap_or(0));
        slot.2 = slot.2.saturating_add(e.counters.input_fresh.unwrap_or(0));
    }
    let mut refused: Vec<String> = Vec::new();
    let mut warnings = Vec::new();
    for (model, (out, cr, inn)) in &derived {
        let Some(lifetime) = stats.by_model.get(model) else {
            continue;
        };
        for (bucket, got, cap) in [
            ("output", *out, lifetime.output),
            ("cache read", *cr, lifetime.cache_read),
            ("input", *inn, lifetime.input),
        ] {
            if got > cap {
                refused.push(model.clone());
                warnings.push(crate::error::Warning::RecoveryImplausible {
                    source: "claude_code_rollup",
                    model: model.clone(),
                    bucket,
                    derived: got,
                    lifetime: cap,
                });
                break;
            }
        }
    }
    if refused.is_empty() {
        return Recovery {
            events,
            warnings: Vec::new(),
        };
    }
    Recovery {
        events: events
            .into_iter()
            .filter(|e| !refused.contains(&e.model))
            .collect(),
        warnings,
    }
}

/// Per-day, per-model token totals from the rollup.
/// The vendor's own version for the `dailyModelTokens` block.
///
/// Not trusted to mean anything in particular, and deliberately not matched
/// against a known list: the units are measured by [`detect_basis`] and the
/// result is bounded by [`keep_plausible`], both of which work on a version
/// nobody here has seen. It is read so a bump can force an archive to rebuild
/// its recovered rows, because those rows are derived and a file that starts
/// saying something new makes every one of them stale.
pub fn daily_tokens_version(contents: &str) -> Option<u64> {
    #[derive(Deserialize)]
    struct Root {
        #[serde(rename = "dailyModelTokensVersion")]
        version: Option<u64>,
    }
    serde_json::from_str::<Root>(contents)
        .ok()
        .and_then(|r| r.version)
}

/// Per-day activity: how much work happened, with no token counts.
///
/// Claude Code keeps this for roughly twice as long as it keeps per-day token
/// counts, which is why a day can be provably worked and have no measurable
/// usage anywhere on the machine. Reported as activity rather than guessed at.
pub fn daily_activity(contents: &str) -> Vec<DayActivity> {
    #[derive(Deserialize)]
    struct Day {
        date: String,
        #[serde(rename = "messageCount")]
        messages: Option<u64>,
        #[serde(rename = "sessionCount")]
        sessions: Option<u64>,
    }
    #[derive(Deserialize)]
    struct Root {
        #[serde(rename = "dailyActivity")]
        activity: Option<Vec<Day>>,
    }
    serde_json::from_str::<Root>(contents)
        .ok()
        .and_then(|r| r.activity)
        .unwrap_or_default()
        .into_iter()
        .map(|d| DayActivity {
            date: d.date,
            messages: d.messages.unwrap_or(0),
            sessions: d.sessions.unwrap_or(0),
        })
        .collect()
}

/// One day of vendor-reported activity, with no token counts attached.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DayActivity {
    pub date: String,
    pub messages: u64,
    pub sessions: u64,
}

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

    const CACHE_HEAVY: &str = r#"{
      "lastComputedDate": "2026-08-11",
      "modelUsage": {
        "claude-opus-5": {
          "inputTokens": 143374, "outputTokens": 16603920,
          "cacheReadInputTokens": 5164247659, "cacheCreationInputTokens": 81938162
        }
      }
    }"#;

    fn day(date: &str, model: &str, tokens: u64) -> (String, BTreeMap<String, u64>) {
        (
            date.to_string(),
            BTreeMap::from([(model.to_string(), tokens)]),
        )
    }

    fn have(
        date: &str,
        model: &str,
        t: ArchiveDayTotals,
    ) -> BTreeMap<(String, String), ArchiveDayTotals> {
        BTreeMap::from([((date.to_string(), model.to_string()), t)])
    }

    #[test]
    fn parses_the_vendor_rollup() {
        let s = parse(SAMPLE).unwrap();
        assert_eq!(s.total_sessions, 1495);
        assert_eq!(s.total_messages, 155767);
        let opus = &s.by_model["claude-opus-4-8"];
        assert_eq!(opus.input, 4_018_543);
        assert_eq!(opus.output, 40_327_792);
        assert_eq!(opus.in_out(), 44_346_335);
        assert_eq!(opus.total(), 44_346_485);
    }

    #[test]
    fn in_out_excludes_cache_to_match_the_vendor_definition() {
        let s = parse(SAMPLE).unwrap();
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
    fn a_daily_sum_above_lifetime_in_out_can_only_be_a_total() {
        let stats = parse(CACHE_HEAVY).unwrap();
        let daily = vec![day("2026-08-11", "claude-opus-5", 576_031_559)];
        assert_eq!(detect_basis(&stats, &daily), DailyBasis::Total);
    }

    #[test]
    fn a_daily_sum_within_lifetime_in_out_is_read_as_in_out() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![day("2026-06-20", "claude-opus-4-8", 1_000)];
        assert_eq!(detect_basis(&stats, &daily), DailyBasis::InputOutput);
    }

    #[test]
    fn backfill_skips_days_the_transcripts_already_cover() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![
            day("2026-06-20", "claude-opus-4-8", 1000),
            day("2026-06-21", "claude-opus-4-8", 2000),
        ];
        let seen = have(
            "2026-06-21",
            "claude-opus-4-8",
            ArchiveDayTotals {
                in_out: 2000,
                total: 900_000,
            },
        );
        let tz = jiff::tz::TimeZone::UTC;
        let ev = backfill_events(&stats, &daily, &seen, &tz).events;
        assert_eq!(ev.len(), 1);
        assert_eq!(ev[0].source, SourceId::ClaudeCodeRollup);
        assert_eq!(ev[0].confidence, Confidence::Derived);
        assert_eq!(
            ev[0].counters.input_fresh.unwrap() + ev[0].counters.output.unwrap(),
            1000
        );
        assert_eq!(ev[0].counters.cache_read, None);
        assert!(ev[0].counters.has_unknown());
    }

    #[test]
    fn backfill_is_idempotent() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![day("2026-06-20", "claude-opus-4-8", 1000)];
        let none = BTreeMap::new();
        let tz = jiff::tz::TimeZone::UTC;
        let a = backfill_events(&stats, &daily, &none, &tz).events;
        let b = backfill_events(&stats, &daily, &none, &tz).events;
        assert_eq!(a[0].id, b[0].id);
    }

    #[test]
    fn rounded_shares_never_exceed_the_reported_day_total() {
        let stats = parse(r#"{"modelUsage":{"m":{"inputTokens":1,"cacheReadInputTokens":1,"cacheCreationInputTokens":1}}}"#).unwrap();
        let recovery = backfill_events(
            &stats,
            &[day("2026-06-20", "m", 2)],
            &BTreeMap::new(),
            &jiff::tz::TimeZone::UTC,
        );
        assert_eq!(recovery.events.len(), 1);
        assert_eq!(recovery.events[0].counters.total(), 2);
    }

    #[test]
    fn invalid_dates_do_not_create_epoch_usage() {
        let stats = parse(SAMPLE).unwrap();
        let recovery = backfill_events(
            &stats,
            &[day("invalid", "claude-opus-4-8", 1000)],
            &BTreeMap::new(),
            &jiff::tz::TimeZone::UTC,
        );
        assert!(recovery.events.is_empty());
    }

    #[test]
    fn backfill_splits_using_the_model_ratio() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![day("2026-06-20", "claude-opus-4-8", 44_346_335)];
        let tz = jiff::tz::TimeZone::UTC;
        let ev = backfill_events(&stats, &daily, &BTreeMap::new(), &tz).events;
        assert_eq!(ev[0].counters.input_fresh.unwrap(), 4_018_543);
        assert_eq!(ev[0].counters.output.unwrap(), 40_327_792);
    }

    #[test]
    fn a_model_with_no_lifetime_totals_recovers_nothing() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![day("2026-06-20", "brand-new-model", 500)];
        let tz = jiff::tz::TimeZone::UTC;
        assert!(
            backfill_events(&stats, &daily, &BTreeMap::new(), &tz)
                .events
                .is_empty()
        );
    }

    #[test]
    fn a_day_the_archive_has_anything_for_is_left_alone() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![day("2026-06-20", "claude-opus-4-8", 1000)];
        let seen = have(
            "2026-06-20",
            "claude-opus-4-8",
            ArchiveDayTotals {
                in_out: 400,
                total: 400,
            },
        );
        let tz = jiff::tz::TimeZone::UTC;
        assert!(
            backfill_events(&stats, &daily, &seen, &tz)
                .events
                .is_empty()
        );
    }

    #[test]
    fn a_day_the_archive_lost_entirely_is_recovered_in_full() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![day("2026-06-20", "claude-opus-4-8", 1000)];
        let tz = jiff::tz::TimeZone::UTC;
        let ev = backfill_events(&stats, &daily, &BTreeMap::new(), &tz).events;
        assert_eq!(ev.len(), 1);
        assert_eq!(ev[0].counters.total(), 1000);
    }

    #[test]
    fn an_archive_ahead_of_the_rollup_recovers_nothing() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![day("2026-06-20", "claude-opus-4-8", 100)];
        let seen = have(
            "2026-06-20",
            "claude-opus-4-8",
            ArchiveDayTotals {
                in_out: 999,
                total: 999,
            },
        );
        let tz = jiff::tz::TimeZone::UTC;
        assert!(
            backfill_events(&stats, &daily, &seen, &tz)
                .events
                .is_empty()
        );
    }

    #[test]
    fn a_cache_heavy_day_is_not_recovered_as_generated_tokens() {
        let stats = parse(CACHE_HEAVY).unwrap();
        let daily = vec![day("2026-08-11", "claude-opus-5", 576_031_559)];
        let tz = jiff::tz::TimeZone::UTC;
        let ev = backfill_events(&stats, &daily, &BTreeMap::new(), &tz).events;
        assert_eq!(ev.len(), 1);
        let c = &ev[0].counters;
        assert_eq!(c.total(), 576_031_559);
        assert!(c.cache_read.unwrap() > 560_000_000, "{c:?}");
        assert!(c.output.unwrap() < 2_500_000, "{c:?}");
        assert!(c.output.unwrap() * 200 < c.cache_read.unwrap(), "{c:?}");
        assert!(!c.has_unknown());
    }

    #[test]
    fn a_total_basis_day_subtracts_the_archive_on_the_same_basis() {
        let stats = parse(CACHE_HEAVY).unwrap();
        let daily = vec![day("2026-08-11", "claude-opus-5", 576_031_559)];
        let seen = have(
            "2026-08-11",
            "claude-opus-5",
            ArchiveDayTotals {
                in_out: 1_000_000,
                total: 576_031_559,
            },
        );
        let tz = jiff::tz::TimeZone::UTC;
        assert!(
            backfill_events(&stats, &daily, &seen, &tz)
                .events
                .is_empty()
        );
    }

    #[test]
    fn a_reading_that_beats_the_vendors_own_lifetime_total_is_refused() {
        let stats = parse(CACHE_HEAVY).unwrap();
        let daily = vec![day("2026-08-11", "claude-opus-5", 900_000_000_000)];
        let tz = jiff::tz::TimeZone::UTC;
        let recovered = backfill_events(&stats, &daily, &BTreeMap::new(), &tz);
        assert!(recovered.events.is_empty(), "{:?}", recovered.events);
        assert_eq!(recovered.warnings.len(), 1);
        assert!(
            format!("{}", recovered.warnings[0]).contains("claude-opus-5"),
            "{}",
            recovered.warnings[0]
        );
    }

    #[test]
    fn one_model_changing_shape_does_not_lose_the_others() {
        let stats = parse(SAMPLE).unwrap();
        let daily = vec![
            day("2026-06-20", "claude-opus-4-8", 1000),
            day("2026-06-21", "claude-fable-5", 900_000_000_000),
        ];
        let tz = jiff::tz::TimeZone::UTC;
        let recovered = backfill_events(&stats, &daily, &BTreeMap::new(), &tz);
        assert_eq!(recovered.events.len(), 1);
        assert_eq!(recovered.events[0].model, "claude-opus-4-8");
        assert_eq!(recovered.warnings.len(), 1);
    }

    #[test]
    fn the_vendors_own_format_version_is_read_when_present() {
        assert_eq!(
            daily_tokens_version(r#"{"dailyModelTokensVersion":5}"#),
            Some(5)
        );
        assert_eq!(daily_tokens_version(r#"{}"#), None);
        assert_eq!(daily_tokens_version("not json"), None);
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
