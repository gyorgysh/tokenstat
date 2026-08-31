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
    /// `directory`, `file` or `snippet`. The client draws a glyph from this.
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
    /// before the command is inserted. Empty for a path.
    #[serde(skip_serializing_if = "Vec::is_empty")]
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
    if token.first || token.open_quote || token.text.is_empty() {
        return None;
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

    // 3. Saved commands found by name.
    //
    // Three characters, not one: `cd` and `ls` appear inside half the
    // commands anybody saves, and a palette that opened on the command word
    // of every line would be in the way rather than in reach.
    if typed.chars().count() >= 3 {
        let mut found: Vec<Row> = Vec::new();
        for snippet in snippets {
            if contains_fold(&snippet.title, typed)
                || snippet.tags.iter().any(|tag| contains_fold(tag, typed))
                || contains_fold(&snippet.command, typed)
            {
                found.push(snippet_row(snippet, replace_all));
            }
        }
        sort_scoped(&mut found, snippets);
        rows.append(&mut found);
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
        let rows = rank(fragment, &t, None, &[], &snippets());
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
        let rows = rank(fragment, &t, Some(&query), &entries, &[]);
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
        let rows = rank(fragment, &t, Some(&query), &entries, &[]);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].title, "src");

        let fragment = "cd ~/.";
        let t = token(fragment);
        let query = path_query(&t, None).expect("path");
        let rows = rank(fragment, &t, Some(&query), &entries, &[]);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].title, ".config");
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
        assert!(rank(fragment, &t, None, &[], &snippets).is_empty());
    }

    #[test]
    fn a_snippet_for_this_server_leads_one_kept_for_every_server() {
        let fragment = "sudo";
        let t = token(fragment);
        let rows = rank(fragment, &t, None, &[], &snippets());
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
        let rows = rank(fragment, &t, None, &[], &list);
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
        let rows = rank(fragment, &t, Some(&query), &entries, &snippets());
        assert_eq!(rows.len(), MAX_ROWS);
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
        let rows = rank(fragment, &t, Some(&query), &entries, &[]);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].title, "ordinary");
    }
}
