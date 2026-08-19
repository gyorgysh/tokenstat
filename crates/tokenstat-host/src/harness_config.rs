// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! The handful of harness settings the launcher (i) badge can change.
//!
//! Another tool's files are read, never written, except here: someone pressed
//! Save on a form that names the file. Never on a timer, never on open. Only
//! allowlisted keys come back, because these files also hold credentials. A
//! backup, when one is written, is `0600` beside the original.

use std::fs;
use std::ops::Range;
use std::path::{Path, PathBuf};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use serde_json::{Map, Value, json};

/// Read the allowlisted settings for a launcher profile.
pub fn get(id: &str) -> Result<Value, String> {
    let Some(schema) = schema(id) else {
        return Ok(json!({
            "id": id,
            "path": Value::Null,
            "available": false,
            "reason": "This tool has no settings this app can change.",
            "fields": [],
        }));
    };
    let path = (schema.path)();
    let path_str = path.display().to_string();
    if !path.exists() {
        return Ok(json!({
            "id": schema.id,
            "path": path_str,
            "available": false,
            "reason": format!("No config at {path_str}"),
            "fields": [],
        }));
    }
    let text = fs::read_to_string(&path).map_err(|e| format!("{path_str}: {e}"))?;
    let fields = match schema.kind {
        FileKind::Toml => read_toml(&text, schema.fields),
        FileKind::Json => match read_json(&text, schema.fields) {
            Ok(fields) => fields,
            Err(reason) => {
                return Ok(json!({
                    "id": schema.id,
                    "path": path_str,
                    "available": false,
                    "reason": reason,
                    "fields": [],
                }));
            }
        },
    };
    Ok(json!({
        "id": schema.id,
        "path": path_str,
        "available": true,
        "reason": Value::Null,
        "fields": fields,
    }))
}

/// Write allowlisted settings. Unknown keys are refused, not ignored.
pub fn set(id: &str, values: &Map<String, Value>) -> Result<Value, String> {
    let schema = schema(id).ok_or_else(|| format!("no configurator for {id}"))?;
    for key in values.keys() {
        if !schema.fields.iter().any(|field| field.key == key) {
            return Err(format!("refusing unknown setting {key}"));
        }
    }
    let path = (schema.path)();
    let path_str = path.display().to_string();
    let original = if path.exists() {
        fs::read_to_string(&path).map_err(|e| format!("{path_str}: {e}"))?
    } else {
        String::new()
    };
    let mut next = original.clone();
    for field in schema.fields {
        let Some(value) = values.get(field.key) else {
            continue;
        };
        let encoded = encode_field(field, value)?;
        next = match (schema.kind, field.loc) {
            (FileKind::Toml, Loc::Toml { section, key }) => toml_set(&next, section, key, &encoded),
            (FileKind::Json, Loc::Json { pointer }) => {
                json_set(&next, pointer, &json_value(field, value)?)?
            }
            _ => return Err(format!("{} cannot be written as {}", field.key, id)),
        };
    }
    if next != original {
        write_with_backup(&path, &original, &next)?;
    }
    get(id)
}

fn write_with_backup(path: &Path, original: &str, next: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    }
    if !original.is_empty() {
        let backup = backup_path(path);
        write_private(&backup, original)?;
    }
    write_private(path, next)
}

fn backup_path(path: &Path) -> PathBuf {
    let mut backup = path.as_os_str().to_os_string();
    backup.push(".bak");
    PathBuf::from(backup)
}

fn write_private(path: &Path, text: &str) -> Result<(), String> {
    fs::write(path, text).map_err(|e| format!("{}: {e}", path.display()))?;
    #[cfg(unix)]
    {
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

#[derive(Clone, Copy)]
enum FileKind {
    Toml,
    Json,
}

#[derive(Clone, Copy)]
enum Loc {
    Toml {
        section: Option<&'static str>,
        key: &'static str,
    },
    Json {
        pointer: &'static str,
    },
}

#[derive(Clone, Copy)]
enum FieldKind {
    Text,
    Number,
    Bool,
    Choice,
}

struct Field {
    key: &'static str,
    label: &'static str,
    kind: FieldKind,
    options: &'static [&'static str],
    hint: Option<&'static str>,
    loc: Loc,
}

struct Schema {
    id: &'static str,
    path: fn() -> PathBuf,
    kind: FileKind,
    fields: &'static [Field],
}

fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default()
}

fn schema(id: &str) -> Option<Schema> {
    match id {
        "grok" => Some(Schema {
            id: "grok",
            path: || home().join(".grok/config.toml"),
            kind: FileKind::Toml,
            fields: GROK,
        }),
        "codex" => Some(Schema {
            id: "codex",
            path: || home().join(".codex/config.toml"),
            kind: FileKind::Toml,
            fields: CODEX,
        }),
        "claude_code" => Some(Schema {
            id: "claude_code",
            path: || home().join(".claude/settings.json"),
            kind: FileKind::Json,
            fields: CLAUDE,
        }),
        "opencode" | "opencode2" => Some(Schema {
            id: if id == "opencode2" {
                "opencode2"
            } else {
                "opencode"
            },
            path: || home().join(".config/opencode/opencode.jsonc"),
            kind: FileKind::Json,
            fields: OPENCODE,
        }),
        _ => None,
    }
}

const GROK: &[Field] = &[
    Field {
        key: "model",
        label: "Model",
        kind: FieldKind::Text,
        options: &[],
        hint: None,
        loc: Loc::Toml {
            section: Some("models"),
            key: "default",
        },
    },
    Field {
        key: "effort",
        label: "Effort",
        kind: FieldKind::Choice,
        options: &["low", "medium", "high", "xhigh"],
        hint: None,
        loc: Loc::Toml {
            section: Some("models"),
            key: "default_reasoning_effort",
        },
    },
    Field {
        key: "compact",
        label: "Compact at",
        kind: FieldKind::Number,
        options: &[],
        hint: Some("percent of the context window"),
        loc: Loc::Toml {
            section: Some("session"),
            key: "auto_compact_threshold_percent",
        },
    },
    Field {
        key: "permission",
        label: "Permissions",
        kind: FieldKind::Choice,
        options: &[
            "default",
            "auto",
            "acceptEdits",
            "always-approve",
            "bypassPermissions",
        ],
        hint: None,
        loc: Loc::Toml {
            section: Some("ui"),
            key: "permission_mode",
        },
    },
    Field {
        key: "yolo",
        label: "YOLO",
        kind: FieldKind::Bool,
        options: &[],
        hint: None,
        loc: Loc::Toml {
            section: Some("ui"),
            key: "yolo",
        },
    },
    Field {
        key: "compact_mode",
        label: "Compact mode",
        kind: FieldKind::Bool,
        options: &[],
        hint: None,
        loc: Loc::Toml {
            section: Some("ui"),
            key: "compact_mode",
        },
    },
];

const CODEX: &[Field] = &[
    Field {
        key: "model",
        label: "Model",
        kind: FieldKind::Text,
        options: &[],
        hint: None,
        loc: Loc::Toml {
            section: None,
            key: "model",
        },
    },
    Field {
        key: "effort",
        label: "Effort",
        kind: FieldKind::Choice,
        options: &["minimal", "low", "medium", "high", "xhigh"],
        hint: None,
        loc: Loc::Toml {
            section: None,
            key: "model_reasoning_effort",
        },
    },
    Field {
        key: "compact",
        label: "Compact after",
        kind: FieldKind::Number,
        options: &[],
        hint: Some(
            "tokens. Codex's context-window override is not offered: it has been reported to break compaction.",
        ),
        loc: Loc::Toml {
            section: None,
            key: "model_auto_compact_token_limit",
        },
    },
    Field {
        key: "approval",
        label: "Approval",
        kind: FieldKind::Choice,
        options: &["untrusted", "on-request", "never"],
        hint: None,
        loc: Loc::Toml {
            section: None,
            key: "approval_policy",
        },
    },
    Field {
        key: "sandbox",
        label: "Sandbox",
        kind: FieldKind::Choice,
        options: &["read-only", "workspace-write", "danger-full-access"],
        hint: None,
        loc: Loc::Toml {
            section: None,
            key: "sandbox_mode",
        },
    },
];

const CLAUDE: &[Field] = &[
    Field {
        key: "model",
        label: "Model",
        kind: FieldKind::Text,
        options: &[],
        hint: None,
        loc: Loc::Json { pointer: "/model" },
    },
    Field {
        key: "effort",
        label: "Effort",
        kind: FieldKind::Choice,
        options: &["low", "medium", "high"],
        hint: None,
        loc: Loc::Json {
            pointer: "/effortLevel",
        },
    },
    Field {
        key: "theme",
        label: "Theme",
        kind: FieldKind::Text,
        options: &[],
        hint: None,
        loc: Loc::Json { pointer: "/theme" },
    },
];

const OPENCODE: &[Field] = &[
    Field {
        key: "model",
        label: "Model",
        kind: FieldKind::Text,
        options: &[],
        hint: Some("provider/model"),
        loc: Loc::Json { pointer: "/model" },
    },
    Field {
        key: "small_model",
        label: "Small model",
        kind: FieldKind::Text,
        options: &[],
        hint: None,
        loc: Loc::Json {
            pointer: "/small_model",
        },
    },
    Field {
        key: "compact_auto",
        label: "Auto compact",
        kind: FieldKind::Bool,
        options: &[],
        hint: None,
        loc: Loc::Json {
            pointer: "/compaction/auto",
        },
    },
    Field {
        key: "compact_prune",
        label: "Prune tool output",
        kind: FieldKind::Bool,
        options: &[],
        hint: None,
        loc: Loc::Json {
            pointer: "/compaction/prune",
        },
    },
    Field {
        key: "compact_tail",
        label: "Keep recent turns",
        kind: FieldKind::Number,
        options: &[],
        hint: None,
        loc: Loc::Json {
            pointer: "/compaction/tail_turns",
        },
    },
    Field {
        key: "compact_preserve",
        label: "Preserve recent tokens",
        kind: FieldKind::Number,
        options: &[],
        hint: None,
        loc: Loc::Json {
            pointer: "/compaction/preserve_recent_tokens",
        },
    },
    Field {
        key: "compact_reserved",
        label: "Reserved for compact",
        kind: FieldKind::Number,
        options: &[],
        hint: None,
        loc: Loc::Json {
            pointer: "/compaction/reserved",
        },
    },
    Field {
        key: "tool_max_lines",
        label: "Tool output lines",
        kind: FieldKind::Number,
        options: &[],
        hint: None,
        loc: Loc::Json {
            pointer: "/tool_output/max_lines",
        },
    },
    Field {
        key: "tool_max_bytes",
        label: "Tool output bytes",
        kind: FieldKind::Number,
        options: &[],
        hint: None,
        loc: Loc::Json {
            pointer: "/tool_output/max_bytes",
        },
    },
];

fn field_json(field: &Field, value: Option<String>) -> Value {
    json!({
        "key": field.key,
        "label": field.label,
        "kind": match field.kind {
            FieldKind::Text => "text",
            FieldKind::Number => "number",
            FieldKind::Bool => "bool",
            FieldKind::Choice => "choice",
        },
        "options": field.options,
        "hint": field.hint,
        "value": value,
    })
}

fn read_toml(text: &str, fields: &[Field]) -> Vec<Value> {
    fields
        .iter()
        .map(|field| {
            let value = match field.loc {
                Loc::Toml { section, key } => toml_get(text, section, key),
                Loc::Json { .. } => None,
            };
            field_json(field, value)
        })
        .collect()
}

fn read_json(text: &str, fields: &[Field]) -> Result<Vec<Value>, String> {
    let stripped = strip_jsonc(text);
    let root: Value = serde_json::from_str(&stripped).map_err(|e| e.to_string())?;
    Ok(fields
        .iter()
        .map(|field| {
            let value = match field.loc {
                Loc::Json { pointer } => json_get(&root, pointer).map(json_to_string),
                Loc::Toml { .. } => None,
            };
            field_json(field, value)
        })
        .collect())
}

fn encode_field(field: &Field, value: &Value) -> Result<String, String> {
    match field.kind {
        FieldKind::Bool => match value {
            Value::Bool(v) => Ok(v.to_string()),
            Value::String(s) if s == "true" || s == "false" => Ok(s.clone()),
            _ => Err(format!("{} must be true or false", field.key)),
        },
        FieldKind::Number => {
            let n = value
                .as_i64()
                .or_else(|| value.as_str().and_then(|s| s.parse().ok()))
                .ok_or_else(|| format!("{} must be a number", field.key))?;
            Ok(n.to_string())
        }
        FieldKind::Choice | FieldKind::Text => {
            let s = value
                .as_str()
                .map(str::to_string)
                .or_else(|| value.as_i64().map(|n| n.to_string()))
                .ok_or_else(|| format!("{} must be text", field.key))?;
            if matches!(field.kind, FieldKind::Choice)
                && !field.options.is_empty()
                && !field.options.contains(&s.as_str())
            {
                return Err(format!("{s} is not a valid {}", field.key));
            }
            if s.chars().any(|c| c == '\n' || c == '\r' || c.is_control()) {
                return Err(format!("{} contains control characters", field.key));
            }
            Ok(toml_quote(&s))
        }
    }
}

fn toml_quote(value: &str) -> String {
    if value.parse::<i64>().is_ok() || value == "true" || value == "false" {
        return value.to_string();
    }
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

fn json_value(field: &Field, value: &Value) -> Result<Value, String> {
    match field.kind {
        FieldKind::Bool => match value {
            Value::Bool(v) => Ok(json!(*v)),
            Value::String(s) if s == "true" => Ok(json!(true)),
            Value::String(s) if s == "false" => Ok(json!(false)),
            _ => Err(format!("{} must be true or false", field.key)),
        },
        FieldKind::Number => {
            let n = value
                .as_i64()
                .or_else(|| value.as_str().and_then(|s| s.parse().ok()))
                .ok_or_else(|| format!("{} must be a number", field.key))?;
            Ok(json!(n))
        }
        FieldKind::Choice | FieldKind::Text => {
            let s = value
                .as_str()
                .map(str::to_string)
                .ok_or_else(|| format!("{} must be text", field.key))?;
            Ok(json!(s))
        }
    }
}

fn toml_get(text: &str, section: Option<&str>, key: &str) -> Option<String> {
    let range = section_range(text, section)?;
    let body = &text[range];
    for line in body.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('#') || trimmed.is_empty() {
            continue;
        }
        let (left, right) = trimmed.split_once('=')?;
        if left.trim() == key {
            return Some(unquote(right.trim()));
        }
    }
    None
}

fn section_range(text: &str, section: Option<&str>) -> Option<Range<usize>> {
    match section {
        None => {
            let end = text.find("\n[").unwrap_or(text.len());
            Some(0..end)
        }
        Some(name) => {
            let header = format!("[{name}]");
            let start = text.find(&header)?;
            let after = start + header.len();
            let rest = &text[after..];
            let end = rest.find("\n[").map(|i| after + i).unwrap_or(text.len());
            Some(after..end)
        }
    }
}

fn toml_set(text: &str, section: Option<&str>, key: &str, encoded: &str) -> String {
    let assignment = format!("{key} = {encoded}");
    if let Some(updated) = replace_key(text, section, key, &assignment) {
        return updated;
    }
    insert_key(text, section, &assignment)
}

fn replace_key(text: &str, section: Option<&str>, key: &str, assignment: &str) -> Option<String> {
    let range = section_range(text, section)?;
    let body = &text[range.clone()];
    let body_start = range.start;
    let mut offset = 0;
    for line in body.split_inclusive('\n') {
        let trimmed = line.trim();
        let matches = !trimmed.starts_with('#')
            && trimmed
                .split_once('=')
                .is_some_and(|(left, _)| left.trim() == key);
        if matches {
            let start = body_start + offset;
            let end = start + line.len();
            let mut out = String::with_capacity(text.len() + assignment.len());
            out.push_str(&text[..start]);
            out.push_str(assignment);
            if line.ends_with('\n') {
                out.push('\n');
            }
            out.push_str(&text[end..]);
            return Some(out);
        }
        offset += line.len();
    }
    None
}

fn insert_key(text: &str, section: Option<&str>, assignment: &str) -> String {
    match section {
        None => {
            if text.is_empty() {
                return format!("{assignment}\n");
            }
            let mut out = String::new();
            out.push_str(assignment);
            out.push('\n');
            if !text.starts_with('\n') && !text.is_empty() {
                out.push('\n');
            }
            out.push_str(text);
            out
        }
        Some(name) => {
            let header = format!("[{name}]");
            if let Some(pos) = text.find(&header) {
                let insert_at = pos + header.len();
                let mut out = String::with_capacity(text.len() + assignment.len() + 2);
                out.push_str(&text[..insert_at]);
                if !text[insert_at..].starts_with('\n') {
                    out.push('\n');
                }
                out.push('\n');
                out.push_str(assignment);
                out.push('\n');
                out.push_str(text[insert_at..].trim_start_matches('\n'));
                if !out.ends_with('\n') {
                    out.push('\n');
                }
                out
            } else {
                let mut out = text.to_string();
                if !out.is_empty() && !out.ends_with('\n') {
                    out.push('\n');
                }
                out.push('\n');
                out.push_str(&header);
                out.push('\n');
                out.push_str(assignment);
                out.push('\n');
                out
            }
        }
    }
}

fn unquote(value: &str) -> String {
    let value = value.trim();
    if value.len() >= 2 && value.starts_with('"') && value.ends_with('"') {
        value[1..value.len() - 1]
            .replace("\\\"", "\"")
            .replace("\\\\", "\\")
    } else {
        value.to_string()
    }
}

fn strip_jsonc(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    let mut in_string = false;
    let mut escape = false;
    while let Some(c) = chars.next() {
        if in_string {
            out.push(c);
            if escape {
                escape = false;
            } else if c == '\\' {
                escape = true;
            } else if c == '"' {
                in_string = false;
            }
            continue;
        }
        match c {
            '"' => {
                in_string = true;
                out.push(c);
            }
            '/' if chars.peek() == Some(&'/') => {
                for n in chars.by_ref() {
                    if n == '\n' {
                        out.push('\n');
                        break;
                    }
                }
            }
            '/' if chars.peek() == Some(&'*') => {
                chars.next();
                let mut prev = '\0';
                for n in chars.by_ref() {
                    if prev == '*' && n == '/' {
                        break;
                    }
                    prev = n;
                }
            }
            _ => out.push(c),
        }
    }
    out
}

fn json_get<'a>(root: &'a Value, pointer: &str) -> Option<&'a Value> {
    root.pointer(pointer)
}

fn json_to_string(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Bool(v) => v.to_string(),
        Value::Number(n) => n.to_string(),
        other => other.to_string(),
    }
}

fn json_set(text: &str, pointer: &str, value: &Value) -> Result<String, String> {
    let encoded = serde_json::to_string(value).map_err(|e| e.to_string())?;
    let mut current = if text.trim().is_empty() {
        "{}\n".to_string()
    } else {
        text.to_string()
    };
    if let Some(range) = jsonc_value_span(&current, pointer) {
        let mut out = String::with_capacity(current.len() + encoded.len());
        out.push_str(&current[..range.start]);
        out.push_str(&encoded);
        out.push_str(&current[range.end..]);
        return Ok(out);
    }
    let parts = pointer_parts(pointer)?;
    for depth in 0..parts.len().saturating_sub(1) {
        let parent = format!("/{}", parts[..=depth].join("/"));
        if jsonc_value_span(&current, &parent).is_none() {
            current = jsonc_insert(&current, &parent, "{}")?;
        }
    }
    jsonc_insert(&current, pointer, &encoded)
}

fn pointer_parts(pointer: &str) -> Result<Vec<&str>, String> {
    if !pointer.starts_with('/') {
        return Err("json pointer must start with /".into());
    }
    Ok(pointer
        .trim_start_matches('/')
        .split('/')
        .filter(|p| !p.is_empty())
        .collect())
}

fn jsonc_value_span(text: &str, pointer: &str) -> Option<Range<usize>> {
    let parts = pointer_parts(pointer).ok()?;
    span_at(text, 0, &parts)
}

fn span_at(text: &str, from: usize, parts: &[&str]) -> Option<Range<usize>> {
    if parts.is_empty() {
        return None;
    }
    let mut i = from;
    skip_ws_and_comments(text, &mut i);
    if text.as_bytes().get(i) != Some(&b'{') {
        return None;
    }
    i += 1;
    loop {
        skip_ws_and_comments(text, &mut i);
        let bytes = text.as_bytes();
        if i >= bytes.len() {
            return None;
        }
        match bytes[i] {
            b'}' => return None,
            b',' => {
                i += 1;
                continue;
            }
            b'"' => {}
            _ => return None,
        }
        let key_end = consume_string(text, i).ok()?;
        let key = &text[i + 1..key_end - 1];
        i = key_end;
        skip_ws_and_comments(text, &mut i);
        if text.as_bytes().get(i) != Some(&b':') {
            return None;
        }
        i += 1;
        let val = consume_value(text, i).ok()?;
        if key == parts[0] {
            if parts.len() == 1 {
                return Some(val);
            }
            return span_at(text, val.start, &parts[1..]);
        }
        i = val.end;
    }
}

fn jsonc_insert(text: &str, pointer: &str, encoded: &str) -> Result<String, String> {
    let parts = pointer_parts(pointer)?;
    let Some((key, parent)) = parts.split_last() else {
        return Err("cannot insert at document root".into());
    };
    if parent.is_empty() {
        return insert_member(text, 0, key, encoded);
    }
    let parent_ptr = format!("/{}", parent.join("/"));
    let parent_span =
        jsonc_value_span(text, &parent_ptr).ok_or_else(|| format!("missing {parent_ptr}"))?;
    insert_member(text, parent_span.start, key, encoded)
}

fn insert_member(
    text: &str,
    object_from: usize,
    key: &str,
    encoded: &str,
) -> Result<String, String> {
    let mut i = object_from;
    skip_ws_and_comments(text, &mut i);
    if text.as_bytes().get(i) != Some(&b'{') {
        return Err("parent is not an object".into());
    }
    let end = consume_balanced(text, i, b'{', b'}')?;
    let close = end - 1;
    let inner = text[i + 1..close].trim();
    let quoted = json_quote_key(key);
    let snippet = if inner.is_empty() {
        format!("\n  {quoted}: {encoded}\n")
    } else {
        format!(",\n  {quoted}: {encoded}")
    };
    let insert_at = if inner.is_empty() {
        close
    } else {
        text[..close].trim_end().len()
    };
    let mut out = String::with_capacity(text.len() + snippet.len() + 1);
    out.push_str(&text[..insert_at]);
    out.push_str(&snippet);
    if !inner.is_empty() && !text[insert_at..close].contains('\n') {
        out.push('\n');
    }
    out.push_str(&text[insert_at..]);
    Ok(out)
}

fn json_quote_key(key: &str) -> String {
    format!("\"{}\"", key.replace('\\', "\\\\").replace('"', "\\\""))
}

fn skip_ws_and_comments(text: &str, i: &mut usize) {
    let bytes = text.as_bytes();
    loop {
        while *i < bytes.len() && bytes[*i].is_ascii_whitespace() {
            *i += 1;
        }
        if *i + 1 < bytes.len() && bytes[*i] == b'/' && bytes[*i + 1] == b'/' {
            *i += 2;
            while *i < bytes.len() && bytes[*i] != b'\n' {
                *i += 1;
            }
            continue;
        }
        if *i + 1 < bytes.len() && bytes[*i] == b'/' && bytes[*i + 1] == b'*' {
            *i += 2;
            while *i + 1 < bytes.len() && !(bytes[*i] == b'*' && bytes[*i + 1] == b'/') {
                *i += 1;
            }
            *i = (*i + 2).min(bytes.len());
            continue;
        }
        break;
    }
}

fn consume_string(text: &str, start: usize) -> Result<usize, String> {
    let bytes = text.as_bytes();
    if bytes.get(start) != Some(&b'"') {
        return Err("expected a string".into());
    }
    let mut i = start + 1;
    let mut escape = false;
    while i < bytes.len() {
        let c = bytes[i];
        if escape {
            escape = false;
            i += 1;
            continue;
        }
        if c == b'\\' {
            escape = true;
            i += 1;
            continue;
        }
        if c == b'"' {
            return Ok(i + 1);
        }
        i += 1;
    }
    Err("unterminated string".into())
}

fn consume_atom(text: &str, start: usize) -> usize {
    let bytes = text.as_bytes();
    let mut i = start;
    while i < bytes.len() {
        match bytes[i] {
            b',' | b'}' | b']' | b':' | b'/' => break,
            c if c.is_ascii_whitespace() => break,
            _ => i += 1,
        }
    }
    i
}

fn consume_balanced(text: &str, start: usize, open: u8, close: u8) -> Result<usize, String> {
    let bytes = text.as_bytes();
    if bytes.get(start) != Some(&open) {
        return Err("expected a container".into());
    }
    let mut i = start + 1;
    let mut depth = 1;
    while i < bytes.len() && depth > 0 {
        skip_ws_and_comments(text, &mut i);
        if i >= bytes.len() {
            break;
        }
        match bytes[i] {
            b'"' => i = consume_string(text, i)?,
            c if c == open => {
                depth += 1;
                i += 1;
            }
            c if c == close => {
                depth -= 1;
                i += 1;
            }
            _ => i += 1,
        }
    }
    if depth != 0 {
        return Err("unbalanced json".into());
    }
    Ok(i)
}

fn consume_value(text: &str, start: usize) -> Result<Range<usize>, String> {
    let mut i = start;
    skip_ws_and_comments(text, &mut i);
    let bytes = text.as_bytes();
    let value_start = i;
    let end = match bytes.get(i) {
        Some(b'{') => consume_balanced(text, i, b'{', b'}')?,
        Some(b'[') => consume_balanced(text, i, b'[', b']')?,
        Some(b'"') => consume_string(text, i)?,
        Some(_) => consume_atom(text, i),
        None => return Err("expected a value".into()),
    };
    Ok(value_start..end)
}

#[cfg(test)]
mod tests {
    use super::{
        Field, FieldKind, Loc, encode_field, insert_key, json_set, strip_jsonc, toml_get, toml_set,
        unquote,
    };
    use serde_json::json;

    #[test]
    fn toml_reads_a_sectioned_key_and_leaves_the_rest_alone() {
        let text = "[ui]\nyolo = true\n\n[models]\ndefault = \"grok-4.6\"\n# keep me\n";
        assert_eq!(
            toml_get(text, Some("models"), "default").as_deref(),
            Some("grok-4.6")
        );
        assert_eq!(toml_get(text, Some("ui"), "yolo").as_deref(), Some("true"));
        let next = toml_set(text, Some("models"), "default", "\"grok-4.5\"");
        assert!(next.contains("default = \"grok-4.5\""), "{next}");
        assert!(next.contains("yolo = true"), "{next}");
        assert!(next.contains("# keep me"), "{next}");
    }

    #[test]
    fn toml_inserts_a_missing_section() {
        let next = insert_key("", Some("session"), "auto_compact_threshold_percent = 80");
        assert!(next.contains("[session]"), "{next}");
        assert!(
            next.contains("auto_compact_threshold_percent = 80"),
            "{next}"
        );
    }

    #[test]
    fn jsonc_strips_comments_and_sets_a_nested_key() {
        let text = "{\n  // schema\n  \"$schema\": \"x\",\n  /* keep structure */\n  \"model\": \"a\"\n}\n";
        assert!(!strip_jsonc(text).contains("//"));
        let next = json_set(text, "/compaction/auto", &json!(true)).expect("set");
        assert!(next.contains("\"auto\": true"), "{next}");
        assert!(next.contains("\"$schema\""), "{next}");
        assert!(next.contains("// schema"), "{next}");
        assert!(next.contains("/* keep structure */"), "{next}");
        assert!(next.contains("\"model\": \"a\""), "{next}");
        let replaced = json_set(text, "/model", &json!("b")).expect("replace");
        assert!(replaced.contains("\"model\": \"b\""), "{replaced}");
        assert!(replaced.contains("// schema"), "{replaced}");
    }

    #[test]
    fn choice_rejects_an_unknown_value() {
        let field = Field {
            key: "effort",
            label: "Effort",
            kind: FieldKind::Choice,
            options: &["low", "high"],
            hint: None,
            loc: Loc::Toml {
                section: None,
                key: "effort",
            },
        };
        assert!(encode_field(&field, &json!("medium")).is_err());
        assert!(encode_field(&field, &json!("low")).is_ok());
    }

    #[test]
    fn set_refuses_an_unknown_key() {
        let mut values = serde_json::Map::new();
        values.insert("api_key".into(), json!("nope"));
        let err = super::set("grok", &values).expect_err("unknown key");
        assert!(err.contains("unknown setting"), "{err}");
    }

    #[test]
    fn unquote_round_trips_a_plain_string() {
        assert_eq!(unquote("\"grok-4.6\""), "grok-4.6");
        assert_eq!(unquote("80"), "80");
        assert_eq!(unquote("true"), "true");
    }
}
