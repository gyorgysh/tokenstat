// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Synthetic source comparison of capability, row lifetime and route effects.

use serde_json::{Value, json};
use tokenstat_linux::{
    chat::{
        self, actions,
        directory::{Model, Owner},
    },
    design::{GlobalSection, WorkspaceSection},
    navigation::{Route, SshSection},
    work::Scope,
};

fn run(input: Value) -> Value {
    let owner = Owner {
        scope: Scope::local("account"),
        generation: 1,
        local_host_identity: "host".into(),
    };
    let folder = input["folder"].as_str().unwrap();
    let before: Route = serde_json::from_value(input["before"].clone()).unwrap();
    let mut route: Route = serde_json::from_value(input["after"].clone()).unwrap();
    let changed = input["scopeChanged"].as_bool().unwrap();
    let visible = input["mounted"].as_bool().unwrap() && !changed;
    let key = actions::Key::new(&owner, folder, "source");
    let mut actions = actions::Model::default();
    let ticket = actions.begin(key.clone()).unwrap();
    let began = actions.copying(&key);
    let target = tokenstat_linux::work::destination::route(folder, None);
    let supported = chat::fork_supported(target.peer.as_deref(), input["version"].as_i64());
    if !visible {
        actions.retain(&Default::default());
    }
    let mut directory = Model::default();
    directory.set_owner(Some(owner.clone()));
    if changed {
        let mut other = owner.clone();
        other.scope = Scope::local("other");
        directory.set_owner(Some(other));
    }
    let mut published = Vec::new();
    let mut reveal = Vec::new();
    let mut projects = Vec::new();
    let mut histories = Vec::new();
    let failure = input["failure"].as_bool().unwrap();
    if supported && !failure && !changed {
        let copy:chat::Conversation=serde_json::from_value(json!({"id":"copy","workspaceId":target.workspace_id,"title":"Copy","backend":"fixture"})).unwrap();
        if directory.publish(&owner, folder, copy, 0) {
            published.push("copy");
        }
        if route == before {
            reveal.push(json!({"id":"copy","folder":folder}));
            projects.push(folder);
            histories.push(folder);
            route = Route::Workspace {
                id: folder.into(),
                section: WorkspaceSection::Chat,
            };
        }
    }
    actions.finish(
        &ticket,
        if supported && !failure && !changed {
            Ok(())
        } else {
            Err("fixture".into())
        },
    );
    json!({"input":input,"began":began,"copying":visible && actions.copying(&key),"error":visible && actions.error(&key).is_some(),"published":published,"reveal":reveal,"projects":projects,"histories":histories,"route":route,"calls":if supported {json!([{"peer":target.peer,"method":"chat.fork","id":"source"}])} else {json!([])},"probes":usize::from(target.peer.as_ref().is_some_and(|s|!s.is_empty()))})
}
fn main() {
    let before = Route::Workspace {
        id: "café".into(),
        section: WorkspaceSection::Chat,
    };
    let after = [
        Route::Workspace {
            id: "cafe\u{301}".into(),
            section: WorkspaceSection::Chat,
        },
        Route::Workspace {
            id: "café".into(),
            section: WorkspaceSection::Notes,
        },
        Route::Global {
            section: GlobalSection::Notes,
        },
    ];
    let mut cases = Vec::new();
    for folder in ["/fixture/alpha", "remote:peer:raw:a"] {
        for version in [-1, 25, 26, 53] {
            for failure in [false, true] {
                for route in &after {
                    for changed in [false, true] {
                        for mounted in [false, true] {
                            cases.push(run(json!({"folder":folder,"before":before,"after":route,"version":version,"failure":failure,"scopeChanged":changed,"mounted":mounted})));
                        }
                    }
                }
            }
        }
    }
    let pairs=vec![
        (before.clone(),after[0].clone()),
        (before.clone(),after[1].clone()),
        (Route::SshTerminals {host:"café".into()},Route::SshTerminals {host:"cafe\u{301}".into()}),
        (Route::Ssh {section:SshSection::Hosts {folder:Some("café".into())}},Route::Ssh {section:SshSection::Hosts {folder:Some("cafe\u{301}".into())}}),
        (Route::Ssh {section:SshSection::Hosts {folder:None}},Route::Ssh {section:SshSection::Hosts {folder:Some(String::new())}}),
    ].into_iter().map(|(a,b)|json!({"a":a,"b":b,"equal":a==b,"setCount":std::collections::HashSet::from([a,b]).len()})).collect::<Vec<_>>();
    println!(
        "{}",
        json!({"minimum":chat::FORK_MIN_PROTOCOL,"cases":cases,"routePairs":pairs})
    );
}
