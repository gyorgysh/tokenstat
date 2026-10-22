// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

pub(super) fn principal(person: &str, device: char, grant: char) -> AuthorizedTeamPrincipal {
    AuthorizedTeamPrincipal::storage_fixture(serde_json::from_value(json!({
        "id":person,"name":"Example member","handle":"example-member","avatar":null,
        "deviceKey":device.to_string().repeat(64),"organizationId":"org_fixture","repositoryId":"repo_fixture",
        "checkoutId":"checkout_fixture","hostKey":"b".repeat(64),"publisherId":"fixture-owner",
        "shareId":format!("share_{}","a".repeat(32)),"grantId":format!("grant_{}",grant.to_string().repeat(32)),
        "epoch":1,"capabilities":["read","comment","run"],"role":"contributor","expiresAt":"2026-12-01T00:00:00Z"
    })).unwrap())
}
pub(super) struct Fixture {
    root: tempfile::TempDir,
    pub(super) store: Store,
    pub(super) chat: Conversation,
    pub(super) preview: String,
    folder: PathBuf,
    checkout: String,
}
impl Fixture {
    pub(super) fn new() -> Self {
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
        let folder = root.path().join("checkout");
        fs::create_dir(&folder).unwrap();
        Self {
            root,
            store,
            chat,
            preview,
            folder,
            checkout: "12".repeat(32),
        }
    }
    pub(super) fn target(&self) -> SharedSource<'_> {
        SharedSource {
            workspace: &self.chat.workspace_id,
            id: &self.chat.id,
            preview: &self.preview,
            revision: Some(self.chat.send_revision),
        }
    }
    pub(super) fn input(&self, actor: &AuthorizedTeamPrincipal, id: &str) -> AskInput {
        AskInput {
            text: "A fictional Ask".into(),
            client_message_id: id.into(),
            client_message_created_at_ms: now_ms(),
            review: self
                .store
                .team_ask_review(
                    self.target(),
                    actor,
                    &self.folder,
                    &self.checkout,
                    || Ok(()),
                )
                .unwrap()
                .digest,
        }
    }
    pub(super) fn prepare(
        &self,
        actor: &AuthorizedTeamPrincipal,
        input: &AskInput,
    ) -> Result<AskPreparation, DispatchError> {
        self.store.prepare_team_ask(
            self.target(),
            actor,
            input,
            (&self.folder, &self.checkout, None),
            || Ok(()),
        )
    }
    pub(super) fn history(&self) -> History {
        self.store
            .shared_history(
                &self.chat.workspace_id,
                &self.chat.id,
                &format!("share_{}", "a".repeat(32)),
                &self.preview,
            )
            .unwrap()
    }
    pub(super) fn journal_bytes(&self) -> Vec<u8> {
        fs::read(self.store.root.join(&self.chat.id).join(writer::JOURNAL)).unwrap()
    }
    fn chat(&self) -> Conversation {
        self.store.current_send_conversation(&self.chat.id).unwrap()
    }
}
pub(super) fn new(value: AskPreparation) -> PreparedAsk {
    match value {
        AskPreparation::New(value) => *value,
        AskPreparation::Existing(_) => panic!("retry was not a new admission"),
    }
}
fn existing(value: AskPreparation) -> Value {
    match value {
        AskPreparation::Existing(value) => value,
        AskPreparation::New(_) => panic!("retry acquired launch ownership"),
    }
}
fn failed(value: Result<AskPreparation, DispatchError>) -> DispatchError {
    match value {
        Err(error) => error,
        Ok(_) => panic!("request unexpectedly succeeded"),
    }
}

#[test]
fn an_ask_has_one_canonical_author_and_retry_keeps_original_device_grant_and_fences() {
    let f = Fixture::new();
    let actor = principal("fixture-person", 'a', 'b');
    let input = f.input(&actor, "ask-one");
    let owned = new(f.prepare(&actor, &input).unwrap());
    assert!(owned.context.events.is_empty());
    assert_eq!(owned.context.message["text"], input.text);
    assert_eq!(owned.context.message["author"]["id"], "fixture-person");
    assert_eq!(owned.context.backend, "codex");
    assert!(!owned.context.worktree.repository);
    assert_eq!(f.chat().team_run_fence.as_ref(), Some(&owned.binding.fence));
    assert!(tokenstat_workspace::writer::Lease::acquire(&f.folder).is_err());
    assert!(
        RunnerLease::try_acquire(&f.store.root, &f.chat.id)
            .unwrap()
            .is_none()
    );
    let second = principal("fixture-person", 'c', 'd');
    let retry = existing(f.prepare(&second, &input).unwrap());
    assert_eq!(retry["receipt"]["runId"], owned.binding.fence.run_id());
    assert_eq!(retry["receipt"]["state"], "reserved");
    let history = f.history();
    assert_eq!(history.events.len(), 1);
    assert_eq!(history.events[0]["mode"], "ask");
    assert_eq!(history.events[0]["author"]["id"], "fixture-person");
    let public = serde_json::to_string(&history).unwrap();
    for private in [
        "teamAsk",
        "runlease_",
        "grant_",
        "deviceKey",
        "clientMessageId",
        "requestDigest",
        "incarnation",
        "checkout_fixture",
    ] {
        assert!(!public.contains(private), "{private}");
    }
    let journal = Journal::decode(&f.journal_bytes(), &writer::source(&f.chat())).unwrap();
    let saved = journal
        .run_status(
            &owned.request.scope,
            "fixture-person",
            &input.client_message_id,
        )
        .unwrap()
        .unwrap();
    assert_eq!(saved.binding(), &owned.binding);
    assert_eq!(saved.request().actor.device, "a".repeat(64));
    assert!(
        !String::from_utf8(f.journal_bytes())
            .unwrap()
            .contains(&input.text)
    );
    let mut altered = input.clone();
    altered.text.push('x');
    assert_eq!(
        failed(f.prepare(&second, &altered)).code,
        "team_run_conflict"
    );
    assert_eq!(
        f.store.refuse_prepared_ask(f.target(), owned).unwrap()["receipt"]["state"],
        "notStarted"
    );
    assert!(f.chat().team_run_fence.is_none());
    assert!(tokenstat_workspace::writer::Lease::acquire(&f.folder).is_ok());
    assert_eq!(
        existing(f.prepare(&second, &input).unwrap())["receipt"]["state"],
        "notStarted"
    );
    assert_eq!(f.history().events.len(), 1);
}

#[test]
fn comments_after_acceptance_do_not_change_the_owned_context_or_reuse_the_ask_id() {
    let f = Fixture::new();
    let actor = principal("fixture-person", 'a', 'b');
    let comment = CommentInput {
        text: "Reviewed discussion".into(),
        client_message_id: "comment-one".into(),
        client_message_created_at_ms: now_ms(),
    };
    f.store
        .team_comment(f.target(), &actor, &comment, || Ok(()))
        .unwrap();
    let input = f.input(&actor, "ask-one");
    let owned = new(f.prepare(&actor, &input).unwrap());
    assert_eq!(owned.context.events.len(), 1);
    assert_eq!(owned.context.events[0]["text"], comment.text);
    let next = CommentInput {
        text: "Discussion for the next turn".into(),
        client_message_id: "comment-two".into(),
        client_message_created_at_ms: now_ms(),
    };
    f.store
        .team_comment(f.target(), &actor, &next, || Ok(()))
        .unwrap();
    f.store
        .ensure_prepared_ask(f.target(), &owned, || Ok(()))
        .unwrap();
    assert_eq!(owned.context.events.len(), 1);
    assert_eq!(f.history().events.len(), 3);
    let changed = CommentInput {
        text: input.text.clone(),
        client_message_id: input.client_message_id.clone(),
        client_message_created_at_ms: input.client_message_created_at_ms,
    };
    assert_eq!(
        f.store
            .team_comment(f.target(), &actor, &changed, || Ok(()))
            .unwrap_err()
            .code,
        "team_comment_conflict"
    );
    f.store.refuse_prepared_ask(f.target(), owned).unwrap();
    let mut reuse = f.input(&actor, "comment-one");
    reuse.text = comment.text;
    assert_eq!(failed(f.prepare(&actor, &reuse)).code, "team_run_conflict");
}

#[test]
fn stale_review_and_busy_writer_leave_no_intent_or_canonical_fence() {
    let f = Fixture::new();
    let actor = principal("fixture-person", 'a', 'b');
    let input = f.input(&actor, "ask-one");
    let lease = tokenstat_workspace::writer::Lease::acquire(&f.folder).unwrap();
    assert_eq!(failed(f.prepare(&actor, &input)).code, "team_run_busy");
    assert!(f.chat().team_run_fence.is_none());
    drop(lease);
    let c = CommentInput {
        text: "New discussion".into(),
        client_message_id: "comment-one".into(),
        client_message_created_at_ms: now_ms(),
    };
    f.store
        .team_comment(f.target(), &actor, &c, || Ok(()))
        .unwrap();
    assert_eq!(
        failed(f.prepare(&actor, &input)).code,
        "team_run_review_changed"
    );
    assert!(f.chat().team_run_fence.is_none());
    assert_eq!(f.history().events.len(), 1);
    let mut changed = f.input(&actor, "ask-two");
    changed.review = "00".repeat(32);
    assert_eq!(
        failed(f.prepare(&actor, &changed)).code,
        "team_run_review_changed"
    );
}

#[test]
fn interrupted_admission_never_replays_a_missing_or_written_ask() {
    for stop in [Step::Fenced, Step::Reserved, Step::Canonical, Step::Proven] {
        let f = Fixture::new();
        let actor = principal("fixture-person", 'a', 'b');
        let input = f.input(&actor, "ask-one");
        let stage = std::mem::discriminant(&stop);
        let error = failed(f.store.prepare_team_ask_steps(
            f.target(),
            &actor,
            &input,
            (&f.folder, &f.checkout, None),
            || Ok(()),
            |step| {
                if std::mem::discriminant(&step) == stage {
                    return Err(DispatchError::new("fixture_interruption", "fixture"));
                }
                Ok(())
            },
        ));
        assert_eq!(error.code, "fixture_interruption");
        assert!(f.chat().team_run_fence.is_some());
        // A fresh store simulates a process restart without retained handles.
        let store = Store::load_at(f.store.root.clone());
        let retried = store.prepare_team_ask(
            f.target(),
            &actor,
            &input,
            (&f.folder, &f.checkout, None),
            || Ok(()),
        );
        if matches!(stop, Step::Fenced) {
            assert_eq!(failed(retried).code, "team_run_busy");
        } else {
            assert_eq!(existing(retried.unwrap())["receipt"]["state"], "reserved");
        }
        assert!(store.require_private_chat(&f.chat.id).is_err());
        let bytes =
            fs::read(f.store.root.join(&f.chat.id).join("events.ndjson")).unwrap_or_default();
        assert_eq!(
            bytes
                .split(|b| *b == b'\n')
                .filter(|l| !l.is_empty())
                .count(),
            usize::from(matches!(stop, Step::Canonical | Step::Proven))
        );
        if matches!(stop, Step::Canonical | Step::Proven) {
            assert_eq!(f.history().events[0]["author"]["id"], "fixture-person");
        }
        if matches!(stop, Step::Reserved) {
            let comment = CommentInput {
                text: "Must wait for recovery".into(),
                client_message_id: "comment-next".into(),
                client_message_created_at_ms: now_ms(),
            };
            assert!(
                store
                    .team_comment(f.target(), &actor, &comment, || Ok(()))
                    .is_err()
            );
        }
    }
}

#[test]
fn only_one_concurrent_admission_gets_the_runner_and_a_second_person_cannot_settle_it() {
    let f = Fixture::new();
    let actor = principal("fixture-person", 'a', 'b');
    let input = f.input(&actor, "ask-one");
    let count = AtomicUsize::new(0);
    std::thread::scope(|scope| {
        let mut handles = Vec::new();
        for _ in 0..2 {
            handles.push(scope.spawn(|| match f.prepare(&actor, &input) {
                Ok(AskPreparation::New(p)) => {
                    count.fetch_add(1, Ordering::SeqCst);
                    Some(p)
                }
                Ok(AskPreparation::Existing(_)) => None,
                Err(e) => {
                    assert_eq!(e.code, "team_run_busy");
                    None
                }
            }));
        }
        let owned = handles
            .into_iter()
            .filter_map(|h| h.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(owned.len(), 1);
        let other = principal("fixture-other", 'c', 'd');
        assert_eq!(failed(f.prepare(&other, &input)).code, "team_run_busy");
        for p in owned {
            f.store.refuse_prepared_ask(f.target(), *p).unwrap();
        }
    });
    assert_eq!(count.load(Ordering::SeqCst), 1);
    assert_eq!(f.history().events.len(), 1);
}

#[test]
fn stale_canonical_fence_or_changed_publication_cannot_pass_pre_spawn_check_or_clear_recovery() {
    let f = Fixture::new();
    let actor = principal("fixture-person", 'a', 'b');
    let input = f.input(&actor, "ask-one");
    let owned = new(f.prepare(&actor, &input).unwrap());
    let path = f.store.root.join("conversations.json");
    let mut index: Index = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    let replacement =
        runs::Fence::new(format!("run_{}", "ee".repeat(16)), "ff".repeat(32)).unwrap();
    index.conversations[0].team_run_fence = Some(replacement.clone());
    fs::write(&path, serde_json::to_vec(&index).unwrap()).unwrap();
    assert!(
        f.store
            .ensure_prepared_ask(f.target(), &owned, || Ok(()))
            .is_err()
    );
    assert!(f.store.refuse_prepared_ask(f.target(), owned).is_err());
    assert_eq!(f.chat().team_run_fence, Some(replacement));
}

#[test]
fn a_private_fork_preserves_ask_authorship_without_copying_run_ownership() {
    let f = Fixture::new();
    let actor = principal("fixture-person", 'a', 'b');
    let input = f.input(&actor, "ask-one");
    let owned = new(f.prepare(&actor, &input).unwrap());
    f.store.refuse_prepared_ask(f.target(), owned).unwrap();
    f.store
        .clear_sharing(
            &f.chat.workspace_id,
            &f.chat.id,
            &format!("share_{}", "a".repeat(32)),
        )
        .unwrap();
    let fork = f.store.fork(&f.chat.id).unwrap();
    let history = f
        .store
        .sharing_history(&fork.workspace_id, &fork.id)
        .unwrap();
    assert_eq!(history.events[0]["mode"], "ask");
    assert_eq!(history.events[0]["author"]["id"], "fixture-person");
    let bytes = fs::read(f.store.root.join(&fork.id).join(writer::JOURNAL)).unwrap();
    let raw: Value = serde_json::from_slice(&bytes).unwrap();
    assert!(raw.get("runs").is_none());
    assert!(fork.team_run_fence.is_none());
    assert!(fork.resume_token.is_none());
    assert!(fork.resume_tokens.is_empty());
}

#[test]
fn a_forged_ask_row_or_deleted_accepted_row_pauses_sharing() {
    for deleted in [false, true] {
        let f = Fixture::new();
        let actor = principal("fixture-person", 'a', 'b');
        let input = f.input(&actor, "ask-one");
        let owned = new(f.prepare(&actor, &input).unwrap());
        let path = f.store.root.join(&f.chat.id).join("events.ndjson");
        if deleted {
            fs::write(&path, b"").unwrap();
        } else {
            let mut row: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
            row["teamAsk"]["attribution"]["actor"]["id"] = json!("forged-person");
            fs::write(&path, format!("{row}\n")).unwrap();
        }
        assert!(
            f.store
                .shared_history(
                    &f.chat.workspace_id,
                    &f.chat.id,
                    &format!("share_{}", "a".repeat(32)),
                    &f.preview
                )
                .is_err()
        );
        assert!(
            f.store
                .ensure_prepared_ask(f.target(), &owned, || Ok(()))
                .is_err()
        );
        drop(owned);
    }
}

#[test]
fn request_cannot_supply_actor_path_resume_grant_or_execution_settings() {
    let f = Fixture::new();
    let actor = principal("fixture-person", 'a', 'b');
    let input = f.input(&actor, "ask-one");
    let base = json!({"text":input.text,"clientMessageId":input.client_message_id,"clientMessageCreatedAtMs":input.client_message_created_at_ms,"review":input.review});
    for key in [
        "actor",
        "deviceKey",
        "path",
        "resume",
        "grantId",
        "backend",
        "permissionMode",
        "systemPrompt",
        "attachments",
    ] {
        let mut raw = base.clone();
        raw[key] = json!("forged");
        assert!(serde_json::from_value::<AskInput>(raw).is_err(), "{key}");
    }
    // The fixture lifetime owns all canonical and checkout files.
    assert!(f.root.path().is_dir());
}

#[test]
fn fresh_context_keeps_private_provider_continuations_and_host_settings_out() {
    let f = Fixture::new();
    let path = f.store.root.join("conversations.json");
    let mut index: Index = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    let chat = &mut index.conversations[0];
    chat.resume_token = Some("PRIVATE_NATIVE_SESSION".into());
    chat.resume_tokens
        .insert("codex".into(), "PRIVATE_OLD_PROVIDER".into());
    chat.system_prompt = "PRIVATE_HOST_INSTRUCTIONS".into();
    chat.allowed_shell_prefixes = vec!["PRIVATE_PERSONAL_GRANT".into()];
    fs::write(&path, serde_json::to_vec(&index).unwrap()).unwrap();
    let actor = principal("fixture-person", 'a', 'b');
    let input = f.input(&actor, "ask-one");
    let owned = new(f.prepare(&actor, &input).unwrap());
    assert!(
        !serde_json::to_string(owned.context())
            .unwrap()
            .contains("PRIVATE_")
    );
    assert!(f.chat().resume_token.is_none());
    assert!(f.chat().resume_tokens.is_empty());
    f.store.refuse_prepared_ask(f.target(), owned).unwrap();
}

#[test]
fn authorization_retired_after_reservation_cannot_append_on_retry() {
    let f = Fixture::new();
    let actor = principal("fixture-person", 'a', 'b');
    let input = f.input(&actor, "ask-one");
    let calls = AtomicUsize::new(0);
    let error = failed(f.store.prepare_team_ask(
        f.target(),
        &actor,
        &input,
        (&f.folder, &f.checkout, None),
        || {
            if calls.fetch_add(1, Ordering::SeqCst) >= 2 {
                Err(DispatchError::new("fixture_access_removed", "fixture"))
            } else {
                Ok(())
            }
        },
    ));
    assert_eq!(error.code, "fixture_access_removed");
    assert!(f.chat().team_run_fence.is_some());
    assert!(
        fs::read(f.store.root.join(&f.chat.id).join("events.ndjson"))
            .unwrap_or_default()
            .is_empty()
    );
    assert_eq!(
        existing(f.prepare(&actor, &input).unwrap())["receipt"]["state"],
        "reserved"
    );
    assert!(
        fs::read(f.store.root.join(&f.chat.id).join("events.ndjson"))
            .unwrap_or_default()
            .is_empty()
    );
}

#[test]
fn damaged_or_cross_mode_journal_proof_never_turns_a_run_into_a_new_attempt() {
    let f = Fixture::new();
    let actor = principal("fixture-person", 'a', 'b');
    let input = f.input(&actor, "ask-one");
    let owned = new(f.prepare(&actor, &input).unwrap());
    let raw: Value = serde_json::from_slice(&f.journal_bytes()).unwrap();
    let key = raw["asks"]
        .as_object()
        .unwrap()
        .keys()
        .next()
        .unwrap()
        .clone();
    for field in ["missing", "bothModes", "recordDigest", "sequence"] {
        let mut damaged = raw.clone();
        match field {
            "missing" => damaged["asks"] = json!({}),
            "bothModes" => damaged["receipts"][&key] = damaged["asks"][&key].clone(),
            "recordDigest" => damaged["asks"][&key]["recordDigest"] = json!("cc".repeat(32)),
            _ => damaged["asks"][&key]["seq"] = json!(9_007_199_254_740_992u64),
        }
        assert!(
            Journal::decode(
                &serde_json::to_vec(&damaged).unwrap(),
                &writer::source(&f.chat())
            )
            .is_err(),
            "{field}"
        );
    }
    f.store.refuse_prepared_ask(f.target(), owned).unwrap();
}

#[test]
fn a_dirty_checkout_changes_the_review_and_blocks_the_old_one() {
    let f = Fixture::new();
    let actor = principal("fixture-person", 'a', 'b');
    let run = |args: &[&str]| {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(&f.folder)
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    };
    run(&["init", "-b", "shared"]);
    run(&["config", "user.name", "Test"]);
    run(&["config", "user.email", "test@example.invalid"]);
    run(&["commit", "--allow-empty", "-m", "init"]);
    let clean = f.input(&actor, "ask-clean");
    std::fs::write(f.folder.join("local.txt"), "uncommitted").unwrap();
    let dirty = f.input(&actor, "ask-dirty");
    assert_ne!(clean.review, dirty.review);
    assert_eq!(
        failed(f.prepare(&actor, &clean)).code,
        "team_run_review_changed"
    );
    let owned = new(f.prepare(&actor, &dirty).unwrap());
    assert!(owned.context.worktree.repository && owned.context.worktree.dirty);
    assert_eq!(owned.context.worktree.branch.as_deref(), Some("shared"));
    assert!(
        owned
            .context
            .worktree
            .head
            .as_ref()
            .is_some_and(|head| head.len() == 40)
    );
    f.store.refuse_prepared_ask(f.target(), owned).unwrap();
}
