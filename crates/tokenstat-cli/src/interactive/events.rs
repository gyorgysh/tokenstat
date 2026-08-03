use std::io::{self, Write};

use anyhow::{Context, Result};
use crossterm::event::{Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use tokenstat_core::Store;

use super::*;

pub(super) fn handle_event(app: &mut App, ev: Event) -> Result<()> {
    match ev {
        Event::Key(key) if key.kind == KeyEventKind::Press => {
            if app.detail.is_some() {
                return handle_detail_key(app, key.code, key.modifiers);
            }
            if app.wizard.is_some() {
                return handle_wizard_key(app, key.code, key.modifiers);
            }

            let suggesting = app.showing_suggestions() && !app.filtered_commands().is_empty();

            // When the palette is open, ↑↓ pick a command instead of scrolling.
            if suggesting {
                match key.code {
                    KeyCode::Up => {
                        if app.suggest_idx > 0 {
                            app.suggest_idx -= 1;
                        }
                        return Ok(());
                    }
                    KeyCode::Down => {
                        let n = app.filtered_commands().len();
                        if n > 0 && app.suggest_idx + 1 < n {
                            app.suggest_idx += 1;
                        }
                        return Ok(());
                    }
                    KeyCode::Tab => {
                        app.apply_suggestion();
                        return Ok(());
                    }
                    // 1-9 run the Nth suggestion directly. The overlay shows the
                    // number on each row, so this is the fast path past the
                    // arrow keys. Only applies while the palette is open.
                    KeyCode::Char(c @ '1'..='9') => {
                        let idx = (c as u8 - b'1') as usize;
                        if idx < app.filtered_commands().len() {
                            app.suggest_idx = idx;
                            app.submit_input()?;
                        }
                        return Ok(());
                    }
                    _ => {}
                }
            }

            // Global shortcuts when the input is empty.
            if app.input.is_empty() {
                match key.code {
                    KeyCode::Char('q') if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                        app.should_quit = true;
                        return Ok(());
                    }
                    KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        app.should_quit = true;
                        return Ok(());
                    }
                    KeyCode::Right if !suggesting => {
                        app.tab = app.tab.next();
                        app.scroll = 0;
                        return Ok(());
                    }
                    KeyCode::Left if !suggesting => {
                        app.tab = app.tab.prev();
                        app.scroll = 0;
                        return Ok(());
                    }
                    KeyCode::BackTab => {
                        app.tab = app.tab.prev();
                        app.scroll = 0;
                        return Ok(());
                    }
                    KeyCode::PageUp => {
                        app.scroll = app.scroll.saturating_sub(5);
                        return Ok(());
                    }
                    KeyCode::PageDown => {
                        app.scroll = app.scroll.saturating_add(5);
                        return Ok(());
                    }
                    KeyCode::Up => {
                        if !app.history.is_empty() {
                            app.history_prev();
                            return Ok(());
                        }
                        app.scroll = app.scroll.saturating_sub(1);
                        return Ok(());
                    }
                    KeyCode::Down => {
                        if app.history_idx.is_some() {
                            app.history_next();
                            return Ok(());
                        }
                        app.scroll = app.scroll.saturating_add(1);
                        return Ok(());
                    }
                    KeyCode::Char(c @ '1'..='9') => {
                        app.tab = Tab::from_index((c as u8 - b'1') as usize);
                        app.scroll = 0;
                        return Ok(());
                    }
                    KeyCode::Char('s') => {
                        if app.tab.is_chrono() {
                            app.toggle_chrono_sort();
                        } else {
                            app.status =
                                "s sorts Daily/Weekly/Monthly. Switch to one of those tabs first."
                                    .into();
                        }
                        return Ok(());
                    }
                    KeyCode::Char('m') => {
                        if app.tab == Tab::Summary {
                            app.summary_models_expanded = !app.summary_models_expanded;
                            app.scroll = 0;
                            app.status = if app.summary_models_expanded {
                                "Showing all models · m collapses".into()
                            } else {
                                "Showing top models · m expands · dollar total stays below".into()
                            };
                        } else {
                            app.status =
                                "m expands the model list on Summary. Switch to that tab first."
                                    .into();
                        }
                        return Ok(());
                    }
                    _ => {}
                }
            } else if !suggesting {
                // With text in the field and no palette, ↑↓ walk command history.
                match key.code {
                    KeyCode::Up => {
                        app.history_prev();
                        return Ok(());
                    }
                    KeyCode::Down => {
                        app.history_next();
                        return Ok(());
                    }
                    _ => {}
                }
            }

            match key.code {
                KeyCode::Esc => {
                    if app.input.is_empty() {
                        app.should_quit = true;
                    } else {
                        app.input.clear();
                        app.cursor = 0;
                        app.suggest_idx = 0;
                    }
                }
                KeyCode::Enter => app.submit_input()?,
                KeyCode::Backspace => app.backspace(),
                KeyCode::Left => app.move_left(),
                KeyCode::Right => app.move_right(),
                KeyCode::Home => app.cursor = 0,
                KeyCode::End => app.cursor = app.input.len(),
                KeyCode::Char(c) => {
                    if key.modifiers.contains(KeyModifiers::CONTROL) && c == 'c' {
                        app.should_quit = true;
                    } else if !key.modifiers.contains(KeyModifiers::CONTROL)
                        && !key.modifiers.contains(KeyModifiers::ALT)
                    {
                        app.insert_char(c);
                    }
                }
                _ => {}
            }
        }
        Event::Resize(_, _) => {}
        _ => {}
    }
    Ok(())
}

/// Keys while a report window (heatmap / wrapped / budget) is open: Esc or q
/// closes it, arrows and page keys scroll. Everything else is ignored so a
/// stray keystroke cannot disturb the report.
pub(super) fn handle_detail_key(
    app: &mut App,
    code: KeyCode,
    modifiers: KeyModifiers,
) -> Result<()> {
    if modifiers.contains(KeyModifiers::CONTROL) && matches!(code, KeyCode::Char('c')) {
        app.should_quit = true;
        return Ok(());
    }
    match code {
        KeyCode::Esc | KeyCode::Char('q') => {
            app.detail = None;
            return Ok(());
        }
        _ => {}
    }
    if let Some(detail) = app.detail.as_mut() {
        match code {
            KeyCode::Up => detail.scroll = detail.scroll.saturating_sub(1),
            KeyCode::Down => detail.scroll = detail.scroll.saturating_add(1),
            KeyCode::PageUp => detail.scroll = detail.scroll.saturating_sub(5),
            KeyCode::PageDown => detail.scroll = detail.scroll.saturating_add(5),
            _ => {}
        }
    }
    Ok(())
}

pub(super) fn handle_wizard_key(
    app: &mut App,
    code: KeyCode,
    modifiers: KeyModifiers,
) -> Result<()> {
    if modifiers.contains(KeyModifiers::CONTROL) && matches!(code, KeyCode::Char('c')) {
        app.should_quit = true;
        return Ok(());
    }

    let Some(wizard) = app.wizard.as_mut() else {
        return Ok(());
    };

    match code {
        KeyCode::Esc => {
            app.wizard = None;
            app.status = "Cancelled".into();
            return Ok(());
        }
        KeyCode::Up => {
            let selected = wizard_selected_mut(wizard);
            if *selected > 0 {
                *selected -= 1;
            }
            return Ok(());
        }
        KeyCode::Down => {
            let n = wizard_option_count(wizard);
            let selected = wizard_selected_mut(wizard);
            if n > 0 && *selected + 1 < n {
                *selected += 1;
            }
            return Ok(());
        }
        KeyCode::Enter => {}
        _ => return Ok(()),
    }

    // Enter: take the wizard so we can mutate app freely.
    let Some(wizard) = app.wizard.take() else {
        return Ok(());
    };
    match wizard {
        Wizard::LoginHost { selected } => {
            let pending = LOGIN_HOSTS
                .get(selected)
                .map(|(_, _, flag)| flag.map(str::to_string));
            if let Some(host_flag) = pending {
                app.pending_login_host = Some(host_flag);
                app.status = "Opening browser for device login…".into();
            } else {
                app.status = "Invalid host choice".into();
            }
        }
        Wizard::AfterLogin {
            handle,
            host,
            selected,
        } => {
            if selected == 0 {
                app.pending_sync_host = Some(host.clone());
                app.status = format!("Syncing as @{handle}…");
            } else {
                app.status = format!("Logged in as @{handle} · sync later with /sync");
            }
        }
        Wizard::Setup { step, selected } => match step {
            SetupStep::Welcome => {
                if selected == 0 {
                    app.wizard = Some(Wizard::Setup {
                        step: SetupStep::ScanOffer,
                        selected: 0,
                    });
                    app.status = "Scan local agent logs into the archive?".into();
                } else {
                    app.status = "Skipped setup. Type /setup anytime.".into();
                }
            }
            SetupStep::ScanOffer => {
                if selected == 0 {
                    app.run_scan(false)?;
                }
                app.wizard = Some(Wizard::Setup {
                    step: SetupStep::ScheduleOffer,
                    selected: 0,
                });
                app.status = "Install an hourly scan so log cleanup cannot erase history?".into();
            }
            SetupStep::ScheduleOffer => {
                if selected == 0 {
                    match app.install_scan_schedule() {
                        Ok(()) => {}
                        Err(e) => app.status = format!("Schedule install failed: {e}"),
                    }
                } else {
                    app.status = "Skipped schedule. Run tokenstat schedule --install later.".into();
                }
                app.wizard = Some(Wizard::Setup {
                    step: SetupStep::LoginOffer,
                    selected: 0,
                });
            }
            SetupStep::LoginOffer => {
                if selected == 0 {
                    app.wizard = Some(Wizard::LoginHost { selected: 0 });
                    app.status = "Choose a host, then confirm in the browser".into();
                } else {
                    app.status =
                        "Setup done locally. Type /login when you want a public profile.".into();
                }
            }
        },
    }
    Ok(())
}

pub(super) fn wizard_selected_mut(wizard: &mut Wizard) -> &mut usize {
    match wizard {
        Wizard::LoginHost { selected }
        | Wizard::AfterLogin { selected, .. }
        | Wizard::Setup { selected, .. } => selected,
    }
}

pub(super) fn wizard_option_count(wizard: &Wizard) -> usize {
    match wizard {
        Wizard::LoginHost { .. } => LOGIN_HOSTS.len(),
        Wizard::AfterLogin { .. } => AFTER_LOGIN_ACTIONS.len(),
        Wizard::Setup { step, .. } => match step {
            SetupStep::Welcome => SETUP_WELCOME.len(),
            SetupStep::ScanOffer => 2,
            SetupStep::ScheduleOffer => 2,
            SetupStep::LoginOffer => 2,
        },
    }
}
/// Leave the alternate screen so device login can print the code and wait.
pub(super) fn run_login_outside_tui(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    app: &mut App,
    host_flag: Option<&str>,
) -> Result<()> {
    disable_raw_mode().context("leaving raw mode for login")?;
    execute!(
        terminal.backend_mut(),
        LeaveAlternateScreen,
        crossterm::cursor::Show
    )
    .context("leaving alternate screen for login")?;

    println!();
    println!("  Linking this machine to tokenstat.ai…");
    println!();

    let outcome = tokenstat_sync::login(host_flag);

    println!();
    print!("  Press Enter to return to tokenstat…");
    let _ = io::stdout().flush();
    let mut line = String::new();
    let _ = io::stdin().read_line(&mut line);

    execute!(
        terminal.backend_mut(),
        EnterAlternateScreen,
        crossterm::cursor::Hide
    )
    .context("re-entering alternate screen after login")?;
    enable_raw_mode().context("re-enabling raw mode after login")?;
    terminal.clear().context("clearing terminal after login")?;

    match outcome {
        Ok(result) => {
            app.refresh_sync_hint();
            // Same as CLI login: sync only runs on a schedule once linked.
            let _ = app.install_linked_schedules(host_flag);
            app.status = format!("Logged in as @{} · {}", result.handle, result.host);
            app.wizard = Some(Wizard::AfterLogin {
                handle: result.handle,
                host: result.host,
                selected: 0,
            });
        }
        Err(e) => {
            app.wizard = None;
            app.status = format!("Login failed: {e}");
        }
    }
    Ok(())
}

/// Kick off a `/sync` on a worker thread and return.
///
/// A sync is a schema fetch plus up to four POST attempts, each with a ten
/// second connect timeout: on a dead network that is tens of seconds, and the
/// UI must not sit frozen through it. The status line says what is happening
/// and [`poll_sync_result`] lands the outcome on the next loop pass.
pub(super) fn start_sync(app: &mut App, host_flag: Option<&str>) {
    if app.pending_sync.is_some() {
        app.status = "sync already running".into();
        return;
    }
    let (tx, rx) = std::sync::mpsc::channel();
    let db_path = app.db_path.clone();
    let host = host_flag.map(str::to_string);
    std::thread::spawn(move || {
        let outcome = match Store::open(&db_path) {
            Ok(store) => tokenstat_sync::sync(
                &store,
                tokenstat_sync::SyncOptions {
                    host_flag: host.as_deref(),
                    prune: false,
                    window: None,
                    dry_run: false,
                    tz_name: None,
                },
            ),
            Err(e) => Err(tokenstat_sync::ProfileError::Core(e)),
        };
        let _ = tx.send(outcome.map_err(|e| e.to_string()));
    });
    app.pending_sync = Some(rx);
    app.status = "Syncing…".into();
    app.dirty = true;
}

/// Collect a finished background sync, if any.
pub(super) fn poll_sync_result(app: &mut App) {
    let Some(rx) = &mut app.pending_sync else {
        return;
    };
    let outcome = match rx.try_recv() {
        Ok(r) => r,
        Err(std::sync::mpsc::TryRecvError::Empty) => return,
        Err(std::sync::mpsc::TryRecvError::Disconnected) => {
            app.pending_sync = None;
            app.status = "sync worker exited without a result".into();
            app.dirty = true;
            return;
        }
    };
    app.pending_sync = None;
    match outcome {
        Ok(result) => {
            app.refresh_sync_hint();
            app.status = format!(
                "Synced {} rows to {} · {}..{}",
                result.rows, result.host, result.window.from, result.window.to
            );
        }
        Err(e) => {
            app.status = format!("sync: {e}");
        }
    }
    app.dirty = true;
}
