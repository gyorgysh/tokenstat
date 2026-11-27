// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
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

const ID_FIELDS: &[&str] = &[
    "requestId",
    "uuid",
    "parentUuid",
    "sessionId",
    "message.id",
    // Pi keeps the event id and its parent at the top level.
    "id",
    "parentId",
    // The DeepSeek Harness nests its message id.
    "data.message.id",
    "metadata.request_id",
    "stream.id",
    "agentId",
];

const PI_ALLOW: &[&str] = &[
    "type",
    "id",
    "parentId",
    "timestamp",
    "version",
    "provider",
    "modelId",
    "message.role",
    "message.model",
    "message.usage.input",
    "message.usage.output",
    "message.usage.cacheRead",
    "message.usage.cacheWrite",
    "message.usage.reasoning",
    "message.usage.totalTokens",
    "message.usage.cost.input",
    "message.usage.cost.output",
    "message.usage.cost.cacheRead",
    "message.usage.cost.cacheWrite",
    "message.usage.cost.total",
];

const DEVIN_ALLOW: &[&str] = &[
    "role",
    "metadata.request_id",
    "metadata.generation_model",
    "metadata.started_generation_at",
    "metadata.created_at",
    "metadata.finish_reason",
    "metadata.num_tokens",
    "metadata.metrics.input_tokens",
    "metadata.metrics.output_tokens",
    "metadata.metrics.cache_read_tokens",
    "metadata.metrics.cache_creation_tokens",
    "metadata.metrics.ttft_ms",
    "metadata.metrics.total_time_ms",
];

const QWEN_ALLOW: &[&str] = &[
    "schemaVersion",
    "id",
    "timestamp",
    "sessionId",
    "model",
    "authType",
    "source",
    "inputTokens",
    "outputTokens",
    "cachedTokens",
    "thoughtsTokens",
    "totalTokens",
    "apiDurationMs",
];

const KIMI_ALLOW: &[&str] = &[
    "type",
    "time",
    "agentId",
    "model",
    // The counters live under `usage`; each path has to name the container,
    // or `filter_object` descends into `usage` and drops every leaf.
    "usage.inputOther",
    "usage.output",
    "usage.inputCacheRead",
    "usage.inputCacheCreation",
    "usageScope",
];

const MUSE_ALLOW: &[&str] = &[
    "schema_version",
    "id",
    "sequence",
    "recorded_at",
    "record_type",
    "payload_type",
    "payload_schema_version",
    "stream.kind",
    "stream.id",
    "payload.event.kind",
    "payload.event.model",
    "payload.event.duration_ms",
    "payload.event.finish_reason",
    "payload.event.usage.input_tokens",
    "payload.event.usage.output_tokens",
    "payload.event.usage.cached_tokens",
    "payload.event.usage.cache_write_tokens",
    "payload.event.usage.cache_read_tokens",
    "payload.event.usage.reasoning_tokens",
];

const DSH_ALLOW: &[&str] = &[
    "type",
    "seq",
    "time",
    "data.turn",
    "data.step",
    "data.message.role",
    "data.message.id",
    "data.message.source.kind",
    "data.message.source.provider",
    "data.message.source.model",
    "data.usage.inputTokens",
    "data.usage.outputTokens",
    "data.usage.cacheReadTokens",
    "data.usage.reasoningTokens",
];

#[derive(Clone, Copy, PartialEq)]
enum Profile {
    ClaudeCode,
    Pi,
    Dsh,
    Muse,
    Devin,
    Kimi,
    Qwen,
}

impl Profile {
    fn parse(name: &str) -> Result<Self> {
        match name {
            "claude" | "claude_code" => Ok(Self::ClaudeCode),
            "pi" => Ok(Self::Pi),
            "dsh" => Ok(Self::Dsh),
            "muse" => Ok(Self::Muse),
            "devin" => Ok(Self::Devin),
            "kimi" => Ok(Self::Kimi),
            "qwen" => Ok(Self::Qwen),
            other => anyhow::bail!(
                "unknown redaction profile: {other} (claude_code, pi, dsh, muse, devin, kimi, qwen)"
            ),
        }
    }

    fn allow(self) -> &'static [&'static str] {
        match self {
            Self::ClaudeCode => CLAUDE_ALLOW,
            Self::Pi => PI_ALLOW,
            Self::Dsh => DSH_ALLOW,
            Self::Muse => MUSE_ALLOW,
            Self::Devin => DEVIN_ALLOW,
            Self::Kimi => KIMI_ALLOW,
            Self::Qwen => QWEN_ALLOW,
        }
    }

    fn keeps(self, obj: &serde_json::Map<String, Value>) -> bool {
        match self {
            Self::ClaudeCode => obj.get("type").and_then(Value::as_str) == Some("assistant"),
            Self::Pi => {
                obj.get("type").and_then(Value::as_str) == Some("message")
                    && obj
                        .get("message")
                        .and_then(Value::as_object)
                        .is_some_and(|m| m.contains_key("usage"))
            }
            // The finished message only. `assistant/chunk` repeats the same
            // counters, and a fixture carrying both would teach the parser's
            // test that double counting is correct.
            Self::Dsh => obj.get("type").and_then(Value::as_str) == Some("assistant/message"),
            // The one record that carries counters. `goal_usage_attribution`
            // restates the same spend against a goal and
            // `subagent.control.runtime_observed` restates a child's running
            // total, so a fixture carrying either would teach the parser's
            // test that double counting is correct.
            Self::Muse => {
                obj.get("payload")
                    .and_then(Value::as_object)
                    .and_then(|p| p.get("event"))
                    .and_then(Value::as_object)
                    .and_then(|e| e.get("kind"))
                    .and_then(Value::as_str)
                    == Some("model_completed")
            }
            Self::Devin => {
                obj.get("role").and_then(Value::as_str) == Some("assistant")
                    && obj
                        .get("metadata")
                        .and_then(Value::as_object)
                        .and_then(|m| m.get("metrics"))
                        .and_then(Value::as_object)
                        .is_some_and(|m| m.contains_key("output_tokens"))
            }
            Self::Qwen => {
                obj.contains_key("totalTokens")
                    && ["inputTokens", "outputTokens", "thoughtsTokens"]
                        .iter()
                        .any(|k| obj.get(*k).and_then(Value::as_u64).is_some_and(|v| v > 0))
            }
            Self::Kimi => {
                obj.get("type").and_then(Value::as_str) == Some("usage.record")
                    && obj
                        .get("usage")
                        .and_then(Value::as_object)
                        .is_some_and(|usage| {
                            [
                                "inputOther",
                                "output",
                                "inputCacheRead",
                                "inputCacheCreation",
                            ]
                            .iter()
                            .any(|key| {
                                usage
                                    .get(*key)
                                    .and_then(Value::as_u64)
                                    .is_some_and(|value| value > 0)
                            })
                        })
            }
        }
    }
}

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("redact") => {
            let input = args
                .next()
                .context("usage: xtask redact <input> <output> [max] [profile]")?;
            let output = args
                .next()
                .context("usage: xtask redact <input> <output> [max] [profile]")?;
            let max = args.next().and_then(|v| v.parse().ok()).unwrap_or(8);
            let profile = match args.next() {
                Some(name) => Profile::parse(&name)?,
                None => Profile::ClaudeCode,
            };
            redact(Path::new(&input), Path::new(&output), max, profile)
        }
        Some("notices") => {
            let out = args
                .next()
                .unwrap_or_else(|| "target/THIRD-PARTY-NOTICES.md".to_string());
            let root = args.next().unwrap_or_else(|| "tokenstat-cli".to_string());
            notices::generate(&root, Path::new(&out))
        }
        Some("pricing-seed") => {
            let out = args
                .next()
                .context("usage: xtask pricing-seed <output.json>")?;
            pricing_seed(Path::new(&out))
        }
        Some(other) => bail!("unknown task: {other}"),
        None => {
            eprintln!("tasks:");
            eprintln!("  redact <input.jsonl|dir> <output-dir> [max-files]");
            eprintln!("      build a committable fixture (default 8 files)");
            eprintln!("  notices [output] [root-crate]");
            eprintln!("      write third party attribution for a shipped binary");
            eprintln!("  pricing-seed <output.json>");
            eprintln!("      download the price book an app bundle ships with");
            Ok(())
        }
    }
}

fn pricing_seed(out: &Path) -> Result<()> {
    if let Some(parent) = out.parent() {
        std::fs::create_dir_all(parent)?;
    }
    match tokenstat_sync::pricing::download_to(out) {
        Ok(refresh) => {
            println!(
                "pricing seed: {} models, effective {} -> {}",
                refresh.models,
                refresh.effective_from,
                out.display()
            );
            Ok(())
        }
        Err(error) => {
            eprintln!("pricing seed: could not download ({error})");
            eprintln!("pricing seed: writing an empty book, the app refreshes on first launch");
            let empty = serde_json::json!({
                "effective_from": "",
                "note": "empty seed: the download failed at build time",
                "models": [],
            });
            std::fs::write(out, serde_json::to_string_pretty(&empty)?)?;
            Ok(())
        }
    }
}

fn redact(input: &Path, out_dir: &Path, max_files: usize, profile: Profile) -> Result<()> {
    let mut files: Vec<PathBuf> = if input.is_dir() {
        walkdir::WalkDir::new(input)
            .into_iter()
            .filter_map(Result::ok)
            .filter(|e| e.file_type().is_file())
            .map(|e| e.into_path())
            .filter(|p| {
                p.extension().is_some_and(|x| x == "jsonl")
                    || p.file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| n.ends_with(".jsonl.zstd"))
            })
            .collect()
    } else {
        vec![input.to_path_buf()]
    };

    files.sort();
    std::fs::create_dir_all(out_dir)?;
    let mut names = Pseudonyms::default();
    let mut written = 0;

    for (n, path) in files.iter().enumerate() {
        if written >= max_files {
            break;
        }
        // The harness compresses its sessions. A fixture stays plain text, so
        // it can be read in a diff and so the guard in `tests/fixtures.rs` can
        // check it without a decoder.
        let contents = if path.extension().is_some_and(|x| x == "zstd") {
            let bytes = std::fs::read(path)?;
            String::from_utf8_lossy(&zstd::decode_all(&bytes[..])?).into_owned()
        } else {
            std::fs::read_to_string(path)?
        };
        let mut kept = String::new();
        for line in contents.lines() {
            let Ok(value) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            let Some(obj) = value.as_object() else {
                continue;
            };
            if !profile.keeps(obj) {
                continue;
            }
            let filtered = filter_object(obj, "", profile.allow(), &mut names);
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

#[derive(Default)]
struct Pseudonyms {
    seen: BTreeMap<String, String>,
}

impl Pseudonyms {
    fn get(&mut self, field: &str, original: &str) -> String {
        let field = match field {
            "parentUuid" => "uuid",
            "parentId" => "id",
            field => field,
        };
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
                        _ => Value::Null,
                    })
                    .collect(),
            ),
            Value::String(s) if ID_FIELDS.contains(&path.as_str()) => {
                Value::String(names.get(&path, s))
            }
            Value::String(s) if is_leaf && is_safe_string(&path, s) => Value::String(s.clone()),
            Value::String(_) => continue,
            other => other.clone(),
        };
        out.insert(k.clone(), redacted);
    }
    out
}

fn is_safe_string(path: &str, s: &str) -> bool {
    let separators = s.contains('/') || s.contains('\\');
    if s.len() > 64 || (separators && path != "type") {
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
            // The DeepSeek Harness nests what the others keep at the top.
            | "data.message.role"
            | "data.message.source.kind"
            | "data.message.source.provider"
            | "data.message.source.model"
            | "time"
            | "provider"
            | "modelId"
            | "role"
            | "metadata.generation_model"
            | "metadata.started_generation_at"
            | "metadata.created_at"
            | "metadata.finish_reason"
            | "model"
            | "authType"
            | "source"
            | "usageScope"
            | "recorded_at"
            | "record_type"
            | "payload_type"
            | "stream.kind"
            | "payload.event.kind"
            | "payload.event.model"
            | "payload.event.finish_reason"
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
        assert!(!is_safe_string("version", "/Users/me/x"));
        assert!(is_safe_string("version", "2.1.219"));
    }

    #[test]
    fn every_profile_retains_usage_discriminators_and_model_metadata() {
        for (profile, input, expected) in [
            (
                Profile::Pi,
                r#"{"type":"message","id":"secret-id","parentId":"secret-parent","provider":"anthropic","modelId":"claude","message":{"role":"assistant","model":"claude","usage":{"input":3}}}"#,
                vec!["provider", "modelId", "message.role", "message.model"],
            ),
            (
                Profile::Dsh,
                r#"{"type":"assistant/message","time":"2026-10-12T00:00:00Z","data":{"message":{"id":"secret-id","role":"assistant","source":{"kind":"provider","provider":"deepseek","model":"deepseek-v4"}},"usage":{"inputTokens":3}}}"#,
                vec!["time", "data.message.role", "data.message.source.model"],
            ),
            (
                Profile::Devin,
                r#"{"role":"assistant","metadata":{"request_id":"secret-id","generation_model":"swe-1-6","started_generation_at":"2026-10-12T00:00:00Z","created_at":"2026-10-12T00:00:00Z","finish_reason":"stop","metrics":{"output_tokens":3}}}"#,
                vec![
                    "role",
                    "metadata.generation_model",
                    "metadata.started_generation_at",
                    "metadata.created_at",
                    "metadata.finish_reason",
                ],
            ),
            (
                Profile::Qwen,
                r#"{"id":"secret-id","sessionId":"secret-session","model":"qwen3-coder","authType":"qwen-oauth","source":"api","totalTokens":3,"outputTokens":3}"#,
                vec!["model", "authType", "source"],
            ),
            (
                Profile::Kimi,
                r#"{"type":"usage.record","agentId":"secret-agent","model":"kimi-k2.5","usageScope":"turn","usage":{"output":3}}"#,
                vec!["type", "model", "usageScope"],
            ),
            (
                Profile::Muse,
                r#"{"id":"secret-id","stream":{"kind":"session","id":"secret-stream"},"record_type":"event","payload_type":"runtime.session","payload":{"event":{"kind":"model_completed","model":"muse-spark","finish_reason":"stop","usage":{"output_tokens":3}}}}"#,
                vec![
                    "stream.kind",
                    "record_type",
                    "payload_type",
                    "payload.event.kind",
                    "payload.event.model",
                    "payload.event.finish_reason",
                ],
            ),
        ] {
            let input = parse(input);
            assert!(profile.keeps(&input));
            let output = Value::Object(filter_object(
                &input,
                "",
                profile.allow(),
                &mut Pseudonyms::default(),
            ));
            for field in expected {
                let pointer = format!("/{}", field.replace('.', "/"));
                assert_eq!(
                    output.pointer(&pointer),
                    Value::Object(input.clone()).pointer(&pointer),
                    "{field}"
                );
            }
            assert!(!output.to_string().contains("secret-"));
        }
    }

    #[test]
    fn parent_references_keep_their_target_identity() {
        let mut names = Pseudonyms::default();
        assert_eq!(names.get("uuid", "a"), names.get("parentUuid", "a"));
        assert_eq!(names.get("id", "b"), names.get("parentId", "b"));
        assert_ne!(names.get("id", "a"), names.get("uuid", "a"));
    }
}
