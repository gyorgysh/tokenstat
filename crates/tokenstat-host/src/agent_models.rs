// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Live model lists from the agent CLIs this machine actually has.
//!
//! The picker used to ship a curated snapshot. That goes stale the moment a
//! CLI adds a default (grok-4.6 was on `grok models` while the picker still
//! offered only grok-4.5). Each backend that can list does so here. A miss
//! falls back to the small snapshot so a missing CLI still has something to
//! show, and a timeout cannot hang the picker.

use std::collections::HashMap;
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

const LIVE_TTL: Duration = Duration::from_secs(10 * 60);
const MISS_TTL: Duration = Duration::from_secs(60);
const LIST_TIMEOUT: Duration = Duration::from_secs(8);
const LIST_CAP: usize = 256 * 1024;

enum Cached {
    Live(Vec<String>),
    Miss,
}

struct Entry {
    at: Instant,
    value: Cached,
}

fn cache() -> &'static Mutex<HashMap<String, Entry>> {
    static CACHE: OnceLock<Mutex<HashMap<String, Entry>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn cache_lock() -> std::sync::MutexGuard<'static, HashMap<String, Entry>> {
    cache().lock().unwrap_or_else(PoisonError::into_inner)
}

/// Ask every listable CLI, in parallel, so one `automation.backends` call
/// waits one timeout rather than one per backend.
///
/// Off the request path: each probe shells a CLI with an 8s timeout, and a
/// hung one (a broken grok install hangs rather than failing) used to stall
/// the whole backends call for seconds, every minute, on every screen that
/// asked. Callers serve the cache (or the curated fallback) immediately; the
/// probes refill it in the background. First call after daemon start answers
/// from fallbacks and the live lists arrive a moment later.
pub fn refresh() {
    if !needs_refresh() || !claim_refresh() {
        return;
    }
    std::thread::spawn(refresh_blocking);
}

/// Whether any entry is missing or past its TTL. Pure cache read, no probes.
fn needs_refresh() -> bool {
    let cache = cache_lock();
    for id in ["grok", "cursor", "agy", "opencode", "opencode2"] {
        let stale = match cache.get(id) {
            None => true,
            Some(entry) => {
                let ttl = match entry.value {
                    Cached::Live(_) => LIVE_TTL,
                    Cached::Miss => MISS_TTL,
                };
                entry.at.elapsed() >= ttl
            }
        };
        if stale {
            return true;
        }
    }
    false
}

/// One background refresh at a time. A second caller while probes are in
/// flight serves the cache instead of doubling the subprocesses.
static REFRESH_IN_FLIGHT: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

fn claim_refresh() -> bool {
    REFRESH_IN_FLIGHT
        .compare_exchange(
            false,
            true,
            std::sync::atomic::Ordering::AcqRel,
            std::sync::atomic::Ordering::Acquire,
        )
        .is_ok()
}

fn release_refresh() {
    REFRESH_IN_FLIGHT.store(false, std::sync::atomic::Ordering::Release);
}

/// The probes themselves, on a background thread: same parallel fan-out as
/// before, one timeout rather than one per backend, but no request waits
/// for it. The claim releases even on panic, so one bad probe run cannot
/// wedge every later refresh.
fn refresh_blocking() {
    struct ReleaseOnDrop;
    impl Drop for ReleaseOnDrop {
        fn drop(&mut self) {
            release_refresh();
        }
    }
    let _release = ReleaseOnDrop;
    std::thread::scope(|scope| {
        scope.spawn(|| fill("grok", || list("grok", &["models"], parse_grok_models)));
        scope.spawn(|| {
            fill("cursor", || {
                list("cursor-agent", &["models"], parse_cursor_models)
            })
        });
        scope.spawn(|| fill("agy", || list("agy", &["models"], parse_agy_models)));
        scope.spawn(|| {
            fill("opencode", || {
                list("opencode", &["models"], parse_opencode_models)
            })
        });
        scope.spawn(|| {
            fill("opencode2", || {
                list("opencode2", &["models"], parse_opencode_models)
            })
        });
    });
}

/// The live list when we have one, otherwise the curated fallback.
pub fn for_backend(id: &str, fallback: &[&str]) -> Vec<String> {
    match cache_lock().get(id) {
        Some(Entry {
            value: Cached::Live(list),
            ..
        }) if !list.is_empty() => list.clone(),
        _ => fallback.iter().map(|s| (*s).to_string()).collect(),
    }
}

fn fill(id: &str, fetch: impl FnOnce() -> Option<Vec<String>>) {
    if let Some(entry) = cache_lock().get(id) {
        let ttl = match entry.value {
            Cached::Live(_) => LIVE_TTL,
            Cached::Miss => MISS_TTL,
        };
        if entry.at.elapsed() < ttl {
            return;
        }
    }
    let value = match fetch() {
        Some(list) if !list.is_empty() => Cached::Live(list),
        _ => Cached::Miss,
    };
    cache_lock().insert(
        id.to_string(),
        Entry {
            at: Instant::now(),
            value,
        },
    );
}

fn list(command: &str, args: &[&str], parse: fn(&str) -> Vec<String>) -> Option<Vec<String>> {
    let bin = crate::launcher::resolve_command(command)?;
    let stdout = run_list(&bin, args)?;
    let models = parse(&stdout);
    if models.is_empty() {
        None
    } else {
        Some(models)
    }
}

fn run_list(bin: &str, args: &[&str]) -> Option<String> {
    let mut cmd = Command::new(bin);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env("PATH", crate::launcher::search_path_var());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }
    let mut child = cmd.spawn().ok()?;
    let stdout = child.stdout.take()?;
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stdout.take(LIST_CAP as u64).read_to_end(&mut buf);
        let _ = tx.send(buf);
    });
    let deadline = Instant::now() + LIST_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    #[cfg(unix)]
                    {
                        let pid = child.id();
                        let _ = Command::new("kill")
                            .args(["-9", &format!("-{pid}")])
                            .status();
                    }
                    let _ = child.wait();
                    return None;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    };
    if !status.success() {
        return None;
    }
    let bytes = rx.recv_timeout(Duration::from_secs(1)).ok()?;
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

/// `grok models` prints a login banner, then `* grok-4.6 (default)` / `- grok-4.5`.
pub(crate) fn parse_grok_models(out: &str) -> Vec<String> {
    let mut models = Vec::new();
    let mut default = None;
    for line in out.lines() {
        let trimmed = line.trim();
        let body = trimmed.trim_start_matches(['*', '-', '•']).trim_start();
        if body.is_empty() || (body.contains(' ') && !body.starts_with("grok-")) {
            if let Some(rest) = trimmed.strip_prefix("Default model:") {
                let id = rest.split_whitespace().next().unwrap_or("");
                if is_model_id(id) {
                    default = Some(id.to_string());
                }
            }
            continue;
        }
        let id = body.split_whitespace().next().unwrap_or("");
        if !is_model_id(id) {
            continue;
        }
        if !models.iter().any(|m| m == id) {
            if body.contains("(default)") {
                default = Some(id.to_string());
            }
            models.push(id.to_string());
        }
    }
    if let Some(id) = default {
        if let Some(idx) = models.iter().position(|m| m == &id) {
            models.remove(idx);
        }
        models.insert(0, id);
    }
    models
}

/// `cursor-agent models` (and `agent models`) print `<id> - <label>`.
pub(crate) fn parse_cursor_models(out: &str) -> Vec<String> {
    out.lines()
        .filter_map(|line| {
            let line = line.trim();
            let (id, rest) = line.split_once(" - ")?;
            let id = id.trim();
            if rest.is_empty() || !is_model_id(id) {
                None
            } else {
                Some(id.to_string())
            }
        })
        .collect()
}

/// Current `agy models` mashes the id into the label (`gemini-3.6-flash-highGemini 3.6 Flash (High)`).
/// Some builds print `id<TAB>label`. Older builds printed the label alone,
/// and that label is what `--model` accepted.
pub(crate) fn parse_agy_models(out: &str) -> Vec<String> {
    let mut models = Vec::new();
    for line in out.lines() {
        let line = line.trim();
        if line.is_empty() || line.to_ascii_lowercase().starts_with("fetching") {
            continue;
        }
        if let Some(id) = sanitize_agy_model(line) {
            if !models.iter().any(|m| m == &id) {
                models.push(id);
            }
        }
    }
    models
}

/// The token `agy --model` will accept. Strips a tab-separated label, or the
/// mashed `idLabel` form, so a picker value cannot poison the launch argv.
pub(crate) fn sanitize_agy_model(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let first = trimmed.split(['\t', '\n']).next().unwrap_or(trimmed).trim();
    if let Some(id) = split_agy_id(first) {
        return Some(id);
    }
    if let Some(id) = split_agy_id(trimmed) {
        return Some(id);
    }
    if is_model_id(first) {
        return Some(first.to_string());
    }
    // Legacy: the whole line is the `--model` value, e.g. "Gemini 3.1 Pro (High)".
    if first.chars().any(|c| c.is_whitespace()) {
        return Some(first.to_string());
    }
    None
}

/// Drop a tab/label suffix on any backend so a stored picker value stays an id.
pub(crate) fn sanitize_cli_model(backend: &str, model: Option<&str>) -> Option<String> {
    let raw = model?.trim();
    if raw.is_empty() {
        return None;
    }
    if backend == "agy" {
        return sanitize_agy_model(raw);
    }
    let first = raw.split(['\t', '\n']).next().unwrap_or(raw).trim();
    if first.is_empty() {
        None
    } else {
        Some(first.to_string())
    }
}

/// `opencode models` prints `provider/model` lines.
pub(crate) fn parse_opencode_models(out: &str) -> Vec<String> {
    out.lines()
        .map(str::trim)
        .filter(|id| {
            let (provider, model) = match id.split_once('/') {
                Some(parts) => parts,
                None => return false,
            };
            is_model_id(provider) && !model.is_empty() && !model.chars().any(char::is_control)
        })
        .map(str::to_string)
        .collect()
}

fn split_agy_id(line: &str) -> Option<String> {
    let bytes = line.as_bytes();
    if !bytes.first()?.is_ascii_lowercase() {
        return None;
    }
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        if c.is_ascii_uppercase() {
            let id = &line[..i];
            return is_model_id(id).then(|| id.to_string());
        }
        if !(c.is_ascii_alphanumeric() || c == b'-' || c == b'.' || c == b'_') {
            return None;
        }
        i += 1;
    }
    None
}

const CHEAP_MARKERS: &[&str] = &["haiku", "nano", "mini", "flash", "fast", "lite", "small"];

/// First listed id that looks cheap. Claude falls back to the last alias.
pub fn cheapest_model(backend: &str, models: &[String]) -> Option<String> {
    if models.is_empty() {
        return None;
    }
    for marker in CHEAP_MARKERS {
        if let Some(id) = models
            .iter()
            .find(|m| m.to_ascii_lowercase().contains(marker))
        {
            return Some(id.clone());
        }
    }
    if backend == "claude" {
        return models.last().cloned();
    }
    models.first().cloned()
}

/// `low` or `minimal` when advertised, otherwise the first level.
pub fn lowest_effort(efforts: &[String]) -> Option<String> {
    for prefer in ["low", "minimal"] {
        if let Some(found) = efforts.iter().find(|e| e.eq_ignore_ascii_case(prefer)) {
            return Some(found.clone());
        }
    }
    efforts.first().cloned()
}

fn is_model_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '.' | '_'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cheapest_model_prefers_a_haiku_alias() {
        let models = ["fable", "opus", "sonnet", "haiku"].map(String::from);
        assert_eq!(cheapest_model("claude", &models).as_deref(), Some("haiku"));
    }

    #[test]
    fn cheapest_model_on_claude_without_a_marker_uses_the_last() {
        let models = ["opus", "sonnet"].map(String::from);
        assert_eq!(cheapest_model("claude", &models).as_deref(), Some("sonnet"));
    }

    #[test]
    fn lowest_effort_prefers_low_then_minimal() {
        let high_first = ["high", "medium", "low"].map(String::from);
        assert_eq!(lowest_effort(&high_first).as_deref(), Some("low"));
        let max_stack = ["max", "high", "minimal"].map(String::from);
        assert_eq!(lowest_effort(&max_stack).as_deref(), Some("minimal"));
    }

    #[test]
    fn grok_list_puts_the_default_first() {
        let out = "\
You are logged in with grok.com.

Default model: grok-4.6

Available models:
  * grok-4.6 (default)
  - grok-4.5
";
        assert_eq!(
            parse_grok_models(out),
            vec!["grok-4.6".to_string(), "grok-4.5".to_string()]
        );
    }

    #[test]
    fn cursor_list_takes_the_id_before_the_dash() {
        let out = "\
Available models

auto - Auto (default)
gpt-5.3-codex - Codex 5.3
cursor-grok-4.6-high - Cursor Grok 4.6
";
        assert_eq!(
            parse_cursor_models(out),
            vec![
                "auto".to_string(),
                "gpt-5.3-codex".to_string(),
                "cursor-grok-4.6-high".to_string()
            ]
        );
    }

    #[test]
    fn agy_list_splits_a_mashed_id_and_label() {
        let out = "\
Fetching available models...
gemini-3.6-flash-highGemini 3.6 Flash (High)
claude-sonnet-4-6Claude Sonnet 4.6 (Thinking)
gpt-oss-120b-mediumGPT-OSS 120B (Medium)
";
        assert_eq!(
            parse_agy_models(out),
            vec![
                "gemini-3.6-flash-high".to_string(),
                "claude-sonnet-4-6".to_string(),
                "gpt-oss-120b-medium".to_string()
            ]
        );
    }

    #[test]
    fn agy_list_keeps_a_legacy_label() {
        assert_eq!(
            parse_agy_models("Gemini 3.1 Pro (High)\n"),
            vec!["Gemini 3.1 Pro (High)".to_string()]
        );
    }

    #[test]
    fn agy_list_splits_a_tab_separated_id() {
        let out = "gemini-3.6-flash-high\tGemini 3.6 Flash (High)\n";
        assert_eq!(
            parse_agy_models(out),
            vec!["gemini-3.6-flash-high".to_string()]
        );
        assert_eq!(
            sanitize_agy_model("gemini-3.6-flash-high\tGemini 3.6 Flash (High)").as_deref(),
            Some("gemini-3.6-flash-high")
        );
    }

    fn parse_if_cli_lists(
        command: &str,
        args: &[&str],
        parse: fn(&str) -> Vec<String>,
    ) -> Option<Vec<String>> {
        let out = std::process::Command::new(command)
            .args(args)
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        let list = parse(&String::from_utf8_lossy(&out.stdout));
        if list.is_empty() { None } else { Some(list) }
    }

    #[test]
    fn a_hanging_list_command_is_reaped() {
        let start = Instant::now();
        assert!(run_list("/bin/sleep", &["30"]).is_none());
        assert!(
            start.elapsed() < Duration::from_secs(12),
            "list timeout should fire well before the sleep ends"
        );
    }

    #[test]
    fn installed_clis_parse_to_model_ids() {
        if let Some(list) = parse_if_cli_lists("grok", &["models"], parse_grok_models) {
            assert!(
                list.iter().any(|m| m.starts_with("grok-")),
                "grok models parsed to {list:?}"
            );
        }
        if let Some(list) = parse_if_cli_lists("cursor-agent", &["models"], parse_cursor_models) {
            assert!(
                list.iter().any(|m| m == "auto" || m.contains('-')),
                "cursor-agent models parsed to {list:?}"
            );
        }
        if let Some(list) = parse_if_cli_lists("agy", &["models"], parse_agy_models) {
            assert!(
                list.iter().any(|m| m.contains('-') || m.contains(' ')),
                "agy models parsed to {list:?}"
            );
        }
        if let Some(list) = parse_if_cli_lists("opencode", &["models"], parse_opencode_models) {
            assert!(
                list.iter().any(|m| m.contains('/')),
                "opencode models parsed to {list:?}"
            );
        }
    }

    #[test]
    fn opencode_list_keeps_provider_slash_model() {
        let out = "\
opencode/big-pickle
opencode-go/grok-4.5
lmstudio/qwen/qwen3-coder-30b
not-a-model
";
        assert_eq!(
            parse_opencode_models(out),
            vec![
                "opencode/big-pickle".to_string(),
                "opencode-go/grok-4.5".to_string(),
                "lmstudio/qwen/qwen3-coder-30b".to_string()
            ]
        );
    }
}
