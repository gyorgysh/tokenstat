// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

//! Line counts for an edit whose agent named only the file it touched.
//!
//! Codex reports a file change as a path and a kind, with no patch, so its
//! edit lines had nothing to count. Reading the file when the change starts
//! is too late: the stream is read a few times a second and the patch is
//! already on disk by then. So the "before" side is what the file held the
//! last time this turn knew it:
//!
//! - a file already changed when the turn began, read then;
//! - a file this turn already edited, as that edit left it;
//! - otherwise the captured index blob, which for a file clean at the start of the
//!   turn is exactly what was on disk.
//!
//! The difference becomes the same `Edit` event every other agent sends
//! itself. Everything here reads. Nothing writes to the folder or to git.

use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::transcript::Event;

/// Larger files are left uncounted. A count is a courtesy, and diffing a
/// generated megabyte file a few times a turn is not.
const MAX_BYTES: usize = 1024 * 1024;
/// How many changed files a turn reads up front. A tree with thousands of
/// untracked files would otherwise be read in full before the agent starts.
const MAX_BASELINE_FILES: usize = 400;
/// The patch kept on the edit row. The counts cover the whole change.
const PATCH_CAP: usize = 16 * 1024;
/// Past this many changed lines the middle of a file is counted as replaced
/// rather than aligned line by line. Memory grows with its square.
const MAX_EDIT_DISTANCE: usize = 1500;
const CONTEXT: usize = 3;

/// What a file held. An unknown baseline must never become an empty file.
#[derive(Clone)]
enum Contents {
    Absent,
    Text(String),
    Unknown,
}

/// One turn's measuring. Built before the agent is launched.
pub(crate) struct EditMeasure {
    known: HashMap<PathBuf, Contents>,
    root: PathBuf,
    index: Option<tokenstat_workspace::git::IndexSnapshot>,
    /// Edits started and not yet ended: their call id and the files named.
    open: HashMap<String, Vec<String>>,
}

impl EditMeasure {
    /// Reads bounded contents of files already changed in the repository, so an edit
    /// to one of them is measured from what it held, not from the index.
    pub(crate) fn start(root: &Path) -> Self {
        let index = tokenstat_workspace::git::IndexSnapshot::read(root);
        let known = index
            .as_ref()
            .map(|index| {
                index
                    .changed_files()
                    .iter()
                    .enumerate()
                    .map(|(n, path)| {
                        let contents = if n < MAX_BASELINE_FILES {
                            read(path)
                        } else {
                            None
                        };
                        (canonical(path), contents.unwrap_or(Contents::Unknown))
                    })
                    .collect()
            })
            .unwrap_or_default();
        Self {
            known,
            root: root.to_path_buf(),
            index,
            open: HashMap::new(),
        }
    }

    /// Passes events through, adding an `Edit` with counts after each
    /// path-only edit that finished.
    pub(crate) fn observe(&mut self, events: Vec<Event>) -> Vec<Event> {
        let mut out = Vec::with_capacity(events.len());
        for event in events {
            let measured = match &event {
                Event::ToolStart {
                    call_id,
                    verb,
                    input,
                    ..
                } if verb == "Edit" => {
                    if let Some(paths) = reported_paths(input) {
                        self.open.insert(call_id.clone(), paths);
                    }
                    Vec::new()
                }
                Event::ToolEnd { call_id, ok, .. } => match self.open.remove(call_id) {
                    Some(paths) if *ok => self.measure(call_id, &paths),
                    _ => Vec::new(),
                },
                _ => Vec::new(),
            };
            out.push(event);
            out.extend(measured);
        }
        out
    }

    fn measure(&mut self, call_id: &str, paths: &[String]) -> Vec<Event> {
        let mut edits = Vec::new();
        for reported in paths {
            let path = self.resolve(reported);
            let before = match self.known.get(&path) {
                Some(contents) => contents.clone(),
                None => match &self.index {
                    Some(index) if index.contains(&path) => index
                        .text(&path, MAX_BYTES)
                        .map(Contents::Text)
                        .unwrap_or(Contents::Unknown),
                    // Not tracked or present at the start, inside the repo:
                    // this file is new. Outside it the baseline is unknown.
                    Some(index) if index.can_be_new(&path) => Contents::Absent,
                    _ => Contents::Unknown,
                },
            };
            let Some(after) = read(&path) else {
                // Too large or not text now. What it held is unknown again.
                self.known.insert(path, Contents::Unknown);
                continue;
            };
            if matches!(before, Contents::Unknown) {
                self.known.insert(path, after);
                continue;
            }
            let (added, removed, patch) = difference(text_of(&before), text_of(&after));
            self.known.insert(path, after);
            if added + removed > 0 {
                edits.push(Event::Edit {
                    call_id: call_id.to_string(),
                    path: reported.clone(),
                    added,
                    removed,
                    patch,
                });
            }
        }
        edits
    }

    fn resolve(&self, reported: &str) -> PathBuf {
        let path = Path::new(reported);
        canonical(&if path.is_absolute() {
            path.to_path_buf()
        } else {
            self.root.join(path)
        })
    }
}

/// One spelling per file. Git names files under the repository's real path
/// and an agent under the folder it was given, and the two differ wherever
/// a symlink sits above the folder. A file not there yet resolves through
/// its folder.
fn canonical(path: &Path) -> PathBuf {
    if let Ok(real) = std::fs::canonicalize(path) {
        return real;
    }
    match (path.parent(), path.file_name()) {
        (Some(folder), Some(name)) => canonical(folder).join(name),
        _ => path.to_path_buf(),
    }
}

/// The files a path-only edit names: Codex's `changes` list. Every other
/// agent's edit input carries its own text and is left alone.
fn reported_paths(input: &Value) -> Option<Vec<String>> {
    let paths: Vec<String> = input
        .get("changes")?
        .as_array()?
        .iter()
        .filter_map(|change| change.get("path").and_then(Value::as_str))
        .filter(|path| !path.is_empty())
        .map(str::to_string)
        .collect();
    (!paths.is_empty()).then_some(paths)
}

/// `None` when the file cannot be counted: too large, not UTF-8, or binary.
fn read(path: &Path) -> Option<Contents> {
    match std::fs::metadata(path) {
        Ok(meta) if !meta.is_file() || meta.len() > MAX_BYTES as u64 => return None,
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Some(Contents::Absent);
        }
        Err(_) => return None,
    }
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .ok()?
        .take((MAX_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() > MAX_BYTES || bytes.contains(&0) {
        return None;
    }
    String::from_utf8(bytes).ok().map(Contents::Text)
}

fn text_of(contents: &Contents) -> &str {
    match contents {
        Contents::Absent => "",
        Contents::Text(text) => text,
        Contents::Unknown => unreachable!("unknown baselines are not diffed"),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Op {
    Same,
    Removed,
    Added,
}

/// Lines added and removed between two texts, and a unified patch of them
/// with a few lines of context, capped at `PATCH_CAP`.
fn difference(old: &str, new: &str) -> (u32, u32, String) {
    // Keep line endings: adding an EOF newline or changing CRLF is still
    // a changed line in git, even when `str::lines` returns identical text.
    let a: Vec<&str> = old.split_inclusive('\n').collect();
    let b: Vec<&str> = new.split_inclusive('\n').collect();
    let ops = script(&a, &b);
    let added = ops.iter().filter(|op| **op == Op::Added).count();
    let removed = ops.iter().filter(|op| **op == Op::Removed).count();
    (
        u32::try_from(added).unwrap_or(u32::MAX),
        u32::try_from(removed).unwrap_or(u32::MAX),
        patch(&a, &b, &ops),
    )
}

/// The shortest edit script, one op per line. Common lines at either end
/// are matched first, which is all most edits need.
fn script(a: &[&str], b: &[&str]) -> Vec<Op> {
    let prefix = a.iter().zip(b).take_while(|(x, y)| x == y).count();
    let room = a.len().min(b.len()) - prefix;
    let suffix = a
        .iter()
        .rev()
        .zip(b.iter().rev())
        .take(room)
        .take_while(|(x, y)| x == y)
        .count();
    let mut ops = vec![Op::Same; prefix];
    ops.extend(middle(
        &a[prefix..a.len() - suffix],
        &b[prefix..b.len() - suffix],
    ));
    ops.extend(std::iter::repeat_n(Op::Same, suffix));
    ops
}

/// Myers' greedy search, keeping each round's frontier to walk back from.
/// Past `MAX_EDIT_DISTANCE` the whole stretch counts as replaced.
fn middle(a: &[&str], b: &[&str]) -> Vec<Op> {
    let replaced = || {
        let mut ops = vec![Op::Removed; a.len()];
        ops.extend(std::iter::repeat_n(Op::Added, b.len()));
        ops
    };
    if a.is_empty() || b.is_empty() {
        return replaced();
    }
    let (n, m) = (a.len() as i64, b.len() as i64);
    let bound = (a.len() + b.len()).min(MAX_EDIT_DISTANCE) as i64;
    let offset = bound + 1;
    let mut v = vec![0i64; (2 * bound + 3) as usize];
    let mut trace: Vec<Vec<i64>> = Vec::new();
    for d in 0..=bound {
        trace.push(v.clone());
        let mut k = -d;
        while k <= d {
            let at = (k + offset) as usize;
            let mut x = if k == -d || (k != d && v[at - 1] < v[at + 1]) {
                v[at + 1]
            } else {
                v[at - 1] + 1
            };
            let mut y = x - k;
            while x < n && y < m && a[x as usize] == b[y as usize] {
                x += 1;
                y += 1;
            }
            v[at] = x;
            if x >= n && y >= m {
                return walk_back(&trace, offset, n, m);
            }
            k += 2;
        }
    }
    replaced()
}

fn walk_back(trace: &[Vec<i64>], offset: i64, n: i64, m: i64) -> Vec<Op> {
    let mut ops = Vec::new();
    let (mut x, mut y) = (n, m);
    for d in (1..trace.len() as i64).rev() {
        let v = &trace[d as usize];
        let k = x - y;
        let previous =
            if k == -d || (k != d && v[(k - 1 + offset) as usize] < v[(k + 1 + offset) as usize]) {
                k + 1
            } else {
                k - 1
            };
        let start_x = v[(previous + offset) as usize];
        let start_y = start_x - previous;
        while x > start_x && y > start_y {
            ops.push(Op::Same);
            x -= 1;
            y -= 1;
        }
        ops.push(if previous == k + 1 {
            Op::Added
        } else {
            Op::Removed
        });
        x = start_x;
        y = start_y;
    }
    while x > 0 && y > 0 {
        ops.push(Op::Same);
        x -= 1;
        y -= 1;
    }
    ops.reverse();
    ops
}

/// Hunks with `CONTEXT` lines either side, the way `git diff` draws them.
fn patch(a: &[&str], b: &[&str], ops: &[Op]) -> String {
    // Where each op sits in the old and new text.
    let mut at = Vec::with_capacity(ops.len());
    let (mut i, mut j) = (0usize, 0usize);
    for op in ops {
        at.push((i, j));
        match op {
            Op::Same => {
                i += 1;
                j += 1;
            }
            Op::Removed => i += 1,
            Op::Added => j += 1,
        }
    }
    let changes: Vec<usize> = (0..ops.len()).filter(|&n| ops[n] != Op::Same).collect();
    let mut out = String::new();
    let mut n = 0;
    while n < changes.len() {
        let first = changes[n];
        let mut last = first;
        while n + 1 < changes.len() && changes[n + 1] - last <= 2 * CONTEXT + 1 {
            n += 1;
            last = changes[n];
        }
        n += 1;
        let start = first.saturating_sub(CONTEXT);
        let end = (last + CONTEXT + 1).min(ops.len());
        let span = &ops[start..end];
        let old_len = span.iter().filter(|op| **op != Op::Added).count();
        let new_len = span.iter().filter(|op| **op != Op::Removed).count();
        let (old_at, new_at) = at[start];
        out.push_str(&format!(
            "@@ -{},{old_len} +{},{new_len} @@\n",
            old_at + usize::from(old_len > 0),
            new_at + usize::from(new_len > 0),
        ));
        for index in start..end {
            let (i, j) = at[index];
            let (marker, line) = match ops[index] {
                Op::Same => (' ', a[i]),
                Op::Removed => ('-', a[i]),
                Op::Added => ('+', b[j]),
            };
            out.push(marker);
            out.push_str(line.strip_suffix('\n').unwrap_or(line));
            out.push('\n');
            if !line.ends_with('\n') {
                out.push_str("\\ No newline at end of file\n");
            }
        }
        if out.len() > PATCH_CAP {
            let mut cut = PATCH_CAP;
            while !out.is_char_boundary(cut) {
                cut -= 1;
            }
            out.truncate(cut);
            out.push('…');
            break;
        }
    }
    out.truncate(out.trim_end_matches('\n').len());
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn counts(old: &str, new: &str) -> (u32, u32) {
        let (added, removed, _) = difference(old, new);
        (added, removed)
    }

    #[test]
    fn counts_lines_the_way_a_diff_does() {
        assert_eq!(counts("a\nb\nc\n", "a\nb\nc\n"), (0, 0));
        assert_eq!(counts("a\nb\nc\n", "a\nB\nc\n"), (1, 1));
        assert_eq!(counts("", "one\ntwo\n"), (2, 0));
        assert_eq!(counts("one\ntwo\n", ""), (0, 2));
        assert_eq!(counts("a\nb\nc\nd\n", "a\nc\nd\ne\n"), (1, 1));
        assert_eq!(counts("x\na\nb\n", "a\nb\ny\n"), (1, 1));
        assert_eq!(counts("line", "line\n"), (1, 1));
        assert_eq!(counts("line\r\n", "line\n"), (1, 1));
        assert!(
            difference("line", "line\n")
                .2
                .contains("-line\n\\ No newline at end of file\n+line")
        );
    }

    #[test]
    fn the_patch_has_hunks_with_context() {
        let old: String = (1..=20).map(|n| format!("line {n}\n")).collect();
        let new = old
            .replace("line 3\n", "line three\n")
            .replace("line 18\n", "");
        let (added, removed, patch) = difference(&old, &new);
        assert_eq!((added, removed), (1, 2));
        assert_eq!(patch.matches("@@ ").count(), 2, "{patch}");
        assert!(
            patch.starts_with("@@ -1,6 +1,6 @@\n line 1\n line 2\n-line 3\n+line three\n"),
            "{patch}"
        );
        assert!(patch.contains("-line 18"), "{patch}");
    }

    #[test]
    fn a_huge_rewrite_still_counts() {
        let old: String = (0..4000).map(|n| format!("{n}\n")).collect();
        let new: String = (0..4000).map(|n| format!("new {n}\n")).collect();
        assert_eq!(counts(&old, &new), (4000, 4000));
    }

    fn start(call: &str, path: &Path) -> Event {
        Event::ToolStart {
            call_id: call.into(),
            verb: "Edit".into(),
            target: path.display().to_string(),
            input: serde_json::json!({
                "path": path.display().to_string(),
                "changes": [{"path": path.display().to_string(), "kind": "update"}],
            }),
        }
    }

    fn end(call: &str) -> Event {
        Event::ToolEnd {
            call_id: call.into(),
            ok: true,
            detail: Some("Updated file".into()),
        }
    }

    fn edit_counts(events: &[Event]) -> Vec<(u32, u32)> {
        events
            .iter()
            .filter_map(|event| match event {
                Event::Edit { added, removed, .. } => Some((*added, *removed)),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn measures_from_the_index_from_the_turn_start_and_from_the_last_edit() {
        let dir = tempfile::tempdir().unwrap();
        let git = |args: &[&str]| {
            assert!(
                Command::new("git")
                    .arg("-C")
                    .arg(dir.path())
                    .args(args)
                    .status()
                    .unwrap()
                    .success()
            );
        };
        git(&["init", "-q"]);
        let clean = dir.path().join("clean.txt");
        let dirty = dir.path().join("dirty.txt");
        std::fs::write(&clean, "a\nb\n").unwrap();
        std::fs::write(&dirty, "a\nb\n").unwrap();
        git(&["add", "."]);
        // Changed before the turn: its uncommitted lines are not this turn's.
        std::fs::write(&dirty, "a\nb\nmine\n").unwrap();

        let mut measure = EditMeasure::start(dir.path());
        // The agent has already written by the time the stream is read.
        std::fs::write(&clean, "a\nB\n").unwrap();
        std::fs::write(&dirty, "a\nb\nmine\nagent\n").unwrap();
        let out = measure.observe(vec![
            start("e1", &clean),
            end("e1"),
            start("e2", &dirty),
            end("e2"),
        ]);
        assert_eq!(edit_counts(&out), vec![(1, 1), (1, 0)]);
        assert!(
            matches!(out[2], Event::Edit { ref call_id, .. } if call_id == "e1"),
            "after its end"
        );

        // A second edit of the same file counts from where the first left it.
        std::fs::write(&clean, "a\nB\nc\n").unwrap();
        assert_eq!(
            edit_counts(&measure.observe(vec![start("e3", &clean), end("e3")])),
            vec![(1, 0)]
        );

        // A new file is all added. A failed edit is not measured.
        let fresh = dir.path().join("new.txt");
        std::fs::write(&fresh, "x\ny\nz\n").unwrap();
        assert_eq!(
            edit_counts(&measure.observe(vec![start("e4", &fresh), end("e4")])),
            vec![(3, 0)]
        );
        let failed = Event::ToolEnd {
            call_id: "e5".into(),
            ok: false,
            detail: None,
        };
        assert!(edit_counts(&measure.observe(vec![start("e5", &clean), failed])).is_empty());
    }

    #[test]
    fn edits_that_carry_their_own_text_are_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let mut measure = EditMeasure::start(dir.path());
        let own = Event::ToolStart {
            call_id: "c1".into(),
            verb: "Edit".into(),
            target: "a.txt".into(),
            input: serde_json::json!({"file_path": "a.txt", "old_string": "a", "new_string": "b"}),
        };
        let out = measure.observe(vec![own, end("c1")]);
        assert_eq!(out.len(), 2);
    }

    fn repository() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        git(dir.path(), &["init", "-q"]);
        dir
    }

    fn git(dir: &Path, args: &[&str]) {
        let out = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    #[test]
    fn existing_files_in_untracked_directories_are_not_new_files() {
        let dir = repository();
        let folder = dir.path().join("untracked");
        std::fs::create_dir(&folder).unwrap();
        let file = folder.join("file.txt");
        std::fs::write(&file, "mine\n").unwrap();
        let mut measure = EditMeasure::start(dir.path());
        std::fs::write(&file, "mine\nagent\n").unwrap();
        assert_eq!(
            edit_counts(&measure.observe(vec![start("e", &file), end("e")])),
            vec![(1, 0)]
        );
    }

    #[test]
    fn staging_during_the_turn_does_not_replace_the_baseline() {
        let dir = repository();
        let file = dir.path().join("file.txt");
        std::fs::write(&file, "old\n").unwrap();
        git(dir.path(), &["add", "."]);
        let mut measure = EditMeasure::start(dir.path());
        std::fs::write(&file, "new\n").unwrap();
        git(dir.path(), &["add", "."]);
        assert_eq!(
            edit_counts(&measure.observe(vec![start("e", &file), end("e")])),
            vec![(1, 1)]
        );
    }

    #[test]
    fn clean_crlf_files_use_the_checkout_form_of_the_index() {
        for autocrlf in [true, false] {
            let dir = repository();
            if autocrlf {
                git(dir.path(), &["config", "core.autocrlf", "true"]);
            } else {
                git(dir.path(), &["config", "core.autocrlf", "false"]);
                std::fs::write(dir.path().join(".gitattributes"), "*.txt text eol=crlf\n").unwrap();
            }
            let file = dir.path().join("file.txt");
            std::fs::write(&file, "one\r\ntwo\r\nthree\r\n").unwrap();
            git(dir.path(), &["add", "."]);
            let mut measure = EditMeasure::start(dir.path());
            std::fs::write(&file, "one\r\nTWO\r\nthree\r\n").unwrap();
            assert_eq!(
                edit_counts(&measure.observe(vec![start("e", &file), end("e")])),
                vec![(1, 1)],
                "only the edited line, not every CRLF line"
            );
        }
    }

    #[test]
    fn checkout_conversions_stay_bounded_and_do_not_run_external_filters() {
        let dir = repository();
        git(dir.path(), &["config", "core.autocrlf", "true"]);
        let file = dir.path().join("file.txt");
        std::fs::write(&file, "a\r\nb\r\n").unwrap();
        git(dir.path(), &["add", "."]);
        let index = tokenstat_workspace::git::IndexSnapshot::read(dir.path()).unwrap();
        let file = canonical(&file);
        assert_eq!(index.text(&file, 6).as_deref(), Some("a\r\nb\r\n"));
        assert_eq!(
            index.text(&file, 4),
            None,
            "converted output exceeds its cap"
        );

        std::fs::write(dir.path().join(".gitattributes"), "*.txt filter=external\n").unwrap();
        git(
            dir.path(),
            &[
                "config",
                "filter.external.smudge",
                "echo unexpected > filter-ran",
            ],
        );
        assert_eq!(index.text(&file, 1024), None);
        assert!(!dir.path().join("filter-ran").exists());
    }

    #[test]
    fn deleting_the_parent_directory_still_counts_the_old_file() {
        let dir = repository();
        let folder = dir.path().join("src");
        std::fs::create_dir(&folder).unwrap();
        let file = folder.join("file.txt");
        std::fs::write(&file, "old\n").unwrap();
        git(dir.path(), &["add", "."]);
        let mut measure = EditMeasure::start(dir.path());
        std::fs::remove_dir_all(folder).unwrap();
        assert_eq!(
            edit_counts(&measure.observe(vec![start("e", &file), end("e")])),
            vec![(0, 1)]
        );
    }

    #[test]
    fn unreadable_baselines_do_not_count_as_empty_files() {
        let dir = repository();
        let file = dir.path().join("binary.txt");
        std::fs::write(&file, b"binary\0\n").unwrap();
        git(dir.path(), &["add", "."]);
        let mut measure = EditMeasure::start(dir.path());
        std::fs::write(&file, "text\n").unwrap();
        assert!(edit_counts(&measure.observe(vec![start("e1", &file), end("e1")])).is_empty());
        // Once text is known, a later change can be counted from it.
        std::fs::write(&file, "text\nmore\n").unwrap();
        assert_eq!(
            edit_counts(&measure.observe(vec![start("e2", &file), end("e2")])),
            vec![(1, 0)]
        );
    }

    #[test]
    fn files_past_the_baseline_limit_are_unknown_not_new() {
        let dir = repository();
        for n in 0..=MAX_BASELINE_FILES {
            std::fs::write(dir.path().join(format!("{n:04}.txt")), "mine\n").unwrap();
        }
        let mut measure = EditMeasure::start(dir.path());
        let file = dir.path().join(format!("{MAX_BASELINE_FILES:04}.txt"));
        std::fs::write(&file, "mine\nagent\n").unwrap();
        assert!(edit_counts(&measure.observe(vec![start("e", &file), end("e")])).is_empty());
    }

    #[test]
    fn without_a_repository_existing_content_is_not_an_addition() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("file.txt");
        std::fs::write(&file, "mine\n").unwrap();
        let mut measure = EditMeasure::start(dir.path());
        std::fs::write(&file, "mine\nagent\n").unwrap();
        assert!(edit_counts(&measure.observe(vec![start("e", &file), end("e")])).is_empty());
    }

    #[test]
    fn ignored_existing_files_are_not_inferred_to_be_new() {
        let dir = repository();
        std::fs::write(dir.path().join(".gitignore"), "ignored.txt\n").unwrap();
        let file = dir.path().join("ignored.txt");
        std::fs::write(&file, "mine\n").unwrap();
        let mut measure = EditMeasure::start(dir.path());
        std::fs::write(&file, "mine\nagent\n").unwrap();
        assert!(edit_counts(&measure.observe(vec![start("e", &file), end("e")])).is_empty());
    }
}
