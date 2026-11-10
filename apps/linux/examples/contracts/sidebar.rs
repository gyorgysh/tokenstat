// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde_json::{Value, json};
use tokenstat_linux::{
    navigation::Navigation,
    project_edit::Directory,
    sidebar::{Mutation, Store},
};

const KEYS: [&str; 12] = [
    "section:projects",
    "section:servers",
    "project:a",
    "project:b",
    "project:c",
    "project:remote:peer:a",
    "project:é",
    "project:e\u{301}",
    "history:a",
    "server:one",
    "project:number",
    "future:row",
];
const IDS: [&str; 6] = ["a", "b", "c", "remote:peer:a", "é", "e\u{301}"];
const PREFIXES: [&str; 5] = ["project:", "history:", "server:", "section:", "future:"];

fn state(store: &Store, windows: &[Directory]) -> Value {
    let snapshot = store.read().unwrap();
    json!({
        "raw":store.preferences.read(Clone::clone).unwrap(),
        "order":snapshot.section_order(),
        "expanded":KEYS.map(|key| json!({"key":key,"yes":snapshot.is_expanded(key,true),"no":snapshot.is_expanded(key,false)})),
        "ids":PREFIXES.map(|prefix|json!({"prefix":prefix,"ids":snapshot.expanded_ids(prefix)})),
        "windows":windows.iter().map(|window|json!({"projects":window.projects_expanded(),"rows":IDS.map(|id|json!({"id":id,"expanded":window.expanded(id)}))})).collect::<Vec<_>>()
    })
}
fn run(input: Value) -> Value {
    let store = Store::default();
    store
        .preferences
        .update(|values| {
            *values = input["seed"].as_object().unwrap().clone();
            Ok(())
        })
        .unwrap();
    let mut windows = Vec::new();
    let mut rows = vec![state(&store, &windows)];
    let mut navigation = Navigation::default();
    for step in input["steps"].as_array().unwrap() {
        let index = step["window"].as_u64().unwrap_or(0) as usize;
        match step["op"].as_str().unwrap() {
            "open" => {
                let mut window = Directory::default();
                window.apply_preferences(&store.read().unwrap());
                windows.push(window);
            }
            "directory" => {
                let ids = step["ids"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|id| id.as_str().unwrap().to_owned())
                    .collect::<Vec<_>>();
                windows[index].reconcile_with_preferences(
                    Some(&ids),
                    &mut navigation,
                    Some(&store.read().unwrap()),
                );
            }
            "project" => {
                let id = step["id"].as_str().unwrap();
                let expanded = step["expanded"].as_bool().unwrap();
                let section = expanded && !windows[index].projects_expanded();
                windows[index].set_expanded(id, expanded);
                if section {
                    store
                        .mutate(&Mutation::Expansion {
                            key: "section:projects".into(),
                            expanded: true,
                        })
                        .unwrap();
                }
                store
                    .mutate(&Mutation::Expansion {
                        key: format!("project:{id}"),
                        expanded,
                    })
                    .unwrap();
            }
            "section" => {
                let expanded = step["expanded"].as_bool().unwrap();
                windows[index].set_projects_expanded(expanded);
                store
                    .mutate(&Mutation::Expansion {
                        key: "section:projects".into(),
                        expanded,
                    })
                    .unwrap();
            }
            "expansion" => {
                store
                    .mutate(&Mutation::Expansion {
                        key: step["key"].as_str().unwrap().into(),
                        expanded: step["expanded"].as_bool().unwrap(),
                    })
                    .unwrap();
            }
            "move" => {
                store
                    .mutate(&Mutation::Move {
                        section: step["section"].as_str().unwrap().into(),
                        before: step["before"].as_str().unwrap().into(),
                    })
                    .unwrap();
            }
            "external" => {
                store
                    .preferences
                    .update(|values| {
                        for (key, value) in step["values"].as_object().unwrap() {
                            values.insert(key.clone(), value.clone());
                        }
                        Ok(())
                    })
                    .unwrap();
            }
            _ => panic!("Unknown sidebar fixture operation"),
        }
        rows.push(state(&store, &windows));
    }
    json!({"input":input,"rows":rows})
}
pub fn snapshot() -> Value {
    let orders = [
        Value::Null,
        json!("unsupported"),
        json!(17),
        json!([]),
        json!(["future"]),
        json!(["servers", "servers", "future", {"layout":{"version":8}}, "projects", 7]),
        json!([false, "projects", "projects", "servers", ["future"]]),
        json!(["servers"]),
        json!(["projects"]),
    ];
    let choices = [
        json!(true),
        json!(false),
        json!(1),
        json!(0),
        json!("open"),
        json!({"future":8}),
        Value::Null,
    ];
    let mut cases = Vec::new();
    for order in orders {
        for choice in &choices {
            let seed = json!({"shell.sidebar.sectionOrder":order,"shell.sidebarWidth":350,
                "shell.sidebar.expanded.project:a":choice,"shell.sidebar.expanded.project:number":1,
                "shell.sidebar.expanded.future:row":{"layout":{"version":8}},
                "shell.sidebar.expanded.project:remote:peer:a":false,
                "shell.sidebar.expanded.section:projects":choice});
            let steps = json!([
                {"op":"open"},
                {"op":"directory","ids":["a","b","remote:peer:a","é"]},
                {"op":"project","id":"a","expanded":false},
                {"op":"section","expanded":false},
                {"op":"project","id":"a","expanded":true},
                {"op":"project","id":"remote:peer:a","expanded":false},
                {"op":"expansion","key":"history:a","expanded":true},
                {"op":"expansion","key":"server:one","expanded":true},
                {"op":"expansion","key":"project:e\u{301}","expanded":true},
                {"op":"expansion","key":"project:é","expanded":false},
                {"op":"directory","ids":["a","b","c"]},
                {"op":"move","section":"servers","before":"projects"},
                {"op":"move","section":"projects","before":"servers"},
                {"op":"move","section":"future","before":"servers"},
                {"op":"move","section":"servers","before":"servers"},
                {"op":"open"},
                {"op":"directory","window":1,"ids":["a","b","c","remote:peer:a","é"]},
                {"op":"project","window":1,"id":"a","expanded":false},
                {"op":"directory","ids":["a","b","c","remote:peer:a","é"]},
                {"op":"section","expanded":false},
                {"op":"external","values":{"shell.sidebar.expanded.project:b":false,"shell.sidebar.expanded.section:projects":true}},
                {"op":"directory","ids":["a","b","c","remote:peer:a","é"]},
                {"op":"directory","ids":[]},
                {"op":"directory","ids":["a","b","c","remote:peer:a","é"]},
                {"op":"open"},
                {"op":"directory","window":2,"ids":["a","b","c","remote:peer:a","é"]}
            ]);
            cases.push(run(json!({"seed":seed,"steps":steps})));
        }
    }
    json!({"cases":cases})
}
