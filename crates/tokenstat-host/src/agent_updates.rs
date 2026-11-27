// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Keeping agent CLIs current for people who only use them through chat.

use serde_json::{Value, json};
use std::time::Duration;
use tokenstat_sync::agent_versions::{self, LatestSource};

#[derive(Clone, Debug, PartialEq)]
enum Via {
    Own(&'static [&'static str]),
    Package(&'static str),
    Installer,
}

struct Plan {
    latest: Option<LatestSource>,
    via: Via,
}

fn plan(id: &str) -> Option<Plan> {
    let (latest, via) = match id {
        "claude_code" => (
            Some(LatestSource::Text(
                "https://downloads.claude.ai/claude-code-releases/latest",
            )),
            Via::Own(&["update"]),
        ),
        "codex" => (
            Some(LatestSource::Json(
                "https://releases.openai.com/codex/channels/latest".into(),
                "/tag_name",
            )),
            Via::Own(&["update"]),
        ),
        "opencode" | "opencode2" => (
            Some(LatestSource::Json(
                "https://opencode.ai/update/api/latest/cli/npm".into(),
                "/version",
            )),
            Via::Own(&["upgrade"]),
        ),
        "grok" => (
            Some(LatestSource::Text("https://x.ai/cli/stable")),
            Via::Own(&["update"]),
        ),
        "copilot" => (
            Some(LatestSource::Npm("@github/copilot")),
            Via::Own(&["update"]),
        ),
        "cline" => (Some(LatestSource::Npm("cline")), Via::Package("cline")),
        "openclaw" => (Some(LatestSource::Npm("openclaw")), Via::Package("openclaw")),


        "muse" => (None, Via::Installer),
        "omp" => (
            Some(LatestSource::Npm("@oh-my-pi/pi-coding-agent")),
            Via::Own(&["update"]),
        ),
        "pi" => (
            Some(LatestSource::Npm("@earendil-works/pi-coding-agent")),
            Via::Package("@earendil-works/pi-coding-agent"),
        ),
        "antigravity" => (
            antigravity_platform().map(|platform| {
                LatestSource::Json(
                    format!(
                        "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/{platform}.json"
                    ),
                    "/version",
                )
            }),
            Via::Own(&["update"]),
        ),
        "cursor_agent" => (
            Some(LatestSource::ScriptMarker(
                "https://cursor.com/install",
                "downloads.cursor.com/lab/",
            )),
            Via::Own(&["update"]),
        ),
        "hermes" => (
            Some(LatestSource::GitHubRelease("NousResearch/hermes-agent")),
            Via::Own(&["update"]),
        ),
        "kilo" => (
            Some(LatestSource::Npm("@kilocode/cli")),
            Via::Package("@kilocode/cli"),
        ),
        "kimi" => (
            Some(LatestSource::Text("https://code.kimi.com/kimi-code/latest")),
            Via::Own(&["upgrade"]),
        ),
        "qwen" => (
            Some(LatestSource::Text(
                "https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/releases/qwen-code/latest/VERSION",
            )),
            Via::Installer,
        ),
        "devin" => (
            Some(LatestSource::Json(
                "https://static.devin.ai/cli/current/manifest.json".into(),
                "/version",
            )),
            Via::Own(&["update"]),
        ),
        _ => return None,
    };
    Some(Plan { latest, via })
}

fn antigravity_platform() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => Some("darwin_arm64"),
        ("macos", "x86_64") => Some("darwin_amd64"),
        ("linux", "aarch64") => Some("linux_arm64"),
        ("linux", "x86_64") => Some("linux_amd64"),
        ("windows", "x86_64") => Some("windows_amd64"),
        _ => None,
    }
}

fn version_in(banner: &str) -> Option<String> {
    let bytes = banner.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        let starts = index == 0
            || !bytes[index - 1].is_ascii_alphanumeric()
            || (bytes[index - 1] == b'v'
                && (index == 1 || !bytes[index - 2].is_ascii_alphanumeric()));
        if bytes[index].is_ascii_digit() && starts {
            let rest: String = banner[index..]
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-')
                .collect();
            let rest = rest.trim_end_matches(['.', '-']).to_owned();
            if rest
                .split('-')
                .next()
                .is_some_and(|core| core.contains('.'))
            {
                return Some(rest);
            }
        }
        index += 1;
    }
    None
}

fn numbers(version: &str) -> Vec<u64> {
    version
        .split('-')
        .next()
        .unwrap_or("")
        .split('.')
        .map(|part| part.parse().unwrap_or(0))
        .collect()
}

fn newer(latest: &str, installed: &str) -> bool {
    let (a, b) = (numbers(latest), numbers(installed));
    for index in 0..a.len().max(b.len()) {
        let (x, y) = (
            a.get(index).copied().unwrap_or(0),
            b.get(index).copied().unwrap_or(0),
        );
        if x != y {
            return x > y;
        }
    }
    false
}

fn installed_version(command: &str) -> Option<String> {
    let mut child = std::process::Command::new(command)
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .ok()?;
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(50));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let output = child.wait_with_output().ok()?;
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push('\n');
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    version_in(&text)
}

fn package_of(plan: &Plan) -> Option<&'static str> {
    match (&plan.via, &plan.latest) {
        (Via::Package(package), _) => Some(package),
        (_, Some(LatestSource::Npm(package))) => Some(package),
        _ => None,
    }
}

fn package_version(command: &str, package: &str) -> Option<String> {
    let real = std::fs::canonicalize(command).ok()?;
    for directory in real.ancestors().skip(1).take(6) {
        let Ok(text) = std::fs::read_to_string(directory.join("package.json")) else {
            continue;
        };
        let value: Value = serde_json::from_str(&text).ok()?;
        if value["name"] == package {
            return value["version"].as_str().map(str::to_owned);
        }
    }
    None
}

fn version_of(plan: &Plan, command: &str) -> Option<String> {
    package_of(plan)
        .and_then(|package| package_version(command, package))
        .or_else(|| installed_version(command))
}

const IDS: &[&str] = &[
    "claude_code",
    "codex",
    "opencode",
    "opencode2",
    "grok",
    "copilot",
    "cline",
    "openclaw",
    "muse",
    "omp",
    "pi",
    "antigravity",
    "cursor_agent",
    "hermes",
    "kilo",
    "kimi",
    "qwen",
    "devin",
];

fn stamp(command: &str) -> Option<String> {
    let real = std::fs::canonicalize(command).ok()?;
    let modified = std::fs::metadata(&real).ok()?.modified().ok()?;
    let seconds = modified
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    Some(format!("{}|{seconds}", real.display()))
}

fn row(id: &'static str, check: bool) -> Option<Value> {
    let plan = plan(id)?;
    let command = crate::launcher::resolved_command(id)?;
    let version = version_of(&plan, &command);
    let mut value = json!({
        "id": id,
        "name": crate::launcher::profile_name(id),
        "version": version,
        "canUpdate": true,
        "canCheck": plan.latest.is_some(),
        "busy": crate::chat::agent_busy(id),
        "stamp": stamp(&command),
    });
    if check && let Some(source) = &plan.latest {
        match agent_versions::latest(source) {
            Ok(latest) => {
                value["updateAvailable"] = json!(
                    version
                        .as_deref()
                        .is_some_and(|installed| newer(&latest, installed))
                );
                value["latest"] = json!(latest);
            }
            Err(error) => value["error"] = json!(error),
        }
    } else if plan.latest.is_some()
        && let Some(latest) = cached_latest(id)
    {
        value["updateAvailable"] = json!(
            version
                .as_deref()
                .is_some_and(|installed| newer(&latest, installed))
        );
        value["latest"] = json!(latest);
    }
    Some(value)
}

/// Every installed agent that tokenstat knows how to update. Versions are
/// read on this machine. The latest versions are fetched only with `check`,
/// which a client sends when somebody presses Check for updates.
///
/// One check runs at a time. A press while the scheduled check is running
/// waits for it and then answers from what it found, rather than asking
/// every vendor twice in a row.
pub(crate) fn list(check: bool) -> Value {
    if !check {
        return Value::Array(rows(false));
    }
    let _flight = FLIGHT
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let checked_at = with_cache(|cache| cache.checked_at_ms);
    if just_checked(crate::chat::now_ms(), checked_at) {
        return Value::Array(rows(false));
    }
    Value::Array(check_now())
}

fn rows(check: bool) -> Vec<Value> {
    let handles: Vec<_> = IDS
        .iter()
        .map(|id| std::thread::spawn(move || row(id, check)))
        .collect();
    handles
        .into_iter()
        .filter_map(|handle| handle.join().ok().flatten())
        .collect()
}

fn check_now() -> Vec<Value> {
    let fresh = rows(true);
    let merged = with_cache(|cache| merged(&cache.rows, fresh));
    remember(&merged);
    merged
}

static FLIGHT: std::sync::Mutex<()> = std::sync::Mutex::new(());

const JUST_CHECKED_MS: i64 = 30 * 1000;

fn just_checked(now: i64, checked_at: i64) -> bool {
    checked_at <= now && now.saturating_sub(checked_at) < JUST_CHECKED_MS
}

fn merged(previous: &[Value], fresh: Vec<Value>) -> Vec<Value> {
    fresh
        .into_iter()
        .map(|mut row| {
            if row.get("error").is_some() && row["latest"].as_str().is_none() {
                let known = previous
                    .iter()
                    .find(|old| old["id"] == row["id"])
                    .and_then(|old| old["latest"].as_str())
                    .filter(|latest| plausible_version(latest))
                    .map(str::to_owned);
                if let Some(latest) = known {
                    row["updateAvailable"] = json!(
                        row["version"]
                            .as_str()
                            .is_some_and(|installed| newer(&latest, installed))
                    );
                    row["latest"] = json!(latest);
                }
            }
            row
        })
        .collect()
}

fn plausible_version(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '+' | '_'))
}

#[derive(Default, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct Cache {
    checked_at_ms: i64,
    rows: Vec<Value>,
}

fn cache_path() -> Option<std::path::PathBuf> {
    Some(tokenstat_paths::data_dir()?.join("agent-updates.json"))
}

static CACHE: std::sync::Mutex<Option<Cache>> = std::sync::Mutex::new(None);

fn with_cache<T>(read: impl FnOnce(&mut Cache) -> T) -> T {
    let mut slot = CACHE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let cache = slot.get_or_insert_with(|| {
        cache_path()
            .and_then(|path| std::fs::read(path).ok())
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    });
    read(cache)
}

fn save(cache: &Cache) {
    if let Some(path) = cache_path()
        && let Ok(bytes) = serde_json::to_vec(cache)
    {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let temporary = path.with_extension("json.tmp");
        if std::fs::write(&temporary, bytes).is_ok() {
            let _ = std::fs::rename(&temporary, &path);
        }
    }
}

fn remember(rows: &[Value]) {
    with_cache(|cache| {
        cache.checked_at_ms = crate::chat::now_ms();
        cache.rows = rows.to_vec();
        save(cache);
    });
}

fn cached_latest(id: &str) -> Option<String> {
    with_cache(|cache| {
        cache
            .rows
            .iter()
            .find(|row| row["id"] == id)
            .and_then(|row| row["latest"].as_str())
            .filter(|latest| plausible_version(latest))
            .map(str::to_owned)
    })
}

/// The cached row for one agent, for the agent picker: `updateAvailable`,
/// `latest` and `version` from the last check. Cheap: no process, no request.
pub(crate) fn cached(id: &str) -> Option<Value> {
    let mut row = with_cache(|cache| cache.rows.iter().find(|row| row["id"] == id).cloned())?;

    let current = crate::launcher::resolved_command(id).and_then(|command| stamp(&command));
    if row["stamp"].as_str().is_some() && current.as_deref() != row["stamp"].as_str() {
        row["updateAvailable"] = json!(false);
        refresh_one(id);
    }
    Some(row)
}

fn refresh_one(id: &str) {
    static RUNNING: std::sync::Mutex<Vec<&'static str>> = std::sync::Mutex::new(Vec::new());
    let Some(id) = IDS.iter().copied().find(|known| *known == id) else {
        return;
    };
    {
        let mut running = RUNNING
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if running.contains(&id) {
            return;
        }
        running.push(id);
    }
    let _ = std::thread::Builder::new()
        .name("agent-version-refresh".into())
        .spawn(move || {
            if let Some(fresh) = row(id, false) {
                with_cache(|cache| {
                    if let Some(slot) = cache.rows.iter_mut().find(|row| row["id"] == id) {
                        *slot = fresh;
                        save(cache);
                    }
                });
            }
            RUNNING
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .retain(|running| *running != id);
        });
}

const COOLDOWN_MS: i64 = 60 * 60 * 1000;
const PERIOD: Duration = Duration::from_secs(6 * 60 * 60);
const PERIOD_JITTER: Duration = Duration::from_secs(45 * 60);
const START_DELAY: Duration = Duration::from_secs(20);
const START_JITTER: Duration = Duration::from_secs(70);

fn due(now: i64, checked_at: i64) -> bool {
    checked_at > now || now.saturating_sub(checked_at) >= COOLDOWN_MS
}

fn jitter(span: Duration) -> Duration {
    let millis = span.as_millis() as u64;
    if millis == 0 {
        return Duration::ZERO;
    }
    Duration::from_millis(rand::random::<u64>() % millis)
}

fn next_period() -> Duration {
    PERIOD - PERIOD_JITTER + jitter(PERIOD_JITTER * 2)
}

fn check_if_due() {
    let _flight = match FLIGHT.try_lock() {
        Ok(flight) => flight,
        Err(std::sync::TryLockError::WouldBlock) => return,

        Err(std::sync::TryLockError::Poisoned(poisoned)) => poisoned.into_inner(),
    };
    let checked_at = with_cache(|cache| cache.checked_at_ms);
    if due(crate::chat::now_ms(), checked_at) {
        let _ = check_now();
    }
}

/// An app connected, which usually means it just started. Check soon,
/// after a little jitter, if the last check is older than the cooldown.
/// Cheap and safe to call on every connection: at most one wait is pending.
pub(crate) fn nudge() {
    static PENDING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

    if cfg!(test) {
        return;
    }
    let fresh = with_cache(|cache| !due(crate::chat::now_ms(), cache.checked_at_ms));
    if fresh || PENDING.swap(true, std::sync::atomic::Ordering::AcqRel) {
        return;
    }
    let spawned = std::thread::Builder::new()
        .name("agent-update-nudge".into())
        .spawn(|| {
            std::thread::sleep(jitter(START_JITTER));
            check_if_due();
            PENDING.store(false, std::sync::atomic::Ordering::Release);
        });
    if spawned.is_err() {
        PENDING.store(false, std::sync::atomic::Ordering::Release);
    }
}

/// Check every installed agent when the host starts and about every six
/// hours after, so an agent that has fallen behind is marked where people
/// already look. The check sends each vendor only the request its own
/// installer makes. It never updates anything: that stays a button press.
pub(crate) fn start_schedule() {
    let _ = std::thread::Builder::new()
        .name("agent-update-check".into())
        .spawn(|| {
            std::thread::sleep(START_DELAY + jitter(START_JITTER));
            loop {
                let _ = std::panic::catch_unwind(check_if_due);
                std::thread::sleep(next_period());
            }
        });
}

fn quoted(path: &str) -> String {
    if cfg!(windows) {
        format!("& '{}'", path.replace('\'', "''"))
    } else {
        format!("'{}'", path.replace('\'', "'\\''"))
    }
}

/// Update one agent, on a button press. Refused while any chat is in a turn
/// on it, because the update replaces the binary that turn is running.
pub(crate) fn update(id: &str) -> Result<Value, String> {
    let plan = plan(id).ok_or_else(|| format!("tokenstat cannot update {id}"))?;
    if crate::chat::agent_busy(id) {
        return Err("A chat is using this agent right now. Update it when that turn ends.".into());
    }
    let command = crate::launcher::resolved_command(id)
        .ok_or_else(|| format!("{id} is not installed on this machine"))?;
    let before = version_of(&plan, &command);
    let process = match &plan.via {
        Via::Own(args) => Some(crate::launcher::installer_process(&format!(
            "{} {}",
            quoted(&command),
            args.join(" ")
        ))),
        Via::Package(package) => {
            let manager = if command.contains("/.bun/") {
                "bun add -g"
            } else {
                "npm install -g"
            };
            Some(crate::launcher::installer_process(&format!(
                "{manager} {package}@latest"
            )))
        }
        Via::Installer => None,
    };
    let mut result = crate::launcher::run_installer_command(id, true, process)?;
    let after = crate::launcher::resolved_command(id)
        .as_deref()
        .and_then(|command| version_of(&plan, command));
    result["before"] = json!(before);
    result["after"] = json!(after);
    if result["ok"] == true {
        with_cache(|cache| {
            if let Some(row) = cache.rows.iter_mut().find(|row| row["id"] == id) {
                let behind = row["latest"]
                    .as_str()
                    .zip(after.as_deref())
                    .is_some_and(|(latest, installed)| newer(latest, installed));
                row["version"] = json!(after);
                row["updateAvailable"] = json!(behind);
                row["stamp"] = json!(
                    crate::launcher::resolved_command(id).and_then(|command| stamp(&command))
                );
                save(cache);
            }
        });
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_check_is_due_after_the_cooldown_or_when_the_clock_moved_back() {
        let now = 10 * COOLDOWN_MS;
        assert!(!due(now, now - COOLDOWN_MS + 1));
        assert!(due(now, now - COOLDOWN_MS));
        assert!(due(now, 0));
        assert!(due(now, now + 1));

        assert!(due(now, i64::MIN));
        assert!(!just_checked(now, i64::MIN));
        assert!(just_checked(now, now - 1000));
        assert!(!just_checked(now, now - JUST_CHECKED_MS));
        assert!(!just_checked(now, now + 1));
    }

    #[test]
    fn the_period_stays_within_its_jitter() {
        for _ in 0..200 {
            let next = next_period();
            assert!(next >= PERIOD - PERIOD_JITTER && next < PERIOD + PERIOD_JITTER);
            assert!(jitter(START_JITTER) < START_JITTER);
        }
        assert_eq!(jitter(Duration::ZERO), Duration::ZERO);
    }

    #[test]
    fn a_failed_vendor_keeps_the_latest_the_previous_check_found() {
        let previous = vec![
            json!({"id": "codex", "latest": "0.9.0"}),
            json!({"id": "grok", "latest": "<script>"}),
        ];
        let fresh = vec![
            json!({"id": "codex", "version": "0.8.0", "error": "timed out"}),
            json!({"id": "grok", "version": "1.0.0", "error": "timed out"}),
            json!({"id": "claude_code", "version": "2.0.0", "latest": "2.0.0", "updateAvailable": false}),
        ];
        let rows = merged(&previous, fresh);
        assert_eq!(rows[0]["latest"], "0.9.0");
        assert_eq!(rows[0]["updateAvailable"], true);
        assert!(rows[1].get("latest").is_none());
        assert_eq!(rows[2]["latest"], "2.0.0");
    }

    #[test]
    fn only_version_shaped_text_is_trusted_from_the_cache() {
        assert!(plausible_version("2.1.318"));
        assert!(plausible_version("v0.9.0-beta+1"));
        assert!(!plausible_version(""));
        assert!(!plausible_version("1.0 now"));
        assert!(!plausible_version(&"9".repeat(65)));
    }

    #[test]
    fn versions_are_read_from_each_vendors_banner() {
        for (banner, version) in [
            ("2.1.318 (Claude Code)", "2.1.318"),
            ("codex-cli 0.167.2", "0.167.2"),
            ("opencode v2.0.32", "2.0.32"),
            ("grok 1.0.62 (1474f9cbdd91) [stable]", "1.0.62"),
            ("GitHub Copilot CLI 1.0.84-5.", "1.0.84-5"),
            ("Muse Code 1.4.15 (1.4.15-R8339.1)", "1.4.15"),
            ("omp/18.18.6", "18.18.6"),
            ("2026.11.11-043ef28", "2026.11.11-043ef28"),
            ("Hermes Agent v0.22.6 (2026.9.24) · stable", "0.22.6"),
            ("devin 3000.11.234 (92c83011d113)", "3000.11.234"),
        ] {
            assert_eq!(version_in(banner).as_deref(), Some(version), "{banner}");
        }
        assert_eq!(version_in("no version here 7"), None);
    }

    #[test]
    fn only_a_higher_number_is_newer() {
        assert!(newer("2.1.322", "2.1.318"));
        assert!(newer("1.0.77", "1.0.62"));
        assert!(newer("2.6.0", "0.40.1"));
        assert!(newer("0.23.1", "0.22.6"));
        assert!(!newer("0.167.2", "0.167.2"));
        assert!(!newer("1.0.75", "1.0.84-5"));
        assert!(!newer("2026.11.11-b912975", "2026.11.11-043ef28"));
        assert!(newer("2026.11.12-aaaaaaa", "2026.11.11-043ef28"));
    }

    #[test]
    fn every_agent_with_an_installer_or_updater_has_a_plan() {
        for id in [
            "claude_code",
            "codex",
            "opencode",
            "grok",
            "copilot",
            "cline",
            "openclaw",
            "muse",
            "omp",
            "pi",
            "antigravity",
            "cursor_agent",
            "hermes",
            "kilo",
            "kimi",
            "qwen",
            "devin",
        ] {
            assert!(plan(id).is_some(), "{id}");
        }
        assert!(plan("shell").is_none() && plan("cursor").is_none());
    }

    #[test]
    fn paths_are_quoted_for_the_runner_shell() {
        if !cfg!(windows) {
            assert_eq!(quoted("/a b/it's"), "'/a b/it'\\''s'");
        }
    }
}
