// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Whether a teammate's Ask may start an agent on this computer.
//!
//! The account server decides who is eligible: every contributor, or only
//! the devices the publisher picked. This decides whether this computer
//! takes part at all, per shared checkout, and it belongs to the person who
//! shares it. A run spends their agent login and works in their folder, so
//! a new share starts with agent runs off until they choose otherwise.
//!
//! - Off: an Ask is refused and the chat hides Ask.
//! - Ask: each request waits until the publisher allows or denies it here.
//! - On: eligible teammates run without asking.
//!
//! The publisher's own Ask from another device is never held: it is them.
//!
//! Settings live in their own file rather than in the publication index, so
//! an older host that meets them after a downgrade only ignores this file
//! and never rejects the index it shares with every other Teams feature.

use crate::error::DispatchError;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::Digest;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::Mutex,
};
use tokenstat_sync::teams::TeamPrincipal;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) enum Access {
    #[default]
    Off,
    Ask,
    On,
}

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Entry {
    access: Access,
    /// People this publisher chose "always allow" for while asking.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    allowed_people: BTreeSet<String>,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct File {
    version: u32,
    checkouts: BTreeMap<String, Entry>,
}

const FILE_MAX_BYTES: u64 = 256 * 1024;
/// How long an unanswered or answered request is kept. Long enough to step
/// away from the computer for a moment, short enough that an old approval
/// cannot start a run nobody remembers allowing.
const REQUEST_LIFETIME_MS: i64 = 15 * 60 * 1000;
const MAX_PENDING: usize = 64;
const MAX_PENDING_PER_PERSON: usize = 3;

/// What the publisher decided about one held request.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Decision {
    Once,
    Always,
    Deny,
}

#[derive(Clone)]
struct Request {
    id: String,
    checkout: String,
    organization: String,
    repository: String,
    person: String,
    person_name: String,
    message: String,
    /// The whole request as it was held. An approval covers exactly this,
    /// so the same message id cannot carry different text once allowed.
    digest: String,
    preview: String,
    created_at_ms: i64,
    decision: Option<Decision>,
}

static REQUESTS: Mutex<Vec<Request>> = Mutex::new(Vec::new());

fn now_ms() -> i64 {
    crate::chat::now_ms()
}

fn requests() -> std::sync::MutexGuard<'static, Vec<Request>> {
    let mut held = REQUESTS.lock().unwrap_or_else(|error| error.into_inner());
    let now = now_ms();
    held.retain(|request| now - request.created_at_ms < REQUEST_LIFETIME_MS);
    held
}

/// This computer's setting for one shared checkout, for the chat details
/// and the review a teammate's app reads before it offers Ask.
pub(super) fn allows(principal: &TeamPrincipal) -> bool {
    principal.person.id == principal.publisher_id
        || load().is_ok_and(|file| {
            file.checkouts
                .get(&principal.checkout_id)
                .is_some_and(|entry| entry.access != Access::Off)
        })
}

/// Decide whether this Ask may start now. A request that has to wait is
/// recorded for the publisher to answer, and the teammate's app sends the
/// same request again until it is answered or expires.
pub(super) fn admit(
    principal: &TeamPrincipal,
    input: &crate::chat::sharing::AskInput,
) -> Result<(), DispatchError> {
    if principal.person.id == principal.publisher_id {
        return Ok(());
    }
    let entry = load()?
        .checkouts
        .get(&principal.checkout_id)
        .cloned()
        .unwrap_or_default();
    let digest = tokenstat_identity::hex(&sha2::Sha256::digest(
        serde_json::to_vec(input).map_err(|_| invalid())?,
    ));
    admit_with(
        &entry,
        principal,
        &input.client_message_id,
        &digest,
        &input.text,
    )
}

fn admit_with(
    entry: &Entry,
    principal: &TeamPrincipal,
    message: &str,
    digest: &str,
    text: &str,
) -> Result<(), DispatchError> {
    if principal.person.id == principal.publisher_id {
        return Ok(());
    }
    match entry.access {
        Access::Off => Err(off()),
        Access::On => Ok(()),
        Access::Ask if entry.allowed_people.contains(&principal.person.id) => Ok(()),
        Access::Ask => {
            let mut held = requests();
            if let Some(index) = held.iter().position(|request| {
                request.checkout == principal.checkout_id
                    && request.person == principal.person.id
                    && request.message == message
            }) {
                if held[index].digest != digest {
                    held.remove(index);
                    return Err(changed_request());
                }
                return match held[index].decision {
                    // Kept rather than consumed: a retry of a run that has
                    // already started must reach its receipt, not a new prompt.
                    Some(Decision::Once | Decision::Always) => Ok(()),
                    Some(Decision::Deny) => {
                        held.remove(index);
                        Err(denied())
                    }
                    None => Err(pending()),
                };
            }
            // One person cannot bury the prompt under new requests, and the
            // whole queue has a ceiling as well. Either way the teammate is
            // told to wait rather than having more requests held.
            let waiting = held.iter().filter(|request| request.decision.is_none());
            let theirs = waiting
                .clone()
                .filter(|request| {
                    request.checkout == principal.checkout_id
                        && request.person == principal.person.id
                })
                .count();
            if theirs >= MAX_PENDING_PER_PERSON || waiting.count() >= MAX_PENDING {
                return Err(busy());
            }
            held.push(Request {
                id: super::publications::opaque("approval"),
                checkout: principal.checkout_id.clone(),
                organization: principal.organization_id.clone(),
                repository: principal.repository_id.clone(),
                person: principal.person.id.clone(),
                person_name: principal.person.name.chars().take(120).collect(),
                message: message.to_string(),
                digest: digest.to_string(),
                preview: preview(text),
                created_at_ms: now_ms(),
                decision: None,
            });
            Err(pending())
        }
    }
}

/// Records the publisher's answer to one held request, and says whose it was.
fn decide(id: &str, decision: Decision) -> Result<(String, String), DispatchError> {
    let mut held = requests();
    let request = held
        .iter_mut()
        .find(|request| request.id == id && request.decision.is_none())
        .ok_or_else(|| {
            DispatchError::new(
                "team_agent_request_gone",
                "This request expired or was already answered.",
            )
        })?;
    request.decision = Some(decision);
    Ok((request.checkout.clone(), request.person.clone()))
}

/// What the prompt shows. Long requests are cut with an ellipsis so the
/// sharer can see that more was asked than the prompt holds.
fn preview(text: &str) -> String {
    const LIMIT: usize = 600;
    let text = text.trim();
    if text.chars().count() <= LIMIT {
        return text.to_string();
    }
    text.chars().take(LIMIT).collect::<String>() + "…"
}

fn busy() -> DispatchError {
    DispatchError::new(
        "team_agent_requests_busy",
        "Requests are already waiting for the sharing computer. Wait for an answer before asking again.",
    )
}
fn changed_request() -> DispatchError {
    DispatchError::new(
        "invalid_ask",
        "This request changed after it was sent. Ask again to send a new one.",
    )
}
fn off() -> DispatchError {
    DispatchError::new(
        "team_agent_runs_off",
        "Agent runs are off for this project on the sharing computer.",
    )
}
fn denied() -> DispatchError {
    DispatchError::new(
        "team_agent_request_denied",
        "The sharing computer declined this run.",
    )
}
fn pending() -> DispatchError {
    DispatchError::new(
        "team_agent_approval_pending",
        "Waiting for the sharing computer to allow this run.",
    )
}
fn invalid() -> DispatchError {
    DispatchError::new(
        "invalid_request",
        "Check the agent access settings and try again.",
    )
}
fn storage() -> DispatchError {
    DispatchError::new(
        "team_agent_access_storage",
        "Agent access settings could not be read or saved. Check their storage and try again.",
    )
}
fn unavailable() -> DispatchError {
    DispatchError::new(
        "team_agent_access_unavailable",
        "Agent access is not available on this computer.",
    )
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Input {
    #[serde(default)]
    checkout: Option<String>,
    #[serde(default)]
    access: Option<Access>,
    #[serde(default)]
    request: Option<String>,
    #[serde(default)]
    decision: Option<Decision>,
}

/// The publisher's own controls, on this computer only:
/// `teams.agentAccess.get`, `.set`, `.requests` and `.decide`.
pub(super) fn call(method: &str, params: &str) -> Option<Result<Value, DispatchError>> {
    if !matches!(
        method,
        "teams.agentAccess.get"
            | "teams.agentAccess.set"
            | "teams.agentAccess.requests"
            | "teams.agentAccess.decide"
    ) {
        return None;
    }
    Some((|| {
        crate::request_context::refuse_remote("Team agent access").map_err(|_| {
            DispatchError::new("local_only", "Change agent access on the sharing computer.")
        })?;
        if params.len() > 16 * 1024 {
            return Err(invalid());
        }
        // The app's Team client adds its account receipt to every call.
        let mut body: Value = serde_json::from_str(params).map_err(|_| invalid())?;
        if let Some(object) = body.as_object_mut() {
            object.remove("_accountScope");
            object.remove("_accountSession");
        }
        let input: Input = serde_json::from_value(body).map_err(|_| invalid())?;
        match method {
            "teams.agentAccess.get" => {
                let checkout = input
                    .checkout
                    .filter(|id| valid_id(id))
                    .ok_or_else(invalid)?;
                let file = load()?;
                Ok(entry_json(file.checkouts.get(&checkout)))
            }
            "teams.agentAccess.set" => {
                let checkout = input
                    .checkout
                    .filter(|id| valid_id(id))
                    .ok_or_else(invalid)?;
                let access = input.access.ok_or_else(invalid)?;
                let file = update(&root()?, |file| {
                    let entry = file.checkouts.entry(checkout.clone()).or_default();
                    entry.access = access;
                    // Choosing again starts the list of standing approvals
                    // again, so "Off" then "Ask" never revives old ones.
                    if access != Access::Ask {
                        entry.allowed_people.clear();
                    }
                })?;
                if access != Access::Ask {
                    requests().retain(|request| request.checkout != checkout);
                }
                Ok(entry_json(file.checkouts.get(&checkout)))
            }
            "teams.agentAccess.requests" => {
                let held = requests();
                let rows: Vec<Value> = held
                    .iter()
                    .filter(|request| request.decision.is_none())
                    .map(|request| {
                        json!({"id":request.id,"checkoutId":request.checkout,
                            "organizationId":request.organization,"repositoryId":request.repository,
                            "personId":request.person,"personName":request.person_name,
                            "text":request.preview,"createdAtMs":request.created_at_ms})
                    })
                    .collect();
                Ok(json!({"requests":rows}))
            }
            _ => {
                let id = input
                    .request
                    .filter(|id| valid_id(id))
                    .ok_or_else(invalid)?;
                let decision = input.decision.ok_or_else(invalid)?;
                let (checkout, person) = decide(&id, decision)?;
                if decision == Decision::Always {
                    update(&root()?, |file| {
                        let entry = file.checkouts.entry(checkout.clone()).or_default();
                        if entry.access == Access::Ask {
                            entry.allowed_people.insert(person.clone());
                        }
                    })?;
                }
                Ok(json!({"decided":true}))
            }
        }
    })())
}

fn entry_json(entry: Option<&Entry>) -> Value {
    let entry = entry.cloned().unwrap_or_default();
    json!({"access":entry.access,"allowedPeople":entry.allowed_people.len()})
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn root() -> Result<PathBuf, DispatchError> {
    Ok(tokenstat_paths::data_dir()
        .ok_or_else(unavailable)?
        .join("team-agent-access"))
}

fn load() -> Result<File, DispatchError> {
    load_at(&root()?)
}

fn load_at(root: &Path) -> Result<File, DispatchError> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000); // FILE_FLAG_OPEN_REPARSE_POINT
    }
    let file = match options.open(root.join("settings.json")) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(File {
                version: 1,
                ..File::default()
            });
        }
        Err(_) => return Err(storage()),
    };
    let metadata = file.metadata().map_err(|_| storage())?;
    if !metadata.is_file() || metadata.len() > FILE_MAX_BYTES {
        return Err(storage());
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(storage());
        }
    }
    let mut bytes = Vec::new();
    file.take(FILE_MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| storage())?;
    if bytes.len() as u64 > FILE_MAX_BYTES {
        return Err(storage());
    }
    let file: File = serde_json::from_slice(&bytes).map_err(|_| storage())?;
    if file.version != 1 || file.checkouts.keys().any(|checkout| !valid_id(checkout)) {
        return Err(storage());
    }
    Ok(file)
}

fn update(root: &Path, change: impl FnOnce(&mut File)) -> Result<File, DispatchError> {
    let mut directory = fs::DirBuilder::new();
    directory.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        directory.mode(0o700);
    }
    directory.create(root).map_err(|_| storage())?;
    let metadata = fs::symlink_metadata(root).map_err(|_| storage())?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(storage());
    }
    let started = std::time::Instant::now();
    let _lease = loop {
        if let Some(lease) =
            crate::chat_receipts::OwnerLease::try_acquire(&root.join("settings.lock"))
                .map_err(|_| storage())?
        {
            break lease;
        }
        if started.elapsed() >= std::time::Duration::from_secs(2) {
            return Err(DispatchError::new(
                "team_agent_access_busy",
                "Another agent access change is being saved. Try again shortly.",
            ));
        }
        std::thread::sleep(std::time::Duration::from_millis(2));
    };
    // Reload under the lease so independent changes keep one another.
    let mut file = load_at(root)?;
    change(&mut file);
    let bytes = serde_json::to_vec(&file).map_err(|_| storage())?;
    if bytes.len() as u64 > FILE_MAX_BYTES {
        return Err(storage());
    }
    let mut staged = tempfile::Builder::new()
        .prefix(".settings-")
        .tempfile_in(root)
        .map_err(|_| storage())?;
    staged
        .write_all(&bytes)
        .and_then(|()| staged.as_file().sync_all())
        .map_err(|_| storage())?;
    for attempt in 0..=50 {
        match staged.persist(root.join("settings.json")) {
            Ok(_) => return Ok(file),
            Err(error)
                if cfg!(windows)
                    && error.error.kind() == std::io::ErrorKind::PermissionDenied
                    && attempt < 50 =>
            {
                staged = error.file;
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(_) => return Err(storage()),
        }
    }
    Err(storage())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_share_starts_off_and_settings_survive_a_reload() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("access");
        assert!(load_at(&root).unwrap().checkouts.is_empty());
        update(&root, |file| {
            file.checkouts
                .entry("checkout_a".into())
                .or_default()
                .access = Access::Ask;
        })
        .unwrap();
        let file = load_at(&root).unwrap();
        assert_eq!(file.checkouts["checkout_a"].access, Access::Ask);
        assert_eq!(Entry::default().access, Access::Off);
    }

    fn principal(person: &str, checkout: &str) -> TeamPrincipal {
        serde_json::from_value(serde_json::json!({
            "id": person, "name": "Ada", "deviceKey": "device", "organizationId": "org_a",
            "repositoryId": "repo_a", "checkoutId": checkout, "hostKey": "host",
            "publisherId": "publisher", "epoch": 1, "capabilities": [], "role": "contributor",
            "expiresAt": "2099-01-01T00:00:00Z"
        }))
        .unwrap()
    }
    fn code(result: Result<(), DispatchError>) -> String {
        result
            .err()
            .map(|error| error.code)
            .unwrap_or_else(|| "ok".into())
    }
    fn held(checkout: &str) -> String {
        requests()
            .iter()
            .find(|request| request.checkout == checkout && request.decision.is_none())
            .map(|request| request.id.clone())
            .unwrap()
    }

    #[test]
    fn off_refuses_on_admits_and_the_publisher_is_never_held() {
        let teammate = principal("person_b", "checkout_off");
        assert_eq!(
            code(admit_with(&Entry::default(), &teammate, "m1", "hi", "hi")),
            "team_agent_runs_off"
        );
        let on = Entry {
            access: Access::On,
            ..Entry::default()
        };
        assert_eq!(code(admit_with(&on, &teammate, "m1", "hi", "hi")), "ok");
        let publisher = principal("publisher", "checkout_off");
        assert_eq!(
            code(admit_with(&Entry::default(), &publisher, "m1", "hi", "hi")),
            "ok"
        );
    }

    #[test]
    fn ask_holds_a_request_until_it_is_allowed_once_and_keeps_it_for_retries() {
        let ask = Entry {
            access: Access::Ask,
            ..Entry::default()
        };
        let teammate = principal("person_c", "checkout_once");
        assert_eq!(
            code(admit_with(&ask, &teammate, "m1", "fix it", "fix it")),
            "team_agent_approval_pending"
        );
        // Sending the same request again does not stack a second prompt.
        assert_eq!(
            code(admit_with(&ask, &teammate, "m1", "fix it", "fix it")),
            "team_agent_approval_pending"
        );
        assert_eq!(
            requests()
                .iter()
                .filter(|request| request.checkout == "checkout_once")
                .count(),
            1
        );
        decide(&held("checkout_once"), Decision::Once).unwrap();
        assert_eq!(
            code(admit_with(&ask, &teammate, "m1", "fix it", "fix it")),
            "ok"
        );
        assert_eq!(
            code(admit_with(&ask, &teammate, "m1", "fix it", "fix it")),
            "ok"
        );
        // Allowing once covers that request only.
        assert_eq!(
            code(admit_with(&ask, &teammate, "m2", "again", "again")),
            "team_agent_approval_pending"
        );
    }

    #[test]
    fn an_approval_does_not_carry_over_to_different_text_under_the_same_id() {
        let ask = Entry {
            access: Access::Ask,
            ..Entry::default()
        };
        let teammate = principal("person_f", "checkout_swap");
        assert_eq!(
            code(admit_with(
                &ask,
                &teammate,
                "m1",
                "digest_a",
                "fix the test"
            )),
            "team_agent_approval_pending"
        );
        decide(&held("checkout_swap"), Decision::Once).unwrap();
        assert_eq!(
            code(admit_with(
                &ask,
                &teammate,
                "m1",
                "digest_b",
                "delete everything"
            )),
            "invalid_ask"
        );
        // The swapped request also cost the approval it tried to borrow.
        assert_eq!(
            code(admit_with(
                &ask,
                &teammate,
                "m1",
                "digest_a",
                "fix the test"
            )),
            "team_agent_approval_pending"
        );
    }

    #[test]
    fn one_person_cannot_hold_more_than_three_requests() {
        let ask = Entry {
            access: Access::Ask,
            ..Entry::default()
        };
        let teammate = principal("person_g", "checkout_flood");
        for message in ["m1", "m2", "m3"] {
            assert_eq!(
                code(admit_with(&ask, &teammate, message, message, "go")),
                "team_agent_approval_pending"
            );
        }
        assert_eq!(
            code(admit_with(&ask, &teammate, "m4", "m4", "go")),
            "team_agent_requests_busy"
        );
        // A request already held still answers as waiting, not busy.
        assert_eq!(
            code(admit_with(&ask, &teammate, "m1", "m1", "go")),
            "team_agent_approval_pending"
        );
    }

    #[test]
    fn a_long_request_is_marked_as_cut_in_the_prompt() {
        assert_eq!(preview("  short  "), "short");
        let long = "x".repeat(700);
        let shown = preview(&long);
        assert!(shown.ends_with('…') && shown.chars().count() == 601);
    }

    #[test]
    fn a_denied_request_is_refused_once_and_cannot_be_answered_twice() {
        let ask = Entry {
            access: Access::Ask,
            ..Entry::default()
        };
        let teammate = principal("person_d", "checkout_deny");
        assert_eq!(
            code(admit_with(&ask, &teammate, "m1", "rm -rf", "rm -rf")),
            "team_agent_approval_pending"
        );
        let id = held("checkout_deny");
        decide(&id, Decision::Deny).unwrap();
        assert!(decide(&id, Decision::Once).is_err());
        assert_eq!(
            code(admit_with(&ask, &teammate, "m1", "rm -rf", "rm -rf")),
            "team_agent_request_denied"
        );
        // A new attempt asks again rather than inheriting the refusal.
        assert_eq!(
            code(admit_with(&ask, &teammate, "m1", "rm -rf", "rm -rf")),
            "team_agent_approval_pending"
        );
    }

    #[test]
    fn a_person_allowed_always_is_admitted_without_a_prompt() {
        let mut ask = Entry {
            access: Access::Ask,
            ..Entry::default()
        };
        ask.allowed_people.insert("person_e".into());
        let teammate = principal("person_e", "checkout_always");
        assert_eq!(code(admit_with(&ask, &teammate, "m9", "go", "go")), "ok");
        assert!(
            requests()
                .iter()
                .all(|request| request.checkout != "checkout_always")
        );
    }

    #[test]
    fn a_file_from_a_newer_version_or_with_a_bad_id_is_refused() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(
            temp.path().join("settings.json"),
            r#"{"version":2,"checkouts":{}}"#,
        )
        .unwrap();
        assert!(load_at(temp.path()).is_err());
        fs::write(
            temp.path().join("settings.json"),
            r#"{"version":1,"checkouts":{"../x":{"access":"on"}}}"#,
        )
        .unwrap();
        assert!(load_at(temp.path()).is_err());
    }
}
