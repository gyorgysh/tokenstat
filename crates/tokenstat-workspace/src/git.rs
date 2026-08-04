//! Read-only git state for a folder.
//!
//! Shells out to `git` rather than linking a git library. `git` is present on
//! any machine that has a checkout worth looking at, `--porcelain=v2` is a
//! documented stable contract meant exactly for this, and libgit2 would be a
//! large C dependency to argue about every time the app's licence guard runs.
//!
//! **Every command here is read-only.** The product rule is that tokenstat
//! never writes to, moves, or deletes anything belonging to another tool, and a
//! user's repository is the sharpest case of that. Nothing in this module may
//! grow a command that mutates: no `add`, no `commit`, no `checkout`, no
//! `stash`. If a feature needs one, it belongs behind an explicit user action
//! somewhere else, not in a status call that runs on a timer.

use std::path::Path;
use std::process::Command;

use serde::Serialize;

/// What happened to one file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ChangeKind {
    Added,
    Modified,
    Deleted,
    Renamed,
    Untracked,
    Conflicted,
}

/// One changed file.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileChange {
    /// Path relative to the repository root, as git reports it.
    pub path: String,
    pub kind: ChangeKind,
    /// Lines added, or `None` when it is not known.
    ///
    /// Untracked files have nothing to diff against, so their counts are
    /// genuinely unknown rather than zero. Same rule as everywhere else in this
    /// project: a number nobody measured is not zero.
    pub added: Option<u64>,
    pub removed: Option<u64>,
}

/// Git state of a folder.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitStatus {
    pub is_repo: bool,
    pub branch: Option<String>,
    pub upstream: Option<String>,
    /// Commits ahead of and behind the upstream, when there is one.
    pub ahead: u32,
    pub behind: u32,
    pub files: Vec<FileChange>,
    /// Totals across files whose counts are known.
    pub added: u64,
    pub removed: u64,
    /// True when at least one file's counts were unknown, so the totals above
    /// are a floor rather than the whole picture.
    pub partial: bool,
}

/// Read git state, or `is_repo: false` for anything that is not a work tree.
///
/// Never fails for "this is not a repository": a plain folder is a legitimate
/// workspace, it just has no branch. Errors are reserved for git being absent
/// or refusing to run.
pub fn status(dir: &Path) -> GitStatus {
    if !inside_work_tree(dir) {
        return GitStatus::default();
    }

    let mut status = GitStatus {
        is_repo: true,
        ..GitStatus::default()
    };

    let raw = match git(
        dir,
        &[
            "status",
            "--porcelain=v2",
            "--branch",
            "--untracked-files=all",
        ],
    ) {
        Some(s) => s,
        None => return status,
    };
    parse_porcelain_v2(&raw, &mut status);

    // Counts come from a separate command because porcelain v2 does not carry
    // them. Staged and unstaged together, which is what "changed since HEAD"
    // means to someone looking at a diff.
    if let Some(numstat) = git(dir, &["diff", "--numstat", "HEAD"]) {
        apply_numstat(&numstat, &mut status);
    }

    for f in &status.files {
        match (f.added, f.removed) {
            (Some(a), Some(r)) => {
                status.added += a;
                status.removed += r;
            }
            _ => status.partial = true,
        }
    }

    status
}

fn inside_work_tree(dir: &Path) -> bool {
    git(dir, &["rev-parse", "--is-inside-work-tree"])
        .map(|s| s.trim() == "true")
        .unwrap_or(false)
}

/// Run a read-only git command, or `None` if it fails.
fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        // A repository with a pager or an alias configured must not change what
        // these commands print, and must never open an interactive prompt in a
        // process nobody can type into.
        .env("GIT_PAGER", "cat")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .args(args)
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Parse `git status --porcelain=v2 --branch`.
///
/// Format, from `git-status(1)`:
///   `# branch.head <name>`, `# branch.upstream <name>`, `# branch.ab +N -M`
///   `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`         ordinary change
///   `2 <XY> ... <path><tab><origPath>`                     rename or copy
///   `u ...`                                                unmerged
///   `? <path>`                                             untracked
fn parse_porcelain_v2(raw: &str, status: &mut GitStatus) {
    for line in raw.lines() {
        if let Some(rest) = line.strip_prefix("# branch.head ") {
            // A repository with no commits yet reports this literally.
            status.branch = (rest != "(detached)").then(|| rest.to_string());
        } else if let Some(rest) = line.strip_prefix("# branch.upstream ") {
            status.upstream = Some(rest.to_string());
        } else if let Some(rest) = line.strip_prefix("# branch.ab ") {
            let mut parts = rest.split_whitespace();
            status.ahead = parts
                .next()
                .and_then(|s| s.strip_prefix('+'))
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            status.behind = parts
                .next()
                .and_then(|s| s.strip_prefix('-'))
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
        } else if let Some(path) = line.strip_prefix("? ") {
            status.files.push(FileChange {
                path: path.to_string(),
                kind: ChangeKind::Untracked,
                added: None,
                removed: None,
            });
        } else if let Some(rest) = line.strip_prefix("1 ") {
            if let Some((xy, path)) = entry(rest, 6) {
                status.files.push(FileChange {
                    path,
                    kind: kind_from_xy(xy),
                    added: None,
                    removed: None,
                });
            }
        } else if let Some(rest) = line.strip_prefix("2 ") {
            // Rename: the path field is `new<tab>old`. The new name is what a
            // reader is looking for.
            if let Some((_, path)) = entry(rest, 7) {
                let new = path.split('\t').next().unwrap_or(&path).to_string();
                status.files.push(FileChange {
                    path: new,
                    kind: ChangeKind::Renamed,
                    added: None,
                    removed: None,
                });
            }
        } else if let Some(rest) = line.strip_prefix("u ") {
            if let Some((_, path)) = entry(rest, 8) {
                status.files.push(FileChange {
                    path,
                    kind: ChangeKind::Conflicted,
                    added: None,
                    removed: None,
                });
            }
        }
    }
}

/// Split an entry into its `XY` field and its path.
///
/// The path is the last field and may itself contain spaces, so this splits by
/// field count from the left rather than splitting the whole line. `skip` is
/// how many fields sit between `XY` and the path, and it differs per entry
/// type: ordinary has 6, rename has 7 (it carries a similarity score), and
/// unmerged has 8 (three stages of mode and hash).
fn entry(rest: &str, skip: usize) -> Option<(&str, String)> {
    let mut it = rest.splitn(skip + 2, ' ');
    let xy = it.next()?;
    for _ in 0..skip {
        it.next()?;
    }
    Some((xy, it.next()?.to_string()))
}

/// Rebuild the new path from a numstat rename.
///
/// git writes the common prefix and suffix once: `docs/{old.md => new.md}`
/// means `docs/new.md`. Taking the tail after the arrow would give `new.md}`
/// and quietly lose the directory, so the file would never match the one
/// `status` reported and its counts would be dropped.
fn numstat_new_path(field: &str) -> String {
    let (open, arrow) = match (field.find('{'), field.find(" => ")) {
        (_, None) => return field.to_string(),
        // No braces: the whole path was replaced, so the tail is the new path.
        (None, Some(a)) => return field[a + 4..].to_string(),
        (Some(o), Some(a)) => (o, a),
    };
    let Some(close) = field[arrow..].find('}').map(|i| i + arrow) else {
        return field[arrow + 4..].to_string();
    };
    format!(
        "{}{}{}",
        &field[..open],
        &field[arrow + 4..close],
        &field[close + 1..]
    )
}

/// `XY` is the staged and unstaged state. Either half being a real change
/// decides the kind, with staged winning when both say something.
fn kind_from_xy(xy: &str) -> ChangeKind {
    let staged = xy.chars().next().unwrap_or('.');
    let unstaged = xy.chars().nth(1).unwrap_or('.');
    for c in [staged, unstaged] {
        match c {
            'A' => return ChangeKind::Added,
            'D' => return ChangeKind::Deleted,
            'R' | 'C' => return ChangeKind::Renamed,
            'M' | 'T' => return ChangeKind::Modified,
            _ => {}
        }
    }
    ChangeKind::Modified
}

/// Attach counts from `git diff --numstat`.
///
/// Binary files print `-` for both columns, which stays unknown rather than
/// becoming zero: a changed image is not an unchanged one.
fn apply_numstat(raw: &str, status: &mut GitStatus) {
    for line in raw.lines() {
        let mut parts = line.splitn(3, '\t');
        let (a, r, path) = match (parts.next(), parts.next(), parts.next()) {
            (Some(a), Some(r), Some(p)) => (a, r, p),
            _ => continue,
        };
        // A rename prints `docs/{old => new}` here but the plain new name in
        // status, so rebuild it before matching.
        let path = numstat_new_path(path);
        if let Some(f) = status.files.iter_mut().find(|f| f.path == path) {
            f.added = a.parse().ok();
            f.removed = r.parse().ok();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plain_folder_is_not_an_error() {
        // A workspace does not have to be a repository. Reporting that as a
        // failure would make every scratch folder look broken.
        let dir = std::env::temp_dir();
        let s = status(&dir);
        if !s.is_repo {
            assert!(s.branch.is_none());
            assert!(s.files.is_empty());
        }
    }

    /// Drive real `git` against a throwaway repository.
    ///
    /// The parsing tests above use captured output, which cannot catch the
    /// field counts drifting. This one can: it is how the ordinary-versus-rename
    /// off-by-one was found.
    #[test]
    fn a_real_repository_reports_its_changes() {
        use std::process::Command;

        let dir = std::env::temp_dir().join(format!("tokenstat-git-live-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let run = |args: &[&str]| {
            Command::new("git")
                .arg("-C")
                .arg(&dir)
                .args(args)
                .output()
                .expect("git must be installed to run this test")
        };
        run(&["init", "-q", "."]);
        run(&["config", "user.email", "t@example.invalid"]);
        run(&["config", "user.name", "t"]);

        std::fs::create_dir_all(dir.join("docs")).unwrap();
        std::fs::write(dir.join("tracked.rs"), "a\nb\n").unwrap();
        std::fs::write(dir.join("docs/my notes.md"), "x\n").unwrap();
        run(&["add", "-A"]);
        run(&["commit", "-qm", "init"]);

        std::fs::write(dir.join("tracked.rs"), "a\nb\nc\n").unwrap();
        run(&["mv", "docs/my notes.md", "docs/renamed.md"]);
        std::fs::write(dir.join("untracked.txt"), "n\n").unwrap();

        let s = status(&dir);
        assert!(s.is_repo);
        assert!(s.branch.is_some(), "a fresh repo still has a branch");

        let by_path: std::collections::HashMap<_, _> =
            s.files.iter().map(|f| (f.path.as_str(), f)).collect();

        // The modified file must carry real counts, which only works if the
        // field count and the numstat join are both right.
        let tracked = by_path.get("tracked.rs").expect("modified file listed");
        assert_eq!(tracked.kind, ChangeKind::Modified);
        assert_eq!(tracked.added, Some(1));

        // A path with a space survives, and a rename keeps its directory.
        assert!(
            by_path.contains_key("docs/renamed.md"),
            "rename should be reported at its new path, got {:?}",
            by_path.keys().collect::<Vec<_>>()
        );
        assert_eq!(
            by_path.get("untracked.txt").unwrap().kind,
            ChangeKind::Untracked
        );
        assert!(s.partial, "an untracked file makes the totals a floor");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn branch_and_counts_parse() {
        let mut s = GitStatus::default();
        parse_porcelain_v2(
            "# branch.oid abc\n\
             # branch.head main\n\
             # branch.upstream origin/main\n\
             # branch.ab +3 -2\n",
            &mut s,
        );
        assert_eq!(s.branch.as_deref(), Some("main"));
        assert_eq!(s.upstream.as_deref(), Some("origin/main"));
        assert_eq!(s.ahead, 3);
        assert_eq!(s.behind, 2);
    }

    #[test]
    fn a_detached_head_has_no_branch() {
        let mut s = GitStatus::default();
        parse_porcelain_v2("# branch.head (detached)\n", &mut s);
        assert!(s.branch.is_none());
    }

    #[test]
    fn every_entry_kind_is_recognised() {
        let mut s = GitStatus::default();
        parse_porcelain_v2(
            "1 M. N... 100644 100644 100644 aaa bbb src/changed.rs\n\
             1 A. N... 100644 100644 100644 aaa bbb src/new.rs\n\
             1 .D N... 100644 100644 100644 aaa bbb src/gone.rs\n\
             2 R. N... 100644 100644 100644 aaa bbb R100 src/new_name.rs\tsrc/old_name.rs\n\
             ? untracked.txt\n",
            &mut s,
        );
        let kinds: Vec<_> = s.files.iter().map(|f| (f.path.as_str(), f.kind)).collect();
        assert!(kinds.contains(&("src/changed.rs", ChangeKind::Modified)));
        assert!(kinds.contains(&("src/new.rs", ChangeKind::Added)));
        assert!(kinds.contains(&("src/gone.rs", ChangeKind::Deleted)));
        assert!(kinds.contains(&("untracked.txt", ChangeKind::Untracked)));
        assert!(s.files.iter().any(|f| f.kind == ChangeKind::Renamed));
    }

    #[test]
    fn a_path_with_spaces_survives() {
        // The path is the last field and can contain spaces. Splitting the
        // whole line on whitespace would truncate it.
        let mut s = GitStatus::default();
        parse_porcelain_v2(
            "1 M. N... 100644 100644 100644 aaa bbb docs/my notes.md\n",
            &mut s,
        );
        assert_eq!(s.files[0].path, "docs/my notes.md");
    }

    #[test]
    fn untracked_and_binary_counts_stay_unknown() {
        let mut s = GitStatus::default();
        parse_porcelain_v2(
            "? new.png\n\
             1 M. N... 100644 100644 100644 aaa bbb logo.png\n",
            &mut s,
        );
        apply_numstat("-\t-\tlogo.png\n", &mut s);

        // A changed binary is not an unchanged one, and an untracked file has
        // nothing to diff against. Neither is zero.
        assert!(s.files.iter().all(|f| f.added.is_none()));
    }

    #[test]
    fn totals_are_marked_partial_when_a_count_is_unknown() {
        let mut s = GitStatus::default();
        parse_porcelain_v2(
            "1 M. N... 100644 100644 100644 aaa bbb a.rs\n\
             ? b.png\n",
            &mut s,
        );
        apply_numstat("10\t2\ta.rs\n", &mut s);
        for f in &s.files {
            match (f.added, f.removed) {
                (Some(a), Some(r)) => {
                    s.added += a;
                    s.removed += r;
                }
                _ => s.partial = true,
            }
        }
        assert_eq!(s.added, 10);
        assert_eq!(s.removed, 2);
        assert!(s.partial, "an unknown count must mark the total as a floor");
    }

    #[test]
    fn renamed_files_get_their_counts() {
        let mut s = GitStatus::default();
        parse_porcelain_v2(
            "2 R. N... 100644 100644 100644 aaa bbb R100 src/new.rs\tsrc/old.rs\n",
            &mut s,
        );
        apply_numstat("4\t1\tsrc/old.rs => src/new.rs\n", &mut s);
        assert_eq!(s.files[0].added, Some(4));
    }
}
