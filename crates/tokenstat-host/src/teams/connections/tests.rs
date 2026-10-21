// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use serde_json::json;
use std::sync::atomic::{AtomicUsize, Ordering};

fn key() -> Key {
    Key {
        owner: "login-1".into(),
        issuer: "http://127.0.0.1:1234".into(),
        device: [1; 32],
        target: Target {
            organization: "org_fixture".into(),
            repository: "repo_fixture".into(),
            checkout: "co_fixture".into(),
            share: None,
        },
    }
}
fn job() -> (Job, Receiver<Result<Value, DispatchError>>) {
    let (reply, receiver) = mpsc::sync_channel(1);
    (
        Job {
            method: TeamReadMethod::CheckoutInfo,
            deadline: Instant::now() + CALL_BUDGET,
            reply,
        },
        receiver,
    )
}
struct Fake {
    id: usize,
    calls: usize,
    fail: bool,
}
impl Transport for Fake {
    fn call(&mut self, _: TeamReadMethod) -> Result<Value, DispatchError> {
        self.calls += 1;
        if self.fail {
            Err(DispatchError::new("checkout_withdrawn", "Unavailable"))
        } else {
            Ok(json!({"connection":self.id,"call":self.calls}))
        }
    }
    fn renew(&mut self) -> Result<(), DispatchError> {
        Ok(())
    }
    fn ensure_current(&self) -> Result<(), DispatchError> {
        Ok(())
    }
}
fn connect(counter: &Arc<AtomicUsize>) -> Connector {
    let counter = counter.clone();
    Box::new(move || {
        Ok(Box::new(Fake {
            id: counter.fetch_add(1, Ordering::SeqCst),
            calls: 0,
            fail: false,
        }))
    })
}

#[test]
fn scoped_requests_are_closed_and_reject_authority_or_personal_methods() {
    let valid = json!({"target":{"organization":"org_fixture","repository":"repo_fixture","checkout":"co_fixture"},"method":"team.checkout.info"});
    assert!(
        serde_json::from_value::<Request>(valid.clone())
            .unwrap()
            .validate()
            .is_ok()
    );
    for method in [
        "remote.call",
        "chat.send",
        "team.run.start",
        "team.checkout.info\n",
    ] {
        let mut value = valid.clone();
        value["method"] = json!(method);
        assert!(serde_json::from_value::<Request>(value).is_err());
    }
    for field in ["params", "peer", "actor", "ticket", "capabilities"] {
        let mut value = valid.clone();
        value[field] = json!({});
        assert!(serde_json::from_value::<Request>(value).is_err());
    }
    for field in ["actor", "deviceKey", "publisher", "path"] {
        let mut value = valid.clone();
        value["target"][field] = json!("forged");
        assert!(serde_json::from_value::<Request>(value).is_err());
    }
    for id in ["", "..", "repo/other", "repo\n", &"a".repeat(129)] {
        let mut value = valid.clone();
        value["target"]["repository"] = json!(id);
        assert!(
            serde_json::from_value::<Request>(value)
                .unwrap()
                .validate()
                .is_err()
        );
    }
}

#[test]
fn connections_serialize_reads_and_never_borrow_other_scopes() {
    let pool = Arc::new(Pool::default());
    let counter = Arc::new(AtomicUsize::new(0));
    let original = key();
    assert_eq!(
        pool.call(
            original.clone(),
            connect(&counter),
            TeamReadMethod::Protocol
        )
        .unwrap(),
        json!({"connection":0,"call":1})
    );
    assert_eq!(
        pool.call(
            original.clone(),
            connect(&counter),
            TeamReadMethod::CheckoutInfo
        )
        .unwrap(),
        json!({"connection":0,"call":2})
    );
    let mut variants = Vec::new();
    let mut changed = original.clone();
    changed.owner = "new-login".into();
    variants.push(changed);
    let mut changed = original.clone();
    changed.issuer = "http://127.0.0.1:5678".into();
    variants.push(changed);
    let mut changed = original.clone();
    changed.device = [2; 32];
    variants.push(changed);
    let mut changed = original.clone();
    changed.target.organization = "org_other".into();
    variants.push(changed);
    let mut changed = original.clone();
    changed.target.repository = "repo_other".into();
    variants.push(changed);
    let mut changed = original.clone();
    changed.target.checkout = "co_other".into();
    variants.push(changed);
    let mut changed = original.clone();
    changed.target.share = Some("share_other".into());
    variants.push(changed);
    for (index, variant) in variants.into_iter().enumerate() {
        assert_eq!(
            pool.call(variant, connect(&counter), TeamReadMethod::Protocol)
                .unwrap(),
            json!({"connection":index+1,"call":1})
        );
    }
    assert_eq!(counter.load(Ordering::SeqCst), 8);
}

#[test]
fn connection_and_queue_limits_reject_without_starting_more_work() {
    let pool = Arc::new(Pool::default());
    let counter = Arc::new(AtomicUsize::new(0));
    let mut receivers = Vec::new();
    for n in 0..MAX_CONNECTIONS {
        let mut target = key();
        target.target.checkout = format!("checkout_{n}");
        let (sender, receiver) = mpsc::sync_channel(MAX_QUEUED);
        pool.slots.lock().unwrap().insert(
            target,
            Slot {
                sender,
                lifetime: Arc::new(()),
            },
        );
        receivers.push(receiver);
    }
    assert_eq!(
        pool.enqueue(key(), connect(&counter), job().0)
            .unwrap_err()
            .code,
        "teams_busy"
    );
    let mut target = key();
    target.target.checkout = "checkout_0".into();
    let mut replies = Vec::new();
    for _ in 0..MAX_QUEUED {
        let (job, reply) = job();
        pool.enqueue(target.clone(), connect(&counter), job)
            .unwrap();
        replies.push(reply);
    }
    assert_eq!(
        pool.enqueue(target, connect(&counter), job().0)
            .unwrap_err()
            .code,
        "teams_busy"
    );
    assert_eq!(receivers[0].try_iter().count(), MAX_QUEUED);
    assert_eq!(counter.load(Ordering::SeqCst), 0);
}

#[test]
fn late_worker_retirement_cannot_remove_a_new_connection() {
    let pool = Arc::new(Pool::default());
    let target = key();
    let old = Arc::new(());
    let (sender, _receiver) = mpsc::sync_channel(MAX_QUEUED);
    let replacement = Arc::new(());
    pool.slots.lock().unwrap().insert(
        target.clone(),
        Slot {
            sender,
            lifetime: replacement.clone(),
        },
    );
    drop(Retirement {
        pool: Arc::downgrade(&pool),
        key: target.clone(),
        lifetime: old,
    });
    assert_eq!(pool.slots.lock().unwrap().len(), 1);
    drop(Retirement {
        pool: Arc::downgrade(&pool),
        key: target,
        lifetime: replacement,
    });
    assert!(pool.slots.lock().unwrap().is_empty());
}

#[test]
fn expired_queue_items_never_connect_and_failures_never_replay() {
    let counter = Arc::new(AtomicUsize::new(0));
    let (sender, receiver) = mpsc::sync_channel(MAX_QUEUED);
    let (mut expired, response) = job();
    expired.deadline = Instant::now();
    sender.send(expired).unwrap();
    work(receiver, connect(&counter));
    assert_eq!(
        response.recv().unwrap().unwrap_err().code,
        "team_connection_unavailable"
    );
    assert_eq!(counter.load(Ordering::SeqCst), 0);

    let (sender, receiver) = mpsc::sync_channel(MAX_QUEUED);
    let (first, first_reply) = job();
    let (second, second_reply) = job();
    sender.send(first).unwrap();
    sender.send(second).unwrap();
    work(
        receiver,
        Box::new(|| {
            Ok(Box::new(Fake {
                id: 1,
                calls: 0,
                fail: true,
            }))
        }),
    );
    assert_eq!(
        first_reply.recv().unwrap().unwrap_err().code,
        "checkout_withdrawn"
    );
    assert_eq!(
        second_reply.recv().unwrap().unwrap_err().code,
        "team_connection_unavailable"
    );
}
