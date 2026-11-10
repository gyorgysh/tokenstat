// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde_json::{Value, json};
use tokenstat_linux::{
    chat::{
        Conversation,
        directory::Owner,
        paging::{Failure, Read, ReadKind, Window, publication::Step},
        projector::Lane,
    },
    work::Scope,
};
fn settle(window: &mut Window, mut step: Step) -> tokenstat_linux::chat::paging::Completion {
    use std::{
        future::Future,
        task::{Context, Poll, Waker},
    };
    // Explicit deterministic fixture executor; the product uses Lane::background.
    let lane = Lane::new(|task| task());
    let mut context = Context::from_waker(Waker::noop());
    loop {
        match step {
            Step::Complete(done) => return done,
            Step::Project(work) => {
                let mut pending = Box::pin(lane.submit(work));
                let Poll::Ready(finished) = pending.as_mut().poll(&mut context) else {
                    panic!("fixture worker not ready")
                };
                step = window.finish_projection(finished);
            }
        }
    }
}

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
fn revise(window: &mut Window, revision: u64) {
    let mut chat = window.selected().unwrap().clone();
    chat.send_revision = Some(revision);
    window.update_metadata(&owner(), "folder", chat);
}
fn finish(window: &mut Window, read: Read, responses: &[Value], calls: &mut Vec<Value>) {
    calls.push(json!({"method":read.method(),"params":read.parameters()}));
    let response = responses.first().expect("unplanned request");
    if let Some(id) = response["select"].as_str() {
        window.select(owner(), "folder", Some(chat(id)), false);
    }
    if let Some(revision) = response["revision"].as_u64() {
        revise(window, revision);
    }
    let failure = || Failure {
        message: response["error"].as_str().unwrap().into(),
        unknown_method: response["unknown"].as_bool().unwrap_or_default()
            || response["error"]
                .as_str()
                .is_some_and(|m| m.starts_with("unknown ")),
    };
    let completion = match read.kind {
        ReadKind::Newest | ReadKind::Earlier => window.receive_page(
            &read,
            if response.get("error").is_some() {
                Err(failure())
            } else {
                Ok(serde_json::from_value(response["value"].clone()).unwrap())
            },
        ),
        ReadKind::Whole | ReadKind::Tail => window.receive_chunk(
            &read,
            if response.get("error").is_some() {
                Err(failure())
            } else {
                Ok(serde_json::from_value(response["value"].clone()).unwrap())
            },
        ),
    };
    let completion = settle(window, completion);
    if let Some(reopen) = completion.reopen {
        finish(window, reopen, &responses[1..], calls);
    } else {
        assert_eq!(responses.len(), 1, "unused responses");
    }
}
pub fn snapshot(traces: &Value) -> Value {
    json!(traces.as_array().unwrap().iter().map(|trace| {
        let mut window = Window::default();
        let mut calls = vec![];
        let mut checkpoints = vec![];
        for action in trace["actions"].as_array().unwrap() {
            let quiet = action["quiet"].as_bool().unwrap_or_default();
            let read = match action["op"].as_str().unwrap() {
                "select"=>{window.select(owner(),"folder",Some(chat(action["id"].as_str().unwrap())),action["fresh"].as_bool().unwrap_or_default()); None},
                "revision"=>{revise(&mut window,action["value"].as_u64().unwrap());None},
                "open"=>window.begin_open(quiet),
                "tail"=>window.begin_tail(quiet),
                "earlier"=>window.begin_earlier(quiet),
                _=>panic!("unknown action"),
            };
            if let Some(read) = read { finish(&mut window,read,action["responses"].as_array().unwrap(),&mut calls); }
            else if let Some(responses) = action["responses"].as_array() { assert!(responses.is_empty(),"unused responses"); }
            checkpoints.push(json!({"selected":window.selected().map(|c|&c.id),"events":window.events(),"opening":window.opening(),
                "liveLoaded":window.live_loaded(),"pagingUnavailable":window.paging_unavailable(),"offset":window.offset(),"tailCursor":window.tail_cursor(),
                "earlierCursor":window.earlier_cursor(),"hasEarlier":window.has_earlier(),"loadingEarlier":window.loading_earlier(),"reachedStart":window.reached_start(),
                "historyTrimmed":window.history_trimmed(),"usage":window.usage(),"usageThrough":window.usage_through(),"contextRevision":window.context_revision(),"error":window.error(),"calls":calls}));
        }
        checkpoints
    }).collect::<Vec<_>>())
}
