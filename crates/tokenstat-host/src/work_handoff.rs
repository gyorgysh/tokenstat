// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Explicit, host-mediated continuation. Sharing is not a send or an outbox.
//! The host supplies the authenticated device identity and timestamp; a client
//! supplies only its display label, optional draft and reading anchor.

use serde::{Deserialize, Serialize};

pub const MAX_DRAFT_BYTES: usize = 256 * 1024;
const MAX_ATTACHMENTS: usize = 20;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SharedDraft {
    pub text: String,
    /// Host-owned attachments, verified against this conversation before put.
    /// Device-local file paths never cross this boundary.
    pub attachment_ids: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReadAnchor {
    pub event_id: String,
    /// A proportion within a row, portable across text sizes and layouts.
    pub fraction: u16,
    pub follows_latest: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PutHandoff {
    pub request_id: String,
    pub expected_revision: u64,
    pub device_name: String,
    pub draft: Option<SharedDraft>,
    pub anchor: Option<ReadAnchor>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Handoff {
    pub revision: u64,
    pub request_id: String,
    pub device_id: String,
    pub device_name: String,
    pub updated_at_ms: i64,
    pub draft: Option<SharedDraft>,
    pub anchor: Option<ReadAnchor>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum PutResult {
    Saved { handoff: Handoff },
    Conflict { current: Option<Handoff> },
}

fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.:".contains(&b))
}

pub(crate) fn validate(request: &PutHandoff, device_id: &str) -> Result<(), String> {
    if !valid_id(&request.request_id) || !valid_id(device_id) {
        return Err("handoff identity is not usable".into());
    }
    if request.device_name.trim().is_empty()
        || request.device_name.len() > 128
        || request.device_name.chars().any(char::is_control)
    {
        return Err("handoff needs a short device name".into());
    }
    if let Some(draft) = &request.draft {
        if draft.text.len() > MAX_DRAFT_BYTES
            || draft.attachment_ids.len() > MAX_ATTACHMENTS
            || draft.attachment_ids.iter().any(|id| !valid_id(id))
        {
            return Err("handoff draft is too large or has invalid attachments".into());
        }
        let mut ids = std::collections::HashSet::new();
        if draft.attachment_ids.iter().any(|id| !ids.insert(id)) {
            return Err("handoff repeats an attachment".into());
        }
    }
    if let Some(anchor) = &request.anchor {
        if !valid_id(&anchor.event_id) || anchor.fraction > 10_000 {
            return Err("handoff reading position is not usable".into());
        }
    }
    Ok(())
}

/// Pure compare-and-swap, called while the persistence transaction is locked.
/// A conflict returns the current version without changing either draft. The
/// client keeps its local version until the person chooses how to resolve it.
pub fn apply(
    current: Option<&Handoff>,
    request: &PutHandoff,
    authenticated_device: &str,
    now_ms: i64,
) -> Result<PutResult, String> {
    validate(request, authenticated_device)?;
    if now_ms < 0 {
        return Err("handoff timestamp is not usable".into());
    }
    if let Some(current) = current {
        if current.device_id == authenticated_device && current.request_id == request.request_id {
            if current.device_name != request.device_name.trim()
                || current.draft != request.draft
                || current.anchor != request.anchor
                || request.expected_revision.checked_add(1) != Some(current.revision)
            {
                return Err("handoff request ID was already used for different content".into());
            }
            // A lost reply does not create a new revision or change its time.
            return Ok(PutResult::Saved {
                handoff: current.clone(),
            });
        }
    }
    let revision = current.map_or(0, |record| record.revision);
    if request.expected_revision != revision {
        return Ok(PutResult::Conflict {
            current: current.cloned(),
        });
    }
    let next = revision
        .checked_add(1)
        .ok_or("handoff revision is exhausted")?;
    Ok(PutResult::Saved {
        handoff: Handoff {
            revision: next,
            request_id: request.request_id.clone(),
            device_id: authenticated_device.into(),
            device_name: request.device_name.trim().into(),
            updated_at_ms: now_ms,
            draft: request.draft.clone(),
            anchor: request.anchor.clone(),
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(id: &str, revision: u64, text: &str) -> PutHandoff {
        PutHandoff {
            request_id: id.into(),
            expected_revision: revision,
            device_name: "Studio".into(),
            draft: Some(SharedDraft {
                text: text.into(),
                attachment_ids: vec![],
            }),
            anchor: None,
        }
    }
    fn saved(result: PutResult) -> Handoff {
        match result {
            PutResult::Saved { handoff } => handoff,
            _ => panic!("expected saved"),
        }
    }

    #[test]
    fn concurrent_edits_return_the_newer_draft_without_overwriting() {
        let first = saved(apply(None, &request("one", 0, "first draft"), "device-a", 1).unwrap());
        let newer = saved(
            apply(
                Some(&first),
                &request("two", 1, "from phone"),
                "device-b",
                2,
            )
            .unwrap(),
        );
        assert_eq!(
            apply(
                Some(&newer),
                &request("three", 1, "from desktop"),
                "device-a",
                3
            )
            .unwrap(),
            PutResult::Conflict {
                current: Some(newer.clone())
            }
        );
        assert_eq!(newer.draft.unwrap().text, "from phone");
    }

    #[test]
    fn lost_reply_is_idempotent_but_an_id_cannot_change_its_content() {
        let original = request("one", 0, "draft");
        let first = saved(apply(None, &original, "device-a", 10).unwrap());
        assert_eq!(
            saved(apply(Some(&first), &original, "device-a", 99).unwrap()),
            first
        );
        assert!(apply(Some(&first), &request("one", 0, "other"), "device-a", 11).is_err());
        let mut spaced = request("spaced", 0, "draft");
        spaced.device_name = "  Studio  ".into();
        let kept = saved(apply(None, &spaced, "device-a", 10).unwrap());
        assert_eq!(
            saved(apply(Some(&kept), &spaced, "device-a", 11).unwrap()),
            kept
        );
        assert!(matches!(
            apply(Some(&first), &original, "device-b", 11).unwrap(),
            PutResult::Conflict { .. }
        ));
    }

    #[test]
    fn missing_revision_and_exhaustion_never_replace_content() {
        assert_eq!(
            apply(None, &request("one", 1, "draft"), "device-a", 1).unwrap(),
            PutResult::Conflict { current: None }
        );
        let mut current = saved(apply(None, &request("one", 0, "draft"), "device-a", 1).unwrap());
        current.revision = u64::MAX;
        assert!(
            apply(
                Some(&current),
                &request("two", u64::MAX, "next"),
                "device-a",
                2
            )
            .is_err()
        );
    }

    #[test]
    fn clients_cannot_supply_server_authority_fields() {
        let mut value = serde_json::to_value(request("one", 0, "draft")).unwrap();
        value["deviceId"] = "another-device".into();
        assert!(serde_json::from_value::<PutHandoff>(value.clone()).is_err());
        value.as_object_mut().unwrap().remove("deviceId");
        value["updatedAtMs"] = 1.into();
        assert!(serde_json::from_value::<PutHandoff>(value).is_err());
    }

    #[test]
    fn payload_bounds_do_not_truncate_words_or_accept_file_paths() {
        let mut value = request("one", 0, &"é".repeat(MAX_DRAFT_BYTES / 2 + 1));
        assert!(apply(None, &value, "device-a", 1).is_err());
        value.draft = Some(SharedDraft {
            text: "draft".into(),
            attachment_ids: vec!["/private/file".into()],
        });
        assert!(apply(None, &value, "device-a", 1).is_err());
        value.draft = None;
        value.anchor = Some(ReadAnchor {
            event_id: "user-s12".into(),
            fraction: 10_001,
            follows_latest: false,
        });
        assert!(apply(None, &value, "device-a", 1).is_err());
        value.anchor.as_mut().unwrap().fraction = 5000;
        assert!(apply(None, &value, "device-a", 1).is_ok());
    }
}
