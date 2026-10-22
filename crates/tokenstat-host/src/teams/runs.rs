// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Team runs that are still going on this host.
//!
//! A guardian stops when its control pipe closes, so the pipe has to live
//! somewhere after the Ask request returns. It lives here, in the host
//! process, next to who may stop the run. A reader thread follows the
//! guardian's events and forgets the run once it has finished. When the host
//! exits, every pipe closes and every run stops.

use super::AuthorizedTeamPrincipal;
use crate::{chat_receipts::team_runs::Fence, error::DispatchError, team_process};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::BufReader,
    process::{Child, ChildStdin, ChildStdout},
    sync::{Mutex, MutexGuard},
};
use tokenstat_sync::teams::RepositoryRole;

/// More runs than this on one computer is a mistake, not a workload.
const LIMIT: usize = 16;

struct Run {
    fence: Fence,
    scope: Scope,
    initiator: String,
    control: ChildStdin,
}

/// Where a run belongs. Stop is checked against all of it.
#[derive(Clone, PartialEq, Eq)]
struct Scope {
    issuer: String,
    publisher: String,
    host: String,
    organization: String,
    repository: String,
    checkout: String,
    share: Option<String>,
}

impl Scope {
    fn of(principal: &AuthorizedTeamPrincipal) -> Self {
        let value = principal.value();
        Self {
            issuer: principal.issuer().into(),
            publisher: value.publisher_id.clone(),
            host: value.host_key.clone(),
            organization: value.organization_id.clone(),
            repository: value.repository_id.clone(),
            checkout: value.checkout_id.clone(),
            share: value.share_id.clone(),
        }
    }
}

static RUNS: Mutex<Option<HashMap<String, Run>>> = Mutex::new(None);

fn runs() -> MutexGuard<'static, Option<HashMap<String, Run>>> {
    RUNS.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn busy() -> DispatchError {
    DispatchError::new(
        "team_runs_busy",
        "This computer is running as many agents as it allows. Try again when one finishes.",
    )
}

pub(super) fn register(
    principal: &AuthorizedTeamPrincipal,
    fence: Fence,
    control: ChildStdin,
    child: Child,
    output: BufReader<ChildStdout>,
) -> Result<(), DispatchError> {
    let id = fence.run_id().to_string();
    {
        let mut guard = runs();
        let table = guard.get_or_insert_with(HashMap::new);
        if table.len() >= LIMIT || table.contains_key(&id) {
            // Dropping the pipe stops this guardian; the reader still reaps it.
            drop(control);
            follow(None, child, output);
            return Err(busy());
        }
        table.insert(
            id.clone(),
            Run {
                fence,
                scope: Scope::of(principal),
                initiator: principal.value().person.id.clone(),
                control,
            },
        );
    }
    follow(Some(id), child, output);
    Ok(())
}

/// Read events until the guardian finishes, then reap it and forget the run.
fn follow(id: Option<String>, mut child: Child, mut output: BufReader<ChildStdout>) {
    let key = id.clone();
    let worker = move || {
        while let Ok(event) = team_process::receive::<Value>(&mut output) {
            if event["event"] == "finished" {
                break;
            }
        }
        // A finished frame can precede the guardian's final drops. Keep the
        // run visible until it exits, so a subsequent Ask/Land cannot race
        // its writer cleanup.
        let _ = child.wait();
        if let Some(id) = &key
            && let Some(table) = runs().as_mut()
        {
            table.remove(id);
        }
    };
    let spawned = std::thread::Builder::new()
        .name("team-run-follow".into())
        .spawn(worker);
    if spawned.is_err()
        && let Some(id) = id
        && let Some(table) = runs().as_mut()
    {
        // No reader means nobody would forget this run. Closing its pipe
        // stops the guardian now rather than leaving it unstoppable.
        table.remove(&id);
    }
}

/// Who may stop a run: the person who asked, a repository maintainer, or the
/// publisher of this checkout. Everyone else sees the run but cannot end it.
fn may_stop(principal: &AuthorizedTeamPrincipal, scope: &Scope, initiator: &str) -> bool {
    let value = principal.value();
    Scope::of(principal) == *scope
        && (value.person.id == initiator
            || value.person.id == value.publisher_id
            || value.role == RepositoryRole::Maintainer)
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Input {
    fence: Fence,
}
fn input(params: &str) -> Result<Input, DispatchError> {
    if params.len() > 1024 {
        return Err(invalid());
    }
    serde_json::from_str(params).map_err(|_| invalid())
}

/// Whether this host still follows a guardian for `fence`.
pub(super) fn is_running(fence: &Fence) -> bool {
    runs()
        .as_ref()
        .and_then(|table| table.get(fence.run_id()))
        .is_some_and(|run| &run.fence == fence)
}

/// A retry can recover control of its own still-running Ask after losing the
/// first reply. The canonical receipt was verified before this lookup.
pub(super) fn resume(principal: &AuthorizedTeamPrincipal, receipt: &Value) -> Option<Value> {
    let id = receipt.get("receipt")?.get("runId")?.as_str()?;
    let guard = runs();
    let run = guard.as_ref()?.get(id)?;
    if run.scope != Scope::of(principal) || run.initiator != principal.value().person.id {
        return None;
    }
    Some(json!({"state":"running","runId":id,"fence":run.fence,"receipt":receipt["receipt"]}))
}

/// Whether a run is still going here. Anyone in the run's scope may ask,
/// since everyone reading the chat sees that it is running.
pub(super) fn status(
    principal: &AuthorizedTeamPrincipal,
    params: &str,
) -> Result<Value, DispatchError> {
    let input = input(params)?;
    let scope = Scope::of(principal);
    let running = runs().as_ref().is_some_and(|table| {
        table
            .get(input.fence.run_id())
            .is_some_and(|run| run.fence == input.fence && run.scope == scope)
    });
    Ok(json!({"running":running}))
}

pub(super) fn stop(
    principal: &AuthorizedTeamPrincipal,
    params: &str,
) -> Result<Value, DispatchError> {
    // Stop needs the same verified Run proof as Review and Send.
    principal.run_ticket()?;
    let input = input(params)?;
    let mut guard = runs();
    let Some(run) = guard
        .as_mut()
        .and_then(|table| table.get_mut(input.fence.run_id()))
        .filter(|run| run.fence == input.fence)
    else {
        // Finished, never started here, or already gone: nothing to stop.
        return Ok(json!({"stopping":false}));
    };
    if !may_stop(principal, &run.scope, &run.initiator) {
        return Err(DispatchError::new(
            "team_run_stop_forbidden",
            "Only the person who asked, a maintainer or the publisher can stop this agent.",
        ));
    }
    team_process::send(
        &mut run.control,
        &json!({"action":"stop","fence":input.fence}),
    )
    .map_err(|_| {
        DispatchError::new(
            "team_run_recovery_required",
            "This Team run needs recovery on its publishing computer.",
        )
    })?;
    Ok(json!({"stopping":true}))
}

fn invalid() -> DispatchError {
    DispatchError::new("invalid_request", "Check the Team request and try again.")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn principal(person: &str, role: &str, share: &str) -> AuthorizedTeamPrincipal {
        AuthorizedTeamPrincipal::storage_fixture(
            serde_json::from_value(json!({
                "id":person,"name":"Example person","handle":null,"avatar":null,"deviceKey":"a".repeat(64),
                "organizationId":"org","repositoryId":"repo","checkoutId":"checkout","hostKey":"b".repeat(64),"publisherId":"owner",
                "shareId":share,"grantId":null,"epoch":1,"capabilities":["read","run"],"role":role,"expiresAt":"2026-12-01T00:00:00Z"
            }))
            .unwrap(),
        )
    }

    #[test]
    fn only_the_asker_a_maintainer_or_the_publisher_can_stop() {
        let share = format!("share_{}", "a".repeat(32));
        let scope = Scope::of(&principal("asker", "viewer", &share));
        assert!(may_stop(
            &principal("asker", "contributor", &share),
            &scope,
            "asker"
        ));
        assert!(may_stop(
            &principal("lead", "maintainer", &share),
            &scope,
            "asker"
        ));
        assert!(may_stop(
            &principal("owner", "viewer", &share),
            &scope,
            "asker"
        ));
        assert!(!may_stop(
            &principal("other", "contributor", &share),
            &scope,
            "asker"
        ));
        assert!(!may_stop(
            &principal("other", "viewer", &share),
            &scope,
            "asker"
        ));
    }

    #[test]
    fn a_maintainer_of_another_share_cannot_stop() {
        let scope = Scope::of(&principal(
            "asker",
            "viewer",
            &format!("share_{}", "a".repeat(32)),
        ));
        let elsewhere = principal("lead", "maintainer", &format!("share_{}", "b".repeat(32)));
        assert!(!may_stop(&elsewhere, &scope, "asker"));
        let maintainer = principal("lead", "maintainer", &format!("share_{}", "a".repeat(32)));
        for changed in ["issuer", "publisher", "host"] {
            let mut other = scope.clone();
            match changed {
                "issuer" => other.issuer = "https://other.example.test".into(),
                "publisher" => other.publisher = "other-publisher".into(),
                _ => other.host = "e".repeat(64),
            }
            assert!(!may_stop(&maintainer, &other, "asker"));
        }
    }

    #[test]
    fn stop_needs_a_run_proof_and_status_reports_unknown_runs() {
        let share = format!("share_{}", "a".repeat(32));
        let fence = json!({"runId":format!("run_{}", "c".repeat(32)),"incarnation":"d".repeat(64)});
        // Without a verified Run proof, Stop is refused before any lookup.
        assert!(
            stop(
                &principal("asker", "viewer", &share),
                &json!({"fence":fence}).to_string(),
            )
            .is_err()
        );
        let report = status(
            &principal("asker", "viewer", &share),
            &json!({"fence":fence}).to_string(),
        )
        .unwrap();
        assert_eq!(report["running"], false);
        assert!(status(&principal("asker", "viewer", &share), "{\"fence\":1}").is_err());
    }
}
