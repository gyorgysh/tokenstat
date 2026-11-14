// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! One visible plan format for every agent.
//!
//! Codex and Claude Code in the modes tokenstat runs have no plan tool:
//! Codex's plan tool is off in exec and app-server turns, and Claude Code's
//! print mode offers neither TodoWrite nor its task tools, not even through a
//! tool search. So their plans never reached the chat. They write one the same
//! way every backend asks a question: a fenced block in the reply, language
//! `tokenstat-plan`, holding the whole list each time.
//!
//! The host records completed blocks as timeline updates and keeps the latest
//! plan in the conversation's activity. Clients hide the raw blocks.
//!
//! Every other agent writes the block too. Several have a todo tool the host
//! can read, but pointing each at its own tool failed in practice: OpenCode's
//! headless run offers none, Cursor never called its own, and a plan split
//! across a tool and prose looked different from agent to agent.

use serde_json::{Value, json};

/// The fence language an agent writes. Specific on purpose, like the
/// question fence, so no ordinary code block is ever read as a plan.
pub const FENCE: &str = "tokenstat-plan";

const STEP_MAX_CHARS: usize = 1000;
const MAX_STEPS: usize = 128;

/// Finds finished plan blocks in a reply that is still growing.
#[derive(Default)]
pub struct Scanner {
    from: usize,
}

impl Scanner {
    /// The newest plan completed since the last call, as `[{text, status}]`
    /// ready for the activity record. A later block replaces an earlier one,
    /// so only the last complete block in this stretch of text matters.
    pub fn scan(&mut self, text: &str) -> Option<Value> {
        self.scan_all(text).pop()
    }

    /// Preserve every completed update when several arrive in one read.
    pub fn scan_all(&mut self, text: &str) -> Vec<Value> {
        self.scan_positions(text)
            .into_iter()
            .map(|(plan, _)| plan)
            .collect()
    }

    /// Include the end of each fence so text in one provider event can still
    /// be interleaved with the plan updates it contains.
    pub fn scan_positions(&mut self, text: &str) -> Vec<(Value, usize)> {
        let mut plans = Vec::new();
        while let Some((body, end)) = crate::chat_question::next_block(text, &mut self.from, FENCE)
        {
            self.from = end;
            if let Some(plan) = parse(body) {
                plans.push((plan, end));
            }
        }
        plans
    }

    /// See `chat_question::Scanner::shift`.
    pub fn shift(&mut self, removed: usize) {
        self.from = self.from.saturating_sub(removed);
    }

    /// See `chat_question::Scanner::finish`.
    pub fn finish(&mut self, text: &str) -> Option<Value> {
        self.scan(&format!("{text}\n"))
    }
}

/// One block body. Accepts `step` (the name Codex's own plan tool used) or
/// `text` for each entry. Anything malformed is dropped.
fn parse(body: &str) -> Option<Value> {
    let value: Value = serde_json::from_str(body.trim()).ok()?;
    let steps = value.get("steps")?.as_array()?;
    let steps: Vec<Value> = steps
        .iter()
        .take(MAX_STEPS)
        .filter_map(|step| {
            let text = step
                .get("step")
                .or_else(|| step.get("text"))?
                .as_str()?
                .trim();
            if text.is_empty() {
                return None;
            }
            let text: String = text.chars().take(STEP_MAX_CHARS).collect();
            Some(
                json!({"text": text, "status": step.get("status").cloned().unwrap_or(Value::Null)}),
            )
        })
        .collect();
    Some(Value::Array(steps))
}

/// How an agent keeps a visible plan. Every agent writes the same block,
/// including those with a todo tool of their own: pointing each at its own
/// tool meant a missing tool (OpenCode's headless run has none) or a half
/// used one left the chat with no plan. The host still reads a todo tool
/// into the same card when an agent calls one anyway.
pub fn rule(backend: &str) -> Option<String> {
    // A plain shell is not an agent.
    (backend != "sh").then(|| {
        format!(
            "{WHEN} keep a visible plan. Write a fenced code block in your reply on its \
             own line when you can, language `{FENCE}`, holding one JSON object: \
             {{\"steps\": [{{\"step\": \"...\", \"status\": \"pending\"}}]}}, where \
             status is pending, in_progress or completed. Write the first block before \
             your first tool call. Write it again, with the whole list, each time a \
             step starts or finishes, and keep one step in_progress. Write it one \
             last time right before your final answer, with every finished step \
             completed. The app shows it in its plan panel and hides the block, so \
             report progress only through the block: do not also write the plan, a \
             step table or \"step N done\" notes as prose. {SKIP} Do not mention \
             this format."
        )
    })
}

/// When a plan is due. Concrete on purpose: "skip this for quick answers"
/// let a model call a six-step file test quick and show no plan at all.
const WHEN: &str = "For any task that takes three or more tool calls, including a small \
    test or a series of edits to one file,";

/// The only exception, stated as a count so it cannot be argued.
const SKIP: &str = "Skip the plan only when you answer with two tool calls or fewer.";

#[cfg(test)]
mod tests {
    use super::*;

    fn block(json: &str) -> String {
        format!("```{FENCE}\n{json}\n```\n")
    }

    #[test]
    fn the_latest_complete_plan_wins() {
        let mut scanner = Scanner::default();
        let mut text = String::from("Starting.\n");
        text.push_str(&block(r#"{"steps":[{"step":"Read","status":"in_progress"},{"step":"Fix","status":"pending"}]}"#));
        text.push_str(&block(r#"{"steps":[{"step":"Read","status":"completed"},{"text":"Fix","status":"in_progress"}]}"#));
        let plan = scanner.scan(&text).expect("a plan");
        assert_eq!(plan[0]["status"], "completed");
        assert_eq!(plan[1]["text"], "Fix");
        assert!(scanner.scan(&text).is_none(), "each block is reported once");
    }

    #[test]
    fn a_plan_still_streaming_waits() {
        let mut scanner = Scanner::default();
        let partial = format!("```{FENCE}\n{{\"steps\":[{{\"step\":\"A\"");
        assert!(scanner.scan(&partial).is_none());
        let done = format!("{partial},\"status\":\"pending\"}}]}}\n```");
        assert!(
            scanner.scan(&done).is_none(),
            "the last line may still be arriving"
        );
        assert!(scanner.finish(&done).is_some());
    }

    #[test]
    fn an_opening_fence_after_prose_on_one_line_is_still_read() {
        let text = format!(
            "Working. ```{FENCE}\n{{\"steps\":[{{\"step\":\"Read\",\"status\":\"in_progress\"}}]}}\n```\n"
        );
        let plan = Scanner::default().scan(&text).expect("inline plan");
        assert_eq!(plan[0]["text"], "Read");
    }

    #[test]
    fn json_on_the_opening_line_and_ticks_on_the_json_line_still_count() {
        let text = format!(
            "```{FENCE} {{\"steps\":[{{\"step\":\"Same\",\"status\":\"pending\"}}]}}\n```\n"
        );
        assert_eq!(Scanner::default().scan(&text).unwrap()[0]["text"], "Same");

        let glued = format!(
            "```{FENCE}\n{{\"steps\":[{{\"step\":\"Tail\",\"status\":\"completed\"}}]}}```\nDone.\n"
        );
        assert_eq!(Scanner::default().scan(&glued).unwrap()[0]["text"], "Tail");

        let one = format!(
            "Before. ```{FENCE} {{\"steps\":[{{\"step\":\"One\",\"status\":\"completed\"}}]}}```\nAfter.\n"
        );
        assert_eq!(Scanner::default().scan(&one).unwrap()[0]["text"], "One");
    }

    #[test]
    fn malformed_plans_and_question_blocks_are_not_plans() {
        let mut scanner = Scanner::default();
        let text = format!(
            "{}```tokenstat-question\n{{\"question\":\"Q?\"}}\n```\n```json\n{{\"steps\":[]}}\n```\n",
            block("not json")
        );
        assert!(scanner.scan(&text).is_none());
    }

    #[test]
    fn a_block_glued_to_the_last_closing_fence_still_updates_the_plan() {
        // Captured from Grok: the second plan opens on the first one's
        // closing line.
        let text = format!(
            "Starting.\n\n```{FENCE}\n{{\"steps\":[{{\"step\":\"Write\",\"status\":\"in_progress\"}},{{\"step\":\"Read\",\"status\":\"pending\"}}]}}\n``````{FENCE}\n{{\"steps\":[{{\"step\":\"Write\",\"status\":\"completed\"}},{{\"step\":\"Read\",\"status\":\"in_progress\"}}]}}\n```\nDone.\n"
        );
        let plans = Scanner::default().scan_all(&text);
        assert_eq!(plans.len(), 2, "{plans:?}");
        assert_eq!(plans[1][0]["status"], "completed");
        assert_eq!(plans[1][1]["status"], "in_progress");
        let plain = format!("```{FENCE}\n{{\"steps\":[]}}\n``````\nprose\n");
        assert_eq!(
            Scanner::default().scan_all(&plain).len(),
            1,
            "a bare run of ticks still only closes"
        );
    }

    #[test]
    fn a_plan_reopened_after_prose_on_its_closing_line_still_counts() {
        // Captured from Cursor: the first plan closes and the next opens on
        // the same line with prose between the fences.
        let text = format!(
            "A.\n```{FENCE}\n{{\"steps\":[{{\"step\":\"A\",\"status\":\"completed\"}}]}}\n```Next works.```{FENCE}\n{{\"steps\":[{{\"step\":\"B\",\"status\":\"in_progress\"}}]}}\n```\nDone.\n"
        );
        let plans = Scanner::default().scan_all(&text);
        assert_eq!(plans.len(), 2, "{plans:?}");
        assert_eq!(plans[0][0]["text"], "A");
        assert_eq!(plans[1][0]["text"], "B");
        assert_eq!(plans[1][0]["status"], "in_progress");
    }

    #[test]
    fn a_closing_fence_glued_to_prose_still_updates_the_plan() {
        // The final update often arrives as ` ```Yes,...` with no newline after
        // the ticks. That must still close the block or the plan sticks mid-run.
        let mut scanner = Scanner::default();
        let mut text = block(
            r#"{"steps":[{"step":"Inspect","status":"completed"},{"step":"Build","status":"completed"},{"step":"Validate","status":"in_progress"}]}"#,
        );
        assert_eq!(scanner.scan(&text).unwrap()[2]["status"], "in_progress");
        text.push_str(&format!(
            "```{FENCE}\n{{\"steps\":[{{\"step\":\"Inspect\",\"status\":\"completed\"}},{{\"step\":\"Build\",\"status\":\"completed\"}},{{\"step\":\"Validate\",\"status\":\"completed\"}}]}}\n```Yes, done."
        ));
        // No newline after the glued prose yet: finish() must still apply it.
        assert!(scanner.scan(&text).is_none());
        let plan = scanner
            .finish(&text)
            .expect("glued closing fence still parses");
        assert_eq!(plan[2]["status"], "completed");
    }

    #[test]
    fn scanner_survives_buffer_trimming_before_final_plan() {
        let mut scanner = Scanner::default();
        let prefix = "a".repeat(1000);
        assert!(scanner.scan(&prefix).is_none());
        scanner.shift(900);
        let text = format!(
            "{}\n{}",
            &prefix[900..],
            block(r#"{"steps":[{"step":"Finish","status":"completed"}]}"#)
        );
        assert_eq!(scanner.finish(&text).unwrap()[0]["text"], "Finish");
    }

    #[test]
    fn every_chat_backend_is_told_how_to_keep_a_plan() {
        for backend in [
            "codex",
            "claude",
            "cursor",
            "agy",
            "opencode",
            "opencode2",
            "muse",
            "grok",
        ] {
            assert!(
                rule(backend).is_some_and(|text| text.contains(FENCE)),
                "{backend} writes the block"
            );
        }
        assert!(rule("sh").is_none());
    }
}
