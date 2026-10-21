// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;

fn principal(role: &str, comment: bool, person: &str, device: char) -> AuthorizedTeamPrincipal {
    AuthorizedTeamPrincipal::storage_fixture(serde_json::from_value(json!({
        "id":person,"name":"Example member","handle":"example-member","avatar":null,
        "deviceKey":device.to_string().repeat(64),"organizationId":"org_fixture","repositoryId":"repo_fixture",
        "checkoutId":"checkout_fixture","hostKey":"b".repeat(64),"publisherId":"fixture-owner",
        "shareId":format!("share_{}", "a".repeat(32)),"grantId":null,"epoch":1,
        "capabilities":if comment {json!(["read","comment"])} else {json!(["read"])},
        "role":role,"expiresAt":"2026-12-01T00:00:00Z"
    })).unwrap())
}
fn fixture() -> (tempfile::TempDir, Store, Conversation, String) {
    let (root, store, chat) = super::super::tests::fixture();
    let preview = store
        .sharing_history(&chat.workspace_id, &chat.id)
        .unwrap()
        .fingerprint;
    store
        .freeze_sharing(
            &chat.workspace_id,
            &chat.id,
            &format!("share_{}", "a".repeat(32)),
            &preview,
        )
        .unwrap();
    (root, store, chat, preview)
}
fn target<'a>(chat: &'a Conversation, preview: &'a str) -> SharedSource<'a> {
    SharedSource {
        workspace: &chat.workspace_id,
        id: &chat.id,
        preview,
        revision: Some(chat.send_revision),
    }
}
fn input(id: &str) -> CommentInput {
    CommentInput {
        text: "A fictional comment".into(),
        client_message_id: id.into(),
        client_message_created_at_ms: now_ms(),
    }
}
fn accepted(value: &Value) {
    assert_eq!(value["receipt"]["state"], "accepted");
}

#[test]
fn canonical_comments_use_the_verified_person_and_survive_retries_across_devices() {
    let (_root, store, chat, preview) = fixture();
    let request = input("message_fixture");
    let actor = principal("contributor", true, "fixture-member", 'a');
    accepted(
        &store
            .team_comment(target(&chat, &preview), &actor, &request, || Ok(()))
            .unwrap(),
    );
    let second_device = principal("contributor", true, "fixture-member", 'c');
    accepted(
        &store
            .team_comment(target(&chat, &preview), &second_device, &request, || Ok(()))
            .unwrap(),
    );
    let history = store
        .shared_history(
            &chat.workspace_id,
            &chat.id,
            actor.value().share_id.as_deref().unwrap(),
            &preview,
        )
        .unwrap();
    assert_eq!(history.events.len(), 1);
    assert_eq!(history.events[0]["author"]["id"], "fixture-member");
    assert_eq!(history.events[0]["mode"], "comment");
    let public = serde_json::to_string(&history).unwrap();
    for field in [
        "deviceKey",
        "teamComment",
        "workspace_fixture",
        "org_fixture",
        "requestDigest",
        "clientMessageId",
    ] {
        assert!(!public.contains(field), "{field}");
    }
    let mut changed = request.clone();
    changed.text.push('x');
    assert_eq!(
        store
            .team_comment(target(&chat, &preview), &actor, &changed, || Ok(()))
            .unwrap_err()
            .code,
        "team_comment_conflict"
    );
    let other_person = principal("contributor", true, "fixture-other", 'd');
    assert_eq!(
        store
            .team_comment_status(
                &chat.workspace_id,
                &chat.id,
                &preview,
                &other_person,
                &request.client_message_id
            )
            .unwrap()["receipt"]["state"],
        "unknown"
    );
    accepted(
        &store
            .team_comment(target(&chat, &preview), &other_person, &request, || Ok(()))
            .unwrap(),
    );
    assert_eq!(
        store
            .shared_history(
                &chat.workspace_id,
                &chat.id,
                actor.value().share_id.as_deref().unwrap(),
                &preview
            )
            .unwrap()
            .events
            .len(),
        2
    );
}

#[test]
fn discussion_can_append_while_a_runner_owns_the_conversation_without_sending_to_it() {
    let (_root, store, chat, preview) = fixture();
    let runner = crate::chat_receipts::RunnerLease::try_acquire(&store.root, &chat.id)
        .unwrap()
        .unwrap();
    let mut index: Index =
        serde_json::from_slice(&fs::read(store.root.join("conversations.json")).unwrap()).unwrap();
    index.conversations[0].running = true;
    index.conversations[0].team_run_fence = Some(
        crate::chat_receipts::team_runs::Fence::new(
            format!("run_{}", "12".repeat(16)),
            "34".repeat(32),
        )
        .unwrap(),
    );
    fs::write(
        store.root.join("conversations.json"),
        serde_json::to_vec(&index).unwrap(),
    )
    .unwrap();
    let actor = principal("contributor", true, "fixture-member", 'a');
    accepted(
        &store
            .team_comment(
                target(&chat, &preview),
                &actor,
                &input("discussion-during-run"),
                || Ok(()),
            )
            .unwrap(),
    );
    assert!(
        crate::chat_receipts::RunnerLease::try_acquire(&store.root, &chat.id)
            .unwrap()
            .is_none()
    );
    assert!(store.current_send_conversation(&chat.id).unwrap().running);
    assert!(store.active.lock().unwrap().is_empty());
    let history = store
        .shared_history(
            &chat.workspace_id,
            &chat.id,
            actor.value().share_id.as_deref().unwrap(),
            &preview,
        )
        .unwrap();
    assert_eq!(history.events.len(), 1);
    assert_eq!(history.events[0]["mode"], "comment");
    assert_eq!(history.events[0]["kind"], "user");
    drop(runner);
}

#[test]
fn role_and_exact_source_checks_happen_before_any_comment_is_reserved() {
    let (_root, store, chat, preview) = fixture();
    for actor in [
        principal("viewer", true, "fixture-member", 'a'),
        principal("contributor", false, "fixture-member", 'a'),
    ] {
        assert_eq!(
            store
                .team_comment(target(&chat, &preview), &actor, &input("denied"), || Ok(()))
                .unwrap_err()
                .code,
            "team_comment_forbidden"
        );
    }
    let actor = principal("contributor", true, "fixture-member", 'a');
    assert!(
        store
            .team_comment(target(&chat, &preview), &actor, &input("stale"), || Err(
                paused()
            ))
            .is_err()
    );
    assert!(
        store
            .team_comment(
                SharedSource {
                    revision: Some(99),
                    ..target(&chat, &preview)
                },
                &actor,
                &input("revision"),
                || Ok(())
            )
            .is_err()
    );
    assert!(!store.root.join(&chat.id).join(JOURNAL).exists());
    assert!(serde_json::from_value::<CommentInput>(json!({"text":"hi","clientMessageId":"forged","clientMessageCreatedAtMs":now_ms(),"actorId":"fixture-owner"})).is_err());
}

#[test]
fn interrupted_canonical_delivery_is_observed_without_duplicate_rows_or_replayed_text() {
    for step in [Step::Reserved, Step::Canonical, Step::Accepted] {
        let (_root, store, chat, preview) = fixture();
        let actor = principal("contributor", true, "fixture-member", 'a');
        let request = input("interrupted");
        assert!(
            store
                .team_comment_steps(
                    target(&chat, &preview),
                    &actor,
                    &request,
                    || Ok(()),
                    |at| {
                        if std::mem::discriminant(&at) == std::mem::discriminant(&step) {
                            Err(unavailable())
                        } else {
                            Ok(())
                        }
                    }
                )
                .is_err()
        );
        let reopened = Store::load_at(store.root.clone());
        let result = reopened
            .team_comment_status(
                &chat.workspace_id,
                &chat.id,
                &preview,
                &actor,
                &request.client_message_id,
            )
            .unwrap();
        let reserved = matches!(step, Step::Reserved);
        assert_eq!(
            result["receipt"]["state"],
            if reserved { "pending" } else { "accepted" }
        );
        let history = reopened
            .shared_history(
                &chat.workspace_id,
                &chat.id,
                actor.value().share_id.as_deref().unwrap(),
                &preview,
            )
            .unwrap();
        assert_eq!(history.events.len(), if reserved { 0 } else { 1 });
        accepted(
            &reopened
                .team_comment(target(&chat, &preview), &actor, &request, || Ok(()))
                .unwrap(),
        );
        assert_eq!(
            reopened
                .shared_history(
                    &chat.workspace_id,
                    &chat.id,
                    actor.value().share_id.as_deref().unwrap(),
                    &preview
                )
                .unwrap()
                .events
                .len(),
            1
        );
    }
}

#[test]
fn another_person_retires_a_provably_unwritten_attempt_without_reusing_it() {
    let (_root, store, chat, preview) = fixture();
    let actor = principal("contributor", true, "fixture-member", 'a');
    let first = input("unwritten");
    let _ = store.team_comment_steps(
        target(&chat, &preview),
        &actor,
        &first,
        || Ok(()),
        |at| {
            if matches!(at, Step::Reserved) {
                Err(unavailable())
            } else {
                Ok(())
            }
        },
    );
    let other = principal("contributor", true, "fixture-other", 'c');
    accepted(
        &store
            .team_comment(target(&chat, &preview), &other, &input("next"), || Ok(()))
            .unwrap(),
    );
    assert_eq!(
        store
            .team_comment(target(&chat, &preview), &actor, &first, || Ok(()))
            .unwrap()["receipt"]["state"],
        "notAccepted"
    );
}

#[test]
fn truncation_and_missing_initialized_receipts_do_not_create_fresh_acceptances() {
    let (_root, store, chat, preview) = fixture();
    let actor = principal("contributor", true, "fixture-member", 'a');
    let request = input("saved");
    accepted(
        &store
            .team_comment(target(&chat, &preview), &actor, &request, || Ok(()))
            .unwrap(),
    );
    let directory = store.root.join(&chat.id);
    let canonical = fs::read(directory.join("events.ndjson")).unwrap();
    fs::write(directory.join("events.ndjson"), b"").unwrap();
    assert!(
        store
            .shared_history(
                &chat.workspace_id,
                &chat.id,
                actor.value().share_id.as_deref().unwrap(),
                &preview
            )
            .is_err()
    );
    assert!(
        store
            .team_comment(target(&chat, &preview), &actor, &request, || Ok(()))
            .is_err()
    );
    fs::write(directory.join("events.ndjson"), canonical).unwrap();
    fs::remove_file(directory.join(JOURNAL)).unwrap();
    assert!(
        store
            .team_comment(target(&chat, &preview), &actor, &request, || Ok(()))
            .is_err()
    );
    // Local recovery still clears the canonical sharing marker.
    store
        .clear_sharing(
            &chat.workspace_id,
            &chat.id,
            actor.value().share_id.as_deref().unwrap(),
        )
        .unwrap();
    assert!(store.require_private_chat(&chat.id).is_ok());
}

#[test]
fn returning_to_private_history_keeps_verified_people_and_retires_unwritten_comments() {
    let (_root, store, chat, preview) = fixture();
    let actor = principal("contributor", true, "fixture-member", 'a');
    accepted(
        &store
            .team_comment(target(&chat, &preview), &actor, &input("first"), || Ok(()))
            .unwrap(),
    );
    let second = input("second");
    let _ = store.team_comment_steps(
        target(&chat, &preview),
        &actor,
        &second,
        || Ok(()),
        |at| {
            if matches!(at, Step::Reserved) {
                Err(unavailable())
            } else {
                Ok(())
            }
        },
    );
    store
        .clear_sharing(
            &chat.workspace_id,
            &chat.id,
            actor.value().share_id.as_deref().unwrap(),
        )
        .unwrap();
    store
        .append(
            &chat.id,
            &StoredEvent::User {
                text: "A later private message".into(),
                at_ms: now_ms(),
                steer: false,
            },
        )
        .unwrap();
    let history = store.sharing_history(&chat.workspace_id, &chat.id).unwrap();
    assert_eq!(history.events.len(), 2);
    assert_eq!(history.events[0]["author"]["id"], "fixture-member");
    assert_eq!(history.events[1]["author"]["kind"], "localBeforeTeams");
}

#[test]
fn a_fork_preserves_verified_people_even_if_an_older_client_dropped_the_journal_flag() {
    let (_root, store, chat, preview) = fixture();
    let actor = principal("contributor", true, "fixture-member", 'a');
    accepted(
        &store
            .team_comment(target(&chat, &preview), &actor, &input("copied"), || Ok(()))
            .unwrap(),
    );
    store
        .clear_sharing(
            &chat.workspace_id,
            &chat.id,
            actor.value().share_id.as_deref().unwrap(),
        )
        .unwrap();
    store
        .edit_conversation(&chat.id, |source| {
            source.team_journal_initialized = false;
            Ok(())
        })
        .unwrap();
    let fork = store.fork(&chat.id).unwrap();
    assert!(fork.team_journal_initialized);
    assert!(fork.team_share.is_none());
    let history = store.sharing_history(&fork.workspace_id, &fork.id).unwrap();
    assert_eq!(history.events.len(), 1);
    assert_eq!(history.events[0]["author"]["id"], "fixture-member");
    fs::remove_file(store.root.join(&fork.id).join(JOURNAL)).unwrap();
    assert!(store.sharing_history(&fork.workspace_id, &fork.id).is_err());
}

#[test]
fn concurrent_devices_accept_one_original_attempt_once() {
    let (_root, store, chat, preview) = fixture();
    let request = input("concurrent");
    let start = std::sync::Barrier::new(2);
    std::thread::scope(|scope| {
        let tasks: Vec<_> = ['a', 'c']
            .into_iter()
            .map(|device| {
                let (start, store, chat, preview, request) =
                    (&start, &store, &chat, &preview, &request);
                scope.spawn(move || {
                    let actor = principal("contributor", true, "fixture-member", device);
                    start.wait();
                    store
                        .team_comment(target(chat, preview), &actor, request, || Ok(()))
                        .unwrap()
                })
            })
            .collect();
        let replies: Vec<_> = tasks.into_iter().map(|task| task.join().unwrap()).collect();
        accepted(&replies[0]);
        assert_eq!(replies[0], replies[1]);
    });
    let actor = principal("contributor", true, "fixture-member", 'a');
    let history = store
        .shared_history(
            &chat.workspace_id,
            &chat.id,
            actor.value().share_id.as_deref().unwrap(),
            &preview,
        )
        .unwrap();
    assert_eq!(history.events.len(), 1);
}

#[test]
fn authority_retirement_after_reservation_never_appends_on_a_read() {
    let (_root, store, chat, preview) = fixture();
    let actor = principal("contributor", true, "fixture-member", 'a');
    let request = input("retired");
    let mut checks = 0;
    assert!(
        store
            .team_comment(target(&chat, &preview), &actor, &request, || {
                checks += 1;
                if checks == 1 { Ok(()) } else { Err(paused()) }
            })
            .is_err()
    );
    assert_eq!(
        store
            .team_comment_status(
                &chat.workspace_id,
                &chat.id,
                &preview,
                &actor,
                &request.client_message_id
            )
            .unwrap()["receipt"]["state"],
        "pending"
    );
    let downgraded = principal("viewer", false, "fixture-member", 'a');
    assert!(
        store
            .team_comment(target(&chat, &preview), &downgraded, &request, || Ok(()))
            .is_err()
    );
    assert!(
        store
            .shared_history(
                &chat.workspace_id,
                &chat.id,
                actor.value().share_id.as_deref().unwrap(),
                &preview
            )
            .unwrap()
            .events
            .is_empty()
    );
}
