// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
use super::{Prefix, delta_event, identity};
use crate::transcript::Event;
use serde_json::Value;
use std::collections::{HashMap, VecDeque};

const CAP: usize = 256;

#[derive(Default)]
struct Part {
    prefix: Prefix,
    complete: bool,
}

#[derive(Default)]
pub(super) struct Parts {
    parts: HashMap<String, Part>,
    completed: VecDeque<String>,
    steps: VecDeque<String>,
}

impl Parts {
    fn part(&mut self, id: &str) -> Option<&mut Part> {
        if !self.parts.contains_key(id) {
            while self.parts.len() >= CAP {
                self.parts.remove(&self.completed.pop_front()?);
            }
        }
        Some(self.parts.entry(id.into()).or_default())
    }

    pub(super) fn observe(&mut self, value: &mut Value) -> Option<Vec<Event>> {
        if value["type"] == "step_finish"
            && let Some(id) = identity(&value["tokenstatStep"])
        {
            if self.steps.iter().any(|seen| seen == id) {
                value["type"] = Value::String("tokenstat.opencode.duplicate".into());
                return Some(Vec::new());
            }
            if self.steps.len() == CAP {
                self.steps.pop_front();
            }
            self.steps.push_back(id.into());
        }
        let partial = value["type"] == "tokenstat.opencode.delta";
        let thinking = value["type"] == "reasoning" || value["thinking"] == true;
        if !partial && !matches!(value["type"].as_str(), Some("text" | "reasoning")) {
            return None;
        }
        let id = identity(&value["tokenstatStream"])?;
        let text = value["part"]["text"].as_str()?;
        let native = value["tokenstatNative"] == true;
        let Some(part) = self.part(id) else {
            return (partial || native).then(Vec::new);
        };
        if partial {
            if part.complete {
                return Some(Vec::new());
            }
            part.prefix.observe(text);
            return Some(delta_event(text, thinking));
        }
        let remainder = part.prefix.remainder(text).to_string();
        part.prefix = Prefix::default();
        part.prefix.observe(text);
        if !part.complete {
            part.complete = true;
            self.completed.push_back(id.into());
        }
        value["part"]["text"] = Value::String(remainder);
        None
    }
}
