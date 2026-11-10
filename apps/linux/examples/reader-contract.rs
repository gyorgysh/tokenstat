// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Synthetic complete wire and warm-row source comparison; no host or disk IO.

use serde::{Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use std::{collections::HashSet, io::Read};
use tokenstat_linux::chat::{Conversation, recent_messages::RecentMessages, send_context, wire::*};
#[path = "contracts/reader_paging.rs"]
mod reader_paging;

fn decode<T: DeserializeOwned + Serialize>(input: &Value) -> Value {
    match serde_json::from_value::<T>(input.clone()) {
        Ok(value) => json!({"ok":true,"value":value}),
        Err(_) => json!({"ok":false}),
    }
}
fn main() {
    let mut bytes = String::new();
    std::io::stdin().read_to_string(&mut bytes).unwrap();
    let input: Value = serde_json::from_str(&bytes).unwrap();
    let wire = input["wire"]
        .as_array()
        .unwrap()
        .iter()
        .map(|case| {
            let value = &case["value"];
            match case["type"].as_str().unwrap() {
                "conversation" => decode::<Conversation>(value),
                "event" => decode::<TimelineEvent>(value),
                "agent" => decode::<AgentEvent>(value),
                "page" => decode::<EventPage>(value),
                "chunk" => decode::<EventChunk>(value),
                _ => panic!("unknown type"),
            }
        })
        .collect::<Vec<_>>();
    let caches = input["caches"]
        .as_array()
        .unwrap()
        .iter()
        .map(|trace| {
            let mut cache = RecentMessages::<Value>::default();
            let mut checkpoints = vec![];
            for action in trace["actions"].as_array().unwrap() {
                let key = action["key"].as_str().unwrap_or_default();
                let mut result = Value::Null;
                match action["op"].as_str().unwrap() {
                    "store" => cache.store(
                        action["rows"].as_array().unwrap(),
                        key,
                        action["speculative"].as_bool().unwrap_or_default(),
                        |r| r["cost"].as_i64().unwrap(),
                    ),
                    "messages" => result = json!(cache.messages(key)),
                    "peek" => result = json!(cache.peek(key)),
                    "remove" => cache.remove(key),
                    "retain" => cache.retain(
                        &action["keys"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .map(|k| k.as_str().unwrap().into())
                            .collect::<HashSet<_>>(),
                        action["folder"].as_str().unwrap(),
                    ),
                    "clear" => cache.remove_all(),
                    _ => panic!("unknown operation"),
                }
                let entries = trace["keys"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|k| {
                        let key = k.as_str().unwrap();
                        json!({"key":key,"contains":cache.contains(key),"rows":cache.peek(key)})
                    })
                    .collect::<Vec<_>>();
                checkpoints.push(json!({"result":result,"entries":entries}));
            }
            json!(checkpoints)
        })
        .collect::<Vec<_>>();
    let revisions = input["revisions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| send_context::after_own_edit(r[0].as_u64(), r[1].as_u64(), r[2].as_u64()))
        .collect::<Vec<_>>();
    println!(
        "{}",
        json!({"wire":wire,"caches":caches,"revisions":revisions,"paging":[OPEN_PAGE_EVENTS,PAGE_EVENTS,PREVIEW_PAGE_EVENTS,HOST_PAGE_EVENTS_MAX],"windows":reader_paging::snapshot(&input["windows"])})
    );
}
