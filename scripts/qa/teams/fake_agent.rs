// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Disposable Team process fixture. Its SDK calls stay on the guardian's loopback socket.

use std::{
    fs,
    io::{self, Read, Write},
    path::PathBuf,
    process::{Command, Stdio},
    time::Duration,
};

fn sdk(helper: &str, request: &str, wrong_token: bool) -> std::process::Output {
    let address = std::env::var("TOKENSTAT_TEAM_SDK_ADDRESS").unwrap();
    let token = if wrong_token {
        "00".repeat(32)
    } else {
        std::env::var("TOKENSTAT_TEAM_SDK_TOKEN").unwrap()
    };
    let mut command = Command::new(helper);
    command
        .arg("team-run-sdk")
        .env_clear()
        .env("TOKENSTAT_TEAM_SDK_ADDRESS", address)
        .env("TOKENSTAT_TEAM_SDK_TOKEN", token)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
        if let Some(root) = std::env::var_os("SystemRoot") {
            command.env("SystemRoot", root);
        }
    }
    let mut child = command.spawn().unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(request.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn check_sdk(helper: &str, state: &std::path::Path) {
    let requests = concat!(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"fixture\",\"version\":\"1\"}}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"team_context\",\"arguments\":{}}}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"workspace_list\",\"arguments\":{}}}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"chat.send\",\"params\":{\"text\":\"must never dispatch\"}}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"team_context\",\"arguments\":{\"id\":\"personal\"}}}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"chart_examples\",\"arguments\":{}}}\n"
    );
    let output = sdk(helper, requests, false);
    assert!(output.status.success());
    let reply = String::from_utf8(output.stdout).unwrap();
    assert_eq!(reply.lines().count(), 7);
    assert!(reply.contains("Fictional supervised Ask"));
    assert!(!reply.contains("PRIVATE_FIXTURE"));
    assert!(reply.contains("chart_create"));
    assert!(reply.contains("This tool is unavailable in a Team run."));
    assert!(reply.contains("This method is unavailable in a Team run."));
    assert!(reply.contains("This tool accepts no target or arguments."));
    assert!(!sdk(helper, requests, true).status.success());
    let output = sdk(
        helper,
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"chart_create\",\"arguments\":{\"chart\":{\"version\":1,\"type\":\"bar\",\"title\":\"Fictional Team chart\",\"categories\":[\"A\",\"B\"],\"series\":[{\"name\":\"Count\",\"data\":[3,7]}]}}}}\n",
        false,
    );
    assert!(output.status.success());
    let reply = String::from_utf8(output.stdout).unwrap();
    assert!(reply.contains("tokenstat-chart") && reply.contains("\"valid\":true"));
    // Only a test completion marker; no scope token or context is recorded.
    fs::write(state.with_extension("sdk"), "scoped MCP bridge verified").unwrap();
}

fn main() {
    let args = std::env::args().collect::<Vec<_>>();
    if args.get(1).is_some_and(|arg| arg == "leaf") {
        let beat = args.get(2).expect("fixture heartbeat");
        let mut count = 0u64;
        loop {
            fs::write(beat, count.to_string()).unwrap();
            count += 1;
            std::thread::sleep(Duration::from_millis(40));
        }
    }
    let mode = args.get(1).expect("fixture mode");
    let state = PathBuf::from(args.get(2).expect("fixture state"));
    let mut context = String::new();
    io::stdin().read_to_string(&mut context).unwrap();
    if context.contains("conflict markers") {
        // A follow-up after a conflicting landing: resolve every marker.
        let shared = std::path::Path::new("shared.txt");
        assert!(fs::read_to_string(shared).unwrap().contains("<<<<<<<"));
        fs::write(shared, "teammate and agent\n").unwrap();
        println!("{}", r#"{"type":"item.completed","item":{"id":"fixture-fix","type":"agent_message","text":"Fictional conflict resolved"}}"#);
        println!("{}", r#"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}"#);
        return;
    }
    assert!(context.contains("Fictional supervised Ask"));
    assert!(!context.contains("PRIVATE_FIXTURE"));
    let later_was_approved = context.contains("Fictional later discussion");
    assert!(std::env::var_os("TOKENSTAT_GUARDIAN_PRIVATE_SENTINEL").is_none());
    if std::env::var_os("TOKENSTAT_TEAM_SDK_ADDRESS").is_some() {
        check_sdk(args.get(3).expect("fixture SDK helper"), &state);
    }
    println!(
        "{}",
        r#"{"type":"thread.started","thread_id":"PRIVATE_FIXTURE_VENDOR_SESSION"}"#
    );
    println!(
        "{}",
        r#"{"type":"item.completed","item":{"id":"fixture-result","type":"agent_message","text":"Fictional guardian reply\n```tokenstat-chart\n{\"version\":1,\"type\":\"bar\",\"title\":\"Fictional Team chart\",\"categories\":[\"A\",\"B\"],\"series\":[{\"name\":\"Count\",\"data\":[3,7]}]}\n```"}}"#
    );
    // A provider's Done record cannot release the checkout while the owned
    // fake process and its descendants are still alive.
    println!(
        "{}",
        r#"{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":20}}"#
    );
    io::stdout().flush().unwrap();
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .arg("leaf")
        .arg(state.with_extension("leaf"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    let child = command.spawn().unwrap();
    fs::write(&state, format!("{} {}", std::process::id(), child.id())).unwrap();
    if mode == "edit" {
        // A lane agent's whole job: change a file in its own folder.
        fs::write("lane-edit.txt", "Fictional lane change\n").unwrap();
    }
    if mode == "conflict" {
        // A teammate lands a change to the same line while this agent works.
        let remote = args.get(4).expect("fixture remote");
        let other = state.with_extension("teammate");
        let git = |dir: &std::path::Path, list: &[&str]| {
            let status = Command::new("git")
                .arg("-C")
                .arg(dir)
                .args(["-c", "user.name=Teammate", "-c", "user.email=teammate@example.invalid", "-c", "commit.gpgSign=false"])
                .args(list)
                .status()
                .unwrap();
            assert!(status.success());
        };
        git(state.parent().unwrap(), &["clone", "-q", remote, other.to_str().unwrap()]);
        fs::write(other.join("shared.txt"), "teammate\n").unwrap();
        git(&other, &["commit", "-qam", "Teammate change"]);
        git(&other, &["push", "-q", "origin", "main"]);
        fs::write("shared.txt", "agent\n").unwrap();
    }
    if mode == "finish" || mode == "edit" || mode == "conflict" {
        return;
    }
    #[cfg(unix)]
    unsafe {
        use std::os::fd::FromRawFd;
        drop(fs::File::from_raw_fd(1));
        drop(fs::File::from_raw_fd(2));
    }
    #[cfg(windows)]
    unsafe {
        use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
        drop(OwnedHandle::from_raw_handle(io::stdout().as_raw_handle()));
        drop(OwnedHandle::from_raw_handle(io::stderr().as_raw_handle()));
    }
    let mut count = 0u64;
    loop {
        if count % 25 == 0
            && let Some(helper) = args.get(3)
        {
            let result = sdk(
                helper,
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"team_run_status\"}}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"team_context\"}}\n",
                false,
            );
            if result.status.success() {
                let reply = String::from_utf8(result.stdout).unwrap();
                assert!(reply.contains("running"));
                assert!(reply.contains("Fictional supervised Ask"));
                assert_eq!(
                    reply.contains("Fictional later discussion"),
                    later_was_approved
                );
                fs::write(state.with_extension("sdk-beat"), count.to_string()).unwrap();
            }
        }
        fs::write(state.with_extension("root"), count.to_string()).unwrap();
        count += 1;
        std::thread::sleep(Duration::from_millis(40));
    }
}
