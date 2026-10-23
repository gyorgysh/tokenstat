// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;

fn service(budget: Duration) -> Service {
    Service::bind(
        Budget {
            deadline: Deadline::capture(budget).unwrap(),
            wall_end: wall_ms().unwrap() + budget.as_millis(),
        },
        json!({"title":"Fixture context","message":{"text":"Original Ask"},"events":[]}),
        "run_fixture".into(),
        Box::new(|| true),
    )
    .unwrap()
}
fn request(service: &Service, token: &str, request: Value) -> io::Result<Value> {
    let mut stream = TcpStream::connect(service.address)?;
    write_frame(
        &mut stream,
        &Envelope {
            version: 1,
            token: token.into(),
            generation: service.shared.generation.load(Ordering::Acquire),
            request,
        },
        REQUEST,
        || Ok(()),
    )?;
    serde_json::from_slice(&read_frame(&mut stream, RESPONSE, || Ok(()))?)
        .map_err(|_| unavailable())
}
fn call(service: &Service, name: &str, args: Value) -> Value {
    request(service, &tokenstat_identity::hex(&service.shared.token), json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":name,"arguments":args}})).unwrap()
}

#[test]
fn scoped_context_charts_and_status_have_no_personal_dispatch() {
    let sdk = service(Duration::from_secs(10));
    assert_eq!(
        call(&sdk, "team_context", json!({}))["result"]["structuredContent"]["data"]["message"]["text"],
        "Original Ask"
    );
    sdk.running().unwrap();
    assert_eq!(
        call(&sdk, "team_run_status", json!({}))["result"]["structuredContent"]["data"],
        json!({"runId":"run_fixture","state":"running"})
    );
    for name in ["chart_create", "chart_validate"] {
        let reply = call(
            &sdk,
            name,
            json!({"chart":tokenstat_core::chart::examples()[0]}),
        );
        assert_eq!(reply["result"]["structuredContent"]["valid"], true);
        assert!(
            reply["result"]["content"][0]["text"]
                .as_str()
                .unwrap()
                .starts_with("```tokenstat-chart\n")
        );
    }
    for name in [
        "workspace_list",
        "chat_send",
        "task_delegate",
        "totals",
        "vault",
        "team_stop",
    ] {
        assert_eq!(
            call(&sdk, name, json!({}))["result"]["isError"],
            true,
            "{name}"
        );
    }
    for args in [
        json!({"id":"other-chat"}),
        json!({"workspaceId":"other"}),
        json!({"text":"Change the Ask"}),
        json!(null),
    ] {
        assert_eq!(call(&sdk, "team_context", args)["result"]["isError"], true);
    }
    assert_eq!(
        call(
            &sdk,
            "chart_create",
            json!({"chart":tokenstat_core::chart::examples()[0],"target":"personal"})
        )["result"]["isError"],
        true
    );
    assert_eq!(
        call(&sdk, "chart_create", json!({"chart":{"script":"evil"}}))["result"]["isError"],
        true
    );
    let token = tokenstat_identity::hex(&sdk.shared.token);
    for method in [
        "chat.send",
        "workspace.write",
        "resources/read",
        "prompts/get",
    ] {
        assert_eq!(
            request(
                &sdk,
                &token,
                json!({"jsonrpc":"2.0","id":2,"method":method})
            )
            .unwrap()["error"]["code"],
            -32601
        );
    }
}

#[test]
fn team_hook_policy_and_lane_tools_share_only_current_run_authority() {
    let root = tempfile::tempdir().unwrap();
    let live = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let current = live.clone();
    let sdk = Service::bind_context(
        Budget {
            deadline: Deadline::capture(Duration::from_secs(10)).unwrap(),
            wall_end: wall_ms().unwrap() + 10_000,
        },
        json!({}),
        2,
        None,
        "run_fixture".into(),
        Box::new(move || current.load(Ordering::Acquire)),
        Some(files::LaneFiles::bind(root.path()).unwrap()),
    )
    .unwrap();
    let token = tokenstat_identity::hex(&sdk.shared.token);
    for name in [
        "exec_command",
        "Bash",
        "Read",
        "apply_patch",
        "mcp__personal__vault",
        "mcp__tokenstat_team__unknown",
    ] {
        assert_eq!(
            request(
                &sdk,
                &token,
                json!({"jsonrpc":"2.0","id":1,"method":"team/tool-policy","params":{"name":name}})
            )
            .unwrap()["result"]["allow"],
            false,
            "{name}"
        );
    }
    for name in [
        "mcp__tokenstat_team__team_context",
        "mcp__tokenstat_team__team_file_write",
    ] {
        assert_eq!(
            request(
                &sdk,
                &token,
                json!({"jsonrpc":"2.0","id":1,"method":"team/tool-policy","params":{"name":name}})
            )
            .unwrap()["result"]["allow"],
            true,
            "{name}"
        );
    }
    assert_eq!(
        call(
            &sdk,
            "team_file_write",
            json!({"path":"new.txt","content":"lane work"})
        )["result"]["isError"],
        Value::Null
    );
    assert_eq!(
        call(&sdk, "team_file_read", json!({"path":"new.txt"}))["result"]["structuredContent"]["data"]
            ["text"],
        "lane work"
    );
    live.store(false, Ordering::Release);
    assert!(request(&sdk,&token,json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"team_file_write","arguments":{"path":"new.txt","content":"expired"}}})).is_err());
    assert_eq!(
        std::fs::read_to_string(root.path().join("new.txt")).unwrap(),
        "lane work"
    );
}

#[test]
fn pausing_files_drains_guardian_workers_before_landing_or_writer_release() {
    use std::sync::mpsc;
    let root = tempfile::tempdir().unwrap();
    let sdk = Arc::new(
        Service::bind_context(
            Budget {
                deadline: Deadline::capture(Duration::from_secs(10)).unwrap(),
                wall_end: wall_ms().unwrap() + 10_000,
            },
            json!({}),
            2,
            None,
            "run_fixture".into(),
            Box::new(|| true),
            Some(files::LaneFiles::bind(root.path()).unwrap()),
        )
        .unwrap(),
    );
    let (entered, waiting) = mpsc::channel();
    let (release, resume) = mpsc::channel();
    let shared = sdk.shared.clone();
    let worker = std::thread::spawn(move || {
        let lane = shared.lane.as_ref().unwrap().lock().unwrap();
        let checks = std::cell::Cell::new(0);
        lane.as_ref().unwrap().call(
            "team_file_write",
            &json!({"path":"late.txt","content":"too late"}),
            || {
                checks.set(checks.get() + 1);
                if checks.get() == 2 {
                    entered.send(()).unwrap();
                    resume.recv().unwrap();
                }
                shared.file_live(0)
            },
        )
    });
    waiting.recv_timeout(Duration::from_secs(2)).unwrap();
    let (done, finished) = mpsc::channel();
    let pausing = sdk.clone();
    let pauser = std::thread::spawn(move || {
        pausing.pause_files();
        done.send(()).unwrap();
    });
    let early = finished.recv_timeout(Duration::from_millis(50));
    release.send(()).unwrap();
    let result = worker.join().unwrap();
    pauser.join().unwrap();
    assert!(
        early.is_err(),
        "pause must wait for the in-flight guardian file operation"
    );
    assert!(result.is_err());
    assert!(!root.path().join("late.txt").exists());
    assert_eq!(
        call(
            &sdk,
            "team_file_write",
            json!({"path":"paused.txt","content":"no"})
        )["result"]["isError"],
        true
    );
    sdk.resume_files().unwrap();
    let mut stale = TcpStream::connect(sdk.address).unwrap();
    write_frame(&mut stale,&Envelope {version:1,token:tokenstat_identity::hex(&sdk.shared.token),generation:0,request:json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"team_file_write","arguments":{"path":"stale.txt","content":"old attempt"}}})},REQUEST,||Ok(())).unwrap();
    assert!(read_frame(&mut stale, RESPONSE, || Ok(())).is_err());
    assert!(!root.path().join("stale.txt").exists());
    assert_ne!(
        call(
            &sdk,
            "team_file_write",
            json!({"path":"repair.txt","content":"new attempt"})
        )["result"]["isError"],
        true
    );
    sdk.retire();
    assert!(sdk.shared.lane.as_ref().unwrap().lock().unwrap().is_none());
}

#[test]
fn wrong_token_expiry_and_explicit_retirement_fail_closed() {
    let sdk = service(Duration::from_secs(10));
    assert!(
        request(
            &sdk,
            &"00".repeat(32),
            json!({"jsonrpc":"2.0","id":1,"method":"tools/list"})
        )
        .is_err()
    );
    assert!(sdk.shared.live().is_ok());
    sdk.retire();
    assert!(sdk.shared.live().is_err());
    assert!(
        request(
            &sdk,
            &tokenstat_identity::hex(&sdk.shared.token),
            json!({"jsonrpc":"2.0","id":1,"method":"tools/list"})
        )
        .is_err()
    );
    let expired = service(Duration::from_secs(10));
    {
        let mut gate = expired.shared.gate.lock().unwrap();
        gate.budget.deadline = Deadline::capture(Duration::ZERO).unwrap();
    }
    assert!(expired.shared.live().is_err());
    // A later budget cannot revive an instance which observed expiry.
    expired.shared.gate.lock().unwrap().budget.deadline =
        Deadline::capture(Duration::from_secs(60)).unwrap();
    assert!(expired.shared.live().is_err());
}

#[test]
fn account_retirement_is_checked_before_disclosing_context() {
    let current = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let held = current.clone();
    let sdk = Service::bind(
        Budget {
            deadline: Deadline::capture(Duration::from_secs(10)).unwrap(),
            wall_end: wall_ms().unwrap() + 10000,
        },
        json!({"private":"accepted fixture context"}),
        "run_fixture".into(),
        Box::new(move || held.load(Ordering::Acquire)),
    )
    .unwrap();
    assert!(sdk.shared.live().is_ok());
    current.store(false, Ordering::Release);
    assert!(
        request(
            &sdk,
            &tokenstat_identity::hex(&sdk.shared.token),
            json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"team_context"}})
        )
        .is_err()
    );
    current.store(true, Ordering::Release);
    assert!(sdk.shared.live().is_err());
}

#[test]
fn malformed_requests_and_extra_routing_fields_cannot_be_dispatched() {
    let sdk = service(Duration::from_secs(10));
    let token = tokenstat_identity::hex(&sdk.shared.token);
    for request in [
        json!({"jsonrpc":"2.0","id":[],"method":"tools/list"}),
        json!({"jsonrpc":"1.0","id":1,"method":"tools/list"}),
        json!({"jsonrpc":"2.0","id":1,"method":"tools/list","target":"personal"}),
    ] {
        assert_eq!(
            super::tests::request(&sdk, &token, request).unwrap()["error"]["code"],
            -32600
        );
    }
    assert!(
        handle(
            &sdk.shared,
            json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
            0,
        )
        .is_null()
    );
}

#[test]
fn framing_is_bounded_and_retirement_interrupts_partial_requests() {
    let sdk = service(Duration::from_secs(10));
    let mut stream = TcpStream::connect(sdk.address).unwrap();
    stream.write_all(b"{\"version\":1").unwrap();
    std::thread::sleep(Duration::from_millis(40));
    sdk.retire();
    let start = Instant::now();
    let mut out = [0; 1];
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .unwrap();
    assert!(matches!(stream.read(&mut out), Ok(0) | Err(_)));
    assert!(start.elapsed() < Duration::from_secs(1));
    let sdk = service(Duration::from_secs(10));
    let mut stream = TcpStream::connect(sdk.address).unwrap();
    assert!(write_frame(&mut stream, &"x".repeat(REQUEST), REQUEST, || Ok(())).is_err());
}

#[test]
fn a_large_escaped_context_fits_the_bounded_mcp_response() {
    let text = "\\".repeat(CONTEXT / 4);
    let sdk = Service::bind(
        Budget {
            deadline: Deadline::capture(Duration::from_secs(10)).unwrap(),
            wall_end: wall_ms().unwrap() + 10000,
        },
        json!({"message":{"text":text}}),
        "run_fixture".into(),
        Box::new(|| true),
    )
    .unwrap();
    let response = call(&sdk, "team_context", json!({}));
    assert_eq!(
        response["result"]["structuredContent"]["data"]["message"]["text"],
        text
    );
    assert!(serde_json::to_vec(&response).unwrap().len() > 6 * 1024 * 1024);
}

#[test]
fn slow_connections_cannot_create_unbounded_workers_or_hold_them_forever() {
    let sdk = service(Duration::from_secs(10));
    let mut held = Vec::new();
    for _ in 0..4 {
        let mut stream = TcpStream::connect(sdk.address).unwrap();
        stream.write_all(b"{").unwrap();
        held.push(stream);
    }
    let start = Instant::now();
    while sdk.shared.workers.load(Ordering::Acquire) < 4 {
        assert!(start.elapsed() < Duration::from_secs(1));
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        request(
            &sdk,
            &tokenstat_identity::hex(&sdk.shared.token),
            json!({"jsonrpc":"2.0","id":1,"method":"tools/list"})
        )
        .is_err()
    );
    while sdk.shared.workers.load(Ordering::Acquire) > 0 {
        assert!(start.elapsed() < Duration::from_secs(3));
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        call(&sdk, "team_run_status", json!({}))["result"]["structuredContent"]["data"]["runId"],
        "run_fixture"
    );
}

#[test]
fn stop_does_not_wait_for_a_slow_account_or_publication_check() {
    use std::sync::{atomic::AtomicBool, mpsc};
    let checking = Arc::new(AtomicBool::new(false));
    let held = checking.clone();
    let (entered, started) = mpsc::channel();
    let (release, waiting) = mpsc::channel();
    let waiting = Mutex::new(waiting);
    let sdk = Service::bind(
        Budget {
            deadline: Deadline::capture(Duration::from_secs(10)).unwrap(),
            wall_end: wall_ms().unwrap() + 10000,
        },
        json!({}),
        "run_fixture".into(),
        Box::new(move || {
            if held.load(Ordering::Acquire) {
                entered.send(()).unwrap();
                waiting.lock().unwrap().recv().unwrap();
            }
            true
        }),
    )
    .unwrap();
    checking.store(true, Ordering::Release);
    let shared = sdk.shared.clone();
    let worker = std::thread::spawn(move || shared.live());
    started.recv_timeout(Duration::from_secs(1)).unwrap();
    sdk.retire();
    assert!(sdk.shared.budget_live().is_err());
    release.send(()).unwrap();
    assert!(worker.join().unwrap().is_err());
}

fn bind_context(context: Value) -> io::Result<Service> {
    // These fixtures verify paging and size bounds. Give a loaded runner
    // time to read every page; lease expiry has separate short-budget tests.
    let budget = Duration::from_secs(60);
    Service::bind(
        Budget {
            deadline: Deadline::capture(budget).unwrap(),
            wall_end: wall_ms().unwrap() + budget.as_millis(),
        },
        context,
        "run_fixture".into(),
        Box::new(|| true),
    )
}

#[test]
fn context_above_four_mib_is_paged_and_keeps_the_original_ask() {
    let events: Vec<_> = (0..60)
        .map(|n| json!({"n": n, "text": "a".repeat(80_000)}))
        .collect();
    let sdk = bind_context(json!({
        "title": "Long",
        "backend": "fixture",
        "historyTrimmed": true,
        "message": {"text": "Original Ask"},
        "events": events,
    }))
    .unwrap();
    let mut seen = Vec::new();
    let mut cursor: Option<String> = None;
    for _ in 0..80 {
        let args = match &cursor {
            None => json!({}),
            Some(cursor) => json!({"cursor": cursor}),
        };
        let data = call(&sdk, "team_context", args)["result"]["structuredContent"]["data"].clone();
        assert_eq!(data["message"]["text"], "Original Ask");
        assert_eq!(data["title"], "Long");
        assert_eq!(data["historyTrimmed"], true);
        assert_eq!(data["eventCount"], 60);
        let page = data["events"].as_array().unwrap();
        assert!(!page.is_empty());
        seen.extend(page.clone());
        match data.get("nextCursor").and_then(Value::as_str) {
            Some(next) => cursor = Some(next.to_string()),
            None => {
                assert!(data["nextCursor"].is_null());
                cursor = None;
                break;
            }
        }
    }
    assert!(cursor.is_none());
    assert_eq!(seen, events);
    assert_eq!(
        call(&sdk, "team_context", json!({"cursor": "01"}))["result"]["isError"],
        true
    );
    assert_eq!(
        call(&sdk, "team_context", json!({"cursor": "61"}))["result"]["isError"],
        true
    );
}

#[test]
fn an_unpageable_or_oversized_snapshot_is_refused() {
    assert!(bind_context(json!({"message": {"text": "a".repeat(CONTEXT + 1)}})).is_err());
    let huge = "b".repeat(SNAPSHOT);
    assert!(bind_context(json!({"message": {"text": "Ask"}, "events": [{"text": huge}]})).is_err());
    let sdk = bind_context(json!({
        "message": {"text": "Ask"},
        "events": [{"text": "c".repeat(PAGE)}],
    }))
    .unwrap();
    assert_eq!(
        call(&sdk, "team_context", json!({"cursor": "0"}))["result"]["content"][0]["text"],
        "This context page is too large."
    );
}
