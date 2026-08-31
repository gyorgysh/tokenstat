// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! What one agent needs to know to pick up where another left off.
//!
//! A conversation can change backend mid-way, and until now that lost
//! everything: each agent keeps its own session under its own resume token, so
//! switching handed the next one a blank page and the person had to re-explain
//! their own project to a second robot in the same window.
//!
//! The transcript was always the shared memory. It is written to
//! `chat/<id>/events.ndjson` for every backend alike, and nothing about it is
//! vendor-specific. What was missing was the handover: a short, honest fold of
//! that timeline, given to an incoming agent once.
//!
//! ## What it is not
//!
//! Not a replay. Feeding a full transcript back would cost more than the
//! conversation did, and most of it is machinery nobody needs twice. This
//! keeps what changes an agent's behaviour: what was asked, what was changed,
//! what ran, what the person refused, and where it was left.
//!
//! Not a sync payload either. This is conversation text and it never leaves
//! the machine, the same way `events.ndjson` never does.

use serde_json::Value;

/// How much of a handover an incoming agent is given, in characters.
///
/// A budget rather than a turn count, because one turn can be a word or a
/// wall. Sized so the brief is a page: enough to know what happened, short
/// enough that it is never the expensive part of the first reply.
pub const BUDGET: usize = 6_000;

/// The most recent assistant reply is the single most useful line in a
/// handover, so it gets its own allowance inside [`BUDGET`].
const TAIL_BUDGET: usize = 1_400;

#[derive(Default)]
struct Folded {
    asks: Vec<String>,
    edits: Vec<String>,
    commands: Vec<String>,
    refused: Vec<String>,
    last_reply: String,
    turns: usize,
}

/// Fold a stored timeline into a handover for an agent that has not seen it.
///
/// Returns an empty string when there is nothing worth handing over, so a
/// caller can treat "no history" and "nothing happened" the same way.
pub fn brief(events: &[Value], folder: &str, budget: usize) -> String {
    let folded = fold(events);
    if folded.turns == 0 {
        return String::new();
    }
    render(&folded, folder, budget)
}

fn fold(events: &[Value]) -> Folded {
    let mut folded = Folded::default();
    let mut reply = String::new();
    for event in events {
        match event.get("kind").and_then(Value::as_str) {
            Some("user") => {
                if let Some(text) = event.get("text").and_then(Value::as_str) {
                    folded.turns += 1;
                    folded.asks.push(one_line(text, 240));
                    // A new question ends the previous answer. Keeping only
                    // the latest is what makes "where it was left" true.
                    reply.clear();
                }
            }
            Some("approval") => {
                let approval = event.get("approval").unwrap_or(&Value::Null);
                if approval.get("decision").and_then(Value::as_str) == Some("deny")
                    && let Some(preview) = approval.get("preview").and_then(Value::as_str)
                {
                    push_unique(&mut folded.refused, one_line(preview, 160));
                }
            }
            Some("agent") => {
                let agent = event.get("event").unwrap_or(&Value::Null);
                match agent.get("kind").and_then(Value::as_str) {
                    Some("text") => {
                        if let Some(delta) = agent.get("delta").and_then(Value::as_str) {
                            reply.push_str(delta);
                        }
                    }
                    Some("edit") => {
                        let path = agent.get("path").and_then(Value::as_str).unwrap_or("");
                        let added = agent.get("added").and_then(Value::as_u64).unwrap_or(0);
                        let removed = agent.get("removed").and_then(Value::as_u64).unwrap_or(0);
                        if !path.is_empty() {
                            push_unique(&mut folded.edits, format!("{path} +{added} −{removed}"));
                        }
                    }
                    Some("toolStart") => {
                        let verb = agent.get("verb").and_then(Value::as_str).unwrap_or("");
                        let target = agent.get("target").and_then(Value::as_str).unwrap_or("");
                        // A shell call is worth remembering by what it ran. A
                        // read is not: the file it touched says nothing about
                        // what the conversation achieved.
                        if is_shell(verb) && !target.is_empty() {
                            push_unique(&mut folded.commands, one_line(target, 160));
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
    folded.last_reply = one_line(&reply, TAIL_BUDGET);
    folded
}

fn is_shell(verb: &str) -> bool {
    let verb = verb.to_ascii_lowercase();
    verb.contains("bash") || verb.contains("shell") || verb.contains("command") || verb == "run"
}

fn render(folded: &Folded, folder: &str, budget: usize) -> String {
    let mut out = String::new();
    out.push_str(
        "Handover: this conversation already ran with a different agent and you are \
         continuing it. Treat the summary below as what has happened so far. Do not \
         redo work that is listed as done, and do not mention or describe this note.\n",
    );
    if !folder.is_empty() {
        out.push_str(&format!("\nFolder: {folder}"));
    }
    out.push_str(&format!("\nTurns so far: {}\n", folded.turns));

    // Sections in the order an agent needs them, and the asks are trimmed
    // first because the earliest ones are the least likely to still matter.
    let asks = fit(&folded.asks, budget.saturating_sub(fixed_cost(folded)));
    section(&mut out, "What the person asked", &asks);
    section(&mut out, "Files changed", &folded.edits);
    section(&mut out, "Commands that ran", &folded.commands);
    section(&mut out, "Refused by the person", &folded.refused);
    if !folded.last_reply.is_empty() {
        out.push_str("\nWhere it was left:\n");
        out.push_str(&folded.last_reply);
        out.push('\n');
    }
    out
}

/// Everything except the asks, which are the part that gets trimmed.
fn fixed_cost(folded: &Folded) -> usize {
    let list = |items: &[String]| items.iter().map(|item| item.len() + 3).sum::<usize>();
    400 + list(&folded.edits)
        + list(&folded.commands)
        + list(&folded.refused)
        + folded.last_reply.len()
}

/// Keep the newest asks, and say how many were dropped.
///
/// Newest rather than oldest: an agent joining now is answering what is being
/// asked now. Saying the count out loud matters more than it looks, because an
/// agent handed a silently truncated history will confidently describe a
/// conversation it was only shown the end of.
fn fit(asks: &[String], budget: usize) -> Vec<String> {
    let mut kept: Vec<String> = Vec::new();
    let mut used = 0;
    for ask in asks.iter().rev() {
        let cost = ask.len() + 3;
        if used + cost > budget && !kept.is_empty() {
            break;
        }
        used += cost;
        kept.push(ask.clone());
    }
    kept.reverse();
    let dropped = asks.len() - kept.len();
    if dropped > 0 {
        kept.insert(0, format!("({dropped} earlier turns not included)"));
    }
    kept
}

fn section(out: &mut String, title: &str, items: &[String]) {
    if items.is_empty() {
        return;
    }
    out.push_str(&format!("\n{title}:\n"));
    for item in items {
        out.push_str(&format!("- {item}\n"));
    }
}

fn push_unique(items: &mut Vec<String>, value: String) {
    if !items.contains(&value) {
        items.push(value);
    }
}

/// Collapse to one line and cap it. A handover is a list, and a list item that
/// spans forty lines of pasted output is not a list item.
fn one_line(text: &str, cap: usize) -> String {
    let joined = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if joined.chars().count() <= cap {
        return joined;
    }
    let kept: String = joined.chars().take(cap).collect();
    format!("{kept}…")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn timeline() -> Vec<Value> {
        vec![
            json!({"kind": "user", "text": "Add a retry to the uploader"}),
            json!({"kind": "agent", "event": {"kind": "toolStart", "verb": "Bash", "target": "cargo test"}}),
            json!({"kind": "agent", "event": {"kind": "edit", "path": "src/upload.rs", "added": 12, "removed": 3}}),
            json!({"kind": "agent", "event": {"kind": "text", "delta": "Added a retry with backoff."}}),
            json!({"kind": "user", "text": "Now cover it with a test"}),
            json!({"kind": "approval", "approval": {"decision": "deny", "preview": "rm -rf target"}}),
            json!({"kind": "agent", "event": {"kind": "text", "delta": "Test added, but "}}),
            json!({"kind": "agent", "event": {"kind": "text", "delta": "it is not passing yet."}}),
        ]
    }

    #[test]
    fn a_handover_keeps_what_changes_the_next_agent_s_behaviour() {
        let text = brief(&timeline(), "/repo", BUDGET);
        assert!(text.contains("Add a retry to the uploader"));
        assert!(text.contains("Now cover it with a test"));
        assert!(text.contains("src/upload.rs +12 −3"));
        assert!(text.contains("cargo test"));
        assert!(text.contains("rm -rf target"));
        assert!(text.contains("Turns so far: 2"));
        assert!(text.contains("/repo"));
    }

    /// Streamed deltas are one reply, and only the newest one is where the
    /// conversation was actually left.
    #[test]
    fn only_the_latest_reply_is_where_it_was_left() {
        let text = brief(&timeline(), "/repo", BUDGET);
        assert!(text.contains("Test added, but it is not passing yet."));
        assert!(!text.contains("Added a retry with backoff."));
    }

    #[test]
    fn nothing_to_hand_over_is_an_empty_brief() {
        assert!(brief(&[], "/repo", BUDGET).is_empty());
        let agent_only =
            vec![json!({"kind": "agent", "event": {"kind": "text", "delta": "hello"}})];
        assert!(brief(&agent_only, "/repo", BUDGET).is_empty());
    }

    /// An agent handed a silently truncated history describes a conversation
    /// it was only shown the end of. Say what was dropped.
    #[test]
    fn a_trimmed_handover_admits_what_it_dropped() {
        let events: Vec<Value> = (0..200)
            .map(|index| json!({"kind": "user", "text": format!("question number {index} {}", "x".repeat(120))}))
            .collect();
        let text = brief(&events, "/repo", 2_000);
        assert!(text.len() < 4_000, "budget ignored: {} chars", text.len());
        assert!(text.contains("earlier turns not included"));
        assert!(
            text.contains("question number 199"),
            "the newest ask must survive"
        );
    }

    #[test]
    fn the_agent_is_told_not_to_narrate_the_handover() {
        let text = brief(&timeline(), "/repo", BUDGET);
        assert!(text.contains("do not mention or describe this note"));
    }

    /// Reads and edits are not commands. A handover listing every file an
    /// agent looked at is noise that crowds out what it did.
    #[test]
    fn only_shell_calls_count_as_commands() {
        let events = vec![
            json!({"kind": "user", "text": "look around"}),
            json!({"kind": "agent", "event": {"kind": "toolStart", "verb": "Read", "target": "src/main.rs"}}),
            json!({"kind": "agent", "event": {"kind": "toolStart", "verb": "run_terminal_command", "target": "git status"}}),
        ];
        let text = brief(&events, "/repo", BUDGET);
        assert!(text.contains("git status"));
        assert!(!text.contains("Read"));
    }
}
