// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! One CPU projection at a time per retained reader, using an injected shared
//! background executor. The production GPUI adapter keeps CPU work off the UI.

use super::paging::publication::{Projected, Work};
use std::{
    collections::VecDeque,
    future::Future,
    pin::Pin,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context, Poll, Waker},
};

type Task = Box<dyn FnOnce() + Send>;
type Spawn = Arc<dyn Fn(Task) + Send + Sync>;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cancelled;
pub struct Finished {
    pub(crate) result: Result<Projected, Cancelled>,
    pub(crate) ticket: super::paging::publication::Ticket,
}
struct Reply {
    result: Option<Finished>,
    waker: Option<Waker>,
}
struct Item {
    work: Work,
    cancelled: Arc<AtomicBool>,
    reply: Arc<Mutex<Reply>>,
}
#[derive(Default)]
struct Queue {
    active: bool,
    pending: VecDeque<Item>,
}
#[derive(Clone)]
pub struct Lane {
    queue: Arc<Mutex<Queue>>,
    spawn: Spawn,
}
pub struct Pending {
    cancelled: Arc<AtomicBool>,
    reply: Arc<Mutex<Reply>>,
    ticket: super::paging::publication::Ticket,
}
impl Pending {
    /// Retained callers explicitly finish this cancellation on their Window,
    /// releasing the matching page spinner without waiting for CPU work.
    pub fn cancel(self) -> Finished {
        self.cancelled.store(true, Ordering::Release);
        Finished {
            result: Err(Cancelled),
            ticket: self.ticket.clone(),
        }
    }
}
impl Future for Pending {
    type Output = Finished;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut reply = self.reply.lock().unwrap();
        if let Some(result) = reply.result.take() {
            Poll::Ready(result)
        } else {
            reply.waker = Some(cx.waker().clone());
            Poll::Pending
        }
    }
}
impl Drop for Pending {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Release);
        let mut reply = self.reply.lock().unwrap();
        reply.waker = None;
        reply.result = None;
    }
}
impl Lane {
    /// The executor must schedule away from the UI thread. The GPUI adapter
    /// below uses its existing shared BackgroundExecutor and creates no threads.
    pub fn new(spawn: impl Fn(Task) + Send + Sync + 'static) -> Self {
        Self {
            queue: Arc::default(),
            spawn: Arc::new(spawn),
        }
    }
    #[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
    pub fn background(executor: gpui::BackgroundExecutor) -> Self {
        Self::new(move |task| {
            let check = executor.clone();
            executor
                .spawn(async move {
                    debug_assert!(
                        !check.is_main_thread(),
                        "Transcript projection ran on the UI thread"
                    );
                    task()
                })
                .detach();
        })
    }
    pub fn submit(&self, work: Work) -> Pending {
        let ticket = work.ticket();
        let cancelled = Arc::new(AtomicBool::new(false));
        let reply = Arc::new(Mutex::new(Reply {
            result: None,
            waker: None,
        }));
        self.queue.lock().unwrap().pending.push_back(Item {
            work,
            cancelled: cancelled.clone(),
            reply: reply.clone(),
        });
        self.pump();
        Pending {
            cancelled,
            reply,
            ticket,
        }
    }
    fn pump(&self) {
        let item = {
            let mut queue = self.queue.lock().unwrap();
            if queue.active {
                return;
            }
            let Some(item) = queue.pending.pop_front() else {
                return;
            };
            queue.active = true;
            item
        };
        let lane = self.clone();
        (self.spawn)(Box::new(move || {
            let ticket = item.work.ticket();
            let result = if item.cancelled.load(Ordering::Acquire) {
                Err(Cancelled)
            } else {
                let result = item.work.project();
                if item.cancelled.load(Ordering::Acquire) {
                    Err(Cancelled)
                } else {
                    Ok(result)
                }
            };
            let waker = {
                let mut reply = item.reply.lock().unwrap();
                if !item.cancelled.load(Ordering::Acquire) {
                    reply.result = Some(Finished { result, ticket });
                }
                reply.waker.take()
            };
            lane.queue.lock().unwrap().active = false;
            if let Some(waker) = waker {
                waker.wake();
            }
            lane.pump();
        }));
    }
}
