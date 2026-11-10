// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Source project edit decisions are separate from a captured view or worker.

use crate::{
    localization,
    work::{destination, text},
};
use serde::Serialize;
mod directory;
pub use directory::Directory;

#[derive(Clone, Debug, Default)]
/// SidebarRenameSheet keeps a failed save visible, including during a retry.
pub struct Rename {
    pub saving: bool,
    pub error: Option<String>,
}
impl Rename {
    pub fn can_save(&self, name: &str) -> bool {
        !self.saving && !text::trim(name).is_empty()
    }
    pub fn height(&self) -> f32 {
        if self.error.is_some() { 300. } else { 250. }
    }
    pub fn begin(&mut self, name: &str) -> Option<String> {
        if !self.can_save(name) {
            return None;
        }
        self.saving = true;
        Some(text::trim(name).to_owned())
    }
    /// Success dismisses even if the callback retired its scope-owned effects.
    pub fn finish(&mut self, result: Result<(), String>) -> bool {
        match result {
            Ok(()) => true,
            Err(error) => {
                self.saving = false;
                self.error = Some(error);
                false
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
/// Malformed remote removal drops its local registration without a bad RPC.
pub enum RemovalRoute {
    Local { id: String },
    Remote { peer: String, id: String },
    ForgetRemote { peer: String },
}
pub fn removal_route(id: &str, peer: Option<&str>) -> RemovalRoute {
    let Some(peer) = peer else {
        return RemovalRoute::Local { id: id.into() };
    };
    let prefix = format!("remote:{peer}:");
    let raw = if let Some(raw) = id.strip_prefix(&prefix) {
        raw
    } else {
        let parts = destination::components(id);
        if parts.len() == 3 { parts[2] } else { id }
    };
    if raw == id {
        RemovalRoute::ForgetRemote { peer: peer.into() }
    } else {
        RemovalRoute::Remote {
            peer: peer.into(),
            id: raw.into(),
        }
    }
}
/// Rename uses the ID's routing prefix, independently of the row's machine ID.
pub fn rename_route(id: &str) -> RemovalRoute {
    let route = destination::route(id, None);
    match route.peer {
        Some(peer) => RemovalRoute::Remote {
            peer,
            id: route.workspace_id,
        },
        None => RemovalRoute::Local { id: id.into() },
    }
}

#[derive(Clone, Debug)]
/// The editor owner supplies these facts; removal never discards a dirty buffer.
pub struct Document {
    pub workspace: String,
    pub path: String,
    pub dirty: bool,
}
pub fn blocking_document<'a>(workspace: &str, documents: &'a [Document]) -> Option<&'a str> {
    documents
        .iter()
        .find(|d| text::equal(&d.workspace, workspace) && d.dirty)
        .map(|d| d.path.as_str())
}
pub fn removal_message(name: Option<&str>) -> String {
    let fallback = localization::text("apple.rootview.this_folder.9d6325c8", &[]);
    localization::text(
        "apple.rootview.remove_0_from_the_sidebar_the_folder_on_di.aef7692a",
        &[name.unwrap_or(&fallback)],
    )
}

#[cfg(unix)]
impl crate::client::Client {
    pub fn rename_repository(&self, id: &str, name: &str) -> anyhow::Result<()> {
        self.prepare()?;
        let params = serde_json::json!({"id": match rename_route(id) {RemovalRoute::Remote {ref id,..} => id.clone(),_=>id.into()},"name":name});
        let value = match rename_route(id) {
            RemovalRoute::Remote { peer, .. } => self.call(
                "remote.call",
                serde_json::json!({"peer":peer,"method":"workspace.rename","params":params}),
            )?,
            _ => self.call("workspace.rename", params)?,
        };
        #[derive(serde::Deserialize)]
        struct Ack {
            renamed: bool,
        }
        let ack: Ack = serde_json::from_value(value)?;
        let _ = ack.renamed;
        Ok(())
    }
    pub fn remove_repository(&self, route: &RemovalRoute) -> anyhow::Result<()> {
        if matches!(route, RemovalRoute::ForgetRemote { .. }) {
            return Ok(());
        }
        self.prepare()?;
        let value = match route {
            RemovalRoute::Local { id } => {
                self.call("workspace.remove", serde_json::json!({"id":id}))?
            }
            RemovalRoute::Remote { peer, id } => self.call(
                "remote.call",
                serde_json::json!({"peer":peer,"method":"workspace.remove","params":{"id":id}}),
            )?,
            RemovalRoute::ForgetRemote { .. } => unreachable!(),
        };
        #[derive(serde::Deserialize)]
        struct Ack {
            removed: bool,
        }
        let ack: Ack = serde_json::from_value(value)?;
        let _ = ack.removed;
        Ok(())
    }
    pub fn repositories(&self) -> anyhow::Result<Vec<crate::desktop_data::Repository>> {
        self.prepare()?;
        Ok(serde_json::from_value(self.call(
            "workspace.list",
            serde_json::json!({"includeGit":false}),
        )?)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rename_rejects_empty_and_double_submit_preserves_errors_during_retry() {
        let mut rename = Rename::default();
        assert!(rename.begin("\u{200b}\n").is_none());
        assert_eq!(rename.begin("  名称\n"), Some("名称".into()));
        assert!(rename.begin("second").is_none());
        assert!(!rename.finish(Err("failed".into())));
        assert_eq!(rename.height(), 300.);
        assert!(rename.begin("retry").is_some());
        assert_eq!(rename.error.as_deref(), Some("failed"));
        assert!(rename.finish(Ok(())));
    }
    #[test]
    fn dirty_gate_is_project_scoped_and_never_resumes_a_removal_itself() {
        let mut docs = vec![
            Document {
                workspace: "other".into(),
                path: "other-file".into(),
                dirty: true,
            },
            Document {
                workspace: "a".into(),
                path: "file".into(),
                dirty: true,
            },
        ];
        assert_eq!(blocking_document("a", &docs), Some("file"));
        docs[1].dirty = false;
        assert!(blocking_document("a", &docs).is_none());
    }
}

#[cfg(all(test, unix))]
#[path = "project_edit/tests.rs"]
mod transport_tests;
