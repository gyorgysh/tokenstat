// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Development tasks. Not shipped to users.
//!
//! `redact` turns a real session log into a committable fixture, and `notices`
//! writes the third party attribution that ships beside a release binary.
//!
//! Hand redaction does not scale. A single project directory here holds nearly
//! two thousand files, and one missed field publishes somebody's source code.
//! So the tool works on a default-deny allowlist: a key survives only if it is
//! named, and everything else is dropped without being inspected. Adding a new
//! field to a parser therefore requires adding it to the allowlist too, which
//! is the point.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde_json::{Map, Value};

mod notices;

/// Keys kept for Claude Code transcripts, as paths from the record root.
///
/// Anything not listed is discarded. In particular `message.content`, `cwd`,
/// `gitBranch`, and `toolUseResult` never survive, because they carry prompts,
/// file contents, and local paths.
const CLAUDE_ALLOW: &[&str] = &[
    "type",
    "requestId",
    "uuid",
    "parentUuid",
    "sessionId",
    "timestamp",
    "version",
    "isSidechain",
    "message.id",
    "message.model",
    "message.role",
    "message.type",
    "message.stop_reason",
    "message.usage.input_tokens",
    "message.usage.output_tokens",
    "message.usage.cache_read_input_tokens",
    "message.usage.cache_creation_input_tokens",
    "message.usage.service_tier",
    "message.usage.cache_creation.ephemeral_5m_input_tokens",
    "message.usage.cache_creation.ephemeral_1h_input_tokens",
    "message.usage.server_tool_use.web_search_requests",
    "message.usage.server_tool_use.web_fetch_requests",
    "message.usage.iterations.input_tokens",
    "message.usage.iterations.output_tokens",
    "message.usage.iterations.cache_read_input_tokens",
    "message.usage.iterations.cache_creation_input_tokens",
];

/// Fields holding an identifier that must be replaced but whose equality
/// relationships have to survive, or the deduplication fixtures stop testing
/// anything.
const ID_FIELDS: &[&str] = &["requestId", "uuid", "parentUuid", "sessionId", "message.id"];

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("redact") => {
            let input = args
                .next()
                .context("usage: xtask redact <input> <output> [max]")?;
            let output = args
                .next()
                .context("usage: xtask redact <input> <output> [max]")?;
            // Fixtures are read by humans and live in git forever, so they stay
            // small on purpose. A whole project directory is 15 MB.
            let max = args.next().and_then(|v| v.parse().ok()).unwrap_or(8);
            redact(Path::new(&input), Path::new(&output), max)
        }
        Some("notices") => {
            // Generated into target/ on purpose: a tracked generated file is
            // what check-no-artifacts.sh exists to reject.
            let out = args
                .next()
                .unwrap_or_else(|| "target/THIRD-PARTY-NOTICES.md".to_string());
            let root = args.next().unwrap_or_else(|| "tokenstat-cli".to_string());
            notices::generate(&root, Path::new(&out))
        }
        Some(other) => bail!("unknown task: {other}"),
        None => {
            eprintln!("tasks:");
            eprintln!("  redact <input.jsonl|dir> <output-dir> [max-files]");
            eprintln!("      build a committable fixture (default 8 files)");
            eprintln!("  notices [output] [root-crate]");
            eprintln!("      write third party attribution for a shipped binary");
            Ok(())
        }
    }
}

fn redact(input: &Path, out_dir: &Path, max_files: usize) -> Result<()> {
    let files: Vec<PathBuf> = if input.is_dir() {
        walkdir::WalkDir::new(input)
            .into_iter()
            .filter_map(Result::ok)
            .filter(|e| e.file_type().is_file())
            .map(|e| e.into_path())
            .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
            .collect()
    } else {
        vec![input.to_path_buf()]
    };

    std::fs::create_dir_all(out_dir)?;
    // Shared across files so an id appearing in two transcripts, which is
    // exactly the resume-duplicate case, maps to the same pseudonym in both.
    let mut names = Pseudonyms::default();
    let mut written = 0;

    for (n, path) in files.iter().enumerate() {
        let contents = std::fs::read_to_string(path)?;
        let mut kept = String::new();
        for line in contents.lines() {
            let Ok(value) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            let Some(obj) = value.as_object() else {
                continue;
            };
            // Only usage-bearing rows are worth keeping in a fixture.
            if obj.get("type").and_then(Value::as_str) != Some("assistant") {
                continue;
            }
            let filtered = filter_object(obj, "", CLAUDE_ALLOW, &mut names);
            kept.push_str(&serde_json::to_string(&Value::Object(filtered))?);
            kept.push('\n');
        }
        if kept.is_empty() {
            continue;
        }
        let name = format!("session-{n:03}.jsonl");
        std::fs::write(out_dir.join(&name), kept)?;
        written += 1;
        if written >= max_files {
            break;
        }
    }

    println!("wrote {written} fixture files to {}", out_dir.display());
    println!("review them before committing, then run: cargo test");
    Ok(())
}

/// Deterministic, stable pseudonyms that preserve equality between records.
#[derive(Default)]
struct Pseudonyms {
    seen: BTreeMap<String, String>,
}

impl Pseudonyms {
    fn get(&mut self, field: &str, original: &str) -> String {
        let next = self.seen.len();
        self.seen
            .entry(format!("{field}:{original}"))
            .or_insert_with(|| {
                let prefix = match field {
                    "requestId" => "req",
                    "message.id" => "msg",
                    "sessionId" => "ses",
                    _ => "id",
                };
                format!("{prefix}_{next:05}")
            })
            .clone()
    }
}

fn filter_object(
    obj: &Map<String, Value>,
    prefix: &str,
    allow: &[&str],
    names: &mut Pseudonyms,
) -> Map<String, Value> {
    let mut out = Map::new();
    for (k, v) in obj {
        let path = if prefix.is_empty() {
            k.clone()
        } else {
            format!("{prefix}.{k}")
        };

        // A container survives when anything beneath it is allowed.
        let is_prefix = allow.iter().any(|a| a.starts_with(&format!("{path}.")));
        let is_leaf = allow.contains(&path.as_str());
        if !is_prefix && !is_leaf {
            continue;
        }

        let redacted = match v {
            Value::Object(inner) => Value::Object(filter_object(inner, &path, allow, names)),
            Value::Array(items) => Value::Array(
                items
                    .iter()
                    .map(|item| match item {
                        Value::Object(inner) => {
                            Value::Object(filter_object(inner, &path, allow, names))
                        }
                        // A bare scalar in an array cannot be verified as safe,
                        // so it does not survive.
                        _ => Value::Null,
                    })
                    .collect(),
            ),
            Value::String(s) if ID_FIELDS.contains(&path.as_str()) => {
                Value::String(names.get(&path, s))
            }
            // Timestamps, model names, and enum-ish values are kept verbatim
            // because the tests depend on them and they identify nobody.
            Value::String(s) if is_leaf && is_safe_string(&path, s) => Value::String(s.clone()),
            Value::String(_) => continue,
            other => other.clone(),
        };
        out.insert(k.clone(), redacted);
    }
    out
}

/// A string leaf may be kept only if it is a known shape.
fn is_safe_string(path: &str, s: &str) -> bool {
    if s.len() > 64 || s.contains('/') || s.contains('\\') {
        return false;
    }
    matches!(
        path,
        "type"
            | "timestamp"
            | "version"
            | "message.model"
            | "message.role"
            | "message.type"
            | "message.stop_reason"
            | "message.usage.service_tier"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(s: &str) -> Map<String, Value> {
        serde_json::from_str(s).unwrap()
    }

    #[test]
    fn prompt_text_and_paths_do_not_survive() {
        let input = parse(
            r#"{"type":"assistant","cwd":"/Users/someone/secret-project",
                "gitBranch":"feature/acquisition",
                "message":{"id":"msg_1","model":"claude-opus-4-8",
                           "content":[{"type":"text","text":"my secret prompt"}],
                           "usage":{"input_tokens":5,"output_tokens":6}}}"#,
        );
        let mut names = Pseudonyms::default();
        let out = filter_object(&input, "", CLAUDE_ALLOW, &mut names);
        let s = serde_json::to_string(&out).unwrap();
        assert!(!s.contains("secret"));
        assert!(!s.contains("Users"));
        assert!(!s.contains("acquisition"));
        assert!(!s.contains("content"));
        // The counters, which are the thing under test, are untouched.
        assert!(s.contains("\"input_tokens\":5"));
        assert!(s.contains("claude-opus-4-8"));
    }

    #[test]
    fn identifiers_are_pseudonymized_but_stay_equal_across_records() {
        let a = parse(r#"{"type":"assistant","requestId":"real_abc","message":{"id":"real_m"}}"#);
        let b = parse(r#"{"type":"assistant","requestId":"real_abc","message":{"id":"real_m"}}"#);
        let mut names = Pseudonyms::default();
        let ra = filter_object(&a, "", CLAUDE_ALLOW, &mut names);
        let rb = filter_object(&b, "", CLAUDE_ALLOW, &mut names);
        assert_ne!(ra["requestId"], Value::String("real_abc".into()));
        // Equality survives, so the deduplication fixture still tests dedup.
        assert_eq!(ra["requestId"], rb["requestId"]);
        assert_eq!(ra["message"]["id"], rb["message"]["id"]);
    }

    #[test]
    fn distinct_identifiers_stay_distinct() {
        let a = parse(r#"{"type":"assistant","requestId":"one"}"#);
        let b = parse(r#"{"type":"assistant","requestId":"two"}"#);
        let mut names = Pseudonyms::default();
        let ra = filter_object(&a, "", CLAUDE_ALLOW, &mut names);
        let rb = filter_object(&b, "", CLAUDE_ALLOW, &mut names);
        assert_ne!(ra["requestId"], rb["requestId"]);
    }

    #[test]
    fn unknown_keys_are_dropped_by_default() {
        let input = parse(r#"{"type":"assistant","somethingBrandNew":"whatever"}"#);
        let mut names = Pseudonyms::default();
        let out = filter_object(&input, "", CLAUDE_ALLOW, &mut names);
        assert!(!out.contains_key("somethingBrandNew"));
    }

    #[test]
    fn nested_cache_fields_survive() {
        let input = parse(
            r#"{"type":"assistant","message":{"usage":{"cache_creation":
               {"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20,"secret":"x"}}}}"#,
        );
        let mut names = Pseudonyms::default();
        let out = filter_object(&input, "", CLAUDE_ALLOW, &mut names);
        let cc = &out["message"]["usage"]["cache_creation"];
        assert_eq!(cc["ephemeral_5m_input_tokens"], 10);
        assert_eq!(cc["ephemeral_1h_input_tokens"], 20);
        assert!(cc.get("secret").is_none());
    }

    #[test]
    fn a_path_shaped_value_is_rejected_even_in_an_allowed_field() {
        // Defence in depth: version is allowed, but a value that looks like a
        // path is not what a version is, so it does not survive.
        assert!(!is_safe_string("version", "/Users/me/x"));
        assert!(is_safe_string("version", "2.1.219"));
    }
}
