// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Scope-fenced Home day presentation, shared by the hover card and pinned inspector.

use super::{ActivityScope, HeatCell};
use crate::display;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DayPart {
    pub model: String,
    pub src: String,
    pub fresh: Option<u64>,
    pub cache_read: Option<u64>,
    pub cache_write5m: Option<u64>,
    pub cache_write1h: Option<u64>,
    pub output: Option<u64>,
    pub tokens: u64,
    pub events: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DayDetail {
    pub date: String,
    pub tokens: u64,
    pub events: u64,
    pub value_micros: i64,
    pub estimated: bool,
    pub unpriced_models: Vec<String>,
    pub rows: Vec<DayPart>,
}
impl DayDetail {
    pub fn value(&self) -> String {
        display::money(
            self.value_micros,
            self.estimated,
            self.unpriced_models.is_empty(),
        )
    }
    pub fn counters(&self) -> [Option<u64>; 5] {
        fn fold(rows: &[DayPart], pick: impl Fn(&DayPart) -> Option<u64>) -> Option<u64> {
            rows.iter()
                .filter_map(pick)
                .fold(None, |acc, n| Some(acc.unwrap_or(0_u64).saturating_add(n)))
        }
        [
            fold(&self.rows, |p| p.fresh),
            fold(&self.rows, |p| p.cache_read),
            fold(&self.rows, |p| p.cache_write5m),
            fold(&self.rows, |p| p.cache_write1h),
            fold(&self.rows, |p| p.output),
        ]
    }
    pub fn segments(&self) -> Vec<Segment> {
        let c = self.counters();
        let values = [
            c[1].unwrap_or(0),
            c[2].unwrap_or(0).saturating_add(c[3].unwrap_or(0)),
            c[4].unwrap_or(0),
            c[0].unwrap_or(0),
        ];
        let total = values.iter().fold(0_u64, |a, n| a.saturating_add(*n));
        if total == 0 {
            return Vec::new();
        }
        values
            .into_iter()
            .enumerate()
            .filter(|(_, n)| *n > 0)
            .map(|(kind, value)| Segment { kind, value, total })
            .collect()
    }
    pub fn fixture(day: &HeatCell) -> Option<Self> {
        if day.value == 0 || day.locked {
            return None;
        }
        let rows = vec![
            DayPart {
                model: "claude-opus-4-8".into(),
                src: "claude_code".into(),
                fresh: Some(400),
                cache_read: Some(1000),
                cache_write5m: None,
                cache_write1h: None,
                output: Some(600),
                tokens: 2000,
                events: 2,
            },
            DayPart {
                model: "gpt-6".into(),
                src: "codex".into(),
                fresh: Some(600),
                cache_read: Some(3000),
                cache_write5m: Some(200),
                cache_write1h: Some(0),
                output: Some(400),
                tokens: 4200,
                events: 3,
            },
            DayPart {
                model: "local/model".into(),
                src: "codex".into(),
                fresh: None,
                cache_read: None,
                cache_write5m: None,
                cache_write1h: None,
                output: None,
                tokens: 128,
                events: 1,
            },
        ];
        Some(Self {
            date: day.date.clone(),
            tokens: 6328,
            events: 6,
            value_micros: day.value.min(i64::MAX as u64) as i64,
            estimated: false,
            unpriced_models: vec!["local/model".into()],
            rows,
        })
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct Segment {
    pub kind: usize,
    pub value: u64,
    pub total: u64,
}
impl Segment {
    pub fn width(&self, available: f64) -> f64 {
        (available * self.value as f64 / self.total as f64).max(2.)
    }
    pub fn percent(&self) -> u64 {
        (100. * self.value as f64 / self.total as f64).round() as u64
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ReportCounters {
    pub total: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReportBucket {
    pub key: String,
    pub counters: ReportCounters,
    pub value_micros: i64,
    pub estimated: bool,
    pub unpriced_models: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DayTotals {
    pub sessions: u64,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DayOverview {
    pub totals: Option<DayTotals>,
    pub by_model: Vec<ReportBucket>,
    pub by_source: Vec<ReportBucket>,
    pub by_project: Vec<ReportBucket>,
    pub by_session: Vec<ReportBucket>,
}
impl DayOverview {
    pub fn fixture(detail: &DayDetail) -> Self {
        let bucket = |key: &str, n, value| ReportBucket {
            key: key.into(),
            counters: ReportCounters { total: n },
            value_micros: value,
            estimated: false,
            unpriced_models: Vec::new(),
        };
        Self {
            totals: Some(DayTotals { sessions: 2 }),
            by_model: vec![
                bucket("gpt-6", 4200, detail.value_micros / 2),
                bucket(
                    "claude-opus-4-8",
                    2000,
                    detail.value_micros - detail.value_micros / 2,
                ),
                bucket("local/model", 128, 0),
            ],
            by_source: vec![
                bucket("codex", 4328, detail.value_micros / 2),
                bucket(
                    "claude_code",
                    2000,
                    detail.value_micros - detail.value_micros / 2,
                ),
            ],
            by_project: vec![
                bucket("/fixture/alpha", 4328, 0),
                bucket("/fixture/beta", 2000, 0),
            ],
            by_session: vec![
                bucket("fixture-session-a", 4328, 0),
                bucket("fixture-session-b", 2000, 0),
            ],
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct GroupRow {
    pub key: String,
    pub label: String,
    pub tokens: u64,
    pub value: Option<String>,
    pub monospaced: bool,
}
fn bucket_row(bucket: &ReportBucket, label: String, monospaced: bool) -> GroupRow {
    GroupRow {
        key: bucket.key.clone(),
        label: if label.is_empty() {
            crate::localization::text("apple.homeinspector.unknown.b23a6a84", &[])
        } else {
            label
        },
        tokens: bucket.counters.total,
        value: Some(display::money(
            bucket.value_micros,
            bucket.estimated,
            bucket.unpriced_models.is_empty(),
        )),
        monospaced,
    }
}
pub fn bucket_rows(buckets: &[ReportBucket]) -> Vec<GroupRow> {
    buckets
        .iter()
        .map(|b| bucket_row(b, b.key.clone(), true))
        .collect()
}
fn fold(parts: &[DayPart], tool: bool) -> Vec<GroupRow> {
    let mut out: Vec<GroupRow> = Vec::new();
    for part in parts {
        let key = if tool {
            display::harness_key(&part.src)
        } else {
            &part.model
        };
        if let Some(row) = out.iter_mut().find(|r| r.key == key) {
            row.tokens = row.tokens.saturating_add(part.tokens);
        } else {
            out.push(GroupRow {
                key: key.into(),
                label: if tool {
                    display::harness_name(key)
                } else {
                    display::short_model(key)
                },
                tokens: part.tokens,
                value: None,
                monospaced: !tool,
            });
        }
    }
    out.sort_by_key(|a| std::cmp::Reverse(a.tokens));
    out
}
pub fn model_rows(
    detail: &DayDetail,
    extra: Option<&DayOverview>,
    unpriced: bool,
) -> Vec<GroupRow> {
    let rows = if let Some(extra) = extra.filter(|e| !e.by_model.is_empty()) {
        extra
            .by_model
            .iter()
            .map(|b| bucket_row(b, display::short_model(&b.key), true))
            .collect()
    } else {
        fold(&detail.rows, false)
    };
    let matches = |row: &GroupRow, name: &str| {
        row.key == name || row.label == name || row.label == display::short_model(name)
    };
    if !unpriced {
        return rows
            .into_iter()
            .filter(|r| !detail.unpriced_models.iter().any(|name| matches(r, name)))
            .collect();
    }
    detail
        .unpriced_models
        .iter()
        .map(|name| {
            let existing = rows.iter().find(|r| matches(r, name));
            GroupRow {
                key: name.clone(),
                label: existing
                    .map(|r| r.label.clone())
                    .unwrap_or_else(|| display::short_model(name)),
                tokens: existing.map(|r| r.tokens).unwrap_or_else(|| {
                    detail
                        .rows
                        .iter()
                        .filter(|p| &p.model == name)
                        .fold(0_u64, |a, p| a.saturating_add(p.tokens))
                }),
                value: None,
                monospaced: true,
            }
        })
        .collect()
}
pub fn harness_rows(detail: &DayDetail, extra: Option<&DayOverview>) -> Vec<GroupRow> {
    if let Some(extra) = extra.filter(|e| !e.by_source.is_empty()) {
        extra
            .by_source
            .iter()
            .map(|b| bucket_row(b, display::harness_name(&b.key), false))
            .collect()
    } else {
        fold(&detail.rows, true)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
#[derive(Clone, Debug, PartialEq)]
pub struct HoverAnchor {
    pub date: String,
    pub rect: Rect,
}
#[derive(Clone, Copy, Debug, Serialize)]
pub struct PopoverGeometry {
    pub width: f64,
    pub height: f64,
    pub center_x: f64,
    pub center_y: f64,
}
impl PopoverGeometry {
    pub fn new(anchor: Option<Rect>, window_width: f64, window_height: f64) -> Self {
        let width = 320_f64.min(240_f64.max(window_width - 32.));
        let height = 330_f64.min(180_f64.max(window_height - 32.));
        let Some(a) = anchor else {
            return Self {
                width,
                height,
                center_x: window_width / 2.,
                center_y: window_height / 2.,
            };
        };
        let left = a.x + a.width / 2. > window_width * 0.5;
        let candidate = if left {
            a.x - 8. - width / 2.
        } else {
            a.x + a.width + 8. + width / 2.
        };
        let flipped = if left {
            a.x + a.width + 8. + width / 2.
        } else {
            a.x - 8. - width / 2.
        };
        let x = if candidate - width / 2. >= 16. && candidate + width / 2. <= window_width - 16. {
            candidate
        } else {
            flipped
        };
        let min_x = 16. + width / 2.;
        let min_y = 16. + height / 2.;
        Self {
            width,
            height,
            center_x: x
                .max(min_x)
                .min((window_width - 16. - width / 2.).max(min_x)),
            center_y: (a.y + a.height / 2.)
                .max(min_y)
                .min((window_height - 16. - height / 2.).max(min_y)),
        }
    }
}

#[derive(Clone, Debug)]
pub struct Reading<T> {
    pub date: Option<String>,
    pub value: Option<T>,
    pub loading: bool,
    pub error: Option<String>,
}
impl<T> Default for Reading<T> {
    fn default() -> Self {
        Self {
            date: None,
            value: None,
            loading: false,
            error: None,
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Selected,
    Hover,
    Overview,
}
#[derive(Clone, Debug)]
pub struct DayRequest {
    epoch: u64,
    generation: u64,
    kind: Kind,
    pub date: String,
    pub scope: ActivityScope,
}
#[derive(Debug, Default)]
pub struct DayState {
    pub selected: Reading<DayDetail>,
    pub hovered: Reading<DayDetail>,
    pub overview: Reading<DayOverview>,
    epoch: u64,
    selected_generation: u64,
    hover_generation: u64,
    overview_generation: u64,
    cache: HashMap<String, DayDetail>,
    overview_cache: HashMap<String, DayOverview>,
    scope: Option<ActivityScope>,
}
impl DayState {
    pub fn invalidate(&mut self, keep_selected: bool) {
        self.epoch = self.epoch.wrapping_add(1);
        self.cache.clear();
        self.overview_cache.clear();
        self.scope = None;
        self.clear_hover();
        if keep_selected {
            self.selected.loading |= self.selected.value.is_some();
            self.overview.loading |= self.overview.value.is_some();
        } else {
            self.selected = Reading::default();
            self.overview = Reading::default();
        }
    }
    pub fn clear_hover(&mut self) {
        self.hover_generation = self.hover_generation.wrapping_add(1);
        self.hovered = Reading::default();
    }
    fn adopt_scope(&mut self, scope: ActivityScope) {
        if self.scope.is_some_and(|previous| previous != scope) {
            self.invalidate(false);
        }
        self.scope = Some(scope);
    }
    pub fn begin_selected(&mut self, day: &HeatCell, scope: ActivityScope) -> Option<DayRequest> {
        self.adopt_scope(scope);
        self.selected_generation = self.selected_generation.wrapping_add(1);
        let same = self.selected.date.as_deref() == Some(&day.date);
        self.selected.date = Some(day.date.clone());
        self.selected.error = None;
        if day.locked {
            self.selected.value = None;
            self.selected.loading = false;
            return None;
        }
        if let Some(cached) = self.cache.get(&day.date) {
            self.selected.value = Some(cached.clone());
            self.selected.loading = false;
            return None;
        }
        if !same {
            self.selected.value = None;
        }
        self.selected.loading = true;
        Some(DayRequest {
            epoch: self.epoch,
            generation: self.selected_generation,
            kind: Kind::Selected,
            date: day.date.clone(),
            scope,
        })
    }
    pub fn begin_hover(
        &mut self,
        day: Option<&HeatCell>,
        scope: ActivityScope,
    ) -> Option<DayRequest> {
        self.adopt_scope(scope);
        let day = day.filter(|d| d.value > 0 && !d.locked);
        if self.hovered.date.as_deref() == day.map(|d| d.date.as_str()) {
            return None;
        }
        self.clear_hover();
        let day = day?;
        self.hovered.date = Some(day.date.clone());
        if let Some(cached) = self.cache.get(&day.date) {
            self.hovered.value = Some(cached.clone());
            return None;
        }
        self.hovered.loading = true;
        Some(DayRequest {
            epoch: self.epoch,
            generation: self.hover_generation,
            kind: Kind::Hover,
            date: day.date.clone(),
            scope,
        })
    }
    pub fn begin_overview(&mut self, day: &HeatCell, scope: ActivityScope) -> Option<DayRequest> {
        self.adopt_scope(scope);
        self.overview_generation = self.overview_generation.wrapping_add(1);
        if scope != ActivityScope::ThisMachine || day.locked {
            self.overview = Reading::default();
            return None;
        }
        let same = self.overview.date.as_deref() == Some(&day.date);
        self.overview.date = Some(day.date.clone());
        self.overview.error = None;
        if let Some(cached) = self.overview_cache.get(&day.date) {
            self.overview.value = Some(cached.clone());
            self.overview.loading = false;
            return None;
        }
        if !same {
            self.overview.value = None;
        }
        self.overview.loading = true;
        Some(DayRequest {
            epoch: self.epoch,
            generation: self.overview_generation,
            kind: Kind::Overview,
            date: day.date.clone(),
            scope,
        })
    }
    pub fn is_current(&self, r: &DayRequest) -> bool {
        r.epoch == self.epoch
            && self.scope == Some(r.scope)
            && r.generation
                == match r.kind {
                    Kind::Selected => self.selected_generation,
                    Kind::Hover => self.hover_generation,
                    Kind::Overview => self.overview_generation,
                }
    }
    pub fn finish_detail(
        &mut self,
        r: &DayRequest,
        result: Result<Option<DayDetail>, String>,
    ) -> bool {
        if r.kind == Kind::Overview || !self.is_current(r) {
            return false;
        }
        let result = result.and_then(|detail| {
            if detail.as_ref().is_some_and(|d| d.date != r.date) {
                Err("The host returned a different day".into())
            } else {
                Ok(detail)
            }
        });
        let (value, error) = match result {
            Ok(value) => (value, None),
            Err(error) => (None, Some(error)),
        };
        if let Some(detail) = &value {
            self.cache.insert(r.date.clone(), detail.clone());
        }
        for reading in [&mut self.selected, &mut self.hovered] {
            if reading.date.as_deref() == Some(&r.date) {
                reading.value = value.clone();
                reading.error = error.clone();
                reading.loading = false;
            }
        }
        true
    }
    pub fn finish_overview(&mut self, r: &DayRequest, result: Result<DayOverview, String>) -> bool {
        if r.kind != Kind::Overview || !self.is_current(r) {
            return false;
        }
        self.overview.loading = false;
        match result {
            Ok(value) => {
                self.overview_cache.insert(r.date.clone(), value.clone());
                self.overview.value = Some(value);
                self.overview.error = None;
            }
            Err(e) => self.overview.error = Some(e),
        }
        true
    }
}

#[cfg(unix)]
impl crate::client::Client {
    pub fn day_detail(
        &self,
        date: &str,
        scope: ActivityScope,
    ) -> anyhow::Result<Option<DayDetail>> {
        self.prepare()?;
        let detail: Option<DayDetail> = serde_json::from_value(self.call(
            "activity.day",
            serde_json::json!({"date":date,"scope":scope.wire(),"weeks":53}),
        )?)?;
        anyhow::ensure!(
            detail.as_ref().is_none_or(|d| d.date == date),
            "The host returned a different day"
        );
        Ok(detail)
    }
    pub fn day_overview(&self, date: &str) -> anyhow::Result<DayOverview> {
        self.prepare()?;
        std::thread::scope(|scope| {
            let handles: Vec<_> = ["totals", "model", "source", "project", "session"]
                .into_iter()
                .map(|group| {
                    scope.spawn(move || {
                        let mut query = serde_json::json!({"since":date,"until":date});
                        if group == "session" {
                            query["limit"] = 80.into();
                        }
                        let (method, params) = if group == "totals" {
                            ("totals", serde_json::json!({"query":query}))
                        } else {
                            ("report", serde_json::json!({"group":group,"query":query}))
                        };
                        (group, self.call(method, params))
                    })
                })
                .collect();
            let mut out = DayOverview::default();
            for handle in handles {
                if let Ok((group, Ok(value))) = handle.join() {
                    match group {
                        "totals" => out.totals = serde_json::from_value(value).ok(),
                        "model" => out.by_model = serde_json::from_value(value).unwrap_or_default(),
                        "source" => {
                            out.by_source = serde_json::from_value(value).unwrap_or_default()
                        }
                        "project" => {
                            out.by_project = serde_json::from_value(value).unwrap_or_default()
                        }
                        "session" => {
                            out.by_session = serde_json::from_value(value).unwrap_or_default()
                        }
                        _ => {}
                    }
                }
            }
            Ok(out)
        })
    }
}

#[cfg(test)]
mod tests;
