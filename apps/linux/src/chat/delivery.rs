// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Captured send and receipt transactions. Call on a background worker; the
//! caller owns selection, sign-in checks, attachment staging and UI publication.

use super::{
    Conversation, DIRECTORY_TIMEOUT_SECS,
    outbox::{Delivery, Message, Store},
};
use crate::{
    client::Client,
    drafts::{Draft, storage},
    work::{Reference, continuity::Date, destination, text},
};
use anyhow::{Context, ensure};
use serde_json::{Value, json};
use std::time::Duration;
use tokenstat_core::host_rpc::ExchangeError;

#[derive(Debug)]
pub enum Outcome {
    Accepted {
        /// Original queued identity, which still owns the recovery draft.
        submitted: Message,
        /// Identity actually transmitted; it can rotate after an earlier attempt.
        delivery: Message,
        conversation: Box<Conversation>,
    },
    ReceiptAccepted {
        message: Message,
    },
    Unconfirmed {
        message: Message,
        state: String,
    },
    Refused {
        message: Message,
        error: String,
    },
    NeedsReview {
        message: Message,
        error: String,
    },
}

/// Only the exact writing and stable identity acknowledged by the host may be
/// removed. The caller passes this captured record to `clear_expected`, which
/// checks again against the latest disk and preserves a newer window's edit.
pub fn acknowledged_draft(reference: &Reference, draft: &Draft, submitted: &Message) -> bool {
    reference
        .conversation_key()
        .is_some_and(|key| draft.reference.conversation_key().as_deref() == Some(key.as_str()))
        && draft
            .message_id
            .as_deref()
            .is_some_and(|id| text::equal(id, &submitted.id))
        && text::equal(
            &draft.text,
            submitted
                .source_draft_text
                .as_deref()
                .unwrap_or(&submitted.text),
        )
        && draft.attachments == submitted.attachments
}

/// Persist a captured draft before attempting delivery. Reusing its stable ID
/// is allowed only for the same writing; an unresolved send owns that ID.
pub fn queue_draft(store: &Store, draft: &Draft, revision: Option<u64>) -> anyhow::Result<Message> {
    let id = draft
        .message_id
        .clone()
        .filter(|id| !id.is_empty())
        .context("The draft has no delivery identity")?;
    let words = text::trim(&draft.text).to_owned();
    ensure!(
        !words.is_empty() || !draft.attachments.is_empty(),
        "The message is empty"
    );
    let candidate = Message {
        id,
        text: words,
        attachments: draft.attachments.clone(),
        delivery: Delivery::Waiting,
        first_attempt_at: None,
        attempted_at: None,
        expected_revision: revision,
        when_connected: false,
        source_draft_text: Some(draft.text.clone()),
        sign_in_backend: None,
    };
    let items = store.update(&draft.reference, |items| {
        if let Some(existing) = items
            .iter()
            .find(|item| text::equal(&item.id, &candidate.id))
        {
            ensure!(
                existing.same_writing(&candidate),
                "The pending message changed"
            );
        } else {
            items.push(candidate.clone());
        }
        Ok(())
    })?;
    items
        .into_iter()
        .find(|item| text::equal(&item.id, &candidate.id))
        .context("Pending message changed")
}

/// Before calling, durably queue the captured item and finish all attachment,
/// agent setup and authorization gates. The fence is checked before each
/// network dispatch; after dispatch, disk reconciliation belongs to the
/// captured reference even if the view or login changes.
pub fn deliver(
    store: &Store,
    client: &Client,
    reference: &Reference,
    folder: &str,
    candidate: &Message,
    now_ms: i64,
    current: impl Fn() -> bool,
) -> anyhow::Result<Outcome> {
    let _lease = store
        .begin_delivery(reference)?
        .context("A message is already being delivered")?;
    let id = reference
        .item_id
        .as_deref()
        .filter(|id| !id.is_empty())
        .context("Missing conversation")?;
    let route = destination::route(folder, None);
    ensure!(
        text::equal(&route.workspace_id, &reference.workspace_id),
        "The conversation destination changed"
    );
    if let Some(peer) = &route.peer {
        ensure!(
            text::equal(peer, &reference.host_identity),
            "The conversation host changed"
        );
    }
    ensure!(current(), "The conversation owner changed");
    let held = store
        .items(reference)?
        .into_iter()
        .find(|item| text::equal(&item.id, &candidate.id))
        .context("Pending message changed")?;
    ensure!(
        held.same_writing(candidate) && held.expected_revision == candidate.expected_revision,
        "Pending message changed"
    );
    client.prepare()?;
    ensure!(current(), "The conversation owner changed");
    if let Some(peer) = &route.peer {
        let version = invoke(client, Some(peer), "protocol", json!({}))?;
        ensure!(current(), "The conversation owner changed");
        let minimum = if held.needs_receipt() { 10 } else { 14 };
        ensure!(
            version["protocolVersion"]
                .as_str()
                .and_then(|v| v.parse::<u64>().ok())
                .is_some_and(|v| v >= minimum),
            "Update the conversation's computer before sending"
        );
        let access = invoke(client, Some(peer), "workspace.access.check", json!({}))?;
        ensure!(current(), "The conversation owner changed");
        ensure!(
            access["allowed"].as_bool() == Some(true),
            "Workspace access is unavailable"
        );
    }
    if held.needs_receipt() {
        let receipt = invoke(
            client,
            route.peer.as_deref(),
            "chat.receipt",
            json!({"id":id,"clientMessageId":held.id}),
        )?;
        let state = match receipt["state"].as_str() {
            Some("accepted") => "accepted",
            Some("pending") => "pending",
            Some("needsRecovery") => "needsRecovery",
            _ => "unknown",
        };
        if state == "accepted" {
            store.update(reference, |items| {
                let index = matching(items, &held)?;
                ensure!(items[index].needs_receipt(), "Pending message changed");
                items.remove(index);
                Ok(())
            })?;
            return Ok(Outcome::ReceiptAccepted { message: held });
        }
        let mut uncertain = held.clone();
        uncertain.delivery = Delivery::DeliveryUnknown;
        replace_if_matches(store, reference, &held, &uncertain)?;
        return Ok(Outcome::Unconfirmed {
            message: uncertain,
            state: state.into(),
        });
    }
    ensure!(held.sign_in_backend.is_none(), "The agent needs sign-in");
    if held.expected_revision.is_none() || held.delivery == Delivery::NeedsReview {
        let mut needs_review = held.clone();
        needs_review.delivery = Delivery::NeedsReview;
        replace_if_matches(store, reference, &held, &needs_review)?;
        return Ok(Outcome::NeedsReview {
            message: needs_review,
            error: "Review the live conversation before sending".into(),
        });
    }
    ensure!(
        !text::trim(&held.text).is_empty() || !held.attachments.is_empty(),
        "The message is empty"
    );
    ensure!(held.can_edit(), "Check delivery before sending again");
    // Caller must have resolved original-file uploads first. This worker never
    // guesses whether a local attachment ID is valid on a remote machine.
    let mut attempt = held.clone();
    let rotates = held.attempted_at.is_some() && held.delivery == Delivery::Waiting;
    if rotates {
        attempt.id = storage::uuid()?;
    }
    let now = Date::from_unix_ms(now_ms);
    let first = if rotates {
        now
    } else {
        held.first_attempt_at.or(held.attempted_at).unwrap_or(now)
    };
    let first_ms = to_unix_ms(first)?;
    attempt.first_attempt_at = Some(first);
    attempt.attempted_at = Some(now);
    attempt.delivery = Delivery::Sending;
    replace_if_matches(store, reference, &held, &attempt)?;
    if !current() {
        // No bytes were sent. Restore the exact prior record if it has not
        // been changed independently, rather than inventing uncertainty.
        replace_if_matches(store, reference, &attempt, &held)?;
        anyhow::bail!("The conversation owner changed");
    }
    let method = if text::trim(&attempt.text) == "/compact" {
        "chat.compact"
    } else {
        "chat.send"
    };
    let params = json!({"id":id,"text":attempt.text,"attachmentIds":attempt.attachments.iter().map(|a| &a.id).collect::<Vec<_>>(),"clientMessageId":attempt.id,"clientMessageCreatedAtMs":first_ms,"expectedRevision":attempt.expected_revision});
    let response = invoke(client, route.peer.as_deref(), method, params);
    match response.and_then(|value| {
        let conversation = serde_json::from_value::<Conversation>(value)
            .context("The host's send response was unreadable")?;
        ensure!(
            text::equal(&conversation.id, id)
                && text::equal(&conversation.workspace_id, &reference.workspace_id),
            "The host answered for a different conversation"
        );
        Ok(conversation)
    }) {
        Ok(conversation) => {
            // Host acceptance is already real even if local persistence fails;
            // the durable sending state will force receipt checking next time.
            store.accept(reference, &attempt, conversation.send_revision)?;
            Ok(Outcome::Accepted {
                submitted: held,
                delivery: attempt,
                conversation: Box::new(conversation),
            })
        }
        Err(error) => {
            let code = error
                .downcast_ref::<ExchangeError>()
                .and_then(|error| match error {
                    ExchangeError::Remote { code, .. } => code.as_deref(),
                    _ => None,
                });
            let is_review = code == Some("conversation_changed");
            let unknown = match error.downcast_ref::<ExchangeError>() {
                Some(ExchangeError::Remote {
                    code: Some(code), ..
                }) => matches!(code.as_str(), "delivery_unknown" | "unknown" | "null"),
                Some(ExchangeError::Transport(_)) => true,
                // `Client` retains an io::Error only for failure to connect;
                // the request could not have left this process in that case.
                None if error.downcast_ref::<std::io::Error>().is_some() => false,
                _ => true,
            };
            let mut recorded = attempt.clone();
            recorded.delivery = if is_review {
                Delivery::NeedsReview
            } else if unknown {
                Delivery::DeliveryUnknown
            } else {
                Delivery::Failed
            };
            replace_if_matches(store, reference, &attempt, &recorded)?;
            let message = format!("{error:#}");
            if is_review {
                Ok(Outcome::NeedsReview {
                    message: recorded,
                    error: message,
                })
            } else if unknown {
                Ok(Outcome::Unconfirmed {
                    message: recorded,
                    state: "unknown".into(),
                })
            } else {
                Ok(Outcome::Refused {
                    message: recorded,
                    error: message,
                })
            }
        }
    }
}
fn to_unix_ms(date: Date) -> anyhow::Result<i64> {
    let ms = (date.0 + 978_307_200.) * 1000.;
    ensure!(
        ms.is_finite() && ms >= i64::MIN as f64 && ms < 9_223_372_036_854_775_808.,
        "The saved message time is invalid"
    );
    Ok(ms.trunc() as i64)
}
fn matching(items: &[Message], expected: &Message) -> anyhow::Result<usize> {
    let index = items
        .iter()
        .position(|item| text::equal(&item.id, &expected.id))
        .context("Pending message changed")?;
    ensure!(items[index] == *expected, "Pending message changed");
    Ok(index)
}
fn replace_if_matches(
    store: &Store,
    reference: &Reference,
    expected: &Message,
    replacement: &Message,
) -> anyhow::Result<()> {
    store.update(reference, |items| {
        let index = matching(items, expected)?;
        items[index] = replacement.clone();
        Ok(())
    })?;
    Ok(())
}
fn invoke(
    client: &Client,
    peer: Option<&str>,
    method: &str,
    params: Value,
) -> anyhow::Result<Value> {
    let timeout = Duration::from_secs(DIRECTORY_TIMEOUT_SECS);
    match peer {
        Some(peer) => client.call_with_timeout(
            "remote.call",
            json!({"peer":peer,"method":method,"params":params}),
            timeout,
        ),
        None => client.call_with_timeout(method, params, timeout),
    }
}

#[cfg(test)]
#[path = "delivery_tests.rs"]
mod tests;
