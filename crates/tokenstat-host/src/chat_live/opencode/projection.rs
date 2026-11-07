// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Correlate the native stream with the selected CLI session and snapshots.

use super::PART_CAP;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet, VecDeque};

#[derive(Default)]
pub(super) struct Projection {
    pub(super) session: Option<String>,
    // CLI completion IDs derive from the native started event. Recovery
    // records instead identify the message and ordinal directly.
    pub(super) parts: HashMap<String, String>,
    pub(super) admitted: HashSet<String>,
    pub(super) ordinals: HashMap<(String, String), u64>,
    ordinal_order: VecDeque<(String, String)>,
    tools: HashMap<String, String>,
    started_tools: HashSet<String>,
    messages: HashSet<String>,
    message_order: VecDeque<String>,
    observed_current: bool,
    limited: bool,
    pending: VecDeque<(Value, usize)>,
    pending_bytes: usize,
    pub(super) ended: bool,
}

fn stream_id(message: &str, kind: &str, ordinal: u64) -> String {
    format!("{message}/{kind}/{ordinal}")
}

impl Projection {
    pub(super) fn observes(kind: &str) -> bool {
        matches!(
            kind,
            "session.text.started"
                | "session.text.delta"
                | "session.text.ended"
                | "session.reasoning.started"
                | "session.reasoning.delta"
                | "session.reasoning.ended"
                | "session.tool.input.started"
                | "session.tool.called"
                | "session.step.ended"
                | "session.execution.succeeded"
                | "session.execution.failed"
                | "session.execution.interrupted"
        )
    }

    fn defer(&mut self, event: Value, bytes: usize) {
        if self.pending.len() >= PART_CAP || self.pending_bytes.saturating_add(bytes) > 1024 * 1024
        {
            // A partial prefix with a missing middle cannot be appended to
            // an exact completion. Keep the CLI recovery path for this turn.
            self.limited = true;
            self.pending.clear();
            self.pending_bytes = 0;
            return;
        }
        self.pending_bytes += bytes;
        self.pending.push_back((event, bytes));
    }

    fn ordinal(&mut self, message: &str, kind: &str) -> &mut u64 {
        let key = (message.to_string(), kind.to_string());
        if !self.ordinals.contains_key(&key) {
            if self.ordinals.len() == PART_CAP
                && let Some(old) = self.ordinal_order.pop_front()
            {
                self.ordinals.remove(&old);
            }
            self.ordinal_order.push_back(key.clone());
        }
        self.ordinals.entry(key).or_default()
    }

    pub(super) fn cli(&mut self, mut value: Value) -> Vec<Value> {
        if self.session.is_none()
            && let Some(session) = value["sessionID"].as_str().filter(|id| {
                id.starts_with("ses_")
                    && id.len() <= 160
                    && id
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
            })
        {
            self.session = Some(session.into());
        }
        if let Some(message) = value["part"]["messageID"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= 160)
            && self.messages.insert(message.into())
        {
            self.message_order.push_back(message.into());
            if self.message_order.len() > PART_CAP
                && let Some(old) = self.message_order.pop_front()
            {
                self.messages.remove(&old);
            }
        }
        let mut out = Vec::new();
        if self.session.is_some() {
            let pending = std::mem::take(&mut self.pending);
            self.pending_bytes = 0;
            for (event, bytes) in pending {
                if self
                    .messages
                    .contains(event["data"]["assistantMessageID"].as_str().unwrap_or(""))
                {
                    out.extend(self.native(event));
                } else if !self.limited {
                    self.defer(event, bytes);
                }
            }
        }
        let kind = value["type"].as_str().unwrap_or("").to_string();
        if matches!(kind.as_str(), "text" | "reasoning") {
            let part = &value["part"];
            let id = part["id"]
                .as_str()
                .filter(|id| id.len() <= 160)
                .unwrap_or("");
            let message = part["messageID"]
                .as_str()
                .filter(|id| id.len() <= 160)
                .unwrap_or("");
            let projected = format!("prt_{}_{}-", message.trim_start_matches("msg_"), kind);
            let key = self
                .parts
                .get(id)
                .cloned()
                .or_else(|| {
                    let ordinal = id.strip_prefix(&projected)?.parse::<u64>().ok()?;
                    Some(stream_id(message, &kind, ordinal))
                })
                .or_else(|| {
                    if id.is_empty() || message.is_empty() || self.parts.len() >= PART_CAP {
                        return None;
                    }
                    let ordinal = *self.ordinal(message, &kind);
                    let key = stream_id(message, &kind, ordinal);
                    self.parts.insert(id.into(), key.clone());
                    Some(key)
                });
            if let Some(key) = key {
                if let Some(ordinal) = key.rsplit('/').next().and_then(|n| n.parse::<u64>().ok()) {
                    let next = self.ordinal(message, &kind);
                    *next = (*next).max(ordinal.saturating_add(1));
                }
                self.parts.retain(|_, part| part != &key);
                self.admitted.remove(&key);
                value["tokenstatStream"] = json!(key);
            }
        } else if kind == "step_finish" {
            normalize_step(&mut value);
        } else if kind == "tool_use" {
            let id = value["part"]["id"]
                .as_str()
                .filter(|id| id.len() <= 160)
                .map(str::to_owned);
            if let Some(id) = id {
                self.tools.remove(&id);
                if self.started_tools.remove(&id) {
                    value["tokenstatToolStarted"] = json!(true);
                }
            }
        }
        out.push(value);
        out
    }

    pub(super) fn native(&mut self, event: Value) -> Vec<Value> {
        let data = &event["data"];
        let kind = event["type"].as_str().unwrap_or("");
        if !Self::observes(kind) {
            return Vec::new();
        }
        let Some(session) = data["sessionID"].as_str() else {
            return Vec::new();
        };
        if self
            .session
            .as_deref()
            .is_some_and(|selected| session != selected)
        {
            return Vec::new();
        }
        if matches!(
            kind,
            "session.execution.succeeded"
                | "session.execution.failed"
                | "session.execution.interrupted"
        ) {
            // SSE can still carry an earlier execution when resuming. Its
            // end is meaningful only after seeing this CLI's own message.
            self.ended |= self.observed_current;
            return Vec::new();
        }
        let Some(message) = data["assistantMessageID"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= 160)
        else {
            return Vec::new();
        };
        if self.limited {
            self.observed_current |= self.session.is_some() && self.messages.contains(message);
            return Vec::new();
        }
        if self.session.is_none() || !self.messages.contains(message) {
            let bytes = event.to_string().len();
            self.defer(event, bytes);
            return Vec::new();
        }
        self.observed_current = true;
        if matches!(kind, "session.tool.input.started" | "session.tool.called") {
            let Some(id) = data["id"]
                .as_str()
                .filter(|id| !id.is_empty() && id.len() <= 160)
            else {
                return Vec::new();
            };
            if kind == "session.tool.input.started" {
                if self.tools.len() < PART_CAP
                    && let Some(name) = data["name"]
                        .as_str()
                        .filter(|name| !name.is_empty() && name.len() <= 160)
                {
                    self.tools.insert(id.into(), name.into());
                }
            } else if self.started_tools.len() < PART_CAP
                && !self.started_tools.contains(id)
                && let Some(name) = self.tools.get(id)
            {
                self.started_tools.insert(id.into());
                return vec![
                    json!({"type":"tool_use","sessionID":session,"part":{"id":id,"tool":name,"state":{"status":"running","input":data["input"]}}}),
                ];
            }
            return Vec::new();
        }
        let (family, phase) = match kind {
            "session.text.started" => ("text", "start"),
            "session.text.delta" => ("text", "delta"),
            "session.text.ended" => ("text", "end"),
            "session.reasoning.started" => ("reasoning", "start"),
            "session.reasoning.delta" => ("reasoning", "delta"),
            "session.reasoning.ended" => ("reasoning", "end"),
            "session.step.ended" => {
                let mut value = json!({"type":"step_finish", "sessionID":session, "part":{"messageID":data["assistantMessageID"],"reason":data["finish"],"tokens":data["tokens"],"cost":data["cost"]}});
                normalize_step(&mut value);
                return vec![value];
            }
            _ => return Vec::new(),
        };
        let Some(message) = data["assistantMessageID"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= 160)
        else {
            return Vec::new();
        };
        let Some(ordinal) = data["ordinal"].as_u64() else {
            return Vec::new();
        };
        let key = stream_id(message, family, ordinal);
        if phase == "start" {
            if let Some(id) = event["id"]
                .as_str()
                .filter(|id| !id.is_empty() && id.len() <= 160)
                && self.parts.len() < PART_CAP
            {
                self.parts.insert(
                    format!("prt_{}", id.trim_start_matches("evt_")),
                    key.clone(),
                );
                self.admitted.insert(key);
            }
            return Vec::new();
        }
        if !self.admitted.contains(&key) {
            return Vec::new();
        }
        let text = if phase == "delta" {
            &data["delta"]
        } else {
            &data["text"]
        };
        vec![
            json!({"type":if phase == "delta" {"tokenstat.opencode.delta"} else {family},"sessionID":session,"tokenstatStream":key,"tokenstatNative":true,"thinking":family=="reasoning","part":{"text":text}}),
        ]
    }
}

fn normalize_step(value: &mut Value) {
    let part = &mut value["part"];
    if let Some(message) = part["messageID"]
        .as_str()
        .filter(|id| !id.is_empty() && id.len() <= 160)
        .map(str::to_owned)
    {
        if let Some(output) = part["tokens"]["output"].as_u64() {
            part["tokens"]["output"] =
                json!(output.saturating_add(part["tokens"]["reasoning"].as_u64().unwrap_or(0)));
        }
        value["tokenstatStep"] = json!(message);
    }
}
