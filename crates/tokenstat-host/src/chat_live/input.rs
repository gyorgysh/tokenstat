// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Keep provider stdin writes from blocking stdout processing or Stop.
use serde_json::Value;
use std::collections::VecDeque;
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};

const MAX_PENDING: usize = 8;
const MAX_BYTES: usize = 16 * 1024 * 1024;
const SMALL_BYTES: usize = 4 * 1024;
const MAX_COMPLETED: usize = 32;

struct Control {
    id: String,
    expires: u64,
}

struct Request {
    bytes: Vec<u8>,
    control: Option<Control>,
    charge: usize,
}

pub(super) struct Frame(Request);

pub(super) fn frame(message: &Value) -> Result<Frame, String> {
    prepare(message, None)
}

fn prepare(message: &Value, control: Option<Control>) -> Result<Frame, String> {
    let mut bytes = serde_json::to_vec(message).map_err(|error| error.to_string())?;
    bytes.push(b'\n');
    let charge = if bytes.len() <= SMALL_BYTES {
        0
    } else {
        bytes.len().min(MAX_BYTES)
    };
    Ok(Frame(Request {
        bytes,
        control,
        charge,
    }))
}

pub(super) enum Failure {
    Expired,
    Write(String),
}

pub(super) struct Completed {
    pub control: Option<String>,
    pub result: Result<(), Failure>,
    charge: usize,
}

pub(super) struct Input {
    sender: mpsc::SyncSender<Request>,
    results: mpsc::Receiver<Completed>,
    completed: VecDeque<Completed>,
    pending: usize,
    bytes: usize,
    closed: Arc<AtomicBool>,
    failed: Option<String>,
}

pub(super) fn start(writer: impl Write + Send + 'static) -> Input {
    start_with(move || writer)
}

/// Construct thread-local writers, such as StdoutLock, on their owning thread.
pub(super) fn start_with<W: Write>(writer: impl FnOnce() -> W + Send + 'static) -> Input {
    let (sender, requests) = mpsc::sync_channel::<Request>(MAX_PENDING);
    let (results, receiver) = mpsc::channel();
    let closed = Arc::new(AtomicBool::new(false));
    let cancelled = Arc::clone(&closed);
    std::thread::spawn(move || {
        let mut writer = writer();
        while let Ok(request) = requests.recv() {
            if cancelled.load(Ordering::Acquire) {
                break;
            }
            let result = if request
                .control
                .as_ref()
                .is_some_and(|control| control.expires <= super::now_ms())
            {
                Err(Failure::Expired)
            } else {
                (|| {
                    // Recheck cancellation between writes. Killing a stuck
                    // provider releases a write already blocked in the OS.
                    for chunk in request.bytes.chunks(8192) {
                        if cancelled.load(Ordering::Acquire) {
                            return Err("The agent input was stopped.".into());
                        }
                        writer.write_all(chunk).map_err(|error| error.to_string())?;
                    }
                    writer.flush().map_err(|error| error.to_string())
                })()
                .map_err(Failure::Write)
            };
            let failed = matches!(result, Err(Failure::Write(_)));
            if results
                .send(Completed {
                    control: request.control.map(|control| control.id),
                    result,
                    charge: request.charge,
                })
                .is_err()
                || failed
            {
                for queued in requests.try_iter() {
                    let _ = results.send(Completed {
                        control: queued.control.map(|control| control.id),
                        result: Err(Failure::Write("The agent input channel closed.".into())),
                        charge: queued.charge,
                    });
                }
                break;
            }
        }
    });
    Input {
        sender,
        results: receiver,
        completed: VecDeque::new(),
        pending: 0,
        bytes: 0,
        closed,
        failed: None,
    }
}

impl Input {
    fn record_completed(&mut self, result: &Completed) {
        if let Err(Failure::Write(error)) = &result.result {
            self.failed = Some(error.clone());
        }
        self.pending -= 1;
        self.bytes -= result.charge;
    }

    fn collect(&mut self) {
        while let Ok(result) = self.results.try_recv() {
            self.record_completed(&result);
            self.completed.push_back(result);
        }
    }

    fn enqueue(&mut self, message: &Value, control: Option<Control>) -> Result<bool, String> {
        self.collect();
        if let Some(error) = &self.failed {
            return Err(error.clone());
        }
        if self.closed.load(Ordering::Acquire) {
            return Err("The agent input was stopped.".into());
        }
        if self.pending >= MAX_PENDING || self.completed.len() >= MAX_COMPLETED {
            return Ok(false);
        }
        let mut frame = Some(prepare(message, control)?);
        self.try_frame(&mut frame)
    }

    pub(super) fn try_frame(&mut self, frame: &mut Option<Frame>) -> Result<bool, String> {
        self.collect();
        if let Some(error) = &self.failed {
            return Err(error.clone());
        }
        if self.closed.load(Ordering::Acquire) {
            return Err("The agent input was stopped.".into());
        }
        let Some(prepared) = frame.as_ref() else {
            return Ok(true);
        };
        if self.pending >= MAX_PENDING || self.completed.len() >= MAX_COMPLETED {
            return Ok(false);
        }
        // Include active large writes in the byte budget. Count-bound small
        // messages add at most 32 KiB and can follow a large initial prompt.
        // One larger message can use the whole budget to preserve old payloads.
        let charge = prepared.0.charge;
        if self.bytes + charge > MAX_BYTES {
            return Ok(false);
        }
        let Frame(request) = frame.take().unwrap();
        match self.sender.try_send(request) {
            Ok(()) => {
                self.pending += 1;
                self.bytes += charge;
                Ok(true)
            }
            Err(mpsc::TrySendError::Full(request)) => {
                *frame = Some(Frame(request));
                Ok(false)
            }
            Err(mpsc::TrySendError::Disconnected(_)) => {
                Err("The agent input channel closed.".into())
            }
        }
    }

    pub(super) fn send(&mut self, message: &Value) -> Result<(), String> {
        if self.enqueue(message, None)? {
            Ok(())
        } else {
            Err("The agent input queue is full.".into())
        }
    }

    pub(super) fn control(
        &mut self,
        message: &Value,
        id: String,
        expires: u64,
    ) -> Result<bool, String> {
        // Preserve serial control admission. Later requests stay in their
        // mailbox, where expiry is checked again before a write is attempted.
        if !self.ready_for_control() {
            return Ok(false);
        }
        self.enqueue(message, Some(Control { id, expires }))
    }

    pub(super) fn ready_for_control(&mut self) -> bool {
        self.collect();
        self.failed.is_some() || (self.pending == 0 && self.completed.len() < MAX_COMPLETED)
    }

    pub(super) fn busy(&self) -> bool {
        self.pending != 0
    }

    pub(super) fn cancel(&self) {
        self.closed.store(true, Ordering::Release);
    }

    pub(super) fn take_completed(&mut self) -> Option<Completed> {
        self.collect();
        self.completed.pop_front()
    }

    pub(super) fn wait_completed(
        &mut self,
        timeout: std::time::Duration,
    ) -> Result<Completed, mpsc::RecvTimeoutError> {
        if let Some(completed) = self.take_completed() {
            return Ok(completed);
        }
        let completed = self.results.recv_timeout(timeout)?;
        self.record_completed(&completed);
        Ok(completed)
    }
}

impl Drop for Input {
    fn drop(&mut self) {
        self.cancel();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    struct HeldWriter {
        entered: Option<mpsc::Sender<()>>,
        release: mpsc::Receiver<()>,
        bytes: Arc<Mutex<Vec<u8>>>,
        finished: mpsc::Sender<()>,
    }
    impl Write for HeldWriter {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if let Some(entered) = self.entered.take() {
                entered.send(()).unwrap();
                self.release.recv().unwrap();
            }
            self.bytes.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    impl Drop for HeldWriter {
        fn drop(&mut self) {
            let _ = self.finished.send(());
        }
    }
    type Fixture = (
        Input,
        mpsc::Receiver<()>,
        mpsc::Sender<()>,
        Arc<Mutex<Vec<u8>>>,
        mpsc::Receiver<()>,
    );
    fn held() -> Fixture {
        let (entered, was_entered) = mpsc::channel();
        let (release, released) = mpsc::channel();
        let (finished, was_finished) = mpsc::channel();
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let writer = HeldWriter {
            entered: Some(entered),
            release: released,
            bytes: Arc::clone(&bytes),
            finished,
        };
        (start(writer), was_entered, release, bytes, was_finished)
    }
    fn completed(input: &mut Input) -> Completed {
        let until = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(completed) = input.take_completed() {
                return completed;
            }
            assert!(Instant::now() < until, "Input write did not finish");
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    #[test]
    fn input_count_includes_the_active_write_and_cancellation_drops_queued_work() {
        let (mut input, entered, release, bytes, finished) = held();
        input.send(&json!({"first":true})).unwrap();
        entered.recv_timeout(Duration::from_secs(2)).unwrap();
        for index in 1..MAX_PENDING {
            input.send(&json!({"index":index})).unwrap();
        }
        assert!(input.send(&json!({"overflow":true})).is_err());
        assert!(
            !input
                .control(&json!({"deferred":true}), "deferred".into(), u64::MAX)
                .unwrap()
        );
        drop(input);
        release.send(()).unwrap();
        finished.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(
            std::str::from_utf8(&bytes.lock().unwrap()).unwrap(),
            "{\"first\":true}\n"
        );
    }

    #[test]
    fn input_byte_budget_includes_the_active_write() {
        let (mut input, entered, release, _, finished) = held();
        let message = json!({"large":"x".repeat(MAX_BYTES/2)});
        input.send(&message).unwrap();
        entered.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(input.pending, 1);
        assert!(input.send(&message).is_err());
        drop(input);
        release.send(()).unwrap();
        finished.recv_timeout(Duration::from_secs(2)).unwrap();
    }

    #[test]
    fn small_protocol_messages_can_follow_an_oversized_initial_prompt() {
        let (mut input, entered, release, _, finished) = held();
        input
            .send(&json!({"prompt":"x".repeat(MAX_BYTES)}))
            .unwrap();
        entered.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(input.bytes, MAX_BYTES);
        input
            .send(&json!({"method":"mcpServerStatus/list"}))
            .unwrap();
        input.send(&json!({"method":"thread/goal/get"})).unwrap();
        assert_eq!(input.pending, 3);
        drop(input);
        release.send(()).unwrap();
        finished.recv_timeout(Duration::from_secs(2)).unwrap();
    }

    #[test]
    fn expired_queued_controls_are_not_written_and_later_input_keeps_its_order() {
        let (mut input, entered, release, bytes, finished) = held();
        input.send(&json!({"first":true})).unwrap();
        entered.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(
            !input
                .control(&json!({"expired":true}), "expired".into(), 0)
                .unwrap()
        );
        release.send(()).unwrap();
        assert!(completed(&mut input).result.is_ok());
        assert!(
            input
                .control(&json!({"expired":true}), "expired".into(), 0)
                .unwrap()
        );
        input.send(&json!({"last":"🌍"})).unwrap();
        let expired = completed(&mut input);
        assert_eq!(expired.control.as_deref(), Some("expired"));
        assert!(matches!(expired.result, Err(Failure::Expired)));
        assert!(completed(&mut input).result.is_ok());
        drop(input);
        finished.recv_timeout(Duration::from_secs(2)).unwrap();
        let bytes = bytes.lock().unwrap();
        let lines: Vec<Value> = std::str::from_utf8(&bytes)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(lines, vec![json!({"first":true}), json!({"last":"🌍"})]);
    }

    #[test]
    fn a_partial_write_failure_is_reported_once() {
        struct FailsAfterPrefix(bool);
        impl Write for FailsAfterPrefix {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                if !self.0 {
                    self.0 = true;
                    return Ok(bytes.len().min(3));
                }
                Err(std::io::Error::from(std::io::ErrorKind::BrokenPipe))
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let mut input = start(FailsAfterPrefix(false));
        assert!(
            input
                .control(&json!({"message":"one attempt"}), "steer".into(), u64::MAX)
                .unwrap()
        );
        let result = completed(&mut input);
        assert_eq!(result.control.as_deref(), Some("steer"));
        assert!(matches!(result.result, Err(Failure::Write(_))));
        assert!(input.take_completed().is_none());
    }
}
