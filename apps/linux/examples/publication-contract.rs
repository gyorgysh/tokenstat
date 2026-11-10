// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Owned, suspended-publication traces. CPU runs on a real temporary worker;
//! delivery is held independently so valid response orders are reproducible.

use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    future::Future,
    io::Read,
    pin::Pin,
    task::{Context, Poll, Waker},
};
use tokenstat_linux::{
    chat::{
        Conversation,
        directory::Owner,
        paging::{ReadKind, Window, publication::Step},
        projector::{Lane, Pending},
    },
    work::Scope,
};
fn owner() -> Owner {
    Owner {
        scope: Scope::local("fixture-account"),
        generation: 1,
        local_host_identity: "fixture-host".into(),
    }
}
fn chat(id: &str) -> Conversation {
    serde_json::from_value(json!({"id":id,"workspaceId":"folder","title":"Synthetic","backend":"fixture","sendRevision":3})).unwrap()
}
fn submit(
    lane: &Lane,
    step: Step,
    id: &str,
    jobs: &mut BTreeMap<String, Option<Pin<Box<Pending>>>>,
    attempts: &mut BTreeMap<String, u64>,
) {
    match step {
        Step::Complete(_) => {
            jobs.insert(id.into(), None);
        }
        Step::Project(work) => {
            *attempts.entry(id.into()).or_default() += 1;
            jobs.insert(id.into(), Some(Box::pin(lane.submit(work))));
        }
    }
}
fn deliver(
    window: &mut Window,
    lane: &Lane,
    id: &str,
    jobs: &mut BTreeMap<String, Option<Pin<Box<Pending>>>>,
    attempts: &mut BTreeMap<String, u64>,
) {
    let pending = jobs.get_mut(id).unwrap().take().unwrap();
    let mut pending = pending;
    let Poll::Ready(finished) = pending
        .as_mut()
        .poll(&mut Context::from_waker(Waker::noop()))
    else {
        panic!("worker not ready")
    };
    submit(lane, window.finish_projection(finished), id, jobs, attempts);
}
fn main() {
    let mut bytes = String::new();
    std::io::stdin().read_to_string(&mut bytes).unwrap();
    let input: Value = serde_json::from_str(&bytes).unwrap();
    let mut traces = vec![];
    for trace in input["traces"].as_array().unwrap() {
        let lane = Lane::new(|task| {
            std::thread::spawn(task).join().unwrap();
        });
        let mut window = Window::default();
        window.select(owner(), "folder", Some(chat("first")), false);
        let mut jobs = BTreeMap::new();
        let mut attempts = BTreeMap::new();
        let mut calls = vec![];
        let read = window.begin_open(false).unwrap();
        calls.push(json!({"method":read.method(),"params":read.parameters()}));
        let step = window.receive_page(
            &read,
            Ok(serde_json::from_value(trace["seed"].clone()).unwrap()),
        );
        submit(&lane, step, "seed", &mut jobs, &mut attempts);
        deliver(&mut window, &lane, "seed", &mut jobs, &mut attempts);
        jobs.clear();
        attempts.clear();
        let mut checkpoints = vec![];
        for action in trace["actions"].as_array().unwrap() {
            match action["op"].as_str().unwrap() {
                "start" => {
                    let id = action["id"].as_str().unwrap();
                    let kind = action["kind"].as_str().unwrap();
                    let step = if kind == "metadata" {
                        Step::Project(window.prepare_metadata().unwrap())
                    } else {
                        let read = match kind {
                            "open" => window.begin_open(false),
                            "earlier" => window.begin_earlier(false),
                            "tail" => window.begin_tail(false),
                            _ => panic!("unknown kind"),
                        }
                        .unwrap();
                        calls.push(json!({"method":read.method(),"params":read.parameters()}));
                        if matches!(read.kind, ReadKind::Newest | ReadKind::Earlier) {
                            window.receive_page(
                                &read,
                                Ok(serde_json::from_value(action["value"].clone()).unwrap()),
                            )
                        } else {
                            window.receive_chunk(
                                &read,
                                Ok(serde_json::from_value(action["value"].clone()).unwrap()),
                            )
                        }
                    };
                    submit(&lane, step, id, &mut jobs, &mut attempts);
                }
                "deliver" => deliver(
                    &mut window,
                    &lane,
                    action["id"].as_str().unwrap(),
                    &mut jobs,
                    &mut attempts,
                ),
                "cancel" => {
                    let pending = jobs
                        .get_mut(action["id"].as_str().unwrap())
                        .unwrap()
                        .take()
                        .unwrap();
                    let finished = Pin::into_inner(pending).cancel();
                    assert!(matches!(
                        window.finish_projection(finished),
                        Step::Complete(_)
                    ));
                }
                "metadata" => {
                    let mut chat = window.selected().unwrap().clone();
                    if let Some(b) = action["backend"].as_str() {
                        chat.backend = b.into();
                    }
                    if let Some(r) = action["running"].as_bool() {
                        chat.running = r;
                    }
                    if let Some(rev) = action["revision"].as_u64() {
                        chat.send_revision = Some(rev);
                    }
                    window.update_metadata(&owner(), "folder", chat);
                }
                "select" => {
                    window.select(
                        owner(),
                        "folder",
                        Some(chat(action["id"].as_str().unwrap())),
                        false,
                    );
                }
                _ => panic!("unknown operation"),
            }
            let job_states=jobs.iter().map(|(id,p)|json!({"id":id,"attempts":attempts.get(id).copied().unwrap_or(0),"pending":p.is_some()})).collect::<Vec<_>>();
            checkpoints.push(json!({"events":window.events(),"rows":window.rows(),"eventsRevision":window.events_revision(),"displayRevision":window.display_revision(),"selected":window.selected().unwrap().id,"backend":window.selected().unwrap().backend,"running":window.selected().unwrap().running,"offset":window.offset(),"tailCursor":window.tail_cursor(),"earlierCursor":window.earlier_cursor(),"hasEarlier":window.has_earlier(),"opening":window.opening(),"loadingEarlier":window.loading_earlier(),"contextRevision":window.context_revision(),"usage":window.usage(),"jobs":job_states,"calls":calls}));
        }
        traces.push(checkpoints);
    }
    println!("{}", json!({"traces":traces}));
}
