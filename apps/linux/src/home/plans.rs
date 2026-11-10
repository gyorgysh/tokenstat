// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Vendor quota readings remain separate from archive subscription usage.
//! Source: PlanLimitsStore, PlanLimitsCard and HomeModel.

pub mod store;

use super::day::ReportBucket;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::time::Duration;
use store::{Flight, Refresh, RefreshError, Store};

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Normal,
    Warning,
    Critical,
}
impl Severity {
    pub fn tint(self) -> crate::design::AdaptiveColor {
        use crate::design::AdaptiveColor;
        match self {
            Self::Normal => crate::design::palette::ACCENT,
            // Current SwiftUI semantic colours, measured by the compiled
            // source contract in both appearances; not Theme.warning/danger.
            Self::Warning => AdaptiveColor::new(0xFF8D28, 1., 0xFF9230, 1.),
            Self::Critical => AdaptiveColor::new(0xFF383C, 1., 0xFF4245, 1.),
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageWindow {
    pub label: String,
    pub scope: Option<String>,
    pub percent: f64,
    pub resets_at_ms: Option<i64>,
    pub severity: Severity,
}
impl UsageWindow {
    pub fn display_label(&self) -> String {
        let key = match self.scope.as_deref().map(str::to_lowercase).as_deref() {
            None => return self.label.clone(),
            Some("secondary") => "apple.models.0_all_models.31683c25",
            Some("primary") => "apple.models.0_primary.57ab87b8",
            Some("current model") => "apple.models.0_secondary.6cd2b67a",
            _ => {
                return format!(
                    "{} ({})",
                    self.label,
                    self.scope.as_deref().unwrap_or_default()
                );
            }
        };
        crate::localization::text(key, &[&self.label])
    }
    pub fn fraction(&self) -> f64 {
        (self.percent / 100.).clamp(0., 1.)
    }
    pub fn percent_text(&self) -> String {
        let value = self.percent.round();
        if value == 0. {
            "0%".into()
        } else {
            format!("{value:.0}%")
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Provider {
    pub source: String,
    pub plan: Option<String>,
    pub windows: Vec<UsageWindow>,
    pub observed_at_ms: i64,
    pub note: Option<String>,
    pub stale: Option<bool>,
}
impl Provider {
    pub fn is_stale(&self) -> bool {
        self.stale == Some(true)
    }
    pub fn visible(&self) -> bool {
        !self.windows.is_empty()
            || self
                .note
                .as_deref()
                .is_some_and(|n| !is_absent(&n.to_lowercase()))
    }
    pub fn next_reset_ms(&self) -> Option<i64> {
        self.windows.iter().filter_map(|w| w.resets_at_ms).min()
    }
}
pub fn is_absent(note: &str) -> bool {
    [
        "not found",
        "not running",
        "no sessions",
        "no cursor session",
        "no opencode",
        "no antigravity",
        "no codex",
        "not signed in",
        "no claude code",
        "no home directory",
    ]
    .iter()
    .any(|p| note.contains(p))
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct LimitsSync {
    #[serde(deserialize_with = "super::optional_bool")]
    pub enabled: bool,
    #[serde(deserialize_with = "nullable_vec")]
    pub skip: Vec<String>,
    #[serde(deserialize_with = "nullable_vec")]
    pub providers: Vec<Provider>,
}
fn nullable_vec<'de, D, T>(deserializer: D) -> Result<Vec<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    Ok(Option::<Vec<T>>::deserialize(deserializer)?.unwrap_or_default())
}

fn source_order(source: &str) -> (usize, &str) {
    (
        [
            "codex",
            "claude_code",
            "cursor",
            "grok",
            "muse",
            "opencode",
            "antigravity",
        ]
        .iter()
        .position(|s| *s == source)
        .unwrap_or(7),
        source,
    )
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Request {
    reader: Reader,
    generation: u64,
    owner: u64,
}
#[derive(Clone, Debug, Default)]
pub struct Plans {
    pub by_source: Vec<ReportBucket>,
    pub limits_loading: bool,
    pub usage_loading: bool,
    pub has_loaded: bool,
    pub limits_error: Option<String>,
    pub usage_error: Option<String>,
    generation: u64,
    pub last_loaded_ms: Option<i64>,
}
/// One shared vendor flight can have multiple independently retired Home
/// readers. Hiding Home never cancels the store's flight or another waiter.
#[derive(Clone, Debug, Default)]
pub struct Reads {
    homes: BTreeMap<Reader, Plans>,
    next_reader: u64,
    fixture_now: Option<i64>,
    pub store: Store,
    owner: u64,
    waiters: BTreeMap<Flight, Vec<Request>>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Reader(u64);

#[derive(Clone, Copy, Debug)]
pub struct HomeLoad {
    pub request: Request,
    pub refresh: Refresh,
}
impl Reads {
    pub fn register(&mut self) -> Reader {
        self.next_reader = self.next_reader.wrapping_add(1);
        let reader = Reader(self.next_reader);
        self.homes.insert(
            reader,
            self.fixture_now.map(Plans::fixture).unwrap_or_default(),
        );
        reader
    }
    pub fn release(&mut self, reader: Reader) {
        self.homes.remove(&reader);
        self.waiters.retain(|_, waiters| {
            waiters.retain(|r| r.reader != reader);
            !waiters.is_empty()
        });
    }
    pub fn home(&self, reader: Reader) -> &Plans {
        self.homes.get(&reader).expect("live Home reader")
    }
    pub fn hide(&mut self, reader: Reader) {
        if let Some(home) = self.homes.get_mut(&reader) {
            home.hide();
        }
    }
    pub fn hide_all(&mut self) {
        self.homes.values_mut().for_each(Plans::hide);
    }
    pub fn owner(&self) -> u64 {
        self.owner
    }
    pub fn set_owner(&mut self, owner: u64) {
        if self.owner != owner {
            self.owner = owner;
            self.fixture_now = None;
            self.homes.values_mut().for_each(Plans::reset_owner);
        }
    }
    pub fn visible(&self) -> Vec<&Provider> {
        self.store.visible(self.owner)
    }
    pub fn state(&self) -> Option<&LimitsSync> {
        self.store.state(self.owner)
    }
    pub fn begin_home(
        &mut self,
        reader: Reader,
        force: bool,
        now_ms: i64,
        visible: bool,
    ) -> Option<HomeLoad> {
        let request = self
            .homes
            .get_mut(&reader)?
            .begin(reader, force, now_ms, visible, self.owner)?;
        let refresh = self.store.begin(self.owner, force, now_ms);
        match refresh {
            Refresh::Start(flight) | Refresh::Join(flight) => {
                self.waiters.entry(flight).or_default().push(request)
            }
            Refresh::Ready => {
                self.homes
                    .get_mut(&reader)?
                    .finish_limits(request, self.owner, Ok(()), now_ms);
            }
        }
        Some(HomeLoad { request, refresh })
    }
    pub fn accept_cache(&mut self, flight: Flight, cache: LimitsSync) -> bool {
        self.store.accept_cache(flight, self.owner, cache)
    }
    pub fn finish_limits(
        &mut self,
        flight: Flight,
        result: Result<Vec<Provider>, RefreshError>,
        now_ms: i64,
    ) {
        let result = self.store.finish(flight, self.owner, result);
        for request in self.waiters.remove(&flight).unwrap_or_default() {
            if let Some(home) = self.homes.get_mut(&request.reader) {
                home.finish_limits(request, self.owner, result.clone(), now_ms);
            }
        }
    }
    pub fn finish_usage(
        &mut self,
        request: Request,
        result: Result<Vec<ReportBucket>, String>,
    ) -> bool {
        self.homes
            .get_mut(&request.reader)
            .is_some_and(|home| home.finish_usage(request, self.owner, result))
    }
    pub fn fixture(now_ms: i64) -> Self {
        Self::fixture_for_owner(now_ms, 0)
    }
    pub fn fixture_for_owner(now_ms: i64, owner: u64) -> Self {
        let mut reads = Self {
            fixture_now: Some(now_ms),
            owner,
            ..Self::default()
        };
        reads.store.settings_changed(owner, fixture_cache(now_ms));
        reads
    }
}
impl Plans {
    pub fn loading(&self) -> bool {
        self.limits_loading || self.usage_loading
    }
    pub fn error(&self) -> Option<&str> {
        self.limits_error.as_deref().or(self.usage_error.as_deref())
    }
    pub fn begin(
        &mut self,
        reader: Reader,
        force: bool,
        now_ms: i64,
        visible: bool,
        owner: u64,
    ) -> Option<Request> {
        if !visible || self.loading() {
            return None;
        }
        if !force
            && self
                .last_loaded_ms
                .is_some_and(|last| now_ms.saturating_sub(last) < 60_000)
        {
            return None;
        }
        self.generation = self.generation.wrapping_add(1);
        self.limits_loading = true;
        self.usage_loading = true;
        Some(Request {
            reader,
            generation: self.generation,
            owner,
        })
    }
    pub fn current(&self, r: Request, owner: u64) -> bool {
        r.generation == self.generation && r.owner == owner
    }
    /// Layout/context changes retire delivery; keep the last readings for a
    /// later visible card, as the source model does.
    pub fn hide(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.limits_loading = false;
        self.usage_loading = false;
        self.limits_error = None;
        self.usage_error = None;
    }
    pub fn reset_owner(&mut self) {
        let generation = self.generation.wrapping_add(1);
        *self = Self {
            generation,
            ..Self::default()
        };
    }
    pub fn finish_limits(
        &mut self,
        r: Request,
        owner: u64,
        result: Result<(), RefreshError>,
        now_ms: i64,
    ) -> bool {
        if !self.current(r, owner) {
            return false;
        }
        self.limits_loading = false;
        match result {
            Ok(()) => {
                self.has_loaded = true;
                self.last_loaded_ms = Some(now_ms);
                self.limits_error = None;
            }
            Err(RefreshError::Failed(error)) => self.limits_error = Some(error),
            Err(RefreshError::Retired) => {}
        }
        true
    }
    pub fn finish_usage(
        &mut self,
        r: Request,
        owner: u64,
        result: Result<Vec<ReportBucket>, String>,
    ) -> bool {
        if !self.current(r, owner) {
            return false;
        }
        self.usage_loading = false;
        match result {
            Ok(rows) => {
                self.by_source = rows;
                self.usage_error = None
            }
            Err(e) => self.usage_error = Some(e),
        }
        true
    }
    pub fn fixture(now_ms: i64) -> Self {
        Self {
            by_source: vec![
                ReportBucket {
                    key: "codex".into(),
                    counters: super::day::ReportCounters { total: 125_000 },
                    value_micros: 0,
                    estimated: false,
                    unpriced_models: vec![],
                },
                ReportBucket {
                    key: "claude_code".into(),
                    counters: super::day::ReportCounters { total: 2_000_000 },
                    value_micros: 0,
                    estimated: false,
                    unpriced_models: vec![],
                },
            ],
            has_loaded: true,
            last_loaded_ms: Some(now_ms),
            ..Self::default()
        }
    }
}
/// Synthetic vendor input shared by fixtures and source-contract tests.
pub fn fixture_cache(now_ms: i64) -> LimitsSync {
    LimitsSync {
        providers: vec![
            Provider {
                source: "codex".into(),
                plan: Some("plus".into()),
                observed_at_ms: now_ms - 120_000,
                note: None,
                stale: None,
                windows: vec![
                    UsageWindow {
                        label: "5-hour".into(),
                        scope: Some("primary".into()),
                        percent: 42.,
                        resets_at_ms: Some(now_ms + 7_200_000),
                        severity: Severity::Normal,
                    },
                    UsageWindow {
                        label: "weekly".into(),
                        scope: Some("secondary".into()),
                        percent: 84.,
                        resets_at_ms: Some(now_ms + 86_400_000),
                        severity: Severity::Warning,
                    },
                ],
            },
            Provider {
                source: "claude_code".into(),
                plan: Some("max".into()),
                observed_at_ms: now_ms - 3_600_000,
                note: Some("Synthetic fixture: the latest vendor read failed.".into()),
                stale: Some(true),
                windows: vec![UsageWindow {
                    label: "weekly".into(),
                    scope: None,
                    percent: 98.5,
                    resets_at_ms: Some(now_ms + 259_200_000),
                    severity: Severity::Critical,
                }],
            },
        ],
        ..LimitsSync::default()
    }
}
pub fn columns(width: f64, panel_count: usize, panel_width: f64) -> usize {
    let fits = ((width + 8.) / (panel_width + 8.)).trunc() as i64;
    (panel_count as i64).min(fits).max(1) as usize
}
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|n| n.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}

#[cfg(unix)]
impl crate::client::Client {
    pub fn plan_cache(&self) -> anyhow::Result<LimitsSync> {
        self.prepare()?;
        Ok(serde_json::from_value(
            self.call("config.limitsSync", serde_json::json!({}))?,
        )?)
    }
    pub fn plan_limits(&self, force: bool) -> anyhow::Result<Vec<Provider>> {
        self.prepare()?;
        Ok(serde_json::from_value(self.call_with_timeout(
            "usage.limits",
            serde_json::json!({"force":force}),
            Duration::from_secs(600),
        )?)?)
    }
    pub fn plan_usage(&self) -> anyhow::Result<Vec<ReportBucket>> {
        self.prepare()?;
        Ok(serde_json::from_value(self.call(
            "report",
            serde_json::json!({"group":"source","query":{"billing":"plan"}}),
        )?)?)
    }
}

#[cfg(test)]
#[path = "plans/tests.rs"]
mod tests;
