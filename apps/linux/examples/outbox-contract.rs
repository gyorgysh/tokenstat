// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Private cross-language fixture; never uses the user's outbox.
use tokenstat_linux::{
    chat::outbox::{Delivery, Message, Store},
    drafts::{Attachment, storage::MAX_FILE_BYTES},
    work::{Kind, Reference, Scope, continuity::Date},
};
fn main() -> anyhow::Result<()> {
    let args: Vec<_> = std::env::args().collect();
    let store = Store::at(args[2].clone().into(), MAX_FILE_BYTES);
    let reference = Reference {
        scope: Scope::local("fixture"),
        host_identity: "host".into(),
        workspace_id: "folder".into(),
        kind: Kind::Conversation,
        item_id: Some("chat".into()),
        anchor: None,
    };
    match args[1].as_str() {
        "write" => {
            store.update(&reference, |items| {
                items.push(Message {
                    id: "rust".into(),
                    text: "Rust / café 🦊".into(),
                    attachments: vec![Attachment {
                        id: "file-rust".into(),
                        name: "one.txt".into(),
                        media_type: Some("text/plain".into()),
                        size: Some(42),
                        tool_call_id: None,
                    }],
                    delivery: Delivery::DeliveryUnknown,
                    first_attempt_at: Some(Date(123.5)),
                    attempted_at: Some(Date(124.)),
                    expected_revision: Some(7),
                    when_connected: false,
                    source_draft_text: Some("Rust / café 🦊".into()),
                    sign_in_backend: None,
                });
                Ok(())
            })?;
        }
        "waiting" => {
            store.update(&reference, |items| {
                items.push(Message {
                    id: "waiting".into(),
                    text: "next".into(),
                    attachments: vec![],
                    delivery: Delivery::Waiting,
                    first_attempt_at: None,
                    attempted_at: None,
                    expected_revision: Some(7),
                    when_connected: false,
                    source_draft_text: None,
                    sign_in_backend: None,
                });
                Ok(())
            })?;
        }
        "accept" => {
            let sent = store
                .items(&reference)?
                .into_iter()
                .find(|item| item.id == "rust")
                .ok_or_else(|| anyhow::anyhow!("missing message"))?;
            store.accept(&reference, &sent, Some(8))?;
        }
        "read" => println!("{}", serde_json::to_string(&store.items(&reference)?)?),
        _ => anyhow::bail!("unknown command"),
    }
    Ok(())
}
