// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Shared-host conversation records and the desktop's scoped state owners.
//! The complete transcript/composer presentation remains in progress.

pub mod actions;
pub mod directory;
pub mod fixtures;
pub mod flights;
pub mod history;
pub mod list_mutations;
pub mod menu;
pub mod paging;
pub mod polling;
pub mod projector;
pub mod query;
#[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
pub mod reader;
pub mod recent_messages;
pub mod send_context;
pub mod steer_overlay;
pub mod transcript;
#[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
pub mod transport;
pub mod wire;
/// Bridge.Patience.standard applies to both local and forwarded chat directories.
pub const DIRECTORY_TIMEOUT_SECS: u64 = 60;
/// RemoteHostFeature.chatFork; unsupported peers never receive chat.fork.
pub const FORK_MIN_PROTOCOL: i64 = 26;
/// A local host is current; remote failure/absence never grants fork support.
pub fn fork_supported(peer: Option<&str>, version: Option<i64>) -> bool {
    peer.is_none_or(str::is_empty) || version.is_some_and(|v| v >= FORK_MIN_PROTOCOL)
}
#[cfg(test)]
mod mutation_tests;
#[cfg(test)]
mod tests;

use serde::{Deserialize, Deserializer, Serialize};

/// The host's full ChatConversation. Setup/resume data remains private in memory;
/// it is never copied into the lightweight Home projection or a fixture manifest.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    pub id: String,
    #[serde(rename = "workspaceId")]
    pub workspace_id: String,
    pub title: String,
    pub backend: String,
    pub team_share: Option<Sharing>,
    #[serde(rename = "personaId")]
    pub persona_id: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    #[serde(default, deserialize_with = "null_default")]
    pub fast_mode: bool,
    #[serde(default, deserialize_with = "null_default")]
    pub system_prompt: String,
    #[serde(default = "default_mode", deserialize_with = "mode")]
    pub mode: String,
    #[serde(default = "default_autonomy", deserialize_with = "autonomy")]
    pub autonomy: String,
    pub resume_token: Option<String>,
    #[serde(default, deserialize_with = "null_default")]
    pub allowed_tools: Vec<String>,
    #[serde(default, deserialize_with = "null_default")]
    pub allowed_shell_prefixes: Vec<String>,
    #[serde(default, deserialize_with = "wire::number::u64_default")]
    pub budget_seconds: u64,
    #[serde(default, deserialize_with = "wire::number::i64_default")]
    pub created_at_ms: i64,
    #[serde(default, deserialize_with = "wire::number::i64_default")]
    pub updated_at_ms: i64,
    #[serde(default, deserialize_with = "wire::number::i64_optional")]
    pub last_message_at_ms: Option<i64>,
    pub last_message_author: Option<String>,
    #[serde(default, deserialize_with = "wire::number::u64_optional")]
    pub send_revision: Option<u64>,
    #[serde(default, deserialize_with = "wire::number::u64_optional")]
    pub run_revision: Option<u64>,
    #[serde(default, deserialize_with = "wire::number::i64_optional")]
    pub run_started_at_ms: Option<i64>,
    #[serde(default, deserialize_with = "null_default")]
    pub running: bool,
    pub pending_steer: Option<String>,
    pub native_steer: Option<bool>,
    pub native_steer_attachments: Option<bool>,
    #[serde(default, deserialize_with = "wire::tolerant")]
    pub routing: Option<wire::RoutingState>,
    pub branch: Option<String>,
    #[serde(default, deserialize_with = "wire::tolerant")]
    pub pull: Option<Pull>,
}
fn default_mode() -> String {
    "plan".into()
}
fn default_autonomy() -> String {
    "standard".into()
}
fn mode<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(Option::<String>::deserialize(d)?.unwrap_or_else(default_mode))
}
fn autonomy<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(Option::<String>::deserialize(d)?.unwrap_or_else(default_autonomy))
}
impl Default for Conversation {
    fn default() -> Self {
        // Only inert local fixtures use Default; wire identity remains required.
        serde_json::from_value(
            serde_json::json!({"id":"","workspaceId":"","title":"","backend":""}),
        )
        .expect("inert conversation")
    }
}
/// A sharing marker disables private mutations, regardless of its label.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Sharing {
    pub id: String,
}
/// Pull decoration is optional: an unreadable shape cannot cost the chat row.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Pull {
    #[serde(deserialize_with = "wire::number::u32_required")]
    pub number: u32,
    pub title: String,
    pub url: String,
    pub state: String,
    pub draft: bool,
    pub base_ref: String,
}
impl Pull {
    /// Preserve the original BranchPull glyph priority.
    pub fn symbol(&self) -> &'static str {
        if self.draft && self.state == "open" {
            "pencil.line"
        } else {
            match self.state.as_str() {
                "merged" => "arrow.triangle.merge",
                "closed" => "xmark.circle",
                _ => "arrow.triangle.pull",
            }
        }
    }
}
fn null_default<'de, D, T>(decoder: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(decoder)?.unwrap_or_default())
}
impl Conversation {
    /// An unavailable draft owner cannot prove an untouched conversation.
    pub fn unused(&self, has_draft: Option<bool>) -> Option<bool> {
        if self.title != "New chat" || self.last_message_at_ms.is_some() || self.running {
            Some(false)
        } else {
            has_draft.map(|draft| !draft)
        }
    }
    /// Empty titles use the same accessible label as the visible title.
    pub fn label(&self) -> String {
        if self.title.is_empty() {
            crate::localization::text("apple.rootview.untitled_conversation.31d248c4", &[])
        } else {
            self.title.clone()
        }
    }
}

#[cfg(unix)]
impl crate::client::Client {
    /// Match the source control gate: local is current, remote probe failures
    /// mean unsupported. A captured account/helper still fences both branches.
    #[cfg(any(feature = "gui", test))]
    pub(crate) fn fork_supported_if_current(
        &self,
        folder: &str,
        current: impl Fn() -> bool,
    ) -> anyhow::Result<bool> {
        anyhow::ensure!(current(), "Chat copy was retired");
        let route = crate::work::destination::route(folder, None);
        let Some(peer) = route.peer.filter(|peer| !peer.is_empty()) else {
            return Ok(true);
        };
        let probe = (|| {
            self.prepare()?;
            anyhow::ensure!(current(), "Chat copy was retired");
            self.call_with_timeout(
                "remote.call",
                serde_json::json!({"peer":peer,"method":"protocol","params":{}}),
                std::time::Duration::from_secs(DIRECTORY_TIMEOUT_SECS),
            )
        })();
        anyhow::ensure!(current(), "Chat copy was retired");
        let version = probe.ok().and_then(|v| {
            v["protocolVersion"]
                .as_str()
                .and_then(|s| s.parse::<i64>().ok())
        });
        Ok(fork_supported(Some(&peer), version))
    }
    /// Called only after the source capability gate, with read invalidation
    /// owned by the GUI before dispatch and after either result branch.
    #[cfg(any(feature = "gui", test))]
    pub(crate) fn fork_conversation_if_current(
        &self,
        folder: &str,
        id: &str,
        current: impl Fn() -> bool,
    ) -> anyhow::Result<Conversation> {
        anyhow::ensure!(current(), "Chat copy was retired");
        self.prepare()?;
        anyhow::ensure!(current(), "Chat copy was retired");
        let route = crate::work::destination::route(folder, None);
        let params = serde_json::json!({"id":id});
        let timeout = std::time::Duration::from_secs(DIRECTORY_TIMEOUT_SECS);
        let result = match route.peer {
            Some(peer) => self.call_with_timeout(
                "remote.call",
                serde_json::json!({"peer":peer,"method":"chat.fork","params":params}),
                timeout,
            )?,
            None => self.call_with_timeout("chat.fork", params, timeout)?,
        };
        anyhow::ensure!(current(), "Chat copy was retired");
        Ok(serde_json::from_value(result)?)
    }
    /// Match Bridge.updateChat's rename subset. Caller owns before/after shared
    /// read invalidation; this worker fences protocol and dispatch by owner.
    #[cfg(any(feature = "gui", test))]
    pub(crate) fn rename_conversation_if_current(
        &self,
        folder: &str,
        id: &str,
        title: &str,
        current: impl Fn() -> bool,
    ) -> anyhow::Result<Conversation> {
        anyhow::ensure!(current(), "Chat rename was retired");
        self.prepare()?;
        anyhow::ensure!(current(), "Chat rename was retired");
        let route = crate::work::destination::route(folder, None);
        let params = serde_json::json!({"id":id,"title":title});
        let timeout = std::time::Duration::from_secs(DIRECTORY_TIMEOUT_SECS);
        let result = match route.peer {
            Some(peer) => self.call_with_timeout(
                "remote.call",
                serde_json::json!({"peer":peer,"method":"chat.update","params":params}),
                timeout,
            )?,
            None => self.call_with_timeout("chat.update", params, timeout)?,
        };
        anyhow::ensure!(current(), "Chat rename was retired");
        Ok(serde_json::from_value(result)?)
    }
    /// Use the owning host's directory, never a legacy transcript endpoint.
    pub fn conversations(&self, folder: &str) -> anyhow::Result<Vec<Conversation>> {
        self.conversations_if_current(folder, || true)
    }
    /// Account/helper retirement is checked again after startup/protocol IO,
    /// before dispatching a directory request captured for an earlier owner.
    pub(crate) fn conversations_if_current(
        &self,
        folder: &str,
        current: impl Fn() -> bool,
    ) -> anyhow::Result<Vec<Conversation>> {
        match self.chat_read_if_current(folder, &query::Query::directory(folder), current)? {
            query::Reply::Directory(rows) => Ok((*rows).clone()),
            _ => unreachable!("directory query returned another result type"),
        }
    }
}
