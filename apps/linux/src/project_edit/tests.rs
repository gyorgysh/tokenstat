// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use crate::client::Client;
use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixListener,
};

fn fake_call(
    method: &str,
    params: Value,
    answer: Value,
    run: impl FnOnce(Client) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("host.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let method = method.to_owned();
    let server = std::thread::spawn(move || {
        drop(listener.accept().unwrap());
        for (method, params, answer) in [
            (
                "protocol".to_owned(),
                json!({}),
                json!({"protocolVersion":"53"}),
            ),
            (method, params, answer),
        ] {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], method);
            assert_eq!(request["params"], params);
            writeln!(
                reader.get_mut(),
                "{}",
                json!({"id":request["id"],"ok":true,"result":answer})
            )
            .unwrap();
        }
    });
    let result = run(Client {
        socket,
        allow_spawn: false,
    });
    server.join().unwrap();
    result
}
#[test]
fn rename_and_remove_use_existing_dispatch_and_require_the_source_acknowledgement_shape() {
    for answer in [
        json!({"renamed":true}),
        json!({"renamed":false}),
        json!({"renamed":"yes"}),
        json!({}),
    ] {
        let valid = answer["renamed"].is_boolean();
        let result = fake_call(
            "workspace.rename",
            json!({"id":"/fixture/á:b","name":"Renamed 日本"}),
            answer,
            |client| client.rename_repository("/fixture/á:b", "Renamed 日本"),
        );
        assert_eq!(result.is_ok(), valid);
    }
    fake_call(
        "remote.call",
        json!({"peer":"peer","method":"workspace.rename","params":{"id":"a:b","name":"Name"}}),
        json!({"renamed":true}),
        |client| client.rename_repository("remote:peer:a:b", "Name"),
    )
    .unwrap();
    for route in [
        RemovalRoute::Local {
            id: "/fixture/project".into(),
        },
        RemovalRoute::Remote {
            peer: "peer".into(),
            id: "raw:project".into(),
        },
    ] {
        let (method, params) = match &route {
            RemovalRoute::Local { id } => ("workspace.remove", json!({"id":id})),
            RemovalRoute::Remote { peer, id } => (
                "remote.call",
                json!({"peer":peer,"method":"workspace.remove","params":{"id":id}}),
            ),
            _ => unreachable!(),
        };
        fake_call(method, params, json!({"removed":false}), |client| {
            client.remove_repository(&route)
        })
        .unwrap();
    }
    let client = Client {
        socket: "/nonexistent-fixture-socket".into(),
        allow_spawn: false,
    };
    client
        .remove_repository(&RemovalRoute::ForgetRemote {
            peer: "peer".into(),
        })
        .unwrap();
}
#[test]
fn directory_reload_has_no_git_side_effect_request_and_empty_is_authoritative() {
    fake_call(
        "workspace.list",
        json!({"includeGit":false}),
        json!([]),
        |client| {
            assert!(client.repositories()?.is_empty());
            Ok(())
        },
    )
    .unwrap();
}
#[test]
fn rename_relabel_never_recreates_a_pin_removed_while_the_host_was_saving() {
    use crate::work::{Scope, continuity::Date, pins::Pins, preferences::Preferences};
    let root = tempfile::tempdir().unwrap();
    let preferences = Preferences::at(root.path().join("work.json"));
    let reference =
        crate::project_menu::reference(Some(&Scope::local("fixture")), Some("host"), "/fixture")
            .unwrap();
    let first = Pins {
        preferences: preferences.clone(),
    };
    let other = Pins {
        preferences: Preferences::at(root.path().join("work.json")),
    };
    assert!(
        !first
            .relabel_if_pinned(&reference, "New", "Folder", Date(2.))
            .unwrap()
    );
    first.pin(&reference, "Old", "Folder", Date(1.)).unwrap();
    other.unpin(&reference).unwrap();
    assert!(
        !first
            .relabel_if_pinned(&reference, "New", "Folder", Date(2.))
            .unwrap()
    );
    assert!(!first.is_pinned(&reference).unwrap());
    other.pin(&reference, "Again", "Folder", Date(3.)).unwrap();
    assert!(
        first
            .relabel_if_pinned(&reference, "Updated", "Updated", Date(4.))
            .unwrap()
    );
    assert_eq!(
        other.pins(Some(&reference.scope)).unwrap()[0].label,
        "Updated"
    );
}
