// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Synthetic on-disk traces for comparison with the actual Swift draft store.

use serde_json::{Value, json};
use std::{collections::BTreeMap, io::Read, path::Path};
use tokenstat_linux::{
    drafts::{self, service::Service, storage::Storage},
    work::{Kind, Reference, Scope, continuity::Date},
};

fn reference(scope: Scope, host: &str, folder: &str, id: &str) -> Reference {
    Reference {
        scope,
        host_identity: host.into(),
        workspace_id: folder.into(),
        kind: Kind::Conversation,
        item_id: Some(id.into()),
        anchor: None,
    }
}
fn drain(service: &mut Service) {
    while let Some(job) = service.next_job() {
        let result = job.execute();
        service.finish(&job, result);
    }
    assert!(service.idle());
}
fn normalize(value: &mut Value, ids: &mut BTreeMap<String, String>) {
    match value {
        Value::Object(map) => {
            if let Some(Value::String(id)) = map.get_mut("messageId")
                && id.len() == 36
                && id.chars().filter(|ch| *ch == '-').count() == 4
            {
                let next = format!("UUID-{}", ids.len() + 1);
                let normalized = ids.entry(id.clone()).or_insert(next).clone();
                *id = normalized;
            }
            for value in map.values_mut() {
                normalize(value, ids);
            }
        }
        Value::Array(values) => {
            for value in values {
                normalize(value, ids);
            }
        }
        _ => {}
    }
}
fn snapshot(
    stores: &[Service],
    references: &[Reference],
    root: &Path,
    storage: &Storage,
    settled: bool,
    ids: &mut BTreeMap<String, String>,
) -> Value {
    let mut rows = Vec::new();
    for store in stores {
        let mut records: Value =
            serde_json::from_slice(&drafts::storage::encode(store.model.records()).unwrap())
                .unwrap();
        normalize(&mut records, ids);
        let protection = if settled {
            match storage.read() {
                Ok(stored) => {
                    json!({"scopes":references.iter().map(|r|store.model.protected_attachments(&stored,&r.scope)).collect::<Vec<_>>(),"references":references.iter().map(|r|store.model.referenced_attachments(&stored,r)).collect::<Vec<_>>()})
                }
                Err(_) => json!("failed"),
            }
        } else {
            json!("pending")
        };
        rows.push(json!({"records":records,"occupied":store.occupied(),"failed":store.save_failed,"memoryBytes":drafts::storage::encode(store.model.records()).unwrap().len(),"has":references.iter().map(|r|store.model.has_draft(r)).collect::<Vec<_>>(),"protection":protection}));
    }
    let disk = if !settled {
        json!("pending")
    } else {
        match std::fs::read(root.join("drafts.v1.json")) {
            Ok(bytes) => {
                if let Ok(mut value) = serde_json::from_slice::<Value>(&bytes) {
                    normalize(&mut value, ids);
                    json!({"records":value,"bytes":bytes.len()})
                } else {
                    json!("invalid")
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Value::Null,
            Err(error) => panic!("{error}"),
        }
    };
    json!({"stores":rows,"disk":disk})
}
fn run(input: Value) -> Value {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("drafts");
    if let Some(seed) = input["seed"].as_str() {
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join("drafts.v1.json"), seed).unwrap();
    }
    let references: Vec<Reference> = serde_json::from_value(input["references"].clone()).unwrap();
    let limit = input["limit"].as_u64().unwrap() as usize;
    let storage = Storage::at(directory.clone(), limit);
    let mut stores = vec![Service::new(Some(storage.clone()))];
    drain(&mut stores[0]);
    let mut expected = BTreeMap::new();
    let mut ids = BTreeMap::new();
    let mut rows = vec![snapshot(
        &stores,
        &references,
        &directory,
        &storage,
        true,
        &mut ids,
    )];
    for step in input["steps"].as_array().unwrap() {
        let index = step["store"].as_u64().unwrap_or(0) as usize;
        let reference = step["ref"]
            .as_u64()
            .map(|index| references[index as usize].clone());
        match step["op"].as_str().unwrap() {
            "open" => {
                let mut store = Service::new(Some(storage.clone()));
                drain(&mut store);
                stores.push(store);
            }
            "save" => {
                stores[index]
                    .save(
                        reference.unwrap(),
                        step["text"].as_str().unwrap().into(),
                        serde_json::from_value(
                            step.get("attachments").cloned().unwrap_or(json!([])),
                        )
                        .unwrap(),
                        Date(step["at"].as_f64().unwrap_or(0.)),
                        step["new"].as_bool().unwrap_or(false),
                    )
                    .unwrap();
            }
            "clear" => stores[index].clear(&reference.unwrap()),
            "remember" => {
                expected.insert(
                    step["name"].as_str().unwrap().to_owned(),
                    stores[index]
                        .model
                        .draft(&reference.unwrap())
                        .unwrap()
                        .clone(),
                );
            }
            "clearExpected" => {
                stores[index].clear_expected(&expected[step["name"].as_str().unwrap()])
            }
            "retry" => stores[index].retry_failed_save(),
            "corrupt" => {
                std::fs::create_dir_all(&directory).unwrap();
                std::fs::write(
                    directory.join("drafts.v1.json"),
                    step["bytes"].as_str().unwrap(),
                )
                .unwrap();
            }
            "settle" => {}
            _ => panic!("Unknown fixture operation"),
        }
        let settled = step["settle"].as_bool().unwrap_or(true);
        if settled {
            for store in &mut stores {
                drain(store);
            }
        }
        rows.push(snapshot(
            &stores,
            &references,
            &directory,
            &storage,
            settled,
            &mut ids,
        ));
    }
    for store in &mut stores {
        drain(store);
    }
    json!({"input":input,"rows":rows})
}
fn cases() -> Value {
    let local = Scope::local("fixture");
    let references = vec![
        reference(local.clone(), "host", "folder", "a"),
        reference(local.clone(), "host", "folder", "b"),
        reference(
            Scope::account("https://fixture.invalid", "alice").unwrap(),
            "host",
            "folder",
            "a",
        ),
        reference(
            Scope::account("https://fixture.invalid", "bob").unwrap(),
            "host",
            "folder",
            "a",
        ),
        reference(local.clone(), "other-host", "folder", "a"),
        reference(local.clone(), "host", "other-folder", "a"),
        reference(local.clone(), "host", "a|b", "c"),
        reference(local.clone(), "host", "a", "b|c"),
    ];
    let mut inputs = Vec::new();
    let scenarios = vec![
        (
            "identity",
            json!([
                {"op":"save","ref":0,"text":"first","at":1},{"op":"remember","ref":0,"name":"old"},{"op":"save","ref":0,"text":"first","at":9},{"op":"save","ref":0,"text":"edited","at":2},{"op":"clearExpected","name":"old"},{"op":"save","ref":0,"text":"edited","at":3,"new":true},{"op":"save","ref":1,"text":"","at":4,"attachments":[{"id":"file","name":"notes.md","mediaType":"text/markdown","size":12,"toolCallId":"tool"}]},{"op":"save","ref":1,"text":" \n\t","at":5},{"op":"clear","ref":0}
            ]),
        ),
        (
            "isolated",
            json!([
                {"op":"save","ref":0,"text":"a","at":1},{"op":"save","ref":2,"text":"alice","at":2},{"op":"save","ref":3,"text":"bob","at":3},{"op":"save","ref":4,"text":"other host","at":4},{"op":"save","ref":5,"text":"other folder","at":5},{"op":"save","ref":6,"text":"separator one","at":6},{"op":"save","ref":7,"text":"separator two","at":7},{"op":"open"},{"op":"clear","store":1,"ref":0},{"op":"save","ref":1,"text":"new","at":8},{"op":"open"}
            ]),
        ),
        (
            "conditional-disk",
            json!([
                {"op":"save","ref":0,"text":"old","at":1},{"op":"remember","ref":0,"name":"old"},{"op":"open"},{"op":"save","store":1,"ref":0,"text":"newer elsewhere","at":2},{"op":"clearExpected","name":"old"},{"op":"open"}
            ]),
        ),
        (
            "failed-deletion",
            json!([
                {"op":"save","ref":0,"text":"writing","at":1},{"op":"corrupt","bytes":"broken"},{"op":"clear","ref":0},{"op":"corrupt","bytes":"{}"},{"op":"retry"},{"op":"open"}
            ]),
        ),
        (
            "failed-save",
            json!([
                {"op":"corrupt","bytes":"broken"},{"op":"save","ref":0,"text":"never lost","at":1},{"op":"corrupt","bytes":"{}"},{"op":"save","ref":1,"text":"other key","at":2},{"op":"open"}
            ]),
        ),
        (
            "unicode",
            json!([
                {"op":"save","ref":0,"text":"café","at":1,"attachments":[{"id":"file","name":"é.txt"}]},{"op":"save","ref":0,"text":"cafe\u{301}","at":9,"attachments":[{"id":"file","name":"e\u{301}.txt"}]},{"op":"save","ref":1,"text":"/literal\\slash/\n東京・🐧","at":2},{"op":"open"}
            ]),
        ),
        (
            "attachment-protection",
            json!([
                {"op":"save","ref":0,"text":"","at":1,"attachments":[{"id":"café","name":"old"}]},{"op":"open"},{"op":"save","store":1,"ref":0,"text":"","at":2,"attachments":[{"id":"cafe\u{301}","name":"new"},{"id":"other","name":"file"}]},{"op":"remember","ref":0,"name":"submitted"},{"op":"clearExpected","name":"submitted"},{"op":"open"}
            ]),
        ),
        (
            "queued",
            json!([
                {"op":"save","ref":0,"text":"queued one","at":1,"settle":false},{"op":"save","ref":1,"text":"queued two","at":2,"settle":false},{"op":"clear","ref":0},{"op":"open"}
            ]),
        ),
    ];
    for (name, steps) in scenarios {
        inputs.push(json!({"name":name,"references":references,"limit":8388608,"steps":steps}));
    }
    let dates = [
        0.,
        -0.,
        1.25,
        -1.25,
        1e-7,
        1e-6,
        1e-5,
        1e15,
        1e16,
        1e20,
        1e-20,
        f64::MIN_POSITIVE,
        f64::MAX,
    ];
    let steps = dates
        .into_iter()
        .enumerate()
        .map(|(index, at)| json!({"op":"save","ref":0,"text":format!("date-{index}"),"at":at}))
        .chain(std::iter::once(json!({"op":"open"})))
        .collect::<Vec<_>>();
    inputs.push(
        json!({"name":"date-encoding","references":references,"limit":8388608,"steps":steps}),
    );
    for (name, seed) in [
        ("invalid-initial", "broken"),
        ("invalid-record", "{\"wrong-key\":{}}"),
        ("oversized-initial", &"x".repeat(701)),
    ] {
        inputs.push(json!({"name":name,"references":references,"limit":700,"seed":seed,"steps":[{"op":"retry"},{"op":"corrupt","bytes":"{}"},{"op":"save","ref":0,"text":"recovered","at":1},{"op":"open"}]}));
    }
    inputs.push(json!({"name":"quota","references":references,"limit":700,"steps":[{"op":"save","ref":0,"text":"x".repeat(1500),"at":1},{"op":"save","ref":0,"text":"small","at":2},{"op":"open"}]}));
    let legacy = drafts::Draft {
        reference: references[0].clone(),
        text: "legacy".into(),
        attachments: vec![],
        updated_at: Date(1.),
        message_id: None,
    };
    let seed = drafts::storage::encode(
        &[(references[0].conversation_key().unwrap(), legacy)]
            .into_iter()
            .collect(),
    )
    .unwrap();
    inputs.push(json!({"name":"legacy-id","references":references,"limit":8388608,"seed":String::from_utf8(seed).unwrap(),"steps":[{"op":"save","ref":0,"text":"legacy","at":2},{"op":"save","ref":0,"text":"changed","at":3},{"op":"open"}]}));
    Value::Array(inputs.into_iter().map(run).collect())
}
fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if let [mode, root] = args.as_slice()
        && mode == "read"
    {
        let storage = Storage::at(root.into(), drafts::storage::MAX_FILE_BYTES);
        storage.prepare().unwrap();
        println!(
            "{}",
            String::from_utf8(drafts::storage::encode(&storage.read().unwrap()).unwrap()).unwrap()
        );
        return;
    }
    if let [mode, root, author] = args.as_slice()
        && mode == "writer"
    {
        let storage = Storage::at(root.into(), drafts::storage::MAX_FILE_BYTES);
        let mut service = Service::new(Some(storage));
        drain(&mut service);
        for index in 0..25 {
            service
                .save(
                    reference(
                        Scope::local("fixture"),
                        "host",
                        "folder",
                        &format!("{author}-{index}"),
                    ),
                    format!("{author}-{index}"),
                    vec![],
                    Date(index as f64),
                    false,
                )
                .unwrap();
            drain(&mut service);
            assert!(!service.save_failed);
        }
        return;
    }
    if let [mode, root] = args.as_slice()
        && mode == "participant"
    {
        let participant = drafts::coordination::join(Path::new(root)).unwrap();
        std::fs::write(Path::new(root).join("ready-rust"), b"ready").unwrap();
        let mut byte = [0];
        std::io::stdin().read_exact(&mut byte).unwrap();
        drop(participant);
        return;
    }
    if let [mode, root] = args.as_slice()
        && mode == "sole"
    {
        let participant = drafts::coordination::join(Path::new(root)).unwrap();
        println!(
            "{}",
            json!({"allowed":drafts::coordination::while_sole(&participant,&Path::new(root).join("original"),||Ok(())).is_ok()})
        );
        return;
    }
    println!("{}", cases());
}
