// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! An OS-account owner can withdraw local sharing even after signing out or
//! losing their cloud account. This surface grants no new access, uses no
//! account credential and never sends a hosted mutation on their behalf.

use super::publications::{Phase, Store};
use crate::error::DispatchError;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Info {
    workspace_id: String,
    id: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Stop {
    workspace_id: String,
    id: String,
    share: String,
    expected_revision: u64,
    confirm_stop: bool,
    #[serde(default)]
    source_only: bool,
}
fn invalid() -> DispatchError {
    DispatchError::new(
        "invalid_request",
        "Refresh this chat's sharing details and try again.",
    )
}
pub(super) fn call(method: &str, params: &str) -> Option<Result<Value, DispatchError>> {
    if !matches!(method, "chat.sharing.info" | "chat.sharing.stopLocal") {
        return None;
    }
    Some((|| {
        crate::request_context::refuse_remote("local chat sharing recovery").map_err(|_| {
            DispatchError::new(
                "local_only",
                "Stop local sharing on its publishing computer.",
            )
        })?;
        if params.len() > 16 * 1024 {
            return Err(invalid());
        }
        match method {
            "chat.sharing.info" => {
                let input: Info = serde_json::from_str(params).map_err(|_| invalid())?;
                let chats = crate::chat::shared();
                let (binding, source_revision) =
                    chats.sharing_state(&input.workspace_id, &input.id)?;
                let record = Store::capture().and_then(|store| {
                    store.source_record(
                        &input.workspace_id,
                        &input.id,
                        binding.as_ref().map(|value| value.id.as_str()),
                    )
                });
                let record = match record {
                    Ok(record) => record,
                    Err(_) if binding.is_some() => None,
                    Err(error) => return Err(error),
                };
                if let Some(binding) = binding.as_ref().filter(|_| record.is_none()) {
                    return Ok(
                        json!({"sharing":{"id":binding.id,"revision":source_revision,"phase":"active",
                        "privateReady":false,"sourceOnly":true,"accountCleanupPending":true}}),
                    );
                }
                Ok(
                    json!({"sharing":record.map(|(parent,row)| json!({"id":row.id,"organizationId":parent.organization_id,"repositoryId":parent.repository_id,"checkoutId":parent.id,
                    "revision":row.revision,"phase":row.phase,"privateReady":binding.is_none(),"accountCleanupPending":row.phase==Phase::Withdrawn && !row.cloud_withdrawn}))}),
                )
            }
            "chat.sharing.stopLocal" => {
                let input: Stop = serde_json::from_str(params).map_err(|_| invalid())?;
                if !input.confirm_stop
                    || input.expected_revision == 0
                    || input.expected_revision > 9_007_199_254_740_991
                    || !crate::chat_receipts::valid_id(&input.id)
                    || input.workspace_id.is_empty()
                    || input.workspace_id.len() > 4096
                    || !input.share.strip_prefix("share_").is_some_and(|id| {
                        id.len() == 32 && id.bytes().all(|byte| byte.is_ascii_hexdigit())
                    })
                {
                    return Err(invalid());
                }
                let chats = crate::chat::shared();
                if input.source_only {
                    chats.clear_sharing_at_revision(
                        &input.workspace_id,
                        &input.id,
                        &input.share,
                        Some(input.expected_revision),
                    )?;
                    return Ok(
                        json!({"stoppedLocally":true,"privateReady":true,"localRecoveryNeeded":false,
                        "accountCleanupPending":true,"localRecordsIncomplete":true}),
                    );
                }
                let store = Store::capture()?;
                // First make the exact reference unreadable. A failed local
                // source repair or unavailable cloud service cannot undo it.
                let (_, retired) = store.retire_source(
                    &input.workspace_id,
                    &input.id,
                    &input.share,
                    input.expected_revision,
                )?;
                let cleared = chats
                    .clear_sharing(&input.workspace_id, &input.id, &input.share)
                    .is_ok();
                let private_ready = cleared
                    && chats
                        .sharing_binding(&input.workspace_id, &input.id)?
                        .is_none();
                Ok(
                    json!({"stoppedLocally":true,"privateReady":private_ready,"localRecoveryNeeded":!cleared,"accountCleanupPending":!retired.cloud_withdrawn}),
                )
            }
            _ => Err(invalid()),
        }
    })())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn paired_personal_devices_cannot_recover_local_sources_or_supply_account_authority() {
        crate::request_context::with_remote_peer("fixture-personal-peer", || {
            for method in ["chat.sharing.info", "chat.sharing.stopLocal"] {
                assert_eq!(call(method, "{}").unwrap().unwrap_err().code, "local_only");
            }
        });
        for body in [
            r#"{"workspaceId":"fixture","id":"chat_fixture","actor":"forged"}"#,
            r#"{"id":"chat_fixture"}"#,
        ] {
            assert_eq!(
                call("chat.sharing.info", body).unwrap().unwrap_err().code,
                "invalid_request"
            );
        }
        assert!(call("chat.send", "{}").is_none());
    }
}
