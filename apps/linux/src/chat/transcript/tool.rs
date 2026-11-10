// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{SourceEq, fields_eq, has_prefix, lf_lines};
use serde::Serialize;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Tool {
    pub call_id: String,
    pub verb: String,
    pub target: String,
    pub running: bool,
    pub failed: bool,
    pub detail: Option<String>,
    pub started_at_ms: i64,
    pub ended_at_ms: Option<i64>,
    pub snippet: Vec<String>,
}
fields_eq!(Tool;call_id,verb,target,running,failed,detail,started_at_ms,ended_at_ms,snippet);
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Edit {
    pub path: String,
    pub added: u32,
    pub removed: u32,
    pub patch: String,
    pub revision: usize,
    pub running: bool,
    pub failed: bool,
    pub started_at_ms: i64,
    pub ended_at_ms: Option<i64>,
}
fields_eq!(Edit;path,added,removed,patch,revision,running,failed,started_at_ms,ended_at_ms);
impl Edit {
    pub fn apply_patch(&mut self, added: u32, removed: u32, patch: &str) {
        if added > 0 {
            self.added = added;
        }
        if removed > 0 {
            self.removed = removed;
        }
        if !patch.is_empty() {
            self.patch = patch.into();
        }
        self.recount_if_needed();
    }
    pub fn apply_detail(&mut self, detail: Option<&str>) {
        if self.patch.is_empty()
            && let Some(detail) = detail.filter(|s| !s.is_empty())
        {
            self.patch = detail.into();
            self.recount_if_needed();
        }
    }
    pub fn recount_if_needed(&mut self) {
        if self.added != 0 || self.removed != 0 || self.patch.is_empty() {
            return;
        }
        for line in lf_lines(&self.patch, usize::MAX) {
            if is_diff_line(line) {
                if line.starts_with('+') {
                    self.added += 1;
                } else {
                    self.removed += 1;
                }
            }
        }
    }
}
pub fn is_file_edit(verb: &str) -> bool {
    verb == "Edit" || verb == "NotebookEdit"
}
pub fn is_diff_line(line: &str) -> bool {
    line.graphemes(true)
        .next()
        .is_some_and(|c| c == "+" || c == "-")
        && !has_prefix(line, "+++ ")
        && !has_prefix(line, "--- ")
}
pub const LINE_CAP: usize = 60;
pub const COLUMN_CAP: usize = 600;
pub fn clip(line: &str) -> String {
    let mut scalars = line.chars();
    let bounded = scalars.by_ref().take(COLUMN_CAP * 4).collect::<String>();
    let too_many_scalars = scalars.next().is_some();
    let mut graphemes = bounded.graphemes(true);
    let prefix = graphemes.by_ref().take(COLUMN_CAP).collect::<String>();
    if too_many_scalars || graphemes.next().is_some() {
        prefix + "…"
    } else {
        bounded
    }
}
pub fn snippet(verb: &str, detail: Option<&str>) -> Vec<String> {
    let Some(detail) = detail.filter(|d| !d.is_empty()) else {
        return vec![];
    };
    let is_diff = matches!(verb, "Edit" | "NotebookEdit" | "Diff");
    let mut out = vec![];
    let mut start = 0;
    let mut count = 1;
    let mut append = |line: &str| {
        let shown = clip(line);
        out.push(if is_diff && is_diff_line(&shown) {
            shown
        } else {
            format!("| {shown}")
        });
    };
    for (i, b) in detail.bytes().enumerate() {
        if b == b'\n' && (i == 0 || detail.as_bytes()[i - 1] != b'\r') {
            if count <= LINE_CAP {
                append(&detail[start..i]);
            }
            count += 1;
            start = i + 1;
        }
    }
    if count <= LINE_CAP {
        append(&detail[start..]);
    }
    if count > LINE_CAP {
        out.push(crate::localization::text(
            "apple.chatmodel.0_more.8bfcca49",
            &[&(count - LINE_CAP).to_string()],
        ));
    }
    out
}
pub fn duration(start: i64, end: Option<i64>) -> Option<String> {
    let ms = end?.checked_sub(start)?.max(0);
    Some(if ms < 1000 {
        format!("{ms}ms")
    } else {
        let s = ms as f64 / 1000.;
        if s < 10. {
            format!("{s:.1}s")
        } else {
            format!("{}s", s.round() as i64)
        }
    })
}
pub fn ordinal(value: i64) -> String {
    let suffix = if (11..=13).contains(&(value % 100)) {
        "th"
    } else {
        match value % 10 {
            1 => "st",
            2 => "nd",
            3 => "rd",
            _ => "th",
        }
    };
    format!("{value}{suffix}")
}
