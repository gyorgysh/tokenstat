// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use crate::work::ScopeKind;

impl HomeWork {
    /// Synthetic rows cover live, disconnected and saved-copy destinations.
    pub fn fixture() -> Self {
        let scope = Scope {
            kind: ScopeKind::Account,
            origin: "https://fixture.invalid".into(),
            identity: "fixture".into(),
        };
        let reference = |host: &str, workspace: &str, kind, item: Option<&str>| Reference {
            scope: scope.clone(),
            host_identity: host.into(),
            workspace_id: workspace.into(),
            kind,
            item_id: item.map(str::to_owned),
            anchor: None,
        };
        let local = reference(
            "local-fixture",
            "alpha",
            Kind::Conversation,
            Some("discussion"),
        );
        let remote = reference(
            "peer-fixture",
            "beta",
            Kind::Conversation,
            Some("disconnected"),
        );
        let saved = reference("peer-fixture", "beta", Kind::Conversation, Some("saved"));
        let previous = reference(
            "local-fixture",
            "previous",
            Kind::Conversation,
            Some("previous"),
        );
        Self {
            catalog: Catalog {
                scope: Some(scope.clone()),
                local_host_identity: Some("local-fixture".into()),
                folders: vec![
                    Folder {
                        id: "alpha".into(),
                        name: "alpha".into(),
                        machine_label: None,
                    },
                    Folder {
                        id: "remote:peer-fixture:beta".into(),
                        name: "beta".into(),
                        machine_label: Some("Studio".into()),
                    },
                ],
                machines: vec![Machine {
                    public_identity: Some("peer-fixture".into()),
                    online: Some(false),
                    ..Machine::default()
                }],
                access: [("peer-fixture".into(), true)].into(),
                saved: vec![saved.clone()],
                conversations: [
                    (
                        "alpha".into(),
                        vec![Conversation {
                            id: "discussion".into(),
                            title: "Continue the design discussion".into(),
                            unused: false,
                        }],
                    ),
                    (
                        "remote:peer-fixture:beta".into(),
                        vec![
                            Conversation {
                                id: "disconnected".into(),
                                title: "Review the implementation".into(),
                                unused: false,
                            },
                            Conversation {
                                id: "saved".into(),
                                title: "Saved conversation".into(),
                                unused: false,
                            },
                        ],
                    ),
                ]
                .into(),
                terminals: BTreeMap::new(),
            },
            recent: vec![local.clone(), remote, saved.clone(), previous],
            pins: vec![
                Pin {
                    reference: reference("local-fixture", "alpha", Kind::Workspace, None),
                    label: "alpha".into(),
                    folder_name: "alpha".into(),
                },
                Pin {
                    reference: saved,
                    label: "Saved conversation".into(),
                    folder_name: "beta".into(),
                },
                Pin {
                    reference: reference("peer-fixture", "beta", Kind::Terminal, Some("ended")),
                    label: "Build session".into(),
                    folder_name: "beta".into(),
                },
            ],
        }
    }
}
