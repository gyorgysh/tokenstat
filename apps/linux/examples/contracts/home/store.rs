// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde_json::{Value, json};
use tokenstat_linux::{
    account_state::LoginOwner,
    desktop_data::Account,
    home::plans::{
        LimitsSync, Provider, Severity, UsageWindow,
        store::{Flight, Refresh, RefreshError, Store},
    },
};

fn provider(reading: f64, observed: i64) -> Provider {
    Provider {
        source: "claude_code".into(),
        plan: None,
        windows: vec![UsageWindow {
            label: "weekly".into(),
            scope: None,
            percent: reading,
            resets_at_ms: None,
            severity: Severity::Normal,
        }],
        observed_at_ms: observed,
        note: None,
        stale: None,
    }
}
struct Reference {
    store: Store,
    owner: u64,
    now: i64,
    cache: LimitsSync,
    cache_calls: u64,
    live_calls: u64,
}
impl Reference {
    fn begin(&mut self, force: bool) -> Refresh {
        let refresh = self.store.begin(self.owner, force, self.now);
        if let Refresh::Start(flight) = refresh {
            self.cache_calls += 1;
            assert!(
                self.store
                    .accept_cache(flight, self.owner, self.cache.clone())
            );
            self.live_calls += 1;
        }
        refresh
    }
    fn start(&mut self, force: bool) -> Flight {
        let Refresh::Start(flight) = self.begin(force) else {
            panic!("expected a new flight")
        };
        flight
    }
    fn row(&self, label: &str) -> Value {
        let state = self.store.state(self.owner);
        json!({"label":label,"owner":self.owner,"cacheCalls":self.cache_calls,"liveCalls":self.live_calls,
            "enabled":state.is_some_and(|s|s.enabled),"skip":state.map(|s|s.skip.clone()).unwrap_or_default(),"refreshing":self.store.is_refreshing(self.owner),
            "providers":self.store.providers(self.owner).into_iter().map(|p|json!({"source":p.source,"percent":p.windows[0].percent,"stale":p.is_stale(),"observed":p.observed_at_ms})).collect::<Vec<_>>()})
    }
}
pub fn snapshot() -> Value {
    let mut h = Reference {
        store: Store::default(),
        owner: 1,
        now: 1_000_000,
        cache: LimitsSync {
            providers: vec![provider(1., 1)],
            ..LimitsSync::default()
        },
        cache_calls: 0,
        live_calls: 0,
    };
    let mut rows = vec![h.row("initial")];
    let first = h.start(false);
    rows.push(h.row("cached"));
    assert_eq!(h.begin(true), Refresh::Join(first));
    rows.push(h.row("joined"));
    h.store
        .finish(first, h.owner, Ok(vec![provider(2., 2)]))
        .unwrap();
    rows.push(h.row("live-after-one-waiter-cancels"));
    assert_eq!(h.begin(false), Refresh::Ready);
    rows.push(h.row("throttled"));
    let old = h.start(true);
    rows.push(h.row("retained-during-refresh"));
    h.owner = 2;
    rows.push(h.row("owner-retired"));
    let current = h.start(false);
    rows.push(h.row("new-owner-cache"));
    assert_eq!(
        h.store.finish(old, h.owner, Ok(vec![provider(99., 99)])),
        Err(RefreshError::Retired)
    );
    rows.push(h.row("late-owner-reply"));
    h.store
        .finish(current, h.owner, Ok(vec![provider(3., 2)]))
        .unwrap();
    rows.push(h.row("new-owner-live"));
    h.now += 31_000;
    let failed = h.start(false);
    rows.push(h.row("pending-failure"));
    h.store
        .finish(failed, h.owner, Err(RefreshError::Failed("offline".into())))
        .unwrap_err();
    rows.push(h.row("failed-retains-live"));
    assert_eq!(h.begin(false), Refresh::Ready);
    rows.push(h.row("failed-attempt-throttled"));
    let before_edit = h.start(true);
    rows.push(h.row("pending-settings-edit"));
    let read = h.store.settings_read(h.owner);
    h.cache.enabled = true;
    h.cache.skip = vec!["claude_code".into()];
    h.store.settings_changed(h.owner, h.cache.clone());
    rows.push(h.row("settings-retire-flight"));
    assert!(
        !h.store
            .accept_cached_settings(h.owner, read, LimitsSync::default())
    );
    rows.push(h.row("late-settings-cache"));
    assert_eq!(
        h.store
            .finish(before_edit, h.owner, Ok(vec![provider(99., 99)])),
        Err(RefreshError::Retired)
    );
    rows.push(h.row("late-settings-vendor"));
    h.cache.providers = vec![provider(4., 3)];
    h.store
        .accept_cached_settings(h.owner, h.store.settings_read(h.owner), h.cache.clone());
    rows.push(h.row("newer-background-cache"));
    let cancelled = h.start(false);
    rows.push(h.row("pending-cancelled-read"));
    h.store
        .finish(cancelled, h.owner, Err(RefreshError::Retired))
        .unwrap_err();
    rows.push(h.row("cancel-does-not-mark-stale"));
    let old_read = h.store.settings_read(h.owner);
    h.owner = 3;
    assert!(
        !h.store
            .accept_cached_settings(h.owner, old_read, h.cache.clone())
    );
    rows.push(h.row("settings-owner-retired"));
    h.store
        .accept_cached_settings(h.owner, h.store.settings_read(h.owner), h.cache.clone());
    rows.push(h.row("new-owner-settings"));
    json!({"transcript":rows,"owners":owner_snapshot()})
}
fn owner_snapshot() -> Vec<Value> {
    let mut owner = LoginOwner::default();
    let mut inputs = vec![Value::Null];
    let base = json!({"machines":[],"signedIn":false,"host":"https://fixture.invalid","handle":null,"accountId":null,"accountSession":"local:1"});
    inputs.extend([base.clone(), base.clone()]);
    let mut account = base;
    account["signedIn"] = json!(true);
    account["accountId"] = json!("id-alice");
    account["accountSession"] = json!("helper:login-one");
    inputs.extend([account.clone(), account.clone()]);
    account["handle"] = json!("\u{200b}\n ");
    inputs.push(account.clone());
    account["handle"] = json!("alice");
    inputs.push(account.clone());
    account["accountSession"] = Value::Null;
    inputs.push(account.clone());
    account["displayName"] = json!("Alice Changed Name");
    inputs.push(account.clone());
    account["accountSession"] = json!("helper:login-two");
    inputs.push(account.clone());
    account["accountSession"] = json!("restarted:login-two");
    inputs.push(account.clone());
    account["host"] = json!("https://other.invalid");
    inputs.push(account.clone());
    account["accountSession"] = Value::Null;
    inputs.push(account.clone());
    account["handle"] = Value::Null;
    account["accountId"] = Value::Null;
    inputs.push(account.clone());
    inputs.push(Value::Null);
    account["signedIn"] = json!(true);
    account["host"] = json!("https://fixture.invalid");
    account["handle"] = json!("café");
    account["accountSession"] = json!("ticket:é");
    inputs.push(account.clone());
    account["handle"] = json!("cafe\u{301}");
    account["accountSession"] = json!("ticket:e\u{301}");
    inputs.push(account.clone());
    account["host"] = json!("HTTPS://FIXTURE.INVALID:443/");
    account["accountSession"] = Value::Null;
    inputs.push(account.clone());
    account["host"] = json!("file:///not-an-account");
    inputs.push(account.clone());
    account["signedIn"] = json!(false);
    inputs.push(account.clone());
    account["host"] = json!("http://localhost:8400");
    inputs.push(account.clone());
    account["accountSession"] = json!("local:two");
    inputs.push(account.clone());
    inputs.push(Value::Null);
    inputs
        .into_iter()
        .map(|input| {
            let account = if input.is_null() {
                None
            } else {
                Some(serde_json::from_value::<Account>(input.clone()).unwrap())
            };
            owner.update(account.as_ref());
            json!({"input":input,"generation":owner.generation(),"session":owner.account_session()})
        })
        .collect()
}
