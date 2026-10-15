// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Push status for visible workspace terminals, independent of an attached
//! frontend. The existing activity sampler supplies the single polling thread.

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

pub(crate) const COMPLETION_LIFE: Duration = Duration::from_secs(3600);

struct CompletedTerminal {
    workspace_id: String,
    phase: &'static str,
    finished_at: Instant,
}

fn completed_terminals() -> &'static Mutex<HashMap<String, CompletedTerminal>> {
    static COMPLETED: OnceLock<Mutex<HashMap<String, CompletedTerminal>>> = OnceLock::new();
    COMPLETED.get_or_init(Default::default)
}

fn remember_completed_terminal(info: &tokenstat_pty::SessionInfo) {
    let mut completed = completed_terminals()
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    retain_completed_terminal(&mut completed, info, Instant::now());
}

fn retain_completed_terminal(
    completed: &mut HashMap<String, CompletedTerminal>,
    info: &tokenstat_pty::SessionInfo,
    now: Instant,
) {
    let phase = if info.alive {
        match info.program_status.as_ref().map(|status| status.state) {
            Some(tokenstat_pty::program_status::State::Done) => "done",
            Some(tokenstat_pty::program_status::State::Error) => "failed",
            _ => return,
        }
    } else {
        match info.exit_code {
            Some(0) => "done",
            Some(_) => "failed",
            None => return,
        }
    };
    if info.hidden || info.workspace_id.as_ref().is_none_or(|id| id.is_empty()) {
        return;
    }
    completed.retain(|_, work| now.saturating_duration_since(work.finished_at) < COMPLETION_LIFE);
    completed
        .entry(info.id.clone())
        .or_insert_with(|| CompletedTerminal {
            workspace_id: info.workspace_id.clone().unwrap_or_default(),
            phase,
            finished_at: now,
        });
    if completed.len() > 200
        && let Some(oldest) = completed
            .iter()
            .min_by_key(|(_, work)| work.finished_at)
            .map(|(id, _)| id.clone())
    {
        completed.remove(&oldest);
    }
}

struct Terminal {
    phase: &'static str,
    sent_at: Instant,
}

fn terminals() -> &'static Mutex<HashMap<String, Terminal>> {
    static TERMINALS: OnceLock<Mutex<HashMap<String, Terminal>>> = OnceLock::new();
    TERMINALS.get_or_init(Default::default)
}

pub(crate) fn start_terminal(info: &tokenstat_pty::SessionInfo) {
    start_terminal_with(info, tokenstat_sync::push::begin_terminal_activity);
}

fn start_terminal_with(info: &tokenstat_pty::SessionInfo, begin: impl FnOnce(&str) -> bool) {
    if info.hidden {
        return;
    }
    // Local results belong in a later foreground overview even when no
    // account was available at launch. Background pushes keep their original
    // binding and never acquire credentials from a later sign-in.
    begin(&info.id);
    let mut terminals = terminals()
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    terminals.insert(
        info.id.clone(),
        Terminal {
            phase: "working",
            sent_at: Instant::now(),
        },
    );
    tokenstat_sync::push::terminal_activity_in_background(&info.id, "working");
    drop(terminals);
    crate::activity::start();
}

fn terminal_phase(alive: bool, exit_code: Option<i32>, waiting: bool) -> Option<&'static str> {
    if !alive {
        // EOF can precede the child's exit status. Wait for the reap rather
        // than reporting success for a process that subsequently fails.
        exit_code.map(|code| if code == 0 { "done" } else { "failed" })
    } else if waiting {
        Some("waiting")
    } else {
        Some("working")
    }
}

pub(crate) fn poll_terminals() {
    let ids: Vec<_> = terminals()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .keys()
        .cloned()
        .collect();
    for id in ids {
        let info = tokenstat_pty::manager().info(&id).ok();
        let phase = info.as_ref().map_or(Some("stopped"), |info| {
            // A Live Activity tracks the PTY lifetime, not individual turns:
            // sending done here would retire its account binding while Claude
            // is still accepting the next prompt. Between turns it is waiting;
            // pty.info/list carry the full done/error state to the app.
            let waiting = info.program_status.as_ref().map_or_else(
                || {
                    info.pid
                        .and_then(crate::activity::reading)
                        .is_some_and(|reading| {
                            reading.attention.is_some()
                                || reading.activity == crate::activity::Activity::Idle
                        })
                },
                |status| status.state != tokenstat_pty::program_status::State::Working,
            );
            terminal_phase(info.alive, info.exit_code, waiting)
        });
        let Some(phase) = phase else { continue };
        let mut terminals = terminals()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let Some(terminal) = terminals.get_mut(&id) else {
            continue;
        };
        if terminal.phase != phase || terminal.sent_at.elapsed() >= Duration::from_secs(60) {
            terminal.phase = phase;
            terminal.sent_at = Instant::now();
            tokenstat_sync::push::terminal_activity_in_background(&id, phase);
        }
        if matches!(phase, "done" | "failed" | "stopped") {
            if let Some(info) = info.as_ref() {
                remember_completed_terminal(info);
            }
            terminals.remove(&id);
        }
    }
    // Capture terminal endings before publishing the combined snapshot.
    poll_overview();
}

struct Overview {
    summary: tokenstat_sync::push::WorkOverview,
    sent_at: Instant,
    expires_at: Instant,
}

fn overview_monitor() -> &'static Mutex<Option<Overview>> {
    static MONITOR: OnceLock<Mutex<Option<Overview>>> = OnceLock::new();
    MONITOR.get_or_init(Default::default)
}

fn priority(phase: &str) -> u8 {
    match phase {
        "waiting" => 0,
        "working" => 1,
        "failed" => 2,
        "done" => 3,
        _ => 4,
    }
}

fn session_phase(info: &tokenstat_pty::SessionInfo) -> &'static str {
    activity_phase(
        info.program_status.as_ref().map(|status| status.state),
        info.pid.and_then(crate::activity::reading),
    )
}

fn activity_phase(
    status: Option<tokenstat_pty::program_status::State>,
    reading: Option<crate::activity::Reading>,
) -> &'static str {
    use tokenstat_pty::program_status::State;
    if let Some(status) = status {
        return match status {
            State::Blocked => "waiting",
            State::Working => "working",
            State::Idle => "idle",
            State::Done => "done",
            State::Error => "failed",
        };
    }
    reading.map_or("idle", |reading| {
        if reading.attention.is_some() {
            "waiting"
        } else if reading.activity == crate::activity::Activity::Working {
            "working"
        } else {
            "idle"
        }
    })
}

fn snapshot() -> (tokenstat_sync::push::WorkOverview, Vec<serde_json::Value>) {
    use tokenstat_sync::push::{WorkOverview, WorkOverviewItem};
    let machine = tokenstat_sync::config::ensure_machine_id().unwrap_or_default();
    let mut rows: Vec<(WorkOverviewItem, String, String, String)> = crate::chat::shared()
        .work_overview()
        .into_iter()
        .map(|(id, workspace, title, phase)| {
            (
                WorkOverviewItem {
                    key: tokenstat_sync::push::overview_item_key(&machine, "chat", &id),
                    kind: "chat".into(),
                    phase: phase.into(),
                },
                id,
                workspace,
                title,
            )
        })
        .collect();
    let sessions: Vec<_> = tokenstat_pty::manager()
        .list()
        .into_iter()
        .filter(|info| {
            info.alive
                && !info.hidden
                && info.workspace_id.as_ref().is_some_and(|id| !id.is_empty())
        })
        .collect();
    {
        let active: HashSet<_> = sessions.iter().map(|info| info.id.clone()).collect();
        let mut completed = completed_terminals()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        completed.retain(|_, work| work.finished_at.elapsed() < COMPLETION_LIFE);
        rows.extend(
            completed
                .iter()
                .filter(|(id, _)| !active.contains(*id))
                .map(|(id, work)| {
                    (
                        WorkOverviewItem {
                            key: tokenstat_sync::push::overview_item_key(&machine, "terminal", id),
                            kind: "terminal".into(),
                            phase: work.phase.into(),
                        },
                        id.clone(),
                        work.workspace_id.clone(),
                        String::new(),
                    )
                }),
        );
    }
    rows.extend(sessions.into_iter().map(|info| {
        let phase = session_phase(&info);
        (
            WorkOverviewItem {
                key: tokenstat_sync::push::overview_item_key(&machine, "terminal", &info.id),
                kind: "terminal".into(),
                phase: phase.into(),
            },
            info.id,
            info.workspace_id.unwrap_or_default(),
            String::new(),
        )
    }));
    rows.sort_by(|a, b| {
        priority(&a.0.phase)
            .cmp(&priority(&b.0.phase))
            .then_with(|| a.0.key.cmp(&b.0.key))
    });
    let mut summary = WorkOverview::default();
    for (item, _, _, _) in &rows {
        summary.total += 1;
        match item.phase.as_str() {
            "working" => summary.working += 1,
            "waiting" => summary.waiting += 1,
            "done" => summary.done += 1,
            "failed" => summary.failed += 1,
            _ => summary.idle += 1,
        }
    }
    summary.items = rows.iter().take(3).map(|row| row.0.clone()).collect();
    let hints = rows
        .into_iter()
        .take(3)
        .map(|(item, id, workspace, title)| {
            let name = crate::workspaces::get(&workspace)
                .map(|ws| ws.name)
                .unwrap_or_else(|_| "Workspace".into());
            serde_json::json!({"key":item.key,"kind":item.kind,"id":id,"workspaceId":workspace,
            "name": if title.trim().is_empty() { name } else { title }})
        })
        .collect();
    (summary, hints)
}

pub(crate) fn overview() -> serde_json::Value {
    let mut monitor = overview_monitor().lock().unwrap_or_else(|e| e.into_inner());
    let (summary, hints) = snapshot();
    // Capture the current account only on an authorized foreground request.
    // Background status never rebinds to an account that arrived later.
    if tokenstat_sync::push::begin_overview_activity() {
        tokenstat_sync::push::overview_activity_in_background(summary.clone());
        *monitor = Some(Overview {
            summary: summary.clone(),
            sent_at: Instant::now(),
            expires_at: Instant::now() + Duration::from_secs(8 * 3600),
        });
        crate::activity::start();
    } else {
        *monitor = None;
    }
    serde_json::json!({"summary":summary,"hints":hints})
}

fn poll_overview() {
    let mut monitor = overview_monitor().lock().unwrap_or_else(|e| e.into_inner());
    let Some(current) = monitor.as_mut() else {
        return;
    };
    if Instant::now() >= current.expires_at {
        *monitor = None;
        return;
    }
    let (summary, _) = snapshot();
    if summary != current.summary || current.sent_at.elapsed() >= Duration::from_secs(60) {
        tokenstat_sync::push::overview_activity_in_background(summary.clone());
        current.summary = summary;
        current.sent_at = Instant::now();
    }
}

/// Retire before killing so the sampler cannot race an explicit Stop and
/// report an error exit as a failed run instead.
pub(crate) fn stop_terminal(id: &str, close: bool) -> Result<(), tokenstat_pty::PtyError> {
    let mut terminals = terminals()
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let info = tokenstat_pty::manager().info(id).ok();
    // A reaped session has already recorded its result. Closing its old tab
    // later must not start a second retention window after that result expires.
    if terminals.contains_key(id)
        && let Some(info) = info.as_ref()
    {
        remember_completed_terminal(info);
    }
    if close {
        tokenstat_pty::manager().close(id)?;
    } else {
        tokenstat_pty::manager().kill(id)?;
    }
    if terminals.remove(id).is_some() {
        let phase = info.as_ref().map_or("stopped", |info| {
            if info.alive {
                "stopped"
            } else {
                terminal_phase(false, info.exit_code, false).unwrap_or("stopped")
            }
        });
        tokenstat_sync::push::terminal_activity_in_background(id, phase);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signed_out_terminal_completion_is_retained() {
        for code in [0, 3] {
            signed_out_terminal_result(code);
        }
    }

    fn signed_out_terminal_result(code: i32) {
        let root = tempfile::tempdir().unwrap();
        let manager = tokenstat_pty::manager();
        let info = manager
            .spawn(&tokenstat_pty::Spawn {
                command: if cfg!(windows) { "cmd.exe" } else { "/bin/sh" }.into(),
                args: if cfg!(windows) {
                    vec!["/c".into(), format!("exit /b {code}")]
                } else {
                    vec!["-c".into(), format!("exit {code}")]
                },
                cwd: root.path().into(),
                workspace_id: Some("completion-workspace".into()),
                hidden: false,
                rows: 24,
                cols: 80,
                no_color: true,
                dark: None,
                environment: Vec::new(),
            })
            .unwrap();
        // No credentials or network. An overview can be requested after sign-in.
        start_terminal_with(&info, |_| false);
        let deadline = Instant::now() + Duration::from_secs(5);
        while manager.info(&info.id).unwrap().exit_code.is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        poll_terminals();
        let completion = completed_terminals()
            .lock()
            .unwrap()
            .get(&info.id)
            .map(|work| work.phase);
        assert_eq!(
            completion,
            Some(if code == 0 { "done" } else { "failed" }),
            "Local completion tracking must not depend on a legacy push binding."
        );
        completed_terminals()
            .lock()
            .unwrap()
            .get_mut(&info.id)
            .unwrap()
            .finished_at = Instant::now() - COMPLETION_LIFE;
        stop_terminal(&info.id, true).unwrap();
        assert!(
            completed_terminals()
                .lock()
                .unwrap()
                .get(&info.id)
                .is_none_or(|work| work.finished_at.elapsed() >= COMPLETION_LIFE),
            "Closing an old result must not restart its retention window."
        );
        completed_terminals().lock().unwrap().remove(&info.id);
    }

    #[cfg(unix)]
    #[test]
    fn explicitly_stopped_terminal_is_not_a_completion() {
        let root = tempfile::tempdir().unwrap();
        let manager = tokenstat_pty::manager();
        let info = manager
            .spawn(&tokenstat_pty::Spawn {
                command: "/bin/sleep".into(),
                args: vec!["5".into()],
                cwd: root.path().into(),
                workspace_id: Some("stopped-workspace".into()),
                hidden: false,
                rows: 24,
                cols: 80,
                no_color: true,
                dark: None,
                environment: Vec::new(),
            })
            .unwrap();
        start_terminal_with(&info, |_| false);
        stop_terminal(&info.id, false).unwrap();
        poll_terminals();
        manager.close(&info.id).unwrap();
        assert!(
            !completed_terminals().lock().unwrap().contains_key(&info.id),
            "Stop must not become a failed or successful result on the next tick."
        );
    }

    #[test]
    fn terminal_completion_survives_close_without_repeating_or_guessing_success() {
        let mut completed = HashMap::new();
        let now = Instant::now();
        let mut info = tokenstat_pty::SessionInfo {
            id: "finished-terminal".into(),
            command: "private command".into(),
            cwd: "/private/path".into(),
            workspace_id: Some("workspace".into()),
            hidden: false,
            rows: 24,
            cols: 80,
            alive: true,
            exit_code: None,
            total_bytes: 0,
            last_activity_at_ms: None,
            pid: None,
            started_at_ms: 1,
            program_status: None,
        };
        retain_completed_terminal(&mut completed, &info, now);
        assert!(completed.is_empty());
        info.alive = false;
        retain_completed_terminal(&mut completed, &info, now);
        assert!(
            completed.is_empty(),
            "EOF alone must not be called success."
        );
        info.exit_code = Some(0);
        retain_completed_terminal(&mut completed, &info, now);
        assert_eq!(completed[&info.id].phase, "done");
        assert_eq!(completed[&info.id].workspace_id, "workspace");
        retain_completed_terminal(&mut completed, &info, now + Duration::from_secs(60));
        assert_eq!(
            completed[&info.id].finished_at, now,
            "Heartbeats cannot refresh completion age."
        );
        info.id = "failed-terminal".into();
        info.exit_code = Some(2);
        retain_completed_terminal(&mut completed, &info, now + COMPLETION_LIFE);
        assert_eq!(completed.len(), 1);
        assert_eq!(completed[&info.id].phase, "failed");
        info.id = "hidden-terminal".into();
        info.hidden = true;
        retain_completed_terminal(&mut completed, &info, now + COMPLETION_LIFE);
        assert_eq!(completed.len(), 1);
        // An interactive agent can finish a turn while its PTY stays alive.
        // Closing that tab must retain the agent's reported result.
        info.id = "completed-agent".into();
        info.hidden = false;
        info.alive = true;
        info.exit_code = None;
        info.program_status = Some(tokenstat_pty::program_status::ProgramStatus {
            state: tokenstat_pty::program_status::State::Done,
            kind: None,
            progress: None,
            app: None,
            id: None,
            revision: 1,
        });
        retain_completed_terminal(&mut completed, &info, now + COMPLETION_LIFE);
        assert_eq!(completed[&info.id].phase, "done");
    }

    #[test]
    fn terminal_status_distinguishes_waiting_success_and_failure() {
        assert_eq!(terminal_phase(true, None, false), Some("working"));
        assert_eq!(terminal_phase(true, None, true), Some("waiting"));
        assert_eq!(terminal_phase(false, Some(0), true), Some("done"));
        assert_eq!(terminal_phase(false, Some(1), false), Some("failed"));
        assert_eq!(terminal_phase(false, None, false), None);
    }

    #[test]
    fn overview_distinguishes_idle_from_attention_and_retains_legacy_evidence() {
        use crate::activity::{Activity, Attention, Reading};
        use tokenstat_pty::program_status::State;
        let mut reading = Reading {
            activity: Activity::Idle,
            attention: Some(Attention::Permission),
            cpu_percent: 0.0,
            memory_mb: 0.0,
        };
        assert_eq!(activity_phase(None, Some(reading)), "waiting");
        for (state, phase) in [
            (State::Idle, "idle"),
            (State::Working, "working"),
            (State::Done, "done"),
            (State::Error, "failed"),
            (State::Blocked, "waiting"),
        ] {
            assert_eq!(
                activity_phase(Some(state), Some(reading)),
                phase,
                "program state wins over an old prompt"
            );
        }
        reading.attention = None;
        assert_eq!(activity_phase(None, Some(reading)), "idle");
        reading.activity = Activity::Working;
        assert_eq!(activity_phase(None, Some(reading)), "working");
        assert_eq!(activity_phase(None, None), "idle");
    }
}
