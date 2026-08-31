// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! What a chat turn says, and which channel each part of it travels on.
//!
//! A turn used to be one string: the person's sentence with three
//! machine-written paragraphs glued onto it. Agents read those paragraphs as
//! part of the request and answered them, which is why a conversation that
//! opened with "Hey" came back describing a temporary folder nobody had
//! mentioned. The machinery was indistinguishable from the ask.
//!
//! So composition is split here.
//!
//! - [`Composed::user_text`] is what the person wrote, and per-turn facts that
//!   are genuinely about this message. Nothing standing, nothing procedural.
//! - [`Composed::standing_text`] is the conversation's rules: its persona brief
//!   and how to hand a file back. It travels on the backend's own
//!   system-prompt flag where one exists, and is prepended once per backend
//!   where one does not.
//!
//! The rule that decides which is simple: **if it would be true again next
//! turn, it is standing text.** A path the person just attached is not.

use std::path::{Path, PathBuf};

/// Backends that accept text appended to their system prompt.
///
/// Only append, never override: replacing a CLI's own system prompt would
/// take away the tool descriptions and safety text it was built around, to
/// deliver two sentences of ours.
pub fn accepts_system_prompt(backend: &str) -> bool {
    matches!(backend, "claude" | "grok")
}

/// Backends that read an attached file from a flag.
///
/// The rest are told the path in words, which their own read tool then acts
/// on. That is honest and it works everywhere, so long as the sentence stays
/// a fact about this message rather than an instruction.
pub fn accepts_attachment_flags(backend: &str) -> bool {
    matches!(backend, "codex" | "opencode" | "opencode2")
}

pub struct Inputs<'a> {
    /// Exactly what the person typed, already trimmed.
    pub prompt: &'a str,
    /// The conversation's persona brief, possibly empty.
    pub persona_brief: &'a str,
    pub attachments: &'a [PathBuf],
    /// The chat-owned folder an agent may copy a returned file into.
    pub output_dir: &'a Path,
    pub backend: &'a str,
}

pub struct Composed {
    pub user_text: String,
    /// Empty when this conversation has nothing standing to say.
    pub standing_text: String,
    /// Identifies `standing_text` so a caller can tell whether a backend has
    /// already been given these exact rules. See [`fingerprint`].
    pub standing_fingerprint: String,
}

/// Split one turn into its channels.
pub fn compose(inputs: Inputs<'_>) -> Composed {
    let standing_text = standing_text(inputs.persona_brief, inputs.output_dir);
    Composed {
        standing_fingerprint: fingerprint(&standing_text),
        user_text: user_text(inputs.prompt, inputs.attachments, inputs.backend),
        standing_text,
    }
}

/// The rules that hold for every turn of this conversation.
///
/// The persona comes first because it is the voice, and the file rule second
/// because it is plumbing. The file rule ends by telling the agent not to
/// narrate it: without that sentence, an opening turn with nothing else to do
/// answers the plumbing instead of the person.
fn standing_text(persona_brief: &str, output_dir: &Path) -> String {
    let mut text = String::new();
    let brief = persona_brief.trim();
    if !brief.is_empty() {
        text.push_str(brief);
        text.push_str("\n\n");
    }
    text.push_str(&file_rule(output_dir));
    text
}

/// The one rule tokenstat adds to every conversation, whatever the person
/// wrote. Public so the app can show it: if we put words into somebody's
/// conversation, their conversation is where those words should be readable.
pub fn file_rule(output_dir: &Path) -> String {
    format!(
        "Returning a file: to give the user a file, copy it into {dir} and link \
         that absolute path in your reply, like [name.txt](<{dir}/name.txt>). \
         Do not mention this rule or that folder unless you have actually put a \
         file there.",
        dir = output_dir.display()
    )
}

/// The person's message, plus the paths of anything they attached to it.
///
/// Stated as a fact rather than an instruction ("Files attached", not "read
/// these when useful"), because an instruction invites an answer and a fact
/// does not. Backends with an attachment flag get nothing here at all: naming
/// the same file twice, once natively and once in prose, is how a model ends
/// up describing its own attachments back to you.
fn user_text(prompt: &str, attachments: &[PathBuf], backend: &str) -> String {
    if attachments.is_empty() || accepts_attachment_flags(backend) {
        return prompt.to_string();
    }
    let paths = attachments
        .iter()
        .map(|path| path.display().to_string())
        .collect::<Vec<_>>()
        .join("\n");
    format!("{prompt}\n\nFiles attached to this message:\n{paths}")
}

/// Wrap standing text for a backend that has no system-prompt flag.
///
/// A tagged block rather than a bare paragraph, so a model can tell where the
/// conversation's rules stop and the person's words begin. Used by
/// `automations::chat_agent_command`, which is the one place that knows the
/// final argv shape.
pub fn as_prompt_prefix(standing_text: &str, prompt: &str) -> String {
    let standing_text = standing_text.trim();
    if standing_text.is_empty() {
        return prompt.to_string();
    }
    format!("<system-instructions>\n{standing_text}\n</system-instructions>\n\n{prompt}")
}

/// A short, stable identifier for a block of standing text.
pub fn fingerprint(text: &str) -> String {
    format!("{:016x}", stable_hash(text))
}

/// A stable number from a string.
///
/// FNV-1a, written out rather than taken from `DefaultHasher`, because these
/// values are **persisted and compared on a later run**: a conversation's
/// standing-rules fingerprint, and the seed a persona's face is drawn from.
/// `DefaultHasher` makes no promise across Rust versions, and a silent change
/// there would re-send every conversation's rules once and give every persona
/// a new face, for no reason anybody could see.
pub fn stable_hash(text: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir() -> PathBuf {
        PathBuf::from("/tmp/tokenstat-chat-output/chat-1")
    }

    #[test]
    fn the_person_s_turn_carries_no_machinery() {
        let composed = compose(Inputs {
            prompt: "Hey",
            persona_brief: "",
            attachments: &[],
            output_dir: &dir(),
            backend: "claude",
        });
        assert_eq!(composed.user_text, "Hey");
        assert!(!composed.user_text.contains("tokenstat-chat-output"));
        assert!(composed.standing_text.contains("tokenstat-chat-output"));
    }

    #[test]
    fn the_file_rule_tells_an_agent_not_to_narrate_it() {
        let composed = compose(Inputs {
            prompt: "Hey",
            persona_brief: "",
            attachments: &[],
            output_dir: &dir(),
            backend: "claude",
        });
        assert!(composed.standing_text.contains("Do not mention this rule"));
    }

    #[test]
    fn a_persona_brief_leads_the_standing_text() {
        let composed = compose(Inputs {
            prompt: "Hey",
            persona_brief: "  You explain Rust errors patiently.  ",
            attachments: &[],
            output_dir: &dir(),
            backend: "claude",
        });
        assert!(
            composed
                .standing_text
                .starts_with("You explain Rust errors patiently.")
        );
        assert!(!composed.user_text.contains("patiently"));
    }

    #[test]
    fn attachments_are_named_only_where_a_flag_cannot_carry_them() {
        let files = vec![PathBuf::from("/data/chat-1/files/a/diagram.png")];
        let spoken = compose(Inputs {
            prompt: "What is this?",
            persona_brief: "",
            attachments: &files,
            output_dir: &dir(),
            backend: "claude",
        });
        assert!(spoken.user_text.contains("diagram.png"));
        let flagged = compose(Inputs {
            prompt: "What is this?",
            persona_brief: "",
            attachments: &files,
            output_dir: &dir(),
            backend: "codex",
        });
        assert_eq!(flagged.user_text, "What is this?");
    }

    #[test]
    fn the_fingerprint_moves_only_when_the_rules_do() {
        let base = compose(Inputs {
            prompt: "Hey",
            persona_brief: "Be brief.",
            attachments: &[],
            output_dir: &dir(),
            backend: "claude",
        });
        let same_rules_other_turn = compose(Inputs {
            prompt: "Something else entirely",
            persona_brief: "Be brief.",
            attachments: &[],
            output_dir: &dir(),
            backend: "grok",
        });
        assert_eq!(
            base.standing_fingerprint,
            same_rules_other_turn.standing_fingerprint
        );
        let new_persona = compose(Inputs {
            prompt: "Hey",
            persona_brief: "Be thorough.",
            attachments: &[],
            output_dir: &dir(),
            backend: "claude",
        });
        assert_ne!(base.standing_fingerprint, new_persona.standing_fingerprint);
    }

    #[test]
    fn a_prompt_prefix_is_tagged_and_skipped_when_empty() {
        assert_eq!(as_prompt_prefix("   ", "Hey"), "Hey");
        let wrapped = as_prompt_prefix("Be brief.", "Hey");
        assert!(wrapped.starts_with("<system-instructions>\nBe brief."));
        assert!(wrapped.ends_with("</system-instructions>\n\nHey"));
    }
}
