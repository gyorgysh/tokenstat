// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#![cfg(all(unix, feature = "local-host"))]

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

struct Runner(Child);
impl Drop for Runner {
    fn drop(&mut self) {
        // Exercise the same signal the PTY manager uses for Stop.
        unsafe {
            libc::kill(self.0.id() as libc::pid_t, libc::SIGHUP);
        }
        let _ = self.0.wait();
    }
}

fn wait_for(mut ready: impl FnMut() -> bool) {
    let until = Instant::now() + Duration::from_secs(8);
    while !ready() {
        assert!(Instant::now() < until, "protocol runner timed out");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Fake native CLIs exercise initialization, two acknowledged changes during
/// one turn, final output and cleanup. No authentication or inference occurs.
#[test]
fn live_controls_apply_without_restarting_or_resending_a_turn() {
    for backend in ["claude", "codex"] {
        let root = tempfile::tempdir().unwrap();
        let fake = root.path().join("fake-agent");
        fs::write(&fake, r##"#!/usr/bin/env python3
import sys,json,os
backend=sys.argv[1]
def emit(v): print(json.dumps(v),flush=True)
count=0
for line in sys.stdin:
 m=json.loads(line)
 if backend=='claude':
  if m.get('type')=='control_request':
   r=m['request'];emit({'type':'control_response','response':{'request_id':m['request_id'],'subtype':'success'}})
   if r['subtype']=='apply_flag_settings':
    assert r['settings']['fastMode']==(count==0);count+=1
    if count==2:
     emit({'type':'assistant','message':{'content':[{'type':'text','text':'Completed once.'}]}})
     emit({'type':'result','subtype':'success','is_error':False});break
  elif m.get('type')=='user':
   assert m['message']['content'][0]['text']=='literal prompt'
   emit({'type':'system','subtype':'init','session_id':'session'})
 else:
  method=m.get('method');p=m.get('params',{})
  if method=='initialize':
   assert p['capabilities']['experimentalApi'];emit({'id':m['id'],'result':{}})
  elif method=='initialized':
   pass
  elif method=='thread/resume':
   assert p['threadId']=='session' and p['config']['bypass_hook_trust']
   assert p['sandbox']=='read-only' and p['approvalPolicy']=='never'
   assert p['cwd']==os.getcwd() and p['excludeTurns']
   emit({'id':m['id'],'result':{'thread':{'id':'session'}}})
  elif method=='turn/start':
   assert p['input'][0]['text']=='literal prompt'
   emit({'id':m['id'],'result':{'turn':{'id':'turn'}}})
  elif method=='turn/settings/update':
   assert p['threadId']=='session' and p['turnId']=='turn'
   assert p['serviceTier']==('priority' if count==0 else 'default');count+=1
   emit({'id':m['id'],'result':{'status':'applied'}})
   if count==2:
    emit({'method':'item/completed','params':{'item':{'id':'answer','type':'agentMessage','text':'Completed once.'}}})
    emit({'method':'thread/tokenUsage/updated','params':{'tokenUsage':{'total':{'inputTokens':100,'cachedInputTokens':40,'outputTokens':5,'reasoningOutputTokens':2}}}})
    emit({'method':'turn/completed','params':{'turn':{'id':'turn','status':'completed'}}})
  elif method=='thread/unsubscribe':
   emit({'id':m['id'],'result':{}});break
  else:
   raise Exception('unexpected prompt or restart')
"##).unwrap();
        fs::set_permissions(&fake, fs::Permissions::from_mode(0o700)).unwrap();
        // An argument-selecting shim keeps the production launch translator
        // under test: it does not learn a fake CLI-specific argv convention.
        let shim = root.path().join("shim");
        fs::write(
            &shim,
            format!("#!/bin/sh\nexec '{}' {backend} \"$@\"\n", fake.display()),
        )
        .unwrap();
        fs::set_permissions(&shim, fs::Permissions::from_mode(0o700)).unwrap();
        let argv = if backend == "claude" {
            json!([
                shim,
                "--settings",
                "{\"fastMode\":false}",
                "-p",
                "literal prompt",
                "--output-format",
                "stream-json",
                "--verbose"
            ])
        } else {
            json!([
                shim,
                "exec",
                "--dangerously-bypass-hook-trust",
                "--sandbox",
                "read-only",
                "resume",
                "session",
                "--json",
                "--",
                "literal prompt"
            ])
        };
        let config = root.path().join("config.json");
        fs::write(&config, json!({"backend":backend,"argv":argv}).to_string()).unwrap();
        let output = fs::File::create(root.path().join("output")).unwrap();
        let mut runner = Runner(
            Command::new(env!("CARGO_BIN_EXE_tokenstat-hostd"))
                .args(["chat-live", config.to_str().unwrap()])
                .stdin(Stdio::null())
                .stdout(output)
                .stderr(fs::File::create(root.path().join("stderr")).unwrap())
                .spawn()
                .unwrap(),
        );
        wait_for(|| {
            assert!(
                runner.0.try_wait().unwrap().is_none(),
                "{backend}: {}",
                fs::read_to_string(root.path().join("stderr")).unwrap()
            );
            root.path().join("ready.json").is_file()
        });
        for (id, fast) in [("a".repeat(32), true), ("b".repeat(32), false)] {
            let request = root.path().join(format!("request-{id}.json"));
            fs::write(
                request.with_extension("tmp"),
                json!({"id":id,"fast":fast,"expires":u64::MAX}).to_string(),
            )
            .unwrap();
            fs::rename(request.with_extension("tmp"), request).unwrap();
            let response = root.path().join(format!("response-{id}.json"));
            wait_for(|| response.exists());
            let value: Value = serde_json::from_slice(&fs::read(response).unwrap()).unwrap();
            assert_eq!(value["ok"], true, "{backend}: {value}");
        }
        wait_for(|| runner.0.try_wait().unwrap().is_some());
        assert!(
            runner.0.wait().unwrap().success(),
            "{backend} runner failed"
        );
        let output = fs::read_to_string(root.path().join("output")).unwrap();
        assert_eq!(
            output.matches("Completed once.").count(),
            1,
            "{backend}: {output}"
        );
        if backend == "codex" {
            let rows: Vec<Value> = output
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect();
            assert_eq!(rows.last().unwrap()["usage"]["cached_input_tokens"], 40);
        }
    }
}

#[test]
fn stopping_the_wrapper_retires_the_native_agent_and_its_tool_process() {
    let root = tempfile::tempdir().unwrap();
    let fake = root.path().join("fake-agent");
    fs::write(
        &fake,
        r#"#!/usr/bin/env python3
import sys,json,subprocess,pathlib
def emit(v): print(json.dumps(v),flush=True)
for line in sys.stdin:
 m=json.loads(line)
 if m.get('type')=='control_request':
  emit({'type':'control_response','response':{'request_id':m['request_id'],'subtype':'success'}})
 elif m.get('type')=='user':
  child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])
  pathlib.Path(m['message']['content'][0]['text']).write_text(str(child.pid))
  emit({'type':'system','subtype':'init','session_id':'session'})
"#,
    )
    .unwrap();
    fs::set_permissions(&fake, fs::Permissions::from_mode(0o700)).unwrap();
    let pid_path = root.path().join("tool.pid");
    let config = root.path().join("config.json");
    fs::write(
        &config,
        json!({"backend":"claude","argv":[fake,"-p",pid_path]}).to_string(),
    )
    .unwrap();
    let runner = Runner(
        Command::new(env!("CARGO_BIN_EXE_tokenstat-hostd"))
            .args(["chat-live", config.to_str().unwrap()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    wait_for(|| root.path().join("ready.json").exists());
    let pid: u32 = fs::read_to_string(pid_path).unwrap().parse().unwrap();
    drop(runner);
    wait_for(|| {
        let output = Command::new("ps")
            .args(["-o", "stat=", "-p", &pid.to_string()])
            .output()
            .unwrap();
        let state = String::from_utf8_lossy(&output.stdout);
        state.trim().is_empty() || state.trim().starts_with('Z')
    });
}

#[test]
fn stopping_codex_flushes_interrupted_tool_history_before_retiring_the_agent() {
    let root = tempfile::tempdir().unwrap();
    let fake = root.path().join("fake-codex");
    fs::write(
        &fake,
        r#"#!/usr/bin/env python3
import sys,json,pathlib,time
root=pathlib.Path(__file__).parent
def emit(v): print(json.dumps(v),flush=True)
for line in sys.stdin:
 m=json.loads(line);method=m.get('method')
 if method=='initialize':emit({'id':m['id'],'result':{}})
 elif method=='initialized':pass
 elif method=='thread/resume':emit({'id':m['id'],'result':{'thread':{'id':'session'}}})
 elif method=='turn/start':
  with (root/'history').open('w') as f:f.write('custom_tool_call\n')
  emit({'id':m['id'],'result':{'turn':{'id':'turn'}}})
 elif method=='turn/interrupt':
  assert m['params']=={'threadId':'session','turnId':'turn'}
  emit({'id':m['id'],'result':{}})
  # Persisting a cancelled tool can exceed the PTY kill's 200ms signal grace.
  time.sleep(0.4)
  with (root/'history').open('a') as f:f.write('custom_tool_call_output: aborted by user\n')
  emit({'method':'item/completed','params':{'item':{'id':'tool','type':'commandExecution','status':'failed','command':'sleep 60','aggregatedOutput':'aborted by user'}}})
  emit({'method':'turn/completed','params':{'threadId':'session','turn':{'id':'turn','status':'interrupted'}}})
 else:raise Exception('stop must not restart or replay the turn')
# EOF must get a chance to complete the server's final rollout flush too.
time.sleep(0.4)
(root/'flushed').write_text('true')
"#,
    )
    .unwrap();
    fs::set_permissions(&fake, fs::Permissions::from_mode(0o700)).unwrap();
    let config = root.path().join("config.json");
    fs::write(
        &config,
        json!({"backend":"codex","argv":[fake,"exec","resume","session","--json","--","literal prompt"]}).to_string(),
    )
    .unwrap();
    let mut runner = Runner(
        Command::new(env!("CARGO_BIN_EXE_tokenstat-hostd"))
            .args(["chat-live", config.to_str().unwrap()])
            .stdin(Stdio::null())
            .stdout(fs::File::create(root.path().join("output")).unwrap())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    wait_for(|| root.path().join("ready.json").is_file());
    fs::write(root.path().join("stop"), "").unwrap();
    wait_for(|| runner.0.try_wait().unwrap().is_some());
    assert!(!runner.0.wait().unwrap().success());
    assert_eq!(
        fs::read_to_string(root.path().join("history")).unwrap(),
        "custom_tool_call\ncustom_tool_call_output: aborted by user\n"
    );
    assert!(root.path().join("flushed").is_file());
    let output = fs::read_to_string(root.path().join("output")).unwrap();
    assert!(output.contains("aborted by user"));
}

#[test]
fn stopping_codex_forces_a_hung_server_to_exit_within_the_stop_deadline() {
    let root = tempfile::tempdir().unwrap();
    let fake = root.path().join("fake-codex");
    fs::write(
        &fake,
        r#"#!/usr/bin/env python3
import sys,json,time,pathlib,subprocess
root=pathlib.Path(__file__).parent
def emit(v): print(json.dumps(v),flush=True)
for line in sys.stdin:
 m=json.loads(line);method=m.get('method')
 if method=='initialize':emit({'id':m['id'],'result':{}})
 elif method=='initialized':pass
 elif method=='thread/resume':emit({'id':m['id'],'result':{'thread':{'id':'session'}}})
 elif method=='turn/start':
  child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])
  (root/'tool.pid').write_text(str(child.pid))
  emit({'id':m['id'],'result':{'turn':{'id':'turn'}}})
 elif method=='turn/interrupt':
  (root/'interrupted').write_text('true')
  time.sleep(60)
 else:raise Exception('unexpected request')
"#,
    )
    .unwrap();
    fs::set_permissions(&fake, fs::Permissions::from_mode(0o700)).unwrap();
    let config = root.path().join("config.json");
    fs::write(
        &config,
        json!({"backend":"codex","argv":[fake,"exec","resume","session","--json","--","literal prompt"]}).to_string(),
    )
    .unwrap();
    let mut runner = Runner(
        Command::new(env!("CARGO_BIN_EXE_tokenstat-hostd"))
            .args(["chat-live", config.to_str().unwrap()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    wait_for(|| root.path().join("ready.json").is_file());
    let pid: u32 = fs::read_to_string(root.path().join("tool.pid"))
        .unwrap()
        .parse()
        .unwrap();
    let started = Instant::now();
    fs::write(root.path().join("stop"), "").unwrap();
    wait_for(|| runner.0.try_wait().unwrap().is_some());
    assert!(started.elapsed() < Duration::from_secs(8));
    assert!(root.path().join("interrupted").is_file());
    wait_for(|| {
        let output = Command::new("ps")
            .args(["-o", "stat=", "-p", &pid.to_string()])
            .output()
            .unwrap();
        let state = String::from_utf8_lossy(&output.stdout);
        state.trim().is_empty() || state.trim().starts_with('Z')
    });
}
