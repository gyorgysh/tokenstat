// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{SourceEq, fields_eq, has_prefix, trim_space};
use crate::work::text;
use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Question {
    pub id: String,
    pub question: String,
    pub options: Vec<String>,
    pub multiple: bool,
    pub default_answer: Option<String>,
    pub blocking: bool,
    pub answer: Option<String>,
    pub delivery: Option<String>,
}
fields_eq!(Question;id,question,options,multiple,default_answer,blocking,answer,delivery);
pub const FENCE: &str = "tokenstat-question";
pub const BLOCK_MAX_BYTES: usize = 64 * 1024;
pub fn stripping(body: &str, streaming: bool) -> String {
    if !body.contains(FENCE) {
        return body.into();
    }
    let lines = body.split('\n').collect::<Vec<_>>();
    let mut kept = vec![];
    let mut inside = false;
    let mut block = vec![];
    let mut bytes = 0;
    for (i, line) in lines.iter().enumerate() {
        let trimmed = text::trim(line);
        if !inside && has_prefix(trimmed, "```") && text::equal(trim_space(&trimmed[3..]), FENCE) {
            inside = true;
            block = vec![*line];
            bytes = 0;
            continue;
        }
        if inside {
            block.push(*line);
            if trimmed == "```" {
                let value = block[1..block.len() - 1].join("\n");
                let valid = value.len() < BLOCK_MAX_BYTES
                    && serde_json::from_str::<serde_json::Value>(&value)
                        .ok()
                        .and_then(|v| {
                            v.get("question")
                                .and_then(|v| v.as_str())
                                .map(|q| !text::trim(q).is_empty())
                        })
                        .unwrap_or(false);
                if !valid {
                    kept.append(&mut block);
                }
                block.clear();
                inside = false;
            } else {
                bytes += line.len() + usize::from(i < lines.len() - 1);
                if bytes > BLOCK_MAX_BYTES {
                    kept.append(&mut block);
                    block.clear();
                    inside = false;
                }
            }
            continue;
        }
        kept.push(line);
    }
    if !streaming {
        kept.append(&mut block);
    }
    text::trim(&kept.join("\n").replace("\n\n\n", "\n\n")).into()
}
