// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#![cfg(all(unix, feature = "local-host"))]

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

struct Runner(std::process::Child);
impl Drop for Runner {
    fn drop(&mut self) {
        if self.0.try_wait().is_ok_and(|status| status.is_some()) {
            return;
        }
        unsafe {
            libc::kill(self.0.id() as i32, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if self.0.try_wait().is_ok_and(|status| status.is_some()) {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

const FAKE: &str = r#"#!/usr/bin/env python3
import base64, http.server, json, os, pathlib, sys, threading, time
root=pathlib.Path.cwd()
def event(kind, **kw):
    value={'id':'evt_part','type':'session.text.'+kind,'data':{'sessionID':'ses_main','assistantMessageID':'msg_text','ordinal':0,**kw}}
    with (root/'events').open('a') as f: f.write(json.dumps(value,ensure_ascii=False)+'\n')
if sys.argv[1]=='serve':
    (root/'server-pid').write_text(str(os.getpid()))
    assert os.environ['TOKENSTAT_TURN_MARKER']=='owned-turn'
    if os.environ.get('TOKENSTAT_STARTUP_HANG'):
        time.sleep(60);sys.exit(1)
    expected='Basic '+base64.b64encode(('opencode:'+os.environ['OPENCODE_PASSWORD']).encode()).decode()
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def do_POST(self):
            if self.path=='/api/session/ses_main/prompt':
                assert self.headers['Authorization']==expected
                body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                assert body['text']=='café steer 🌍' and body['delivery']=='steer' and body['resume'] is False
                assert body['files']==[]
                (root/'steered.json').write_text(json.dumps(body))
                with (root/'events').open('a') as f:f.write(json.dumps({'type':'session.inbox.delivered','data':{'sessionID':'ses_main','inboxID':body['id']}})+'\n')
                ack={'data':{'id':body['id'],'sessionID':'ses_main','type':'user','delivery':'steer','payload':{'text':body['text']}}}
                self.send_response(200);self.end_headers();self.wfile.write(json.dumps(ack).encode());return
            assert self.path=='/api/session/ses_main/interrupt'
            assert self.headers['Authorization']==expected
            (root/'interrupted').write_text('true')
            with (root/'events').open('a') as f:f.write(json.dumps({'type':'session.execution.interrupted','data':{'sessionID':'ses_main'}})+'\n')
            self.send_response(200);self.end_headers();self.wfile.write(b'{"interrupted":true}')
        def do_GET(self):
            assert self.path=='/api/event'
            assert self.headers['Authorization']==expected
            self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
            self.wfile.write(b'data: {"type":"server.connected"}\n\n');self.wfile.flush()
            with (root/'events').open() as events:
                while True:
                    line=events.readline()
                    if not line: time.sleep(.005);continue
                    value=json.loads(line)
                    self.wfile.write(('data: '+line+'\n').encode());self.wfile.flush()
                    if os.environ.get('TOKENSTAT_DISCONNECT') and value['type']=='session.text.delta': return
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    print(json.dumps({'url':'http://127.0.0.1:'+str(server.server_port)}),flush=True)
    def end_lease():
        sys.stdin.read()
        (root/'lease-closed').write_text('true')
        server.shutdown()
    threading.Thread(target=end_lease,daemon=True).start()
    server.serve_forever()
elif sys.argv[1]=='run':
    (root/'cli-pid').write_text(str(os.getpid()))
    assert '--standalone' not in sys.argv and '--server' in sys.argv
    assert sys.argv[sys.argv.index('--model')+1]=='opencode/deepseek-v4.1-flash-free#low'
    assert sys.argv[sys.argv.index('--session')+1]=='ses_main'
    assert sys.argv[sys.argv.index('--file')+1]=='sample ü.txt'
    def emit(v):print(json.dumps(v,ensure_ascii=False),flush=True)
    emit({'type':'step_start','sessionID':'ses_main','part':{'messageID':'msg_text'}})
    event('started');event('delta',delta='café ')
    if os.environ.get('TOKENSTAT_BACKPRESSURE'):
        for _ in range(40):event('delta',delta='x'*(512*1024))
    while not (root/'continue').exists():
        if (root/'interrupted').exists():sys.exit(130)
        time.sleep(.005)
    event('delta',delta='🌍.');event('ended',text='café 🌍.')
    emit({'type':'text','sessionID':'ses_main','part':{'id':'prt_part','messageID':'msg_text','text':'café 🌍.'}})
    step={'sessionID':'ses_main','assistantMessageID':'msg_text','finish':'stop','tokens':{'input':4,'output':2,'reasoning':3,'cache':{'read':7,'write':1}},'cost':.012}
    with (root/'events').open('a') as f:
        f.write(json.dumps({'type':'session.step.ended','data':step})+'\n')
        f.write(json.dumps({'type':'session.execution.succeeded','data':{'sessionID':'ses_main'}})+'\n')
    emit({'type':'step_finish','sessionID':'ses_main','part':{'messageID':'msg_text','reason':'stop','tokens':step['tokens'],'cost':step['cost']}})
"#;

fn run_case(disconnect: bool, stop: bool, startup_stop: bool, backpressure: bool, steer: bool) {
    let root = tempfile::tempdir().unwrap();
    let project = root.path().join("project ü");
    fs::create_dir(&project).unwrap();
    fs::write(project.join("events"), "").unwrap();
    let fake = root.path().join("opencode2");
    fs::write(&fake, FAKE).unwrap();
    fs::set_permissions(&fake, fs::Permissions::from_mode(0o700)).unwrap();
    let config = root.path().join("config.json");
    fs::write(&config, json!({"backend":"opencode2","argv":[fake,"run","--standalone","--thinking","--auto","--format","json","--model","opencode/deepseek-v4.1-flash-free#low","--session","ses_main","--file","sample ü.txt","--","literal prompt"]}).to_string()).unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_tokenstat-hostd"));
    command
        .args(["chat-live", config.to_str().unwrap()])
        .current_dir(&project)
        .env("TOKENSTAT_TURN_MARKER", "owned-turn")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if disconnect {
        command.env("TOKENSTAT_DISCONNECT", "1");
    }
    if startup_stop {
        command.env("TOKENSTAT_STARTUP_HANG", "1");
    }
    if backpressure {
        command.env("TOKENSTAT_BACKPRESSURE", "1");
    }
    let mut runner = Runner(command.spawn().unwrap());
    let child = &mut runner.0;
    let (tx, rx) = mpsc::channel();
    let (release, blocked) = mpsc::channel::<()>();
    let stdout = child.stdout.take().unwrap();
    let reader = std::thread::spawn(move || {
        let mut records = Vec::new();
        let mut reader = BufReader::new(stdout);
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap() == 0 {
                break;
            }
            if !line.ends_with('\n') {
                // A deliberately unread output pipe cannot finish its last
                // frame within Stop's flush budget. The host parser drops
                // this incomplete tail; all prior records remain valid.
                assert!(backpressure);
                assert!(serde_json::from_str::<Value>(&line).is_err());
                assert_eq!(reader.read_line(&mut String::new()).unwrap(), 0);
                break;
            }
            let value: Value = serde_json::from_str(&line).unwrap();
            if value["type"] == "tokenstat.opencode.delta" {
                let _ = tx.send(());
                if backpressure {
                    let _ = blocked.recv();
                }
            }
            records.push(value);
        }
        records
    });
    if startup_stop {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !project.join("server-pid").exists() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
    } else {
        rx.recv_timeout(Duration::from_secs(10))
            .expect("native text must arrive before releasing the CLI snapshot");
    }
    if steer {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !root.path().join("ready.json").exists() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        let id = "0123456789abcdef0123456789abcdef";
        let expires = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64
            + 10000;
        fs::write(
            root.path().join(format!("request-{id}.json")),
            json!({"id":id,"steer":"café steer 🌍","images":[],"expires":expires}).to_string(),
        )
        .unwrap();
        let response = root.path().join(format!("response-{id}.json"));
        while !response.exists() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        let response: Value = serde_json::from_slice(&fs::read(response).unwrap()).unwrap();
        assert_eq!(response["ok"], true);
        assert!(project.join("steered.json").is_file());
    }
    let stopping = Instant::now();
    if backpressure {
        std::thread::sleep(Duration::from_millis(300));
    }
    if stop || startup_stop {
        fs::write(root.path().join("stop"), "").unwrap();
    } else {
        fs::write(project.join("continue"), "").unwrap();
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            panic!("stream helper did not finish");
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    drop(release);
    let records = reader.join().unwrap();
    if stop || startup_stop {
        assert!(!status.success());
        assert!(stopping.elapsed() < Duration::from_secs(4));
        if stop {
            assert!(
                project.join("interrupted").exists(),
                "Stop must use the native interrupt before retiring the server"
            );
        }
    } else {
        assert!(status.success());
        assert!(
            project.join("lease-closed").exists(),
            "the server must receive lease EOF before forced cleanup"
        );
        let text: String = records
            .iter()
            .filter(|record| record["type"] == "tokenstat.opencode.delta")
            .filter_map(|record| record["part"]["text"].as_str())
            .collect();
        assert!(text.starts_with("café ") && "café 🌍.".starts_with(&text));
        assert!(
            records
                .iter()
                .any(|record| record["type"] == "text" && record["part"]["text"] == "café 🌍.")
        );
        let usage: Vec<_> = records
            .iter()
            .filter(|record| record["type"] == "step_finish")
            .collect();
        assert!(!usage.is_empty());
        // The parser unit tests fold these same correlated snapshots into
        // one Usage event. Check the process boundary preserved identity.
        for record in usage {
            assert_eq!(record["tokenstatStep"], "msg_text");
            assert_eq!(record["part"]["tokens"]["output"], 5);
            assert_eq!(record["part"]["cost"], 0.012);
        }
    }
    for file in ["cli-pid", "server-pid"] {
        if let Ok(pid) = fs::read_to_string(project.join(file)) {
            let pid = pid.trim().parse::<i32>().unwrap();
            assert_eq!(
                unsafe { libc::kill(pid, 0) },
                -1,
                "{file} process survived its owner"
            );
        }
    }
}

#[test]
fn native_deltas_precede_completion_and_usage_is_not_doubled() {
    run_case(false, false, false, false, false);
}

#[test]
fn a_disconnected_observer_keeps_the_cli_completion_without_resending() {
    run_case(true, false, false, false, false);
}

#[test]
fn stop_retires_the_owned_cli_and_server() {
    run_case(false, true, false, false, false);
}

#[test]
fn stop_during_server_startup_is_bounded() {
    run_case(false, false, true, false, false);
}

#[test]
fn stop_interrupts_native_execution_when_stdout_is_not_consumed() {
    run_case(false, true, false, true, false);
}

#[test]
fn steering_is_acknowledged_by_the_same_native_session_without_restarting_the_cli() {
    run_case(false, false, false, false, true);
}

#[test]
fn stopping_after_steering_retires_the_control_worker_and_owned_processes() {
    run_case(false, true, false, false, true);
}
