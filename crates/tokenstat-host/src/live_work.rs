// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Push status for visible workspace terminals, independent of an attached
//! frontend. The existing activity sampler supplies the single polling thread.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

struct Terminal {
    phase: &'static str,
    sent_at: Instant,
}

fn terminals() -> &'static Mutex<HashMap<String, Terminal>> {
    static TERMINALS: OnceLock<Mutex<HashMap<String, Terminal>>> = OnceLock::new();
    TERMINALS.get_or_init(Default::default)
}

pub(crate) fn start_terminal(info: &tokenstat_pty::SessionInfo) {
    if info.hidden || !tokenstat_sync::push::begin_terminal_activity(&info.id) {
        return;
    }
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
    poll_overview();
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
            terminals.remove(&id);
        }
    }
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
        .live_work()
        .into_iter()
        .map(|(id, workspace, title, waiting)| {
            (
                WorkOverviewItem {
                    key: tokenstat_sync::push::overview_item_key(&machine, "chat", &id),
                    kind: "chat".into(),
                    phase: if waiting { "waiting" } else { "working" }.into(),
                },
                id,
                workspace,
                title,
            )
        })
        .collect();
    rows.extend(
        tokenstat_pty::manager()
            .list()
            .into_iter()
            .filter(|info| {
                info.alive
                    && !info.hidden
                    && info.workspace_id.as_ref().is_some_and(|id| !id.is_empty())
            })
            .map(|info| {
                let phase = session_phase(&info);
                (
                    WorkOverviewItem {
                        key: tokenstat_sync::push::overview_item_key(
                            &machine, "terminal", &info.id,
                        ),
                        kind: "terminal".into(),
                        phase: phase.into(),
                    },
                    info.id,
                    info.workspace_id.unwrap_or_default(),
                    String::new(),
                )
            }),
    );
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
