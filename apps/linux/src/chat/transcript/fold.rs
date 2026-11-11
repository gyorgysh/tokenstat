// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! All four original detail levels, preserving readable rows and stable groups.

use super::{
    Activity, ChangedFile, GroupStyle, Kind, PlainStep, Row, StepGroup, TurnChanges, lf_lines, nfc,
    trim_space,
};
use crate::work::text;
use std::collections::{HashMap, HashSet};
use unicode_segmentation::UnicodeSegmentation;

/// Use the same detail identity already owned by the real application menu.
pub use crate::commands::ChatDetail as Detail;
pub fn group_id(first: &str) -> String {
    format!("g:{first}")
}
pub fn owner(id: &str, folded: &[Row]) -> Option<String> {
    folded.iter().find(|r|matches!(&r.kind,Kind::Group{group} if !group.open&&(group.member_ids.iter().any(|m|text::equal(m,id))||r.image_row_ids.iter().any(|m|text::equal(m,id))))).map(|r|r.id.clone())
}
pub fn fold(
    items: &[Row],
    detail: Detail,
    running: bool,
    is_open: impl Fn(&str) -> bool,
) -> Vec<Row> {
    let folded = match detail {
        Detail::Detailed => items.to_vec(),
        Detail::Standard | Detail::Compact => {
            standard_compact(items, running, &is_open, detail == Detail::Compact)
        }
        Detail::Minimal => minimal(items, running, &is_open),
    };
    with_turn_changes(&folded, items, running)
}
pub fn with_turn_changes(folded: &[Row], raw: &[Row], running: bool) -> Vec<Row> {
    let mut changes = HashMap::new();
    let mut turn = 0;
    let mut building: HashMap<String, usize> = HashMap::new();
    let mut current = TurnChanges {
        id: String::new(),
        files: vec![],
    };
    let close = |changes: &mut HashMap<usize, TurnChanges>,
                 current: &mut TurnChanges,
                 building: &mut HashMap<String, usize>,
                 turn: usize| {
        let old = std::mem::replace(
            current,
            TurnChanges {
                id: String::new(),
                files: vec![],
            },
        );
        if !old.files.is_empty() {
            changes.insert(turn, old);
        }
        building.clear();
    };
    for row in raw {
        match &row.kind {
            Kind::User { .. } if !row.is_steer => {
                close(&mut changes, &mut current, &mut building, turn);
                turn += 1;
            }
            Kind::Edit { state } if !state.failed && !state.running => {
                if current.files.is_empty() {
                    current.id = format!("changes:{}", row.id);
                }
                if let Some(i) = building.get(&nfc(&state.path)) {
                    let f = &mut current.files[*i];
                    f.added += u64::from(state.added);
                    f.removed += u64::from(state.removed);
                    f.patches.push(state.patch.clone());
                } else {
                    building.insert(nfc(&state.path), current.files.len());
                    current.files.push(ChangedFile {
                        path: state.path.clone(),
                        added: u64::from(state.added),
                        removed: u64::from(state.removed),
                        patches: vec![state.patch.clone()],
                    });
                }
            }
            _ => {}
        }
    }
    close(&mut changes, &mut current, &mut building, turn);
    if changes.is_empty() {
        return folded.to_vec();
    }
    let mut out = vec![];
    turn = 0;
    for row in folded {
        if matches!(row.kind, Kind::User { .. }) && !row.is_steer {
            if let Some(changes) = changes.get(&turn) {
                out.push(Row::new(
                    &changes.id,
                    Kind::Changes {
                        changes: changes.clone(),
                    },
                ));
            }
            turn += 1;
        }
        out.push(row.clone());
    }
    if !running && let Some(changes) = changes.get(&turn) {
        out.push(Row::new(
            &changes.id,
            Kind::Changes {
                changes: changes.clone(),
            },
        ));
    }
    out
}
fn standard_compact(
    items: &[Row],
    running: bool,
    is_open: &impl Fn(&str) -> bool,
    compact: bool,
) -> Vec<Row> {
    let mut out = vec![];
    let mut run = vec![];
    let flush = |run: &mut Vec<Row>, out: &mut Vec<Row>, trailing: bool| {
        if run.is_empty() {
            return;
        }
        if !compact && run.len() < 2 {
            out.append(run);
        } else {
            let mut group = make(GroupStyle::Explored, run, running && trailing);
            group.plain = compact;
            emit(group, run, out, is_open);
            run.clear();
        }
    };
    for (i, row) in items.iter().enumerate() {
        match &row.kind {
            Kind::Tool { state } if !state.failed && is_exploration(&state.verb) => {
                run.push(row.clone())
            }
            Kind::Thinking { text } => {
                flush(&mut run, &mut out, false);
                if running && i == items.len() - 1 {
                    out.push(row.clone());
                } else {
                    let mut group = make(GroupStyle::Thought, std::slice::from_ref(row), false);
                    group.preview = preview(text);
                    group.plain = compact;
                    emit(group, std::slice::from_ref(row), &mut out, is_open);
                }
            }
            Kind::Tool { state } if compact => {
                flush(&mut run, &mut out, false);
                let mut group = make(GroupStyle::Step, std::slice::from_ref(row), state.running);
                group.plain = true;
                emit(group, std::slice::from_ref(row), &mut out, is_open);
            }
            Kind::Edit { state } if compact => {
                flush(&mut run, &mut out, false);
                let mut group = make(GroupStyle::Step, std::slice::from_ref(row), state.running);
                group.plain = true;
                emit(group, std::slice::from_ref(row), &mut out, is_open);
            }
            _ => {
                flush(&mut run, &mut out, false);
                out.push(row.clone());
            }
        }
    }
    flush(&mut run, &mut out, true);
    out
}
fn minimal(items: &[Row], running: bool, is_open: &impl Fn(&str) -> bool) -> Vec<Row> {
    let mut starts = items
        .iter()
        .enumerate()
        .filter_map(|(i, r)| (matches!(r.kind, Kind::User { .. }) && !r.is_steer).then_some(i))
        .collect::<Vec<_>>();
    if starts.first() != Some(&0) {
        starts.insert(0, 0);
    }
    let mut out = vec![];
    for (n, start) in starts.iter().copied().enumerate() {
        if start >= items.len() {
            continue;
        }
        let end = starts.get(n + 1).copied().unwrap_or(items.len());
        minimal_turn(
            &items[start..end],
            running && end == items.len(),
            is_open,
            &mut out,
        );
    }
    out
}
fn minimal_turn(turn: &[Row], live: bool, is_open: &impl Fn(&str) -> bool, out: &mut Vec<Row>) {
    let mut members = vec![];
    let mut usage = vec![];
    let mut cost = 0.;
    let mut known = true;
    let mut last_header = None;
    let flush = |members: &mut Vec<Row>,
                 out: &mut Vec<Row>,
                 last_header: &mut Option<usize>,
                 trailing: bool| {
        if members.is_empty() {
            return;
        }
        *last_header = Some(out.len());
        let thoughts = members
            .iter()
            .all(|r| matches!(r.kind, Kind::Thinking { .. }));
        let mut group = make(
            if thoughts {
                GroupStyle::Thought
            } else {
                GroupStyle::Work
            },
            members,
            live && trailing,
        );
        if thoughts && let Kind::Thinking { text } = &members[0].kind {
            group.preview = preview(text);
        }
        if live
            && trailing
            && let Some(Row {
                kind: Kind::Thinking { text },
                ..
            }) = members.last()
        {
            group.preview = preview(text);
        }
        emit(group, members, out, is_open);
        members.clear();
    };
    for row in turn {
        match &row.kind {
            Kind::Usage { cost: spent, .. } => {
                cost += spent.unwrap_or_default();
                known = known && spent.is_some_and(|s| s.is_finite() && s >= 0.);
                usage.push(row);
            }
            Kind::Thinking { .. } => members.push(row.clone()),
            Kind::Tool { .. } | Kind::Edit { .. } => members.push(row.clone()),
            _ => {
                flush(&mut members, out, &mut last_header, false);
                out.push(row.clone());
            }
        }
    }
    flush(&mut members, out, &mut last_header, true);
    if let Some(i) = last_header
        && known
        && cost.is_finite()
        && cost > 0.
        && let Kind::Group { group } = &out[i].kind
    {
        let mut group = group.clone();
        group.cost = Some(cost);
        let previous = &out[i];
        let mut row = Row::new(&previous.id, Kind::Group { group });
        row.last_sequence = previous.last_sequence;
        row.image_attachments = previous.image_attachments.clone();
        row.image_row_ids = previous.image_row_ids.clone();
        out[i] = row;
    } else if let Some(first) = usage.first() {
        let mut input = 0_u64;
        let mut output = 0_u64;
        for row in &usage {
            if let Kind::Usage {
                input: a,
                output: b,
                ..
            } = row.kind
            {
                input = input.saturating_add(a);
                output = output.saturating_add(b);
            }
        }
        let mut row = Row::new(
            &first.id,
            Kind::Usage {
                input,
                output,
                cost: (known && cost.is_finite()).then_some(cost),
            },
        );
        row.last_sequence = usage.last().and_then(|r| r.last_sequence);
        out.push(row);
    }
}
fn emit(
    mut group: StepGroup,
    members: &[Row],
    out: &mut Vec<Row>,
    is_open: &impl Fn(&str) -> bool,
) {
    let id = group_id(&members[0].id);
    group.open = is_open(&id);
    let open = group.open;
    let plain = group.plain;
    let mut header = Row::new(&id, Kind::Group { group });
    header.last_sequence = members.last().and_then(|r| r.last_sequence);
    if !open {
        let mut seen = HashSet::new();
        header.image_attachments = members
            .iter()
            .flat_map(|r| &r.image_attachments)
            .filter(|f| seen.insert(nfc(&f.id)))
            .cloned()
            .collect();
        header.image_row_ids = members
            .iter()
            .flat_map(|r| &r.image_row_ids)
            .cloned()
            .collect();
    }
    out.push(header);
    if !open {
        return;
    }
    for member in members {
        let mut row = member.clone();
        row.group_id = Some(id.clone());
        if plain {
            row.plain_step = Some(if members.len() == 1 {
                PlainStep::Detail
            } else {
                PlainStep::Line
            });
        }
        out.push(row);
    }
}
fn make(style: GroupStyle, members: &[Row], running: bool) -> StepGroup {
    let mut group = StepGroup::new(style, members.iter().map(|r| r.id.clone()).collect());
    let mut paths = HashSet::new();
    let mut any_running = false;
    for member in members {
        match &member.kind {
            Kind::Tool { state } => {
                group.steps += 1;
                activity(
                    &mut group,
                    member,
                    &state.verb,
                    &state.target,
                    state.running,
                    state.failed,
                );
                group.failures += usize::from(state.failed);
                group.reads += usize::from(state.verb == "Read");
                group.searches += usize::from(is_search(&state.verb));
                group.pages += usize::from(state.verb == "WebFetch");
                span(&mut group, state.started_at_ms, state.ended_at_ms);
                if state.running {
                    any_running = true;
                    group.live_verb = Some(state.verb.clone());
                    group.live_target = Some(state.target.clone());
                }
            }
            Kind::Edit { state } => {
                group.steps += 1;
                activity(
                    &mut group,
                    member,
                    "Edit",
                    &state.path,
                    state.running,
                    state.failed,
                );
                group.failures += usize::from(state.failed);
                paths.insert(nfc(&state.path));
                group.added += u64::from(state.added);
                group.removed += u64::from(state.removed);
                span(&mut group, state.started_at_ms, state.ended_at_ms);
                if state.running {
                    any_running = true;
                    group.live_verb = Some("Edit".into());
                    group.live_target = Some(state.path.clone());
                }
            }
            _ => {}
        }
    }
    group.files = paths.len();
    if members.len() == 1 {
        match &members[0].kind {
            Kind::Tool { state } => {
                group.verb = Some(state.verb.clone());
                group.subject = Some(state.target.clone());
            }
            Kind::Edit { state } => {
                group.verb = Some("Edit".into());
                group.subject = Some(state.path.clone());
            }
            _ => {}
        }
    }
    group.running = any_running || running;
    group
}
fn activity(
    group: &mut StepGroup,
    member: &Row,
    verb: &str,
    target: &str,
    running: bool,
    failed: bool,
) {
    if group.style != GroupStyle::Work {
        return;
    }
    let prefix = target.graphemes(true).take(160).collect::<String>();
    let line = prefix
        .split(|c| {
            matches!(
                c,
                '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
            )
        })
        .next()
        .unwrap_or_default();
    group.recent_activity.push(Activity {
        id: member.id.clone(),
        verb: verb.into(),
        target: trim_space(line).into(),
        running,
        failed,
    });
    if group.recent_activity.len() > 3 {
        let i = group
            .recent_activity
            .iter()
            .position(|a| !a.running)
            .unwrap_or_default();
        group.recent_activity.remove(i);
    }
}
fn span(group: &mut StepGroup, start: i64, end: Option<i64>) {
    if start > 0 {
        group.started_at_ms = Some(group.started_at_ms.unwrap_or(start).min(start));
    }
    if let Some(end) = end.filter(|e| *e > 0) {
        group.ended_at_ms = Some(group.ended_at_ms.unwrap_or(end).max(end));
    }
}
fn is_search(verb: &str) -> bool {
    matches!(verb, "Grep" | "Search" | "Glob" | "Find" | "WebSearch")
}
fn is_exploration(verb: &str) -> bool {
    verb == "Read" || is_search(verb) || verb == "WebFetch"
}
pub fn preview(text: &str) -> Option<String> {
    for line in lf_lines(text, usize::MAX)
        .into_iter()
        .filter(|l| !l.is_empty())
    {
        let plain = trim_space(trim_space(line).trim_matches(|c| "#*_>`- ".contains(c)));
        if !plain.is_empty() {
            return Some(plain.graphemes(true).take(160).collect());
        }
    }
    None
}
