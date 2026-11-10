// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Synthetic ordered inputs for the complete original list/note state owners.

use serde_json::{Value, json};
use std::collections::HashMap;
use tokenstat_linux::chat::{Conversation, flights, list_mutations, steer_overlay};
use unicode_normalization::UnicodeNormalization;

fn row(raw: &Value) -> Conversation {
    serde_json::from_value(json!({"id":raw["id"],"title":raw["title"],"pendingSteer":raw["pendingSteer"],"workspaceId":"folder","backend":"fixture"})).unwrap()
}
fn rows(raw: &Value) -> Vec<Conversation> {
    raw.as_array().unwrap().iter().map(row).collect()
}
fn value(row: &Conversation) -> Value {
    json!({"id":row.id,"title":row.title,"pendingSteer":row.pending_steer})
}
fn run(input: Value) -> Value {
    let mut lists = list_mutations::Model::default();
    let mut notes = steer_overlay::Model::default();
    let mut reads = HashMap::new();
    let mut mutations = HashMap::new();
    let mut current: HashMap<String, Vec<Conversation>> = HashMap::new();
    let mut output = Vec::new();
    for step in input["steps"].as_array().unwrap() {
        let owner = step["owner"].as_str().unwrap_or("owner");
        let owner_key = owner.nfc().collect::<String>();
        let name = step["name"].as_str().unwrap_or("default");
        let mut accepted = Value::Null;
        let mut record = Value::Null;
        match step["op"].as_str().unwrap() {
            "read" => {
                reads.insert(
                    name.to_owned(),
                    (lists.begin_read(owner), notes.begin_read(owner)),
                );
            }
            "replace" => lists.replace(row(&step["row"]), owner),
            "remove" => lists.remove(step["id"].as_str().unwrap(), owner),
            "mutation" => {
                mutations.insert(
                    name.to_owned(),
                    notes.mutation(owner, step["id"].as_str().unwrap()),
                );
            }
            "remember" => {
                accepted = json!(notes.remember(
                    owner,
                    step["id"].as_str().unwrap(),
                    step["note"].as_str().map(str::to_owned),
                    step["since"].as_str().map(|name| &mutations[name])
                ));
            }
            "apply" => {
                let (list, note) = &reads[name];
                let held = current.get(&owner_key).cloned().unwrap_or_default();
                let incoming = lists.apply(rows(&step["rows"]), list, &held);
                let incoming = notes.apply(incoming, note, &held);
                current.insert(owner_key.clone(), incoming);
            }
            "preserve" => {
                let incoming = row(&step["row"]);
                let held = current.get(&owner_key).and_then(|rows| {
                    rows.iter()
                        .find(|r| tokenstat_linux::work::text::equal(&r.id, &incoming.id))
                });
                record = value(&steer_overlay::Model::preserving_note(incoming, held));
            }
            "reset" => {
                lists.remove_all();
                notes.remove_all();
                current.clear();
            }
            _ => panic!("Unknown synthetic operation"),
        }
        output.push(json!({"rows":current.get(&owner_key).into_iter().flatten().map(value).collect::<Vec<_>>(),"accepted":accepted,"record":record}));
    }
    json!({"input":input,"rows":output})
}
fn cases() -> Vec<Value> {
    let mut cases = Vec::new();
    for bits in 0..32 {
        let a = json!({"id":"a","title":"Old","pendingSteer":"old note"});
        let b = json!({"id":"b","title":"Delete me","pendingSteer":null});
        let mut steps = vec![
            json!({"op":"read","name":"old"}),
            json!({"op":"read","name":"other","owner":"other"}),
            json!({"op":"replace","row":{"id":"a","title":"Renamed","pendingSteer":null}}),
        ];
        if bits & 1 != 0 {
            steps.push(json!({"op":"remove","id":"b"}));
        }
        steps.extend([
            json!({"op":"remember","id":"a","note":"first"}),
            json!({"op":"mutation","id":"a","name":"delivery"}),
        ]);
        if bits & 2 != 0 {
            steps.push(json!({"op":"remember","id":"a","note":"first"}));
        }
        steps.push(json!({"op":"remember","id":"a","note":null,"since":"delivery"}));
        steps.push(json!({"op":"apply","name":"old","rows":if bits&4!=0 {json!([])} else {json!([a,b,b])}}));
        steps.push(json!({"op":"preserve","row":{"id":if bits&8!=0 {"other"} else {"a"},"title":"Metadata","pendingSteer":null}}));
        steps.push(json!({"op":"apply","name":"other","owner":"other","rows":[a,b]}));
        steps.extend([json!({"op":"read","name":"fresh"}),json!({"op":"apply","name":"fresh","rows":[{"id":"a","title":"Other device","pendingSteer":if bits&16!=0 {json!("other client's note")} else {Value::Null}}]}),json!({"op":"remember","id":"a","note":null,"since":"delivery"}),json!({"op":"apply","name":"old","rows":[a,b]}),json!({"op":"read","name":"missing"}),json!({"op":"apply","name":"missing","rows":[]}),json!({"op":"reset"}),json!({"op":"read","name":"new-account"}),json!({"op":"apply","name":"new-account","rows":[a,b]})]);
        cases.push(run(json!({"name":format!("race-{bits}"),"steps":steps})));
    }
    cases.push(run(json!({"name":"canonical-identities","steps":[{"op":"read","owner":"café","name":"old"},{"op":"replace","owner":"cafe\u{301}","row":{"id":"café","title":"Changed"}},{"op":"remember","owner":"café","id":"cafe\u{301}","note":"NFC"},{"op":"apply","owner":"café","name":"old","rows":[{"id":"cafe\u{301}","title":"Old"},{"id":"café","title":"Duplicate"}]}]})));
    cases.push(run(json!({"name":"wrong-mutation-owner","steps":[{"op":"mutation","owner":"other","id":"a","name":"other"},{"op":"mutation","id":"b","name":"b"},{"op":"remember","id":"a","note":null,"since":"other"},{"op":"remember","id":"a","note":null,"since":"b"}]})));
    cases
}
fn main() {
    println!(
        "{}",
        json!({"cases":cases(),"reads":flights::READ_METHODS,"mutations":flights::MUTATION_METHODS})
    );
}
