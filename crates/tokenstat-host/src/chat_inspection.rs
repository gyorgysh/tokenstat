// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Allowlisted, bounded chat metadata. Never copy server commands, URLs,
//! environment, credentials, tool arguments or schema bodies to the inspector.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

const ITEMS: usize = 256;
const SERVERS: usize = 64;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct Snapshot {
    pub model: Option<String>,
    pub context_used: Option<u64>,
    pub context_window: Option<u64>,
    pub context_source: Option<String>,
    pub tools: Option<Vec<String>>,
    pub used_tools: Vec<String>,
    pub mcp_servers: Vec<Server>,
    pub mcp_reported: bool,
    pub inventory_partial: bool,
}

pub(crate) struct Launch {
    pub backend: String,
    pub requested_model: Option<String>,
    pub revision: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Server {
    pub name: String,
    pub status: String,
    pub source: String,
    pub tools: Option<Vec<String>>,
}

fn name(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty() || value.chars().any(char::is_control) {
        return None;
    }
    let mut end = value.len().min(160);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    Some(value[..end].to_owned())
}

fn names(value: &Value) -> Option<Vec<String>> {
    let mut names: Vec<_> = if let Some(items) = value.as_array() {
        items
            .iter()
            .filter_map(|item| item.as_str().or_else(|| item["name"].as_str()))
            .filter_map(name)
            .take(ITEMS)
            .collect()
    } else if let Some(items) = value.as_object() {
        items
            .keys()
            .filter_map(|key| name(key))
            .take(ITEMS)
            .collect()
    } else {
        return None;
    };
    names.sort();
    names.dedup();
    Some(names)
}

fn oversized(value: &Value, limit: usize) -> bool {
    value
        .as_array()
        .map(Vec::len)
        .or_else(|| value.as_object().map(serde_json::Map::len))
        .is_some_and(|count| count > limit)
}

fn count(value: &Value, keys: &[&str]) -> Option<u64> {
    keys.iter().find_map(|key| value[*key].as_u64())
}

fn prompt_tokens(usage: &Value, cache_is_separate: bool) -> Option<u64> {
    let input = count(usage, &["input_tokens", "inputTokens", "input"])?;
    if !cache_is_separate {
        return Some(input);
    }
    input
        .checked_add(
            count(usage, &["cache_read_input_tokens", "cacheReadTokens"])
                .or_else(|| usage.pointer("/cache/read").and_then(Value::as_u64))
                .unwrap_or(0),
        )?
        .checked_add(
            count(usage, &["cache_creation_input_tokens", "cacheWriteTokens"])
                .or_else(|| usage.pointer("/cache/write").and_then(Value::as_u64))
                .unwrap_or(0),
        )
}

impl Snapshot {
    /// Called only on complete protocol records, never on text/tool payloads.
    pub fn observe(&mut self, backend: &str, value: &Value) -> bool {
        let kind = value["type"].as_str().unwrap_or("");
        let init = kind == "system" && value["subtype"] == "init";
        let muse_model = backend == "muse"
            && value["payload_type"] == "runtime.session"
            && value
                .pointer("/payload/event/kind")
                .is_some_and(|v| v == "model_completed");
        let agy_init = backend == "agy" && value["event"] == "init";
        let relevant = init
            || muse_model
            || agy_init
            || matches!(kind, "tokenstat.context" | "tokenstat.mcp")
            || matches!(
                (backend, kind),
                ("claude" | "cursor", "assistant")
                    | ("grok", "usage")
                    | ("claude", "result")
                    | ("opencode" | "opencode2", "step_finish")
            );
        if !relevant {
            return false;
        }
        let previous = self.clone();
        if init {
            self.model = value["model"].as_str().and_then(name);
            self.tools = names(&value["tools"]);
            self.inventory_partial |= oversized(&value["tools"], ITEMS)
                || oversized(&value["mcp_servers"], SERVERS)
                || value["mcp_servers"].as_array().is_some_and(|servers| {
                    servers
                        .iter()
                        .take(SERVERS)
                        .any(|s| oversized(&s["tools"], ITEMS))
                });
            if let Some(servers) = value["mcp_servers"].as_array() {
                self.mcp_reported = true;
                self.mcp_servers = servers
                    .iter()
                    .take(SERVERS)
                    .filter_map(|server| {
                        Some(Server {
                            name: name(server["name"].as_str()?)?,
                            status: status(server["status"].as_str()),
                            source: "agent".into(),
                            tools: names(&server["tools"]),
                        })
                    })
                    .collect();
            }
        }
        if muse_model {
            if let Some(event) = value.pointer("/payload/event") {
                self.model = event["model"]
                    .as_str()
                    .and_then(name)
                    .or_else(|| self.model.clone());
                // Muse includes cache reads and writes in input_tokens.
                if let Some(used) = prompt_tokens(&event["usage"], false) {
                    self.context_used = Some(used);
                    self.context_source = Some("lastInput".into());
                }
            }
        }
        if agy_init {
            self.model = value
                .pointer("/init/model")
                .and_then(Value::as_str)
                .and_then(name);
        }
        if kind == "tokenstat.context" {
            if let Some(model) = value["model"].as_str().and_then(name) {
                self.model = Some(model);
            }
            if let Some(used) = value["contextUsed"].as_u64() {
                self.context_used = Some(used);
                self.context_source = Some("agent".into());
            }
            if let Some(window) = value["contextWindow"].as_u64().filter(|n| *n > 0) {
                self.context_window = Some(window);
            }
        }
        if kind == "tokenstat.mcp" {
            if let Some(servers) = value["servers"].as_array() {
                self.mcp_reported = true;
                self.inventory_partial |=
                    value["inventoryPartial"] == true || servers.len() > SERVERS;
                for server in servers.iter().take(SERVERS) {
                    self.inventory_partial |= oversized(&server["tools"], ITEMS);
                    let Some(server_name) = server["name"].as_str().and_then(name) else {
                        continue;
                    };
                    let entry = Server {
                        name: server_name.clone(),
                        status: status(server["runtimeStatus"].as_str()),
                        source: "agent".into(),
                        tools: names(&server["tools"]),
                    };
                    if let Some(old) = self.mcp_servers.iter_mut().find(|s| s.name == server_name) {
                        let tools = entry.tools.or_else(|| old.tools.clone());
                        *old = Server { tools, ..entry };
                    } else if self.mcp_servers.len() < SERVERS {
                        self.mcp_servers.push(entry);
                    } else {
                        self.inventory_partial = true;
                    }
                }
            }
        }
        // Claude result usage is a whole-turn total. Its last assistant
        // message is the prompt footprint; never use the result total here.
        let usage = match (backend, kind) {
            ("claude", "assistant") | ("cursor", "assistant") => value.pointer("/message/usage"),
            ("grok", "usage") => Some(value.get("usage").unwrap_or(value)),
            ("opencode" | "opencode2", "step_finish") => value.pointer("/part/tokens"),
            _ => None,
        };
        if let Some(usage) = usage {
            if let Some(used) = prompt_tokens(
                usage,
                matches!(backend, "claude" | "opencode" | "opencode2"),
            ) {
                self.context_used = Some(used);
                self.context_source = Some("lastInput".into());
            }
        }
        if backend == "claude" && kind == "result" {
            if let Some(models) = value["modelUsage"].as_object() {
                // Mixed-model turns do not have a single unambiguous window.
                let selected = self
                    .model
                    .as_ref()
                    .and_then(|model| models.get(model))
                    .or_else(|| {
                        (models.len() == 1)
                            .then(|| models.values().next())
                            .flatten()
                    });
                if let Some(window) = selected
                    .and_then(|v| v["contextWindow"].as_u64())
                    .filter(|n| *n > 0)
                {
                    self.context_window = Some(window);
                }
            }
        }
        *self != previous
    }

    pub fn used_tool(&mut self, tool: &str) -> bool {
        let Some(tool) = name(tool) else {
            return false;
        };
        if self.used_tools.contains(&tool) {
            return false;
        }
        if self.used_tools.len() >= ITEMS {
            return !std::mem::replace(&mut self.inventory_partial, true);
        }
        self.used_tools.push(tool);
        true
    }
}

fn status(value: Option<&str>) -> String {
    match value {
        Some(
            "connected"
            | "starting"
            | "failed"
            | "disabled"
            | "cancelled"
            | "notStarted"
            | "authenticationRequired",
        ) => value.unwrap(),
        Some("needs-auth") => "authenticationRequired",
        // A discovered tool catalog does not prove a server is still connected.
        _ => "unknown",
    }
    .into()
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Stored {
    pub backend: String,
    pub requested_model: Option<String>,
    pub run_revision: u64,
    pub observed_at_ms: i64,
    pub snapshot: Snapshot,
}

/// The same capped, nonblocking regular-file reader is used for external
/// configuration and our small sidecar. A project FIFO must never park a host.
fn read(path: &Path) -> Option<String> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = options.open(path).ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() > 8 * 1024 * 1024 {
        return None;
    }
    let mut text = String::new();
    file.take(8 * 1024 * 1024 + 1)
        .read_to_string(&mut text)
        .ok()?;
    (text.len() <= 8 * 1024 * 1024).then_some(text)
}

pub(crate) fn load(path: &Path) -> Option<Stored> {
    serde_json::from_str(&read(path)?).ok()
}

pub(crate) fn configured(
    backend: &str,
    home: &Path,
    cwd: &Path,
    codex_home: Option<PathBuf>,
    config_home: Option<PathBuf>,
) -> (Vec<Server>, bool) {
    let config = config_home
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home.join(".config"));
    let paths = match backend {
        "claude" => vec![home.join(".claude.json"), cwd.join(".mcp.json")],
        "codex" => vec![
            codex_home
                .filter(|p| p.is_absolute())
                .unwrap_or_else(|| home.join(".codex"))
                .join("config.toml"),
            cwd.join(".codex/config.toml"),
        ],
        "cursor" => vec![home.join(".cursor/mcp.json"), cwd.join(".cursor/mcp.json")],
        "grok" => vec![
            home.join(".grok/config.toml"),
            cwd.join(".grok/config.toml"),
        ],
        "muse" => vec![config.join("muse/mcp.json")],
        "opencode" | "opencode2" => vec![
            config.join("opencode/opencode.json"),
            config.join("opencode/opencode.jsonc"),
            cwd.join("opencode.json"),
            cwd.join("opencode.jsonc"),
        ],
        "agy" => vec![
            home.join(".gemini/config/mcp_config.json"),
            cwd.join(".agents/mcp_config.json"),
        ],
        _ => vec![],
    };
    let mut servers = BTreeMap::new();
    let mut partial = false;
    for path in paths {
        let Some(text) = read(&path) else {
            continue;
        };
        if path.extension().is_some_and(|ext| ext == "toml") {
            let Ok(document) = text.parse::<toml_edit::DocumentMut>() else {
                continue;
            };
            if let Some(table) = document
                .get("mcp_servers")
                .and_then(toml_edit::Item::as_table_like)
            {
                partial |= table.len() > ITEMS;
                for (key, entry) in table.iter().take(ITEMS) {
                    let Some(key) = name(key) else {
                        continue;
                    };
                    let disabled =
                        entry.get("enabled").and_then(toml_edit::Item::as_bool) == Some(false);
                    servers.insert(
                        key.clone(),
                        Server {
                            name: key,
                            status: if disabled { "disabled" } else { "configured" }.into(),
                            source: "configuration".into(),
                            tools: None,
                        },
                    );
                }
            }
        } else {
            let Ok(value) =
                serde_json::from_str::<Value>(&crate::harness_config::strip_trailing_commas(
                    &crate::harness_config::strip_jsonc(&text),
                ))
            else {
                continue;
            };
            partial |= add_config(
                &mut servers,
                value.get("mcpServers").or_else(|| value.get("mcp")),
            );
            if backend == "claude" {
                partial |= add_config(
                    &mut servers,
                    value
                        .get("projects")
                        .and_then(|projects| projects.get(cwd.to_string_lossy().as_ref()))
                        .and_then(|project| project.get("mcpServers")),
                );
            }
        }
    }
    partial |= servers.len() > ITEMS;
    (servers.into_values().take(ITEMS).collect(), partial)
}

fn add_config(servers: &mut BTreeMap<String, Server>, value: Option<&Value>) -> bool {
    let Some(entries) = value.and_then(Value::as_object) else {
        return false;
    };
    for (key, entry) in entries.iter().take(ITEMS) {
        let Some(key) = name(key) else {
            continue;
        };
        let disabled = entry == false || entry["enabled"] == false || entry["disabled"] == true;
        servers.insert(
            key.clone(),
            Server {
                name: key,
                status: if disabled { "disabled" } else { "configured" }.into(),
                source: "configuration".into(),
                tools: None,
            },
        );
    }
    entries.len() > ITEMS
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn claude_context_is_last_prompt_with_cache_not_whole_turn() {
        let mut s = Snapshot::default();
        s.observe("claude", &json!({"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":3}}}));
        s.observe("claude", &json!({"type":"result","usage":{"input_tokens":9000},"modelUsage":{"model":{"contextWindow":200000}}}));
        assert_eq!(s.context_used, Some(33));
        assert_eq!(s.context_window, Some(200000));
        s.observe(
            "claude",
            &json!({"type":"assistant","message":{"usage":{"input_tokens":2}}}),
        );
        assert_eq!(
            s.context_used,
            Some(2),
            "compaction may reduce the footprint"
        );
    }

    #[test]
    fn runtime_inventory_is_allowlisted_and_bounded() {
        let mut s = Snapshot::default();
        s.observe("claude", &json!({"type":"system","subtype":"init","tools":["Read","mcp__godot__scene"],"mcp_servers":[{"name":"godot-mcp","status":"connected","command":"secret","env":{"TOKEN":"secret"}}]}));
        s.observe("codex", &json!({"type":"tokenstat.mcp","servers":[{"name":"tokenstat-mcp","runtimeStatus":"connected","tools":{"usage":{"inputSchema":{"secret":"secret"}}},"url":"secret"}]}));
        assert_eq!(s.mcp_servers.len(), 2);
        assert_eq!(s.mcp_servers[1].tools, Some(vec!["usage".into()]));
        assert!(!serde_json::to_string(&s).unwrap().contains("secret"));
        let many: Vec<_> = (0..1000).map(|i| format!("tool{i}")).collect();
        s.observe(
            "cursor",
            &json!({"type":"system","subtype":"init","tools":many}),
        );
        assert_eq!(s.tools.as_ref().unwrap().len(), ITEMS);
        assert!(
            s.inventory_partial,
            "truncated tools must be labeled partial"
        );
    }

    #[test]
    fn capped_inventory_stays_explicitly_partial() {
        let mut s = Snapshot::default();
        let servers: Vec<_> = (0..SERVERS + 1)
            .map(|i| json!({"name":format!("server-{i}"),"runtimeStatus":"connected"}))
            .collect();
        s.observe("codex", &json!({"type":"tokenstat.mcp","servers":servers}));
        assert_eq!(s.mcp_servers.len(), SERVERS);
        assert!(s.inventory_partial);
        let mut s = Snapshot::default();
        s.observe(
            "codex",
            &json!({"type":"tokenstat.mcp","servers":[],"inventoryPartial":true}),
        );
        assert!(
            s.inventory_partial,
            "upstream pagination limits survive normalization"
        );
        let root = tempfile::tempdir().unwrap();
        let entries: serde_json::Map<_, _> = (0..ITEMS + 1)
            .map(|i| (format!("server-{i}"), json!({})))
            .collect();
        std::fs::write(
            root.path().join(".mcp.json"),
            json!({"mcpServers":entries}).to_string(),
        )
        .unwrap();
        let (servers, partial) =
            configured("claude", &root.path().join("home"), root.path(), None, None);
        assert_eq!(servers.len(), ITEMS);
        assert!(partial);
    }

    #[test]
    fn adapters_never_treat_arbitrary_tool_output_as_metadata() {
        for backend in [
            "claude",
            "codex",
            "cursor",
            "grok",
            "muse",
            "opencode",
            "opencode2",
            "agy",
            "sh",
        ] {
            let mut s = Snapshot::default();
            assert!(!s.observe(backend, &json!({"type":"tool_result","model":"fake","contextUsed":999,"tools":["fake"],"mcp_servers":[{"name":"fake","status":"connected"}]})));
            assert_eq!(s.context_used, None);
        }
    }

    #[test]
    fn configs_are_backend_scoped_and_never_claim_a_connection() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        let cwd = root.path().join("project");
        std::fs::create_dir_all(&cwd).unwrap();
        for (backend, path, content) in [
            (
                "claude",
                ".mcp.json",
                r#"{"mcpServers":{"godot-mcp":{"command":"secret"}}}"#,
            ),
            (
                "codex",
                ".codex/config.toml",
                "[mcp_servers.codex-only]\nenabled = false\ncommand = 'secret'",
            ),
            (
                "cursor",
                ".cursor/mcp.json",
                r#"{"mcpServers":{"cursor-only":{}}}"#,
            ),
            (
                "grok",
                ".grok/config.toml",
                "[mcp_servers.grok-only]\ncommand = 'secret'",
            ),
            (
                "opencode",
                "opencode.jsonc",
                "{/*comment*/\"mcp\":{\"oc-only\":{\"enabled\":true,},},}",
            ),
            (
                "agy",
                ".agents/mcp_config.json",
                r#"{"mcpServers":{"agy-only":{}}}"#,
            ),
        ] {
            let path = cwd.join(path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, content).unwrap();
            let (servers, partial) = configured(backend, &home, &cwd, None, None);
            assert!(!partial);
            assert_eq!(servers.len(), 1, "{backend}");
            assert_ne!(servers[0].status, "connected");
            assert!(!serde_json::to_string(&servers).unwrap().contains("secret"));
        }
        let muse = home.join(".config/muse");
        std::fs::create_dir_all(&muse).unwrap();
        std::fs::write(muse.join("mcp.json"), r#"{"mcpServers":{"muse-only":{}}}"#).unwrap();
        assert_eq!(
            configured("muse", &home, &cwd, None, None).0[0].name,
            "muse-only"
        );
        assert!(configured("sh", &home, &cwd, None, None).0.is_empty());
        assert_eq!(configured("opencode2", &home, &cwd, None, None).0.len(), 1);
    }

    #[test]
    fn configured_servers_respect_custom_launch_roots() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        let config = root.path().join("custom-xdg");
        let codex = root.path().join("custom-codex");
        let cwd = root.path().join("project");
        std::fs::create_dir_all(config.join("muse")).unwrap();
        std::fs::create_dir_all(&codex).unwrap();
        std::fs::create_dir_all(&cwd).unwrap();
        std::fs::write(
            config.join("muse/mcp.json"),
            r#"{"mcpServers":{"custom-muse":{}}}"#,
        )
        .unwrap();
        std::fs::write(
            codex.join("config.toml"),
            "[mcp_servers.custom-codex]\ncommand = 'private'",
        )
        .unwrap();
        assert_eq!(
            configured("muse", &home, &cwd, None, Some(config)).0[0].name,
            "custom-muse"
        );
        assert_eq!(
            configured("codex", &home, &cwd, Some(codex), None).0[0].name,
            "custom-codex"
        );
    }

    #[test]
    fn muse_opencode_and_grok_preserve_the_latest_prompt_footprint() {
        let mut muse = Snapshot::default();
        muse.observe("muse", &json!({"payload_type":"runtime.session","payload":{"event":{"kind":"model_completed","model":"muse-spark-1.2","usage":{"input_tokens":100,"cache_read_tokens":80}}}}));
        assert_eq!(muse.context_used, Some(100), "cache already included");
        muse.observe("muse", &json!({"payload_type":"subagent.control.runtime_observed","payload":{"record":{"usage":{"input_tokens":9000}}}}));
        assert_eq!(
            muse.context_used,
            Some(100),
            "child usage is not the parent context"
        );
        for backend in ["opencode", "opencode2"] {
            let mut oc = Snapshot::default();
            oc.observe(backend, &json!({"type":"step_finish","part":{"tokens":{"input":10,"cache":{"read":20,"write":3}}}}));
            assert_eq!(oc.context_used, Some(33), "{backend}");
        }
        let mut grok = Snapshot::default();
        grok.observe(
            "grok",
            &json!({"type":"usage","input_tokens":44,"cache_read_input_tokens":30}),
        );
        assert_eq!(grok.context_used, Some(44));
    }

    #[test]
    fn complete_record_parser_captures_metadata_without_timeline_noise() {
        let mut parser = crate::transcript::Parser::new("claude");
        let record = b"{\"type\":\"system\",\"subtype\":\"init\",\"tools\":[\"Read\"],\"mcp_servers\":[{\"name\":\"godot-mcp\",\"status\":\"connected\"}]}\n";
        assert!(parser.push_events(&record[..20]).is_empty());
        assert!(parser.take_inspection().is_none());
        assert!(parser.push_events(&record[20..]).is_empty());
        let snapshot = parser.take_inspection().unwrap();
        assert_eq!(snapshot.tools, Some(vec!["Read".into()]));
        assert_eq!(snapshot.mcp_servers[0].name, "godot-mcp");
        assert!(
            parser.take_inspection().is_none(),
            "unchanged polls do no disk work"
        );
    }

    #[test]
    fn codex_latest_context_is_not_cumulative_usage() {
        let mut s = Snapshot::default();
        s.observe(
            "codex",
            &json!({"type":"turn.completed","usage":{"input_tokens":100000}}),
        );
        assert_eq!(s.context_used, None);
        s.observe(
            "codex",
            &json!({"type":"tokenstat.context","contextUsed":2100,"contextWindow":1000000}),
        );
        assert_eq!(s.context_used, Some(2100));
        assert_eq!(s.context_window, Some(1000000));
    }
}
