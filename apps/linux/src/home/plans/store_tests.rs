// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use crate::home::plans::fixture_cache;

fn start(store: &mut Store, owner: u64, force: bool, now: i64) -> Flight {
    match store.begin(owner, force, now) {
        Refresh::Start(flight) => flight,
        other => panic!("expected new flight, got {other:?}"),
    }
}
#[test]
fn readers_join_and_a_failed_attempt_is_throttled_across_mounts() {
    let mut store = Store::default();
    let first = start(&mut store, 1, false, 1_000_000);
    assert_eq!(store.begin(1, true, 1_000_001), Refresh::Join(first));
    store.accept_cache(first, 1, fixture_cache(1_000_000));
    let values: Vec<_> = store
        .providers(1)
        .iter()
        .map(|p| p.windows[0].percent)
        .collect();
    assert_eq!(values, [42., 98.5]);
    store
        .finish(first, 1, Err(RefreshError::Failed("offline".into())))
        .unwrap_err();
    assert!(store.providers(1).iter().all(|p| p.is_stale()));
    assert_eq!(store.begin(1, false, 1_029_999), Refresh::Ready);
    let retry = start(&mut store, 1, false, 1_030_000);
    store.finish(retry, 1, Ok(vec![])).unwrap();
    // A backwards clock must not throttle forever; manual refresh always bypasses it.
    let backwards = start(&mut store, 1, false, 999_000);
    store.finish(backwards, 1, Ok(vec![])).unwrap();
    start(&mut store, 1, true, 999_001);
}
#[test]
fn an_owner_change_hides_data_immediately_and_old_completion_cannot_end_a_new_flight() {
    let mut store = Store::default();
    let old = start(&mut store, 1, true, 1_000_000);
    store.accept_cache(old, 1, fixture_cache(1_000_000));
    assert!(store.providers(2).is_empty() && store.state(2).is_none() && !store.is_refreshing(2));
    let new = start(&mut store, 2, false, 1_000_001);
    assert!(!store.accept_cache(old, 2, fixture_cache(1_000_002)));
    assert_eq!(
        store.finish(old, 2, Ok(fixture_cache(1_000_002).providers)),
        Err(RefreshError::Retired)
    );
    assert!(store.current(new, 2));
    assert!(store.providers(2).is_empty());
    store.finish(new, 2, Ok(vec![])).unwrap();
}
#[test]
fn settings_retire_vendor_and_cached_replies_but_keep_equal_date_failure_notes() {
    let mut store = Store::default();
    let old = start(&mut store, 1, true, 1_000_000);
    store.accept_cache(old, 1, fixture_cache(1_000_000));
    let read = store.settings_read(1);
    store.settings_changed(
        1,
        LimitsSync {
            enabled: true,
            skip: vec!["codex".into()],
            ..LimitsSync::default()
        },
    );
    assert_eq!(store.finish(old, 1, Ok(vec![])), Err(RefreshError::Retired));
    assert!(!store.accept_cached_settings(1, read, LimitsSync::default()));
    assert!(store.state(1).unwrap().enabled);
    assert_eq!(store.visible(1).len(), 1);
    let fresh = start(&mut store, 1, false, 1_000_001);
    store
        .finish(fresh, 1, Err(RefreshError::Failed("offline".into())))
        .unwrap_err();
    let mut cache = fixture_cache(1_000_000);
    cache.providers.iter_mut().for_each(|p| {
        p.stale = None;
        p.note = None;
    });
    assert!(store.accept_cached_settings(1, store.settings_read(1), cache.clone()));
    assert!(store.providers(1).iter().all(|p| p.is_stale()));
    cache
        .providers
        .iter_mut()
        .for_each(|p| p.observed_at_ms += 1);
    assert!(store.accept_cached_settings(1, store.settings_read(1), cache));
    assert!(store.providers(1).iter().all(|p| !p.is_stale()));
    let read = store.settings_read(1);
    assert!(!store.accept_cached_settings(2, read, LimitsSync::default()));
}
#[test]
fn disabled_records_come_from_raw_cache_after_live_success_and_cancellation_does_not_mark_stale() {
    let mut store = Store::default();
    let first = start(&mut store, 1, true, 1_000_000);
    store
        .finish(first, 1, Ok(fixture_cache(1_000_000).providers))
        .unwrap();
    let second = start(&mut store, 1, true, 1_000_001);
    let mut cache = fixture_cache(1_000_000);
    cache.skip = vec!["claude_code".into()];
    cache.providers[1].stale = Some(false);
    cache.providers[1].note = None;
    store.accept_cache(second, 1, cache);
    assert!(store.providers(1)[1].is_stale());
    let codex = store.providers(1)[0].clone();
    store.finish(second, 1, Ok(vec![codex])).unwrap();
    assert!(!store.providers(1)[1].is_stale());
    assert_eq!(store.visible(1).len(), 1);
    let cancelled = start(&mut store, 1, true, 1_000_002);
    assert_eq!(
        store.finish(cancelled, 1, Err(RefreshError::Retired)),
        Err(RefreshError::Retired)
    );
    assert!(store.providers(1).iter().all(|p| !p.is_stale()));
}
