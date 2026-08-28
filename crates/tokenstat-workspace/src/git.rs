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

/// One branch a person can switch this worktree to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Branch {
    pub name: String,
    pub current: bool,
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    /// Commit time in unix seconds. Zero means git had no commit to report.
    pub last_commit: i64,
    /// A remote-tracking branch with no local branch of the same name.
    pub remote: bool,
}

/// One commit, as the history panel shows it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Commit {
    /// Full hash. The abbreviation is the reader's job, not the parser's.
    pub id: String,
    pub subject: String,
    pub author: String,
    /// Author email, so a reader can tell two people with the same name apart
    /// and can draw a stable mark for each of them.
    pub email: String,
    /// Author time in unix seconds. Author rather than commit time, because
    /// that is when the work was done, and a rebase should not restate it.
    pub timestamp: i64,
    /// True while this commit is not on the upstream branch yet. False when
    /// there is no upstream, because then nothing is known to be behind rather
    /// than everything being unpushed.
    pub unpushed: bool,
    /// Authored by the identity this repository is configured with, so a front
    /// end can show the signed-in person's own picture beside it.
    ///
    /// Decided here rather than in the app: `user.email` is git's answer to
    /// "who am I in this repository", it can differ per repository, and the app
    /// has no other way to learn it.
    pub mine: bool,
}

/// What one line of a diff is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DiffLineKind {
    Context,
    Added,
    Removed,
}

/// One line of a diff, carrying the numbers both sides would show in a gutter.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffLine {
    pub kind: DiffLineKind,
    /// Line number on the left, absent for an added line.
    pub old_line: Option<u32>,
    /// Line number on the right, absent for a removed line.
    pub new_line: Option<u32>,
    /// The line without its leading `+`, `-` or space.
    pub text: String,
}

/// One `@@` hunk.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffHunk {
    /// The `@@ ... @@` line, including any trailing section heading git found.
    pub header: String,
    pub lines: Vec<DiffLine>,
}

/// The diff of one file against HEAD.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileDiff {
    pub path: String,
    pub hunks: Vec<DiffHunk>,
    /// True when git refused to diff it as text. There is nothing to show, and
    /// showing nothing without saying why looks like an empty file.
    pub binary: bool,
    /// True when the file is not tracked, so every line reads as added.
    pub untracked: bool,
}

fn path_allowed(path: &str) -> bool {
    crate::tree::assert_relative_inside(path).is_ok()
}

/// Reject option-like and empty revision strings before they reach git.
fn safe_rev(id: &str) -> bool {
    let id = id.trim();
    if id.is_empty() || id.starts_with('-') {
        return false;
    }
    // Allow hex hashes, HEAD, and common relative forms without shell metachars.
    id.chars().all(|c| {
        c.is_ascii_alphanumeric()
            || matches!(c, '/' | '_' | '-' | '.' | '~' | '^' | '@' | '{' | '}')
    })
}

/// Diff one file against HEAD, staged and unstaged together.
///
/// An untracked file has nothing to diff against, so it is compared with an
/// empty file and every line comes back added, which is what someone looking at
/// a new file expects to see.
pub fn diff(dir: &Path, path: &str) -> FileDiff {
    let mut out = FileDiff {
        path: path.to_string(),
        ..FileDiff::default()
    };
    if !inside_work_tree(dir) {
        return out;
    }
    if !path_allowed(path) {
        return out;
    }

    let tracked = git(dir, &["ls-files", "--error-unmatch", "--", path]).is_some();
    out.untracked = !tracked;

    let raw = if tracked {
        git(dir, &["diff", "HEAD", "--", path])
    } else {
        // `--no-index` exits 1 when the files differ, which is the normal
        // answer here rather than a failure.
        git_allowing(
            dir,
            &["diff", "--no-index", "--", "/dev/null", path],
            &[0, 1],
        )
    };

    let Some(raw) = raw else { return out };
    if raw.lines().any(|l| l.starts_with("Binary files ")) {
        out.binary = true;
        return out;
    }
    out.hunks = parse_diff(&raw);
    out
}

/// Parse unified diff output into hunks with both gutters filled in.
fn parse_diff(raw: &str) -> Vec<DiffHunk> {
    let mut hunks: Vec<DiffHunk> = Vec::new();
    let (mut old_no, mut new_no) = (0u32, 0u32);

    for line in raw.lines() {
        if line.starts_with("@@") {
            let (old_start, new_start) = hunk_starts(line);
            old_no = old_start;
            new_no = new_start;
            hunks.push(DiffHunk {
                header: line.to_string(),
                lines: Vec::new(),
            });
            continue;
        }
        let Some(hunk) = hunks.last_mut() else {
            // Everything before the first `@@` is the file header.
            continue;
        };
        // "\ No newline at end of file" is a note about the previous line, not
        // a line of the file, and numbering it would shift every line after it.
        if line.starts_with('\\') {
            continue;
        }

        let mut chars = line.chars();
        let (kind, text) = match chars.next() {
            Some('+') => (DiffLineKind::Added, chars.as_str()),
            Some('-') => (DiffLineKind::Removed, chars.as_str()),
            Some(' ') => (DiffLineKind::Context, chars.as_str()),
            // An empty line in the body is an empty context line: git writes
            // the leading space, but some tools strip trailing whitespace.
            None => (DiffLineKind::Context, ""),
            // Anything else belongs to a header we are not in a hunk for.
            _ => continue,
        };

        let (old_line, new_line) = match kind {
            DiffLineKind::Added => {
                new_no += 1;
                (None, Some(new_no))
            }
            DiffLineKind::Removed => {
                old_no += 1;
                (Some(old_no), None)
            }
            DiffLineKind::Context => {
                old_no += 1;
                new_no += 1;
                (Some(old_no), Some(new_no))
            }
        };
        hunk.lines.push(DiffLine {
            kind,
            old_line,
            new_line,
            text: text.to_string(),
        });
    }
    hunks
}

/// Pull the two starting line numbers out of `@@ -a,b +c,d @@`.
///
/// The counts are omitted when they are 1, so `-a +c` is legal and has to
/// parse the same way.
fn hunk_starts(header: &str) -> (u32, u32) {
    let mut old = 0;
    let mut new = 0;
    for field in header.split_whitespace() {
        let number = |s: &str| -> u32 {
            s.split(',')
                .next()
                .and_then(|n| n.parse::<u32>().ok())
                .unwrap_or(1)
                // The header names the first line; the parser counts up from
                // the one before it.
                .saturating_sub(1)
        };
        if let Some(rest) = field.strip_prefix('-') {
            old = number(rest);
        } else if let Some(rest) = field.strip_prefix('+') {
            new = number(rest);
        }
    }
    (old, new)
}

/// One commit in full: what it says, and what it changed.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitDetail {
    pub id: String,
    pub subject: String,
    /// Everything after the subject, trimmed. Empty when there is none.
    pub body: String,
    pub author: String,
    pub email: String,
    pub timestamp: i64,
    /// Parent hashes. Two or more means a merge, which is why the diff below
    /// can be empty for a commit that plainly changed things.
    pub parents: Vec<String>,
    pub files: Vec<FileChange>,
    pub added: u64,
    pub removed: u64,
    /// Per-file diffs, in the order the files are listed.
    pub diffs: Vec<FileDiff>,
}

/// Read one commit: its message, its files, and their diffs.
///
/// `id` is passed to git as a revision, so it accepts a hash, a tag, `HEAD~2`,
/// or anything else git resolves. An unknown revision comes back as `None`
/// rather than an error, because the caller asked about something that is not
/// there rather than doing something wrong.
pub fn show(dir: &Path, id: &str) -> Option<CommitDetail> {
    if !inside_work_tree(dir) {
        return None;
    }
    if !safe_rev(id) {
        return None;
    }

    let format = format!("--format=%H{US}%s{US}%b{US}%an{US}%ae{US}%at{US}%P");
    // Rev already passed safe_rev (no leading dash). Do not put `--` before it:
    // git would treat the id as a pathspec.
    let raw = git(dir, &["show", "--no-patch", &format, id])?;
    let mut fields = raw.trim_end_matches('\n').splitn(7, US);

    let mut detail = CommitDetail {
        id: fields.next()?.to_string(),
        subject: fields.next()?.to_string(),
        body: fields.next()?.trim().to_string(),
        author: fields.next()?.to_string(),
        email: fields.next()?.to_string(),
        timestamp: fields.next()?.trim().parse().ok()?,
        parents: fields
            .next()?
            .split_whitespace()
            .map(str::to_string)
            .collect(),
        ..CommitDetail::default()
    };

    // Names and statuses, then counts, the same two-command split `status` uses
    // and for the same reason: neither command reports both.
    let range = format!("{id}^!");
    if let Some(names) = git(dir, &["diff", "--name-status", "-M", &range]) {
        for line in names.lines() {
            let mut parts = line.split('\t');
            let (Some(status), Some(first)) = (parts.next(), parts.next()) else {
                continue;
            };
            // A rename prints `R100<tab>old<tab>new`. The new name is the one a
            // reader is looking for, and the one the diff is keyed by.
            let path = parts.next().unwrap_or(first).to_string();
            detail.files.push(FileChange {
                path,
                kind: kind_from_xy(status),
                added: None,
                removed: None,
            });
        }
    }
    if let Some(numstat) = git(dir, &["diff", "--numstat", "-M", &range]) {
        let mut status = GitStatus {
            files: std::mem::take(&mut detail.files),
            ..GitStatus::default()
        };
        apply_numstat(&numstat, &mut status);
        detail.files = status.files;
    }
    for f in &detail.files {
        detail.added += f.added.unwrap_or(0);
        detail.removed += f.removed.unwrap_or(0);
    }

    detail.diffs = detail
        .files
        .iter()
        .map(|f| {
            let raw = git(dir, &["diff", "-M", &range, "--", &f.path]).unwrap_or_default();
            FileDiff {
                path: f.path.clone(),
                binary: raw.lines().any(|l| l.starts_with("Binary files ")),
                untracked: false,
                hunks: parse_diff(&raw),
            }
        })
        .collect();

    Some(detail)
}

/// Read the most recent commits, newest first.
///
/// Empty for a folder that is not a repository, and for a repository with no
/// commits yet. Neither is an error: one is a plain folder and the other is a
/// repository someone just made.
pub fn log(dir: &Path, limit: u32) -> Vec<Commit> {
    if !inside_work_tree(dir) {
        return Vec::new();
    }

    // Unit separator between fields and record separator between commits, so a
    // subject containing a newline or a tab cannot shift the parse. `%x1f` and
    // `%x1e` are exactly what those two ASCII controls are for.
    let format = format!("--format=%H{US}%s{US}%an{US}%ae{US}%at{RS}");
    let raw = match git(
        dir,
        &["log", &format!("--max-count={limit}"), &format, "HEAD"],
    ) {
        Some(s) => s,
        None => return Vec::new(),
    };

    // Which commits are not upstream yet. A separate command because deriving
    // it from the ahead count assumes a linear history, and a merge breaks that
    // assumption silently.
    let unpushed: std::collections::HashSet<String> = git(dir, &["rev-list", "@{upstream}..HEAD"])
        .map(|s| s.lines().map(|l| l.trim().to_string()).collect())
        .unwrap_or_default();

    // Who this repository thinks you are. Read once per history rather than
    // per commit, and left empty when git has no answer: an empty identity
    // matches nobody, which is the right outcome for a repository with no
    // `user.email` set.
    let me = configured_email(dir);

    parse_log(&raw, &unpushed, me.as_deref())
}

/// `user.email` for this repository, honouring any per-repository override.
fn configured_email(dir: &Path) -> Option<String> {
    let value = git(dir, &["config", "--get", "user.email"])?;
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_ascii_lowercase())
}

const US: char = '\u{1f}';
const RS: char = '\u{1e}';

fn parse_log(
    raw: &str,
    unpushed: &std::collections::HashSet<String>,
    me: Option<&str>,
) -> Vec<Commit> {
    raw.split(RS)
        .map(str::trim_start)
        .filter(|record| !record.is_empty())
        .filter_map(|record| {
            let mut fields = record.splitn(5, US);
            let id = fields.next()?.to_string();
            let subject = fields.next()?.to_string();
            let author = fields.next()?.to_string();
            let email = fields.next()?.to_string();
            let timestamp = fields.next()?.trim().parse().ok()?;
            // Addresses are case insensitive in practice and git does not
            // normalise them, so a repository configured with `Ada@Example.com`
            // still recognises its own commits.
            let mine = me.is_some_and(|me| me == email.trim().to_ascii_lowercase());
            Some(Commit {
                unpushed: unpushed.contains(&id),
                id,
                subject,
                author,
                email,
                timestamp,
                mine,
            })
        })
        .collect()
}

/// Read git state, or `is_repo: false` for anything that is not a work tree.
///
/// Never fails for "this is not a repository": a plain folder is a legitimate
/// workspace, it just has no branch. Errors are reserved for git being absent
/// or refusing to run.
///
/// One `git status` is enough to decide "is this a repo": a separate
/// `rev-parse` was a full process spawn for every folder on every list, and
/// the status command already fails cleanly outside a work tree.
pub fn status(dir: &Path) -> GitStatus {
    let raw = match git(
        dir,
        &[
            "status",
            "--porcelain=v2",
            "--branch",
            // `normal` lists untracked files but does not recurse into
            // untracked directories. `all` did, and on a build tree or a
            // monorepo that walk dominated `workspace.list`. The sidebar
            // needs to know something is dirty, not every file under
            // `target/` or `node_modules/` that was never gitignored.
            "--untracked-files=normal",
        ],
    ) {
        Some(s) => s,
        // Not a repository, or git is missing. A plain folder is a valid
        // workspace with no branch.
        None => return GitStatus::default(),
    };

    let mut status = GitStatus {
        is_repo: true,
        ..GitStatus::default()
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

/// List local branches and remote-tracking branches in one git process.
///
/// Remote refs that already have a same-named local branch are omitted. The
/// picker presents those as one local branch with its upstream, rather than as
/// two choices that appear to do the same thing.
pub fn branches(dir: &Path) -> Vec<Branch> {
    let Some(raw) = git(
        dir,
        &[
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname)%1f%(refname:short)%1f%(HEAD)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(committerdate:unix)",
            "refs/heads",
            "refs/remotes",
        ],
    ) else {
        return Vec::new();
    };

    let records: Vec<_> = raw.lines().filter_map(parse_branch).collect();
    let local_names: std::collections::HashSet<_> = records
        .iter()
        .filter(|branch| !branch.remote)
        .map(|branch| branch.name.clone())
        .collect();
    records
        .into_iter()
        .filter(|branch| {
            if !branch.remote {
                return true;
            }
            let Some((_, local_name)) = branch.name.split_once('/') else {
                return false;
            };
            local_name != "HEAD" && !local_names.contains(local_name)
        })
        .collect()
}

fn parse_branch(record: &str) -> Option<Branch> {
    let mut fields = record.split('\u{1f}');
    let refname = fields.next()?;
    let name = fields.next()?.to_string();
    let current = fields.next()?.trim() == "*";
    let upstream = fields
        .next()
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let track = fields.next().unwrap_or_default();
    let last_commit = fields
        .next()
        .unwrap_or_default()
        .trim()
        .parse()
        .unwrap_or(0);
    let remote = refname.starts_with("refs/remotes/");
    let mut ahead = 0;
    let mut behind = 0;
    for part in track.split(',').map(str::trim) {
        if let Some(value) = part.strip_prefix("ahead ") {
            ahead = value.parse().unwrap_or(0);
        } else if let Some(value) = part.strip_prefix("behind ") {
            behind = value.parse().unwrap_or(0);
        }
    }
    Some(Branch {
        name,
        current,
        upstream,
        ahead,
        behind,
        last_commit,
        remote,
    })
}

fn inside_work_tree(dir: &Path) -> bool {
    git(dir, &["rev-parse", "--is-inside-work-tree"])
        .map(|s| s.trim() == "true")
        .unwrap_or(false)
}

/// Run a read-only git command, or `None` if it fails.
fn git(dir: &Path, args: &[&str]) -> Option<String> {
    git_allowing(dir, args, &[0])
}

/// As [`git`], but for commands whose non-zero exit is an answer rather than a
/// failure. `diff --no-index` exits 1 to say "these differ", which is exactly
/// what it was asked.
fn git_allowing(dir: &Path, args: &[&str], codes: &[i32]) -> Option<String> {
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
    codes
        .contains(&out.status.code().unwrap_or(-1))
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
    fn branch_records_keep_tracking_and_remote_shape() {
        let local = parse_branch("refs/heads/work\u{1f}work\u{1f}*\u{1f}origin/work\u{1f}ahead 2, behind 1\u{1f}1700000000")
            .expect("local branch");
        assert_eq!(local.name, "work");
        assert!(local.current);
        assert_eq!(local.upstream.as_deref(), Some("origin/work"));
        assert_eq!((local.ahead, local.behind), (2, 1));
        assert!(!local.remote);

        let remote = parse_branch(
            "refs/remotes/origin/review\u{1f}origin/review\u{1f} \u{1f}\u{1f}\u{1f}1690000000",
        )
        .expect("remote branch");
        assert!(remote.remote);
        assert_eq!(remote.last_commit, 1_690_000_000);
    }

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
    fn a_subject_with_control_characters_does_not_shift_the_parse() {
        // The whole reason for the unit and record separators: a subject can
        // contain a newline or a tab, and splitting on either would turn one
        // commit into two and misattribute every field after it.
        let raw = format!(
            "aaa{US}fix: a subject\nwith a newline{US}Ada{US}ada@example.com{US}1700000000{RS}\
             bbb{US}feat: plain{US}Grace{US}grace@example.com{US}1700000100{RS}"
        );
        let unpushed = ["bbb".to_string()].into_iter().collect();
        let commits = parse_log(&raw, &unpushed, None);

        assert_eq!(commits.len(), 2);
        assert_eq!(commits[0].subject, "fix: a subject\nwith a newline");
        assert_eq!(commits[0].author, "Ada");
        assert_eq!(commits[0].email, "ada@example.com");
        assert_eq!(commits[0].timestamp, 1_700_000_000);
        assert!(!commits[0].unpushed);
        assert!(commits[1].unpushed);
    }

    #[test]
    fn the_configured_identity_claims_its_own_commits() {
        // Case is not part of an address in practice, and git stores whatever
        // was typed, so a repository set up as `Ada@Example.com` still has to
        // recognise a commit authored as `ada@example.com`.
        let raw = format!(
            "aaa{US}fix: mine{US}Ada{US}Ada@Example.com{US}1700000000{RS}\
             bbb{US}fix: theirs{US}Grace{US}grace@example.com{US}1700000100{RS}"
        );
        let unpushed = std::collections::HashSet::new();
        let commits = parse_log(&raw, &unpushed, Some("ada@example.com"));

        assert!(commits[0].mine, "the configured address is this person");
        assert!(!commits[1].mine, "somebody else's commit is not theirs");

        // No identity configured: nothing is claimed, rather than everything.
        let anonymous = parse_log(&raw, &unpushed, None);
        assert!(anonymous.iter().all(|commit| !commit.mine));
    }

    #[test]
    fn a_diff_numbers_both_gutters() {
        let hunks = parse_diff(
            "diff --git a/a.rs b/a.rs\n\
             --- a/a.rs\n\
             +++ b/a.rs\n\
             @@ -10,4 +10,5 @@ fn main() {\n\
             \x20context one\n\
             -gone\n\
             +new one\n\
             +new two\n\
             \x20context two\n",
        );
        assert_eq!(hunks.len(), 1);
        assert!(hunks[0].header.ends_with("fn main() {"));

        let rows: Vec<_> = hunks[0]
            .lines
            .iter()
            .map(|l| (l.kind, l.old_line, l.new_line, l.text.as_str()))
            .collect();
        assert_eq!(
            rows,
            vec![
                (DiffLineKind::Context, Some(10), Some(10), "context one"),
                (DiffLineKind::Removed, Some(11), None, "gone"),
                (DiffLineKind::Added, None, Some(11), "new one"),
                (DiffLineKind::Added, None, Some(12), "new two"),
                // The removed line advanced only the left gutter and the added
                // lines only the right, so the trailing context has to land on
                // 12 and 13. Getting this wrong is invisible until someone
                // reads a line number.
                (DiffLineKind::Context, Some(12), Some(13), "context two"),
            ]
        );
    }

    #[test]
    fn a_hunk_header_without_counts_parses() {
        // git omits the count when it is 1, so `@@ -3 +3 @@` is legal.
        let hunks = parse_diff("@@ -3 +7 @@\n-old\n+new\n");
        assert_eq!(hunks[0].lines[0].old_line, Some(3));
        assert_eq!(hunks[0].lines[1].new_line, Some(7));
    }

    #[test]
    fn a_no_newline_marker_does_not_shift_the_numbering() {
        let hunks = parse_diff("@@ -1,2 +1,2 @@\n-old\n\\ No newline at end of file\n+new\n");
        assert_eq!(hunks[0].lines.len(), 2);
        assert_eq!(hunks[0].lines[1].new_line, Some(1));
    }

    #[test]
    fn an_untracked_file_reads_as_entirely_added() {
        let dir = std::env::temp_dir().join(format!("tokenstat-diff-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(&dir)
                .args(args)
                .output()
                .expect("git must be installed to run this test")
        };
        run(&["init", "-q", "."]);
        run(&["config", "user.email", "t@example.invalid"]);
        run(&["config", "user.name", "t"]);
        std::fs::write(dir.join("seed.txt"), "seed\n").unwrap();
        run(&["add", "-A"]);
        run(&["commit", "-qm", "init"]);

        std::fs::write(dir.join("new.txt"), "alpha\nbeta\n").unwrap();
        let d = diff(&dir, "new.txt");
        assert!(d.untracked);
        assert!(!d.binary);
        let kinds: Vec<_> = d.hunks[0].lines.iter().map(|l| l.kind).collect();
        assert_eq!(kinds, vec![DiffLineKind::Added, DiffLineKind::Added]);

        // And a tracked edit still diffs against HEAD.
        std::fs::write(dir.join("seed.txt"), "seed\nmore\n").unwrap();
        let d = diff(&dir, "seed.txt");
        assert!(!d.untracked);
        assert!(
            d.hunks[0]
                .lines
                .iter()
                .any(|l| l.kind == DiffLineKind::Added && l.text == "more")
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_commit_reads_back_with_its_message_and_diff() {
        let dir = std::env::temp_dir().join(format!("tokenstat-show-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(&dir)
                .args(args)
                .output()
                .expect("git must be installed to run this test");
        };
        run(&["init", "-q", "."]);
        run(&["config", "user.email", "t@example.invalid"]);
        run(&["config", "user.name", "Ada"]);
        std::fs::write(dir.join("a.txt"), "one\n").unwrap();
        run(&["add", "-A"]);
        run(&["commit", "-qm", "init"]);

        std::fs::write(dir.join("a.txt"), "one\ntwo\n").unwrap();
        std::fs::write(dir.join("b.txt"), "new\n").unwrap();
        run(&["add", "-A"]);
        run(&[
            "commit",
            "-qm",
            "feat: two things\n\nA body that\nspans lines.",
        ]);

        let detail = show(&dir, "HEAD").expect("HEAD resolves");
        assert_eq!(detail.subject, "feat: two things");
        assert_eq!(detail.body, "A body that\nspans lines.");
        assert_eq!(detail.author, "Ada");
        assert_eq!(detail.parents.len(), 1);

        let paths: Vec<_> = detail.files.iter().map(|f| f.path.as_str()).collect();
        assert!(
            paths.contains(&"a.txt") && paths.contains(&"b.txt"),
            "{paths:?}"
        );
        assert_eq!(detail.added, 2, "one line in each file");

        // The diffs are the point: a commit list nobody can open is a list.
        let a = detail.diffs.iter().find(|d| d.path == "a.txt").unwrap();
        assert!(
            a.hunks[0]
                .lines
                .iter()
                .any(|l| l.kind == DiffLineKind::Added && l.text == "two")
        );

        // The first commit has no parent, and `id^!` still has to work there.
        let first = show(&dir, "HEAD~1").expect("the root commit resolves");
        assert!(first.parents.is_empty());
        assert_eq!(first.subject, "init");

        assert!(show(&dir, "nope-not-a-rev").is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_plain_folder_has_no_history() {
        let commits = log(&std::env::temp_dir(), 20);
        assert!(commits.is_empty());
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
