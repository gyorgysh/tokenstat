// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde_json::{Value, json};
use tokenstat_linux::{
    home::work::HomeWork,
    work::destination::{self, Facts},
};

fn reading(work: &HomeWork) -> Value {
    json!({"recent":work.recent_rows(),"pins":work.pin_rows(),
        "recentOpen":work.recent.iter().map(|r|work.catalog.open_recent(r)).collect::<Vec<_>>(),
        "pinOpen":work.pins.iter().map(|p|work.catalog.open_pin(p)).collect::<Vec<_>>()})
}
pub fn snapshot() -> Value {
    let mut availability = vec![];
    for bits in 0..32 {
        for access in [None, Some(false), Some(true)] {
            for supported in [None, Some(false), Some(true)] {
                for exists in [None, Some(false), Some(true)] {
                    let facts = Facts {
                        account_verified: bits & 1 != 0,
                        host_linked: bits & 2 != 0,
                        connected: bits & 4 != 0,
                        saved_copy: bits & 8 != 0,
                        reconnecting: bits & 16 != 0,
                        access_allowed: access,
                        supported,
                        item_exists: exists,
                    };
                    let result = destination::availability(facts);
                    availability
                        .push(json!({"input":facts,"result":result,"message":result.message()}));
                }
            }
        }
    }
    let mut routes = vec![];
    for folder in [
        "",
        ":",
        "::",
        "remote:",
        "remote::",
        "remote:peer:",
        "remote::folder",
        "remote:peer:folder",
        "remote:peer::folder",
        "remote:::peer:folder",
        "remote:peer:folder:part",
        "remote:peer:::folder",
        "remote:peer::",
        "remote:peer:::",
        "local:folder",
        "/local/folder",
        "remote:PEER:Ünicode",
        "remote:peer:remote:nested:raw",
    ] {
        for peer in [None, Some(""), Some("explicit:peer")] {
            routes.push(
                json!({"folder":folder,"explicit":peer,"result":destination::route(folder,peer)}),
            );
        }
    }
    let fixture = HomeWork::fixture();
    let mut projections = vec![];
    for variant in 0..28 {
        let mut work = fixture.clone();
        match variant {
            1 => work.catalog.scope = None,
            2 => work.catalog.scope.as_mut().unwrap().identity = "another-account".into(),
            3 => work.catalog.scope.as_mut().unwrap().origin = "https://other.invalid".into(),
            4 => work.catalog.local_host_identity = None,
            5 => work.catalog.local_host_identity = Some("".into()),
            6 => work.catalog.folders.clear(),
            7 => work.catalog.folders[0].name = "renamed alpha".into(),
            8 => work.catalog.folders[1].machine_label = Some("Renamed Studio".into()),
            9 => work.catalog.machines.clear(),
            10 => work.catalog.machines[0].online = Some(true),
            11 => work.catalog.machines[0].online = None,
            12 => {
                work.catalog.access.insert("peer-fixture".into(), false);
            }
            13 => work.catalog.access.clear(),
            14 => work.catalog.saved.clear(),
            15 => work.catalog.conversations.get_mut("alpha").unwrap()[0].unused = true,
            16 => work.catalog.conversations.get_mut("alpha").unwrap()[0]
                .title
                .clear(),
            17 => work.catalog.conversations.clear(),
            18 => {
                work.catalog.machines[0].online = Some(true);
                work.catalog
                    .terminals
                    .insert("remote:peer-fixture:beta".into(), vec!["ended".into()]);
            }
            19 => {
                work.recent[0].item_id = None;
            }
            20 => {
                work.recent[0].item_id = Some("".into());
            }
            21 => {
                work.recent.insert(0, work.recent[0].clone());
                work.catalog.conversations.get_mut("alpha").unwrap()[0].unused = true;
            }
            22 => {
                work.recent.clear();
                work.pins.clear();
            }
            23..=25 => {
                let kind = match variant {
                    23 => tokenstat_linux::work::Kind::Commit,
                    24 => tokenstat_linux::work::Kind::SavedDiff,
                    _ => tokenstat_linux::work::Kind::Terminal,
                };
                work.pins[1].reference.kind = kind;
                work.catalog.saved[0].kind = kind;
            }
            26 => {
                work.pins[1].reference.item_id = Some("".into());
                work.catalog.saved[0].item_id = Some("".into());
            }
            27 => {
                work.pins[1].reference.kind = tokenstat_linux::work::Kind::Commit;
                work.catalog.machines[0].online = Some(true);
                work.catalog.saved.clear();
            }
            _ => {}
        }
        projections.push(json!({"variant":variant,"input":work,"reading":reading(&work)}));
    }
    json!({"availability":availability,"routes":routes,"projections":projections,"fixture":fixture})
}
