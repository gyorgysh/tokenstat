// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Synthetic account report ownership trace for original Swift comparison.

use serde_json::{Value, json};
use tokenstat_linux::{
    insights::account::{Cut, Report, State},
    work::Scope,
};

fn report(cut: Cut, key: &str) -> Report {
    serde_json::from_value(
        json!({"group":cut.wire(),"fetchedAtMs":1,"stale":false,"rows":[{
            "key":key,"counters":{"total":1,"inputTotal":0,"hasUnknown":false},
            "events":1,"sessions":1,"valueMicros":0,"estimated":false,"unpricedModels":[]
        }]}),
    )
    .unwrap()
}
fn point(label: &str, state: &State, scope: Option<&Scope>) -> Value {
    let keys = |cut| {
        state
            .rows(cut, scope)
            .map(|rows| rows.iter().map(|row| row.key.clone()).collect::<Vec<_>>())
    };
    json!({"label":label,"cut":state.cut.wire(),"loading":state.loading(),
        "model":keys(Cut::Model),"source":keys(Cut::Source),"day":keys(Cut::Day),
        "error":state.error(),"needsSignIn":state.needs_sign_in()})
}
fn main() {
    let a = Scope::local("a");
    let b = Scope::local("b");
    let mut s = State::default();
    let mut out = Vec::new();
    let old = s.load(Some(&a), false).unwrap();
    out.push(point("first", &s, Some(&a)));
    let new = s.load(Some(&a), false).unwrap();
    s.finish(&old, Some(&a), false, Ok(report(Cut::Model, "old")));
    out.push(point("old reply", &s, Some(&a)));
    s.finish(&new, Some(&a), false, Ok(report(Cut::Model, "one")));
    out.push(point("model loaded", &s, Some(&a)));
    assert!(s.load(Some(&a), false).is_none());
    s.cut = Cut::Day;
    let day = s.load(Some(&a), false).unwrap();
    s.cut = Cut::Source;
    let fresh = s.refresh(Some(&a), false).unwrap();
    out.push(point("refresh", &s, Some(&a)));
    s.finish(&day, Some(&a), false, Ok(report(Cut::Day, "stale")));
    out.push(point("stale day", &s, Some(&a)));
    s.finish(&fresh, Some(&a), false, Ok(report(Cut::Source, "tool")));
    out.push(point("source loaded", &s, Some(&a)));
    let prior = s.refresh(Some(&a), false).unwrap();
    out.push(point("scope changed", &s, Some(&b)));
    let new_owner = s.load(Some(&b), false).unwrap();
    s.finish(&prior, Some(&b), false, Ok(report(Cut::Source, "private")));
    out.push(point("old account", &s, Some(&b)));
    s.finish(&new_owner, Some(&b), false, Err("Please sign in".into()));
    out.push(point("failure", &s, Some(&b)));
    let cancelled = s.load(Some(&b), false).unwrap();
    s.finish(
        &cancelled,
        Some(&b),
        true,
        Ok(report(Cut::Source, "cancelled")),
    );
    out.push(point("cancelled", &s, Some(&b)));
    let retry = s.load(Some(&b), false).unwrap();
    s.finish(&retry, Some(&b), false, Ok(report(Cut::Source, "new")));
    out.push(point("retry", &s, Some(&b)));
    println!("{}", serde_json::to_string(&out).unwrap());
}
