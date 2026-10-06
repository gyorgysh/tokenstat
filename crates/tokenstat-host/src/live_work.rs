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
    let ids: Vec<_> = terminals()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .keys()
        .cloned()
        .collect();
    for id in ids {
        let info = tokenstat_pty::manager().info(&id).ok();
        let phase = info.as_ref().map_or(Some("stopped"), |info| {
            let waiting = info
                .pid
                .and_then(crate::activity::reading)
                .is_some_and(|reading| {
                    reading.attention.is_some()
                        || reading.activity == crate::activity::Activity::Idle
                });
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
}
