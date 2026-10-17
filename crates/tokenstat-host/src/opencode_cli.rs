// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! The executable name no longer identifies OpenCode's CLI generation.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

const PROBE_TIMEOUT: Duration = Duration::from_secs(3);
const CACHE_TTL: Duration = Duration::from_secs(60);
const SERVER_TIMEOUT: Duration = Duration::from_secs(8);
const CATALOG_SETTLE: Duration = Duration::from_millis(500);

#[path = "opencode_probe.rs"]
mod probe;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Generation {
    V1,
    V2,
}

pub(crate) fn gate_config(generation: Generation, plugin: &Path) -> serde_json::Value {
    match generation {
        Generation::V1 => serde_json::json!({
            "plugin": [plugin],
            "permission": {"edit":"allow", "bash":"allow", "webfetch":"allow", "external_directory":"allow"}
        }),
        Generation::V2 => serde_json::json!({
            "plugins": [plugin],
            "permissions": [{"action":"*", "resource":"*", "effect":"ask"}]
        }),
    }
}

/// A package directory also works with 2.0.1, which ignored configured files.
pub(crate) fn write_gate_home(home: &Path) -> Result<PathBuf, String> {
    let v2 = home.join("v2");
    std::fs::create_dir_all(&v2).map_err(|error| error.to_string())?;
    let plugin = home.join("opencode-plugin.js");
    let legacy = include_str!("../../../scripts/cli-bridge/opencode-plugin.js");
    for path in [&plugin, &v2.join("opencode-plugin.js")] {
        std::fs::write(path, legacy).map_err(|error| error.to_string())?;
    }
    std::fs::write(
        v2.join("index.js"),
        include_str!("../../../scripts/cli-bridge/opencode-plugin-v2.js"),
    )
    .map_err(|error| error.to_string())?;
    std::fs::write(
        v2.join("package.json"),
        r#"{"name":"tokenstat-opencode-gate","type":"module","main":"index.js"}"#,
    )
    .map_err(|error| error.to_string())?;
    Ok(plugin)
}

#[derive(Clone, PartialEq, Eq, Hash)]
struct Executable {
    path: String,
    length: u64,
    modified: Option<SystemTime>,
}

fn executable(command: &str) -> Option<Executable> {
    let path = crate::launcher::resolve_command(command)?;
    let metadata = std::fs::metadata(&path).ok()?;
    Some(Executable {
        path,
        length: metadata.len(),
        modified: metadata.modified().ok(),
    })
}

pub(crate) fn generation(command: &str) -> Generation {
    detected_generation(command).unwrap_or(Generation::V2)
}

pub(crate) fn require_generation(command: &str) -> Result<Generation, String> {
    match detected_generation(command) {
        Some(generation) => Ok(generation),
        None if executable(command).is_none() => Ok(Generation::V2),
        None => Err(format!(
            "Could not determine the installed {command} CLI version. Check that it can run --version or run --help, then retry."
        )),
    }
}

fn detected_generation(command: &str) -> Option<Generation> {
    type Cache = HashMap<Executable, (Instant, Option<Generation>)>;
    static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
    let binary = executable(command)?;
    // Shell wrappers can keep their own metadata while replacing the real
    // executable they forward to. Recheck those rather than caching a v1
    // answer through an upgrade of the wrapped binary.
    let cacheable = cacheable_executable(&binary.path);
    let mut cache = CACHE
        .get_or_init(Mutex::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if cacheable
        && let Some((at, generation)) = cache.get(&binary)
        && at.elapsed()
            < if generation.is_some() {
                CACHE_TTL
            } else {
                Duration::from_secs(5)
            }
    {
        return *generation;
    }
    let version = crate::agent_models::run_cli_probe(
        &binary.path,
        &["--version"],
        PROBE_TIMEOUT,
        64 * 1024,
        None,
        &[],
    );
    let generation = version
        .as_ref()
        .filter(|output| output.success)
        .and_then(|output| {
            generation_from_version(&format!("{}\n{}", output.stdout, output.stderr))
        })
        .or_else(|| {
            let help = crate::agent_models::run_cli_probe(
                &binary.path,
                &["run", "--help"],
                PROBE_TIMEOUT,
                64 * 1024,
                None,
                &[],
            )?;
            help.success
                .then(|| generation_from_help(&format!("{}\n{}", help.stdout, help.stderr)))
                .flatten()
        });
    cache.retain(|_, (at, _)| at.elapsed() < CACHE_TTL);
    if cacheable {
        cache.insert(binary, (Instant::now(), generation));
    }
    generation
}

fn cacheable_executable(path: &str) -> bool {
    use std::io::Read;
    if Path::new(path)
        .extension()
        .and_then(|value| value.to_str())
        .is_some_and(|extension| {
            extension.eq_ignore_ascii_case("cmd") || extension.eq_ignore_ascii_case("bat")
        })
    {
        return false;
    }
    let mut header = [0; 2];
    std::fs::File::open(path)
        .and_then(|mut file| file.read_exact(&mut header))
        .is_ok()
        && header != *b"#!"
}

fn generation_from_version(version: &str) -> Option<Generation> {
    version.split_whitespace().find_map(|word| {
        let word = word.trim_start_matches('v');
        let mut parts = word.split('.');
        let major = parts.next()?;
        parts.next()?.parse::<u32>().ok()?;
        parts.next()?.split('-').next()?.parse::<u32>().ok()?;
        match major {
            "1" => Some(Generation::V1),
            "2" => Some(Generation::V2),
            _ => None, // Preview versions are identified by their help flags.
        }
    })
}

fn generation_from_help(help: &str) -> Option<Generation> {
    if help.split_whitespace().any(|word| word == "--variant") {
        Some(Generation::V1)
    } else if help.contains("provider/model#variant") || help.contains("--standalone") {
        Some(Generation::V2)
    } else {
        None
    }
}

type Variants = HashMap<String, Vec<String>>;
type ModelCache = HashMap<(Executable, PathBuf), (Instant, Variants)>;

fn directory_header(directory: &Path) -> String {
    let mut value = String::from("x-opencode-directory:");
    for byte in directory.to_string_lossy().bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            value.push(char::from(byte));
        } else {
            use std::fmt::Write;
            let _ = write!(value, "%{byte:02X}");
        }
    }
    value
}

/// Early v2 releases expose empty and bundled snapshots before provider
/// plugins settle. Debounce changes on the same leased server, bounded by
/// its deadline, so neither the picker nor effort selection caches that race.
fn settled_snapshot<T: PartialEq>(
    server: &probe::Server,
    route: &str,
    parse: impl Fn(&str) -> Option<T>,
    ready: impl Fn(&T) -> bool,
) -> Option<T> {
    let mut snapshot = None;
    let mut changed = Instant::now();
    loop {
        if server.expired() {
            return snapshot;
        }
        let Some((success, output)) = server.get(route, 4 * 1024 * 1024) else {
            // Newer v2 routes wait for plugin activation themselves. One
            // short request timeout must not consume the whole startup
            // budget before their first catalog response is available.
            std::thread::sleep(Duration::from_millis(100));
            continue;
        };
        if !success {
            return None;
        }
        let value = parse(&output)?;
        if snapshot.as_ref() != Some(&value) {
            snapshot = Some(value);
            changed = Instant::now();
        }
        if snapshot.as_ref().is_some_and(&ready) && changed.elapsed() >= CATALOG_SETTLE {
            return snapshot;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn variants(
    command: &str,
    directory: Option<&Path>,
    expected_model: Option<&str>,
    force: bool,
) -> Variants {
    static CACHE: OnceLock<Mutex<ModelCache>> = OnceLock::new();
    let Some(binary) = executable(command) else {
        return Variants::new();
    };
    let directory = directory
        .map(Path::to_path_buf)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(std::env::temp_dir);
    let key = (binary, directory);
    let cache = CACHE.get_or_init(Mutex::default);
    if !force
        && let Some((at, variants)) = cache.lock().unwrap_or_else(|e| e.into_inner()).get(&key)
        && at.elapsed()
            < if expected_model.map_or(!variants.is_empty(), |model| variants.contains_key(model)) {
                CACHE_TTL
            } else {
                Duration::from_secs(5)
            }
    {
        return variants.clone();
    }
    // Keep one leased server alive while its plugin-backed model registry
    // settles. A fresh standalone CLI per poll would keep seeing a cold
    // snapshot; the user's service may also run an incompatible CLI version.
    let variants = (|| {
        let server = probe::Server::start(&key.0.path, &key.1, SERVER_TIMEOUT)?;
        settled_snapshot(&server, "/api/model", parse_variants, |variants| {
            expected_model.map_or(!variants.is_empty(), |model| variants.contains_key(model))
        })
    })()
    .unwrap_or_default();
    let mut cache = cache.lock().unwrap_or_else(|e| e.into_inner());
    cache.retain(|_, (at, _)| at.elapsed() < CACHE_TTL);
    // Bound project-specific catalogs even on hosts opening many folders.
    if cache.len() >= 32 {
        cache.clear();
    }
    cache.insert(key, (Instant::now(), variants.clone()));
    variants
}

/// The picker and effort selection use the same version-matched registry.
pub(crate) fn models(command: &str, force: bool) -> Option<Vec<String>> {
    if detected_generation(command)? == Generation::V1 {
        let binary = executable(command)?;
        let output = crate::agent_models::run_cli_probe(
            &binary.path,
            &["models"],
            SERVER_TIMEOUT,
            256 * 1024,
            None,
            &[],
        )?;
        return output.success.then(|| {
            crate::agent_models::parse_opencode_models(&format!(
                "{}\n{}",
                output.stdout, output.stderr
            ))
        });
    }
    let mut models: Vec<String> = variants(command, None, None, force).into_keys().collect();
    models.sort();
    (!models.is_empty()).then_some(models)
}

fn parse_variants(output: &str) -> Option<Variants> {
    let value: serde_json::Value = serde_json::from_str(output).ok()?;
    let mut variants = Variants::new();
    for model in value.get("data")?.as_array()? {
        if model.get("enabled").and_then(|value| value.as_bool()) == Some(false) {
            continue;
        }
        let (Some(provider), Some(id)) = (
            model.get("providerID").and_then(|v| v.as_str()),
            model.get("id").and_then(|v| v.as_str()),
        ) else {
            continue;
        };
        let names = model
            .get("variants")
            .and_then(|v| v.as_array())
            .into_iter()
            .flatten()
            .filter_map(|v| v.get("id")?.as_str().map(str::to_string))
            .collect();
        variants.insert(format!("{provider}/{id}"), names);
    }
    Some(variants)
}

fn selected_model(model: &str, effort: Option<&str>, variants: &Variants) -> String {
    if !model.contains('#')
        && let Some(effort) = effort
        && variants
            .get(model)
            .is_some_and(|names| names.iter().any(|name| name == effort))
    {
        return format!("{model}#{effort}");
    }
    model.to_string()
}

pub(crate) fn model_arguments(
    command: &str,
    generation: Generation,
    model: Option<&str>,
    effort: Option<&str>,
    directory: Option<&Path>,
) -> Vec<String> {
    let mut args = Vec::new();
    match generation {
        Generation::V1 => {
            if let Some(model) = model {
                args.extend(["--model".into(), model.into()]);
            }
            if let Some(effort) = effort {
                args.extend(["--variant".into(), effort.into()]);
            }
        }
        Generation::V2 => {
            if let Some(model) = model {
                let variants = if effort.is_some() && !model.contains('#') {
                    variants(command, directory, Some(model), false)
                } else {
                    Variants::new()
                };
                args.extend(["--model".into(), selected_model(model, effort, &variants)]);
            } else if let Some(effort) = effort {
                // V2 has no independent effort flag. Resolve the configured
                // default before applying an effort to an otherwise empty pick.
                let default = (|| {
                    let binary = executable(command)?;
                    let directory = directory
                        .map(Path::to_path_buf)
                        .or_else(|| std::env::current_dir().ok())?;
                    let server = probe::Server::start(&binary.path, &directory, SERVER_TIMEOUT)?;
                    let value: serde_json::Value = settled_snapshot(
                        &server,
                        "/api/model/default",
                        |output| serde_json::from_str(output).ok(),
                        |value: &serde_json::Value| {
                            value.get("data").is_some_and(|data| !data.is_null())
                        },
                    )?;
                    let model = value.get("data")?;
                    let id = format!(
                        "{}/{}",
                        model.get("providerID")?.as_str()?,
                        model.get("id")?.as_str()?
                    );
                    let variants =
                        parse_variants(&serde_json::json!({"data":[model]}).to_string())?;
                    let selected = selected_model(&id, Some(effort), &variants);
                    (selected != id).then_some(selected)
                })();
                if let Some(model) = default {
                    args.extend(["--model".into(), model]);
                }
            }
        }
    }
    args
}

/// Only an authoritative absence invalidates a saved native session.
/// Probe V2 through the selected executable so it owns its schema and data
/// root; guessing a local SQLite layout could discard a valid session.
pub(crate) fn session_exists(command: &str, id: &str, directory: Option<&Path>) -> Option<bool> {
    match detected_generation(command)? {
        Generation::V2 => {
            if !id.starts_with("ses_")
                || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
            {
                return None;
            }
            let binary = executable(command)?;
            let route = format!("/api/session/{id}");
            let server = probe::Server::start(&binary.path, directory?, SERVER_TIMEOUT)?;
            let (success, output) = server.get(&route, 64 * 1024)?;
            session_from_response(success, &output, id)
        }
        Generation::V1 => {
            let login = tokenstat_pty::login_env();
            let environment = |name: &str| match &login {
                Some(login) => login.vars.get(name).map(PathBuf::from),
                None => std::env::var_os(name).map(PathBuf::from),
            };
            let home = environment(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
                .filter(|path| path.is_absolute())
                .or_else(tokenstat_paths::home_dir)?;
            let path = match environment("XDG_DATA_HOME").filter(|path| path.is_absolute()) {
                Some(data) => data.join("opencode/opencode.db"),
                None => tokenstat_core::sources::opencode::discover(&home)?,
            };
            tokenstat_core::sources::opencode::session_exists(&path, id, false).ok()
        }
    }
}

fn session_from_response(success: bool, output: &str, id: &str) -> Option<bool> {
    let value: serde_json::Value = serde_json::from_str(output).ok()?;
    let tag = value.get("_tag").and_then(|v| v.as_str());
    // Older preview CLIs exit zero even for an HTTP error body.
    if tag == Some("SessionNotFoundError") {
        return Some(false);
    }
    if success {
        let found = value
            .get("id")
            .or_else(|| value.pointer("/data/id"))?
            .as_str()?;
        return (found == id).then_some(true);
    }
    None
}

#[cfg(all(test, unix))]
#[path = "opencode_cli_live_tests.rs"]
mod live_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn fake_cli(root: &Path, body: &str) -> String {
        use std::os::unix::fs::PermissionsExt;
        let path = root.join("opencode");
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path.to_str().unwrap().to_string()
    }

    #[cfg(unix)]
    fn fake_api(root: &Path, output: &str, cold: bool) -> String {
        use std::os::unix::fs::PermissionsExt;
        let path = root.join("opencode");
        let payload = serde_json::to_string(output).unwrap();
        let script = format!(
            r#"#!/usr/bin/env python3
import json,sys,os,base64,threading,time
from http.server import BaseHTTPRequestHandler,HTTPServer
if '--version' in sys.argv:
 print('opencode v2.0.32');sys.exit(0)
PAYLOAD={payload}
count=0
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  global count
  count+=1
  if {cold} and count==1:time.sleep(2.1)
  expected='Basic '+base64.b64encode(('opencode:'+os.environ['OPENCODE_PASSWORD']).encode()).decode()
  if self.headers.get('Authorization')!=expected:
   self.send_response(401);self.end_headers();return
  with open(sys.argv[0]+'.args','a') as f:f.write('GET '+self.path+'\nx-opencode-directory:'+self.headers.get('x-opencode-directory','')+'\n')
  self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers()
  body=('{{"data":[]}}' if count==1 else '{{"data":[{{"providerID":"stale","id":"bundled"}},{{"providerID":"opencode-go","id":"gemini","variants":[]}}]}}') if {cold} and count<=3 else PAYLOAD
  self.wfile.write(body.encode())
server=HTTPServer(('127.0.0.1',0),Handler)
print(json.dumps({{'url':'http://127.0.0.1:'+str(server.server_port)}}),flush=True)
def lease():
 sys.stdin.read();server.shutdown()
threading.Thread(target=lease,daemon=True).start()
server.serve_forever()
"#,
            cold = if cold { "True" } else { "False" }
        );
        std::fs::write(&path, script).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path.to_str().unwrap().to_string()
    }

    #[test]
    #[cfg(unix)]
    fn replacing_opencode_invalidates_detection_and_preserves_a_wrapper() {
        let root = tempfile::tempdir().unwrap();
        let binary = fake_cli(root.path(), "echo 'model flags: --model --variant'");
        assert_eq!(generation(&binary), Generation::V1);
        fake_cli(
            root.path(),
            "echo 'Model to use in the format provider/model#variant'",
        );
        assert_eq!(generation(&binary), Generation::V2);
        // A wrapper is executed as supplied; no binary is renamed or replaced.
        assert!(
            std::fs::read_to_string(binary)
                .unwrap()
                .starts_with("#!/bin/sh")
        );
    }

    #[test]
    #[cfg(unix)]
    fn model_probe_is_project_scoped_and_does_not_guess_unsupported_efforts() {
        let root = tempfile::tempdir().unwrap();
        let binary = fake_api(
            root.path(),
            r#"{"data":[{"providerID":"opencode-go","id":"gemini","variants":[{"id":"high"}]}]}"#,
            true,
        );
        assert_eq!(models(&binary, true).unwrap(), ["opencode-go/gemini"]);
        let args = model_arguments(
            &binary,
            Generation::V2,
            Some("opencode-go/gemini"),
            Some("high"),
            Some(root.path()),
        );
        assert_eq!(args, ["--model", "opencode-go/gemini#high"]);
        let probe = std::fs::read_to_string(format!("{binary}.args")).unwrap();
        assert!(probe.contains("GET /api/model\nx-opencode-directory:"));
        assert!(
            probe.matches("GET /api/model").count() >= 4,
            "empty and bundled snapshots must settle on the same leased server"
        );
        assert!(probe.contains(&directory_header(root.path())));
        let args = model_arguments(
            &binary,
            Generation::V2,
            Some("opencode-go/gemini"),
            Some("max"),
            Some(root.path()),
        );
        assert_eq!(args, ["--model", "opencode-go/gemini"]);
        assert!(
            model_arguments(
                &binary,
                Generation::V2,
                None,
                Some("high"),
                Some(root.path())
            )
            .is_empty()
        );
        let args = model_arguments(
            &binary,
            Generation::V1,
            Some("opencode-go/gemini"),
            Some("max"),
            Some(root.path()),
        );
        assert_eq!(args, ["--model", "opencode-go/gemini", "--variant", "max"]);
    }

    #[test]
    #[cfg(unix)]
    fn leased_probe_bounds_startup_and_retires_a_stalled_process_group() {
        for response in ["echo '{}'", "true"] {
            let root = tempfile::tempdir().unwrap();
            let binary = fake_cli(
                root.path(),
                &format!("echo $$ > \"$0.pid\"\n{response}\nsleep 30"),
            );
            let start = Instant::now();
            assert!(
                probe::Server::start(&binary, root.path(), Duration::from_millis(150)).is_none()
            );
            assert!(start.elapsed() < Duration::from_secs(5));
            let pid: i32 = std::fs::read_to_string(format!("{binary}.pid"))
                .unwrap()
                .trim()
                .parse()
                .unwrap();
            // The dedicated process group was killed, including the sleeper.
            let deadline = Instant::now() + Duration::from_secs(2);
            loop {
                let alive = unsafe { libc::kill(-pid, 0) } == 0;
                if !alive {
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "stalled probe group survived cleanup"
                );
                std::thread::sleep(Duration::from_millis(20));
            }
        }
    }

    #[test]
    fn help_identifies_the_contract_without_relying_on_the_binary_name_or_version() {
        assert_eq!(
            generation_from_help("--model string\n--variant string"),
            Some(Generation::V1)
        );
        assert_eq!(
            generation_from_help("--model string provider/model#variant"),
            Some(Generation::V2)
        );
        assert_eq!(generation_from_help(""), None);
    }

    #[test]
    #[cfg(unix)]
    fn detects_stable_versions_and_stderr_help_under_any_executable_name() {
        for name in ["opencode", "opencode1", "opencode2"] {
            for (version, help, expected) in [
                ("1.19.3", "--variant string", Generation::V1),
                ("opencode v2.0.1", "provider/model#variant", Generation::V2),
                (
                    "opencode2 v0.0.0-next-17444",
                    "provider/model#variant",
                    Generation::V2,
                ),
            ] {
                let root = tempfile::tempdir().unwrap();
                let binary = fake_cli(
                    root.path(),
                    &format!(
                        "case \"$1\" in --version) echo '{version}' >&2;; run) echo '{help}' >&2;; esac"
                    ),
                );
                let renamed = root.path().join(name);
                if renamed != Path::new(&binary) {
                    std::fs::rename(&binary, &renamed).unwrap();
                }
                assert_eq!(
                    require_generation(renamed.to_str().unwrap()).unwrap(),
                    expected
                );
            }
        }
    }

    #[test]
    #[cfg(unix)]
    fn unchanged_wrapper_rechecks_the_binary_it_forwards_to() {
        let root = tempfile::tempdir().unwrap();
        let real = root.path().join("actual-version");
        std::fs::write(&real, "1.19.3").unwrap();
        let binary = fake_cli(
            root.path(),
            &format!(
                "cat \"$(dirname \"$0\")/actual-version\"\n#{}",
                "padding".repeat(10_000)
            ),
        );
        let before = std::fs::read(&binary).unwrap();
        assert_eq!(require_generation(&binary).unwrap(), Generation::V1);
        std::fs::write(&real, "opencode v2.0.1").unwrap();
        assert_eq!(require_generation(&binary).unwrap(), Generation::V2);
        assert_eq!(std::fs::read(&binary).unwrap(), before);
        fake_cli(root.path(), "echo 'unexpected response'");
        assert!(
            require_generation(&binary).is_err(),
            "an installed but unidentified CLI must not be guessed"
        );
    }

    #[test]
    fn session_validation_keeps_auth_transport_and_malformed_responses_inconclusive() {
        let id = "ses_012345abcdef0123456789abcd";
        assert_eq!(
            session_from_response(true, &format!(r#"{{"id":"{id}"}}"#), id),
            Some(true)
        );
        for success in [true, false] {
            assert_eq!(
                session_from_response(success, r#"{"_tag":"SessionNotFoundError"}"#, id),
                Some(false)
            );
        }
        for body in [
            r#"{"_tag":"UnauthorizedError"}"#,
            r#"{"_tag":"ServiceUnavailableError"}"#,
            "not json",
            r#"{"id":"other"}"#,
        ] {
            assert_eq!(session_from_response(false, body, id), None);
        }
        assert_eq!(session_from_response(true, r#"{"id":"other"}"#, id), None);
    }

    #[test]
    fn directory_headers_encode_unicode_spaces_and_delimiters() {
        assert_eq!(
            directory_header(Path::new("/tmp/ü 🦆/#?")),
            "x-opencode-directory:%2Ftmp%2F%C3%BC%20%F0%9F%A6%86%2F%23%3F"
        );
    }

    #[test]
    #[cfg(unix)]
    fn effort_can_select_a_variant_of_the_configured_default() {
        let root = tempfile::tempdir().unwrap();
        let binary = fake_api(
            root.path(),
            r#"{"data":{"providerID":"custom","id":"default","variants":[{"id":"high"}]}}"#,
            false,
        );
        assert_eq!(
            model_arguments(
                &binary,
                Generation::V2,
                None,
                Some("high"),
                Some(root.path())
            ),
            ["--model", "custom/default#high"]
        );
        assert!(
            model_arguments(
                &binary,
                Generation::V2,
                None,
                Some("max"),
                Some(root.path())
            )
            .is_empty()
        );
        fake_cli(root.path(), "echo 'server unavailable' >&2; exit 1");
        assert_eq!(
            model_arguments(
                &binary,
                Generation::V2,
                Some("custom/default"),
                Some("high"),
                Some(root.path())
            ),
            ["--model", "custom/default"]
        );
    }

    #[test]
    fn v2_gate_leaves_native_permissions_at_ask_until_the_plugin_approves() {
        let config = gate_config(Generation::V2, Path::new("/private/gate/v2"));
        assert_eq!(config["plugins"], serde_json::json!(["/private/gate/v2"]));
        assert_eq!(
            config["permissions"],
            serde_json::json!([{"action":"*", "resource":"*", "effect":"ask"}])
        );
        assert!(config.get("plugin").is_none());
        let legacy = gate_config(Generation::V1, Path::new("/private/gate/v1.js"));
        assert!(legacy.get("plugin").is_some());
        assert!(legacy.get("permission").is_some());
    }

    #[test]
    fn variants_are_per_model_and_explicit_suffixes_survive() {
        let catalog = parse_variants(
            r#"{"data":[
            {"providerID":"opencode","id":"beam-free","variants":[{"id":"max"}]},
            {"providerID":"opencode-go","id":"gemini","variants":[{"id":"high"}]},
            {"providerID":"meta","id":"muse","variants":[{"id":"max"}]},
            {"providerID":"custom","id":"org/model","variants":[{"id":"deep"}]}
        ]}"#,
        )
        .unwrap();
        for model in ["opencode/beam-free", "meta/muse"] {
            assert_eq!(
                selected_model(model, Some("max"), &catalog),
                format!("{model}#max")
            );
        }
        assert_eq!(
            selected_model("opencode-go/gemini", Some("max"), &catalog),
            "opencode-go/gemini"
        );
        assert_eq!(
            selected_model("opencode-go/gemini", Some("high"), &catalog),
            "opencode-go/gemini#high"
        );
        assert_eq!(
            selected_model("custom/org/model", Some("deep"), &catalog),
            "custom/org/model#deep"
        );
        assert_eq!(
            selected_model("opencode/beam-free#high", Some("max"), &catalog),
            "opencode/beam-free#high"
        );
        assert_eq!(
            selected_model("unknown/model", Some("max"), &catalog),
            "unknown/model"
        );
        assert_eq!(
            selected_model("opencode/beam-free", Some("max"), &Variants::new()),
            "opencode/beam-free"
        );
    }
}
