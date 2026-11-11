// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The original desktop's display rows and projection, independent of GPUI.
//! Raw events remain available for search/cache; presentation owns no archive.

pub mod auth;
mod coalesce;
pub mod fold;
pub mod images;
pub mod muse;
pub mod question;
pub mod tool;
use super::wire::Approval;
use crate::{drafts::Attachment, work::text};
pub use coalesce::coalesce;
pub use question::Question;
use serde::Serialize;
pub use tool::{Edit, Tool};
#[cfg(test)]
mod tests;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub is_steer: bool,
    pub id: String,
    pub kind: Kind,
    pub last_sequence: Option<u64>,
    #[serde(rename = "groupID")]
    pub group_id: Option<String>,
    pub plain_step: Option<PlainStep>,
    pub image_attachments: Vec<Attachment>,
    #[serde(rename = "imageRowIDs")]
    pub image_row_ids: Vec<String>,
    pub source_backend: Option<String>,
}
impl Row {
    pub fn new(id: impl Into<String>, kind: Kind) -> Self {
        Self {
            is_steer: false,
            id: id.into(),
            kind,
            last_sequence: None,
            group_id: None,
            plain_step: None,
            image_attachments: vec![],
            image_row_ids: vec![],
            source_backend: None,
        }
    }
}
#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum PlainStep {
    Detail,
    Line,
}
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Kind {
    User {
        text: String,
    },
    Assistant {
        text: String,
        backend: Option<String>,
    },
    TurnSeparator {
        backend: String,
    },
    Handoff {
        to: String,
        brief: String,
    },
    Thinking {
        text: String,
    },
    Tool {
        state: Tool,
    },
    Edit {
        state: Edit,
    },
    Attachment {
        file: Attachment,
    },
    Approval {
        approval: Approval,
    },
    Usage {
        input: u64,
        output: u64,
        cost: Option<f64>,
    },
    Failed {
        text: String,
    },
    Group {
        group: StepGroup,
    },
    Question {
        question: Question,
    },
    Changes {
        changes: TurnChanges,
    },
}
#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum GroupStyle {
    Work,
    Explored,
    Thought,
    Step,
}
#[derive(Clone, Debug, Serialize)]
pub struct Activity {
    pub id: String,
    pub verb: String,
    pub target: String,
    pub running: bool,
    pub failed: bool,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StepGroup {
    pub style: GroupStyle,
    pub open: bool,
    #[serde(rename = "memberIDs")]
    pub member_ids: Vec<String>,
    pub steps: usize,
    pub files: usize,
    pub added: u64,
    pub removed: u64,
    pub reads: usize,
    pub searches: usize,
    pub pages: usize,
    pub failures: usize,
    pub running: bool,
    pub live_verb: Option<String>,
    pub live_target: Option<String>,
    pub recent_activity: Vec<Activity>,
    pub started_at_ms: Option<i64>,
    pub ended_at_ms: Option<i64>,
    pub cost: Option<f64>,
    pub preview: Option<String>,
    pub plain: bool,
    pub verb: Option<String>,
    pub subject: Option<String>,
}
impl StepGroup {
    pub fn new(style: GroupStyle, member_ids: Vec<String>) -> Self {
        Self {
            style,
            open: false,
            member_ids,
            steps: 0,
            files: 0,
            added: 0,
            removed: 0,
            reads: 0,
            searches: 0,
            pages: 0,
            failures: 0,
            running: false,
            live_verb: None,
            live_target: None,
            recent_activity: vec![],
            started_at_ms: None,
            ended_at_ms: None,
            cost: None,
            preview: None,
            plain: false,
            verb: None,
            subject: None,
        }
    }
    pub fn activity_preview(&self) -> &[Activity] {
        if self.style == GroupStyle::Work && self.running && !self.open {
            &self.recent_activity
        } else {
            &[]
        }
    }
}
#[derive(Clone, Debug, Serialize)]
pub struct ChangedFile {
    pub path: String,
    pub added: u64,
    pub removed: u64,
    pub patches: Vec<String>,
}
#[derive(Clone, Debug, Serialize)]
pub struct TurnChanges {
    pub id: String,
    pub files: Vec<ChangedFile>,
}

// Swift Equatable uses canonical String equality throughout nested rows. Keep
// stored spelling, avoid serializing/cloning megabyte tool details to compare.
pub(super) trait SourceEq {
    fn source_eq(&self, other: &Self) -> bool;
}
impl SourceEq for String {
    fn source_eq(&self, other: &Self) -> bool {
        self == other || text::equal(self, other)
    }
}
impl<T: SourceEq> SourceEq for Option<T> {
    fn source_eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Some(a), Some(b)) => a.source_eq(b),
            (None, None) => true,
            _ => false,
        }
    }
}
impl<T: SourceEq> SourceEq for Vec<T> {
    fn source_eq(&self, other: &Self) -> bool {
        self.len() == other.len() && self.iter().zip(other).all(|(a, b)| a.source_eq(b))
    }
}
macro_rules! scalar_eq { ($($ty:ty),*) => {$(impl SourceEq for $ty {fn source_eq(&self,other:&Self)->bool {self==other}})*}; }
scalar_eq!(
    bool,
    u32,
    u64,
    i64,
    usize,
    f64,
    PlainStep,
    GroupStyle,
    Attachment,
    Kind,
    Row,
    Tool,
    Edit,
    Question,
    Activity,
    StepGroup,
    ChangedFile,
    TurnChanges
);
macro_rules! fields_eq {
    ($ty:ty; $($field:ident),+) => {impl PartialEq for $ty {fn eq(&self,other:&Self)->bool {$(self.$field.source_eq(&other.$field))&&+}}};
}
pub(super) use fields_eq;
fields_eq!(Row; is_steer,id,kind,last_sequence,group_id,plain_step,image_attachments,image_row_ids,source_backend);
fields_eq!(Activity; id,verb,target,running,failed);
fields_eq!(StepGroup; style,open,member_ids,steps,files,added,removed,reads,searches,pages,failures,running,live_verb,live_target,recent_activity,started_at_ms,ended_at_ms,cost,preview,plain,verb,subject);
fields_eq!(ChangedFile; path,added,removed,patches);
fields_eq!(TurnChanges; id,files);
impl PartialEq for Kind {
    fn eq(&self, other: &Self) -> bool {
        use Kind::*;
        match (self, other) {
            (User { text: a }, User { text: b })
            | (Thinking { text: a }, Thinking { text: b })
            | (Failed { text: a }, Failed { text: b }) => a.source_eq(b),
            (
                Assistant {
                    text: a,
                    backend: x,
                },
                Assistant {
                    text: b,
                    backend: y,
                },
            ) => a.source_eq(b) && x.source_eq(y),
            (TurnSeparator { backend: a }, TurnSeparator { backend: b }) => a.source_eq(b),
            (Handoff { to: a, brief: x }, Handoff { to: b, brief: y }) => {
                a.source_eq(b) && x.source_eq(y)
            }
            (Tool { state: a }, Tool { state: b }) => a == b,
            (Edit { state: a }, Edit { state: b }) => a == b,
            (Attachment { file: a }, Attachment { file: b }) => a == b,
            (Approval { approval: a }, Approval { approval: b }) => {
                a.id.source_eq(&b.id)
                    && a.conversation_id.source_eq(&b.conversation_id)
                    && a.verb.source_eq(&b.verb)
                    && a.preview.source_eq(&b.preview)
                    && a.shell_prefix.source_eq(&b.shell_prefix)
                    && a.created_at_ms == b.created_at_ms
                    && a.expires_at_ms == b.expires_at_ms
                    && a.decision.source_eq(&b.decision)
                    && a.read_only == b.read_only
            }
            (
                Usage {
                    input: a,
                    output: x,
                    cost: c,
                },
                Usage {
                    input: b,
                    output: y,
                    cost: d,
                },
            ) => a == b && x == y && c == d,
            (Group { group: a }, Group { group: b }) => a == b,
            (Question { question: a }, Question { question: b }) => a == b,
            (Changes { changes: a }, Changes { changes: b }) => a == b,
            _ => false,
        }
    }
}

pub(super) fn nfc(s: &str) -> String {
    use unicode_normalization::UnicodeNormalization;
    s.nfc().collect()
}
pub(super) fn has_prefix(s: &str, prefix: &str) -> bool {
    use unicode_segmentation::UnicodeSegmentation;
    if prefix.is_ascii() {
        return s.starts_with(prefix)
            && (prefix.is_empty()
                || s.len() == prefix.len()
                || s.grapheme_indices(true)
                    .take_while(|(i, _)| *i <= prefix.len())
                    .any(|(i, _)| i == prefix.len()));
    }
    let s = nfc(s);
    let prefix = nfc(prefix);
    s.starts_with(&prefix)
        && (prefix.is_empty()
            || s.len() == prefix.len()
            || s.grapheme_indices(true).any(|(i, _)| i == prefix.len()))
}
pub(super) fn whitespace(c: char) -> bool {
    c == '\t'
        || c == '\u{20}'
        || c == '\u{a0}'
        || c == '\u{1680}'
        || ('\u{2000}'..='\u{200b}').contains(&c)
        || c == '\u{202f}'
        || c == '\u{205f}'
        || c == '\u{3000}'
}
pub(super) fn trim_space(s: &str) -> &str {
    s.trim_matches(whitespace)
}
/// String.split(separator: Character("\n")) deliberately does not split CRLF.
pub(super) fn lf_lines(s: &str, max_splits: usize) -> Vec<&str> {
    let mut out = vec![];
    let mut start = 0;
    for (i, b) in s.bytes().enumerate() {
        if b == b'\n' && (i == 0 || s.as_bytes()[i - 1] != b'\r') && out.len() < max_splits {
            out.push(&s[start..i]);
            start = i + 1;
        }
    }
    out.push(&s[start..]);
    out
}
