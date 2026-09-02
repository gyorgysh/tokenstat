//! The normalized schema every source is mapped onto.
//!
//! Two design rules carry most of the weight here, and both are enforced by the
//! type system rather than by review:
//!
//! 1. [`Counters`] fields are mutually exclusive, so summing them is always the
//!    total billable volume. Vendors disagree about whether cached tokens are a
//!    subset of the prompt total or a separate bucket, and normalizing onto
//!    disjoint categories is what makes their numbers comparable at all.
//! 2. A cumulative sample cannot be added to anything. Summing a running total
//!    is the single most common bug in this category of tool, so [`Cumulative`]
//!    simply does not implement [`std::ops::Add`].

use std::fmt;

use serde::{Deserialize, Serialize};

/// Which tool produced an event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceId {
    ClaudeCode,
    /// Claude Code's own aggregated rollup, used to recover history whose
    /// transcripts have already been deleted. Day and model granularity only.
    ClaudeCodeRollup,
    Codex,
    Grok,
    OpenCode,
    Cline,
    Cursor,
    Antigravity,
    OpenClaw,
    Zed,
    Copilot,
    /// Pi's CLI agent. JSONL sessions, one file per session under the folder
    /// it was run in.
    Pi,
    /// Hermes Agent. One SQLite state file, with usage already rolled up per
    /// session and model.
    Hermes,
    /// Kilo Code's CLI. An OpenCode fork, so the same database shape under its
    /// own name, and counted as its own tool because it is one.
    Kilo,
    /// DeepSeek Harness. Compressed JSONL sessions, one folder per session.
    Dsh,
    /// Muse. One JSONL event log per session, plus one per subagent, under a
    /// date-partitioned sessions root.
    Muse,
    /// Devin CLI. One SQLite database, counters on the assistant nodes of a
    /// message forest.
    Devin,
    /// Kimi Code. Per-request usage records in each agent's durable wire log.
    Kimi,
}

impl SourceId {
    /// Stable string used in the database and in `--json` output.
    pub fn as_str(self) -> &'static str {
        match self {
            SourceId::ClaudeCode => "claude_code",
            SourceId::ClaudeCodeRollup => "claude_code_rollup",
            SourceId::Codex => "codex",
            SourceId::Grok => "grok",
            SourceId::OpenCode => "opencode",
            SourceId::Cline => "cline",
            SourceId::Cursor => "cursor",
            SourceId::Antigravity => "antigravity",
            SourceId::OpenClaw => "openclaw",
            SourceId::Zed => "zed",
            SourceId::Copilot => "copilot",
            SourceId::Pi => "pi",
            SourceId::Hermes => "hermes",
            SourceId::Kilo => "kilo",
            SourceId::Dsh => "dsh",
            SourceId::Muse => "muse",
            SourceId::Devin => "devin",
            SourceId::Kimi => "kimi",
        }
    }

    /// Human facing name used in reports.
    pub fn display_name(self) -> &'static str {
        match self {
            SourceId::ClaudeCode => "Claude Code",
            SourceId::ClaudeCodeRollup => "Claude Code (recovered)",
            SourceId::Codex => "Codex",
            SourceId::Grok => "Grok",
            SourceId::OpenCode => "OpenCode",
            SourceId::Cline => "Cline",
            SourceId::Cursor => "Cursor",
            SourceId::Antigravity => "Antigravity",
            SourceId::OpenClaw => "OpenClaw",
            SourceId::Zed => "Zed",
            SourceId::Copilot => "Copilot CLI",
            SourceId::Pi => "Pi",
            SourceId::Hermes => "Hermes Agent",
            SourceId::Kilo => "Kilo Code",
            SourceId::Dsh => "DeepSeek Harness",
            SourceId::Muse => "Muse",
            SourceId::Devin => "Devin CLI",
            SourceId::Kimi => "Kimi Code",
        }
    }

    /// The tool a stored source id belongs to.
    ///
    /// Recovery used to be written as `claude_code_estimate` and is still
    /// written as `claude_code_rollup`. Those rows stay on disk under those
    /// names so they can be recomputed and deleted independently. Anything
    /// that names a tool folds them into Claude Code.
    pub fn tool_id(id: &str) -> &str {
        match id {
            "claude_code_estimate" | "claude_code_rollup" => "claude_code",
            other => other,
        }
    }

    /// Human name for a stored source id, including ids this enum does not
    /// carry.
    ///
    /// Recovery used to be written as `claude_code_estimate`. Those rows stay
    /// under that name on disk so [`crate::store::Store::clear_recovered`]
    /// cannot delete them. A breakdown still names them as Claude Code,
    /// recovered. A tool list folds them through [`Self::tool_id`].
    pub fn label(id: &str) -> &str {
        match id {
            "claude_code_estimate" => "Claude Code (recovered)",
            other => Self::from_archive(other)
                .map(Self::display_name)
                .unwrap_or(other),
        }
    }

    fn from_archive(id: &str) -> Option<Self> {
        match id {
            "claude_code" => Some(Self::ClaudeCode),
            "claude_code_rollup" => Some(Self::ClaudeCodeRollup),
            "codex" => Some(Self::Codex),
            "grok" => Some(Self::Grok),
            "opencode" => Some(Self::OpenCode),
            "cline" => Some(Self::Cline),
            "cursor" => Some(Self::Cursor),
            "antigravity" => Some(Self::Antigravity),
            "openclaw" => Some(Self::OpenClaw),
            "zed" => Some(Self::Zed),
            "copilot" => Some(Self::Copilot),
            "pi" => Some(Self::Pi),
            "hermes" => Some(Self::Hermes),
            "kilo" => Some(Self::Kilo),
            "dsh" => Some(Self::Dsh),
            "muse" => Some(Self::Muse),
            "devin" => Some(Self::Devin),
            "kimi" => Some(Self::Kimi),
            _ => None,
        }
    }
}

impl fmt::Display for SourceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Token counts, split into categories that never overlap.
///
/// `None` means the source does not report the field at all. `Some(0)` means it
/// reported zero. Keeping those distinct is what lets a report say "at least
/// 1.2M" instead of silently presenting a partial sum as complete.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Counters {
    /// Prompt tokens that were not served from cache.
    pub input_fresh: Option<u64>,
    /// Prompt tokens served from cache, billed at a reduced rate.
    pub cache_read: Option<u64>,
    /// Tokens written to the 5 minute cache.
    pub cache_write_5m: Option<u64>,
    /// Tokens written to the 1 hour cache, billed higher than the 5 minute one.
    pub cache_write_1h: Option<u64>,
    /// Generated tokens, including reasoning where the vendor bills it as output.
    pub output: Option<u64>,
}

impl Counters {
    /// Total billable tokens. Sound only because the fields are disjoint.
    pub fn total(&self) -> u64 {
        self.input_fresh.unwrap_or(0)
            + self.cache_read.unwrap_or(0)
            + self.cache_write_5m.unwrap_or(0)
            + self.cache_write_1h.unwrap_or(0)
            + self.output.unwrap_or(0)
    }

    /// Every prompt-side token, whatever bucket it landed in.
    pub fn input_total(&self) -> u64 {
        self.input_fresh.unwrap_or(0)
            + self.cache_read.unwrap_or(0)
            + self.cache_write_5m.unwrap_or(0)
            + self.cache_write_1h.unwrap_or(0)
    }

    /// True when at least one field is unreported, so a sum over this event is
    /// a lower bound rather than an exact figure.
    pub fn has_unknown(&self) -> bool {
        self.input_fresh.is_none()
            || self.cache_read.is_none()
            || self.cache_write_5m.is_none()
            || self.cache_write_1h.is_none()
            || self.output.is_none()
    }

    /// Add `other` into `self`, treating an unreported field as zero but
    /// remembering that the result is now partial.
    pub fn accumulate(&mut self, other: &Counters) {
        fn add(slot: &mut Option<u64>, v: Option<u64>) {
            if let Some(v) = v {
                *slot = Some(slot.unwrap_or(0) + v);
            }
        }
        add(&mut self.input_fresh, other.input_fresh);
        add(&mut self.cache_read, other.cache_read);
        add(&mut self.cache_write_5m, other.cache_write_5m);
        add(&mut self.cache_write_1h, other.cache_write_1h);
        add(&mut self.output, other.output);
    }
}

/// A per-request measurement. Safe to sum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Delta(pub Counters);

/// A running total. Deliberately not summable.
///
/// Sources such as Codex and the Grok session log restate a session total on
/// every record. Adding those together inflates without bound, so the only way
/// out of this type is [`Series::observe`](crate::series::Series::observe),
/// which differences consecutive samples into a [`Delta`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cumulative(pub Counters);

impl std::ops::Add for Delta {
    type Output = Delta;
    fn add(mut self, rhs: Delta) -> Delta {
        self.0.accumulate(&rhs.0);
        self
    }
}

/// Counts a source reports that must never be added to [`Counters`], either
/// because they are a subset of another field or because they are not tokens.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Extras {
    /// Reasoning tokens already counted inside `output`.
    pub reasoning_within_output: Option<u64>,
    pub web_search_requests: Option<u32>,
    pub web_fetch_requests: Option<u32>,
}

/// Whether usage was charged per token or covered by a subscription.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BillingMode {
    /// Billed per token against an API account.
    Metered,
    /// Covered by a subscription. Never presented as money charged.
    Plan,
    Unknown,
}

impl BillingMode {
    pub fn as_str(self) -> &'static str {
        match self {
            BillingMode::Metered => "metered",
            BillingMode::Plan => "plan",
            BillingMode::Unknown => "unknown",
        }
    }
}

/// How an event's identity was derived, which determines how much to trust that
/// two records referring to the same request actually collapse.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Confidence {
    /// The provider assigned a stable id that survives a log rewrite.
    Exact,
    /// A tuple of source-native fields that is unique by construction.
    Strong,
    /// Derived from position in a series. Deterministic, so re-reads are still
    /// idempotent, but it cannot survive the file being rewritten differently.
    Derived,
}

impl Confidence {
    pub fn as_str(self) -> &'static str {
        match self {
            Confidence::Exact => "exact",
            Confidence::Strong => "strong",
            Confidence::Derived => "derived",
        }
    }
}

/// A timestamp normalized to UTC milliseconds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Timestamp {
    pub utc_ms: i64,
}

impl Timestamp {
    pub fn from_ms(utc_ms: i64) -> Self {
        Self { utc_ms }
    }

    /// Calendar date in `tz`, used for daily bucketing.
    ///
    /// Bucketing happens once, at ingest. Re-bucketing an already-bucketed
    /// aggregate is what duplicates usage across a boundary when a user changes
    /// timezone, so rollups are rebuilt from events instead.
    pub fn local_date(&self, tz: &jiff::tz::TimeZone) -> String {
        let ts =
            jiff::Timestamp::from_millisecond(self.utc_ms).unwrap_or(jiff::Timestamp::UNIX_EPOCH);
        tz.to_datetime(ts).date().to_string()
    }

    pub fn local_hour(&self, tz: &jiff::tz::TimeZone) -> u8 {
        let ts =
            jiff::Timestamp::from_millisecond(self.utc_ms).unwrap_or(jiff::Timestamp::UNIX_EPOCH);
        tz.to_datetime(ts).hour() as u8
    }
}

/// A 16 byte content-derived event id, used as the deduplication key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct EventId(pub [u8; 16]);

impl EventId {
    /// Hash an identity tuple. Callers pass the parts that make a request
    /// unique, so the same request seen in two files produces the same id.
    pub fn derive(parts: &[&str]) -> Self {
        let mut hasher = blake3::Hasher::new();
        for p in parts {
            hasher.update(p.as_bytes());
            // Length-prefix free separator: a byte that cannot appear in the
            // ids we hash, so ("ab","c") and ("a","bc") do not collide.
            hasher.update(&[0x1f]);
        }
        let mut out = [0u8; 16];
        out.copy_from_slice(&hasher.finalize().as_bytes()[..16]);
        EventId(out)
    }
}

impl fmt::Display for EventId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for b in self.0 {
            write!(f, "{b:02x}")?;
        }
        Ok(())
    }
}

/// One normalized API request.
#[derive(Debug, Clone)]
pub struct UsageEvent {
    pub id: EventId,
    pub source: SourceId,
    pub ts: Timestamp,
    /// Canonical model identifier, for example `claude-opus-4-8`.
    pub model: String,
    /// Session identifier as the tool reports it. Local only.
    pub session: String,
    /// Project the work happened in. Local only, never synced verbatim.
    pub project: String,
    pub counters: Counters,
    pub extras: Extras,
    pub billing: BillingMode,
    pub confidence: Confidence,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn total_sums_disjoint_fields() {
        let c = Counters {
            input_fresh: Some(10),
            cache_read: Some(100),
            cache_write_5m: Some(5),
            cache_write_1h: Some(2),
            output: Some(50),
        };
        assert_eq!(c.total(), 167);
        assert_eq!(c.input_total(), 117);
        assert!(!c.has_unknown());
    }

    #[test]
    fn unknown_is_not_zero() {
        let c = Counters {
            input_fresh: Some(10),
            output: Some(5),
            ..Default::default()
        };
        assert!(c.has_unknown());
        assert_eq!(c.total(), 15);
    }

    #[test]
    fn accumulate_keeps_unreported_fields_unreported() {
        let mut a = Counters {
            input_fresh: Some(1),
            ..Default::default()
        };
        a.accumulate(&Counters {
            input_fresh: Some(2),
            output: Some(7),
            ..Default::default()
        });
        assert_eq!(a.input_fresh, Some(3));
        assert_eq!(a.output, Some(7));
        // Never observed on either side, so it stays unknown rather than zero.
        assert_eq!(a.cache_read, None);
    }

    #[test]
    fn recovered_claude_code_reads_as_the_same_tool() {
        assert_eq!(SourceId::label("claude_code"), "Claude Code");
        assert_eq!(
            SourceId::label("claude_code_rollup"),
            "Claude Code (recovered)"
        );
        assert_eq!(
            SourceId::label("claude_code_estimate"),
            "Claude Code (recovered)"
        );
        assert_eq!(SourceId::label("mystery_tool"), "mystery_tool");
        assert_eq!(SourceId::tool_id("claude_code"), "claude_code");
        assert_eq!(SourceId::tool_id("claude_code_rollup"), "claude_code");
        assert_eq!(SourceId::tool_id("claude_code_estimate"), "claude_code");
        assert_eq!(SourceId::tool_id("codex"), "codex");
    }

    #[test]
    fn event_id_is_stable_and_separator_safe() {
        let a = EventId::derive(&["req_1", "msg_1"]);
        let b = EventId::derive(&["req_1", "msg_1"]);
        assert_eq!(a, b);
        // Without a separator these two would hash identically.
        assert_ne!(EventId::derive(&["ab", "c"]), EventId::derive(&["a", "bc"]));
    }

    #[test]
    fn local_date_uses_the_given_zone() {
        // Late evening UTC is already the next day further east, which is
        // exactly the boundary that makes daily bucketing timezone sensitive.
        let ts = Timestamp::from_ms(
            "2026-07-28T23:30:00Z"
                .parse::<jiff::Timestamp>()
                .unwrap()
                .as_millisecond(),
        );
        let utc = jiff::tz::TimeZone::UTC;
        let bud = jiff::tz::TimeZone::get("Europe/Budapest").unwrap();
        assert_eq!(ts.local_date(&utc), "2026-07-28");
        assert_eq!(ts.local_date(&bud), "2026-07-29");
        assert_eq!(ts.local_hour(&utc), 23);
    }
}
