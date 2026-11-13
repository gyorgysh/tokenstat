// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Keeping agent CLIs current for people who only use them through chat.
//!
//! Chat runs an agent without its interactive screen, so the agent's own
//! "update available" notice never reaches anyone, and an agent that only
//! updates itself in that screen drifts behind. Each agent here has two
//! entries: where its vendor publishes the latest version, and how it is
//! updated. Both run only when a person presses a button.

use serde_json::{Value, json};
use std::time::Duration;
use tokenstat_sync::agent_versions::{self, LatestSource};

/// How an installed agent is brought up to date.
#[derive(Clone, Debug, PartialEq)]
enum Via {
    /// The agent's own update command, with these arguments.
    Own(&'static [&'static str]),
    /// A global package: reinstalled at `@latest` with whichever of npm or
    /// bun put it on this machine.
    Package(&'static str),
    /// The vendor's installer again, which always installs the latest.
    Installer,
}

struct Plan {
    latest: Option<LatestSource>,
    via: Via,
}

/// The table. Every latest-version address is the one the vendor's own
/// installer reads, so a version that address names is one the update can
/// actually install.
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
        // The installer fetches a launcher script that carries no version, so
        // there is nothing to compare. Update runs the installer again.
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

/// Antigravity publishes one manifest per platform, named the way its own
/// installer names them.
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

/// The first `1.2.3`-shaped token in a version banner, with any `-suffix`.
/// Banners differ ("codex-cli 0.167.2", "Hermes Agent v0.22.6 (2026.9.24)"),
/// and the first dotted number is the version in every one checked.
fn version_in(banner: &str) -> Option<String> {
    let bytes = banner.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        // A digit that starts a word, or follows a lone `v` ("v2.0.32").
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

/// The numeric parts before any `-suffix`.
fn numbers(version: &str) -> Vec<u64> {
    version
        .split('-')
        .next()
        .unwrap_or("")
        .split('.')
        .map(|part| part.parse().unwrap_or(0))
        .collect()
}

/// Whether `latest` is newer than `installed`, comparing only the dotted
/// numbers. A build suffix (Cursor's commit hash) is not an order, so two
/// builds of the same dated version count as equal.
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

/// Ask the installed command for its version. Bounded, because a CLI that
/// wants a terminal can wait on its input forever.
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

/// The npm package an agent was installed from, when its latest version
/// comes from the registry.
fn package_of(plan: &Plan) -> Option<&'static str> {
    match (&plan.via, &plan.latest) {
        (Via::Package(package), _) => Some(package),
        (_, Some(LatestSource::Npm(package))) => Some(package),
        _ => None,
    }
}

/// A globally installed package's version, from the `package.json` above
/// the real file its command links to. Some package CLIs wait for a
/// terminal on `--version`, and this needs no process at all.
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

/// The installed version, by the cheapest way that works for this agent.
fn version_of(plan: &Plan, command: &str) -> Option<String> {
    package_of(plan)
        .and_then(|package| package_version(command, package))
        .or_else(|| installed_version(command))
}

/// Every agent with an update plan, in the order lists show them.
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

/// Identifies the installed command file: its real path and modified time.
/// Any update, by tokenstat or not, changes one or the other.
fn stamp(command: &str) -> Option<String> {
    let real = std::fs::canonicalize(command).ok()?;
    let modified = std::fs::metadata(&real).ok()?.modified().ok()?;
    let seconds = modified
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    Some(format!("{}|{seconds}", real.display()))
}

/// One agent's row: its installed version and, when `check` is set, the
/// latest one its vendor publishes.
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
        // The last daily or manual check, compared with what is installed
        // now, so an update made outside tokenstat clears the mark.
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

/// Ask every vendor, keep what was learned, and answer with the merged rows.
/// The caller holds `FLIGHT`.
fn check_now() -> Vec<Value> {
    let fresh = rows(true);
    let merged = with_cache(|cache| merged(&cache.rows, fresh));
    remember(&merged);
    merged
}

/// Held for the whole of a check, so a scheduled one and a button press
/// never ask the vendors at the same time.
static FLIGHT: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// A check this recent already answers a button press.
const JUST_CHECKED_MS: i64 = 30 * 1000;

fn just_checked(now: i64, checked_at: i64) -> bool {
    // Saturating: `checked_at` comes from a file on disk, and a damaged one
    // must not overflow the subtraction.
    checked_at <= now && now.saturating_sub(checked_at) < JUST_CHECKED_MS
}

/// A row whose vendor could not be reached keeps the latest version the
/// previous check found, compared with what is installed now. One failed
/// request must not clear a mark that was right an hour ago.
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

/// What a stored version may look like. The cache is a file on disk, and a
/// damaged or edited one must not put arbitrary text in front of a person.
fn plausible_version(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '+' | '_'))
}

/// What the last check found, kept so the agent picker can mark an agent
/// that is behind without asking anyone. Rows are the same shape `list`
/// returns: installed version, latest version, whether one is newer.
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
    // Updated since the check, by tokenstat or anything else: the old answer
    // is about a binary that is gone. Clear the mark and read the new
    // version in the background, against the latest the check found.
    let current = crate::launcher::resolved_command(id).and_then(|command| stamp(&command));
    if row["stamp"].as_str().is_some() && current.as_deref() != row["stamp"].as_str() {
        row["updateAvailable"] = json!(false);
        refresh_one(id);
    }
    Some(row)
}

/// Re-read one agent's installed version and store it with the cached latest.
/// At most one refresh per agent at a time.
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

/// A check younger than this is fresh enough for anything but a button
/// press. It is what keeps an app opened ten times an hour, or several
/// phones connecting at once, from asking every vendor each time.
const COOLDOWN_MS: i64 = 60 * 60 * 1000;
/// While the host runs it checks again about this often, give or take
/// `PERIOD_JITTER`, so machines that started together drift apart.
const PERIOD: Duration = Duration::from_secs(6 * 60 * 60);
const PERIOD_JITTER: Duration = Duration::from_secs(45 * 60);
/// The first check waits this long after the host or an app starts, plus
/// up to `START_JITTER`, so it never competes with startup work.
const START_DELAY: Duration = Duration::from_secs(20);
const START_JITTER: Duration = Duration::from_secs(70);

/// Whether a check last made at `checked_at` should be made again. A time
/// in the future means the clock moved back, and the cache cannot be
/// trusted to say how old it is.
fn due(now: i64, checked_at: i64) -> bool {
    checked_at > now || now.saturating_sub(checked_at) >= COOLDOWN_MS
}

/// A random length up to `span`. Spread, not secrecy, so the thread RNG is fine.
fn jitter(span: Duration) -> Duration {
    let millis = span.as_millis() as u64;
    if millis == 0 {
        return Duration::ZERO;
    }
    Duration::from_millis(rand::random::<u64>() % millis)
}

/// `PERIOD` moved by up to `PERIOD_JITTER` either way.
fn next_period() -> Duration {
    PERIOD - PERIOD_JITTER + jitter(PERIOD_JITTER * 2)
}

/// Check now unless a check is running or one was made within the cooldown.
/// Never waits: a busy flight means somebody else is already asking.
fn check_if_due() {
    let _flight = match FLIGHT.try_lock() {
        Ok(flight) => flight,
        // Somebody else is already asking. Their check answers this one.
        Err(std::sync::TryLockError::WouldBlock) => return,
        // A panic during a check must not stop every later scheduled one.
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
    // Unit tests call `protocol` all the time. They must not reach vendors.
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
                // A panic in one check must not end the schedule.
                let _ = std::panic::catch_unwind(check_if_due);
                std::thread::sleep(next_period());
            }
        });
}

/// Quote a path for the shell the installer runner uses.
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
            // bun's global packages live under ~/.bun. Anything else came
            // from npm, which is also what every catalog entry installs with.
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
        // A damaged cache may hold any i64; none of it may overflow.
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
        // A stored value that is not a version is not shown.
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
