// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Count-bound small updates and byte-bound large provider messages.
use serde_json::Value;
use std::sync::{Arc, Condvar, Mutex, PoisonError, mpsc};
use std::time::Duration;

type Message = Result<Value, String>;

struct Budget {
    limit: usize,
    state: Mutex<BudgetState>,
    available: Condvar,
}

#[derive(Default)]
struct BudgetState {
    used: usize,
    closed: bool,
}

struct Permit {
    budget: Arc<Budget>,
    bytes: usize,
}

impl Budget {
    fn reserve(self: &Arc<Self>, bytes: usize) -> Option<Permit> {
        // A frame larger than the budget can proceed on its own. The protocol
        // reader still enforces the separate per-frame limit.
        let bytes = bytes.min(self.limit);
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        while !state.closed && state.used + bytes > self.limit {
            state = self
                .available
                .wait(state)
                .unwrap_or_else(PoisonError::into_inner);
        }
        if state.closed {
            return None;
        }
        state.used += bytes;
        Some(Permit {
            budget: Arc::clone(self),
            bytes,
        })
    }

    fn close(&self) {
        self.state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .closed = true;
        self.available.notify_all();
    }
}

impl Drop for Permit {
    fn drop(&mut self) {
        let mut state = self
            .budget
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        state.used -= self.bytes;
        drop(state);
        self.budget.available.notify_one();
    }
}

struct Queued {
    value: Message,
    permit: Option<Permit>,
}

#[derive(Clone)]
pub(super) struct Sender {
    sender: mpsc::SyncSender<Queued>,
    budget: Arc<Budget>,
    small_limit: usize,
}

pub(super) struct Messages {
    receiver: mpsc::Receiver<Queued>,
    budget: Arc<Budget>,
}

pub(super) fn channel() -> (Sender, Messages) {
    // Up to 32 small messages need no budget lock and occupy at most 128 KiB
    // of input bytes. Larger messages share 8 MiB; a single oversized frame
    // may use the whole budget. This counts encoded input, not JSON heap cost.
    channel_with_limits(32, 4 * 1024, 8 * 1024 * 1024)
}

fn channel_with_limits(count: usize, small_limit: usize, bytes: usize) -> (Sender, Messages) {
    let (sender, receiver) = mpsc::sync_channel(count);
    let budget = Arc::new(Budget {
        limit: bytes,
        state: Mutex::new(BudgetState::default()),
        available: Condvar::new(),
    });
    (
        Sender {
            sender,
            budget: Arc::clone(&budget),
            small_limit,
        },
        Messages { receiver, budget },
    )
}

impl Sender {
    pub(super) fn send(&self, value: Message, bytes: usize) -> bool {
        let permit = if bytes > self.small_limit {
            let Some(permit) = self.budget.reserve(bytes) else {
                return false;
            };
            Some(permit)
        } else {
            None
        };
        self.sender.send(Queued { value, permit }).is_ok()
    }
}

impl Messages {
    pub(super) fn recv_timeout(
        &self,
        timeout: Duration,
    ) -> Result<Message, mpsc::RecvTimeoutError> {
        self.receiver
            .recv_timeout(timeout)
            .map(|Queued { value, permit }| {
                drop(permit);
                value
            })
    }
}

impl Drop for Messages {
    fn drop(&mut self) {
        self.budget.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn preserves_order_errors_and_eof() {
        let (sender, messages) = channel();
        assert!(sender.send(Ok(json!({"part": 1})), 100));
        assert!(sender.send(Err("invalid message".into()), 0));
        drop(sender);
        assert_eq!(
            messages.recv_timeout(Duration::ZERO).unwrap().unwrap(),
            json!({"part": 1})
        );
        assert_eq!(
            messages.recv_timeout(Duration::ZERO).unwrap().unwrap_err(),
            "invalid message"
        );
        assert!(matches!(
            messages.recv_timeout(Duration::ZERO),
            Err(mpsc::RecvTimeoutError::Disconnected)
        ));
    }

    #[test]
    fn large_messages_wait_for_bytes_to_be_consumed() {
        let (sender, messages) = channel_with_limits(32, 4, 10);
        let (sent, received) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            assert!(sender.send(Ok(json!(1)), 6));
            sent.send(1).unwrap();
            assert!(sender.send(Ok(json!(2)), 6));
            sent.send(2).unwrap();
        });
        assert_eq!(received.recv_timeout(Duration::from_secs(2)).unwrap(), 1);
        assert!(received.recv_timeout(Duration::from_millis(40)).is_err());
        assert_eq!(
            messages.recv_timeout(Duration::ZERO).unwrap().unwrap(),
            json!(1)
        );
        assert_eq!(received.recv_timeout(Duration::from_secs(2)).unwrap(), 2);
        assert_eq!(
            messages
                .recv_timeout(Duration::from_secs(2))
                .unwrap()
                .unwrap(),
            json!(2)
        );
        worker.join().unwrap();
    }

    #[test]
    fn one_oversized_frame_can_proceed_without_deadlocking() {
        let (sender, messages) = channel_with_limits(32, 4, 10);
        assert!(sender.send(Ok(json!(1)), 100));
        assert_eq!(messages.budget.state.lock().unwrap().used, 10);
        assert_eq!(
            messages.recv_timeout(Duration::ZERO).unwrap().unwrap(),
            json!(1)
        );
        assert!(sender.send(Ok(json!(2)), 100));
        assert_eq!(
            messages.recv_timeout(Duration::ZERO).unwrap().unwrap(),
            json!(2)
        );
    }

    #[test]
    fn dropping_the_receiver_releases_a_byte_blocked_sender() {
        let (sender, messages) = channel_with_limits(32, 4, 10);
        assert!(sender.send(Ok(json!(1)), 10));
        let (finished, was_finished) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            finished.send(sender.send(Ok(json!(2)), 10)).unwrap();
        });
        assert!(
            was_finished
                .recv_timeout(Duration::from_millis(40))
                .is_err()
        );
        drop(messages);
        assert!(!was_finished.recv_timeout(Duration::from_secs(2)).unwrap());
        worker.join().unwrap();
    }

    #[test]
    fn small_messages_keep_the_count_limit_without_reserving_bytes() {
        let (sender, messages) = channel_with_limits(2, 4, 10);
        assert!(sender.send(Ok(json!(1)), 4));
        assert!(sender.send(Ok(json!(2)), 4));
        assert_eq!(messages.budget.state.lock().unwrap().used, 0);
        let (finished, was_finished) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            finished.send(sender.send(Ok(json!(3)), 4)).unwrap();
        });
        assert!(
            was_finished
                .recv_timeout(Duration::from_millis(40))
                .is_err()
        );
        assert_eq!(
            messages.recv_timeout(Duration::ZERO).unwrap().unwrap(),
            json!(1)
        );
        assert!(was_finished.recv_timeout(Duration::from_secs(2)).unwrap());
        assert_eq!(
            messages.recv_timeout(Duration::ZERO).unwrap().unwrap(),
            json!(2)
        );
        assert_eq!(
            messages.recv_timeout(Duration::ZERO).unwrap().unwrap(),
            json!(3)
        );
        worker.join().unwrap();
    }

    #[test]
    fn dropping_the_receiver_releases_a_count_blocked_sender_and_its_permits() {
        let (sender, messages) = channel_with_limits(1, 4, 20);
        let budget = Arc::clone(&messages.budget);
        assert!(sender.send(Ok(json!(1)), 6));
        let (finished, was_finished) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            finished.send(sender.send(Ok(json!(2)), 6)).unwrap();
        });
        let until = std::time::Instant::now() + Duration::from_secs(2);
        while budget.state.lock().unwrap().used != 12 {
            assert!(
                std::time::Instant::now() < until,
                "Sender did not reserve its pending frame"
            );
            std::thread::yield_now();
        }
        assert!(was_finished.try_recv().is_err());
        drop(messages);
        assert!(!was_finished.recv_timeout(Duration::from_secs(2)).unwrap());
        worker.join().unwrap();
        assert_eq!(budget.state.lock().unwrap().used, 0);
    }
}
