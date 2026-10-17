// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Opt-in acceptance tests against actual CLIs. They use temporary projects,
//! the production chat argv, PTY transport, parser and native resume lookup.
//! Each case runs in its own process so PATH and CLI caches cannot leak.

use super::*;
use crate::automations::{ChatLaunch, chat_agent_command, interactive_agent_command};
use crate::transcript::{Event, Parser};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::process::Command;

#[derive(Clone, serde::Deserialize, serde::Serialize)]
struct Case {
    label: String,
    binary: PathBuf,
    backend: String,
    generation: u8,
    #[serde(default)]
    upgrade_to: Option<PathBuf>,
}

#[test]
#[ignore = "uses anonymous native CLI inference; set TOKENSTAT_OPENCODE_LIVE_MATRIX"]
fn installed_matrix() {
    let path = std::env::var("TOKENSTAT_OPENCODE_LIVE_MATRIX").expect(
        "set TOKENSTAT_OPENCODE_LIVE_MATRIX to a JSON array of {label,binary,backend,generation}",
    );
    let cases: Vec<Case> = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
    assert!(!cases.is_empty());
    for case in cases {
        println!("Testing {} through {}", case.label, case.backend);
        let status = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "opencode_cli::live_tests::actual_case",
                "--ignored",
                "--nocapture",
            ])
            .env(
                "TOKENSTAT_OPENCODE_LIVE_CASE",
                serde_json::to_string(&case).unwrap(),
            )
            .status()
            .unwrap();
        assert!(status.success(), "{} failed", case.label);
    }
}

struct Pty(String);
impl Drop for Pty {
    fn drop(&mut self) {
        let _ = tokenstat_pty::manager().close(&self.0);
    }
}

fn run(
    case: &Case,
    folder: &Path,
    argv: &[String],
    name: &str,
    environment: Vec<(String, String)>,
) -> Vec<Event> {
    let executable = folder.parent().unwrap().join("bin").join(&case.backend);
    let info = tokenstat_pty::manager()
        .spawn(&tokenstat_pty::Spawn {
            command: executable.display().to_string(),
            args: argv[1..].to_vec(),
            cwd: folder.to_path_buf(),
            workspace_id: None,
            hidden: true,
            rows: 40,
            cols: 160,
            no_color: true,
            dark: None,
            environment,
        })
        .unwrap();
    let pty = Pty(info.id);
    let deadline = Instant::now() + Duration::from_secs(90);
    let mut parser = Parser::new(&case.backend);
    let mut offset = 0;
    let mut raw = Vec::new();
    let mut events = Vec::new();
    let mut exited = None;
    let exit_code = loop {
        let chunk = tokenstat_pty::manager()
            .read_for_stream(&pty.0, "compat", offset)
            .unwrap();
        assert_eq!(chunk.dropped, 0);
        offset = chunk.next_offset;
        events.extend(parser.push_events(&chunk.bytes));
        raw.extend(chunk.bytes);
        let state = tokenstat_pty::manager().info(&pty.0).unwrap();
        if !state.alive {
            let at = *exited.get_or_insert_with(Instant::now);
            if tokenstat_pty::manager()
                .output_end_offset(&pty.0)
                .unwrap()
                .is_some_and(|end| offset >= end)
                || at.elapsed() > Duration::from_secs(3)
            {
                break state.exit_code;
            }
        }
        if Instant::now() >= deadline {
            fs::write(folder.join(format!("{name}.ndjson")), &raw).unwrap();
            panic!("{} {name} timed out", case.label);
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    events.extend(parser.finish_events());
    fs::write(folder.join(format!("{name}.ndjson")), raw).unwrap();
    assert_eq!(exit_code, Some(0), "{} {name}: {events:?}", case.label);
    assert!(
        !events
            .iter()
            .any(|event| matches!(event, Event::Failed { .. })),
        "{events:?}"
    );
    events
}

fn text(events: &[Event]) -> String {
    events
        .iter()
        .filter_map(|event| match event {
            Event::Text { delta } => Some(delta.as_str()),
            _ => None,
        })
        .collect()
}

fn session(events: &[Event]) -> &str {
    events
        .iter()
        .find_map(|event| match event {
            Event::Session { id } => Some(id.as_str()),
            _ => None,
        })
        .expect("the parser must capture the native session ID")
}

fn argv(case: &Case, prompt: &str, resume: Option<&str>, attachments: &[PathBuf]) -> Vec<String> {
    chat_agent_command(
        &case.backend,
        prompt,
        Some("opencode/beam-free"),
        Some("low"),
        90,
        ChatLaunch {
            resume,
            bypass: true,
            mode: "execute",
            hook_helper: None,
            system_append: None,
            agy_customization_dir: None,
            cursor_plugin_dir: None,
            grok_allow_rules: &[],
            attachments,
        },
    )
    .unwrap()
}

#[test]
#[ignore = "child of installed_matrix; never runs inference in the ordinary suite"]
fn actual_case() {
    let value = std::env::var("TOKENSTAT_OPENCODE_LIVE_CASE").expect("run installed_matrix");
    let case: Case = serde_json::from_str(&value).unwrap();
    assert!(matches!(case.backend.as_str(), "opencode" | "opencode2"));
    assert!(case.binary.is_absolute() && case.binary.is_file());
    let root = tempfile::tempdir().unwrap();
    let bin = root.path().join("bin");
    fs::create_dir(&bin).unwrap();
    let selected = bin.join("selected-cli");
    fs::write(&selected, format!("{}\n", case.binary.display())).unwrap();
    // Enforce isolation at the final exec too: a login-shell profile may
    // otherwise replace XDG variables after the child test sets them.
    let isolation: String = [
        ("XDG_DATA_HOME", "data"),
        ("XDG_CACHE_HOME", "cache"),
        ("XDG_CONFIG_HOME", "config"),
        ("XDG_STATE_HOME", "state"),
    ]
    .into_iter()
    .map(|(name, suffix)| {
        format!(
            "export {name}={}\n",
            crate::chat_gate::shell_quote(&root.path().join(suffix).display().to_string())
        )
    })
    .collect();
    for alias in ["opencode", "opencode1", "opencode2"] {
        let shim = bin.join(alias);
        fs::write(
            &shim,
            format!(
                // Execute the actual path so vendor scripts resolving their
                // sibling binary through $0 keep their original directory.
                "#!/bin/sh\n{isolation}IFS= read -r tokenstat_cli < {} || exit 1\nexec \"$tokenstat_cli\" \"$@\"\n",
                crate::chat_gate::shell_quote(&selected.display().to_string())
            ),
        )
        .unwrap();
        fs::set_permissions(shim, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let folder = root.path().join("project ü 🦆");
    fs::create_dir(&folder).unwrap();
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    // Preserve public model metadata, which older CLIs may no longer be
    // able to download. This cache contains no credentials or session data.
    let public_catalog = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| tokenstat_paths::home_dir().map(|home| home.join(".cache")))
        .map(|cache| cache.join("opencode/models.json"));
    // This exact child test is the only test in its fresh process, before
    // any environment readers or CLI/PTY background threads have started.
    // Native CLI data and migrations stay away from the user's database.
    unsafe {
        std::env::set_var("PATH", path);
        for (name, suffix) in [
            ("XDG_DATA_HOME", "data"),
            ("XDG_CACHE_HOME", "cache"),
            ("XDG_CONFIG_HOME", "config"),
            ("XDG_STATE_HOME", "state"),
        ] {
            let directory = root.path().join(suffix);
            fs::create_dir_all(&directory).unwrap();
            std::env::set_var(name, directory);
        }
        std::env::set_var("OPENCODE_DISABLE_AUTOUPDATE", "1");
    }
    if let Some(source) = public_catalog.filter(|path| path.is_file()) {
        let destination = root.path().join("cache/opencode/models.json");
        fs::create_dir_all(destination.parent().unwrap()).unwrap();
        fs::copy(source, destination).unwrap();
    }
    std::env::set_current_dir(&folder).unwrap();
    let expected = if case.generation == 1 {
        Generation::V1
    } else {
        Generation::V2
    };
    for alias in ["opencode", "opencode1", "opencode2"] {
        assert_eq!(
            require_generation(bin.join(alias).to_str().unwrap()).unwrap(),
            expected,
            "generation must follow the executable rather than its name"
        );
    }
    let picker = models(&case.backend, true).unwrap();
    assert!(
        picker.iter().any(|model| model == "opencode/beam-free"),
        "the model picker must work without a compatible shared service: {picker:?}"
    );
    let core = std::env::var("TOKENSTAT_OPENCODE_LIVE_PHASE").as_deref() != Ok("additional");
    let mut upgrade_context = None;
    if core {
        let word = format!("compat-{:016x}", rand::random::<u64>());
        let first = argv(
            &case,
            &format!("Remember this test word: {word}. Reply READY. Do not use tools."),
            None,
            &[],
        );
        if expected == Generation::V1 {
            assert!(first.windows(2).any(|p| p == ["--variant", "low"]));
            assert!(!first.contains(&"--standalone".into()));
        } else {
            assert!(first.contains(&"--standalone".into()));
            assert!(
                first
                    .windows(2)
                    .any(|p| p == ["--model", "opencode/beam-free#low"]),
                "{first:?}"
            );
            assert!(!first.contains(&"--variant".into()));
        }
        let reply = run(&case, &folder, &first, "first", Vec::new());
        assert!(text(&reply).contains("READY"), "{reply:?}");
        let id = session(&reply).to_string();
        upgrade_context = Some((id.clone(), word.clone()));
        assert_eq!(
            session_exists(&case.backend, &id, Some(&folder)),
            Some(true)
        );
        assert_eq!(
            session_exists(
                &case.backend,
                "ses_012345abcdef0123456789abcd",
                Some(&folder)
            ),
            Some(false)
        );
        let attachment = folder.join("attachment ü.txt");
        fs::write(&attachment, "ATTACHMENT_COMPAT_OK").unwrap();
        let next = argv(
            &case,
            "What test word did I ask you to remember? Also quote the token in the attached file. Reply with only those two values. Do not use tools.",
            Some(&id),
            &[attachment],
        );
        let resumed = run(&case, &folder, &next, "resumed", Vec::new());
        assert_eq!(session(&resumed), id);
        let answer = text(&resumed);
        assert!(
            answer.contains(&word) && answer.contains("ATTACHMENT_COMPAT_OK"),
            "{resumed:?}"
        );
        let hook_home = folder.join("gate");
        let legacy_plugin = write_gate_home(&hook_home).unwrap();
        let plugin = if expected == Generation::V1 {
            legacy_plugin
        } else {
            hook_home.join("v2")
        };
        let helper = folder.join("helper.py");
        fs::write(
            &helper,
            r#"#!/usr/bin/env python3
import json,sys,os
payload=json.load(sys.stdin)
with open(os.environ['TOKENSTAT_COMPAT_HOOK_LOG'],'a') as f:
 f.write(json.dumps({'phase':sys.argv[-1],'payload':payload})+'\n')
print(json.dumps({'decision':os.environ['TOKENSTAT_COMPAT_DECISION']}))
"#,
        )
        .unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o755)).unwrap();
        for decision in ["allow", "deny"] {
            let marker = folder.join("marker.txt");
            let _ = fs::remove_file(&marker);
            let log = folder.join(format!("{decision}-hook.ndjson"));
            let prompt = "Use your shell tool exactly once to run: printf TOKENSTAT_GATE > marker.txt . If denied, say BLOCKED and stop. Do not retry or use another tool.";
            let guarded = chat_agent_command(
                &case.backend,
                prompt,
                Some("opencode/beam-free"),
                Some("low"),
                90,
                ChatLaunch {
                    resume: None,
                    bypass: false,
                    mode: "execute",
                    hook_helper: Some(&helper),
                    system_append: None,
                    agy_customization_dir: None,
                    cursor_plugin_dir: None,
                    grok_allow_rules: &[],
                    attachments: &[],
                },
            )
            .unwrap();
            assert!(!guarded.contains(&"--auto".into()));
            run(
                &case,
                &folder,
                &guarded,
                decision,
                vec![
                    (
                        "OPENCODE_CONFIG_DIR".into(),
                        hook_home.display().to_string(),
                    ),
                    (
                        "OPENCODE_CONFIG_CONTENT".into(),
                        gate_config(expected, &plugin).to_string(),
                    ),
                    (
                        crate::chat_gate::HELPER_PATH_ENV.into(),
                        helper.display().to_string(),
                    ),
                    (
                        "TOKENSTAT_COMPAT_HOOK_LOG".into(),
                        log.display().to_string(),
                    ),
                    ("TOKENSTAT_COMPAT_DECISION".into(), decision.into()),
                ],
            );
            assert!(
                log.exists() && fs::read_to_string(&log).unwrap().contains("pre"),
                "the host gate must run"
            );
            assert_eq!(
                marker.exists(),
                decision == "allow",
                "the real tool must honor the decision"
            );
        }
    }
    local_model(&case, &folder);
    let interactive = interactive_agent_command(
        &case.backend,
        "What is two plus five? Reply with one English word.",
        Some("opencode/beam-free"),
        Some("low"),
    )
    .unwrap();
    assert_eq!(
        interactive[1],
        if expected == Generation::V1 {
            "run"
        } else {
            "mini"
        }
    );
    interactive_reply(&case, &folder, &interactive);
    if let Some(upgrade) = &case.upgrade_to {
        assert_eq!(expected, Generation::V1);
        assert!(upgrade.is_absolute() && upgrade.is_file());
        let (old_id, word) = upgrade_context.expect("upgrade checks require the core phase");
        let wrapper = bin.join(&case.backend);
        let original_wrapper = fs::read(&wrapper).unwrap();
        fs::write(&selected, format!("{}\n", upgrade.display())).unwrap();
        for alias in ["opencode", "opencode1", "opencode2"] {
            assert_eq!(
                require_generation(bin.join(alias).to_str().unwrap()).unwrap(),
                Generation::V2,
                "an unchanged wrapper must detect an upgraded real binary immediately"
            );
        }
        assert_eq!(fs::read(&wrapper).unwrap(), original_wrapper);
        let present = session_exists(&case.backend, &old_id, Some(&folder))
            .expect("the upgraded CLI must answer native session lookup");
        let prompt = if present {
            "Recall the test word from our earlier messages. Reply only with that word.".to_string()
        } else {
            format!(
                "Conversation handover: the earlier test word was {word}. Reply only with that word."
            )
        };
        let command = argv(&case, &prompt, present.then_some(old_id.as_str()), &[]);
        assert!(command.contains(&"--standalone".into()));
        assert!(!command.contains(&"--variant".into()));
        let reply = run(&case, &folder, &command, "upgraded", Vec::new());
        assert!(text(&reply).contains(&word), "{reply:?}");
        assert_eq!(
            session_exists(&case.backend, session(&reply), Some(&folder)),
            Some(true)
        );
        println!(
            "{}: unchanged wrappers detected v1 -> v2; real v1 session transition passed (native resume available: {present})",
            case.label
        );
    }
    println!(
        "{}: detected {:?}; local provider config and real interactive reply passed; core chat/resume/attachment/allow/deny checks {}",
        case.label,
        expected,
        if core {
            "passed"
        } else {
            "covered by the preceding core matrix run"
        }
    );
}

fn interactive_reply(case: &Case, folder: &Path, argv: &[String]) {
    let executable = folder.parent().unwrap().join("bin").join(&case.backend);
    let info = tokenstat_pty::manager()
        .spawn(&tokenstat_pty::Spawn {
            command: executable.display().to_string(),
            args: argv[1..].to_vec(),
            cwd: folder.to_path_buf(),
            workspace_id: None,
            hidden: true,
            rows: 40,
            cols: 160,
            no_color: false,
            dark: None,
            environment: Vec::new(),
        })
        .unwrap();
    let pty = Pty(info.id);
    let deadline = Instant::now() + Duration::from_secs(45);
    let mut offset = 0;
    let mut raw = Vec::new();
    loop {
        let chunk = tokenstat_pty::manager()
            .read_for_stream(&pty.0, "interactive-compat", offset)
            .unwrap();
        offset = chunk.next_offset;
        raw.extend(chunk.bytes);
        let rendered = crate::transcript::strip_ansi(&String::from_utf8_lossy(&raw)).to_lowercase();
        if rendered.contains("seven") {
            break;
        }
        if !tokenstat_pty::manager().info(&pty.0).unwrap().alive || Instant::now() >= deadline {
            panic!(
                "{} interactive prompt was not submitted or answered: {}",
                case.label, rendered
            );
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    // The interactive interface stays open after replying. Dropping this
    // exact PTY retires it and its private server without touching a service.
}

fn local_model(case: &Case, folder: &Path) {
    use std::io::{BufRead, BufReader};
    use std::process::Stdio;
    let script = folder.join("local-provider.py");
    fs::write(&script, r#"import json,sys
from http.server import BaseHTTPRequestHandler,HTTPServer
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  body=json.dumps({'object':'list','data':[{'id':'local/test','object':'model','owned_by':'fixture'}]}).encode()
  self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(body)
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  with open(sys.argv[1],'a') as f:f.write(json.dumps({'model':body.get('model'),'path':self.path})+'\n')
  base={'id':'fixture','object':'chat.completion','model':'local/test','created':0}
  self.send_response(200)
  if body.get('stream'):
   self.send_header('Content-Type','text/event-stream');self.end_headers()
   for data in [{**base,'object':'chat.completion.chunk','choices':[{'index':0,'delta':{'role':'assistant','content':'LOCAL_MODEL_COMPAT_OK'},'finish_reason':None}]},{**base,'object':'chat.completion.chunk','choices':[{'index':0,'delta':{},'finish_reason':'stop'}],'usage':{'prompt_tokens':10,'completion_tokens':2,'total_tokens':12}}]:
    self.wfile.write(('data: '+json.dumps(data)+'\n\n').encode())
   self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
  else:
   self.send_header('Content-Type','application/json');self.end_headers()
   self.wfile.write(json.dumps({**base,'choices':[{'index':0,'message':{'role':'assistant','content':'LOCAL_MODEL_COMPAT_OK'},'finish_reason':'stop'}],'usage':{'prompt_tokens':10,'completion_tokens':2,'total_tokens':12}}).encode())
server=HTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
"#).unwrap();
    let requests = folder.join("local-provider.ndjson");
    struct Server(std::process::Child);
    impl Drop for Server {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let mut server = Server(
        Command::new("python3")
            .args([script.as_os_str(), requests.as_os_str()])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let mut port = String::new();
    BufReader::new(server.0.stdout.take().unwrap())
        .read_line(&mut port)
        .unwrap();
    crate::local_models::set_port("lmstudio", port.trim().parse().unwrap()).unwrap();
    let environment =
        crate::launcher::model_environment(&case.backend, Some("lmstudio"), Some("local/test"))
            .unwrap();
    let command = chat_agent_command(
        &case.backend,
        "Reply hello without using tools.",
        Some("lmstudio/local/test"),
        None,
        90,
        ChatLaunch {
            resume: None,
            bypass: true,
            mode: "execute",
            hook_helper: None,
            system_append: None,
            agy_customization_dir: None,
            cursor_plugin_dir: None,
            grok_allow_rules: &[],
            attachments: &[],
        },
    )
    .unwrap();
    let reply = run(case, folder, &command, "local-model", environment);
    assert!(text(&reply).contains("LOCAL_MODEL_COMPAT_OK"), "{reply:?}");
    assert!(fs::read_to_string(requests).unwrap().contains("local/test"));
}
