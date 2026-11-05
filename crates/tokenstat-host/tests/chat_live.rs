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
        if self.0.try_wait().is_ok_and(|status| status.is_some()) {
            return;
        }
        // Exercise the same signal the PTY manager uses for Stop.
        unsafe {
            libc::kill(self.0.id() as libc::pid_t, libc::SIGHUP);
        }
        let _ = self.0.wait();
    }
}

#[test]
fn large_native_messages_remain_ordered_after_output_backpressure() {
    use std::io::Read;
    let root = tempfile::tempdir().unwrap();
    let fake = root.path().join("fake-claude");
    fs::write(&fake, r#"#!/usr/bin/env python3
import sys,json
def emit(value): print(json.dumps(value,ensure_ascii=False),flush=True)
for line in sys.stdin:
 message=json.loads(line)
 if message.get('type')=='control_request':
  emit({'type':'control_response','response':{'request_id':message['request_id'],'subtype':'success'}})
 elif message.get('type')=='user':
  emit({'type':'system','subtype':'init','session_id':'session'})
  for index in range(21):
   text=f'part:{index}:🙂:'+'x'*(9*1024*1024 if index==0 else 512*1024)
   emit({'type':'assistant','message':{'content':[{'type':'text','text':text}]}})
  emit({'type':'result','is_error':False})
  break
"#).unwrap();
    fs::set_permissions(&fake, fs::Permissions::from_mode(0o700)).unwrap();
    let config = root.path().join("config.json");
    fs::write(
        &config,
        json!({"backend":"claude","argv":[fake,"-p","literal prompt"]}).to_string(),
    )
    .unwrap();
    let mut runner = Runner(
        Command::new(env!("CARGO_BIN_EXE_tokenstat-hostd"))
            .args(["chat-live", config.to_str().unwrap()])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    wait_for(|| root.path().join("ready.json").exists());
    // Hold the real output pipe so the provider reader has to queue messages.
    std::thread::sleep(Duration::from_millis(200));
    let mut stdout = runner.0.stdout.take().unwrap();
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout.read_to_end(&mut bytes).unwrap();
        bytes
    });
    let mut status = None;
    wait_for(|| {
        status = runner.0.try_wait().unwrap();
        status.is_some()
    });
    let mut diagnostics = String::new();
    runner
        .0
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut diagnostics)
        .unwrap();
    assert!(status.unwrap().success(), "{diagnostics}");
    let bytes = reader.join().unwrap();
    let output = std::str::from_utf8(&bytes).unwrap();
    let mut seen = 0;
    let mut results = 0;
    for line in output.lines() {
        let message: Value = serde_json::from_str(line).unwrap();
        if message["type"] == "assistant" {
            let text = message["message"]["content"][0]["text"].as_str().unwrap();
            let prefix = format!("part:{seen}:🙂:");
            let payload = text
                .strip_prefix(&prefix)
                .expect("Provider messages changed order");
            assert_eq!(
                payload.len(),
                if seen == 0 {
                    9 * 1024 * 1024
                } else {
                    512 * 1024
                }
            );
            assert!(payload.bytes().all(|byte| byte == b'x'));
            seen += 1;
        } else if message["type"] == "result" {
            results += 1;
        }
    }
    assert_eq!(seen, 21);
    assert_eq!(results, 1);
}

#[test]
fn large_initial_prompt_does_not_block_provider_output() {
    let root = tempfile::tempdir().unwrap();
    let fake = root.path().join("fake-claude");
    fs::write(&fake, r#"#!/usr/bin/env python3
import sys,json,os,pathlib
root=pathlib.Path(__file__).parent
(root/'group').write_text(str(os.getpgrp()))
def emit(value): print(json.dumps(value),flush=True)
initialize=json.loads(sys.stdin.readline())
emit({'type':'control_response','response':{'request_id':initialize['request_id'],'subtype':'success'}})
# Startup diagnostics can fill stdout before the CLI reads its next input.
for index in range(40):
 emit({'type':'system','subtype':'status','index':index,'detail':'x'*(512*1024)})
message=json.loads(sys.stdin.readline())
assert message['type']=='user' and message['message']['content'][0]['text']=='p'*(1024*1024)
(root/'prompt-read').write_text('once')
emit({'type':'system','subtype':'init','session_id':'session'})
emit({'type':'assistant','message':{'content':[{'type':'text','text':'Prompt received once.'}]}})
emit({'type':'result','is_error':False})
"#).unwrap();
    fs::set_permissions(&fake, fs::Permissions::from_mode(0o700)).unwrap();
    let config = root.path().join("config.json");
    fs::write(
        &config,
        json!({"backend":"claude","argv":[fake,"-p","p".repeat(1024*1024)]}).to_string(),
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
    let until = Instant::now() + Duration::from_secs(5);
    let mut status = None;
    while Instant::now() < until {
        status = runner.0.try_wait().unwrap();
        if status.is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    if status.is_none() {
        // The old writer blocks even the wrapper's signal handler. Retire
        // only this fixture's still-owned provider group before failing.
        let group: i32 = fs::read_to_string(root.path().join("group"))
            .unwrap()
            .parse()
            .unwrap();
        assert!(group > 1 && group != unsafe { libc::getpgrp() });
        unsafe {
            libc::kill(-group, libc::SIGKILL);
        }
        panic!("Sending the initial prompt blocked provider output and turn completion");
    }
    assert!(status.unwrap().success());
    assert_eq!(
        fs::read_to_string(root.path().join("prompt-read")).unwrap(),
        "once"
    );
    let output = fs::read_to_string(root.path().join("output")).unwrap();
    let rows: Vec<Value> = output
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(
        rows.iter().filter(|row| row["subtype"] == "status").count(),
        40
    );
    assert_eq!(rows.iter().filter(|row| row["type"] == "result").count(), 1);
}

#[test]
fn stop_remains_responsive_during_an_incomplete_steering_write() {
    let root = tempfile::tempdir().unwrap();
    let fake = root.path().join("fake-claude");
    fs::write(&fake, r#"#!/usr/bin/env python3
import sys,json,os,pathlib,time
root=pathlib.Path(__file__).parent
(root/'group').write_text(str(os.getpgrp()))
def emit(value): print(json.dumps(value),flush=True)
for line in sys.stdin:
 message=json.loads(line)
 if message.get('type')=='control_request':
  emit({'type':'control_response','response':{'request_id':message['request_id'],'subtype':'success'}})
 elif message.get('type')=='user':
  emit({'type':'system','subtype':'init','session_id':'session'})
  # Leave stdin open without reading the next message.
  time.sleep(60)
"#).unwrap();
    fs::set_permissions(&fake, fs::Permissions::from_mode(0o700)).unwrap();
    let config = root.path().join("config.json");
    fs::write(
        &config,
        json!({"backend":"claude","argv":[fake,"-p","literal prompt"]}).to_string(),
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
    let id = "00000000000040008000000000000001";
    let request = root.path().join(format!("request-{id}.json"));
    let response = root.path().join(format!("response-{id}.json"));
    let temporary = request.with_extension("tmp");
    fs::write(
        &temporary,
        json!({"id":id,"steer":"x".repeat(1024*1024),"expires":u64::MAX}).to_string(),
    )
    .unwrap();
    fs::rename(temporary, &request).unwrap();
    let until = Instant::now() + Duration::from_secs(2);
    while request.exists() && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(10));
    }
    let admitted = !request.exists();
    let start = Instant::now();
    fs::write(root.path().join("stop"), "").unwrap();
    let mut status = None;
    while start.elapsed() < Duration::from_secs(3) {
        status = runner.0.try_wait().unwrap();
        if status.is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    if status.is_none() {
        let group: i32 = fs::read_to_string(root.path().join("group"))
            .unwrap()
            .parse()
            .unwrap();
        assert!(group > 1 && group != unsafe { libc::getpgrp() });
        unsafe {
            libc::kill(-group, libc::SIGKILL);
        }
        panic!("An incomplete steering write blocked Stop");
    }
    assert!(admitted && !status.unwrap().success());
    if let Ok(response) = fs::read(&response) {
        let response: Value = serde_json::from_slice(&response).unwrap();
        assert_ne!(
            response["ok"], true,
            "A partial write must not be reported as accepted"
        );
    }
    println!("Stop during blocked steering input: {:?}", start.elapsed());
}

#[test]
fn a_completed_turn_survives_an_unconfirmed_steering_write() {
    let root = tempfile::tempdir().unwrap();
    let fake = root.path().join("fake-claude");
    fs::write(&fake, r#"#!/usr/bin/env python3
import sys,json,pathlib,time,os
root=pathlib.Path(__file__).parent
(root/'group').write_text(str(os.getpgrp()))
def emit(value): print(json.dumps(value),flush=True)
for line in sys.stdin:
 message=json.loads(line)
 if message.get('type')=='control_request':
  emit({'type':'control_response','response':{'request_id':message['request_id'],'subtype':'success'}})
 elif message.get('type')=='user':
  emit({'type':'system','subtype':'init','session_id':'session'})
  while not (root/'finish').exists(): time.sleep(0.01)
  emit({'type':'assistant','message':{'content':[{'type':'text','text':'Original work completed.'}]}})
  emit({'type':'result','is_error':False})
  break
"#).unwrap();
    fs::set_permissions(&fake, fs::Permissions::from_mode(0o700)).unwrap();
    let config = root.path().join("config.json");
    fs::write(
        &config,
        json!({"backend":"claude","argv":[fake,"-p","literal prompt"]}).to_string(),
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
    let id = "00000000000040008000000000000001";
    let request = root.path().join(format!("request-{id}.json"));
    let response = root.path().join(format!("response-{id}.json"));
    let temporary = request.with_extension("tmp");
    fs::write(
        &temporary,
        json!({"id":id,"steer":"x".repeat(1024*1024),"expires":u64::MAX}).to_string(),
    )
    .unwrap();
    fs::rename(temporary, &request).unwrap();
    let until = Instant::now() + Duration::from_secs(2);
    while request.exists() && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(10));
    }
    fs::write(root.path().join("finish"), "").unwrap();
    wait_for(|| runner.0.try_wait().unwrap().is_some());
    assert!(
        runner.0.wait().unwrap().success(),
        "A failed steer must not discard the completed turn"
    );
    let response: Value = serde_json::from_slice(&fs::read(response).unwrap()).unwrap();
    assert_eq!(response["ok"], false);
    assert_eq!(response["unknown"], true);
    let output = fs::read_to_string(root.path().join("output")).unwrap();
    let rows: Vec<Value> = output
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert!(output.contains("Original work completed."));
    assert_eq!(rows.iter().filter(|row| row["type"] == "result").count(), 1);
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
        for with_image in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let fake = root.path().join("fake-agent");
            fs::write(&fake, r##"#!/usr/bin/env python3
import sys,json,os,uuid
backend=sys.argv[1]
def emit(v): print(json.dumps(v),flush=True)
count=0
pending=None
for line in sys.stdin:
 m=json.loads(line)
 if backend=='claude':
  if m.get('type')=='control_request':
   r=m['request'];emit({'type':'control_response','response':{'request_id':m['request_id'],'subtype':'success'}})
   if r['subtype']=='apply_flag_settings':
    assert r['settings']['fastMode']==(count==0);count+=1
    if pending is not None: emit(pending);pending=None
    if count==2:
     emit({'type':'assistant','message':{'content':[{'type':'text','text':'Completed once.'}]}})
     emit({'type':'result','subtype':'success','is_error':False});break
  elif m.get('type')=='user':
   if m['message']['content'][0]['text']=='literal prompt':
    emit({'type':'system','subtype':'init','session_id':'session'})
   else:
    text=m['message']['content'][0]['text']
    assert text.startswith('Additional context.')
    if '\n' in text: assert os.path.isfile(text.split('\n')[-1])
    assert uuid.UUID(m['uuid']).version==4
    pending=m
    emit({'type':'result','subtype':'success','is_error':False})
    emit({'type':'result','subtype':'error_during_execution','is_error':True})
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
   emit({'id':m['id'],'result':{'thread':{'id':'session'},'model':'gpt-test'}})
  elif method=='turn/start':
   assert p['input'][0]['text']=='literal prompt'
   emit({'id':m['id'],'result':{'turn':{'id':'turn'}}})
  elif method=='mcpServerStatus/list':
   assert p['threadId']=='session'
   emit({'id':m['id'],'result':{'data':[{'name':'godot-mcp','runtimeStatus':'connected','tools':{'scene':{'inputSchema':{'private':'secret'}}}}],'nextCursor':None}})
  elif method=='thread/goal/get':
   assert p=={'threadId':'session'}
   # A live update wins if the initial read's response arrives afterward.
   emit({'method':'thread/goal/updated','params':{'threadId':'session','goal':{'threadId':'session','objective':'Finish current work','status':'active','tokensUsed':10,'tokenBudget':None,'timeUsedSeconds':2}}})
   emit({'id':m['id'],'result':{'goal':{'threadId':'session','objective':'Stale goal read','status':'paused'}}})
  elif method=='turn/steer':
   assert p['threadId']=='session' and p['expectedTurnId']=='turn'
   assert p['input'][0]=={'type':'text','text':'Additional context.'}
   if len(p['input'])>1:
    assert p['input'][1]['type']=='localImage' and os.path.isfile(p['input'][1]['path'])
    assert len(p['input'])==2
   assert uuid.UUID(p['clientUserMessageId']).version==4
   emit({'id':m['id'],'result':{'turnId':'turn'}})
  elif method=='turn/settings/update':
   assert p['threadId']=='session' and p['turnId']=='turn'
   assert p['serviceTier']==('priority' if count==0 else 'default');count+=1
   emit({'id':m['id'],'result':{'status':'applied'}})
   if count==2:
    emit({'method':'turn/plan/updated','params':{'threadId':'someone-else','turnId':'turn','plan':[{'step':'Wrong plan','status':'pending'}]}})
    emit({'method':'turn/plan/updated','params':{'threadId':'session','turnId':'turn','plan':[{'step':'Verify current work','status':'inProgress'}]}})
    emit({'method':'item/completed','params':{'threadId':'someone-else','turnId':'turn','item':{'id':'wrong','type':'agentMessage','text':'Foreign output'}}})
    emit({'method':'item/completed','params':{'threadId':'session','turnId':'turn','item':{'id':'agent','type':'collabAgentToolCall','tool':'spawnAgent','status':'completed','senderThreadId':'session','receiverThreadIds':['child'],'prompt':'Review parser','agentsStates':{'child':{'status':'running'}}}}})
    emit({'method':'item/completed','params':{'threadId':'session','turnId':'turn','item':{'id':'answer','type':'agentMessage','text':'Completed once.'}}})
    emit({'method':'thread/tokenUsage/updated','params':{'threadId':'session','turnId':'turn','tokenUsage':{'last':{'inputTokens':60,'cachedInputTokens':40,'outputTokens':5,'reasoningOutputTokens':2},'modelContextWindow':200000,'total':{'inputTokens':100,'cachedInputTokens':40,'outputTokens':5,'reasoningOutputTokens':2}}}})
    emit({'method':'turn/completed','params':{'threadId':'session','turn':{'id':'turn','status':'completed'}}})
  elif method=='thread/unsubscribe':
   emit({'method':'thread/goal/updated','params':{'threadId':'session','goal':{'threadId':'session','objective':'Finish current work','status':'complete','tokensUsed':100,'tokenBudget':None,'timeUsedSeconds':3}}})
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
            let image = root.path().join("steering image.png");
            fs::write(&image, b"\x89PNG\r\n\x1a\nimage").unwrap();
            let text = if with_image && backend == "claude" {
                format!(
                    "Additional context.\n\nFiles attached to this message:\n{}",
                    image.display()
                )
            } else {
                "Additional context.".into()
            };
            let images = if with_image && backend == "codex" {
                vec![image]
            } else {
                vec![]
            };
            let steer_id = "00000000000040008000000000000001";
            let request = root.path().join(format!("request-{steer_id}.json"));
            fs::write(
                request.with_extension("tmp"),
                json!({"id":steer_id,"steer":text,"images":images,"expires":u64::MAX}).to_string(),
            )
            .unwrap();
            fs::rename(request.with_extension("tmp"), request).unwrap();
            let response = root.path().join(format!("response-{steer_id}.json"));
            wait_for(|| response.exists());
            let accepted: Value = serde_json::from_slice(&fs::read(response).unwrap()).unwrap();
            assert_eq!(accepted["ok"], true, "{backend}: {accepted}");
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
                let done = rows
                    .iter()
                    .find(|row| row["type"] == "turn.completed")
                    .unwrap();
                assert_eq!(done["usage"]["cached_input_tokens"], 40);
                let context = rows
                    .iter()
                    .find(|row| row["type"] == "tokenstat.context" && row["contextUsed"] == 60)
                    .unwrap();
                assert_eq!(context["contextWindow"], 200000);
                let mcp = rows
                    .iter()
                    .find(|row| row["type"] == "tokenstat.mcp")
                    .unwrap();
                assert_eq!(mcp["servers"][0]["name"], "godot-mcp");
                assert_eq!(mcp["servers"][0]["tools"], json!(["scene"]));
                assert!(!mcp.to_string().contains("secret"));
                let goal = rows
                    .iter()
                    .find(|row| row["type"] == "tokenstat.activity" && row["kind"] == "goal")
                    .unwrap();
                assert_eq!(goal["goal"]["objective"], "Finish current work");
                let final_goal = rows.iter().rev().find(|row| row["kind"] == "goal").unwrap();
                assert_eq!(final_goal["goal"]["status"], "complete");
                assert_eq!(final_goal["goal"]["tokensUsed"], 100);
                assert!(!output.contains("Stale goal read"));
                assert!(!output.contains("Wrong plan"));
                assert!(!output.contains("Foreign output"));
                assert!(
                    rows.iter().any(|row| row["kind"] == "plan"
                        && row["plan"][0]["step"] == "Verify current work")
                );
                assert!(
                    rows.iter()
                        .any(|row| row["item"]["type"] == "collab_agent_tool_call")
                );
            } else {
                let rows: Vec<Value> = output
                    .lines()
                    .map(|line| serde_json::from_str(line).unwrap())
                    .collect();
                assert_eq!(
                    rows.iter().filter(|row| row["type"] == "result").count(),
                    1,
                    "results before the steer echo must not close the turn: {output}"
                );
            }
        }
    }
}

#[test]
fn resumed_claude_background_results_do_not_complete_the_new_prompt() {
    let root = tempfile::tempdir().unwrap();
    let fake = root.path().join("fake-claude");
    fs::write(
        &fake,
        r#"#!/usr/bin/env python3
import sys,json,time
def emit(v): print(json.dumps(v),flush=True)
sys.stderr.write('diagnostic-only\n'*10000)
sys.stderr.flush()
for line in sys.stdin:
 m=json.loads(line)
 if m.get('type')=='control_request':
  emit({'type':'control_response','response':{'request_id':m['request_id'],'subtype':'success'}})
  emit({'type':'system','subtype':'init','session_id':'session'})
  # Resuming can report an old background task before reading the new input.
  emit({'type':'result','subtype':'success','origin':{'kind':'task-notification'},'is_error':False,'num_turns':0})
  time.sleep(.2)
 elif m.get('type')=='user':
  assert m['message']['content'][0]['text']=='literal prompt'
  # A background task failure is also separate from the person's request.
  emit({'type':'result','origin':{'kind':'task-notification'},'is_error':True})
  emit({'type':'assistant','message':{'content':[{'type':'text','text':'New prompt completed.'}]}})
  emit({'type':'result','subtype':'success','is_error':False,'num_turns':1})
  break
"#,
    )
    .unwrap();
    fs::set_permissions(&fake, fs::Permissions::from_mode(0o700)).unwrap();
    let config = root.path().join("config.json");
    fs::write(
        &config,
        json!({"backend":"claude","argv":[fake,"-p","literal prompt","--resume","session","--output-format","stream-json","--verbose"]}).to_string(),
    )
    .unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_tokenstat-hostd"))
        .args(["chat-live", config.to_str().unwrap()])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let rows: Vec<Value> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert!(rows.iter().any(|row| row["type"] == "assistant"));
    assert_eq!(rows.iter().filter(|row| row["type"] == "result").count(), 1);
    assert_eq!(rows.last().unwrap()["num_turns"], 1);
    assert!(
        output.stderr.is_empty(),
        "successful diagnostics must not leak into the wrapper PTY"
    );
}

#[test]
fn failed_native_agent_reports_only_a_bounded_diagnostic_tail() {
    let root = tempfile::tempdir().unwrap();
    let fake = root.path().join("fake-claude");
    fs::write(&fake, "#!/usr/bin/env python3\nimport sys\nsys.stdin.readline()\nsys.stderr.write('x'*20000+'useful failure detail\\n')\nsys.stderr.flush()\n").unwrap();
    fs::set_permissions(&fake, fs::Permissions::from_mode(0o700)).unwrap();
    let config = root.path().join("config.json");
    fs::write(
        &config,
        json!({"backend":"claude","argv":[fake,"-p","test"]}).to_string(),
    )
    .unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_tokenstat-hostd"))
        .args(["chat-live", config.to_str().unwrap()])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(output.stderr.len() < 9000);
    assert!(String::from_utf8_lossy(&output.stderr).contains("useful failure detail"));
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
 elif method in ('mcpServerStatus/list','thread/goal/get'):emit({'id':m['id'],'error':{'code':-32601,'message':'unsupported'}})
 elif method=='turn/start':
  with (root/'history').open('w') as f:f.write('custom_tool_call\n')
  emit({'id':m['id'],'result':{'turn':{'id':'turn'}}})
 elif method=='turn/interrupt':
  assert m['params']=={'threadId':'session','turnId':'turn'}
  emit({'id':m['id'],'result':{}})
  for thread,turn in [('foreign-thread','turn'),('session','foreign-turn')]:
   emit({'method':'item/started','params':{'threadId':thread,'turnId':turn,'item':{'id':'foreign','type':'commandExecution','command':'foreign-private-command'}}})
   emit({'method':'item/completed','params':{'threadId':thread,'turnId':turn,'item':{'id':'foreign','type':'commandExecution','status':'failed','command':'foreign-private-command','aggregatedOutput':'foreign-private-output'}}})
  # Persisting a cancelled tool can exceed the PTY kill's 200ms signal grace.
  time.sleep(0.4)
  with (root/'history').open('a') as f:f.write('custom_tool_call_output: aborted by user\n')
  emit({'method':'item/completed','params':{'threadId':'session','turnId':'turn','item':{'id':'tool','type':'commandExecution','status':'failed','command':'sleep 60','aggregatedOutput':'aborted by user'}}})
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
    assert!(!output.contains("foreign-private"));
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
 elif method in ('mcpServerStatus/list','thread/goal/get'):emit({'id':m['id'],'error':{'code':-32601,'message':'unsupported'}})
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

/// Manual compaction is a native operation on the resumed session. It must
/// never create a normal model turn containing the literal slash command.
#[test]
fn compact_uses_the_native_protocol_and_surfaces_unsupported_versions() {
    for (backend, refuse) in [("claude", false), ("codex", false), ("codex", true)] {
        let root = tempfile::tempdir().unwrap();
        let fake = root.path().join("fake-agent");
        fs::write(&fake, format!(r##"#!/usr/bin/env python3
import json,sys
backend='{backend}'
refuse={refuse}
def emit(v): print(json.dumps(v),flush=True)
for line in sys.stdin:
 m=json.loads(line)
 if backend=='claude':
  if m.get('type')=='control_request': emit({{'type':'control_response','response':{{'request_id':m['request_id'],'subtype':'success'}}}})
  elif m.get('type')=='user':
   assert m['message']['content']==[{{'type':'text','text':'/compact'}}]
   emit({{'type':'system','subtype':'compact_boundary','compact_metadata':{{'trigger':'manual','pre_tokens':40000}}}})
   emit({{'type':'result','subtype':'success','is_error':False}});break
 else:
  method=m.get('method');p=m.get('params',{{}})
  if method=='initialize': emit({{'id':m['id'],'result':{{}}}})
  elif method=='initialized': pass
  elif method=='thread/resume': emit({{'id':m['id'],'result':{{'thread':{{'id':'session'}}}}}})
  elif method=='thread/compact/start':
   assert p=={{'threadId':'session'}}
   if refuse:
    emit({{'id':m['id'],'error':{{'code':-32601,'message':'Native compaction unavailable'}}}});break
   emit({{'id':m['id'],'result':{{}}}})
   emit({{'method':'turn/started','params':{{'threadId':'session','turn':{{'id':'goal','status':'inProgress'}}}}}})
   emit({{'method':'turn/completed','params':{{'threadId':'session','turn':{{'id':'goal','status':'interrupted','error':{{'message':'goal interrupted'}}}}}}}})
   emit({{'method':'turn/started','params':{{'threadId':'session','turn':{{'id':'compact'}}}}}})
   emit({{'method':'item/started','params':{{'threadId':'session','turnId':'compact','item':{{'id':'compact-item','type':'contextCompaction'}}}}}})
   emit({{'method':'turn/completed','params':{{'threadId':'session','turn':{{'id':'compact','status':'completed'}}}}}})
  elif method in ('mcpServerStatus/list','thread/goal/get'): emit({{'id':m['id'],'error':{{'code':-32601,'message':'unsupported'}}}})
  elif method=='thread/unsubscribe': emit({{'id':m['id'],'result':{{}}}});break
  else: raise Exception('Unexpected model prompt: '+method)
"##, refuse=if refuse {"True"} else {"False"})).unwrap();
        fs::set_permissions(&fake, fs::Permissions::from_mode(0o700)).unwrap();
        let config = root.path().join("config.json");
        // Exercise the same command constructor as Store::send. Codex plan
        // mode and changed standing rules both decorate the prompt, but
        // neither may turn maintenance into a normal inference request.
        let mut argv = tokenstat_host::automations::chat_agent_command(
            backend,
            "/compact",
            None,
            None,
            3600,
            tokenstat_host::automations::ChatLaunch {
                resume: Some("session"),
                bypass: false,
                mode: "plan",
                hook_helper: None,
                system_append: Some("The person's updated standing rules."),
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
                attachments: &[],
            },
        )
        .unwrap();
        argv[0] = fake.to_string_lossy().into_owned();
        fs::write(
            &config,
            json!({"backend":backend,"argv":argv,"compact":true}).to_string(),
        )
        .unwrap();
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
        wait_for(|| runner.0.try_wait().unwrap().is_some());
        assert_eq!(runner.0.wait().unwrap().success(), !refuse);
        let output = fs::read_to_string(root.path().join("output")).unwrap();
        assert_eq!(output.contains("Context compaction completed."), !refuse);
        if !refuse && backend == "codex" {
            assert!(
                !output.contains("goal interrupted"),
                "a resumed goal turn must not finish compaction: {output}"
            );
        }
        if refuse {
            assert!(
                fs::read_to_string(root.path().join("stderr"))
                    .unwrap()
                    .contains("Native compaction unavailable")
            );
        }
    }
}
