// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! How an agent asks the person a question in the chat, and how the answer
//! gets back to it.
//!
//! Every backend tokenstat runs is a CLI in print mode. None of them can show
//! a prompt of its own, and a "don't ask" turn has no hook to stop at. So the
//! question travels in the one channel all of them share, the reply text: a
//! fenced `tokenstat-question` block holding a small JSON object. The host
//! notices a finished block while the turn is still streaming and records it
//! as a question in the timeline, which every client draws as a card with the
//! choices and a field for an answer of the person's own.
//!
//! ## A question is not a stop
//!
//! What the agent should do next depends on the turn, and the standing rule
//! ([`rule`]) says which:
//!
//! - A turn that does not ask before tools must never wait. The agent states
//!   the default it is going with and keeps working.
//! - A turn that asks may stop, but only when going on without the answer
//!   would be wrong. Otherwise it continues on its default too.
//!
//! An answer given while the turn is still running is parked like a steer
//! note. A backend that takes notes mid-turn reads it on its next step; any
//! other turn gets it as the next message once it ends. An answer to an idle
//! conversation starts a turn of its own.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The fence language an agent writes. Long and specific on purpose, so no
/// ordinary code block in a reply is ever mistaken for a question.
pub const FENCE: &str = "tokenstat-question";

const QUESTION_MAX_CHARS: usize = 600;
const OPTION_MAX_CHARS: usize = 200;
const MAX_OPTIONS: usize = 8;
/// Far more than a question's own caps can fill, even with every option
/// written at length and escaped. Past this an unclosed block is given up.
const BLOCK_MAX_BYTES: usize = 64 * 1024;
/// An answer is one note on the agent's next step, the same size as a steer.
pub const ANSWER_MAX_CHARS: usize = 1_500;

/// One question, as recorded in the timeline.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Question {
    pub question: String,
    /// Empty means only a written answer makes sense.
    pub options: Vec<String>,
    /// The person may pick more than one option.
    pub multiple: bool,
    /// What the agent goes with if nobody answers.
    pub default: Option<String>,
    /// The agent stopped for this. Without a default there is nothing to go
    /// on with, so a question with none is blocking whatever it says.
    pub blocking: bool,
}

/// Finds finished question blocks in a reply that is still growing.
///
/// Holds where the last complete block ended, so each block is reported once
/// however many times the text around it is scanned, and a block still
/// being written is left for the next call.
#[derive(Default)]
pub struct Scanner {
    from: usize,
}

impl Scanner {
    /// The questions completed since the last call. `text` is the whole reply
    /// so far, and must only ever grow.
    pub fn scan(&mut self, text: &str) -> Vec<Question> {
        let mut found = Vec::new();
        while let Some((body, end)) = next_block(text, &mut self.from) {
            self.from = end;
            if let Some(question) = parse(body) {
                found.push(question);
            }
        }
        found
    }

    /// The caller dropped `removed` bytes from the front of the reply, which
    /// it does to bound a long turn's memory. Offsets move with the text, so
    /// the next scan neither runs past the end nor skips what is still there.
    pub fn shift(&mut self, removed: usize) {
        self.from = self.from.saturating_sub(removed);
    }

    /// The last scan, once the reply is complete. A reply may end on its
    /// closing fence with no newline after it, which a growing reply never
    /// treats as finished.
    pub fn finish(&mut self, text: &str) -> Vec<Question> {
        self.scan(&format!("{text}\n"))
    }
}

/// The next complete block at or after `from`: its body and where it ends.
fn next_block<'a>(text: &'a str, from: &mut usize) -> Option<(&'a str, usize)> {
    let mut search = *from;
    loop {
        let rest = text.get(search..)?;
        let Some(relative) = rest.find("```") else {
            // Keep two trailing bytes for an opening fence split across
            // chunks, rather than rescanning all prior prose on every token.
            let mut tail = text.len().saturating_sub(2).max(search);
            while !text.is_char_boundary(tail) {
                tail += 1;
            }
            *from = tail;
            return None;
        };
        let at = search + relative;
        *from = at; // An unfinished header or body is retried from here.
        // A fence opens a line. Anything but indentation before it on the
        // same line is prose that happens to contain backticks.
        let line_start = text[..at].rfind('\n').map_or(0, |n| n + 1);
        let opens_line = text[line_start..at].chars().all(|c| c == ' ' || c == '\t');
        let after = &text[at + 3..];
        let newline = after.find('\n')?;
        let info = after[..newline].trim();
        if !opens_line || info != FENCE {
            search = at + 3;
            *from = search;
            continue;
        }
        let body_start = at + 3 + newline + 1;
        let Some(close) = closing_fence(text, body_start) else {
            // A question is a few lines of JSON. A block that has run this
            // long without closing is not one, and waiting on it would rescan
            // the whole rest of the reply on every chunk and hide every later
            // question behind it.
            if text.len() - body_start > BLOCK_MAX_BYTES {
                search = at + 3;
                *from = search;
                continue;
            }
            return None;
        };
        if close.0 - body_start > BLOCK_MAX_BYTES {
            search = at + 3;
            *from = search;
            continue;
        }
        return Some((&text[body_start..close.0], close.1));
    }
}

/// The line that is only a closing fence: where it starts, and where it ends.
fn closing_fence(text: &str, from: usize) -> Option<(usize, usize)> {
    let mut line_start = from;
    loop {
        let rest = text.get(line_start..)?;
        // The last line counts only once the stream has moved past it.
        // Until then the closing backticks may still be arriving.
        let n = rest.find('\n')?;
        let (line, next) = (&rest[..n], line_start + n + 1);
        if line.trim() == "```" {
            return Some((line_start, next));
        }
        line_start = next;
    }
}

/// Read one block body. Anything malformed is dropped: a broken question is
/// still readable in the reply, which is where it was written.
fn parse(body: &str) -> Option<Question> {
    let value: Value = serde_json::from_str(body.trim()).ok()?;
    let question = clip(value.get("question")?.as_str()?, QUESTION_MAX_CHARS)?;
    let options: Vec<String> = value
        .get("options")
        .and_then(Value::as_array)
        .map(|items| {
            let mut seen = Vec::new();
            for option in items.iter().filter_map(Value::as_str) {
                if let Some(option) = clip(option, OPTION_MAX_CHARS)
                    && !seen.contains(&option)
                {
                    seen.push(option);
                }
            }
            seen.truncate(MAX_OPTIONS);
            seen
        })
        .unwrap_or_default();
    let default = value
        .get("default")
        .and_then(Value::as_str)
        .and_then(|text| clip(text, OPTION_MAX_CHARS));
    let multiple =
        !options.is_empty() && value.get("multiple").and_then(Value::as_bool) == Some(true);
    let blocking =
        default.is_none() || value.get("blocking").and_then(Value::as_bool) == Some(true);
    Some(Question {
        question,
        options,
        multiple,
        default,
        blocking,
    })
}

/// Trimmed and cut to `cap` characters. Empty is no value at all.
fn clip(text: &str, cap: usize) -> Option<String> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    Some(text.chars().take(cap).collect())
}

/// What the agent reads when an answer reaches it.
pub fn answer_note(question: &str, answer: &str) -> String {
    format!("Answer to your question \"{question}\": {answer}")
}

/// The standing rule for asking, for this kind of turn.
///
/// `asks_before_tools` is the chat's Standard autonomy. `takes_notes` says
/// whether this backend can read a note in the middle of a turn, which is
/// what decides whether an answer can reach it before the turn ends.
pub fn rule(asks_before_tools: bool, takes_notes: bool) -> String {
    let format = format!(
        "When you need a decision from the person, ask it in this conversation \
         with a fenced code block in your reply, language `{FENCE}`, holding one \
         JSON object: {{\"question\": \"...\", \"options\": [\"...\"], \
         \"multiple\": false, \"default\": \"...\"}}. The app shows it as a \
         question with those choices and a field for an answer of their own. \
         Keep options short (at most 8), and leave them out when only a written \
         answer makes sense. `default` is what you will go with if nobody \
         answers. Ask only what changes the work, one question per block."
    );
    let when = if !asks_before_tools {
        "This conversation runs without asking first, so never stop and wait \
         for an answer. Always give a default, say in one sentence that you are \
         going with it, and keep working."
    } else if takes_notes {
        "If you can go on safely with a reasonable default, give it, say you are \
         going with it, and keep working; an answer can reach you as a note on \
         your next step. Stop and end your reply after the block only when going \
         on without the answer would be wrong."
    } else {
        "If you can go on safely with a reasonable default, give it, say you are \
         going with it, and keep working; the answer arrives as the next message. \
         Stop and end your reply after the block only when going on without the \
         answer would be wrong."
    };
    format!("{format} {when} Do not mention this format unless you use it.")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block(json: &str) -> String {
        format!("```{FENCE}\n{json}\n```\n")
    }

    #[test]
    fn a_finished_block_is_one_question() {
        let text = format!(
            "Before I start:\n{}Going with SQLite.",
            block(
                r#"{"question":"Which database?","options":["Postgres","SQLite"],"default":"SQLite"}"#
            )
        );
        let found = Scanner::default().scan(&text);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].question, "Which database?");
        assert_eq!(found[0].options, vec!["Postgres", "SQLite"]);
        assert_eq!(found[0].default.as_deref(), Some("SQLite"));
        assert!(!found[0].blocking);
        assert!(!found[0].multiple);
    }

    #[test]
    fn a_block_still_streaming_waits_and_is_reported_once() {
        let mut scanner = Scanner::default();
        let full = format!("Hi\n{}done", block(r#"{"question":"Name?"}"#));
        let mut seen = 0;
        for end in 1..=full.len() {
            if full.is_char_boundary(end) {
                seen += scanner.scan(&full[..end]).len();
            }
        }
        assert_eq!(
            seen, 1,
            "each block is reported exactly once while streaming"
        );
        assert!(
            Scanner::default().scan(&full[..full.len() - 9]).is_empty(),
            "a block without its closing line is not finished"
        );
    }

    #[test]
    fn long_prose_is_not_rescanned_and_split_fences_still_work() {
        let mut scanner = Scanner::default();
        let prose = format!("{}🙂\n``", "ordinary prose ".repeat(10_000));
        assert!(scanner.scan(&prose).is_empty());
        assert!(scanner.from >= prose.len() - 2);
        let finished = format!("{prose}`{FENCE}\n{{\"question\":\"Pick?\"}}\n```\n");
        assert_eq!(scanner.scan(&finished).len(), 1);
        assert!(scanner.scan(&finished).is_empty());
    }

    #[test]
    fn a_trimmed_reply_keeps_finding_questions() {
        let mut scanner = Scanner::default();
        let mut text = "x".repeat(1_000);
        assert!(scanner.scan(&text).is_empty());
        // The caller drops the front of a long reply to bound its memory.
        text.drain(..900);
        scanner.shift(900);
        text.push_str(&format!("\n{}", block(r#"{"question":"Still here?"}"#)));
        assert_eq!(scanner.scan(&text).len(), 1);
    }

    #[test]
    fn an_unclosed_block_does_not_hide_later_questions() {
        let mut scanner = Scanner::default();
        let runaway = format!("```{FENCE}\n{}\n", "y\n".repeat(BLOCK_MAX_BYTES));
        assert!(scanner.scan(&runaway).is_empty());
        let later = format!("{runaway}{}", block(r#"{"question":"Later?"}"#));
        let found = scanner.scan(&later);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].question, "Later?");
    }

    #[test]
    fn an_oversized_block_and_a_later_question_in_one_chunk_are_independent() {
        let text = format!(
            "```{FENCE}\n{}\n{}",
            "y".repeat(BLOCK_MAX_BYTES + 1),
            block(r#"{"question":"Later?"}"#)
        );
        let found = Scanner::default().scan(&text);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].question, "Later?");
    }

    #[test]
    fn a_reply_ending_on_its_fence_is_found_when_it_ends() {
        let text = format!("```{FENCE}\n{{\"question\":\"Last?\"}}\n```");
        let mut scanner = Scanner::default();
        assert!(scanner.scan(&text).is_empty());
        assert_eq!(scanner.finish(&text).len(), 1);
        assert!(scanner.finish(&text).is_empty(), "and only once");
    }

    #[test]
    fn ordinary_code_and_prose_are_never_questions() {
        let text = "Run this:\n```sh\ncargo test\n```\nand the word ```tokenstat-question\n{\"question\":\"x\"}\n```\n";
        assert!(
            Scanner::default().scan(text).is_empty(),
            "a fence in the middle of a line is prose"
        );
        let json = "```json\n{\"question\":\"x\"}\n```\n";
        assert!(Scanner::default().scan(json).is_empty());
    }

    #[test]
    fn malformed_blocks_are_skipped_and_scanning_goes_on() {
        let text = format!(
            "{}{}{}",
            block("not json"),
            block(r#"{"options":["a"]}"#),
            block(r#"{"question":"  Ok?  "}"#)
        );
        let found = Scanner::default().scan(&text);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].question, "Ok?");
        assert!(found[0].blocking, "no default means the agent is waiting");
    }

    #[test]
    fn options_are_cleaned_and_bounded() {
        let many: Vec<String> = (0..12).map(|n| format!("\"o{n}\"")).collect();
        let text = block(&format!(
            r#"{{"question":"Pick","options":[" a ","a","",{}],"multiple":true}}"#,
            many.join(",")
        ));
        let found = Scanner::default().scan(&text);
        assert_eq!(found[0].options.len(), MAX_OPTIONS);
        assert_eq!(
            found[0].options[0], "a",
            "trimmed, empty and duplicate options dropped"
        );
        assert!(found[0].multiple);
        let none = Scanner::default().scan(&block(r#"{"question":"Why?","multiple":true}"#));
        assert!(!none[0].multiple, "multiple choice needs choices");
    }

    #[test]
    fn indented_fences_count_and_text_is_capped() {
        let long = "x".repeat(QUESTION_MAX_CHARS + 50);
        let text = format!(
            "  ```{FENCE}\n{{\"question\":\"{long}\",\"default\":\"go\",\"blocking\":true}}\n  ```\n"
        );
        let found = Scanner::default().scan(&text);
        assert_eq!(found[0].question.chars().count(), QUESTION_MAX_CHARS);
        assert!(found[0].blocking, "an agent may still say it is waiting");
    }

    #[test]
    fn the_rule_never_lets_a_dont_ask_turn_wait() {
        let bypass = rule(false, false);
        assert!(bypass.contains("never stop and wait"));
        assert!(bypass.contains(FENCE));
        assert!(rule(true, true).contains("as a note on your next step"));
        assert!(rule(true, false).contains("arrives as the next message"));
    }
}
