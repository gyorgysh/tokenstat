// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Image evidence from explicit image reads and structured tool results.
//! Never follow network URLs or interpret paths printed in prose as images.
use crate::transcript::Event;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

const INLINE_BYTES: usize = 8 * 1024 * 1024;
const IMAGE_COUNT: usize = 128;

pub(crate) enum Source {
    File(PathBuf),
    Bytes(Vec<u8>),
}

pub(crate) struct Image {
    pub call_id: String,
    pub source: Source,
}

#[derive(Default)]
pub(crate) struct Collector {
    reads: HashMap<String, PathBuf>,
    seen: HashSet<String>,
    captured_calls: HashSet<String>,
    pending: Vec<Image>,
    count: usize,
    pending_bytes: usize,
}

impl Collector {
    pub fn take(&mut self) -> Vec<Image> {
        self.pending_bytes = 0;
        std::mem::take(&mut self.pending)
    }

    pub fn observe(&mut self, backend: &str, value: &Value, events: &[Event]) {
        if self.count >= IMAGE_COUNT {
            return;
        }
        // Correlation is explicit: Claude tool_result names its tool_use_id.
        if backend == "claude" {
            if value["type"] == "assistant"
                && let Some(blocks) = value
                    .pointer("/message/content")
                    .or_else(|| value.get("content"))
                    .and_then(Value::as_array)
            {
                for block in blocks.iter().take(128) {
                    // Use the actual local tool name and arguments. Display
                    // verbs can be inferred from shell commands or MCP names.
                    if block["type"] == "tool_use"
                        && block["name"] == "Read"
                        && let Some(call) = block["id"].as_str()
                        && let Some(path) = block
                            .pointer("/input/file_path")
                            .or_else(|| block.pointer("/input/path"))
                            .and_then(Value::as_str)
                        && self.reads.len() < 128
                        && !call.is_empty()
                        && call.len() <= 512
                        && path.len() <= 8192
                        && image_extension(Path::new(path))
                    {
                        self.reads.insert(call.into(), path.into());
                    }
                }
            }
            if value["type"] == "user"
                && let Some(blocks) = value
                    .pointer("/message/content")
                    .or_else(|| value.get("content"))
                    .and_then(Value::as_array)
            {
                for block in blocks.iter().take(128) {
                    if block["type"] == "tool_result"
                        && let Some(call) = block["tool_use_id"]
                            .as_str()
                            .or_else(|| block["toolUseId"].as_str())
                    {
                        self.content(call, &block["content"], 0);
                    }
                }
            }
        } else if backend == "codex" && value["type"] == "item.completed" {
            let item = &value["item"];
            if let Some(call) = item["id"].as_str() {
                match item["type"].as_str() {
                    Some("image_view") if events.iter().any(|event| matches!(event, Event::ToolEnd { call_id, ok: true, .. } if call_id == call)) => {
                        if let Some(path) = item["path"].as_str() {
                            self.file(call, path);
                        }
                    }
                    Some("image_generation") if item["status"] == "completed" => {
                        if let Some(path) = item["savedPath"]
                            .as_str()
                            .or_else(|| item["saved_path"].as_str())
                        {
                            self.file(call, path);
                        } else if let Some(data) = item["result"].as_str() {
                            self.inline(call, data);
                        }
                    }
                    Some("mcp_tool_call" | "dynamic_tool_call") => {
                        self.content(call, &item["result"], 0);
                        self.content(call, &item["contentItems"], 0);
                    }
                    _ => {}
                }
            }
        } else {
            // Other adapters already normalize their correlated tool end.
            // Only one end may own the structured content in a record.
            let mut ends = events.iter().filter_map(|event| match event {
                Event::ToolEnd { call_id, .. } => Some(call_id.as_str()),
                _ => None,
            });
            if let Some(call) = ends.next()
                && ends.next().is_none()
            {
                for key in [
                    "result",
                    "output",
                    "response",
                    "content",
                    "payload",
                    "part",
                    "tool_call",
                ] {
                    self.content(call, &value[key], 0);
                }
            }
        }
        for event in events {
            if let Event::ToolEnd { call_id, ok, .. } = event
                && let Some(path) = self.reads.remove(call_id)
                && *ok
                && !self.captured_calls.contains(call_id)
            {
                self.file(call_id, &path.to_string_lossy());
            }
        }
    }

    fn file(&mut self, call: &str, path: &str) {
        if call.is_empty()
            || call.len() > 512
            || path.len() > 8192
            || !image_extension(Path::new(path))
            || self.count >= IMAGE_COUNT
        {
            return;
        }
        let key = format!("{call}:file:{path}");
        if self.seen.insert(key) {
            self.captured_calls.insert(call.into());
            self.count += 1;
            self.pending.push(Image {
                call_id: call.into(),
                source: Source::File(path.into()),
            });
        }
    }

    fn inline(&mut self, call: &str, data: &str) {
        if call.is_empty() || call.len() > 512 || self.count >= IMAGE_COUNT {
            return;
        }
        let encoded = if let Some((prefix, data)) = data.split_once(',') {
            if !prefix.starts_with("data:image/") || !prefix.ends_with(";base64") {
                return;
            }
            data
        } else {
            data
        };
        if encoded.len() > INLINE_BYTES.div_ceil(3) * 4 {
            return;
        }
        let Ok(bytes) = crate::base64::decode(encoded) else {
            return;
        };
        if bytes.len() > INLINE_BYTES
            || self.pending_bytes.saturating_add(bytes.len()) > 16 * 1024 * 1024
            || media_type(&bytes).is_none()
        {
            return;
        }
        use sha2::{Digest, Sha256};
        let hash = Sha256::digest(&bytes)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let key = format!("{call}:data:{hash}");
        if self.seen.insert(key) {
            self.captured_calls.insert(call.into());
            self.count += 1;
            self.pending_bytes += bytes.len();
            self.pending.push(Image {
                call_id: call.into(),
                source: Source::Bytes(bytes),
            });
        }
    }

    fn content(&mut self, call: &str, value: &Value, depth: usize) {
        if depth > 8 || self.count >= IMAGE_COUNT {
            return;
        }
        if let Some(parts) = value.as_array() {
            for part in parts.iter().take(128) {
                self.content(call, part, depth + 1);
            }
            return;
        }
        if !value.is_object() {
            return;
        }
        if matches!(
            value["type"].as_str(),
            Some("image" | "input_image" | "output_image" | "inputImage")
        ) {
            if let Some(data) = value["data"]
                .as_str()
                .or_else(|| value.pointer("/source/data").and_then(Value::as_str))
            {
                self.inline(call, data);
            } else if let Some(url) = value["image_url"]
                .as_str()
                .or_else(|| value["imageUrl"].as_str())
                .or_else(|| value["url"].as_str())
            {
                self.inline(call, url);
            }
        }
        // Embedded resource bytes are evidence. A remote MCP file:// URI
        // names its own host's filesystem, never this host's local files.
        if let Some(resource) = value.get("resource")
            && resource["mimeType"]
                .as_str()
                .is_some_and(|mime| mime.starts_with("image/"))
            && let Some(blob) = resource["blob"].as_str()
        {
            self.inline(call, blob);
        }
        for key in ["content", "result", "output", "response", "event", "state"] {
            if let Some(child) = value.get(key) {
                self.content(call, child, depth + 1);
            }
        }
    }
}

fn image_extension(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| {
            matches!(
                ext.to_ascii_lowercase().as_str(),
                "png"
                    | "jpg"
                    | "jpeg"
                    | "gif"
                    | "webp"
                    | "bmp"
                    | "tif"
                    | "tiff"
                    | "avif"
                    | "heic"
                    | "heif"
            )
        })
}

pub(crate) fn media_type(bytes: &[u8]) -> Option<(&'static str, &'static str)> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some(("image/png", "png"))
    } else if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Some(("image/jpeg", "jpg"))
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some(("image/gif", "gif"))
    } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        Some(("image/webp", "webp"))
    } else if bytes.starts_with(b"BM") {
        Some(("image/bmp", "bmp"))
    } else if bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*") {
        Some(("image/tiff", "tiff"))
    } else if bytes.get(4..8) == Some(b"ftyp") {
        match bytes.get(8..12) {
            Some(b"avif" | b"avis") => Some(("image/avif", "avif")),
            Some(b"heic" | b"heix" | b"hevc" | b"hevx") => Some(("image/heic", "heic")),
            Some(b"mif1" | b"msf1") => Some(("image/heif", "heif")),
            _ => None,
        }
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn only_correlated_image_content_is_captured_and_duplicates_are_bounded() {
        let data = crate::base64::encode(b"\x89PNG\r\n\x1a\nfixture");
        let mut collector = Collector::default();
        let result = json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"screen","content":[{"type":"text","text":"/private/secret.png"},{"type":"image","source":{"type":"base64","data":data}}]}]}});
        collector.observe("claude", &result, &[]);
        let images = collector.take();
        assert_eq!(images.len(), 1);
        assert_eq!(images[0].call_id, "screen");
        collector.observe("claude", &result, &[]);
        assert!(collector.take().is_empty());
        collector.observe(
            "claude",
            &json!({"type":"user","message":{"content":[{"type":"image","source":{"data":data}}]}}),
            &[],
        );
        assert!(
            collector.take().is_empty(),
            "ordinary user images have no tool provenance"
        );
    }
    #[test]
    fn reads_are_captured_only_after_success_and_remote_images_are_not_fetched() {
        let mut collector = Collector::default();
        for ok in [false, true] {
            let events = [
                Event::ToolStart {
                    call_id: format!("read-{ok}"),
                    verb: "Read".into(),
                    target: "plot.png".into(),
                    input: Value::Null,
                },
                Event::ToolEnd {
                    call_id: format!("read-{ok}"),
                    ok,
                    detail: None,
                },
            ];
            collector.observe("claude", &json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":format!("read-{ok}"),"name":"Read","input":{"file_path":"plot.png"}}]}}), &events);
        }
        assert_eq!(collector.take().len(), 1);
        collector.observe("codex", &json!({"type":"item.completed","item":{"type":"mcp_tool_call","id":"remote","result":{"content":[{"type":"image","url":"https://example.com/private.png"}]}}}), &[]);
        assert!(collector.take().is_empty());
    }

    #[test]
    fn refused_codex_image_reads_never_archive_the_requested_file() {
        let mut collector = Collector::default();
        let item = json!({"type":"item.completed","item":{"type":"image_view","id":"denied","path":"/private/image.png","status":"failed"}});
        collector.observe(
            "codex",
            &item,
            &[Event::ToolEnd {
                call_id: "denied".into(),
                ok: false,
                detail: None,
            }],
        );
        assert!(collector.take().is_empty());
        collector.observe(
            "codex",
            &item,
            &[Event::ToolEnd {
                call_id: "denied".into(),
                ok: true,
                detail: None,
            }],
        );
        assert_eq!(
            collector.take().len(),
            1,
            "only the explicit successful read may archive the path"
        );
    }

    #[test]
    fn mcp_resource_uris_cannot_read_the_hosts_unrelated_local_files() {
        let mut collector = Collector::default();
        let item = json!({"type":"item.completed","item":{"type":"mcp_tool_call","id":"remote-resource","result":{"content":[{"type":"resource","resource":{"uri":"file:///private/image.png","mimeType":"image/png"}}]}}});
        collector.observe("codex", &item, &[]);
        assert!(collector.take().is_empty());
    }

    #[test]
    fn pending_reads_cannot_keep_oversized_agent_paths_or_identifiers() {
        let mut collector = Collector::default();
        collector.observe(
            "claude",
            &json!({"type":"assistant","message":{"content":[
                {"type":"tool_use","id":"read","name":"Read","input":{"file_path":format!("{}.png", "a".repeat(8192))}},
                {"type":"tool_use","id":"x".repeat(513),"name":"Read","input":{"file_path":"plot.png"}}
            ]}}),
            &[
                Event::ToolStart {
                    call_id: "read".into(),
                    verb: "Read".into(),
                    target: format!("{}.png", "a".repeat(8192)),
                    input: Value::Null,
                },
                Event::ToolStart {
                    call_id: "x".repeat(513),
                    verb: "Read".into(),
                    target: "plot.png".into(),
                    input: Value::Null,
                },
            ],
        );
        assert!(collector.reads.is_empty());
    }

    #[test]
    fn shell_display_hints_never_authorize_local_image_reads() {
        let mut parser = crate::transcript::Parser::new("codex");
        let command = "echo 'cat private.png'";
        let stream = format!(
            "{}\n{}\n",
            json!({"type":"item.started","item":{"id":"shell","type":"command_execution","command":command}}),
            json!({"type":"item.completed","item":{"id":"shell","type":"command_execution","command":command,"exit_code":0,"aggregated_output":"cat private.png"}})
        );
        parser.push_events(stream.as_bytes());
        assert!(
            parser.take_images().is_empty(),
            "a shell command mentioning an image is not an image read"
        );
    }
}
