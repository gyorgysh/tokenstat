// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{
    api_error,
    publications::{self, ChatShare, ChatTarget, Owner, Phase, Store},
    sharing,
};
use crate::{account_session::AccountSnapshot, error::DispatchError};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokenstat_sync::teams::{Page, Repository, Revision, TeamClient, TeamError};

pub(super) enum Request {
    Options(List),
    List(List),
    Preview(Target),
    Publish(Publish),
    Withdraw(Withdraw),
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct List {
    organization: String,
    repository: String,
    checkout: String,
    #[serde(default)]
    page: Page,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Target {
    organization: String,
    repository: String,
    checkout: String,
    conversation: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Publish {
    organization: String,
    repository: String,
    checkout: String,
    conversation: String,
    preview: String,
    request_id: String,
    confirm_history: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Withdraw {
    organization: String,
    repository: String,
    checkout: String,
    share: String,
    expected_revision: u64,
}
fn invalid() -> DispatchError {
    api_error(TeamError::InvalidRequest)
}
fn changed() -> DispatchError {
    DispatchError::new(
        "chat_sharing_changed",
        "This chat's sharing changed. Review it again.",
    )
}
fn identifier(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}
fn identifiers(values: [&str; 3]) -> Result<(), DispatchError> {
    if values.into_iter().all(identifier) {
        Ok(())
    } else {
        Err(invalid())
    }
}
pub(super) fn parse(method: &str, body: Value) -> Option<Result<Request, DispatchError>> {
    if !matches!(
        method,
        "teams.chat.options"
            | "teams.chat.list"
            | "teams.chat.preview"
            | "teams.chat.publish"
            | "teams.chat.withdraw"
    ) {
        return None;
    }
    Some((|| match method {
        "teams.chat.options" | "teams.chat.list" => {
            let value: List = serde_json::from_value(body).map_err(|_| invalid())?;
            identifiers([&value.organization, &value.repository, &value.checkout])?;
            value.page.validate().map_err(api_error)?;
            Ok(if method == "teams.chat.options" {
                Request::Options(value)
            } else {
                Request::List(value)
            })
        }
        "teams.chat.preview" => {
            let value: Target = serde_json::from_value(body).map_err(|_| invalid())?;
            identifiers([&value.organization, &value.repository, &value.checkout])?;
            Ok(Request::Preview(value))
        }
        "teams.chat.publish" => {
            let value: Publish = serde_json::from_value(body).map_err(|_| invalid())?;
            identifiers([&value.organization, &value.repository, &value.checkout])?;
            if !value.confirm_history
                || !crate::chat_receipts::valid_id(&value.request_id)
                || value.preview.len() != 64
                || !value.preview.bytes().all(|byte| byte.is_ascii_hexdigit())
            {
                return Err(invalid());
            }
            Ok(Request::Publish(value))
        }
        "teams.chat.withdraw" => {
            let value: Withdraw = serde_json::from_value(body).map_err(|_| invalid())?;
            identifiers([&value.organization, &value.repository, &value.checkout])?;
            if !value.share.strip_prefix("share_").is_some_and(|suffix| {
                suffix.len() == 32 && suffix.bytes().all(|byte| byte.is_ascii_hexdigit())
            }) || value.expected_revision == 0
                || value.expected_revision > 9_007_199_254_740_991
            {
                return Err(invalid());
            }
            Ok(Request::Withdraw(value))
        }
        _ => Err(invalid()),
    })())
}
struct Review {
    checkout: publications::Checkout,
    repository: Repository,
    history: crate::chat::sharing::History,
    preview: String,
}
fn target<'a>(binding: &'a Owner, request: &'a Target) -> ChatTarget<'a> {
    ChatTarget {
        owner: binding,
        organization: &request.organization,
        repository: &request.repository,
        checkout: &request.checkout,
    }
}
fn review(
    owner: &AccountSnapshot,
    client: &TeamClient,
    request: &Target,
) -> Result<Review, DispatchError> {
    let (binding, local, repository, cloud_revision) = review_context(owner, client, request)?;
    finish_review(owner, request, binding, local, repository, cloud_revision)
}
pub(super) fn local_checkout(
    owner: &AccountSnapshot,
    client: &TeamClient,
    organization: &str,
    repository: &str,
    checkout: &str,
) -> Result<publications::Checkout, DispatchError> {
    let target = Target {
        organization: organization.into(),
        repository: repository.into(),
        checkout: checkout.into(),
        conversation: String::new(),
    };
    Ok(review_context(owner, client, &target)?.1)
}
fn review_context(
    owner: &AccountSnapshot,
    client: &TeamClient,
    request: &Target,
) -> Result<(Owner, publications::Checkout, Repository, u64), DispatchError> {
    let binding = sharing::binding_features(
        client,
        &[
            "checkout-publication",
            "chat-publication",
            "scoped-connections",
        ],
    )?;
    let repository = sharing::repository(client, &request.organization, &request.repository)?;
    let local = Store::capture()?.resolve(
        &binding,
        &request.organization,
        &request.repository,
        &request.checkout,
    )?;
    let workspace = crate::workspaces::get(&local.workspace_id).map_err(|_| changed())?;
    if publications::Folder::capture(&workspace.path)? != local.folder {
        return Err(changed());
    }
    let published = client
        .checkout_publication(&request.organization, &request.checkout)
        .map_err(api_error)?
        .checkout;
    if published.id != local.id
        || published.organization_id != local.organization_id
        || published.repository_id != local.repository_id
        || published.publisher_id != binding.publisher_id
        || published.host_key != binding.host_key
    {
        return Err(api_error(TeamError::InvalidResponse));
    }
    owner.ensure_current().map_err(super::changed)?;
    Ok((binding, local, repository, published.revision))
}
fn finish_review(
    owner: &AccountSnapshot,
    request: &Target,
    binding: Owner,
    local: publications::Checkout,
    repository: Repository,
    cloud_revision: u64,
) -> Result<Review, DispatchError> {
    let history =
        crate::chat::shared().sharing_history(&local.workspace_id, &request.conversation)?;
    let receipt = json!({"v":1,"account":owner.id,"owner":binding,"organization":request.organization,"repository":repository.id,"repositoryRevision":repository.revision,
        "checkout":local.id,"publicationRevision":local.revision,"cloudRevision":cloud_revision,"conversation":request.conversation,"history":history.fingerprint,"sourceRevision":history.source_revision});
    let preview = tokenstat_identity::hex(&Sha256::digest(
        serde_json::to_vec(&receipt).map_err(|_| invalid())?,
    ));
    Ok(Review {
        checkout: local,
        repository,
        history,
        preview,
    })
}
fn publication_dto(row: &ChatShare) -> Value {
    json!({"id":row.id,"checkoutId":row.checkout_id,"revision":row.revision})
}
pub(super) fn perform(
    owner: &AccountSnapshot,
    client: &TeamClient,
    request: Request,
) -> Result<Value, DispatchError> {
    match request {
        Request::Options(request) => {
            let source = Target {
                organization: request.organization,
                repository: request.repository,
                checkout: request.checkout,
                conversation: String::new(),
            };
            let (_, checkout, _, _) = review_context(owner, client, &source)?;
            let rows = crate::chat::shared().list(&checkout.workspace_id);
            let start = request.page.offset as usize;
            let count = request.page.limit as usize;
            let chats:Vec<_>=rows.iter().skip(start).take(count).map(|chat| json!({"id":chat.id,"title":chat.title,"backend":chat.backend,"shared":chat.team_share.is_some()})).collect();
            Ok(json!({"chats":chats,"nextOffset":(rows.len()>start+count).then_some(start+count)}))
        }
        Request::List(request) => {
            let binding = sharing::local_binding(owner, client)?;
            let target = ChatTarget {
                owner: &binding,
                organization: &request.organization,
                repository: &request.repository,
                checkout: &request.checkout,
            };
            let rows = Store::capture()?.local_chats(&target)?;
            let start = request.page.offset as usize;
            let count = request.page.limit as usize;
            let rows: Vec<_> = rows
                .iter()
                .filter(|row| row.phase != Phase::Withdrawn || !row.cloud_withdrawn)
                .collect();
            let publications:Vec<_>=rows.iter().skip(start).take(count).map(|row| json!({"id":row.id,"checkoutId":row.checkout_id,"conversationId":row.conversation_id,"phase":row.phase,"revision":row.revision,"accountCleanupPending":row.phase==Phase::Withdrawn && !row.cloud_withdrawn})).collect();
            Ok(
                json!({"publications":publications,"nextOffset":(rows.len()>start+count).then_some(start+count)}),
            )
        }
        Request::Preview(request) => {
            let review = review(owner, client, &request)?;
            Ok(
                json!({"conversation":request.conversation,"checkoutId":review.checkout.id,"repository":review.repository,
                "deviceName":tokenstat_identity::machine_label(),"history":review.history,"preview":review.preview,
                "audience":"currentAndFutureRepositoryMembers","allowsAgentRuns":false}),
            )
        }
        Request::Publish(input) => publish(owner, client, input),
        Request::Withdraw(request) => {
            let binding = sharing::local_binding(owner, client)?;
            let target = ChatTarget {
                owner: &binding,
                organization: &request.organization,
                repository: &request.repository,
                checkout: &request.checkout,
            };
            let store = Store::capture()?;
            let parent = store.local_chat_checkout(&target)?;
            let previous = store.local_chat(&target, &request.share)?;
            let retired =
                store.withdraw_chat(&target, &request.share, request.expected_revision)?;
            crate::chat::shared().clear_sharing(
                &parent.workspace_id,
                &retired.conversation_id,
                &retired.id,
            )?;
            if previous.cloud_withdrawn {
                return Ok(json!({"withdrawn":true}));
            }
            // Missing is not a withdrawal receipt: an earlier POST may still
            // commit after a timeout. Reserve a terminal cloud tombstone with
            // expectedRevision 0, or delete the exact observed live revision.
            // One revision race gets a fresh read; no publish is replayed.
            for _ in 0..2 {
                let revision = match client.chat_publication(
                    &request.organization,
                    &request.checkout,
                    &retired.id,
                ) {
                    Ok(value)
                        if value.share.id == retired.id
                            && value.share.checkout_id == retired.checkout_id =>
                    {
                        value.share.revision
                    }
                    Err(TeamError::Rejected {
                        status: 404, code, ..
                    }) if code == "not_found" => 0,
                    _ => break,
                };
                match client.withdraw_chat(
                    &request.organization,
                    &request.checkout,
                    &retired.id,
                    Revision {
                        expected_revision: revision,
                    },
                ) {
                    Ok(value) if value.withdrawn => {
                        store.confirm_chat_withdrawal(&target, &retired.id)?;
                        return Ok(json!({"withdrawn":true}));
                    }
                    Err(TeamError::Rejected {
                        status: 409, code, ..
                    }) if code == "revision_conflict" => continue,
                    _ => break,
                }
            }
            Ok(json!({"withdrawn":true,"accountCleanupPending":true}))
        }
    }
}

/// Share one local chat with the repository, from a reviewed preview.
fn publish(
    owner: &AccountSnapshot,
    client: &TeamClient,
    input: Publish,
) -> Result<Value, DispatchError> {
    publish_if_current(owner, client, input, &|| {
        owner.ensure_current().map_err(super::changed)
    })
}

fn publish_if_current(
    owner: &AccountSnapshot,
    client: &TeamClient,
    input: Publish,
    current: &dyn Fn() -> Result<(), DispatchError>,
) -> Result<Value, DispatchError> {
    current()?;
    let request = Target {
        organization: input.organization,
        repository: input.repository,
        checkout: input.checkout,
        conversation: input.conversation,
    };
    let (binding, checkout, repository, cloud_revision) = review_context(owner, client, &request)?;
    let store = Store::capture()?;
    let target = target(&binding, &request);
    // Repeating an accepted publication settles its original receipt;
    // later shared messages must not turn it into a new publication.
    if let Some(previous) = store.chat_request(&target, &input.request_id)?
        && previous.phase == Phase::Active
    {
        if previous.conversation_id != request.conversation {
            return Err(changed());
        }
        crate::chat::shared().shared_chat_index(
            &checkout.workspace_id,
            &previous.conversation_id,
            &previous.id,
            &previous.preview,
        )?;
        let current = client
            .chat_publication(&request.organization, &request.checkout, &previous.id)
            .map_err(api_error)?
            .share;
        if current.id != previous.id
            || current.checkout_id != previous.checkout_id
            || Some(current.revision) != previous.cloud_revision
        {
            return Err(changed());
        }
        return Ok(
            json!({"publication":publication_dto(&store.resolve_chat(&target,&previous.id)?)}),
        );
    }
    let review = finish_review(
        owner,
        &request,
        binding.clone(),
        checkout,
        repository,
        cloud_revision,
    )?;
    if review.preview != input.preview {
        return Err(DispatchError::new(
            "chat_history_changed",
            "This chat changed after its sharing preview. Review the history again.",
        ));
    }
    current()?;
    let prepared = store.prepare_chat_at_revision(
        &target,
        &request.conversation,
        &input.request_id,
        &review.history.fingerprint,
        review.history.source_revision,
    )?;
    let chats = crate::chat::shared();
    if let Err(error) = chats.freeze_sharing_if_current(
        &review.checkout.workspace_id,
        &request.conversation,
        &prepared.id,
        &review.history.fingerprint,
        review.history.source_revision,
        || {
            current()?;
            let row = store
                .chat_request(&target, &input.request_id)?
                .ok_or_else(changed)?;
            if row.id != prepared.id
                || row.conversation_id != request.conversation
                || row.preview != review.history.fingerprint
                || row.source_revision != Some(review.history.source_revision)
                || row.phase == Phase::Withdrawn
            {
                return Err(changed());
            }
            Ok(())
        },
    ) {
        if matches!(
            error.code.as_str(),
            "chat_history_changed" | "chat_already_shared" | "chat_running"
        ) {
            let _ = store.withdraw_chat(&target, &prepared.id, prepared.revision);
        }
        return Err(error);
    }
    owner.ensure_current().map_err(super::changed)?;
    current()?;
    let published = client
        .publish_chat(&request.organization, &request.checkout, &prepared.id, true)
        .map_err(api_error)?
        .share;
    if published.id != prepared.id
        || published.checkout_id != prepared.checkout_id
        || published.revision == 0
    {
        return Err(api_error(TeamError::InvalidResponse));
    }
    owner.ensure_current().map_err(super::changed)?;
    current()?;
    store.activate_chat(&target, &prepared.id, prepared.revision, published.revision)?;
    Ok(json!({"publication":publication_dto(&store.resolve_chat(&target,&prepared.id)?)}))
}

/// A member with permission to run agents here starts a fresh chat on this
/// computer. It is created empty, with no persona, and shared with the
/// repository like any other, so the Ask that follows is about nothing the
/// publisher had not already chosen to share.
/// What a member asked for, from their checkout-scoped Run proof.
pub(super) struct NewChat<'a> {
    pub organization: &'a str,
    pub repository: &'a str,
    pub checkout: &'a str,
    pub title: &'a str,
    pub request_id: &'a str,
    pub person: &'a str,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct NewChatInput {
    pub title: String,
    pub request_id: String,
}
pub(super) fn new_chat_input(params: &str) -> Result<NewChatInput, DispatchError> {
    if params.len() > 2048 {
        return Err(invalid());
    }
    let mut input: NewChatInput = serde_json::from_str(params).map_err(|_| invalid())?;
    input.title = input.title.trim().to_owned();
    if input.title.is_empty()
        || input.title.chars().count() > 120
        || input.title.chars().any(char::is_control)
        || !crate::chat_receipts::valid_id(&input.request_id)
    {
        return Err(invalid());
    }
    Ok(input)
}

/// An account-authenticated request made on the publishing computer may
/// create an empty chat there. This neither starts an agent nor grants Run
/// access to this device or anyone else. Other computers keep the Run proof
/// requirement. The full publication/role/folder checks run again below.
pub(super) fn start_for_owner(
    owner: &AccountSnapshot,
    client: &TeamClient,
    organization: &str,
    repository: &str,
    checkout: &str,
    params: &str,
) -> Result<Option<Value>, DispatchError> {
    let binding = sharing::local_binding(owner, client)?;
    let store = Store::capture()?;
    if !store.list(&binding)?.iter().any(|row| {
        row.id == checkout
            && row.organization_id == organization
            && row.repository_id == repository
            && row.phase == Phase::Active
    }) {
        return Ok(None);
    }
    let input = new_chat_input(params)?;
    start_for_member(
        owner,
        client,
        NewChat {
            organization,
            repository,
            checkout,
            title: &input.title,
            request_id: &input.request_id,
            person: &binding.publisher_id,
        },
        &|| owner.ensure_current().map_err(super::changed),
    )
    .map(Some)
}
pub(super) fn start_for_member(
    owner: &AccountSnapshot,
    client: &TeamClient,
    asked: NewChat<'_>,
    current: &dyn Fn() -> Result<(), DispatchError>,
) -> Result<Value, DispatchError> {
    current()?;
    let NewChat {
        organization,
        repository,
        checkout,
        title,
        request_id,
        person,
    } = asked;
    identifiers([organization, repository, checkout])?;
    let source = Target {
        organization: organization.into(),
        repository: repository.into(),
        checkout: checkout.into(),
        conversation: String::new(),
    };
    let (binding, local, _, _) = review_context(owner, client, &source)?;
    let store = Store::capture()?;
    let _request = store.new_chat_lease(&target(&binding, &source), request_id)?;
    // A timed-out cloud publication keeps its original conversation and
    // request. Creating another conversation would conflict with that saved
    // request forever, and would spend another rate-limit slot on each retry.
    let previous = store.chat_request(&target(&binding, &source), request_id)?;
    if let Some(previous) = &previous
        && previous.phase == Phase::Active
    {
        current()?;
        return Ok(json!({"share":previous.id}));
    }
    let chats = crate::chat::shared();
    let (chat, created) = new_chat_conversation(
        &chats,
        &local.workspace_id,
        title,
        previous.as_ref(),
        current,
        || admit_new_chat(person, checkout),
    )?;
    let request = Target {
        conversation: chat.id.clone(),
        ..source
    };
    let original_revision = previous
        .as_ref()
        .map_or(Some(chat.send_revision), |row| row.source_revision)
        .ok_or_else(changed)?;
    let shared = review(owner, client, &request).and_then(|review| {
        require_empty_new_chat(&review.history, original_revision)?;
        publish_if_current(
            owner,
            client,
            Publish {
                organization: request.organization.clone(),
                repository: request.repository.clone(),
                checkout: request.checkout.clone(),
                conversation: chat.id.clone(),
                preview: review.preview,
                request_id: request_id.into(),
                confirm_history: true,
            },
            current,
        )
    });
    match shared {
        Ok(value) => Ok(json!({"share":value["publication"]["id"]})),
        Err(error) => {
            // A prepared record may already be committed remotely even when
            // its reply was lost. Keep the matching source for idempotent
            // recovery instead of deleting it or creating a replacement.
            let owns_source = store
                .chat_request(&target(&binding, &request), request_id)
                .map(|saved| saved.is_some_and(|row| row.conversation_id == chat.id));
            if created && matches!(owns_source, Ok(false)) {
                let _ = chats.remove_untouched_empty(&chat.id, chat.send_revision);
            }
            Err(error)
        }
    }
}

/// The account lookups and publication locks above can outlive a short member
/// lease. Check it again at the local creation boundary, before making a chat.
fn new_chat_conversation(
    chats: &crate::chat::Store,
    workspace: &str,
    title: &str,
    previous: Option<&ChatShare>,
    current: &dyn Fn() -> Result<(), DispatchError>,
    admit: impl FnOnce() -> Result<(), DispatchError>,
) -> Result<(crate::chat::Conversation, bool), DispatchError> {
    current()?;
    if let Some(previous) = previous {
        if previous.phase != Phase::Prepared {
            return Err(changed());
        }
        let chat = chats
            .list(workspace)
            .into_iter()
            .find(|chat| chat.id == previous.conversation_id)
            .ok_or_else(changed)?;
        return Ok((chat, false));
    }
    admit()?;
    current()?;
    chats
        .create(crate::chat::Create {
            workspace_id: workspace.into(),
            title: Some(title.into()),
            backend: "claude".into(),
            persona_id: Some(String::new()),
            ..Default::default()
        })
        .map(|chat| (chat, true))
        .map_err(|_| changed())
}

/// A member requested a fresh, empty chat, not permission to share private
/// messages the physical owner may have added while account lookups ran.
/// The publication preview and canonical freeze bind this exact revision too.
fn require_empty_new_chat(
    history: &crate::chat::sharing::History,
    revision: u64,
) -> Result<(), DispatchError> {
    if history.history_bytes != 0 || history.source_revision != revision {
        return Err(DispatchError::new(
            "chat_history_changed",
            "This chat changed before sharing. Its local history has been kept private.",
        ));
    }
    Ok(())
}

/// A Run proof lives for minutes, so one person could otherwise fill this
/// computer with empty chats before it expires. Ten an hour per person and
/// checkout is more than anyone starts by hand.
fn admit_new_chat(person: &str, checkout: &str) -> Result<(), DispatchError> {
    use std::{
        collections::HashMap,
        sync::Mutex,
        time::{Duration, Instant},
    };
    const PER_HOUR: usize = 10;
    type Started = HashMap<(String, String), Vec<Instant>>;
    static STARTED: Mutex<Option<Started>> = Mutex::new(None);
    let mut started = STARTED.lock().map_err(|_| changed())?;
    let started = started.get_or_insert_with(HashMap::new);
    let hour = Duration::from_secs(3600);
    started.retain(|_, times| {
        times.retain(|at| at.elapsed() < hour);
        !times.is_empty()
    });
    let times = started
        .entry((person.to_string(), checkout.to_string()))
        .or_default();
    if times.len() >= PER_HOUR {
        return Err(DispatchError::new(
            "team_new_chat_limit",
            "You started several chats on this computer in the last hour. Use one of them, or try again later.",
        ));
    }
    times.push(Instant::now());
    Ok(())
}

#[cfg(test)]
mod new_chat_tests {
    fn saved_empty_chat() -> (
        tempfile::TempDir,
        crate::chat::Store,
        crate::chat::Conversation,
    ) {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("chats");
        std::fs::create_dir(&directory).unwrap();
        let original: crate::chat::Conversation = serde_json::from_value(serde_json::json!({
            "id": "chat_fixture", "workspaceId": "workspace", "title": "Original chat",
            "backend": "claude", "createdAtMs": 1, "updatedAtMs": 1,
        }))
        .unwrap();
        std::fs::write(
            directory.join("conversations.json"),
            serde_json::to_vec(&serde_json::json!({"conversations": [original]})).unwrap(),
        )
        .unwrap();
        let chats = crate::chat::Store::at(directory);
        chats.refresh_index().unwrap();
        (root, chats, original)
    }
    #[test]
    fn empty_chat_input_cannot_carry_a_private_source_or_agent_request() {
        let valid =
            serde_json::json!({"title":"  Fictional project chat  ","requestId":"new-fixture"});
        let input = super::new_chat_input(&valid.to_string()).unwrap();
        assert_eq!(input.title, "Fictional project chat");
        assert_eq!(input.request_id, "new-fixture");
        for field in [
            "conversation",
            "workspace",
            "backend",
            "text",
            "person",
            "grant",
        ] {
            let mut input = valid.clone();
            input[field] = serde_json::json!("private-or-forged");
            assert!(super::new_chat_input(&input.to_string()).is_err());
        }
        for title in [
            "".to_owned(),
            "  ".into(),
            "chat\nprivate".into(),
            "a".repeat(121),
        ] {
            let mut input = valid.clone();
            input["title"] = serde_json::json!(title);
            assert!(super::new_chat_input(&input.to_string()).is_err());
        }
    }
    #[test]
    fn expired_member_cannot_create_a_chat_after_review_lookups() {
        let root = tempfile::tempdir().unwrap();
        let chats = crate::chat::Store::at(root.path().join("chats"));
        let error = super::new_chat_conversation(
            &chats,
            "reviewed-workspace",
            "Shared chat",
            None,
            &|| {
                Err(crate::error::DispatchError::new(
                    "team_access_expired",
                    "The member's reviewed authority expired during account lookups.",
                ))
            },
            || panic!("an expired request cannot spend an admission slot"),
        )
        .unwrap_err();
        assert_eq!(error.code, "team_access_expired");
        assert!(chats.list("reviewed-workspace").is_empty());
        assert!(!root.path().join("chats/conversations.json").exists());
    }

    #[test]
    fn retrying_a_prepared_new_chat_reuses_its_source_without_another_admission() {
        let (_root, chats, original) = saved_empty_chat();
        let mut previous = super::ChatShare {
            id: format!("share_{}", "ab".repeat(16)),
            checkout_id: "checkout".into(),
            conversation_id: original.id.clone(),
            request_id: "original-request".into(),
            preview: "ab".repeat(32),
            phase: super::Phase::Prepared,
            revision: 1,
            cloud_revision: None,
            cloud_withdrawn: false,
            source_revision: Some(0),
        };
        for _ in 0..12 {
            let (retried, created) = super::new_chat_conversation(
                &chats,
                "workspace",
                "Retry title",
                Some(&previous),
                &|| Ok(()),
                || panic!("a retry cannot spend another admission slot"),
            )
            .unwrap();
            assert_eq!(retried.id, original.id);
            assert_eq!(retried.title, "Original chat");
            assert!(!created);
        }
        assert_eq!(chats.list("workspace").len(), 1);
        previous.phase = super::Phase::Withdrawn;
        assert!(
            super::new_chat_conversation(
                &chats,
                "workspace",
                "Retry title",
                Some(&previous),
                &|| Ok(()),
                || Ok(()),
            )
            .is_err(),
            "a retired request cannot create a replacement chat"
        );
    }

    #[test]
    fn automatic_empty_chat_publication_never_adopts_private_edits_or_deletes_them() {
        let (root, chats, original) = saved_empty_chat();
        let mut history = chats.sharing_history("workspace", &original.id).unwrap();
        assert!(super::require_empty_new_chat(&history, 0).is_ok());
        history.source_revision = 1;
        assert!(super::require_empty_new_chat(&history, 0).is_err());
        let directory = root.path().join("chats").join(&original.id);
        std::fs::create_dir(&directory).unwrap();
        let private =
            b"{\"kind\":\"user\",\"text\":\"Private local note\",\"at_ms\":2,\"seq\":0}\n";
        std::fs::write(directory.join("events.ndjson"), private).unwrap();
        let history = chats.sharing_history("workspace", &original.id).unwrap();
        assert_eq!(
            super::require_empty_new_chat(&history, 0).unwrap_err().code,
            "chat_history_changed"
        );
        assert!(chats.remove_untouched_empty(&original.id, 0).is_err());
        assert_eq!(chats.list("workspace").len(), 1);
        assert_eq!(
            std::fs::read(directory.join("events.ndjson")).unwrap(),
            private
        );
        let (_root, untouched, original) = saved_empty_chat();
        assert!(untouched.remove_untouched_empty(&original.id, 0).unwrap());
        assert!(untouched.list("workspace").is_empty());
    }

    #[test]
    fn new_chats_are_capped_per_person_and_checkout() {
        for _ in 0..10 {
            assert!(super::admit_new_chat("cap-person", "cap-checkout").is_ok());
        }
        let refused = super::admit_new_chat("cap-person", "cap-checkout").unwrap_err();
        assert_eq!(refused.code, "team_new_chat_limit");
        assert!(super::admit_new_chat("cap-person", "other-checkout").is_ok());
        assert!(super::admit_new_chat("other-person", "cap-checkout").is_ok());
    }
}
