use ratatui::Frame;
use ratatui::layout::{Constraint, Direction, Layout, Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph, Tabs};

use super::*;
use crate::ui;

pub(super) fn draw(f: &mut Frame<'_>, app: &mut App) {
    let area = f.area();
    // Thin chrome: tabs, flexible data, one input line, one status line.
    // Suggestions overlay the bottom of the data pane so they do not steal
    // permanent vertical space.
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(3),
            Constraint::Length(1),
            Constraint::Length(1),
        ])
        .split(area);

    draw_tabs(f, chunks[0], app);
    draw_body(f, chunks[1], app);
    if app.wizard.is_none() {
        draw_suggestions_overlay(f, chunks[1], app);
    }
    draw_input(f, chunks[2], app);
    draw_status(f, chunks[3], app);
    if app.wizard.is_some() {
        draw_wizard(f, area, app);
    }
    if app.detail.is_some() {
        draw_detail(f, area, app);
    }
}

pub(super) fn draw_tabs(f: &mut Frame<'_>, area: Rect, app: &App) {
    // Each tab carries its own number, so switching by key is discoverable
    // without a legend line spending a row on it.
    let titles: Vec<Line<'_>> = Tab::ALL
        .iter()
        .enumerate()
        .map(|(i, t)| {
            Line::from(vec![
                Span::styled(
                    format!(" {} ", i + 1),
                    Style::default().fg(if app.tab.index() == i {
                        Color::Black
                    } else {
                        MUTED
                    }),
                ),
                Span::raw(format!("{} ", t.title())),
            ])
        })
        .collect();
    let divider = if ui::caps().unicode { "│" } else { "|" };
    let tabs = Tabs::new(titles)
        .select(app.tab.index())
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_type(border_type())
                .border_style(Style::default().fg(border()))
                .title(Span::styled(
                    " tokenstat.ai ",
                    Style::default().fg(accent()).add_modifier(Modifier::BOLD),
                )),
        )
        .style(Style::default().fg(MUTED))
        .highlight_style(
            Style::default()
                .fg(Color::Black)
                .bg(accent())
                .add_modifier(Modifier::BOLD),
        )
        .divider(Span::styled(divider, Style::default().fg(MUTED)));
    f.render_widget(tabs, area);
}

pub(super) fn draw_body(f: &mut Frame<'_>, area: Rect, app: &App) {
    let filter_note = if filter_active(&app.filter) {
        format!(" · filter {}", describe_filter(&app.filter))
    } else {
        String::new()
    };
    let title = match app.tab {
        Tab::Summary => {
            if app.summary_models_expanded {
                format!(" Headline · m collapses models{filter_note} ")
            } else {
                format!(" Headline · m expands models{filter_note} ")
            }
        }
        Tab::Daily => {
            if app.chrono_newest_first {
                format!(" Per day · newest first · s to flip{filter_note} ")
            } else {
                format!(" Per day · oldest first · s to flip{filter_note} ")
            }
        }
        Tab::Weekly => {
            if app.chrono_newest_first {
                format!(" Per week · newest first · s to flip{filter_note} ")
            } else {
                format!(" Per week · oldest first · s to flip{filter_note} ")
            }
        }
        Tab::Monthly => {
            if app.chrono_newest_first {
                format!(" Per month · newest first · s to flip{filter_note} ")
            } else {
                format!(" Per month · oldest first · s to flip{filter_note} ")
            }
        }
        Tab::Models => format!(" Per model{filter_note} "),
        Tab::Projects => format!(" Per project{filter_note} "),
        Tab::Sessions => format!(" Busiest sessions{filter_note} "),
        Tab::Blocks => format!(" 5 hour windows{filter_note} "),
        Tab::Doctor => " Archive health ".to_string(),
    };
    // Open at the bottom: the input and status lines below continue the panel,
    // so a closing rule there would cut the client in half.
    let block = Block::default()
        .borders(Borders::LEFT | Borders::RIGHT | Borders::TOP)
        .border_type(border_type())
        .border_style(Style::default().fg(border()))
        .title(Span::styled(
            title,
            Style::default()
                .fg(secondary())
                .add_modifier(Modifier::BOLD),
        ));
    let inner = block.inner(area);
    f.render_widget(block, area);

    let lines = if app.empty && app.tab != Tab::Doctor {
        if filter_active(&app.filter) {
            filtered_empty_lines()
        } else {
            empty_archive_lines()
        }
    } else {
        match app.tab {
            Tab::Summary => summary_lines(app, inner.width),
            Tab::Daily => table_lines(
                &chrono_ordered(&app.days, app.chrono_newest_first),
                "Date",
                false,
                &app.prices,
            ),
            Tab::Weekly => table_lines(
                &chrono_ordered(&app.weeks, app.chrono_newest_first),
                "Week",
                false,
                &app.prices,
            ),
            Tab::Monthly => table_lines(
                &chrono_ordered(&app.months, app.chrono_newest_first),
                "Month",
                false,
                &app.prices,
            ),
            Tab::Models => table_lines(&app.models, "Model", true, &app.prices),
            Tab::Projects => table_lines(&app.projects, "Project", false, &app.prices),
            Tab::Sessions => table_lines(&app.sessions, "Session", false, &app.prices),
            Tab::Blocks => block_lines(app),
            Tab::Doctor => doctor_lines(app),
        }
    };

    // Leave room at the bottom of the pane when the palette is open so rows
    // are not permanently covered without a way to scroll past them.
    let reserve = suggestion_height(app, inner.height);
    let view_height = inner.height.saturating_sub(reserve);
    let scroll = app.scroll.min(lines.len().saturating_sub(1) as u16);
    let para = Paragraph::new(lines)
        .scroll((scroll, 0))
        .style(Style::default());
    let view = Rect {
        x: inner.x,
        y: inner.y,
        width: inner.width,
        height: view_height.max(1),
    };
    f.render_widget(para, view);
}

pub(super) fn suggestion_height(app: &App, available: u16) -> u16 {
    if !app.showing_suggestions() {
        return 0;
    }
    let n = app.filtered_commands().len() as u16;
    if n == 0 {
        return 0;
    }
    // Cap so a tall catalog never eats the whole pane.
    n.min(available.saturating_sub(4).min(8)).saturating_add(1) // +1 separator
}

pub(super) fn draw_suggestions_overlay(f: &mut Frame<'_>, body: Rect, app: &App) {
    if !app.showing_suggestions() {
        return;
    }
    let cmds = app.filtered_commands();
    if cmds.is_empty() {
        return;
    }

    let inner = Rect {
        x: body.x.saturating_add(1),
        y: body.y.saturating_add(1),
        width: body.width.saturating_sub(2),
        height: body.height.saturating_sub(1),
    };
    let height = suggestion_height(app, inner.height);
    if height == 0 || inner.width == 0 {
        return;
    }

    let area = Rect {
        x: inner.x,
        y: inner.y + inner.height.saturating_sub(height),
        width: inner.width,
        height,
    };
    f.render_widget(Clear, area);

    let mut lines: Vec<Line<'static>> = Vec::new();
    // Top rule, then command rows. Selected row is bright; others are muted.
    lines.push(Line::from(Span::styled(
        "─".repeat(area.width as usize),
        Style::default().fg(MUTED),
    )));

    let visible = height.saturating_sub(1) as usize;
    let start = app
        .suggest_idx
        .saturating_sub(visible.saturating_sub(1))
        .min(cmds.len().saturating_sub(visible));
    for (offset, cmd) in cmds.iter().skip(start).take(visible).enumerate() {
        let i = start + offset;
        let selected = i == app.suggest_idx;
        let name = format!("/{}", cmd.name);
        // The running index doubles as the pick key (1-9 run the Nth item), so
        // the number is part of the row. Show the filtered position, which is
        // what the key actually picks.
        let pick = i + 1;
        let pick_key = if pick <= 9 {
            pick.to_string()
        } else {
            " ".to_string()
        };
        let style = if selected {
            Style::default().fg(SELECTED).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(MUTED)
        };
        let pick_style = if selected {
            Style::default().fg(accent()).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(secondary())
        };
        let about_style = if selected {
            Style::default().fg(accent())
        } else {
            Style::default().fg(MUTED)
        };
        lines.push(Line::from(vec![
            Span::styled(format!(" {pick_key}"), pick_style),
            Span::styled(format!(" {name:<11}"), style),
            Span::styled(format!("  {}", cmd.about), about_style),
        ]));
    }

    f.render_widget(Paragraph::new(lines), area);
}

pub(super) fn draw_input(f: &mut Frame<'_>, area: Rect, app: &App) {
    f.render_widget(Clear, area);
    let prompt = "❯ ";
    let display = Line::from(vec![
        Span::styled(
            prompt,
            Style::default().fg(accent()).add_modifier(Modifier::BOLD),
        ),
        Span::raw(app.input.clone()),
    ]);
    f.render_widget(Paragraph::new(display), area);

    let prefix = app.input[..app.cursor].chars().count() as u16;
    let x = area.x.saturating_add(2).saturating_add(prefix);
    if x < area.x + area.width {
        f.set_cursor_position(Position { x, y: area.y });
    }
}

pub(super) fn draw_status(f: &mut Frame<'_>, area: Rect, app: &App) {
    let hint = if app.showing_suggestions() && !app.filtered_commands().is_empty() {
        "↑↓ select · 1-9 run · Tab complete · Enter run · Esc clear".to_string()
    } else if let Some(sync) = &app.sync_hint {
        if app.status.starts_with("type /") {
            format!("{sync}  ·  {}", app.status)
        } else {
            app.status.clone()
        }
    } else {
        app.status.clone()
    };
    let version = format!("v{}", tokenstat_core::VERSION);
    let ver_w = version.chars().count() as u16;
    // Leave room for the version on the right so it stays put while status text
    // changes length. Truncate the hint rather than colliding with the version.
    let hint_budget = area.width.saturating_sub(ver_w.saturating_add(3)) as usize;
    let hint = if hint.chars().count() > hint_budget {
        let mut cut = hint
            .chars()
            .take(hint_budget.saturating_sub(1))
            .collect::<String>();
        cut.push_str(ui::ellipsis());
        cut
    } else {
        hint
    };
    let hint_len = hint.chars().count() as u16;
    let pad = area.width.saturating_sub(1 + hint_len + ver_w + 1) as usize;
    let line = Line::from(vec![
        Span::styled(" ", Style::default()),
        Span::styled(hint, Style::default().fg(MUTED)),
        Span::raw(" ".repeat(pad)),
        Span::styled(version, Style::default().fg(secondary())),
        Span::raw(" "),
    ]);
    f.render_widget(Paragraph::new(line), area);
}
pub(super) fn draw_wizard(f: &mut Frame<'_>, area: Rect, app: &App) {
    let Some(wizard) = &app.wizard else {
        return;
    };

    let (title, subtitle, options, step_label) = match wizard {
        Wizard::LoginHost { .. } => (
            " Link tokenstat.ai ",
            "Choose where to sign in. A browser opens with a one-time code.".into(),
            LOGIN_HOSTS
                .iter()
                .map(|(label, about, _)| (*label, *about))
                .collect(),
            None,
        ),
        Wizard::AfterLogin { handle, host, .. } => (
            " Logged in ",
            format!("@{handle} on {host}"),
            AFTER_LOGIN_ACTIONS.to_vec(),
            None,
        ),
        Wizard::Setup { step, .. } => match step {
            SetupStep::Welcome => (
                " Welcome to tokenstat ",
                "Everything stays on this machine until you sync aggregates.".into(),
                SETUP_WELCOME.to_vec(),
                Some((1, 4)),
            ),
            SetupStep::ScanOffer => (
                " Scan local logs ",
                "Read agent session counters into the local archive.".into(),
                vec![
                    ("Scan now", "Discover installed tools and import usage"),
                    ("Skip", "Continue without scanning"),
                ],
                Some((2, 4)),
            ),
            SetupStep::ScheduleOffer => (
                " Keep it current ",
                "Claude Code deletes transcripts after 30 days. A timer prevents that.".into(),
                vec![
                    ("Install hourly scan", "Writes the platform scheduler entry"),
                    ("Skip", "You can run tokenstat schedule --install later"),
                ],
                Some((3, 4)),
            ),
            SetupStep::LoginOffer => (
                " Public profile ",
                "Optional. Only sealed aggregates are eligible for sync.".into(),
                vec![
                    ("Log in", "Device login to tokenstat.ai"),
                    ("Skip", "Stay local for now"),
                ],
                Some((4, 4)),
            ),
        },
    };

    let selected = match wizard {
        Wizard::LoginHost { selected }
        | Wizard::AfterLogin { selected, .. }
        | Wizard::Setup { selected, .. } => *selected,
    };

    let height = (5 + options.len() as u16 + 2).min(area.height.saturating_sub(2));
    let width = area.width.saturating_sub(4).min(72).max(40.min(area.width));
    let popup = centered_rect(width, height, area);
    f.render_widget(Clear, popup);

    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(border_type())
        .title(Span::styled(
            title,
            Style::default().fg(accent()).add_modifier(Modifier::BOLD),
        ))
        .border_style(Style::default().fg(accent()));
    let inner = block.inner(popup);
    f.render_widget(block, popup);

    let mut lines: Vec<Line<'static>> = Vec::new();
    if let Some((step, total)) = step_label {
        lines.push(Line::from(Span::styled(
            format!("Step {step} of {total}"),
            Style::default().fg(secondary()),
        )));
        lines.push(Line::from(""));
    }
    lines.push(Line::from(Span::styled(
        subtitle,
        Style::default().fg(MUTED),
    )));
    lines.push(Line::from(""));
    for (i, (label, about)) in options.iter().enumerate() {
        let on = i == selected;
        let marker = if on { "› " } else { "  " };
        let label_style = if on {
            Style::default().fg(SELECTED).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(MUTED)
        };
        let about_style = if on {
            Style::default().fg(secondary())
        } else {
            Style::default().fg(MUTED)
        };
        lines.push(Line::from(vec![
            Span::styled(format!("{marker}{label}"), label_style),
            Span::raw("  "),
            Span::styled((*about).to_string(), about_style),
        ]));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "↑↓ select · Enter confirm · Esc cancel",
        Style::default().fg(MUTED),
    )));

    f.render_widget(Paragraph::new(lines), inner);
}

pub(super) fn centered_rect(width: u16, height: u16, area: Rect) -> Rect {
    let width = width.min(area.width);
    let height = height.min(area.height);
    Rect {
        x: area.x + (area.width.saturating_sub(width)) / 2,
        y: area.y + (area.height.saturating_sub(height)) / 2,
        width,
        height,
    }
}

/// The `/heatmap`, `/wrapped`, and `/budget` report window. Contents are
/// precomputed; the last line of the popup is the scroll hint, so the body and
/// the hint never fight for the same row.
pub(super) fn draw_detail(f: &mut Frame<'_>, area: Rect, app: &App) {
    let Some(detail) = &app.detail else {
        return;
    };
    let width = detail
        .width
        .min(area.width.saturating_sub(2))
        .max(30.min(area.width));
    let content_h = detail.lines.len() as u16;
    // Border top, body, hint line, border bottom: content + 3 rows.
    let height = (content_h.saturating_add(3))
        .min(area.height.saturating_sub(2))
        .max(6);
    let popup = centered_rect(width, height, area);
    f.render_widget(Clear, popup);

    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(border_type())
        .border_style(Style::default().fg(accent()))
        .title(Span::styled(
            " report · Esc closes ",
            Style::default().fg(accent()).add_modifier(Modifier::BOLD),
        ));
    let inner = block.inner(popup);
    f.render_widget(block, popup);

    let body_h = inner.height.saturating_sub(1).max(1);
    let scroll = detail
        .scroll
        .min(detail.lines.len().saturating_sub(1) as u16);
    let body = Rect {
        x: inner.x,
        y: inner.y,
        width: inner.width,
        height: body_h,
    };
    f.render_widget(
        Paragraph::new(detail.lines.clone()).scroll((scroll, 0)),
        body,
    );

    let hint = Line::from(Span::styled(
        "↑↓ scroll · Esc closes",
        Style::default().fg(MUTED),
    ));
    let hint_rect = Rect {
        x: inner.x,
        y: inner.y + body_h,
        width: inner.width,
        height: 1,
    };
    f.render_widget(Paragraph::new(hint), hint_rect);
}
