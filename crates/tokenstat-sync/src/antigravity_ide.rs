//! Antigravity IDE language-server sync.
//!
//! The IDE keeps per-turn usage inside a local language server. When that
//! process is running, this module discovers its loopback port and CSRF token
//! from the process table, calls Connect-RPC methods, and writes normalized
//! JSONL under the tokenstat data directory for [`tokenstat_core`] to parse.
//!
//! Soft-fails when the IDE is closed. Never invents events from brain
//! transcripts.

use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use serde_json::Value;
use tokenstat_core::limits::{LimitSeverity, ProviderLimits, UsageWindow};
use tokenstat_core::sources::antigravity_cache;

use crate::creds::{cache_is_fresh, cache_path};
use crate::{FETCH_TTL, Vendor};

const MAX_RPC_BODY_BYTES: usize = 32 * 1024 * 1024;
const SERVICE: &str = "exa.language_server_pb.LanguageServerService";

#[derive(Debug, Clone)]
struct Connection {
    pid: u32,
    port: u16,
    csrf_token: String,
    fingerprint: String,
}

#[derive(Debug, Clone)]
struct ProcessCandidate {
    pid: u32,
    declared_port: Option<u16>,
    csrf_token: String,
}

#[derive(Debug, Clone)]
struct TrajectorySummary {
    session_id: String,
    last_modified_ms: Option<i64>,
    step_count: Option<i32>,
    connection_fingerprint: String,
}

/// Result of attempting an IDE session sync.
#[derive(Debug, Default)]
pub struct IdeSyncReport {
    pub sessions_written: usize,
    pub connections: usize,
    pub from_cache: bool,
    pub message: String,
}

/// Read per-model quota windows from the running Antigravity IDE language server.
pub fn limits() -> ProviderLimits {
    let connections = match detect_connections() {
        Ok(connections) => connections,
        Err(error) => {
            return ProviderLimits::unavailable(
                "antigravity",
                format!("Antigravity discovery failed: {error}"),
            );
        }
    };
    if connections.is_empty() {
        return ProviderLimits::unavailable(
            "antigravity",
            "Antigravity is not running, so its model limits cannot be read.",
        );
    }

    let mut grouped: HashMap<(String, String), (f64, Option<i64>)> = HashMap::new();
    let mut plan = None;
    for connection in connections {
        let Ok(response) = rpc_request(&connection, "GetUserStatus", &serde_json::json!({})) else {
            continue;
        };
        let status = response.get("userStatus").unwrap_or(&response);
        plan = plan.or_else(|| {
            status
                .pointer("/planStatus/planInfo/planName")
                .and_then(Value::as_str)
                .map(str::to_string)
        });
        let Some(models) = status
            .pointer("/cascadeModelConfigData/clientModelConfigs")
            .and_then(Value::as_array)
        else {
            continue;
        };
        for model in models {
            let label = model
                .get("label")
                .and_then(Value::as_str)
                .or_else(|| model.pointer("/modelOrAlias/model").and_then(Value::as_str))
                .unwrap_or("model");
            let Some(quota) = model.get("quotaInfo") else {
                continue;
            };
            let Some(remaining) = quota.get("remainingFraction").and_then(Value::as_f64) else {
                continue;
            };
            if !remaining.is_finite() || !(0.0..=1.0).contains(&remaining) {
                continue;
            }
            let percent = (1.0 - remaining) * 100.0;
            let group = if label.to_ascii_lowercase().contains("gemini") {
                "Gemini models"
            } else {
                "Claude and GPT models"
            };
            let resets_at_ms = quota
                .get("resetTime")
                .and_then(Value::as_str)
                .and_then(|raw| raw.parse::<jiff::Timestamp>().ok())
                .map(|timestamp| timestamp.as_millisecond());
            let window = if resets_at_ms.is_some_and(|reset| reset - now_ms() > 10 * 60 * 60 * 1000)
            {
                "weekly"
            } else {
                "5-hour"
            };
            let entry = grouped
                .entry((group.to_string(), window.to_string()))
                .or_insert((0.0, resets_at_ms));
            if percent > entry.0 {
                *entry = (percent, resets_at_ms);
            }
        }
    }
    let mut windows: Vec<UsageWindow> = grouped
        .into_iter()
        .map(|((group, window), (percent, resets_at_ms))| UsageWindow {
            label: format!("{group} · {window}"),
            percent,
            resets_at_ms,
            severity: LimitSeverity::from_percent(percent),
        })
        .collect();
    windows.sort_by_key(|window| {
        (
            !window.label.starts_with("Gemini"),
            !window.label.ends_with("weekly"),
        )
    });
    if windows.is_empty() {
        return ProviderLimits::unavailable(
            "antigravity",
            "Antigravity reported no model quota windows.",
        );
    }
    ProviderLimits {
        source: "antigravity".to_string(),
        plan,
        windows,
        observed_at_ms: now_ms(),
        note: None,
    }
}

/// Discover a running Antigravity language server, pull generator metadata, and
/// write JSONL session caches. Respects the usual fetch TTL via a stamp file.
pub fn sync_sessions(force: bool) -> anyhow::Result<IdeSyncReport> {
    let stamp = cache_path(Vendor::Antigravity, "ide-sync.stamp")?;
    if !force && cache_is_fresh(&stamp, FETCH_TTL) {
        let sessions = count_session_files();
        return Ok(IdeSyncReport {
            sessions_written: sessions,
            connections: 0,
            from_cache: true,
            message: format!("IDE cache fresh ({sessions} sessions)"),
        });
    }

    let connections = detect_connections()?;
    if connections.is_empty() {
        return Ok(IdeSyncReport {
            message: "Antigravity IDE not running (open the app to sync IDE sessions)".into(),
            ..IdeSyncReport::default()
        });
    }

    let summaries = list_trajectory_summaries(&connections)?;
    if summaries.is_empty() {
        // Do not stamp: an empty miss must not block a later real session
        // inside the TTL window.
        return Ok(IdeSyncReport {
            connections: connections.len(),
            message: format!(
                "IDE language server found ({}) but no trajectories returned",
                connections.len()
            ),
            ..IdeSyncReport::default()
        });
    }

    let root = session_cache_dir()?;
    fs::create_dir_all(&root)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&root, fs::Permissions::from_mode(0o700));
    }

    let mut written = 0usize;
    for summary in &summaries {
        if let Some(artifact) = fetch_session_artifact(summary, &connections)? {
            let path = root.join(format!("{}.jsonl", sanitize_filename(&summary.session_id)));
            write_secret_file(&path, &artifact)?;
            written += 1;
        }
    }

    let _ = touch_stamp(&stamp);
    Ok(IdeSyncReport {
        sessions_written: written,
        connections: connections.len(),
        from_cache: false,
        message: format!(
            "IDE sync: {written} sessions from {} language server(s)",
            connections.len()
        ),
    })
}

fn session_cache_dir() -> anyhow::Result<PathBuf> {
    antigravity_cache::cache_dir().ok_or_else(|| anyhow::anyhow!("no tokenstat data directory"))
}

fn count_session_files() -> usize {
    let Some(root) = antigravity_cache::cache_dir() else {
        return 0;
    };
    antigravity_cache::shards(&root).len()
}

fn touch_stamp(path: &std::path::Path) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, b"ok")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

fn write_secret_file(path: &std::path::Path, contents: &str) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, contents)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

fn sanitize_filename(id: &str) -> String {
    id.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn detect_connections() -> anyhow::Result<Vec<Connection>> {
    let candidates = detect_process_candidates()?;
    let mut connections = Vec::new();

    for candidate in candidates {
        let ports = candidate_probe_ports(&candidate, find_listening_ports(candidate.pid)?);
        for port in ports {
            if probe_heartbeat(port, &candidate.csrf_token) {
                connections.push(Connection {
                    pid: candidate.pid,
                    port,
                    csrf_token: candidate.csrf_token.clone(),
                    fingerprint: format!("pid:{}:port:{}", candidate.pid, port),
                });
                break;
            }
        }
    }

    connections.sort_by(|a, b| b.pid.cmp(&a.pid).then_with(|| a.port.cmp(&b.port)));
    connections.dedup_by(|a, b| a.pid == b.pid && a.port == b.port);
    Ok(connections)
}

fn candidate_probe_ports(candidate: &ProcessCandidate, mut ports: Vec<u16>) -> Vec<u16> {
    if let Some(declared) = candidate.declared_port {
        if !ports.contains(&declared) {
            ports.push(declared);
        }
    }
    ports.sort_unstable();
    ports.dedup();
    ports
}

fn detect_process_candidates() -> anyhow::Result<Vec<ProcessCandidate>> {
    #[cfg(target_os = "windows")]
    {
        return detect_windows_process_candidates();
    }
    #[cfg(not(target_os = "windows"))]
    {
        detect_unix_process_candidates()
    }
}

#[cfg(not(target_os = "windows"))]
fn detect_unix_process_candidates() -> anyhow::Result<Vec<ProcessCandidate>> {
    let output = run_command("ps", &["-ww", "-eo", "pid,ppid,args"])?;
    let mut candidates = Vec::new();

    for line in output.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let parts: Vec<&str> = trimmed.split_whitespace().collect();
        if parts.len() < 3 {
            continue;
        }
        let Ok(pid) = parts[0].parse::<u32>() else {
            continue;
        };
        let command = parts[2..].join(" ");
        if !is_antigravity_process(&command) {
            continue;
        }
        let Some(csrf_token) = extract_csrf_token(&command) else {
            continue;
        };
        candidates.push(ProcessCandidate {
            pid,
            declared_port: extract_declared_port(&command),
            csrf_token,
        });
    }

    candidates.sort_by_key(|b| std::cmp::Reverse(b.pid));
    candidates.dedup_by(|a, b| a.pid == b.pid);
    Ok(candidates)
}

#[cfg(target_os = "windows")]
fn detect_windows_process_candidates() -> anyhow::Result<Vec<ProcessCandidate>> {
    let script = "Get-CimInstance Win32_Process | Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress";
    let output = Command::new("powershell")
        .args(["-NoProfile", "-Command", script])
        .output()?;
    if !output.status.success() {
        anyhow::bail!("Windows process discovery failed");
    }
    let text = String::from_utf8_lossy(&output.stdout);
    parse_windows_process_json(&text)
}

#[cfg(target_os = "windows")]
fn parse_windows_process_json(text: &str) -> anyhow::Result<Vec<ProcessCandidate>> {
    let value: Value = serde_json::from_str(text.trim()).unwrap_or(Value::Null);
    let items: Vec<&Value> = match &value {
        Value::Array(v) => v.iter().collect(),
        Value::Object(_) => vec![&value],
        _ => Vec::new(),
    };
    let mut candidates = Vec::new();
    for item in items {
        let Some(pid) = item.get("ProcessId").and_then(Value::as_u64) else {
            continue;
        };
        let command = item
            .get("CommandLine")
            .and_then(Value::as_str)
            .unwrap_or("");
        if !is_antigravity_process(command) {
            continue;
        }
        let Some(csrf_token) = extract_csrf_token(command) else {
            continue;
        };
        candidates.push(ProcessCandidate {
            pid: pid as u32,
            declared_port: extract_declared_port(command),
            csrf_token,
        });
    }
    Ok(candidates)
}

fn is_antigravity_process(command: &str) -> bool {
    let lower = command.to_lowercase();
    (lower.contains("language_server")
        && (lower.contains("antigravity") || lower.contains("--app_data_dir antigravity")))
        || lower.contains("/antigravity/")
        || lower.contains("\\antigravity\\")
}

fn extract_csrf_token(command: &str) -> Option<String> {
    let token = extract_flag_value(command, "--csrf_token")?;
    if token.len() >= 32 && token.chars().all(|ch| ch.is_ascii_hexdigit() || ch == '-') {
        Some(token)
    } else {
        None
    }
}

fn extract_declared_port(command: &str) -> Option<u16> {
    extract_flag_value(command, "--extension_server_port")?
        .parse::<u16>()
        .ok()
}

fn extract_flag_value(command: &str, flag: &str) -> Option<String> {
    let compact = format!("{flag}=");
    if let Some(idx) = command.find(&compact) {
        let rest = &command[idx + compact.len()..];
        return rest
            .split_whitespace()
            .next()
            .map(|value| value.to_string());
    }
    let idx = command.find(flag)?;
    let rest = &command[idx + flag.len()..];
    rest.split_whitespace()
        .find(|value| !value.is_empty())
        .map(|value| value.trim().to_string())
}

fn find_listening_ports(pid: u32) -> anyhow::Result<Vec<u16>> {
    #[cfg(target_os = "windows")]
    {
        return find_windows_listening_ports(pid);
    }
    #[cfg(not(target_os = "windows"))]
    {
        let pid_str = pid.to_string();
        let mut ports = run_port_query(&["-Pan", "-p", &pid_str, "-iTCP", "-sTCP:LISTEN"])?;
        if ports.is_empty() {
            ports = run_port_query(&["-Pan", "-p", &pid_str, "-i"])?;
        }
        ports.sort_unstable();
        ports.dedup();
        Ok(ports)
    }
}

#[cfg(not(target_os = "windows"))]
fn run_port_query(args: &[&str]) -> anyhow::Result<Vec<u16>> {
    match run_command("lsof", args) {
        Ok(output) => Ok(parse_ports(&output)),
        Err(err) if is_not_found(&err) => Ok(Vec::new()),
        Err(err) => Err(err),
    }
}

#[cfg(target_os = "windows")]
fn find_windows_listening_ports(pid: u32) -> anyhow::Result<Vec<u16>> {
    let output = run_command("netstat", &["-ano", "-p", "TCP"])?;
    Ok(parse_windows_netstat_ports(&output, pid))
}

#[cfg(target_os = "windows")]
fn parse_windows_netstat_ports(output: &str, pid: u32) -> Vec<u16> {
    let mut ports = Vec::new();
    let pid_text = pid.to_string();
    for line in output.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 5 || !parts[0].eq_ignore_ascii_case("TCP") {
            continue;
        }
        if parts[3] != "LISTENING" || parts[4] != pid_text {
            continue;
        }
        if let Some(port) = parts[1].rsplit(':').next().and_then(|p| p.parse().ok()) {
            ports.push(port);
        }
    }
    ports
}

#[cfg(not(target_os = "windows"))]
fn parse_ports(output: &str) -> Vec<u16> {
    output.lines().filter_map(parse_port_from_line).collect()
}

#[cfg(not(target_os = "windows"))]
fn parse_port_from_line(line: &str) -> Option<u16> {
    for token in line.split_whitespace() {
        if let Some(port) = token
            .strip_prefix("127.0.0.1:")
            .or_else(|| token.strip_prefix("localhost:"))
            .or_else(|| token.strip_prefix("*:"))
            .or_else(|| token.strip_prefix("::1:"))
        {
            let cleaned = port.trim_end_matches("(LISTEN)").trim_end_matches(',');
            if let Ok(parsed) = cleaned.parse::<u16>() {
                return Some(parsed);
            }
        }
    }
    if let Some(idx) = line.rfind(':') {
        let rest = line[idx + 1..].trim();
        let digits: String = rest.chars().take_while(|ch| ch.is_ascii_digit()).collect();
        if !digits.is_empty() {
            return digits.parse().ok();
        }
    }
    None
}

fn probe_heartbeat(port: u16, csrf_token: &str) -> bool {
    let connection = Connection {
        pid: 0,
        port,
        csrf_token: csrf_token.to_string(),
        fingerprint: format!("port:{port}"),
    };
    let body = serde_json::json!({ "uuid": "00000000-0000-0000-0000-000000000000" });
    rpc_request(&connection, "Heartbeat", &body).is_ok()
}

fn list_trajectory_summaries(connections: &[Connection]) -> anyhow::Result<Vec<TrajectorySummary>> {
    let mut merged: HashMap<String, TrajectorySummary> = HashMap::new();
    for connection in connections {
        let response = match rpc_request(
            connection,
            "GetAllCascadeTrajectories",
            &serde_json::json!({}),
        ) {
            Ok(response) => response,
            Err(_) => continue,
        };
        for summary in normalize_trajectory_summaries(&response, &connection.fingerprint) {
            match merged.get(&summary.session_id) {
                Some(existing) if !is_better_summary(&summary, existing) => {}
                _ => {
                    merged.insert(summary.session_id.clone(), summary);
                }
            }
        }
    }
    let mut values: Vec<TrajectorySummary> = merged.into_values().collect();
    values.sort_by(|a, b| {
        b.last_modified_ms
            .unwrap_or_default()
            .cmp(&a.last_modified_ms.unwrap_or_default())
            .then_with(|| a.session_id.cmp(&b.session_id))
    });
    Ok(values)
}

fn fetch_session_artifact(
    summary: &TrajectorySummary,
    connections: &[Connection],
) -> anyhow::Result<Option<String>> {
    let preferred = connections
        .iter()
        .find(|c| c.fingerprint == summary.connection_fingerprint);
    let mut ordered: Vec<&Connection> = Vec::new();
    if let Some(c) = preferred {
        ordered.push(c);
    }
    ordered.extend(
        connections
            .iter()
            .filter(|c| c.fingerprint != summary.connection_fingerprint),
    );

    let fallback_ms = summary
        .last_modified_ms
        .filter(|&ms| ms > 0)
        .unwrap_or_else(now_ms);

    for connection in ordered {
        let response = match rpc_request(
            connection,
            "GetCascadeTrajectoryGeneratorMetadata",
            &serde_json::json!({ "cascadeId": summary.session_id }),
        ) {
            Ok(value) => value,
            Err(_) => continue,
        };
        let metadata = response
            .get("generatorMetadata")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if metadata.is_empty() {
            continue;
        }
        let lines = normalize_session_metadata(&summary.session_id, &metadata, fallback_ms)?;
        if lines.is_empty() {
            continue;
        }
        return Ok(Some(format!("{}\n", lines.join("\n"))));
    }
    Ok(None)
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn normalize_session_metadata(
    session_id: &str,
    metadata: &[Value],
    fallback_ms: i64,
) -> anyhow::Result<Vec<String>> {
    let mut lines = Vec::new();
    for meta in metadata {
        let chat_model = meta.get("chatModel").unwrap_or(meta);
        let model_id = resolve_model_id(chat_model);
        let created_at = first_timestamp(&[
            chat_model
                .get("chatStartMetadata")
                .and_then(|value| value.get("createdAt")),
            chat_model.get("createdAt"),
            chat_model.get("timestamp"),
            meta.get("createdAt"),
            meta.get("timestamp"),
        ])
        .or(Some(fallback_ms).filter(|&ms| ms > 0));

        lines.push(serde_json::to_string(&serde_json::json!({
            "type": "session_meta",
            "sessionId": session_id,
            "modelId": model_id,
            "timestamp": created_at,
        }))?);

        let retries = chat_model
            .get("retryInfos")
            .or_else(|| chat_model.get("retries"))
            .or_else(|| meta.get("retryInfos"))
            .and_then(Value::as_array);

        if let Some(retry_infos) = retries {
            for retry in retry_infos {
                let usage = retry.get("usage").unwrap_or(retry);
                let input = to_safe_i64(usage.get("inputTokens").or_else(|| usage.get("input")));
                let output = to_safe_i64(usage.get("outputTokens").or_else(|| usage.get("output")));
                let cache_read = to_safe_i64(
                    usage
                        .get("cacheReadTokens")
                        .or_else(|| usage.get("cacheRead")),
                );
                let reasoning = to_safe_i64(
                    usage
                        .get("thinkingOutputTokens")
                        .or_else(|| usage.get("reasoningTokens"))
                        .or_else(|| usage.get("reasoning")),
                );
                let timestamp = first_timestamp(&[
                    usage.get("createdAt"),
                    usage.get("timestamp"),
                    usage.get("completedAt"),
                    usage.get("startTime"),
                    retry.get("createdAt"),
                    retry.get("timestamp"),
                ])
                .or(created_at)
                .unwrap_or(fallback_ms);

                if input == 0 && output == 0 && cache_read == 0 && reasoning == 0 {
                    continue;
                }

                lines.push(serde_json::to_string(&serde_json::json!({
                    "type": "usage",
                    "sessionId": session_id,
                    "modelId": model_id,
                    "timestamp": timestamp,
                    "input": input,
                    "output": output,
                    "cacheRead": cache_read,
                    "cacheWrite": 0,
                    "reasoning": reasoning,
                    "responseId": usage
                        .get("responseId")
                        .or_else(|| usage.get("id"))
                        .and_then(Value::as_str),
                }))?);
            }
        }
    }
    Ok(lines)
}

fn first_timestamp(values: &[Option<&Value>]) -> Option<i64> {
    values
        .iter()
        .find_map(|value| value.and_then(parse_timestamp_value))
}

fn resolve_model_id(chat_model: &Value) -> String {
    chat_model
        .get("responseModel")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            chat_model
                .get("model")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
        })
        .unwrap_or("unknown")
        .to_string()
}

fn normalize_trajectory_summaries(response: &Value, fingerprint: &str) -> Vec<TrajectorySummary> {
    let items: Vec<Value> = if let Some(array) = response
        .get("trajectorySummaries")
        .and_then(Value::as_array)
    {
        array.to_vec()
    } else if let Some(object) = response
        .get("trajectorySummaries")
        .and_then(Value::as_object)
    {
        object
            .iter()
            .map(|(key, value)| {
                let mut entry = value.clone();
                if entry.get("cascadeId").is_none() {
                    entry["cascadeId"] = Value::String(key.clone());
                }
                entry
            })
            .collect()
    } else if let Some(array) = response
        .get("cascadeTrajectories")
        .and_then(Value::as_array)
    {
        array.to_vec()
    } else {
        Vec::new()
    };

    items
        .into_iter()
        .filter_map(|item| normalize_trajectory_summary(&item, fingerprint))
        .collect()
}

fn normalize_trajectory_summary(item: &Value, fingerprint: &str) -> Option<TrajectorySummary> {
    let session_id = first_string(&[
        item.get("cascadeId"),
        item.get("trajectoryId"),
        item.get("id"),
        item.get("sessionId"),
    ])?;
    Some(TrajectorySummary {
        session_id,
        last_modified_ms: parse_timestamp(&[
            item.get("lastModifiedTime"),
            item.get("lastModified"),
            item.get("updatedAt"),
            item.get("modifiedAt"),
        ]),
        step_count: first_i32(&[
            item.get("stepCount"),
            item.get("numSteps"),
            item.get("totalSteps"),
        ]),
        connection_fingerprint: fingerprint.to_string(),
    })
}

fn is_better_summary(next: &TrajectorySummary, current: &TrajectorySummary) -> bool {
    let next_modified = next.last_modified_ms.unwrap_or_default();
    let current_modified = current.last_modified_ms.unwrap_or_default();
    if next_modified != current_modified {
        return next_modified > current_modified;
    }
    next.step_count.unwrap_or_default() > current.step_count.unwrap_or_default()
}

fn first_string(values: &[Option<&Value>]) -> Option<String> {
    values.iter().find_map(|value| {
        value
            .and_then(|inner| inner.as_str())
            .filter(|text| !text.trim().is_empty())
            .map(|text| text.to_string())
    })
}

fn first_i32(values: &[Option<&Value>]) -> Option<i32> {
    values.iter().find_map(|value| {
        value.and_then(|inner| {
            inner
                .as_i64()
                .and_then(|n| i32::try_from(n).ok())
                .or_else(|| inner.as_u64().and_then(|n| i32::try_from(n).ok()))
                .or_else(|| inner.as_str().and_then(|t| t.parse().ok()))
        })
    })
}

fn parse_timestamp(values: &[Option<&Value>]) -> Option<i64> {
    values
        .iter()
        .find_map(|value| value.and_then(parse_timestamp_value))
}

fn parse_timestamp_value(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_u64().and_then(|n| i64::try_from(n).ok()))
        .or_else(|| {
            value.as_f64().and_then(|n| {
                if n.is_finite() && n > 0.0 {
                    Some(n as i64)
                } else {
                    None
                }
            })
        })
        .or_else(|| {
            value.as_str().and_then(|text| {
                text.parse::<i64>().ok().or_else(|| {
                    text.parse::<jiff::Timestamp>()
                        .ok()
                        .map(|ts| ts.as_millisecond())
                })
            })
        })
        .or_else(|| {
            // Protobuf JSON Timestamp: { "seconds": "...", "nanos": ... }
            let seconds = value.get("seconds").and_then(|s| {
                s.as_i64()
                    .or_else(|| s.as_u64().and_then(|n| i64::try_from(n).ok()))
                    .or_else(|| s.as_str().and_then(|t| t.parse().ok()))
            })?;
            let nanos = value
                .get("nanos")
                .and_then(|n| {
                    n.as_i64()
                        .or_else(|| n.as_u64().and_then(|x| i64::try_from(x).ok()))
                })
                .unwrap_or(0);
            seconds.checked_mul(1000)?.checked_add(nanos / 1_000_000)
        })
        .map(|ms| {
            // Heuristic: values that look like seconds rather than ms.
            if (1_000_000_000..100_000_000_000).contains(&ms) {
                ms.saturating_mul(1000)
            } else {
                ms
            }
        })
        .filter(|timestamp| *timestamp > 0)
}

fn to_safe_i64(value: Option<&Value>) -> i64 {
    value
        .and_then(|inner| {
            inner
                .as_i64()
                .or_else(|| inner.as_u64().and_then(|n| i64::try_from(n).ok()))
                .or_else(|| inner.as_str().and_then(|t| t.parse().ok()))
        })
        .unwrap_or(0)
        .max(0)
}

fn rpc_request(connection: &Connection, method: &str, body: &Value) -> anyhow::Result<Value> {
    match rpc_request_plain_http(connection, method, body) {
        Ok(value) => Ok(value),
        Err(http_err) => https_rpc_request(connection, method, body).map_err(|https_err| {
            anyhow::anyhow!("HTTP RPC failed ({http_err:#}); HTTPS fallback failed: {https_err:#}")
        }),
    }
}

fn https_rpc_request(connection: &Connection, method: &str, body: &Value) -> anyhow::Result<Value> {
    let url = format!("https://127.0.0.1:{}/{SERVICE}/{method}", connection.port);
    let client = reqwest::blocking::Client::builder()
        .danger_accept_invalid_certs(true)
        .no_proxy()
        .timeout(Duration::from_secs(10))
        .connect_timeout(Duration::from_secs(5))
        .build()?;
    let response = client
        .post(url)
        .header("Content-Type", "application/json")
        .header("Connect-Protocol-Version", "1")
        .header("X-Codeium-Csrf-Token", &connection.csrf_token)
        .body(serde_json::to_vec(body)?)
        .send()?;
    let status = response.status();
    let response_body = response.text()?;
    if response_body.len() > MAX_RPC_BODY_BYTES {
        anyhow::bail!("Antigravity RPC body exceeds {MAX_RPC_BODY_BYTES} cap");
    }
    if !status.is_success() {
        anyhow::bail!(
            "Antigravity HTTPS RPC {method} failed with status {status}: {response_body}"
        );
    }
    Ok(serde_json::from_str(&response_body)?)
}

fn rpc_request_plain_http(
    connection: &Connection,
    method: &str,
    body: &Value,
) -> anyhow::Result<Value> {
    let mut stream = TcpStream::connect(("127.0.0.1", connection.port))?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;

    let body_text = serde_json::to_string(body)?;
    let request = format!(
        "POST /{SERVICE}/{method} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnect-Protocol-Version: 1\r\nX-Codeium-Csrf-Token: {}\r\nConnection: close\r\n\r\n{body_text}",
        connection.port,
        body_text.len(),
        connection.csrf_token,
    );
    stream.write_all(request.as_bytes())?;

    let mut reader = BufReader::new(stream);
    let mut status_line = String::new();
    reader.read_line(&mut status_line)?;
    let status_code = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| anyhow::anyhow!("Malformed HTTP response from Antigravity RPC"))?;

    let mut content_length: Option<usize> = None;
    let mut chunked = false;
    loop {
        let mut header = String::new();
        reader.read_line(&mut header)?;
        let trimmed = header.trim();
        if trimmed.is_empty() {
            break;
        }
        let lower = trimmed.to_ascii_lowercase();
        if let Some(value) = lower.strip_prefix("content-length:") {
            content_length = value.trim().parse().ok();
        }
        if lower.contains("transfer-encoding") && lower.contains("chunked") {
            chunked = true;
        }
    }

    let response_body = if chunked {
        read_chunked_body(&mut reader)?
    } else if let Some(length) = content_length {
        if length > MAX_RPC_BODY_BYTES {
            anyhow::bail!("Antigravity RPC body of {length} bytes exceeds cap");
        }
        let mut bytes = vec![0_u8; length];
        reader.read_exact(&mut bytes)?;
        String::from_utf8(bytes)?
    } else {
        let mut text = String::new();
        reader
            .by_ref()
            .take(MAX_RPC_BODY_BYTES as u64 + 1)
            .read_to_string(&mut text)?;
        if text.len() > MAX_RPC_BODY_BYTES {
            anyhow::bail!("Antigravity RPC body exceeds cap");
        }
        text
    };

    if status_code != 200 {
        anyhow::bail!("Antigravity RPC {method} failed with status {status_code}: {response_body}");
    }
    Ok(serde_json::from_str(&response_body)?)
}

fn read_chunked_body(reader: &mut BufReader<TcpStream>) -> anyhow::Result<String> {
    let mut body = Vec::new();
    loop {
        let mut size_line = String::new();
        reader.read_line(&mut size_line)?;
        let trimmed = size_line.trim();
        let chunk_size = usize::from_str_radix(
            trimmed
                .split(';')
                .next()
                .map(str::trim)
                .filter(|v| !v.is_empty())
                .ok_or_else(|| anyhow::anyhow!("Missing chunk size"))?,
            16,
        )?;
        if chunk_size == 0 {
            break;
        }
        if chunk_size > MAX_RPC_BODY_BYTES
            || body.len().saturating_add(chunk_size) > MAX_RPC_BODY_BYTES
        {
            anyhow::bail!("Antigravity RPC body exceeds cap");
        }
        let mut chunk = vec![0_u8; chunk_size];
        reader.read_exact(&mut chunk)?;
        body.extend_from_slice(&chunk);
        let mut crlf = [0_u8; 2];
        reader.read_exact(&mut crlf)?;
    }
    Ok(String::from_utf8(body)?)
}

fn run_command(program: &str, args: &[&str]) -> anyhow::Result<String> {
    let output = Command::new(program).args(args).output()?;
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(not(target_os = "windows"))]
fn is_not_found(err: &anyhow::Error) -> bool {
    err.chain().any(|cause| {
        cause
            .downcast_ref::<std::io::Error>()
            .is_some_and(|io| io.kind() == std::io::ErrorKind::NotFound)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_antigravity_process_matches_language_server() {
        assert!(is_antigravity_process(
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token abc --app_data_dir antigravity"
        ));
        assert!(!is_antigravity_process("language_server --other_app"));
        assert!(!is_antigravity_process("notepad.exe"));
    }

    #[test]
    fn extract_csrf_and_port() {
        let cmd = "language_server --extension_server_port 49321 --csrf_token abcdef0123456789abcdef0123456789 --app_data_dir antigravity";
        assert_eq!(
            extract_csrf_token(cmd).as_deref(),
            Some("abcdef0123456789abcdef0123456789")
        );
        assert_eq!(extract_declared_port(cmd), Some(49321));
    }

    #[test]
    fn normalize_usage_metadata() {
        let meta = serde_json::json!([{
            "chatModel": {
                "responseModel": "gemini-3-flash",
                "chatStartMetadata": { "createdAt": { "seconds": "1711200000", "nanos": 0 } },
                "retryInfos": [{
                    "usage": {
                        "inputTokens": 12,
                        "outputTokens": 4,
                        "cacheReadTokens": 2,
                        "thinkingOutputTokens": 1,
                        "responseId": "resp-1",
                        "createdAt": { "seconds": "1711200001", "nanos": 0 }
                    }
                }]
            }
        }]);
        let lines = normalize_session_metadata("abc", meta.as_array().unwrap(), 0).unwrap();
        assert_eq!(lines.len(), 2);
        assert!(lines[0].contains("session_meta"));
        assert!(lines[1].contains("\"input\":12"));
        assert!(lines[1].contains("resp-1"));
        assert!(lines[1].contains("1711200001000"));
    }

    #[test]
    fn normalize_falls_back_when_timestamps_missing() {
        let meta = serde_json::json!([{
            "chatModel": {
                "responseModel": "gemini-3-flash",
                "retryInfos": [{
                    "usage": {
                        "inputTokens": 12,
                        "outputTokens": 4,
                        "cacheReadTokens": 0,
                        "thinkingOutputTokens": 0,
                        "responseId": "resp-2"
                    }
                }]
            }
        }]);
        let lines =
            normalize_session_metadata("abc", meta.as_array().unwrap(), 1_711_200_000_000).unwrap();
        assert!(lines[1].contains("1711200000000"));
    }

    #[cfg(not(target_os = "windows"))]
    #[test]
    fn parse_port_from_lsof_line() {
        assert_eq!(
            parse_port_from_line(
                "language_ 4363 gyorgy 7u IPv4 0x1 0t0 TCP 127.0.0.1:61542 (LISTEN)"
            ),
            Some(61542)
        );
    }
}
