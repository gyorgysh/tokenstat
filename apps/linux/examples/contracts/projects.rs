// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde_json::{Value, json};
use tokenstat_linux::{
    commands::EntryKind,
    project_edit::{self, RemovalRoute},
    project_menu::{self, State},
    work::Scope,
};

pub fn snapshot() -> Value {
    let mut cases = Vec::new();
    for bits in 0..128 {
        for pin_count in [0, 7, 8, 9] {
            for remote in [None, Some(""), Some("peer")] {
                let state = State {
                    reference: bits & 1 != 0,
                    pinned: bits & 2 != 0,
                    stale: bits & 4 != 0,
                    shared: bits & 8 != 0,
                    stop_sharing: bits & 16 != 0,
                    git_is_repo: if bits & 32 != 0 {
                        Some(bits & 64 != 0)
                    } else {
                        None
                    },
                    pin_count,
                    machine_id: remote.map(str::to_owned),
                    machine_label: match bits % 3 {
                        0 => None,
                        1 => Some(String::new()),
                        _ => Some("Fixture computer 🐧".into()),
                    },
                };
                let items = project_menu::items(&state).into_iter().map(|item| json!({
                    "kind": match item.kind { EntryKind::Action => "action", EntryKind::Separator => "separator", EntryKind::Heading => "heading" },
                    "title": item.title, "enabled": item.enabled, "selected": item.selected,
                    "symbol": item.icon.map(|icon| icon.symbol()), "destructive": item.destructive,
                })).collect::<Vec<_>>();
                cases.push(json!({"state":state,"items":items}));
            }
        }
    }
    let mut references = Vec::new();
    for scope in [
        None,
        Some(Scope::local("fixture")),
        Scope::account("https://example.test", "fixture-owner"),
    ] {
        for local in [None, Some(""), Some("fixture-host")] {
            for folder in [
                "",
                "alpha",
                "remote:peer:alpha",
                "remote::peer:alpha",
                "remote:peer:",
                "remote:peer:a:b",
                "remote:peer",
                "é",
            ] {
                references.push(json!({"scope":scope,"local":local,"folder":folder,"reference":project_menu::reference(scope.as_ref(),local,folder)}));
            }
        }
    }
    let mut removals = Vec::new();
    for id in [
        "/fixture/a",
        "remote:peer:a",
        "remote:peer:",
        "remote:other:a",
        "remote::peer:a",
        "remote:peer:a:b",
        "remote:peer",
        "a:b:c",
        "a::b:c",
        "::a:b:c",
        "",
        "é",
        "remote:::",
        "remote:peer::a",
    ] {
        for peer in [None, Some(""), Some("peer")] {
            for dirty in ["none", "own", "other"] {
                for fail in [false, true] {
                    for selected in [false, true] {
                        let route = project_edit::removal_route(id, peer);
                        let blocked = dirty == "own";
                        let rpc = !blocked && !matches!(route, RemovalRoute::ForgetRemote { .. });
                        let success = !blocked && (!rpc || !fail);
                        let mut calls = Vec::new();
                        if rpc {
                            calls.push(match &route {
                            RemovalRoute::Local{id}=>json!({"method":"workspace.remove","params":{"id":id}}),
                            RemovalRoute::Remote{peer,id}=>json!({"method":"remote.call","params":{"peer":peer,"method":"workspace.remove","params":{"id":id}}}),
                            _=>unreachable!(),
                        });
                        }
                        let remote = peer.is_some();
                        removals.push(json!({"input":{"id":id,"peer":peer,"dirty":dirty,"fail":fail,"selected":selected},"result":{
                            "calls":calls,"close":if blocked {Some("dirty-file")} else {None},"forgotten":if success {vec![id]} else {vec![]},
                            "refreshed":if success && matches!(route,RemovalRoute::Remote {..}) {vec![peer.unwrap()]} else {vec![]},
                            "load":usize::from(success&&!remote),"publish":usize::from(success&&remote),
                            "selection":if selected&&!success {Some(id)} else if !selected {Some("other-selected")} else {None},"error":if rpc&&fail {Some("host failed")} else {None},
                        }}));
                    }
                }
            }
        }
    }
    json!({"menus":cases,"references":references,"removals":removals})
}
