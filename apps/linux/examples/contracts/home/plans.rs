// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde_json::{Value, json};
use tokenstat_linux::{
    display,
    home::plans::{self, LimitsSync, Provider, Severity, UsageWindow, store::Store},
};

pub fn snapshot() -> Value {
    let mut windows = Vec::new();
    for scope in [
        None,
        Some("primary"),
        Some("PRIMARY"),
        Some("secondary"),
        Some("current model"),
        Some("Current Model"),
        Some("general"),
        Some(""),
    ] {
        for percent in [-10., -0.5, 0., 0.5, 42.49, 42.5, 84., 98.5, 100., 104.] {
            let window = UsageWindow {
                label: "weekly".into(),
                scope: scope.map(str::to_owned),
                percent,
                resets_at_ms: Some(1_800_000_000_000),
                severity: Severity::Normal,
            };
            windows.push(json!({"input":window,"label":window.display_label(),"fraction":window.fraction(),"percent":window.percent_text()}));
        }
    }
    let colors = [Severity::Normal, Severity::Warning, Severity::Critical].map(|s| {
        let c = s.tint();
        json!({"severity":s,"light":[c.light.0,c.light.1],"dark":[c.dark.0,c.dark.1]})
    });
    let mut providers = Vec::new();
    let window = plans::fixture_cache(1_800_000_000_000).providers[0]
        .windows
        .clone();
    for note in [
        None,
        Some(""),
        Some("Not Found"),
        Some("NOT RUNNING"),
        Some("No sessions"),
        Some("no cursor session"),
        Some("no opencode"),
        Some("no antigravity"),
        Some("no codex"),
        Some("not signed in"),
        Some("no claude code"),
        Some("no home directory"),
        Some("rate limited"),
        Some("Authentication expired"),
    ] {
        for populated in [false, true] {
            for stale in [None, Some(false), Some(true)] {
                let provider = Provider {
                    source: "codex".into(),
                    plan: None,
                    windows: if populated { window.clone() } else { vec![] },
                    observed_at_ms: if populated { 1_800_000_000_000 } else { 0 },
                    note: note.map(str::to_owned),
                    stale,
                };
                providers.push(json!({"input":provider,"visible":provider.visible(),"stale":provider.is_stale(),"nextReset":provider.next_reset_ms(),"observed":provider.observed_at_ms > 0}));
            }
        }
    }
    let mut ordered = plans::fixture_cache(1_800_000_000_000);
    let base = ordered.providers[0].clone();
    ordered.providers = [
        "zeta",
        "antigravity",
        "cursor",
        "claude_code",
        "opencode",
        "muse",
        "grok",
        "codex",
        "alpha",
    ]
    .map(|s| Provider {
        source: s.into(),
        ..base.clone()
    })
    .into();
    ordered.skip = vec!["cursor".into()];
    let mut store = Store::default();
    store.settings_changed(0, ordered.clone());
    let ordering = json!({"input":ordered,"visible":store.visible(0).into_iter().map(|p|p.source.clone()).collect::<Vec<_>>()});
    let mut columns = Vec::new();
    for width in [0., 320., 600., 667., 668., 1006., 2000.] {
        for count in [0, 1, 3, 8] {
            for panel_width in [330., 297.] {
                columns.push(json!({"width":width,"count":count,"panelWidth":panel_width,"columns":plans::columns(width,count,panel_width)}));
            }
        }
    }
    let cache: Vec<_> = [
        json!({}),
        json!({"enabled":null,"skip":null,"providers":null}),
        json!({"enabled":true,"skip":["codex"]}),
    ]
    .map(|input| {
        let state: LimitsSync = serde_json::from_value(input.clone()).unwrap();
        json!({"input":input,"enabled":state.enabled,"skip":state.skip,"providers":state.providers})
    })
    .into();
    let capitalized = [
        "plus",
        "MAX",
        "pro+",
        "team plan",
        "gpt-5 pro",
        "o'NEILL",
        "l’été",
        "straße",
        "iOS enterprise",
        "123PRO",
    ]
    .map(|s| json!({"input":s,"text":display::capitalized(s)}));
    json!({"windows":windows,"colors":colors,"providers":providers,"ordering":ordering,"columns":columns,"cache":cache,"capitalized":capitalized})
}
