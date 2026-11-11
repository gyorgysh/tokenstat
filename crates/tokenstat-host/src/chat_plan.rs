// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! A visible plan for agents whose CLI gives them no plan tool.
//!
//! Some agents report their plan through a tool the host already reads
//! (Cursor's todos, OpenCode's todowrite). Codex and Claude Code in the modes
//! tokenstat runs have none: Codex's plan tool is off in exec and app-server
//! turns, and Claude Code's print mode offers neither TodoWrite nor its task
//! tools, not even through a tool search. So their plans never reached the
//! chat. They write one the same way every backend asks a question: a fenced
//! block in the reply, language `tokenstat-plan`, holding the whole list each
//! time.
//! The host reads the latest complete block into the conversation's activity
//! and the clients hide the block from the reply.
//!
//! OpenCode and Muse do have a todo tool the host reads, but nothing told the
//! model to use it, and a smaller model often did the work with no plan at
//! all. They get one sentence pointing at their own tool instead of the block.

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
        let mut latest = None;
        while let Some((body, end)) = crate::chat_question::next_block(text, &mut self.from, FENCE)
        {
            self.from = end;
            if let Some(plan) = parse(body) {
                latest = Some(plan);
            }
        }
        latest
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

/// How this backend should keep a visible plan: the fenced block, a pointer
/// to its own todo tool, or nothing when it keeps one without being asked.
pub fn rule(backend: &str) -> Option<String> {
    match backend {
        "codex" | "claude" => Some(format!(
            "For work with three or more steps, keep a visible plan: write a fenced \
             code block in your reply, language `{FENCE}`, holding one JSON object: \
             {{\"steps\": [{{\"step\": \"...\", \"status\": \"pending\"}}]}}, where status \
             is pending, in_progress or completed. Write the first block before you \
             start the work, then a new one each time a step starts or finishes, \
             always with the whole list, \
             and keep one step in_progress. The app shows \
             it in its plan panel and hides the block, so report progress only \
             through the block: do not also write the plan or \"step N done\" notes \
             as prose. Skip this for quick answers, and do not mention this format."
        )),
        "opencode" => Some(native_rule("todowrite")),
        "muse" => Some(native_rule("write_todos")),
        _ => None,
    }
}

fn native_rule(tool: &str) -> String {
    format!(
        "For work with three or more steps, keep a visible plan with your `{tool}` \
         tool: write the list before you start the work, then update it each time \
         a step starts or finishes, with one step in progress. The app shows that \
         list in its plan panel, so do not also write the plan or \"step N done\" \
         notes as prose. Skip this for quick answers."
    )
}

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
    fn malformed_plans_and_question_blocks_are_not_plans() {
        let mut scanner = Scanner::default();
        let text = format!(
            "{}```tokenstat-question\n{{\"question\":\"Q?\"}}\n```\n```json\n{{\"steps\":[]}}\n```\n",
            block("not json")
        );
        assert!(scanner.scan(&text).is_none());
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
        let plan = scanner.finish(&text).expect("glued closing fence still parses");
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
    fn only_backends_without_a_reaching_plan_tool_get_a_rule() {
        assert!(rule("codex").is_some_and(|text| text.contains(FENCE)));
        assert!(rule("claude").is_some_and(|text| text.contains(FENCE)));
        assert!(
            rule("opencode")
                .is_some_and(|text| text.contains("todowrite") && !text.contains(FENCE))
        );
        assert!(
            rule("muse").is_some_and(|text| text.contains("write_todos") && !text.contains(FENCE))
        );
        assert!(rule("cursor").is_none());
    }
}
