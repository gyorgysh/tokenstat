// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! What to offer somebody part-way through typing a command in an SSH session.
//!
//! Two honest sources and no third one. A saved snippet is something the
//! person wrote down themselves, and a directory name is something the server
//! was asked for over the session that is already open. Nothing here guesses
//! at shell history, walks `PATH`, or installs anything on the far end, and
//! nothing is ever sent to the shell because a row happens to be highlighted.
//!
//! The ranking lives in the host rather than in a client so that the Mac,
//! Windows and Android all offer the same rows in the same order, and so that
//! the parts worth testing (which token is being completed, what a name has to
//! be escaped to, which row wins) are tested once.

use serde::Serialize;

/// The most rows a palette is ever given.
///
/// Six is what a person reads without scanning. A longer list is a list
/// somebody has to search, which is the work the palette exists to save.
pub(crate) const MAX_ROWS: usize = 6;

/// What a row inserts, and what it replaces to do it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Row {
    /// What this row came from, and the glyph the client draws for it:
    /// `directory` and `file` are names the server reported, `visited` is a
    /// folder this session has been in, `history` is a command run in it, and
    /// `snippet` is one somebody saved.
    pub kind: &'static str,
    /// The short name a person reads.
    pub title: String,
    /// The quieter second line: the full path, or the command a snippet runs.
    pub detail: String,
    /// The text to type once `replace` characters have been rubbed out.
    pub insert: String,
    /// How many characters of the typed fragment this row stands in for,
    /// counted from the end. The client sends that many backspaces first.
    pub replace: usize,
    /// `{{placeholder}}` names in a snippet, so the client can ask for them
    /// before the command is inserted. Empty for a path, and always written:
    /// a strict decoder on the other end reads a missing key as a broken
    /// answer rather than as an empty list.
    pub variables: Vec<String>,
}

/// One name the far end listed, already split into what it is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Entry {
    pub name: String,
    pub directory: bool,
}

/// A saved command, in the shape the ranking needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Snippet {
    pub title: String,
    pub command: String,
    pub tags: Vec<String>,
    pub variables: Vec<String>,
    /// Saved against the server this session is on, rather than against every
    /// server. Those lead, because somebody scoped them on purpose.
    pub scoped: bool,
}

/// The last word of a command line, and where it starts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Token {
    /// Byte offset into the fragment. Also the length of everything before it.
    pub start: usize,
    /// The characters as typed, backslash escapes and all.
    pub text: String,
    /// Whether anything precedes it, which is what makes it an argument
    /// rather than the command itself.
    pub first: bool,
    /// The line has an open quote, so the cursor is inside a string. Nothing
    /// is offered there: an escaped path dropped into a half-written quote
    /// makes a line that reads as something other than what it does.
    pub open_quote: bool,
}

impl Token {
    /// The path this token means, with `\ ` and friends turned back into the
    /// characters they stand for.
    pub fn literal(&self) -> String {
        unescape(&self.text)
    }
}

/// Which directory a token wants listed, and what it wants filtered out of it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PathQuery {
    /// The directory to list. Absolute, or `~`-rooted, or relative to the
    /// session's own directory when one is known.
    pub dir: String,
    /// What the completed name has to start with. Empty right after a slash.
    pub prefix: String,
    /// Everything before the last slash, as it should be re-typed. `""` when
    /// the token has no slash in it at all.
    pub head: String,
}

/// Punctuation that starts a whole new command. The word after one of these
/// is a program name again, so nothing is completed against it.
const COMMAND_BREAKS: &[char] = &['|', ';', '&', '(', ')', '`', '{', '}', '\n'];

/// Punctuation that ends a word without ending the command. What follows a
/// redirect or an `=` is a path, which is exactly what is worth completing:
/// `--config=/etc/n` should offer the file, not the flag.
const WORD_BREAKS: &[char] = &[' ', '\t', '<', '>', '='];

/// Split off the word the cursor is sitting at the end of.
///
/// A backslash escapes the character after it, which is how a space becomes
/// part of a path rather than the end of one. Quotes are deliberately not
/// understood: a token that opens one is left alone by `path_query`, because
/// inserting an escaped path into a half-open quote produces a line that says
/// something other than what it looks like.
pub(crate) fn last_token(fragment: &str) -> Token {
    let mut start = 0usize;
    let mut escaped = false;
    let mut quote: Option<char> = None;
    let mut seen_word = false;
    let mut first = true;
    for (index, ch) in fragment.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if let Some(open) = quote {
            if ch == open {
                quote = None;
            }
            continue;
        }
        match ch {
            '\\' => {
                escaped = true;
                seen_word = true;
            }
            '\'' | '"' => {
                quote = Some(ch);
                seen_word = true;
            }
            ch if COMMAND_BREAKS.contains(&ch) => {
                first = true;
                seen_word = false;
                start = index + ch.len_utf8();
            }
            ch if WORD_BREAKS.contains(&ch) => {
                // A redirect is always followed by a path, whatever came
                // before it. A space only makes an argument once a command
                // word has actually been typed.
                if seen_word || ch == '<' || ch == '>' {
                    first = false;
                }
                seen_word = false;
                start = index + ch.len_utf8();
            }
            _ => seen_word = true,
        }
    }
    Token {
        start,
        text: fragment[start..].to_string(),
        first,
        open_quote: quote.is_some(),
    }
}

/// Turn `a\ b` back into `a b`.
fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut escaped = false;
    for ch in text.chars() {
        if escaped {
            out.push(ch);
            escaped = false;
        } else if ch == '\\' {
            escaped = true;
        } else {
            out.push(ch);
        }
    }
    out
}

/// Which directory to ask the server about, if any.
///
/// Nothing is asked for the command word itself: the first word of a line is
/// a program, and listing the working directory to complete it would offer
/// files as if they were commands. An argument is fair game, and an argument
/// that starts with `-` is a flag.
///
/// `base` is the session's own working directory when the server has said
/// what it is. Without one, a relative token has no meaning this side could
/// give it, so relative completion stays quiet rather than silently
/// completing against the home directory.
pub(crate) fn path_query(token: &Token, base: Option<&str>) -> Option<PathQuery> {
    if token.first || token.open_quote {
        return None;
    }
    // A word not started yet, after a command that has one. `cd ` means "what
    // is in here", which is only answerable where the session's own directory
    // is known.
    if token.text.is_empty() {
        let base = base?;
        return Some(PathQuery {
            dir: base.to_string(),
            prefix: String::new(),
            head: String::new(),
        });
    }
    if token.text.starts_with('-') {
        return None;
    }
    // A half-open quote. Completing into it would change what the rest of the
    // line means.
    if token.text.contains('\'') || token.text.contains('"') {
        return None;
    }
    let literal = token.literal();
    if literal.contains('\0') {
        return None;
    }
    let (head, prefix) = match literal.rfind('/') {
        Some(cut) => (literal[..=cut].to_string(), literal[cut + 1..].to_string()),
        None => (String::new(), literal.clone()),
    };
    let dir = if head.is_empty() {
        // `sr`, meaning something in the directory the session is sitting in.
        base?.to_string()
    } else if head == "~/" {
        "~".to_string()
    } else if let Some(rest) = head.strip_prefix("~/") {
        format!("~/{}", rest.trim_end_matches('/'))
    } else if head.starts_with('/') {
        let trimmed = head.trim_end_matches('/');
        if trimmed.is_empty() {
            "/".to_string()
        } else {
            trimmed.to_string()
        }
    } else {
        // A relative head: `src/`, `../`, `./log/`.
        let base = base?;
        let joined = format!("{}/{}", base.trim_end_matches('/'), head);
        joined.trim_end_matches('/').to_string()
    };
    Some(PathQuery { dir, prefix, head })
}

/// Characters a shell leaves alone inside a bare word.
fn plain(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || "_./:@%+,^-".contains(ch)
}

/// Write a path so a shell reads it as the one literal path it is.
///
/// Backslashes rather than quotes, because the result is typed into a line
/// somebody is still editing: a quote would have to be closed, and closing it
/// for them changes where their cursor means to be. A leading `~` is left
/// bare, since escaping it turns the home directory into a filename.
pub(crate) fn escape_path(path: &str) -> Option<String> {
    if path.contains('\n') || path.contains('\r') || path.contains('\0') {
        return None;
    }
    let (lead, rest) = if path == "~" {
        ("~", "")
    } else if let Some(rest) = path.strip_prefix("~/") {
        ("~/", rest)
    } else {
        ("", path)
    };
    let mut out = String::with_capacity(path.len() + 4);
    out.push_str(lead);
    for ch in rest.chars() {
        if !plain(ch) {
            out.push('\\');
        }
        out.push(ch);
    }
    Some(out)
}

/// Join a listed name onto the part of the path already typed.
fn joined(query: &PathQuery, entry: &Entry) -> String {
    let mut path = format!("{}{}", query.head, entry.name);
    if entry.directory {
        path.push('/');
    }
    path
}

/// What one session has done, as watched from this side.
///
/// Only lines the far end was seen echoing reach here, which is the same test
/// that keeps a password from being drawn on screen: a prompt with echo off
/// never confirms, so nothing typed into one is ever remembered. Held in
/// memory for the life of the session and never written anywhere. This is not
/// the shell's history file, and nothing here is read from the server.
#[derive(Debug, Default)]
pub(crate) struct SessionHistory {
    /// Where the session is, as far as this side can tell: seeded from the
    /// directory the session was opened in, moved by the `cd` lines watched
    /// since, and replaced outright whenever the server says so itself.
    pub cwd: Option<String>,
    /// The one before this, for `cd -`.
    previous: Option<String>,
    /// Directories this session has been in, most recent first.
    pub directories: Vec<String>,
    /// Command lines run in it, most recent first.
    pub commands: Vec<String>,
}

/// How many directories a session remembers.
const KEPT_DIRECTORIES: usize = 60;
/// How many command lines a session remembers.
const KEPT_COMMANDS: usize = 200;
/// The longest command line worth remembering. A pasted file is not a command
/// somebody will want offered back to them.
const LONGEST_COMMAND: usize = 512;

/// Commands after which this side no longer knows where the session is.
///
/// Each of these can leave the person somewhere else entirely: on another
/// machine, as another user, inside a container, or in a shell whose
/// directory this one never saw. Guessing after one of them is how a
/// completion ends up naming a directory that is not there.
const LOSES_THE_PLACE: [&str; 14] = [
    "ssh", "su", "sudo", "doas", "docker", "podman", "kubectl", "chroot", "bash", "sh", "zsh",
    "fish", "screen", "tmux",
];

impl SessionHistory {
    /// Start where the session was opened. The client asked for that
    /// directory and this side sent the `cd` that went there, so it is known
    /// rather than assumed.
    pub fn opened_in(&mut self, directory: &str) {
        let directory = directory.trim();
        if directory.is_empty() {
            return;
        }
        self.arrive(directory.to_string());
    }

    /// What the server itself says, which beats anything worked out here.
    pub fn reported(&mut self, directory: &str) {
        if directory.trim().is_empty() || self.cwd.as_deref() == Some(directory) {
            return;
        }
        self.arrive(directory.to_string());
    }

    /// One command line, as the person submitted it.
    pub fn ran(&mut self, command: &str) {
        let command = command.trim();
        if command.is_empty() || command.len() > LONGEST_COMMAND {
            return;
        }
        remember(&mut self.commands, command.to_string(), KEPT_COMMANDS);
        self.follow(command);
    }

    /// Move the working directory the way this line would have.
    fn follow(&mut self, command: &str) {
        let token = last_token(command);
        let mut words = command.split_whitespace();
        let Some(head) = words.next() else { return };
        // The name as typed, so `/usr/bin/ssh` counts as `ssh`.
        let name = head.rsplit('/').next().unwrap_or(head);
        if name != "cd" {
            if LOSES_THE_PLACE.contains(&name) {
                self.previous = self.cwd.take();
            }
            return;
        }
        // `cd` with more than one word after it is not a plain change of
        // directory, and neither is one this side cannot read.
        let argument = words.next().unwrap_or("~");
        if words.next().is_some() || token.open_quote {
            self.previous = self.cwd.take();
            return;
        }
        let argument = unescape(argument);
        if argument == "-" {
            std::mem::swap(&mut self.cwd, &mut self.previous);
            if let Some(now) = self.cwd.clone() {
                remember(&mut self.directories, now, KEPT_DIRECTORIES);
            }
            return;
        }
        let Some(target) = self.resolve(&argument) else {
            self.previous = self.cwd.take();
            return;
        };
        self.arrive(target);
    }

    /// Where an argument to `cd` would put the session.
    fn resolve(&self, argument: &str) -> Option<String> {
        if argument.starts_with('/') || argument == "~" || argument.starts_with("~/") {
            return Some(normalize(argument));
        }
        // Relative, so it only means something from somewhere known.
        let cwd = self.cwd.as_deref()?;
        Some(normalize(&format!(
            "{}/{argument}",
            cwd.trim_end_matches('/')
        )))
    }

    fn arrive(&mut self, directory: String) {
        if self.cwd.as_deref() == Some(directory.as_str()) {
            return;
        }
        self.previous = self.cwd.replace(directory.clone());
        remember(&mut self.directories, directory, KEPT_DIRECTORIES);
    }
}

/// Most recent first, no repeats, bounded.
fn remember(list: &mut Vec<String>, value: String, keep: usize) {
    list.retain(|held| held != &value);
    list.insert(0, value);
    list.truncate(keep);
}

/// Fold `.` and `..` away without touching the disk.
///
/// Textual on purpose: this runs against a path on another machine, so there
/// is nothing here to ask. A `..` through a symlink therefore lands where the
/// text says rather than where the link does, and the listing that follows is
/// what settles whether it exists at all.
fn normalize(path: &str) -> String {
    let rooted = path.starts_with('/');
    let home = path == "~" || path.starts_with("~/");
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => continue,
            ".." => {
                if parts.last().is_some_and(|last| *last != "~") {
                    parts.pop();
                } else if !rooted && !home {
                    parts.push("..");
                }
            }
            other => parts.push(other),
        }
    }
    let joined = parts.join("/");
    if rooted {
        format!("/{joined}")
    } else if joined.is_empty() {
        "/".into()
    } else {
        joined
    }
}

/// Order the rows a palette shows, best first.
///
/// The order is meant to be predictable rather than clever:
///
/// 1. A saved command whose text is what the person has started typing. They
///    are typing it out because they know it exists.
/// 2. Names from the directory, exact prefix before a case-insensitive one,
///    directories before files, alphabetical within each.
/// 3. Saved commands found by title or tag, this server's before the ones
///    kept for every server.
///
/// Two rows that would type the same characters collapse into the first.
pub(crate) fn rank(
    fragment: &str,
    token: &Token,
    query: Option<&PathQuery>,
    entries: &[Entry],
    snippets: &[Snippet],
    history: &SessionHistory,
) -> Vec<Row> {
    let mut rows: Vec<Row> = Vec::new();
    let typed = fragment.trim_start();
    let replace_all = fragment.chars().count();
    let replace_token = token.text.chars().count();

    // 1. A saved command being typed out by hand.
    if !typed.is_empty() {
        for snippet in snippets {
            if starts_with_fold(&snippet.command, typed) && snippet.command.len() > typed.len() {
                rows.push(snippet_row(snippet, replace_all));
            }
        }
        sort_scoped(&mut rows, snippets);
    }

    // 2. What the far end says is in the directory.
    if let Some(query) = query {
        let mut names: Vec<&Entry> = entries
            .iter()
            .filter(|entry| matches_prefix(&entry.name, &query.prefix))
            .collect();
        names.sort_by(|left, right| {
            let exact = right
                .name
                .starts_with(&query.prefix)
                .cmp(&left.name.starts_with(&query.prefix));
            let kind = right.directory.cmp(&left.directory);
            exact
                .then(kind)
                .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
        });
        for entry in names {
            let path = joined(query, entry);
            let Some(insert) = escape_path(&path) else {
                // A name with a newline in it. Not something to type into a
                // prompt on somebody's behalf.
                continue;
            };
            rows.push(Row {
                kind: if entry.directory { "directory" } else { "file" },
                title: entry.name.clone(),
                detail: path,
                insert,
                replace: replace_token,
                variables: Vec::new(),
            });
        }
    }

    // 3. A line already run in this session, being typed again. Somebody
    // repeating themselves is the commonest thing at a prompt, and this is
    // the one source that knows what they repeat. After the directory,
    // because when a path is being written the path is the answer.
    //
    // Three characters of it, so `cd ` does not offer back every `cd` this
    // session has run in front of what is actually in the folder.
    if typed.trim().chars().count() >= 3 {
        for command in &history.commands {
            if starts_with_fold(command, typed) && command.len() > typed.len() {
                rows.push(Row {
                    kind: "history",
                    title: command.clone(),
                    detail: String::new(),
                    insert: command.clone(),
                    replace: replace_all,
                    variables: Vec::new(),
                });
            }
        }
    }

    // 4. Somewhere this session has already been. Offered whenever a path is
    // being written, including the moment after `cd `, because the folder
    // somebody wants next is usually one they have been in before.
    if query.is_some() {
        let wanted = token.literal();
        for directory in &history.directories {
            if history.cwd.as_deref() == Some(directory.as_str()) {
                continue;
            }
            if !wanted.is_empty() && !starts_with_fold(directory, &wanted) {
                continue;
            }
            let mut path = directory.clone();
            if !path.ends_with('/') {
                path.push('/');
            }
            let Some(insert) = escape_path(&path) else {
                continue;
            };
            rows.push(Row {
                kind: "visited",
                title: directory
                    .rsplit('/')
                    .next()
                    .unwrap_or(directory)
                    .to_string(),
                detail: directory.clone(),
                insert,
                replace: replace_token,
                variables: Vec::new(),
            });
        }
    }

    // 5. Saved commands found by name.
    //
    // Three characters, not one: `cd` and `ls` appear inside half the
    // commands anybody saves, and a palette that opened on the command word
    // of every line would be in the way rather than in reach.
    let wanted = typed.trim();
    if wanted.chars().count() >= 3 {
        let mut found: Vec<Row> = Vec::new();
        for snippet in snippets {
            if contains_fold(&snippet.title, wanted)
                || snippet.tags.iter().any(|tag| contains_fold(tag, wanted))
                || contains_fold(&snippet.command, wanted)
            {
                found.push(snippet_row(snippet, replace_all));
            }
        }
        sort_scoped(&mut found, snippets);
        rows.append(&mut found);

        // 6. And a line run in this session with the typed text anywhere in
        // it, which is how somebody finds the long command they half
        // remember.
        for command in &history.commands {
            if contains_fold(command, wanted) {
                rows.push(Row {
                    kind: "history",
                    title: command.clone(),
                    detail: String::new(),
                    insert: command.clone(),
                    replace: replace_all,
                    variables: Vec::new(),
                });
            }
        }
    }

    let mut seen: Vec<String> = Vec::new();
    rows.retain(|row| {
        if seen.iter().any(|had| had == &row.insert) {
            return false;
        }
        seen.push(row.insert.clone());
        true
    });
    rows.truncate(MAX_ROWS);
    rows
}

fn snippet_row(snippet: &Snippet, replace: usize) -> Row {
    Row {
        kind: "snippet",
        title: snippet.title.clone(),
        detail: snippet.command.clone(),
        insert: snippet.command.clone(),
        replace,
        variables: snippet.variables.clone(),
    }
}

/// Scoped snippets ahead of general ones, then alphabetically.
fn sort_scoped(rows: &mut [Row], snippets: &[Snippet]) {
    let scoped = |row: &Row| {
        snippets
            .iter()
            .find(|snippet| snippet.command == row.insert && snippet.title == row.title)
            .map(|snippet| snippet.scoped)
            .unwrap_or(false)
    };
    rows.sort_by(|left, right| {
        scoped(right)
            .cmp(&scoped(left))
            .then_with(|| left.title.to_lowercase().cmp(&right.title.to_lowercase()))
    });
}

fn matches_prefix(name: &str, prefix: &str) -> bool {
    if prefix.is_empty() {
        // A bare `.` file is noise until somebody types the dot.
        return !name.starts_with('.');
    }
    starts_with_fold(name, prefix)
}

fn starts_with_fold(haystack: &str, needle: &str) -> bool {
    haystack.len() >= needle.len() && haystack[..needle.len()].eq_ignore_ascii_case(needle)
}

fn contains_fold(haystack: &str, needle: &str) -> bool {
    haystack.to_lowercase().contains(&needle.to_lowercase())
}

/// The command that lists one directory, read-only and in a fixed locale.
///
/// `-A` leaves out `.` and `..`, which are not names anybody needs offered.
/// `-p` marks directories, `-L` follows a symlink so a linked directory is
/// still marked as one, and `LC_ALL=C` keeps the order and the messages the
/// same whatever the server's locale is.
pub(crate) fn list_command(dir: &str) -> Option<String> {
    if dir.is_empty() || dir.len() > 4096 {
        return None;
    }
    if dir.contains('\n') || dir.contains('\r') || dir.contains('\0') {
        return None;
    }
    let target = if dir == "~" {
        "\"$HOME\"".to_string()
    } else if let Some(rest) = dir.strip_prefix("~/") {
        format!("\"$HOME\"/{}", single_quoted(rest))
    } else {
        single_quoted(dir)
    };
    Some(format!("LC_ALL=C ls -1ApL -- {target}"))
}

/// Wrap in single quotes, the one form a POSIX shell reads literally.
fn single_quoted(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\"'\"'"))
}

/// Read what `ls -1Ap` wrote.
///
/// Bounded by the caller, which stops reading long before a directory of a
/// million files could arrive. Anything unusable is dropped rather than
/// guessed at.
pub(crate) fn parse_listing(output: &str, cap: usize) -> Vec<Entry> {
    let mut entries = Vec::new();
    for line in output.lines() {
        let line = line.trim_end_matches('\r');
        if line.is_empty() {
            continue;
        }
        // `ls` on a path that does not exist writes to stderr, which the
        // reader keeps separate. A line that still looks like a message is
        // not a filename anybody can use.
        let directory = line.ends_with('/');
        let name = line.trim_end_matches('/');
        if name.is_empty() || name.contains('/') {
            continue;
        }
        entries.push(Entry {
            name: name.to_string(),
            directory,
        });
        if entries.len() >= cap {
            break;
        }
    }
    entries
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token(fragment: &str) -> Token {
        last_token(fragment)
    }

    #[test]
    fn the_last_word_is_what_is_being_typed() {
        let t = token("cd /opt/p");
        assert_eq!(t.text, "/opt/p");
        assert_eq!(t.start, 3);
        assert!(!t.first);

        let t = token("ls");
        assert_eq!(t.text, "ls");
        assert!(t.first, "the command word is not an argument");

        let t = token("cd ");
        assert_eq!(t.text, "");
        assert!(!t.first);
    }

    #[test]
    fn an_escaped_space_stays_inside_the_word() {
        let t = token("cat /var/My\\ Files/re");
        assert_eq!(t.text, "/var/My\\ Files/re");
        assert_eq!(t.literal(), "/var/My Files/re");
    }

    #[test]
    fn a_pipe_or_an_equals_starts_a_new_word() {
        assert_eq!(token("ls | grep /et").text, "/et");
        assert_eq!(token("nginx --config=/etc/n").text, "/etc/n");
        assert!(
            token("ls | gr").first,
            "the word after a pipe is a command again"
        );
        assert!(
            !token("cat > /tmp/o").first,
            "a redirect is followed by a path"
        );
    }

    #[test]
    fn absolute_and_home_paths_split_into_a_directory_and_a_prefix() {
        let q = path_query(&token("cd /opt/p"), None).expect("absolute");
        assert_eq!(q.dir, "/opt");
        assert_eq!(q.prefix, "p");
        assert_eq!(q.head, "/opt/");

        let q = path_query(&token("cd /opt/"), None).expect("trailing slash");
        assert_eq!(q.dir, "/opt");
        assert_eq!(q.prefix, "");

        let q = path_query(&token("cd /"), None).expect("root");
        assert_eq!(q.dir, "/");
        assert_eq!(q.prefix, "");

        let q = path_query(&token("cd ~/pro"), None).expect("home");
        assert_eq!(q.dir, "~");
        assert_eq!(q.prefix, "pro");

        let q = path_query(&token("cd ~/src/pro"), None).expect("under home");
        assert_eq!(q.dir, "~/src");
        assert_eq!(q.prefix, "pro");
    }

    #[test]
    fn a_relative_path_needs_a_directory_to_be_relative_to() {
        assert!(
            path_query(&token("cd sr"), None).is_none(),
            "no working directory means no answer, rather than a wrong one"
        );
        let q = path_query(&token("cd sr"), Some("/srv/app")).expect("with a base");
        assert_eq!(q.dir, "/srv/app");
        assert_eq!(q.prefix, "sr");

        let q = path_query(&token("cd src/li"), Some("/srv/app")).expect("nested");
        assert_eq!(q.dir, "/srv/app/src");
        assert_eq!(q.prefix, "li");
    }

    #[test]
    fn the_command_word_a_flag_and_a_quote_are_left_alone() {
        assert!(path_query(&token("ls"), Some("/tmp")).is_none());
        assert!(path_query(&token("ls -l"), Some("/tmp")).is_none());
        assert!(
            path_query(&token("cat '/etc/pas"), Some("/tmp")).is_none(),
            "an open quote is a string, not a path being typed"
        );
        assert!(path_query(&token("cat \"/etc/pas"), Some("/tmp")).is_none());
        assert!(
            path_query(&token("git commit -m \"fix the"), Some("/tmp")).is_none(),
            "a message is not a filename"
        );
    }

    #[test]
    fn escaping_leaves_a_plain_path_alone_and_protects_the_rest() {
        assert_eq!(escape_path("/opt/proj/").as_deref(), Some("/opt/proj/"));
        assert_eq!(
            escape_path("/var/My Files/").as_deref(),
            Some("/var/My\\ Files/")
        );
        assert_eq!(
            escape_path("~/Music/A&B").as_deref(),
            Some("~/Music/A\\&B"),
            "the tilde stays bare or it stops meaning home"
        );
        assert_eq!(escape_path("~").as_deref(), Some("~"));
        assert_eq!(
            escape_path("/tmp/a\nb"),
            None,
            "a newline in a name would run the rest as a command"
        );
    }

    #[test]
    fn the_list_command_quotes_its_argument_and_expands_home_itself() {
        assert_eq!(
            list_command("/opt/it's").as_deref(),
            Some("LC_ALL=C ls -1ApL -- '/opt/it'\"'\"'s'")
        );
        assert_eq!(
            list_command("~").as_deref(),
            Some("LC_ALL=C ls -1ApL -- \"$HOME\"")
        );
        assert_eq!(
            list_command("~/src").as_deref(),
            Some("LC_ALL=C ls -1ApL -- \"$HOME\"/'src'")
        );
        assert_eq!(list_command("/tmp\nrm -rf /"), None);
        assert_eq!(list_command(""), None);
    }

    #[test]
    fn a_listing_reads_as_names_and_a_mark_for_directories() {
        let entries = parse_listing("proj/\nREADME.md\nlink/\n\n", 100);
        assert_eq!(
            entries,
            vec![
                Entry {
                    name: "proj".into(),
                    directory: true
                },
                Entry {
                    name: "README.md".into(),
                    directory: false
                },
                Entry {
                    name: "link".into(),
                    directory: true
                },
            ]
        );
        assert_eq!(parse_listing("a/\nb/\nc/\n", 2).len(), 2, "the cap holds");
    }

    fn snippets() -> Vec<Snippet> {
        vec![
            Snippet {
                title: "Restart web".into(),
                command: "sudo systemctl restart nginx".into(),
                tags: vec!["nginx".into()],
                variables: vec![],
                scoped: true,
            },
            Snippet {
                title: "Tail syslog".into(),
                command: "sudo tail -f /var/log/syslog".into(),
                tags: vec!["logs".into()],
                variables: vec![],
                scoped: false,
            },
        ]
    }

    #[test]
    fn a_saved_command_being_typed_out_leads() {
        let fragment = "sudo systemctl";
        let t = token(fragment);
        let rows = rank(
            fragment,
            &t,
            None,
            &[],
            &snippets(),
            &SessionHistory::default(),
        );
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].kind, "snippet");
        assert_eq!(rows[0].title, "Restart web");
        assert_eq!(
            rows[0].replace,
            fragment.chars().count(),
            "a snippet stands in for the whole line typed so far"
        );
    }

    #[test]
    fn directories_come_before_files_and_an_exact_prefix_before_a_folded_one() {
        let fragment = "cd /opt/p";
        let t = token(fragment);
        let query = path_query(&t, None).expect("path");
        let entries = vec![
            Entry {
                name: "Photos".into(),
                directory: true,
            },
            Entry {
                name: "profile.txt".into(),
                directory: false,
            },
            Entry {
                name: "proj".into(),
                directory: true,
            },
            Entry {
                name: "other".into(),
                directory: true,
            },
        ];
        let rows = rank(
            fragment,
            &t,
            Some(&query),
            &entries,
            &[],
            &SessionHistory::default(),
        );
        let titles: Vec<&str> = rows.iter().map(|row| row.title.as_str()).collect();
        assert_eq!(titles, vec!["proj", "profile.txt", "Photos"]);
        assert_eq!(rows[0].insert, "/opt/proj/");
        assert_eq!(rows[0].replace, "/opt/p".chars().count());
    }

    #[test]
    fn dotfiles_stay_out_until_the_dot_is_typed() {
        let entries = vec![
            Entry {
                name: ".config".into(),
                directory: true,
            },
            Entry {
                name: "src".into(),
                directory: true,
            },
        ];
        let fragment = "cd ~/";
        let t = token(fragment);
        let query = path_query(&t, None).expect("path");
        let rows = rank(
            fragment,
            &t,
            Some(&query),
            &entries,
            &[],
            &SessionHistory::default(),
        );
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].title, "src");

        let fragment = "cd ~/.";
        let t = token(fragment);
        let query = path_query(&t, None).expect("path");
        let rows = rank(
            fragment,
            &t,
            Some(&query),
            &entries,
            &[],
            &SessionHistory::default(),
        );
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].title, ".config");
    }

    fn history(commands: &[&str], opened_in: &str) -> SessionHistory {
        let mut past = SessionHistory::default();
        past.opened_in(opened_in);
        for command in commands {
            past.ran(command);
        }
        past
    }

    #[test]
    fn a_session_follows_the_cd_lines_it_watched() {
        let past = history(
            &["ls -l", "cd /opt", "cd pueev_web", "cd ../digitalocean"],
            "~",
        );
        assert_eq!(past.cwd.as_deref(), Some("/opt/digitalocean"));
        assert_eq!(
            past.directories,
            vec!["/opt/digitalocean", "/opt/pueev_web", "/opt", "~"],
            "most recent first, no repeats"
        );
    }

    #[test]
    fn cd_with_no_argument_is_home_and_cd_dash_goes_back() {
        let past = history(&["cd /opt", "cd", "cd -"], "~");
        assert_eq!(past.cwd.as_deref(), Some("/opt"));
    }

    #[test]
    fn a_command_that_could_move_the_session_ends_the_guessing() {
        for line in ["ssh other-server", "sudo -i", "docker exec -it web sh"] {
            let past = history(&["cd /opt", line], "~");
            assert!(
                past.cwd.is_none(),
                "{line} could leave the session anywhere, so nothing is claimed"
            );
        }
        let past = history(&["cd /opt", "grep -r ssh ."], "~");
        assert_eq!(
            past.cwd.as_deref(),
            Some("/opt"),
            "a word that merely mentions one of them is not one of them"
        );
    }

    #[test]
    fn a_relative_cd_from_an_unknown_place_stays_unknown() {
        let mut past = SessionHistory::default();
        past.ran("cd src");
        assert!(past.cwd.is_none());
    }

    #[test]
    fn the_server_saying_where_it_is_wins() {
        let mut past = history(&["cd /opt"], "~");
        past.reported("/srv/app");
        assert_eq!(past.cwd.as_deref(), Some("/srv/app"));
    }

    #[test]
    fn an_empty_argument_offers_what_is_in_the_current_directory() {
        let past = history(&["cd /opt"], "~");
        let fragment = "cd ";
        let t = token(fragment);
        let query = path_query(&t, past.cwd.as_deref()).expect("the session knows where it is");
        assert_eq!(query.dir, "/opt");
        assert_eq!(query.prefix, "");
        let entries = vec![Entry {
            name: "pueev_web".into(),
            directory: true,
        }];
        let rows = rank(fragment, &t, Some(&query), &entries, &[], &past);
        let titles: Vec<&str> = rows.iter().map(|row| row.title.as_str()).collect();
        assert_eq!(
            titles,
            vec!["pueev_web", "~"],
            "what is in here, then where this session has been"
        );
        assert_eq!(rows[0].kind, "directory");
        assert_eq!(rows[1].kind, "visited");
        assert_eq!(rows[1].insert, "~/");
    }

    #[test]
    fn a_line_already_run_is_offered_back_before_anything_else() {
        let past = history(&["systemctl restart nginx", "cd /opt"], "~");
        let fragment = "systemctl re";
        let t = token(fragment);
        let rows = rank(fragment, &t, None, &[], &snippets(), &past);
        assert_eq!(rows[0].kind, "history");
        assert_eq!(rows[0].title, "systemctl restart nginx");
        assert_eq!(rows[0].replace, fragment.chars().count());
    }

    #[test]
    fn the_current_directory_is_not_offered_as_somewhere_to_go() {
        let past = history(&["cd /opt"], "~");
        let fragment = "cd /o";
        let t = token(fragment);
        let query = path_query(&t, past.cwd.as_deref()).expect("path");
        let rows = rank(fragment, &t, Some(&query), &[], &[], &past);
        assert!(
            !rows.iter().any(|row| row.kind == "visited"),
            "standing in /opt, offering /opt as somewhere to go is offering nothing"
        );
    }

    #[test]
    fn a_password_is_never_remembered_because_it_never_arrives() {
        // The client only reports a line the far end echoed, so this is the
        // whole of the guarantee here: what is not handed over is not kept.
        let past = SessionHistory::default();
        assert!(past.commands.is_empty());
    }

    #[test]
    fn a_two_letter_command_word_does_not_open_the_list() {
        let fragment = "cd";
        let t = token(fragment);
        let snippets = vec![Snippet {
            title: "Tail syslog".into(),
            command: "sudo tail -f /var/log/syslog".into(),
            tags: vec![],
            variables: vec![],
            scoped: true,
        }];
        assert!(
            rank(
                fragment,
                &t,
                None,
                &[],
                &snippets,
                &SessionHistory::default()
            )
            .is_empty()
        );
    }

    #[test]
    fn a_snippet_for_this_server_leads_one_kept_for_every_server() {
        let fragment = "sudo";
        let t = token(fragment);
        let rows = rank(
            fragment,
            &t,
            None,
            &[],
            &snippets(),
            &SessionHistory::default(),
        );
        assert_eq!(rows[0].title, "Restart web", "scoped first");
        assert_eq!(rows[1].title, "Tail syslog");
    }

    #[test]
    fn two_rows_that_would_type_the_same_thing_collapse() {
        let mut list = snippets();
        list.push(Snippet {
            title: "Restart web".into(),
            command: "sudo systemctl restart nginx".into(),
            tags: vec![],
            variables: vec![],
            scoped: false,
        });
        let fragment = "sudo systemctl";
        let t = token(fragment);
        let rows = rank(fragment, &t, None, &[], &list, &SessionHistory::default());
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn never_more_than_six_rows() {
        let entries: Vec<Entry> = (0..40)
            .map(|n| Entry {
                name: format!("proj{n}"),
                directory: true,
            })
            .collect();
        let fragment = "cd /opt/p";
        let t = token(fragment);
        let query = path_query(&t, None).expect("path");
        let rows = rank(
            fragment,
            &t,
            Some(&query),
            &entries,
            &snippets(),
            &SessionHistory::default(),
        );
        assert_eq!(rows.len(), MAX_ROWS);
    }

    #[test]
    fn every_row_carries_every_field_it_promises() {
        let fragment = "cd /opt/p";
        let t = token(fragment);
        let query = path_query(&t, None).expect("path");
        let entries = vec![Entry {
            name: "proj".into(),
            directory: true,
        }];
        let rows = rank(
            fragment,
            &t,
            Some(&query),
            &entries,
            &[],
            &SessionHistory::default(),
        );
        let wire = serde_json::to_value(&rows[0]).expect("serialize");
        let object = wire.as_object().expect("object");
        // A row with no placeholders still says so. A strict decoder on the
        // other end reads a missing key as a broken answer rather than as an
        // empty list, and a palette that never appears is what that looks
        // like from the outside.
        for key in ["kind", "title", "detail", "insert", "replace", "variables"] {
            assert!(object.contains_key(key), "{key} is missing from {wire}");
        }
        assert_eq!(object["variables"], serde_json::json!([]));
    }

    #[test]
    fn a_name_that_cannot_be_typed_safely_is_dropped() {
        let entries = vec![
            Entry {
                name: "one\ntwo".into(),
                directory: false,
            },
            Entry {
                name: "ordinary".into(),
                directory: false,
            },
        ];
        let fragment = "cat /tmp/o";
        let t = token(fragment);
        let query = path_query(&t, None).expect("path");
        let rows = rank(
            fragment,
            &t,
            Some(&query),
            &entries,
            &[],
            &SessionHistory::default(),
        );
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].title, "ordinary");
    }
}
