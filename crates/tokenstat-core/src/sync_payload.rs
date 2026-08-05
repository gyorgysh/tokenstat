//! Sealed day × source × model × project-key rollup for tokenstat.ai sync.
//!
//! Only allowlisted fields exist on these types. Opaque `proj` / `salt_id` are
//! required. Project *paths*, session ids, and prompts never appear on the
//! wire. The network stack lives in `tokenstat-sync`.

use hmac::{Hmac, KeyInit, Mac};
use serde::Serialize;
use sha2::Sha256;

use crate::error::CoreError;
use crate::store::Store;

type HmacSha256 = Hmac<Sha256>;

/// Highest schema version this CLI can emit.
///
/// v1: single `cw` cache-write total (priced at the 5m rate on the server).
/// v2: `cw5` + `cw1` split so 1-hour Anthropic writes use the 2x rate.
pub const SYNC_SCHEMA_VERSION: u32 = 2;

/// Maximum inclusive day span for one sync window (~13 months for heatmaps).
pub const SYNC_WINDOW_MAX_DAYS: i64 = 400;

/// Closed set of JSON keys allowed anywhere in a sync document.
///
/// `cw` is the schema v1 single cache-write total (see [`SyncPayload::canonical_bytes`]
/// when `v < 2`). `cw5` / `cw1` are the schema v2 split. All three stay on the
/// allowlist so both wire shapes pass key checks during the overlap window.
pub const ALLOWED_SYNC_KEYS: &[&str] = &[
    "v",
    "machine",
    "salt_id",
    "tz",
    "generated_at",
    "window",
    "prune",
    "rows",
    "totals",
    "from",
    "to",
    "d",
    "src",
    "model",
    "proj",
    "in",
    "out",
    "cr",
    "cw",
    "cw1",
    "cw5",
    "ev",
    "plan",
    "conf",
];

/// Keys that must never appear in a sync document.
pub const FORBIDDEN_SYNC_KEYS: &[&str] =
    &["project", "path", "session", "prompt", "host", "hostname"];

/// Inclusive local-date window for a sync upload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SyncWindow {
    pub from: String,
    pub to: String,
}

/// Client-side totals the server recomputes and must match.
///
/// Schema v2 fields (`cw5`/`cw1`). When emitting v1, [`SyncPayload`] maps these
/// into a single `cw` via a custom serializer path in `build_sync_payload`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SyncTotals {
    pub cr: u64,
    pub cw1: u64,
    pub cw5: u64,
    #[serde(rename = "in")]
    pub input: u64,
    pub out: u64,
    pub rows: u64,
}

/// One day × source × model × opaque-project rollup row.
///
/// Field declaration order is alphabetical so compact serde JSON is canonical.
/// Schema v2: `cw5` (5-minute cache write) + `cw1` (1-hour cache write).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SyncRow {
    pub conf: String,
    pub cr: u64,
    pub cw1: u64,
    pub cw5: u64,
    pub d: String,
    pub ev: u64,
    #[serde(rename = "in")]
    pub input: u64,
    pub model: String,
    pub out: u64,
    pub plan: bool,
    /// Opaque HMAC (`p_` + 24 hex) or JSON null for unattributed usage.
    pub proj: Option<String>,
    pub src: String,
}

/// Complete sync envelope.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SyncPayload {
    pub generated_at: String,
    pub machine: String,
    pub prune: bool,
    pub rows: Vec<SyncRow>,
    pub salt_id: String,
    pub totals: SyncTotals,
    pub tz: String,
    pub v: u32,
    pub window: SyncWindow,
}

/// Local archive bucket before project paths are hashed into `proj`.
#[derive(Debug, Clone)]
pub struct SyncRollupBucket {
    pub d: String,
    pub src: String,
    pub model: String,
    /// Local project path or label. Hashed; never serialized as-is.
    pub project: String,
    pub input: u64,
    pub out: u64,
    pub cr: u64,
    pub cw5: u64,
    pub cw1: u64,
    pub ev: u64,
    pub plan: bool,
    pub conf: String,
}

impl SyncTotals {
    pub fn from_rows(rows: &[SyncRow]) -> Self {
        let mut t = SyncTotals {
            cr: 0,
            cw1: 0,
            cw5: 0,
            input: 0,
            out: 0,
            rows: rows.len() as u64,
        };
        for r in rows {
            t.cr = t.cr.saturating_add(r.cr);
            t.cw5 = t.cw5.saturating_add(r.cw5);
            t.cw1 = t.cw1.saturating_add(r.cw1);
            t.input = t.input.saturating_add(r.input);
            t.out = t.out.saturating_add(r.out);
        }
        t
    }

    pub fn matches_rows(&self, rows: &[SyncRow]) -> bool {
        self == &Self::from_rows(rows)
    }

    /// Total cache-write tokens (both tiers).
    pub fn cw_total(&self) -> u64 {
        self.cw5.saturating_add(self.cw1)
    }
}

impl SyncPayload {
    /// Canonical JSON body for upload / hashing.
    ///
    /// Schema v2 serializes `cw5`/`cw1`. Schema v1 maps those into a single `cw`
    /// so older servers keep working during the overlap window.
    pub fn canonical_bytes(&self) -> Result<Vec<u8>, CoreError> {
        if self.v >= 2 {
            serde_json::to_vec(self).map_err(|source| CoreError::Json {
                context: "sync payload".into(),
                source,
            })
        } else {
            let v1 = SyncPayloadV1 {
                generated_at: self.generated_at.clone(),
                machine: self.machine.clone(),
                prune: self.prune,
                rows: self
                    .rows
                    .iter()
                    .map(|r| SyncRowV1 {
                        conf: r.conf.clone(),
                        cr: r.cr,
                        cw: r.cw5.saturating_add(r.cw1),
                        d: r.d.clone(),
                        ev: r.ev,
                        input: r.input,
                        model: r.model.clone(),
                        out: r.out,
                        plan: r.plan,
                        proj: r.proj.clone(),
                        src: r.src.clone(),
                    })
                    .collect(),
                salt_id: self.salt_id.clone(),
                totals: SyncTotalsV1 {
                    cr: self.totals.cr,
                    cw: self.totals.cw_total(),
                    input: self.totals.input,
                    out: self.totals.out,
                    rows: self.totals.rows,
                },
                tz: self.tz.clone(),
                v: 1,
                window: self.window.clone(),
            };
            serde_json::to_vec(&v1).map_err(|source| CoreError::Json {
                context: "sync payload v1".into(),
                source,
            })
        }
    }

    pub fn assert_sealed(&self) -> Result<(), CoreError> {
        let bytes = self.canonical_bytes()?;
        let value: serde_json::Value =
            serde_json::from_slice(&bytes).map_err(|source| CoreError::Json {
                context: "sync payload reseal".into(),
                source,
            })?;
        check_keys(&value, "")?;
        if !self.totals.matches_rows(&self.rows) {
            return Err(CoreError::SyncTotalsMismatch);
        }
        if !is_valid_salt_id(&self.salt_id) {
            return Err(CoreError::InvalidSaltId(self.salt_id.clone()));
        }
        for row in &self.rows {
            if let Some(p) = &row.proj {
                if !is_valid_project_key(p) {
                    return Err(CoreError::InvalidProjectKey(p.clone()));
                }
            }
        }
        let mut seen = std::collections::BTreeSet::new();
        for row in &self.rows {
            let key = (
                row.d.as_str(),
                row.src.as_str(),
                row.model.as_str(),
                row.proj.as_deref(),
            );
            if !seen.insert(key) {
                return Err(CoreError::DuplicateSyncRow {
                    d: row.d.clone(),
                    src: row.src.clone(),
                    model: row.model.clone(),
                    proj: row.proj.clone().unwrap_or_default(),
                });
            }
        }
        Ok(())
    }
}

fn check_keys(value: &serde_json::Value, path: &str) -> Result<(), CoreError> {
    match value {
        serde_json::Value::Object(map) => {
            for (k, v) in map {
                if FORBIDDEN_SYNC_KEYS.contains(&k.as_str()) {
                    return Err(CoreError::ForbiddenSyncField(k.clone()));
                }
                if !ALLOWED_SYNC_KEYS.contains(&k.as_str()) {
                    return Err(CoreError::ForbiddenSyncField(k.clone()));
                }
                let child = if path.is_empty() {
                    k.clone()
                } else {
                    format!("{path}.{k}")
                };
                check_keys(v, &child)?;
            }
            Ok(())
        }
        serde_json::Value::Array(items) => {
            for (i, v) in items.iter().enumerate() {
                check_keys(v, &format!("{path}[{i}]"))?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

/// Validate `m_` + 16 lowercase hex bytes.
pub fn is_valid_machine_id(id: &str) -> bool {
    let Some(rest) = id.strip_prefix("m_") else {
        return false;
    };
    rest.len() == 16
        && rest
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

/// Validate `s_` + 8 lowercase hex bytes.
pub fn is_valid_salt_id(id: &str) -> bool {
    let Some(rest) = id.strip_prefix("s_") else {
        return false;
    };
    rest.len() == 8
        && rest
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

/// Validate `p_` + 24 lowercase hex bytes.
pub fn is_valid_project_key(id: &str) -> bool {
    let Some(rest) = id.strip_prefix("p_") else {
        return false;
    };
    rest.len() == 24
        && rest
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

/// `HMAC-SHA256(local_salt, canonical_project_path)` truncated to 12 bytes.
///
/// Empty / whitespace-only paths are unattributed (`None` → JSON null).
pub fn project_key(salt: &[u8], project_path: &str) -> Result<Option<String>, CoreError> {
    let canonical = canonicalize_project_path(project_path);
    if canonical.is_empty() {
        return Ok(None);
    }
    let mut mac = HmacSha256::new_from_slice(salt)
        .map_err(|_| CoreError::InvalidSaltId("hmac key rejected".into()))?;
    mac.update(canonical.as_bytes());
    let digest = mac.finalize().into_bytes();
    let mut hex = String::with_capacity(24);
    for b in digest.iter().take(12) {
        hex.push_str(&format!("{b:02x}"));
    }
    Ok(Some(format!("p_{hex}")))
}

/// Trim; keep the archive's project string otherwise. Paths stay local.
pub fn canonicalize_project_path(project: &str) -> String {
    project.trim().to_string()
}

/// Inputs for building a sealed sync payload.
pub struct SyncBuildArgs<'a> {
    pub machine: &'a str,
    pub salt_id: &'a str,
    pub salt_key: &'a [u8],
    pub tz: &'a str,
    pub window: SyncWindow,
    pub prune: bool,
    /// Payload `v` chosen against the server envelope.
    pub schema_v: u32,
    /// Live allowlist from `/api/v1/schema`. `None` skips the check (dry-run offline).
    pub allowed_sources: Option<&'a [String]>,
    pub allowed_confidence: Option<&'a [String]>,
}

/// Build a sealed sync payload from the archive rollup.
pub fn build_sync_payload(
    store: &Store,
    args: SyncBuildArgs<'_>,
) -> Result<SyncPayload, CoreError> {
    if !is_valid_machine_id(args.machine) {
        return Err(CoreError::InvalidMachineId(args.machine.to_string()));
    }
    if !is_valid_salt_id(args.salt_id) {
        return Err(CoreError::InvalidSaltId(args.salt_id.to_string()));
    }
    if args.window.from > args.window.to {
        return Err(CoreError::InvalidSyncWindow {
            from: args.window.from.clone(),
            to: args.window.to.clone(),
        });
    }

    let buckets = store.sync_rollup(&args.window.from, &args.window.to)?;
    let mut rows: Vec<SyncRow> = Vec::with_capacity(buckets.len());
    for b in buckets {
        if b.d < args.window.from || b.d > args.window.to {
            continue;
        }
        if b.model.is_empty() || b.model.len() > 128 {
            continue;
        }
        if let Some(allowed) = args.allowed_sources {
            if !allowed.iter().any(|s| s == &b.src) {
                return Err(CoreError::UnsupportedSyncEnum {
                    field: "src".into(),
                    value: b.src,
                });
            }
        }
        if let Some(allowed) = args.allowed_confidence {
            if !allowed.iter().any(|c| c == &b.conf) {
                return Err(CoreError::UnsupportedSyncEnum {
                    field: "conf".into(),
                    value: b.conf,
                });
            }
        }
        let proj = project_key(args.salt_key, &b.project)?;
        // Schema v1 only has a single write bucket: fold both tiers into cw5 so
        // the server prices them at the 5m rate (the only rate it knows under v1).
        let (cw5, cw1) = if args.schema_v >= 2 {
            (b.cw5, b.cw1)
        } else {
            (b.cw5.saturating_add(b.cw1), 0)
        };
        rows.push(SyncRow {
            conf: b.conf,
            cr: b.cr,
            cw1,
            cw5,
            d: b.d,
            ev: b.ev,
            input: b.input,
            model: b.model,
            out: b.out,
            plan: b.plan,
            proj,
            src: b.src,
        });
    }
    // Server uniqueness is (d, src, model, proj). Never emit two rows that
    // only differ on plan/conf: merge any collision by summing counters.
    rows = collapse_duplicate_row_keys(rows);
    rows.sort_by(|a, b| (&a.d, &a.src, &a.model, &a.proj).cmp(&(&b.d, &b.src, &b.model, &b.proj)));

    let totals = SyncTotals::from_rows(&rows);
    let generated_at = jiff::Timestamp::now()
        .strftime("%Y-%m-%dT%H:%M:%SZ")
        .to_string();

    let payload = SyncPayload {
        generated_at,
        machine: args.machine.to_string(),
        prune: args.prune,
        rows,
        salt_id: args.salt_id.to_string(),
        totals,
        tz: args.tz.to_string(),
        v: args.schema_v,
        window: args.window,
    };
    payload.assert_sealed()?;
    Ok(payload)
}

/// Wire-only v1 row (single `cw`). Used by [`SyncPayload::canonical_bytes`].
#[derive(Debug, Clone, Serialize)]
struct SyncRowV1 {
    conf: String,
    cr: u64,
    cw: u64,
    d: String,
    ev: u64,
    #[serde(rename = "in")]
    input: u64,
    model: String,
    out: u64,
    plan: bool,
    proj: Option<String>,
    src: String,
}

#[derive(Debug, Clone, Serialize)]
struct SyncTotalsV1 {
    cr: u64,
    cw: u64,
    #[serde(rename = "in")]
    input: u64,
    out: u64,
    rows: u64,
}

#[derive(Debug, Clone, Serialize)]
struct SyncPayloadV1 {
    generated_at: String,
    machine: String,
    prune: bool,
    rows: Vec<SyncRowV1>,
    salt_id: String,
    totals: SyncTotalsV1,
    tz: String,
    v: u32,
    window: SyncWindow,
}

/// Merge rows that share the server uniqueness key `(d, src, model, proj)`.
///
/// `plan` stays true only when every merged contributor was plan. Confidence
/// keeps the weaker rank so mixed buckets do not look stronger than they are.
fn collapse_duplicate_row_keys(rows: Vec<SyncRow>) -> Vec<SyncRow> {
    use std::collections::BTreeMap;
    let mut map: BTreeMap<(String, String, String, Option<String>), SyncRow> = BTreeMap::new();
    for row in rows {
        let key = (
            row.d.clone(),
            row.src.clone(),
            row.model.clone(),
            row.proj.clone(),
        );
        match map.entry(key) {
            std::collections::btree_map::Entry::Vacant(slot) => {
                slot.insert(row);
            }
            std::collections::btree_map::Entry::Occupied(mut slot) => {
                let existing = slot.get_mut();
                existing.input = existing.input.saturating_add(row.input);
                existing.out = existing.out.saturating_add(row.out);
                existing.cr = existing.cr.saturating_add(row.cr);
                existing.cw5 = existing.cw5.saturating_add(row.cw5);
                existing.cw1 = existing.cw1.saturating_add(row.cw1);
                existing.ev = existing.ev.saturating_add(row.ev);
                existing.plan = existing.plan && row.plan;
                existing.conf = weaker_confidence(&existing.conf, &row.conf).to_string();
            }
        }
    }
    map.into_values().collect()
}

fn weaker_confidence<'a>(a: &'a str, b: &'a str) -> &'a str {
    let rank = |c: &str| match c {
        "exact" => 2,
        "strong" => 1,
        _ => 0,
    };
    if rank(a) <= rank(b) { a } else { b }
}

/// Pick the highest CLI-supported `v` still inside `[min_v, max_v]`.
pub fn choose_schema_v(min_v: u32, max_v: u32) -> Result<u32, CoreError> {
    if max_v < min_v {
        return Err(CoreError::UnsupportedSyncSchemaRange { min_v, max_v });
    }
    // Highest version we speak that the server still accepts.
    let chosen = SYNC_SCHEMA_VERSION.min(max_v);
    if chosen < min_v {
        return Err(CoreError::UnsupportedSyncSchemaRange { min_v, max_v });
    }
    Ok(chosen)
}

/// Choose the default inclusive window from archive span and an optional cursor.
pub fn default_sync_window(
    first_date: Option<&str>,
    last_date: Option<&str>,
    today: &str,
    cursor_from: Option<&str>,
) -> Option<SyncWindow> {
    let end = last_date.unwrap_or(today);
    let end = if end.is_empty() { today } else { end };
    if end.is_empty() {
        return None;
    }

    let start_floor = first_date.unwrap_or(end);
    let mut from = cursor_from.unwrap_or(start_floor);
    if from < start_floor {
        from = start_floor;
    }
    if from > end {
        from = end;
    }

    let mut from = from.to_string();
    if let (Ok(from_d), Ok(to_d)) = (
        from.parse::<jiff::civil::Date>(),
        end.parse::<jiff::civil::Date>(),
    ) {
        if let Ok(span) = from_d.until((jiff::Unit::Day, to_d)) {
            if i64::from(span.get_days()) >= SYNC_WINDOW_MAX_DAYS {
                if let Ok(trimmed) =
                    to_d.checked_sub(jiff::Span::new().days(SYNC_WINDOW_MAX_DAYS - 1))
                {
                    from = trimmed.to_string();
                }
            }
        }
    }

    Some(SyncWindow {
        from,
        to: end.to_string(),
    })
}

/// Parse `YYYY-MM-DD..YYYY-MM-DD`.
pub fn parse_window_arg(raw: &str) -> Result<SyncWindow, CoreError> {
    let Some((from, to)) = raw.split_once("..") else {
        return Err(CoreError::InvalidSyncWindow {
            from: raw.to_string(),
            to: String::new(),
        });
    };
    let from = from.trim();
    let to = to.trim();
    if from.parse::<jiff::civil::Date>().is_err() || to.parse::<jiff::civil::Date>().is_err() {
        return Err(CoreError::InvalidSyncWindow {
            from: from.to_string(),
            to: to.to_string(),
        });
    }
    if from > to {
        return Err(CoreError::InvalidSyncWindow {
            from: from.to_string(),
            to: to.to_string(),
        });
    }
    Ok(SyncWindow {
        from: from.to_string(),
        to: to.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{
        BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
    };

    #[allow(clippy::too_many_arguments)]
    fn ev(
        id: &str,
        ms: i64,
        source: SourceId,
        model: &str,
        project: &str,
        billing: BillingMode,
        conf: Confidence,
        input: u64,
        out: u64,
        cr: u64,
        cw: u64,
    ) -> UsageEvent {
        UsageEvent {
            id: EventId::derive(&[id]),
            source,
            ts: Timestamp::from_ms(ms),
            model: model.into(),
            session: "ses_should_never_sync".into(),
            project: project.into(),
            counters: Counters {
                input_fresh: Some(input),
                cache_read: Some(cr),
                cache_write_5m: Some(cw),
                cache_write_1h: None,
                output: Some(out),
            },
            extras: Extras::default(),
            billing,
            confidence: conf,
        }
    }

    #[test]
    fn sealed_payload_hashes_project_and_omits_path() {
        let mut store = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        let ms = 1_753_444_800_000;
        let day = Timestamp::from_ms(ms).local_date(&tz);
        store
            .insert_events(
                &[ev(
                    "a",
                    ms,
                    SourceId::ClaudeCode,
                    "claude-opus-4-8",
                    "/Users/secret/project",
                    BillingMode::Plan,
                    Confidence::Exact,
                    10,
                    20,
                    30,
                    40,
                )],
                &tz,
            )
            .unwrap();

        let salt = [7u8; 32];
        let payload = build_sync_payload(
            &store,
            SyncBuildArgs {
                machine: "m_0123456789abcdef",
                salt_id: "s_abcdef01",
                salt_key: &salt,
                tz: "UTC",
                window: SyncWindow {
                    from: day.clone(),
                    to: day.clone(),
                },
                prune: false,
                schema_v: 1,
                allowed_sources: None,
                allowed_confidence: None,
            },
        )
        .unwrap();

        let json = String::from_utf8(payload.canonical_bytes().unwrap()).unwrap();
        for bad in FORBIDDEN_SYNC_KEYS {
            assert!(
                !json.contains(&format!("\"{bad}\"")),
                "forbidden key {bad} leaked into {json}"
            );
        }
        assert!(!json.contains("ses_should_never_sync"));
        assert!(!json.contains("/Users/secret"));
        assert!(json.contains("\"salt_id\":\"s_abcdef01\""));
        assert!(json.contains("\"prune\":false"));
        assert_eq!(payload.rows.len(), 1);
        let proj = payload.rows[0].proj.as_deref().unwrap();
        assert!(is_valid_project_key(proj), "{proj}");
        assert_eq!(
            proj,
            project_key(&salt, "/Users/secret/project")
                .unwrap()
                .unwrap()
        );
        assert_eq!(payload.rows[0].conf, "exact");
        assert_eq!(payload.totals.rows, 1);
    }

    #[test]
    fn empty_project_becomes_null_proj() {
        let salt = [1u8; 32];
        assert_eq!(project_key(&salt, "   ").unwrap(), None);
        assert_eq!(project_key(&salt, "").unwrap(), None);
    }

    #[test]
    fn salt_rotation_changes_proj_namespace() {
        let a = project_key(&[1u8; 32], "/repo").unwrap().unwrap();
        let b = project_key(&[2u8; 32], "/repo").unwrap().unwrap();
        assert_ne!(a, b);
    }

    #[test]
    fn canonical_bytes_are_stable_for_identical_payload() {
        let payload = SyncPayload {
            generated_at: "2026-07-29T00:00:00Z".into(),
            machine: "m_0123456789abcdef".into(),
            prune: false,
            rows: vec![SyncRow {
                conf: "exact".into(),
                cr: 1,
                cw1: 0,
                cw5: 2,
                d: "2026-07-25".into(),
                ev: 3,
                input: 4,
                model: "m".into(),
                out: 5,
                plan: true,
                proj: Some("p_0123456789abcdef01234567".into()),
                src: "claude_code".into(),
            }],
            salt_id: "s_abcdef01".into(),
            totals: SyncTotals {
                cr: 1,
                cw1: 0,
                cw5: 2,
                input: 4,
                out: 5,
                rows: 1,
            },
            tz: "UTC".into(),
            v: 2,
            window: SyncWindow {
                from: "2026-07-25".into(),
                to: "2026-07-25".into(),
            },
        };
        let a = payload.canonical_bytes().unwrap();
        let b = payload.canonical_bytes().unwrap();
        assert_eq!(a, b);
        let s = String::from_utf8(a).unwrap();
        assert!(s.contains("\"salt_id\":\"s_abcdef01\""));
        assert!(s.contains("\"proj\":\"p_0123456789abcdef01234567\""));
    }

    #[test]
    fn prune_defaults_false_and_totals_must_match() {
        let mut payload = SyncPayload {
            generated_at: "2026-07-29T00:00:00Z".into(),
            machine: "m_0123456789abcdef".into(),
            prune: false,
            rows: vec![],
            salt_id: "s_abcdef01".into(),
            totals: SyncTotals {
                cr: 0,
                cw1: 0,
                cw5: 0,
                input: 0,
                out: 0,
                rows: 0,
            },
            tz: "UTC".into(),
            v: 2,
            window: SyncWindow {
                from: "2026-07-25".into(),
                to: "2026-07-25".into(),
            },
        };
        payload.assert_sealed().unwrap();
        payload.totals.input = 99;
        assert!(matches!(
            payload.assert_sealed(),
            Err(CoreError::SyncTotalsMismatch)
        ));
    }

    #[test]
    fn machine_and_salt_shapes() {
        assert!(is_valid_machine_id("m_0123456789abcdef"));
        assert!(is_valid_salt_id("s_abcdef01"));
        assert!(!is_valid_salt_id("s_ABCDEF01"));
        assert!(!is_valid_salt_id("s_short"));
    }

    #[test]
    fn choose_schema_v_refuses_outside_range() {
        assert_eq!(choose_schema_v(1, 1).unwrap(), 1);
        assert_eq!(choose_schema_v(1, 2).unwrap(), 2);
        assert_eq!(choose_schema_v(2, 2).unwrap(), 2);
        // Server only speaks v=3+ and we max out at SYNC_SCHEMA_VERSION.
        assert!(choose_schema_v(3, 4).is_err());
    }

    #[test]
    fn default_window_caps_at_400_days() {
        let w = default_sync_window(Some("2024-01-01"), Some("2026-07-29"), "2026-07-29", None)
            .unwrap();
        assert_eq!(w.to, "2026-07-29");
        let from: jiff::civil::Date = w.from.parse().unwrap();
        let to: jiff::civil::Date = w.to.parse().unwrap();
        let days = from.until((jiff::Unit::Day, to)).unwrap().get_days();
        assert!(i64::from(days) < SYNC_WINDOW_MAX_DAYS);
        assert!(i64::from(days) >= SYNC_WINDOW_MAX_DAYS - 2);
    }

    #[test]
    fn sync_rollup_sql_groups_by_project_not_session() {
        let sql = Store::SYNC_ROLLUP_SQL;
        assert!(sql.contains("project"), "{sql}");
        assert!(!sql.contains("session"), "{sql}");
        // Server uniqueness is (d, src, model, proj). Billing must not split
        // that key into duplicate rows.
        assert!(
            !sql.contains(
                "GROUP BY local_date, source, model, project,\n                 CASE WHEN billing"
            ),
            "billing must not be in GROUP BY: {sql}"
        );
    }

    #[test]
    fn duplicate_row_keys_are_merged_before_seal() {
        let a = SyncRow {
            conf: "exact".into(),
            cr: 1,
            cw1: 0,
            cw5: 0,
            d: "2026-07-25".into(),
            ev: 1,
            input: 10,
            model: "cursor-grok-4.5-high-fast".into(),
            out: 2,
            plan: true,
            proj: Some("p_90dd920167a25fd92b25870b".into()),
            src: "cursor".into(),
        };
        let mut b = a.clone();
        b.conf = "strong".into();
        b.plan = false;
        b.input = 5;
        b.out = 3;
        b.ev = 2;
        let merged = collapse_duplicate_row_keys(vec![a, b]);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].input, 15);
        assert_eq!(merged[0].out, 5);
        assert_eq!(merged[0].ev, 3);
        assert!(!merged[0].plan);
        assert_eq!(merged[0].conf, "strong");
    }
}
