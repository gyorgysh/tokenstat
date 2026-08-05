// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Syntax spans for the workspace editor.
//!
//! The editor in the desktop app needs to colour code. It could tokenize in
//! Swift, and then the iPad client, the Windows client and anything else would
//! each need their own copy of that work, in their own language, disagreeing in
//! their own ways. So highlighting happens once, here, and every front end
//! renders the same answer.
//!
//! # Kinds, not colours
//!
//! A [`Span`] carries a [`Kind`], never a colour. A highlighter that knows the
//! theme is a highlighter that has to ship the theme, and then a user switching
//! to light mode is a round trip through this crate. The front end owns the
//! palette, and this crate owns the question of what a run of bytes *is*.
//!
//! # Offsets are UTF-16
//!
//! Rust indexes strings by byte and Apple's text system indexes them by UTF-16
//! code unit. Converting on the Swift side means walking the string again per
//! span, so the conversion happens here, in the single pass that already walks
//! the text. An emoji in a comment shifts every following span, and getting
//! this wrong colours the wrong half of a file with no error anywhere.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

use serde::{Deserialize, Serialize};
use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

/// Files above this are handed back unhighlighted.
///
/// Parsing a large file is not the problem: applying tens of thousands of
/// attribute runs to a text view is. The caller is told the file was too large
/// rather than being left to guess why nothing is coloured, because an editor
/// that silently stops colouring reads as a bug in the highlighter.
pub const MAX_BYTES: usize = 2 * 1024 * 1024;

/// What a run of source text is, in the vocabulary a colour scheme uses.
///
/// Deliberately coarse. Grammars distinguish `variable.parameter` from
/// `variable.member`, and no colour scheme anyone reads code in uses more than
/// about a dozen colours, so the extra precision would only ever be collapsed
/// again at the far end.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Keyword,
    /// String and character literals, including their escapes.
    String,
    Number,
    Comment,
    /// Type names, including builtin ones.
    Type,
    /// Anything called: functions, methods, macros.
    Function,
    /// Constants and builtin values such as `true` or `nil`.
    Constant,
    /// Attributes, annotations, decorators, and preprocessor lines.
    Attribute,
    /// Struct fields, object keys, and the left-hand side of a mapping.
    Property,
    /// Variable and parameter names the grammar could resolve.
    Variable,
    Operator,
    /// Brackets, delimiters, and markup punctuation.
    Punctuation,
    /// Markup: headings, emphasis, link text.
    Markup,
}

/// A coloured run of text.
///
/// `start` and `len` are **UTF-16 code units**, not bytes. See the crate docs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Span {
    pub start: u32,
    pub len: u32,
    pub kind: Kind,
}

/// The languages with a grammar compiled in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Language {
    Rust,
    Swift,
    JavaScript,
    TypeScript,
    Tsx,
    Html,
    Css,
    Go,
    Python,
    Json,
    Toml,
    Yaml,
    Markdown,
    Shell,
}

impl Language {
    /// The stable identifier used on the wire and in the front ends.
    pub fn id(self) -> &'static str {
        match self {
            Self::Rust => "rust",
            Self::Swift => "swift",
            Self::JavaScript => "javascript",
            Self::TypeScript => "typescript",
            Self::Tsx => "tsx",
            Self::Html => "html",
            Self::Css => "css",
            Self::Go => "go",
            Self::Python => "python",
            Self::Json => "json",
            Self::Toml => "toml",
            Self::Yaml => "yaml",
            Self::Markdown => "markdown",
            Self::Shell => "shell",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Some(match id {
            "rust" => Self::Rust,
            "swift" => Self::Swift,
            "javascript" => Self::JavaScript,
            "typescript" => Self::TypeScript,
            "tsx" => Self::Tsx,
            "html" => Self::Html,
            "css" => Self::Css,
            "go" => Self::Go,
            "python" => Self::Python,
            "json" => Self::Json,
            "toml" => Self::Toml,
            "yaml" => Self::Yaml,
            "markdown" => Self::Markdown,
            "shell" => Self::Shell,
            _ => return None,
        })
    }

    /// Guess the language from a path.
    ///
    /// Extension first, then whole file names, because the shell dotfiles have
    /// no extension to look at and are common enough in a home directory to be
    /// worth naming.
    pub fn detect(path: &str) -> Option<Self> {
        let name = path.rsplit(['/', '\\']).next().unwrap_or(path);
        let lower = name.to_ascii_lowercase();

        if let Some((_, extension)) = lower.rsplit_once('.') {
            let found = match extension {
                "rs" => Some(Self::Rust),
                "swift" => Some(Self::Swift),
                "js" | "jsx" | "mjs" | "cjs" => Some(Self::JavaScript),
                "ts" | "mts" | "cts" => Some(Self::TypeScript),
                "tsx" => Some(Self::Tsx),
                "html" | "htm" | "xhtml" => Some(Self::Html),
                "css" => Some(Self::Css),
                "go" => Some(Self::Go),
                "py" | "pyi" => Some(Self::Python),
                "json" | "jsonc" => Some(Self::Json),
                "toml" => Some(Self::Toml),
                "yaml" | "yml" => Some(Self::Yaml),
                "md" | "markdown" | "mdx" => Some(Self::Markdown),
                "sh" | "bash" | "zsh" => Some(Self::Shell),
                _ => None,
            };
            if found.is_some() {
                return found;
            }
        }

        match lower.as_str() {
            "cargo.lock" => Some(Self::Toml),
            ".zshrc" | ".zprofile" | ".zshenv" | ".bashrc" | ".bash_profile" | ".profile" => {
                Some(Self::Shell)
            }
            _ => None,
        }
    }

    /// How this language is commented and indented.
    ///
    /// The editor needs this to toggle a comment and to indent a new line, and
    /// the alternative is a second table of the same facts in every front end.
    pub fn syntax(self) -> Syntax {
        match self {
            Self::Rust
            | Self::Swift
            | Self::JavaScript
            | Self::TypeScript
            | Self::Tsx
            | Self::Go => Syntax {
                line_comment: Some("//"),
                block_comment: Some(("/*", "*/")),
                indent: 4,
            },
            Self::Css => Syntax {
                line_comment: None,
                block_comment: Some(("/*", "*/")),
                indent: 2,
            },
            Self::Html => Syntax {
                line_comment: None,
                block_comment: Some(("<!--", "-->")),
                indent: 2,
            },
            Self::Python => Syntax {
                line_comment: Some("#"),
                block_comment: None,
                indent: 4,
            },
            Self::Shell | Self::Toml | Self::Yaml => Syntax {
                line_comment: Some("#"),
                block_comment: None,
                indent: 2,
            },
            // JSON has no comment syntax. Saying `//` here would produce a file
            // the language cannot parse, which is worse than the key doing
            // nothing.
            Self::Json => Syntax {
                line_comment: None,
                block_comment: None,
                indent: 2,
            },
            Self::Markdown => Syntax {
                line_comment: None,
                block_comment: Some(("<!--", "-->")),
                indent: 2,
            },
        }
    }
}

/// The editing facts about a language that are not colours.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Syntax {
    /// The line comment token, or `None` where the language has none.
    pub line_comment: Option<&'static str>,
    pub block_comment: Option<(&'static str, &'static str)>,
    /// Spaces per indent level.
    pub indent: u8,
}

#[derive(Debug, thiserror::Error)]
pub enum HighlightError {
    #[error("the file is {1} bytes, over the {2} byte highlighting limit")]
    TooLarge(&'static str, usize, usize),
    #[error("the {0} grammar could not be loaded: {1}")]
    Grammar(&'static str, String),
    #[error("highlighting failed: {0}")]
    Parse(String),
}

/// The capture names asked of every grammar, in the order their [`Kind`] sits
/// in [`KINDS`].
///
/// tree-sitter matches a capture to the longest configured name that is a
/// prefix of it, so listing `function.method` alongside `function` is only
/// needed when the two should differ. They do not here, and the shorter name
/// already catches the longer one.
const CAPTURES: &[&str] = &[
    "keyword",
    "string",
    "number",
    "comment",
    "type",
    "constructor",
    "function",
    "constant",
    "attribute",
    "property",
    "label",
    "variable",
    "operator",
    "punctuation",
    "tag",
    "text.title",
    "text.emphasis",
    "text.strong",
    "text.literal",
    "text.uri",
    "escape",
];

/// One [`Kind`] per entry of [`CAPTURES`], by position.
const KINDS: &[Kind] = &[
    Kind::Keyword,
    Kind::String,
    Kind::Number,
    Kind::Comment,
    Kind::Type,
    Kind::Type,
    Kind::Function,
    Kind::Constant,
    Kind::Attribute,
    Kind::Property,
    Kind::Property,
    Kind::Variable,
    Kind::Operator,
    Kind::Punctuation,
    Kind::Markup,
    Kind::Markup,
    Kind::Markup,
    Kind::Markup,
    Kind::String,
    Kind::Constant,
    Kind::String,
];

/// JavaScript's highlights, plus what TypeScript adds. See the note at the
/// TypeScript arm of `configuration`.
static TYPESCRIPT_HIGHLIGHTS: LazyLock<String> = LazyLock::new(|| {
    format!(
        "{}\n{}",
        tree_sitter_javascript::HIGHLIGHT_QUERY,
        tree_sitter_typescript::HIGHLIGHTS_QUERY
    )
});

/// The same, plus JSX.
static TSX_HIGHLIGHTS: LazyLock<String> = LazyLock::new(|| {
    format!(
        "{}\n{}\n{}",
        tree_sitter_javascript::HIGHLIGHT_QUERY,
        tree_sitter_javascript::JSX_HIGHLIGHT_QUERY,
        tree_sitter_typescript::HIGHLIGHTS_QUERY
    )
});

/// Grammars are compiled once and reused.
///
/// Building a `HighlightConfiguration` compiles the grammar's highlight query,
/// which is milliseconds, and the editor re-highlights on a keystroke debounce.
/// Paying that per keystroke would be the whole latency budget.
static CONFIGS: LazyLock<Mutex<HashMap<Language, &'static HighlightConfiguration>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn configuration(language: Language) -> Result<&'static HighlightConfiguration, HighlightError> {
    let mut cache = CONFIGS
        .lock()
        .map_err(|_| HighlightError::Parse("the grammar cache was poisoned".into()))?;
    if let Some(config) = cache.get(&language) {
        return Ok(config);
    }

    let (grammar, highlights, injections, locals) = match language {
        Language::Rust => (
            tree_sitter_rust::LANGUAGE.into(),
            tree_sitter_rust::HIGHLIGHTS_QUERY,
            tree_sitter_rust::INJECTIONS_QUERY,
            "",
        ),
        Language::Swift => (
            tree_sitter_swift::LANGUAGE.into(),
            tree_sitter_swift::HIGHLIGHTS_QUERY,
            tree_sitter_swift::INJECTIONS_QUERY,
            tree_sitter_swift::LOCALS_QUERY,
        ),
        Language::JavaScript => (
            tree_sitter_javascript::LANGUAGE.into(),
            tree_sitter_javascript::HIGHLIGHT_QUERY,
            tree_sitter_javascript::INJECTIONS_QUERY,
            tree_sitter_javascript::LOCALS_QUERY,
        ),
        // TypeScript's own query holds only what TypeScript adds to
        // JavaScript, so used alone it colours the type annotations and leaves
        // `const`, `function` and every string untouched. The two are meant to
        // be concatenated, and a test pins it, because the result of getting
        // this wrong is a file that looks *nearly* highlighted.
        Language::TypeScript => (
            tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            TYPESCRIPT_HIGHLIGHTS.as_str(),
            "",
            tree_sitter_typescript::LOCALS_QUERY,
        ),
        Language::Tsx => (
            tree_sitter_typescript::LANGUAGE_TSX.into(),
            TSX_HIGHLIGHTS.as_str(),
            "",
            tree_sitter_typescript::LOCALS_QUERY,
        ),
        Language::Html => (
            tree_sitter_html::LANGUAGE.into(),
            tree_sitter_html::HIGHLIGHTS_QUERY,
            tree_sitter_html::INJECTIONS_QUERY,
            "",
        ),
        Language::Css => (
            tree_sitter_css::LANGUAGE.into(),
            tree_sitter_css::HIGHLIGHTS_QUERY,
            "",
            "",
        ),
        Language::Go => (
            tree_sitter_go::LANGUAGE.into(),
            tree_sitter_go::HIGHLIGHTS_QUERY,
            "",
            "",
        ),
        Language::Python => (
            tree_sitter_python::LANGUAGE.into(),
            tree_sitter_python::HIGHLIGHTS_QUERY,
            "",
            "",
        ),
        Language::Json => (
            tree_sitter_json::LANGUAGE.into(),
            tree_sitter_json::HIGHLIGHTS_QUERY,
            "",
            "",
        ),
        Language::Toml => (
            tree_sitter_toml_ng::LANGUAGE.into(),
            tree_sitter_toml_ng::HIGHLIGHTS_QUERY,
            "",
            "",
        ),
        Language::Yaml => (
            tree_sitter_yaml::LANGUAGE.into(),
            tree_sitter_yaml::HIGHLIGHTS_QUERY,
            "",
            "",
        ),
        // Block grammar only. The inline grammar is a separate parser reached
        // through an injection, and headings, fences and lists are the part
        // worth colouring in a file someone is editing beside a terminal.
        Language::Markdown => (
            tree_sitter_md::LANGUAGE.into(),
            tree_sitter_md::HIGHLIGHT_QUERY_BLOCK,
            "",
            "",
        ),
        Language::Shell => (
            tree_sitter_bash::LANGUAGE.into(),
            tree_sitter_bash::HIGHLIGHT_QUERY,
            "",
            "",
        ),
    };

    let mut config = HighlightConfiguration::new(
        grammar,
        language.id(),
        &without_modifier_captures(highlights),
        injections,
        locals,
    )
    .map_err(|e| HighlightError::Grammar(language.id(), e.to_string()))?;
    config.configure(CAPTURES);

    // Leaked on purpose, once per language for the life of the process. The
    // alternative is an `Arc` clone on every keystroke to satisfy a lifetime
    // that outlives every caller anyway.
    let config: &'static HighlightConfiguration = Box::leak(Box::new(config));
    cache.insert(language, config);
    Ok(config)
}

/// Colour a file.
///
/// Spans are returned in ascending order, do not overlap, and cover only the
/// text the grammar had something to say about: plain text produces no span at
/// all rather than a span of some default kind. Adjacent runs of one kind are
/// merged, because a text view applying attributes cares about the number of
/// runs and a grammar will happily emit one per token.
pub fn spans(language: Language, text: &str) -> Result<Vec<Span>, HighlightError> {
    if text.len() > MAX_BYTES {
        return Err(HighlightError::TooLarge(
            language.id(),
            text.len(),
            MAX_BYTES,
        ));
    }

    let config = configuration(language)?;
    let mut highlighter = Highlighter::new();
    let events = highlighter
        .highlight(config, text.as_bytes(), None, |_| None)
        .map_err(|e| HighlightError::Parse(e.to_string()))?;

    let mut spans: Vec<Span> = Vec::new();
    let mut stack: Vec<Kind> = Vec::new();
    // Walked alongside the events rather than recomputed per span. The events
    // cover the text in order, so this is one pass over the file in total.
    let mut cursor_byte = 0usize;
    let mut cursor_u16 = 0usize;

    for event in events {
        match event.map_err(|e| HighlightError::Parse(e.to_string()))? {
            HighlightEvent::HighlightStart(highlight) => {
                stack.push(KINDS.get(highlight.0).copied().unwrap_or(Kind::Variable));
            }
            HighlightEvent::HighlightEnd => {
                stack.pop();
            }
            HighlightEvent::Source { start, end } => {
                // Advance to the start of this run, counting what was skipped.
                cursor_u16 += utf16_len(text, cursor_byte, start);
                let width = utf16_len(text, start, end);
                let start_u16 = cursor_u16;
                cursor_u16 += width;
                cursor_byte = end;

                // The innermost highlight wins: a string inside a macro call
                // should read as a string.
                let Some(&kind) = stack.last() else { continue };
                if width == 0 {
                    continue;
                }

                match spans.last_mut() {
                    Some(last)
                        if last.kind == kind
                            && last.start as usize + last.len as usize == start_u16 =>
                    {
                        last.len += width as u32;
                    }
                    _ => spans.push(Span {
                        start: start_u16 as u32,
                        len: width as u32,
                        kind,
                    }),
                }
            }
        }
    }

    Ok(spans)
}

/// Capture names that mark a node for something other than colour.
///
/// `@spell` tells an editor's spell checker where prose lives, and `@conceal`
/// tells it what to hide. They are not colours and this crate has no meaning
/// for them.
const MODIFIER_CAPTURES: &[&str] = &["@spell", "@nospell", "@conceal", "@none"];

/// Remove the modifier captures from a highlight query.
///
/// Not cosmetic. When several captures land on one node, `tree-sitter-highlight`
/// keeps the **last** one, unconditionally. Grammars written for editors that
/// understand these markers put them last, as in the Swift grammar's
/// `[(comment) (multiline_comment)] @comment @spell`. Left in, `@spell` wins,
/// it has no configured kind, and every comment in the file comes back
/// uncoloured while the rest of the file colours perfectly. The result looks
/// like a theme with no comment colour rather than like a query problem, which
/// is why this is written down here.
fn without_modifier_captures(query: &str) -> String {
    let mut out = query.to_string();
    for modifier in MODIFIER_CAPTURES {
        out = out.replace(modifier, "");
    }
    out
}

/// UTF-16 code units in `text[from..to]`.
///
/// Byte offsets from tree-sitter always land on character boundaries, but a
/// grammar with a broken external scanner is not a reason to panic in an
/// editor, so a bad range counts as nothing rather than slicing.
fn utf16_len(text: &str, from: usize, to: usize) -> usize {
    if from >= to || to > text.len() {
        return 0;
    }
    match text.get(from..to) {
        Some(slice) => slice.encode_utf16().count(),
        None => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kind_at(spans: &[Span], offset: u32) -> Option<Kind> {
        spans
            .iter()
            .find(|s| s.start <= offset && offset < s.start + s.len)
            .map(|s| s.kind)
    }

    #[test]
    fn detects_languages_from_paths() {
        assert_eq!(Language::detect("src/main.rs"), Some(Language::Rust));
        assert_eq!(
            Language::detect("App/RootView.swift"),
            Some(Language::Swift)
        );
        assert_eq!(Language::detect("a/b/c.tsx"), Some(Language::Tsx));
        assert_eq!(Language::detect("Cargo.lock"), Some(Language::Toml));
        assert_eq!(Language::detect(".zshrc"), Some(Language::Shell));
        assert_eq!(Language::detect("LICENSE"), None);
    }

    #[test]
    fn colours_rust() {
        let text = "fn main() {\n    // hi\n    let x = 1;\n}\n";
        let spans = spans(Language::Rust, text).expect("rust highlights");
        assert_eq!(kind_at(&spans, 0), Some(Kind::Keyword), "fn");
        assert_eq!(kind_at(&spans, 3), Some(Kind::Function), "main");
        let comment = text.find("//").expect("comment") as u32;
        assert_eq!(kind_at(&spans, comment), Some(Kind::Comment));
    }

    #[test]
    fn spans_are_ordered_and_do_not_overlap() {
        // `file!()` is relative to the workspace root and the test runs in the
        // package directory, so it is joined rather than opened directly.
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/lib.rs");
        let text = std::fs::read_to_string(path).expect("this file");
        let spans = spans(Language::Rust, &text).expect("rust highlights");
        assert!(
            spans.len() > 50,
            "expected real output, got {}",
            spans.len()
        );
        for pair in spans.windows(2) {
            assert!(
                pair[0].start + pair[0].len <= pair[1].start,
                "{:?} overlaps {:?}",
                pair[0],
                pair[1]
            );
        }
    }

    /// The reason offsets are UTF-16 at all. A comment containing an astral
    /// character makes the byte offset and the code unit offset diverge, and
    /// nothing downstream would report the mismatch: the file would simply be
    /// coloured from the wrong place onwards.
    #[test]
    fn offsets_are_utf16_code_units() {
        let text = "// 🎉\nfn f() {}\n";
        let spans = spans(Language::Rust, text).expect("rust highlights");
        // "// 🎉" is 5 UTF-16 units, since the emoji is a surrogate pair, and
        // the newline is the sixth, so `fn` starts at 6 and not at its byte
        // offset of 9.
        assert_eq!(kind_at(&spans, 6), Some(Kind::Keyword), "{spans:?}");
    }

    #[test]
    fn refuses_a_file_over_the_limit() {
        let huge = "// x\n".repeat(MAX_BYTES / 5 + 1);
        assert!(matches!(
            spans(Language::Rust, &huge),
            Err(HighlightError::TooLarge(..))
        ));
    }

    #[test]
    fn every_language_parses_something() {
        let samples: &[(Language, &str)] = &[
            (Language::Rust, "fn a() {}"),
            (Language::Swift, "func a() {}"),
            (Language::JavaScript, "function a() {}"),
            (Language::TypeScript, "function a(): void {}"),
            (Language::Tsx, "const a = <b />;"),
            (Language::Html, "<main class=\"app\">Hello</main>"),
            (Language::Css, ".app { color: red; }"),
            (Language::Go, "package main\nfunc main() {}"),
            (Language::Python, "def a():\n    pass\n"),
            (Language::Json, "{\"a\": 1}"),
            (Language::Toml, "a = 1\n"),
            (Language::Yaml, "a: 1\n"),
            (Language::Markdown, "# Title\n"),
            (Language::Shell, "echo hi\n"),
        ];
        for (language, source) in samples {
            let spans = spans(*language, source)
                .unwrap_or_else(|e| panic!("{} failed: {e}", language.id()));
            assert!(!spans.is_empty(), "{} produced no spans", language.id());
        }
    }

    /// TypeScript's own highlight query only covers what TypeScript adds to
    /// JavaScript. Configured with that query alone, `const` and every string
    /// literal come back uncoloured, which looks like a theme problem rather
    /// than a missing query.
    #[test]
    fn typescript_inherits_the_javascript_query() {
        let text = "const greeting: string = \"hi\";";
        for language in [Language::TypeScript, Language::Tsx] {
            let spans = spans(language, text).expect("typescript highlights");
            assert_eq!(
                kind_at(&spans, 0),
                Some(Kind::Keyword),
                "{}: const",
                language.id()
            );
            let quote = text.find('"').expect("string") as u32;
            assert_eq!(
                kind_at(&spans, quote),
                Some(Kind::String),
                "{}: literal",
                language.id()
            );
            let annotation = text.find("string").expect("annotation") as u32;
            assert_eq!(
                kind_at(&spans, annotation),
                Some(Kind::Type),
                "{}: annotation",
                language.id()
            );
        }
    }

    /// Comments must colour in every language that has them.
    ///
    /// This is the test for [`without_modifier_captures`]. Swift, and any
    /// grammar written the same way, tags comments `@comment @spell`, the last
    /// capture wins, and `@spell` is not a colour. The file then highlights
    /// everywhere except its comments, which reads as a theme problem and sends
    /// you looking in the wrong place entirely.
    #[test]
    fn comments_colour_in_every_language_that_has_them() {
        let samples: &[(Language, &str, &str)] = &[
            (Language::Rust, "// note\nfn a() {}\n", "//"),
            (Language::Swift, "// note\nfunc a() {}\n", "//"),
            (Language::JavaScript, "// note\nfunction a() {}\n", "//"),
            (Language::TypeScript, "// note\nfunction a() {}\n", "//"),
            (Language::Tsx, "// note\nconst a = 1;\n", "//"),
            (Language::Go, "// note\nfunc main() {}\n", "//"),
            (Language::Python, "# note\ndef a():\n    pass\n", "#"),
            (Language::Toml, "# note\na = 1\n", "#"),
            (Language::Yaml, "# note\na: 1\n", "#"),
            (Language::Shell, "# note\necho hi\n", "#"),
        ];
        for (language, source, token) in samples {
            let spans = spans(*language, source).expect("highlights");
            let at = source.find(token).expect("the comment") as u32;
            assert_eq!(
                kind_at(&spans, at),
                Some(Kind::Comment),
                "{} left its comment uncoloured: {spans:?}",
                language.id()
            );
        }
    }

    /// Every capture name must have a kind, or a grammar's captures silently
    /// shift onto the wrong colours.
    #[test]
    fn every_capture_has_a_kind() {
        assert_eq!(CAPTURES.len(), KINDS.len());
    }
}
