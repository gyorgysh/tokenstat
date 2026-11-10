// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{Edit, Kind, Question, Row, Tool, muse, nfc, question, tool};
use crate::{chat::wire::TimelineEvent, drafts::Attachment, work::text};
use std::collections::{BTreeSet, HashMap};

fn label(key: &str) -> String {
    crate::localization::text(key, &[])
}
fn stamp(event: &TimelineEvent, position: usize) -> String {
    event.seq.map_or_else(
        || format!("{}-{position}", event.at_ms.unwrap_or_default()),
        |s| format!("s{s}"),
    )
}
#[derive(Default)]
struct Build {
    items: Vec<Row>,
    running: BTreeSet<usize>,
    tool_indexes: HashMap<String, Vec<usize>>,
    tool_starts: HashMap<String, usize>,
    tool_backends: HashMap<usize, String>,
    edit_starts: HashMap<String, usize>,
    approval_indexes: HashMap<String, usize>,
    question_indexes: HashMap<String, usize>,
    edit_revisions: HashMap<String, usize>,
    text: String,
    text_id: String,
    text_backend: Option<String>,
    text_last: Option<u64>,
    thinking: String,
    thinking_id: String,
    thinking_last: Option<u64>,
    last_backend: Option<String>,
}
impl Build {
    fn flush_text(&mut self, backend: Option<&str>, running: bool) {
        let body = question::stripping(&self.text, running);
        let body = text::trim(&body);
        if !body.is_empty() {
            let mut row = Row::new(
                &self.text_id,
                Kind::Assistant {
                    text: body.into(),
                    backend: self
                        .text_backend
                        .clone()
                        .or_else(|| backend.map(str::to_owned)),
                },
            );
            row.last_sequence = self.text_last;
            self.items.push(row);
        }
        self.text.clear();
        self.text_id.clear();
        self.text_backend = None;
        self.text_last = None;
    }
    fn flush_thinking(&mut self) {
        let body = text::trim(&self.thinking);
        if !body.is_empty() {
            let mut row = Row::new(&self.thinking_id, Kind::Thinking { text: body.into() });
            row.last_sequence = self.thinking_last;
            self.items.push(row);
        }
        self.thinking.clear();
        self.thinking_id.clear();
        self.thinking_last = None;
    }
    fn flush(&mut self, backend: Option<&str>, running: bool) {
        self.flush_text(backend, running);
        self.flush_thinking();
    }
    fn close(&mut self, failed: bool, at: Option<i64>, detail: Option<&str>) {
        for i in &self.running {
            let kind = match &self.items[*i].kind {
                Kind::Tool { state } if state.running => {
                    let mut state = state.clone();
                    state.running = false;
                    state.failed = failed;
                    if state.detail.is_none() {
                        state.detail = detail.map(str::to_owned);
                        state.snippet = tool::snippet(&state.verb, detail);
                    }
                    state.ended_at_ms = at;
                    Kind::Tool { state }
                }
                Kind::Edit { state } if state.running => {
                    let mut state = state.clone();
                    state.running = false;
                    state.failed = failed;
                    state.ended_at_ms = at;
                    state.apply_detail(detail);
                    Kind::Edit { state }
                }
                _ => continue,
            };
            self.items[*i] = Row::new(&self.items[*i].id, kind);
        }
        self.running.clear();
    }
    fn revision(&mut self, path: &str) -> usize {
        let n = self.edit_revisions.entry(nfc(path)).or_default();
        *n += 1;
        *n
    }
    fn note_tool(&mut self, index: usize, call: &str) {
        if call.is_empty() {
            return;
        }
        let indices = self.tool_indexes.entry(nfc(call)).or_default();
        indices.retain(|i| *i != index);
        indices.push(index);
    }
    fn end_index(&self, call: &str) -> Option<usize> {
        if call.is_empty() {
            return None;
        }
        let indices = self.tool_indexes.get(&nfc(call))?;
        indices
            .iter()
            .copied()
            .find(|i| match &self.items[*i].kind {
                Kind::Tool { state } => state.running,
                Kind::Edit { state } => state.running,
                _ => false,
            })
            .or_else(|| indices.last().copied())
    }
    fn matching_edit(&self, call: &str, path: &str) -> Option<usize> {
        if !call.is_empty()
            && let Some(indices) = self.tool_indexes.get(&nfc(call))
        {
            for i in indices.iter().rev() {
                match &self.items[*i].kind {
                    Kind::Edit { state }
                        if path.is_empty()
                            || text::equal(&state.path, path)
                            || state.path == "File" =>
                    {
                        return Some(*i);
                    }
                    Kind::Tool { state }
                        if tool::is_file_edit(&state.verb)
                            && (path.is_empty()
                                || text::equal(&state.target, path)
                                || state.target.is_empty()) =>
                    {
                        return Some(*i);
                    }
                    _ => {}
                }
            }
        }
        for i in self.running.iter().rev() {
            match &self.items[*i].kind {
                Kind::Edit { state }
                    if state.running && (path.is_empty() || text::equal(&state.path, path)) =>
                {
                    return Some(*i);
                }
                Kind::Tool { state }
                    if state.running
                        && tool::is_file_edit(&state.verb)
                        && (path.is_empty() || text::equal(&state.target, path)) =>
                {
                    return Some(*i);
                }
                _ => {}
            }
        }
        None
    }
}

pub fn coalesce(
    events: &[TimelineEvent],
    default_backend: Option<&str>,
    running: bool,
) -> Vec<Row> {
    let mut b = Build::default();
    for event in events {
        if event.kind == "user" {
            b.flush(default_backend, running);
            if event.steer != Some(true) {
                b.close(
                    false,
                    event.at_ms,
                    Some(&label("apple.chatmodel.interrupted.132d124d")),
                );
                b.edit_revisions.clear();
            }
            let mut row = Row::new(
                format!("user-{}", stamp(event, b.items.len())),
                Kind::User {
                    text: event.text.clone().unwrap_or_default(),
                },
            );
            row.is_steer = event.steer == Some(true);
            b.items.push(row);
            continue;
        }
        if event.kind == "handoff" {
            b.flush(default_backend, running);
            b.items.push(Row::new(
                format!("handoff-{}", stamp(event, b.items.len())),
                Kind::Handoff {
                    to: event.to.clone().unwrap_or_default(),
                    brief: event.brief.clone().unwrap_or_default(),
                },
            ));
            b.last_backend = event.to.clone().or(b.last_backend);
            continue;
        }
        if let Some(approval) = &event.approval {
            b.flush(default_backend, running);
            let id = format!("approval-{}", approval.id);
            let key = nfc(&id);
            let row = Row::new(
                id,
                Kind::Approval {
                    approval: approval.clone(),
                },
            );
            if let Some(i) = b.approval_indexes.get(&key) {
                b.items[*i] = row;
            } else {
                b.approval_indexes.insert(key, b.items.len());
                b.items.push(row);
            }
            continue;
        }
        if event.kind == "question"
            && let (Some(id), Some(asked)) = (&event.record_id, &event.question)
        {
            b.flush(default_backend, running);
            b.question_indexes.insert(nfc(id), b.items.len());
            b.items.push(Row::new(
                format!("question-{id}"),
                Kind::Question {
                    question: Question {
                        id: id.clone(),
                        question: asked.clone(),
                        options: event.options.clone().unwrap_or_default(),
                        multiple: event.multiple.unwrap_or_default(),
                        default_answer: event.default_answer.clone(),
                        blocking: event.blocking.unwrap_or(event.default_answer.is_none()),
                        answer: None,
                        delivery: None,
                    },
                },
            ));
            continue;
        }
        if event.kind == "answer" || event.kind == "answerWithdrawn" {
            if let Some(id) = &event.question_id
                && let Some(i) = b.question_indexes.get(&nfc(id))
                && let Kind::Question { question } = &b.items[*i].kind
            {
                let mut question = question.clone();
                let withdrawn = event.kind == "answerWithdrawn";
                question.answer = (!withdrawn).then(|| event.text.clone().unwrap_or_default());
                question.delivery = if withdrawn {
                    None
                } else {
                    event.delivery.clone()
                };
                b.items[*i] = Row::new(&b.items[*i].id, Kind::Question { question });
            }
            continue;
        }
        let Some(agent) = &event.event else {
            continue;
        };
        let backend = event.backend.as_deref().or(default_backend);
        if let (Some(backend), Some(last)) = (backend, b.last_backend.as_deref())
            && !text::equal(backend, last)
        {
            b.flush(default_backend, running);
            b.items.push(Row::new(
                format!("turn-{}", stamp(event, b.items.len())),
                Kind::TurnSeparator {
                    backend: backend.into(),
                },
            ));
        }
        if let Some(backend) = backend {
            b.last_backend = Some(backend.into());
        }
        match agent.kind.as_str() {
            "text" => {
                b.flush_thinking();
                if b.text.is_empty() {
                    b.text_id = format!("text-{}", stamp(event, b.items.len()));
                    b.text_backend = backend.map(str::to_owned);
                }
                b.text += agent.delta.as_deref().unwrap_or_default();
                b.text_last = event.seq;
            }
            "thinking" => {
                b.flush_text(default_backend, running);
                if b.thinking.is_empty() {
                    b.thinking_id = format!("think-{}", stamp(event, b.items.len()));
                }
                b.thinking += agent.delta.as_deref().unwrap_or_default();
                b.thinking_last = event.seq;
            }
            "toolStart" => {
                b.flush(default_backend, running);
                let call = agent
                    .call_id
                    .clone()
                    .unwrap_or_else(|| format!("tool-{}", stamp(event, b.items.len())));
                let count = b.tool_starts.entry(nfc(&call)).or_default();
                *count += 1;
                let id = if event.seq.is_some() {
                    format!("tool-{}", stamp(event, b.items.len()))
                } else if *count == 1 {
                    format!("tool-{call}")
                } else {
                    format!("tool-{call}#{count}")
                };
                let verb = agent.verb.as_deref().unwrap_or_default();
                let target = tool::clip(agent.target.as_deref().unwrap_or_default());
                let i = b.items.len();
                b.note_tool(i, &call);
                b.running.insert(i);
                b.tool_backends
                    .insert(i, backend.unwrap_or_default().into());
                let revision_path = if target.is_empty() {
                    label("apple.chatmodel.file.50009ce1")
                } else {
                    target.clone()
                };
                let kind = if tool::is_file_edit(verb) {
                    Kind::Edit {
                        state: Edit {
                            path: if target.is_empty() {
                                "File".into()
                            } else {
                                target.clone()
                            },
                            added: 0,
                            removed: 0,
                            patch: String::new(),
                            revision: b.revision(&revision_path),
                            running: true,
                            failed: false,
                            started_at_ms: event.at_ms.unwrap_or_default(),
                            ended_at_ms: None,
                        },
                    }
                } else {
                    Kind::Tool {
                        state: Tool {
                            call_id: call,
                            verb: verb.into(),
                            target,
                            running: true,
                            failed: false,
                            detail: None,
                            started_at_ms: event.at_ms.unwrap_or_default(),
                            ended_at_ms: None,
                            snippet: vec![],
                        },
                    }
                };
                b.items.push(Row::new(id, kind));
            }
            "toolEnd" => {
                b.flush(default_backend, running);
                let call = agent.call_id.as_deref().unwrap_or_default();
                if let Some(i) = b.end_index(call) {
                    let kind = match &b.items[i].kind {
                        Kind::Tool { state } => {
                            let mut state = state.clone();
                            let p = muse::completed(
                                b.tool_backends.get(&i).map(String::as_str),
                                &state.verb,
                                &state.target,
                                agent.detail.as_deref(),
                            );
                            state.verb = p.verb;
                            state.target = tool::clip(&p.target);
                            state.running = false;
                            state.failed = !agent.ok.unwrap_or(true);
                            state.detail = agent.detail.clone();
                            state.snippet = tool::snippet(&state.verb, agent.detail.as_deref());
                            state.ended_at_ms = event.at_ms;
                            Kind::Tool { state }
                        }
                        Kind::Edit { state } => {
                            let mut state = state.clone();
                            state.running = false;
                            state.failed = !agent.ok.unwrap_or(true);
                            state.ended_at_ms = event.at_ms;
                            state.apply_detail(agent.detail.as_deref());
                            Kind::Edit { state }
                        }
                        _ => b.items[i].kind.clone(),
                    };
                    b.items[i] = Row::new(&b.items[i].id, kind);
                    b.running.remove(&i);
                } else if tool::is_file_edit(agent.verb.as_deref().unwrap_or_default()) {
                    let path = tool::clip(agent.target.as_deref().unwrap_or_default());
                    let path = if path.is_empty() {
                        label("apple.chatmodel.file.50009ce1")
                    } else {
                        path
                    };
                    let mut state = Edit {
                        revision: b.revision(&path),
                        path,
                        added: 0,
                        removed: 0,
                        patch: String::new(),
                        running: false,
                        failed: !agent.ok.unwrap_or(true),
                        started_at_ms: event.at_ms.unwrap_or_default(),
                        ended_at_ms: event.at_ms,
                    };
                    state.apply_detail(agent.detail.as_deref());
                    let id = if event.seq.is_some() || call.is_empty() {
                        stamp(event, b.items.len())
                    } else {
                        call.into()
                    };
                    b.items
                        .push(Row::new(format!("edit-{id}"), Kind::Edit { state }));
                } else {
                    let fallback = if call.is_empty() {
                        format!("end-{}", stamp(event, b.items.len()))
                    } else {
                        call.into()
                    };
                    let p = muse::completed(
                        backend,
                        agent.verb.as_deref().unwrap_or_default(),
                        agent.target.as_deref().unwrap_or_default(),
                        agent.detail.as_deref(),
                    );
                    b.tool_backends
                        .insert(b.items.len(), backend.unwrap_or_default().into());
                    let id = if event.seq.is_some() {
                        stamp(event, b.items.len())
                    } else {
                        fallback.clone()
                    };
                    let snippet = tool::snippet(&p.verb, agent.detail.as_deref());
                    b.items.push(Row::new(
                        format!("tool-{id}"),
                        Kind::Tool {
                            state: Tool {
                                call_id: fallback,
                                verb: p.verb,
                                target: tool::clip(&p.target),
                                running: false,
                                failed: !agent.ok.unwrap_or(true),
                                detail: agent.detail.clone(),
                                started_at_ms: event.at_ms.unwrap_or_default(),
                                ended_at_ms: event.at_ms,
                                snippet,
                            },
                        },
                    ));
                }
            }
            "edit" => {
                b.flush(default_backend, running);
                let call = agent.call_id.as_deref().unwrap_or_default();
                let path = agent
                    .path
                    .clone()
                    .unwrap_or_else(|| label("apple.chatmodel.file.50009ce1"));
                let added = agent.added.unwrap_or_default();
                let removed = agent.removed.unwrap_or_default();
                let patch = agent.patch.as_deref().unwrap_or_default();
                if let Some(i) = b.matching_edit(call, &path) {
                    let kind = match &b.items[i].kind {
                        Kind::Edit { state } => {
                            let mut state = state.clone();
                            state.apply_patch(added, removed, patch);
                            if state.path == "File" && !path.is_empty() {
                                state.path = path;
                            }
                            Kind::Edit { state }
                        }
                        Kind::Tool { state } => {
                            let mut state = Edit {
                                path: path.clone(),
                                added,
                                removed,
                                patch: patch.into(),
                                revision: 1,
                                running: state.running,
                                failed: false,
                                started_at_ms: state.started_at_ms,
                                ended_at_ms: if state.running {
                                    None
                                } else {
                                    event.at_ms.or(state.ended_at_ms)
                                },
                            };
                            state.revision = b.revision(&path);
                            state.recount_if_needed();
                            Kind::Edit { state }
                        }
                        _ => b.items[i].kind.clone(),
                    };
                    b.items[i] = Row::new(&b.items[i].id, kind);
                    b.note_tool(i, call);
                } else {
                    let mut state = Edit {
                        revision: b.revision(&path),
                        path,
                        added,
                        removed,
                        patch: patch.into(),
                        running: false,
                        failed: false,
                        started_at_ms: event.at_ms.unwrap_or_default(),
                        ended_at_ms: None,
                    };
                    state.recount_if_needed();
                    let id = if event.seq.is_some() || call.is_empty() {
                        format!("edit-{}", stamp(event, b.items.len()))
                    } else {
                        let n = b.edit_starts.entry(nfc(call)).or_default();
                        *n += 1;
                        if *n == 1 {
                            format!("edit-{call}")
                        } else {
                            format!("edit-{call}#{n}")
                        }
                    };
                    b.note_tool(b.items.len(), call);
                    b.items.push(Row::new(id, Kind::Edit { state }));
                }
            }
            "attachment" => {
                b.flush(default_backend, running);
                if let Some(id) = &agent.id {
                    let mut row = Row::new(
                        format!("attachment-{id}"),
                        Kind::Attachment {
                            file: Attachment {
                                id: id.clone(),
                                name: agent.name.clone().filter(|s| !s.is_empty()).unwrap_or_else(
                                    || label("apple.chatmodel.attachment.040d2b36"),
                                ),
                                media_type: agent.media_type.clone(),
                                size: agent.size,
                                tool_call_id: agent.call_id.clone(),
                            },
                        },
                    );
                    row.source_backend = backend.map(str::to_owned);
                    b.items.push(row);
                }
            }
            "usage" => {
                b.flush(default_backend, running);
                b.items.push(Row::new(
                    format!("usage-{}", stamp(event, b.items.len())),
                    Kind::Usage {
                        input: agent.input.unwrap_or_default(),
                        output: agent.output.unwrap_or_default(),
                        cost: agent.cost_usd,
                    },
                ));
            }
            "failed" => {
                b.flush(default_backend, running);
                b.close(true, event.at_ms, agent.text.as_deref());
                b.items.push(Row::new(
                    format!("failed-{}", stamp(event, b.items.len())),
                    Kind::Failed {
                        text: agent
                            .text
                            .clone()
                            .unwrap_or_else(|| label("apple.chatmodel.the_turn_failed.45783181")),
                    },
                ));
            }
            "done" => {
                b.flush(default_backend, running);
                let status = agent.status.as_deref().unwrap_or_default();
                b.close(
                    status == "error",
                    event.at_ms,
                    (status == "error").then_some(status),
                );
            }
            _ => {}
        }
    }
    b.flush(default_backend, running);
    if !running {
        b.close(
            false,
            None,
            Some(&label(
                "apple.chatmodel.ended_without_a_tool_result.da8d3680",
            )),
        );
    }
    for (i, backend) in b.tool_backends {
        b.items[i].source_backend = (!backend.is_empty()).then_some(backend);
    }
    b.items
}
