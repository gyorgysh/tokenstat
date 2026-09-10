// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Readable conversation blocks using the same boundaries and archive-position
//! row identities as Apple's ChatDisplayItem.coalesce. Raw tool/approval payloads
//! are never search text. Inputs come from the bounded authorized store snapshot.

use serde_json::Value;

#[derive(Debug, PartialEq, Eq)]
pub struct Block {
    pub anchor: String,
    pub text: String,
}

#[derive(Default)]
struct Pending {
    anchor: Option<String>,
    text: String,
}

impl Pending {
    fn append(&mut self, record: &Value, prefix: &str, delta: &str) {
        if self.text.is_empty() {
            self.anchor = anchor(record, prefix);
        }
        self.text.push_str(delta);
    }

    fn flush(&mut self, blocks: &mut Vec<Block>) {
        let text = self.text.trim();
        if let Some(anchor) = self.anchor.take().filter(|_| !text.is_empty()) {
            blocks.push(Block {
                anchor,
                text: text.to_owned(),
            });
        }
        self.text.clear();
    }
}

fn anchor(record: &Value, prefix: &str) -> Option<String> {
    record
        .get("seq")?
        .as_u64()
        .map(|seq| format!("{prefix}-s{seq}"))
}

fn string<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

pub fn blocks(events: &[Value], default_backend: &str) -> Vec<Block> {
    let mut blocks = Vec::new();
    let mut text = Pending::default();
    let mut thinking = Pending::default();
    let mut last_backend: Option<&str> = None;
    for record in events {
        let kind = string(record, "kind").unwrap_or_default();
        if kind == "user" || kind == "handoff" {
            text.flush(&mut blocks);
            thinking.flush(&mut blocks);
            let field = if kind == "user" { "text" } else { "brief" };
            let body = string(record, field).unwrap_or_default();
            if let Some(anchor) = anchor(record, kind).filter(|_| !body.trim().is_empty()) {
                blocks.push(Block {
                    anchor,
                    text: body.to_owned(),
                });
            }
            if kind == "handoff" {
                last_backend = string(record, "to").or(last_backend);
            }
            continue;
        }
        if record.get("approval").is_some_and(|value| !value.is_null()) {
            text.flush(&mut blocks);
            thinking.flush(&mut blocks);
            continue;
        }
        let Some(agent) = record.get("event").filter(|value| value.is_object()) else {
            continue;
        };
        let backend = string(record, "backend").unwrap_or(default_backend);
        if last_backend.is_some_and(|previous| previous != backend) {
            text.flush(&mut blocks);
            thinking.flush(&mut blocks);
        }
        last_backend = Some(backend);
        match string(agent, "kind").unwrap_or_default() {
            "text" => {
                thinking.flush(&mut blocks);
                text.append(record, "text", string(agent, "delta").unwrap_or_default());
            }
            "thinking" => {
                text.flush(&mut blocks);
                thinking.append(record, "think", string(agent, "delta").unwrap_or_default());
            }
            "toolStart" | "toolEnd" | "edit" | "attachment" | "usage" | "failed" | "done" => {
                text.flush(&mut blocks);
                thinking.flush(&mut blocks);
            }
            _ => {}
        }
    }
    text.flush(&mut blocks);
    thinking.flush(&mut blocks);
    blocks
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn streamed_text_uses_first_record_anchor_and_display_boundaries() {
        let events = vec![
            json!({"seq":10,"kind":"user","text":"Question"}),
            json!({"seq":20,"kind":"agent","event":{"kind":"text","delta":"  Hello"}}),
            json!({"seq":30,"kind":"agent","event":{"kind":"session","id":"secret"}}),
            json!({"seq":40,"kind":"agent","event":{"kind":"text","delta":" world  "}}),
            json!({"seq":50,"kind":"agent","event":{"kind":"thinking","delta":"Think"}}),
            json!({"seq":60,"kind":"agent","event":{"kind":"thinking","delta":" more"}}),
            json!({"seq":70,"kind":"agent","event":{"kind":"toolStart","input":"secret"}}),
            json!({"seq":80,"kind":"agent","event":{"kind":"text","delta":"After"}}),
            json!({"seq":90,"kind":"agent","backend":"other","event":{"kind":"text","delta":"Changed"}}),
            json!({"seq":100,"kind":"handoff","to":"third","brief":"Context"}),
            json!({"seq":110,"kind":"approval","approval":{"text":"secret"}}),
        ];
        let actual: Vec<_> = blocks(&events, "default")
            .into_iter()
            .map(|b| (b.anchor, b.text))
            .collect();
        let expected: Vec<_> = [
            ("user-s10", "Question"),
            ("text-s20", "Hello world"),
            ("think-s50", "Think more"),
            ("text-s80", "After"),
            ("text-s90", "Changed"),
            ("handoff-s100", "Context"),
        ]
        .into_iter()
        .map(|(a, t)| (a.to_owned(), t.to_owned()))
        .collect();
        assert_eq!(actual, expected);
    }

    #[test]
    fn every_display_separator_splits_text_without_indexing_its_payload() {
        for kind in [
            "toolStart",
            "toolEnd",
            "edit",
            "attachment",
            "usage",
            "failed",
            "done",
        ] {
            let events = vec![
                json!({"seq":1,"kind":"agent","event":{"kind":"text","delta":"Before"}}),
                json!({"seq":2,"kind":"agent","event":{"kind":kind,"text":"private","patch":"private","detail":"private"}}),
                json!({"seq":3,"kind":"agent","event":{"kind":"text","delta":"After"}}),
            ];
            assert_eq!(
                blocks(&events, "default"),
                vec![
                    Block {
                        anchor: "text-s1".into(),
                        text: "Before".into()
                    },
                    Block {
                        anchor: "text-s3".into(),
                        text: "After".into()
                    },
                ],
                "{kind}"
            );
        }
    }

    #[test]
    fn missing_stable_positions_and_nonreadable_payloads_never_become_results() {
        let events = vec![
            json!({"kind":"user","text":"legacy"}),
            json!({"kind":"agent","event":{"kind":"text","delta":"legacy"}}),
            json!({"seq":20,"kind":"agent","event":{"kind":"text","delta":" continuation"}}),
            json!({"seq":30,"kind":"agent","event":{"kind":"done"}}),
            json!({"seq":40,"kind":"agent","event":{"kind":"failed","text":"private error"}}),
            json!({"seq":50,"kind":"agent","event":{"kind":"text","delta":""}}),
            json!({"seq":60,"kind":"agent","event":{"kind":"text","delta":"Valid"}}),
        ];
        assert_eq!(
            blocks(&events, "default"),
            vec![Block {
                anchor: "text-s60".into(),
                text: "Valid".into()
            }]
        );
    }
}
