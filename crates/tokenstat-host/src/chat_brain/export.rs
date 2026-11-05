// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde_json::Value;
use std::io::{self, Seek, SeekFrom, Write};

const TEXT_CAP: usize = 4_000;
const DETAIL_CAP: usize = 2_000;

fn cap_chars(text: &str, cap: usize) -> String {
    match text.char_indices().nth(cap) {
        Some((end, _)) => format!("{}…\n[{cap} chars shown]", &text[..end]),
        None => text.to_string(),
    }
}

/// Stream the chronological export. Seeking back over trailing whitespace
/// preserves the old reply trimming without buffering an entire answer.
/// The caller truncates the destination to the length returned by `finish`.
pub(crate) struct HistoryWriter<W> {
    output: W,
    position: u64,
    last_content: u64,
    reply_open: bool,
    backend: String,
}

impl<W: Write + Seek> HistoryWriter<W> {
    pub(crate) fn new(mut output: W, folder: &str) -> io::Result<Self> {
        output.seek(SeekFrom::Start(0))?;
        let mut writer = Self {
            output,
            position: 0,
            last_content: 0,
            reply_open: false,
            backend: String::new(),
        };
        writer.write("# Conversation history\n")?;
        if !folder.is_empty() {
            writer.write(&format!("\nFolder: {folder}\n"))?;
        }
        Ok(writer)
    }

    fn write(&mut self, text: &str) -> io::Result<()> {
        self.output.write_all(text.as_bytes())?;
        self.position = self
            .position
            .checked_add(text.len() as u64)
            .ok_or_else(|| io::Error::other("history export is too large"))?;
        Ok(())
    }

    fn write_delta(&mut self, delta: &str) -> io::Result<()> {
        let text = if self.reply_open {
            delta
        } else {
            delta.trim_start()
        };
        if text.is_empty() {
            return Ok(());
        }
        if !self.reply_open {
            let label = if self.backend.is_empty() {
                String::new()
            } else {
                format!(" ({})", self.backend)
            };
            self.write(&format!("\n## Agent{label}\n"))?;
            self.reply_open = true;
        }
        let start = self.position;
        self.write(text)?;
        let content = text.trim_end().len();
        if content > 0 {
            self.last_content = start + content as u64;
        }
        Ok(())
    }

    fn flush_reply(&mut self) -> io::Result<()> {
        if !self.reply_open {
            return Ok(());
        }
        if self.position != self.last_content {
            self.output.seek(SeekFrom::Start(self.last_content))?;
            self.position = self.last_content;
        }
        self.write("\n")?;
        self.reply_open = false;
        Ok(())
    }

    pub(crate) fn push(&mut self, event: &Value) -> io::Result<()> {
        match event.get("kind").and_then(Value::as_str) {
            Some("user") => {
                self.flush_reply()?;
                self.backend.clear();
                if let Some(text) = event.get("text").and_then(Value::as_str) {
                    self.write("\n## Person\n")?;
                    self.write(&cap_chars(text.trim(), TEXT_CAP))?;
                    self.write("\n")?;
                }
            }
            Some("agent") => {
                let agent = event.get("event").unwrap_or(&Value::Null);
                match agent.get("kind").and_then(Value::as_str) {
                    Some("text") | Some("thinking") => {
                        if let Some(active) = event.get("backend").and_then(Value::as_str) {
                            if self.reply_open && self.backend != active {
                                self.flush_reply()?;
                            }
                            self.backend = active.to_string();
                        }
                        if let Some(delta) = agent.get("delta").and_then(Value::as_str) {
                            self.write_delta(delta)?;
                        }
                    }
                    _ => {
                        self.flush_reply()?;
                        self.backend.clear();
                        match agent.get("kind").and_then(Value::as_str) {
                            Some("toolStart") => {
                                let verb =
                                    agent.get("verb").and_then(Value::as_str).unwrap_or("tool");
                                let target =
                                    agent.get("target").and_then(Value::as_str).unwrap_or("");
                                self.write(&format!("\n- {verb} {}\n", target.trim()))?;
                            }
                            Some("toolEnd") => {
                                let ok = agent.get("ok").and_then(Value::as_bool).unwrap_or(true);
                                let detail =
                                    agent.get("detail").and_then(Value::as_str).unwrap_or("");
                                let mark = if ok { "" } else { " (failed)" };
                                if detail.trim().is_empty() {
                                    self.write(&format!("\n- tool finished{mark}\n"))?;
                                } else {
                                    self.write(&format!(
                                        "\n- tool finished{mark}: {}\n",
                                        cap_chars(detail.trim(), DETAIL_CAP)
                                    ))?;
                                }
                            }
                            Some("edit") => {
                                let path = agent.get("path").and_then(Value::as_str).unwrap_or("");
                                let added = agent.get("added").and_then(Value::as_u64).unwrap_or(0);
                                let removed =
                                    agent.get("removed").and_then(Value::as_u64).unwrap_or(0);
                                self.write(&format!("\n- Edit {path} +{added} −{removed}\n"))?;
                            }
                            Some("attachment") => {
                                let name =
                                    agent.get("name").and_then(Value::as_str).unwrap_or("file");
                                self.write(&format!("\n- attached {name}\n"))?;
                            }
                            Some("failed") => {
                                let text = agent.get("text").and_then(Value::as_str).unwrap_or("");
                                self.write(&format!(
                                    "\n- failed: {}\n",
                                    cap_chars(text.trim(), DETAIL_CAP)
                                ))?;
                            }
                            Some("done") => {
                                let status =
                                    agent.get("status").and_then(Value::as_str).unwrap_or("");
                                if !matches!(status, "ok" | "") {
                                    self.write(&format!("\n- turn ended: {status}\n"))?;
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
            Some("approval") => {
                self.flush_reply()?;
                self.backend.clear();
                let approval = event.get("approval").unwrap_or(&Value::Null);
                let decision = approval
                    .get("decision")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let preview = approval
                    .get("preview")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                self.write(&format!(
                    "\n- Approval {decision}: {}\n",
                    cap_chars(preview.trim(), 500)
                ))?;
            }
            Some("handoff") => {
                self.flush_reply()?;
                self.backend.clear();
                if let Some(to) = event.get("to").and_then(Value::as_str) {
                    self.write(&format!("\n- Handed to {to}\n"))?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    pub(crate) fn finish(mut self) -> io::Result<(W, u64)> {
        self.flush_reply()?;
        self.output.flush()?;
        Ok((self.output, self.position))
    }
}
