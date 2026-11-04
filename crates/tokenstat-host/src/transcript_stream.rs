// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Normalize partial provider text before the existing transcript parser.
//! Only ordinary text/thinking events reach clients; completed records still
//! carry tools, usage, images and inspection metadata.

use std::collections::HashMap;

use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::transcript::Event;

#[derive(Default)]
struct Prefix {
    bytes: usize,
    hash: Sha256,
}

impl Prefix {
    fn observe(&mut self, delta: &str) {
        self.bytes = self.bytes.saturating_add(delta.len());
        self.hash.update(delta.as_bytes());
    }

    fn remainder<'a>(&self, text: &'a str) -> &'a str {
        // Keep a digest rather than another copy of potentially large output.
        // A corrected or otherwise inconsistent final snapshot stays visible.
        match text.get(..self.bytes) {
            Some(prefix) if Sha256::digest(prefix.as_bytes()) == self.hash.clone().finalize() => {
                &text[self.bytes..]
            }
            _ => text,
        }
    }
}

#[derive(Default)]
struct ClaudeMessage {
    blocks: HashMap<u64, Prefix>,
    current_block: Option<u64>,
    stopped: bool,
}

#[derive(Default)]
pub(crate) struct Streams {
    // Claude's partial envelopes carry the parent tool id, while the final
    // assistant record identifies its message directly.
    claude_active: HashMap<String, String>,
    claude: HashMap<String, ClaudeMessage>,
    codex: HashMap<String, Prefix>,
}

const MAX_MESSAGES: usize = 128;
const MAX_BLOCKS: u64 = 128;

fn identity(value: &Value) -> Option<&str> {
    value
        .as_str()
        .filter(|id| !id.is_empty() && id.len() <= 256)
}

fn delta_event(text: &str, thinking: bool) -> Vec<Event> {
    if text.is_empty() {
        Vec::new()
    } else if thinking {
        vec![Event::Thinking { delta: text.into() }]
    } else {
        vec![Event::Text { delta: text.into() }]
    }
}

impl Streams {
    /// Returns events for a partial record. For final records, removes only
    /// the text already emitted and lets the normal parser handle the rest.
    pub(crate) fn observe(&mut self, backend: &str, value: &mut Value) -> Option<Vec<Event>> {
        match backend {
            "claude" => self.claude(value),
            "codex" => self.codex(value),
            _ => None,
        }
    }

    fn claude(&mut self, value: &mut Value) -> Option<Vec<Event>> {
        if value["type"] == "stream_event" {
            let event = &value["event"];
            let parent = value["parent_tool_use_id"].as_str().unwrap_or("");
            if parent.len() > 256 {
                return Some(Vec::new());
            }
            match event["type"].as_str() {
                Some("message_start") => {
                    self.claude_active.remove(parent);
                    if let Some(id) = identity(&event["message"]["id"])
                        && self.claude.len() < MAX_MESSAGES
                        && self.claude_active.len() < MAX_MESSAGES
                    {
                        self.claude.entry(id.into()).or_default();
                        self.claude_active.insert(parent.into(), id.into());
                    }
                }
                Some("content_block_start" | "content_block_delta") => {
                    let id = self.claude_active.get(parent)?;
                    let message = self.claude.get_mut(id)?;
                    let index = event["index"].as_u64()?;
                    message.current_block = Some(index);
                    if index >= MAX_BLOCKS {
                        return Some(Vec::new());
                    }
                    let block = if event["type"] == "content_block_start" {
                        &event["content_block"]
                    } else {
                        &event["delta"]
                    };
                    let thinking =
                        matches!(block["type"].as_str(), Some("thinking" | "thinking_delta"));
                    let text = match block["type"].as_str() {
                        Some("text" | "text_delta") => block["text"].as_str(),
                        Some("thinking" | "thinking_delta") => block["thinking"].as_str(),
                        _ => None,
                    }?;
                    message.blocks.entry(index).or_default().observe(text);
                    return Some(delta_event(text, thinking));
                }
                Some("message_stop") => {
                    if let Some(id) = self.claude_active.remove(parent)
                        && let Some(message) = self.claude.get_mut(&id)
                    {
                        message.stopped = true;
                        if message.blocks.is_empty() {
                            self.claude.remove(&id);
                        }
                    }
                }
                _ => {}
            }
            return Some(Vec::new());
        }
        if value["type"] == "assistant"
            && let Some(id) = identity(&value["message"]["id"]).map(str::to_owned)
            && let Some(message) = self.claude.get_mut(&id)
            && let Some(content) = value["message"]["content"].as_array_mut()
        {
            // Claude emits one assistant record per completed block, before
            // content_block_stop. Its single-element content array does not
            // carry the original block index. Older full snapshots use array
            // indices instead. Keep the other blocks until message_stop.
            let single_index = (content.len() == 1)
                .then_some(message.current_block)
                .flatten();
            for (index, block) in content.iter_mut().enumerate() {
                let index = single_index.unwrap_or(index as u64);
                let key = match block["type"].as_str() {
                    Some("thinking") => "thinking",
                    Some("text") => "text",
                    _ => continue,
                };
                if let Some(prefix) = message.blocks.remove(&index)
                    && let Some(text) = block[key].as_str()
                {
                    block[key] = Value::String(prefix.remainder(text).into());
                }
            }
            if message.stopped && message.blocks.is_empty() {
                self.claude.remove(&id);
            }
        }
        None
    }

    fn codex(&mut self, value: &mut Value) -> Option<Vec<Event>> {
        if value["type"] == "item.delta" && value["item"]["type"] == "agent_message" {
            let id = identity(&value["item"]["id"])?;
            let text = value["item"]["text"].as_str()?;
            if !self.codex.contains_key(id) && self.codex.len() >= MAX_MESSAGES {
                return Some(Vec::new());
            }
            self.codex.entry(id.into()).or_default().observe(text);
            return Some(delta_event(text, false));
        }
        if value["type"] == "item.completed"
            && value["item"]["type"] == "agent_message"
            && let Some(id) = identity(&value["item"]["id"])
            && let Some(prefix) = self.codex.remove(id)
            && let Some(text) = value["item"]["text"].as_str()
            && crate::transcript::codex_rejection(Some(text)).is_none()
        {
            value["item"]["text"] = Value::String(prefix.remainder(text).into());
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::Parser;
    use serde_json::json;

    fn feed(parser: &mut Parser, value: Value) -> Vec<Event> {
        parser.push_events(format!("{value}\n").as_bytes())
    }

    fn text(events: &[Event]) -> String {
        events
            .iter()
            .filter_map(|event| match event {
                Event::Text { delta } => Some(delta.as_str()),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn claude_partial_text_precedes_completion_and_final_keeps_tools() {
        let mut p = Parser::new("claude");
        feed(
            &mut p,
            json!({"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}),
        );
        let mut result = String::new();
        for delta in ["Hello", " ", "🌍"] {
            let events = feed(
                &mut p,
                json!({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":delta}}}),
            );
            assert_eq!(text(&events), delta);
            result.push_str(&text(&events));
        }
        let final_events = feed(
            &mut p,
            json!({"type":"assistant","message":{"id":"m1","content":[
                {"type":"text","text":"Hello 🌍!"},
                {"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"a.txt"}}
            ]}}),
        );
        assert_eq!(text(&final_events), "!");
        assert!(
            final_events
                .iter()
                .any(|e| matches!(e, Event::ToolStart { call_id, .. } if call_id == "tool-1"))
        );
        result.push_str(&text(&final_events));
        let final_result = feed(
            &mut p,
            json!({"type":"result","result":"Hello 🌍!","usage":{"input_tokens":3,"output_tokens":2}}),
        );
        assert!(text(&final_result).is_empty());
        assert!(
            final_result
                .iter()
                .any(|e| matches!(e, Event::Usage { .. }))
        );
        assert_eq!(result, "Hello 🌍!");
    }

    #[test]
    fn claude_interleaved_messages_and_thinking_keep_their_own_prefixes() {
        let mut p = Parser::new("claude");
        for (parent, id, text) in [
            (Value::Null, "main", "main"),
            (json!("tool"), "child", "child"),
        ] {
            feed(
                &mut p,
                json!({"type":"stream_event","parent_tool_use_id":parent,"event":{"type":"message_start","message":{"id":id}}}),
            );
            assert_eq!(text_for(&mut p, parent, text), text);
        }
        let thinking = feed(
            &mut p,
            json!({"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"Considering"}}}),
        );
        assert!(matches!(&thinking[..], [Event::Thinking { delta }] if delta == "Considering"));
        for (id, full) in [("child", "child"), ("main", "main")] {
            let events = feed(
                &mut p,
                json!({"type":"assistant","message":{"id":id,"content":[{"type":"text","text":full},{"type":"thinking","thinking":"Considering"}]}}),
            );
            assert!(text(&events).is_empty());
            if id == "main" {
                assert!(!events.iter().any(|e| matches!(e, Event::Thinking { .. })));
            }
        }
        fn text_for(p: &mut Parser, parent: Value, delta: &str) -> String {
            text(&feed(
                p,
                json!({"type":"stream_event","parent_tool_use_id":parent,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":delta}}}),
            ))
        }
    }

    #[test]
    fn claude_completes_each_block_separately_with_the_same_message_id() {
        let mut p = Parser::new("claude");
        // More messages than the bound also verifies normal streams release
        // their state, rather than eventually falling back to buffered text.
        for n in 0..MAX_MESSAGES + 1 {
            let id = format!("message-{n}");
            feed(
                &mut p,
                json!({"type":"stream_event","event":{"type":"message_start","message":{"id":id}}}),
            );
            for (index, kind, key, delta_kind, value) in [
                (0, "thinking", "thinking", "thinking_delta", "Considering"),
                (1, "text", "text", "text_delta", "Hello 🌍"),
                (3, "text", "text", "text_delta", "Again"),
            ] {
                feed(
                    &mut p,
                    json!({"type":"stream_event","event":{"type":"content_block_start","index":index,"content_block":{"type":kind,key:""}}}),
                );
                let partial = feed(
                    &mut p,
                    json!({"type":"stream_event","event":{"type":"content_block_delta","index":index,"delta":{"type":delta_kind,key:value}}}),
                );
                assert_eq!(partial.len(), 1);
                let final_events = feed(
                    &mut p,
                    json!({"type":"assistant","message":{"id":id,"content":[{"type":kind,key:value}]}}),
                );
                assert!(
                    !final_events
                        .iter()
                        .any(|e| matches!(e, Event::Text { .. } | Event::Thinking { .. }))
                );
                feed(
                    &mut p,
                    json!({"type":"stream_event","event":{"type":"content_block_stop","index":index}}),
                );
                if index == 1 {
                    feed(
                        &mut p,
                        json!({"type":"stream_event","event":{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tool","name":"Read","input":{}}}}),
                    );
                    let tool = feed(
                        &mut p,
                        json!({"type":"assistant","message":{"id":id,"content":[{"type":"tool_use","id":"tool","name":"Read","input":{"file_path":"a.txt"}}]}}),
                    );
                    assert!(tool.iter().any(|e| matches!(e, Event::ToolStart { .. })));
                    feed(
                        &mut p,
                        json!({"type":"stream_event","event":{"type":"content_block_stop","index":2}}),
                    );
                }
            }
            feed(
                &mut p,
                json!({"type":"stream_event","event":{"type":"message_stop"}}),
            );
        }
    }

    #[test]
    fn codex_deltas_keep_spaces_and_do_not_repeat_final_snapshots() {
        let mut p = Parser::new("codex");
        for delta in ["Hello", " ", "🌍"] {
            assert_eq!(
                text(&feed(
                    &mut p,
                    json!({"type":"item.delta","item":{"type":"agent_message","id":"one","text":delta}})
                )),
                delta
            );
        }
        assert_eq!(
            text(&feed(
                &mut p,
                json!({"type":"item.completed","item":{"type":"agent_message","id":"one","text":"Hello 🌍!"}})
            )),
            "!"
        );
        // Older exec versions emit no deltas; a new message with identical
        // text must also remain a new message.
        assert_eq!(
            text(&feed(
                &mut p,
                json!({"type":"item.completed","item":{"type":"agent_message","id":"two","text":"Hello 🌍!"}})
            )),
            "Hello 🌍!"
        );
    }

    #[test]
    fn streaming_survives_fragmented_utf8_and_preserves_final_whitespace() {
        for (backend, records) in [
            (
                "codex",
                vec![
                    json!({"type":"item.delta","item":{"type":"agent_message","id":"one","text":"Hi 🌍"}}),
                    json!({"type":"item.completed","item":{"type":"agent_message","id":"one","text":"Hi 🌍 \n"}}),
                ],
            ),
            (
                "claude",
                vec![
                    json!({"type":"stream_event","event":{"type":"message_start","message":{"id":"one"}}}),
                    json!({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi 🌍"}}}),
                    // Some adapters close the stream before its final snapshot.
                    json!({"type":"stream_event","event":{"type":"message_stop"}}),
                    json!({"type":"assistant","message":{"id":"one","content":[{"type":"text","text":"Hi 🌍 \n"}]}}),
                ],
            ),
        ] {
            let bytes = records
                .iter()
                .map(Value::to_string)
                .collect::<Vec<_>>()
                .join("\r\n");
            for width in [1, 2, 7, 31, bytes.len()] {
                let mut parser = Parser::new(backend);
                let mut events = Vec::new();
                for chunk in bytes.as_bytes().chunks(width) {
                    events.extend(parser.push_events(chunk));
                }
                events.extend(parser.finish_events());
                assert_eq!(text(&events), "Hi 🌍 \n", "{backend}: {width}");
            }
        }
    }

    #[test]
    fn prefix_keeps_inconsistent_final_text() {
        let mut prefix = Prefix::default();
        prefix.observe("Hi 🌍");
        assert_eq!(prefix.remainder("Hi 🌍!"), "!");
        assert_eq!(prefix.remainder("Hi"), "Hi");
        assert_eq!(prefix.remainder("Other"), "Other");
    }

    #[test]
    fn excess_unfinished_messages_fall_back_to_complete_output() {
        let mut p = Parser::new("codex");
        for n in 0..MAX_MESSAGES {
            assert_eq!(
                text(&feed(
                    &mut p,
                    json!({"type":"item.delta","item":{"type":"agent_message","id":n.to_string(),"text":"x"}})
                )),
                "x"
            );
        }
        assert!(text(&feed(&mut p, json!({"type":"item.delta","item":{"type":"agent_message","id":"overflow","text":"new"}}))).is_empty());
        assert_eq!(
            text(&feed(
                &mut p,
                json!({"type":"item.completed","item":{"type":"agent_message","id":"overflow","text":"new message"}})
            )),
            "new message"
        );
    }
}
