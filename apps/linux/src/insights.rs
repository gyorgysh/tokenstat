// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The original Insights snapshot and guarded per-window refresh ownership.
//! The local report's selection, time range, and refresh ownership.

use crate::chat::wire::number;
use serde::{Deserialize, Serialize};
pub mod account;
pub mod fetch;

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Query {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub since: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub until: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub billing: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<i64>,
}

impl PartialEq for Query {
    fn eq(&self, other: &Self) -> bool {
        fn equal(a: &Option<String>, b: &Option<String>) -> bool {
            match (a, b) {
                (Some(a), Some(b)) => crate::work::text::equal(a, b),
                (None, None) => true,
                _ => false,
            }
        }
        equal(&self.since, &other.since)
            && equal(&self.until, &other.until)
            && equal(&self.model, &other.model)
            && equal(&self.project, &other.project)
            && equal(&self.billing, &other.billing)
            && self.limit == other.limit
    }
}
impl Eq for Query {}

impl Query {
    pub fn day(date: &str) -> Self {
        Self {
            since: Some(date.into()),
            until: Some(date.into()),
            ..Self::default()
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Period {
    Week,
    Month,
    Quarter,
    #[default]
    All,
}

impl Period {
    pub const ALL: [Self; 4] = [Self::Week, Self::Month, Self::Quarter, Self::All];
    pub fn label(self) -> &'static str {
        match self {
            Self::Week => "7d",
            Self::Month => "30d",
            Self::Quarter => "90d",
            Self::All => "All",
        }
    }
    fn days(self) -> Option<i32> {
        match self {
            Self::Week => Some(7),
            Self::Month => Some(30),
            Self::Quarter => Some(90),
            Self::All => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Tab {
    #[default]
    Overview,
    Models,
    Projects,
    Harnesses,
    Sessions,
}

impl Tab {
    pub const ALL: [Self; 5] = [
        Self::Overview,
        Self::Models,
        Self::Projects,
        Self::Harnesses,
        Self::Sessions,
    ];
    pub fn label_key(self) -> &'static str {
        match self {
            Self::Overview => "apple.insightsmodel.overview.d4b1ea57",
            Self::Models => "apple.insightsmodel.models.d17d2d78",
            Self::Projects => "common.projects",
            Self::Harnesses => "apple.insightsmodel.coding_tools.6032f740",
            Self::Sessions => "apple.insightsmodel.sessions.6fa3cbf4",
        }
    }
    pub fn symbol(self) -> &'static str {
        match self {
            Self::Overview => "square.grid.2x2",
            Self::Models => "cpu",
            Self::Projects => "folder",
            Self::Harnesses => "terminal",
            Self::Sessions => "bubble.left.and.bubble.right",
        }
    }
}

/// Calendar-day arithmetic uses local noon so a daylight-saving transition
/// cannot turn the chosen local date into an adjacent day.
#[cfg(unix)]
fn local_start(days: i32) -> Option<String> {
    let now = unsafe { libc::time(std::ptr::null_mut()) };
    local_start_at(now, days)
}

#[cfg(unix)]
pub fn local_start_at(now: libc::time_t, days: i32) -> Option<String> {
    let mut local = std::mem::MaybeUninit::<libc::tm>::uninit();
    if unsafe { libc::localtime_r(&now, local.as_mut_ptr()) }.is_null() {
        return None;
    }
    let mut local = unsafe { local.assume_init() };
    local.tm_mday -= days - 1;
    local.tm_hour = 12;
    local.tm_min = 0;
    local.tm_sec = 0;
    local.tm_isdst = -1;
    if unsafe { libc::mktime(&mut local) } == -1 {
        return None;
    }
    Some(format!(
        "{:04}-{:02}-{:02}",
        local.tm_year + 1900,
        local.tm_mon + 1,
        local.tm_mday
    ))
}

#[cfg(not(unix))]
fn local_start(_days: i32) -> Option<String> {
    None
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Counters {
    #[serde(default, deserialize_with = "number::u64_optional")]
    pub input_fresh: Option<u64>,
    #[serde(default, deserialize_with = "number::u64_optional")]
    pub cache_read: Option<u64>,
    #[serde(default, deserialize_with = "number::u64_optional")]
    pub cache_write_5m: Option<u64>,
    #[serde(default, deserialize_with = "number::u64_optional")]
    pub cache_write_1h: Option<u64>,
    #[serde(default, deserialize_with = "number::u64_optional")]
    pub output: Option<u64>,
    #[serde(deserialize_with = "number::u64_required")]
    pub total: u64,
    #[serde(deserialize_with = "number::u64_required")]
    pub input_total: u64,
    pub has_unknown: bool,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Bucket {
    pub key: String,
    pub counters: Counters,
    #[serde(deserialize_with = "number::u64_required")]
    pub events: u64,
    #[serde(deserialize_with = "number::u64_required")]
    pub sessions: u64,
    #[serde(deserialize_with = "number::i64_required")]
    pub value_micros: i64,
    pub estimated: bool,
    pub unpriced_models: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Totals {
    pub counters: Counters,
    #[serde(deserialize_with = "number::u64_required")]
    pub events: u64,
    #[serde(deserialize_with = "number::u64_required")]
    pub sessions: u64,
    #[serde(deserialize_with = "number::u64_required")]
    pub days: u64,
    pub first_date: Option<String>,
    pub last_date: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Info {
    pub protocol_version: String,
    pub core_version: String,
    pub db_path: Option<String>,
    pub has_archive: bool,
    #[serde(default, deserialize_with = "number::i64_optional")]
    pub last_scan_ms: Option<i64>,
    pub timezone: String,
    pub price_book_effective_from: String,
    pub has_prices: bool,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Block {
    #[serde(deserialize_with = "number::i64_required")]
    pub start_ms: i64,
    #[serde(deserialize_with = "number::i64_required")]
    pub end_ms: i64,
    pub counters: Counters,
    #[serde(deserialize_with = "number::u64_required")]
    pub events: u64,
    #[serde(deserialize_with = "number::u64_required")]
    pub sessions: u64,
    pub active: bool,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SplitBucket {
    pub key: String,
    pub split: String,
    pub counters: Counters,
    #[serde(deserialize_with = "number::u64_required")]
    pub events: u64,
    #[serde(deserialize_with = "number::u64_required")]
    pub sessions: u64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub info: Info,
    pub totals: Totals,
    pub daily: Vec<Bucket>,
    pub by_model: Vec<Bucket>,
    pub by_project: Vec<Bucket>,
    pub by_source: Vec<Bucket>,
    pub by_session: Vec<Bucket>,
    pub active_block: Option<Block>,
    pub project_harnesses: Vec<SplitBucket>,
}

pub fn model_value(rows: &[Bucket]) -> String {
    let (micros, estimated, complete) =
        rows.iter()
            .fold((0_i64, false, true), |(sum, estimated, complete), row| {
                (
                    sum.saturating_add(row.value_micros),
                    estimated || row.estimated,
                    complete && row.unpriced_models.is_empty(),
                )
            });
    crate::display::money(micros, estimated, complete)
}

#[derive(Clone)]
pub struct Read {
    generation: u64,
    pub query: Query,
    cancelled: std::sync::Arc<std::sync::atomic::AtomicBool>,
}
impl Read {
    pub fn is_current(&self) -> bool {
        !self.cancelled.load(std::sync::atomic::Ordering::Acquire)
    }
}

#[derive(Default)]
pub struct State {
    pub snapshot: Option<Snapshot>,
    pub loading: bool,
    pub error: Option<String>,
    pub query: Query,
    pub period: Period,
    pub tab: Tab,
    pub focused_day: Option<String>,
    pub selected: Option<Bucket>,
    pub action_message: Option<String>,
    action_generation: u64,
    generation: u64,
    pending: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
}

impl State {
    /// InspectorView distinguishes a confirmed empty archive from loading,
    /// failure, and a snapshot that has not arrived yet.
    pub fn inspector_empty_archive(&self) -> bool {
        self.snapshot
            .as_ref()
            .is_some_and(|snapshot| snapshot.totals.events == 0)
            && self.error.is_none()
            && !self.loading
    }

    /// ProjectHarnesses follows byProject order and keeps split order unchanged.
    /// Swift String equality is canonically equivalent, including for paths.
    pub fn selected_project_harnesses(&self) -> Vec<&SplitBucket> {
        let (Some(snapshot), Some(selected)) = (&self.snapshot, &self.selected) else {
            return Vec::new();
        };
        if self.tab != Tab::Projects
            || !snapshot
                .by_project
                .iter()
                .any(|project| crate::work::text::equal(&project.key, &selected.key))
        {
            return Vec::new();
        }
        snapshot
            .project_harnesses
            .iter()
            .filter(|split| crate::work::text::equal(&split.key, &selected.key))
            .collect()
    }

    pub fn clear_action(&mut self) {
        self.action_message = None;
    }

    pub fn show_action(&mut self, message: String) -> u64 {
        self.action_generation = self.action_generation.wrapping_add(1);
        self.action_message = Some(message);
        self.action_generation
    }

    pub fn expire_action(&mut self, generation: u64) -> bool {
        if self.action_generation != generation || self.action_message.is_none() {
            return false;
        }
        self.action_message = None;
        true
    }
    pub fn update_query(&mut self) {
        self.query = if let Some(day) = &self.focused_day {
            Query::day(day)
        } else {
            Query {
                since: self.period.days().and_then(local_start),
                ..Query::default()
            }
        };
    }

    pub fn set_period(&mut self, period: Period) -> bool {
        if self.period == period {
            return false;
        }
        self.period = period;
        self.focused_day = None;
        self.update_query();
        true
    }

    pub fn focus_day(&mut self, day: &str) -> bool {
        if self
            .focused_day
            .as_deref()
            .is_some_and(|old| crate::work::text::equal(old, day))
        {
            return false;
        }
        self.focused_day = Some(day.into());
        self.selected = None;
        self.update_query();
        true
    }

    pub fn clear_focused_day(&mut self) -> bool {
        if self.focused_day.take().is_none() {
            return false;
        }
        self.update_query();
        true
    }

    pub fn set_tab(&mut self, tab: Tab) {
        if self.tab != tab {
            self.tab = tab;
            self.selected = None;
        }
    }

    pub fn rows(&self) -> &[Bucket] {
        let Some(snapshot) = &self.snapshot else {
            return &[];
        };
        match self.tab {
            Tab::Overview | Tab::Models => &snapshot.by_model,
            Tab::Projects => &snapshot.by_project,
            Tab::Harnesses => &snapshot.by_source,
            Tab::Sessions => &snapshot.by_session,
        }
    }

    pub fn begin(&mut self, query: Query) -> Read {
        if let Some(old) = self.pending.take() {
            old.store(true, std::sync::atomic::Ordering::Release);
        }
        let cancelled = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        self.pending = Some(cancelled.clone());
        self.generation = self.generation.wrapping_add(1);
        self.query = query.clone();
        self.loading = true;
        self.error = None;
        Read {
            generation: self.generation,
            query,
            cancelled,
        }
    }
    /// As in InsightsModel.refresh, an old generation or query cannot publish
    /// values or errors, or clear a newer request's loading state.
    pub fn finish(&mut self, read: &Read, result: Result<Snapshot, String>) -> bool {
        if read.generation != self.generation {
            return false;
        }
        self.loading = false;
        if read.query != self.query {
            return false;
        }
        match result {
            Ok(snapshot) => {
                self.snapshot = Some(snapshot);
                if let Some(key) = self.selected.as_ref().map(|row| row.key.clone()) {
                    self.selected = self
                        .rows()
                        .iter()
                        .find(|row| crate::work::text::equal(&row.key, &key))
                        .cloned();
                }
            }
            Err(error) => self.error = Some(error),
        }
        true
    }
}

#[cfg(unix)]
impl crate::client::Client {
    pub fn insights_snapshot(&self, query: &Query) -> anyhow::Result<Snapshot> {
        self.insights_snapshot_if_current(query, || true)
    }
    pub fn insights_snapshot_if_current(
        &self,
        query: &Query,
        current: impl Fn() -> bool,
    ) -> anyhow::Result<Snapshot> {
        anyhow::ensure!(current(), "Insights request cancelled");
        self.prepare()?;
        anyhow::ensure!(current(), "Insights request cancelled");
        Ok(serde_json::from_value(self.call_with_timeout(
            "insights.snapshot",
            serde_json::json!({"query":query}),
            std::time::Duration::from_secs(60),
        )?)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    #[test]
    fn scan_and_fetch_share_action_ownership_without_old_timers_erasing_new_messages() {
        let mut state = State::default();
        let scan = state.show_action("scan complete".into());
        state.clear_action(); // Starting a fetch clears the previous toast.
        let fetch = state.show_action("remote complete".into());
        assert!(!state.expire_action(scan));
        assert_eq!(state.action_message.as_deref(), Some("remote complete"));
        assert!(state.expire_action(fetch));
        assert!(state.action_message.is_none());
        let prior = state.show_action("same".into());
        state.clear_action();
        let current = state.show_action("same".into());
        assert!(!state.expire_action(prior));
        assert!(state.expire_action(current));
    }

    fn fixture() -> Value {
        json!({"info":{"protocolVersion":"53","coreVersion":"fixture","dbPath":null,"hasArchive":true,"timezone":"UTC","priceBookEffectiveFrom":"","hasPrices":false},
            "totals":{"counters":{"total":2,"inputTotal":1,"hasUnknown":true},"events":1,"sessions":1,"days":1},
            "daily":[],"byModel":[],"byProject":[],"bySource":[],"bySession":[],"activeBlock":null,"projectHarnesses":[]})
    }

    #[test]
    fn refresh_keeps_last_good_snapshot_and_fences_stale_query_and_progress() {
        let snapshot: Snapshot = serde_json::from_value(fixture()).unwrap();
        assert_eq!(snapshot.totals.counters.total, 2);
        assert!(snapshot.totals.counters.input_fresh.is_none());
        assert!(serde_json::from_value::<Snapshot>(json!({"info":{}})).is_err());
        let mut state = State::default();
        let first = state.begin(Query::default());
        let newer = state.begin(Query::day("2026-01-02"));
        assert!(!state.finish(&first, Ok(snapshot.clone())));
        assert!(state.loading && state.snapshot.is_none());
        assert!(state.finish(&newer, Ok(snapshot)));
        assert!(!state.loading && state.snapshot.is_some());
        let failed = state.begin(Query::default());
        assert!(state.finish(&failed, Err("offline".into())));
        assert_eq!(state.error.as_deref(), Some("offline"));
        assert!(state.snapshot.is_some());
        let obsolete = state.begin(Query::default());
        state.query = Query::day("2026-03-04");
        assert!(!state.finish(&obsolete, Err("stale".into())));
        assert!(!state.loading && state.error.is_none());
        let canonical = state.begin(Query {
            project: Some("caf\u{e9}".into()),
            ..Query::default()
        });
        state.query.project = Some("cafe\u{301}".into());
        assert!(state.finish(&canonical, Ok(serde_json::from_value(fixture()).unwrap())));
        let mut integral = fixture();
        integral["totals"]["events"] = json!(1.0);
        assert!(serde_json::from_value::<Snapshot>(integral.clone()).is_ok());
        integral["totals"]["events"] = json!(1.5);
        assert!(serde_json::from_value::<Snapshot>(integral).is_err());
    }

    #[test]
    fn local_tabs_period_and_day_preserve_and_reconcile_selection_like_model() {
        let mut value = fixture();
        let row = |key: &str, total: u64| json!({"key":key,"counters":{"total":total,"inputTotal":1,"hasUnknown":false},"events":1,"sessions":1,"valueMicros":0,"estimated":false,"unpricedModels":[]});
        value["byModel"] = json!([row("café", 2)]);
        value["byProject"] = json!([row("project", 3)]);
        let mut state = State::default();
        let read = state.begin(Query::default());
        assert!(state.finish(&read, Ok(serde_json::from_value(value.clone()).unwrap())));
        state.selected = Some(state.rows()[0].clone());
        assert!(state.set_period(Period::Week));
        assert!(state.query.since.is_some() && state.query.until.is_none());
        assert_eq!(state.selected.as_ref().unwrap().key, "café");
        assert!(!state.set_period(Period::Week));
        let failed = state.begin(state.query.clone());
        assert!(state.finish(&failed, Err("offline".into())));
        assert_eq!(state.selected.as_ref().unwrap().key, "café");
        let read = state.begin(state.query.clone());
        value["byModel"] = json!([row("cafe\u{301}", 9)]);
        assert!(state.finish(&read, Ok(serde_json::from_value(value.clone()).unwrap())));
        assert_eq!(state.selected.as_ref().unwrap().counters.total, 9);
        state.set_tab(Tab::Projects);
        assert!(state.selected.is_none());
        state.selected = Some(state.rows()[0].clone());
        state.set_tab(Tab::Projects);
        assert!(state.selected.is_some());
        assert!(state.focus_day("2026-01-02"));
        assert!(state.selected.is_none());
        assert_eq!(state.query, Query::day("2026-01-02"));
        assert!(!state.focus_day("2026-01-02"));
        state.selected = Some(state.rows()[0].clone());
        assert!(state.clear_focused_day());
        assert!(state.selected.is_some());
        assert!(state.query.since.is_some() && state.query.until.is_none());
        assert!(!state.clear_focused_day());
        let read = state.begin(state.query.clone());
        value["byProject"] = json!([]);
        assert!(state.finish(&read, Ok(serde_json::from_value(value).unwrap())));
        assert!(state.selected.is_none());
    }

    #[cfg(unix)]
    #[test]
    fn superseded_snapshot_does_not_dispatch_after_protocol_setup() {
        use std::{
            io::{BufRead, BufReader, Write},
            os::unix::net::UnixListener,
            sync::mpsc,
        };
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("host.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let (held_tx, held_rx) = mpsc::channel();
        let (resume_tx, resume_rx) = mpsc::channel();
        let server = std::thread::spawn(move || {
            drop(listener.accept().unwrap());
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], "protocol");
            held_tx.send(()).unwrap();
            resume_rx.recv().unwrap();
            writeln!(
                reader.get_mut(),
                "{}",
                json!({"id":request["id"],"ok":true,"result":{"protocolVersion":"53"}})
            )
            .unwrap();
            listener
        });
        let mut state = State::default();
        let first = state.begin(Query::default());
        let worker_read = first.clone();
        let client = crate::client::Client {
            socket,
            allow_spawn: false,
        };
        let worker = std::thread::spawn(move || {
            client.insights_snapshot_if_current(&worker_read.query, || worker_read.is_current())
        });
        held_rx.recv().unwrap();
        let second = state.begin(Query::day("2026-01-02"));
        resume_tx.send(()).unwrap();
        assert!(worker.join().unwrap().is_err());
        assert!(!state.finish(&first, Err("cancelled".into())));
        assert!(state.loading && second.is_current());
        let listener = server.join().unwrap();
        listener.set_nonblocking(true).unwrap();
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
    }

    #[cfg(unix)]
    #[test]
    fn full_snapshot_uses_original_query_envelope_and_validates_required_fields() {
        use std::{
            io::{BufRead, BufReader, Write},
            os::unix::net::UnixListener,
        };
        for valid in [true, false] {
            let dir = tempfile::tempdir().unwrap();
            let socket = dir.path().join("host.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            let worker = std::thread::spawn(move || {
                drop(listener.accept().unwrap());
                for (method, result) in [
                    ("protocol", json!({"protocolVersion":"53"})),
                    (
                        "insights.snapshot",
                        if valid { fixture() } else { json!({"info":{}}) },
                    ),
                ] {
                    let (stream, _) = listener.accept().unwrap();
                    let mut reader = BufReader::new(stream);
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    let request: Value = serde_json::from_str(&line).unwrap();
                    assert_eq!(request["method"], method);
                    if method == "insights.snapshot" {
                        assert_eq!(
                            request["params"],
                            json!({"query":{"since":"2026-01-02","until":"2026-01-02"}})
                        );
                    }
                    writeln!(
                        reader.get_mut(),
                        "{}",
                        json!({"id":request["id"],"ok":true,"result":result})
                    )
                    .unwrap();
                }
            });
            let client = crate::client::Client {
                socket,
                allow_spawn: false,
            };
            assert_eq!(
                client.insights_snapshot(&Query::day("2026-01-02")).is_ok(),
                valid
            );
            worker.join().unwrap();
        }
    }
}
