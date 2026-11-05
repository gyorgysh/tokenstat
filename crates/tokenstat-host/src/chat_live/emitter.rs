// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Bounded output forwarding with cancellable backpressure and a final flush.
use super::input::{self, Completed, Failure, Input};
use serde_json::Value;
use std::io::Write;
use std::path::Path;
use std::sync::mpsc;
use std::time::{Duration, Instant};

const STOP_FLUSH: Duration = Duration::from_millis(250);

pub(super) struct Emitter {
    writer: Input,
    stop: super::mailbox::Stop,
    stopped_at: Option<Instant>,
    failure: Option<String>,
}

impl Emitter {
    pub(super) fn new<W: Write>(
        writer: impl FnOnce() -> W + Send + 'static,
        directory: &Path,
    ) -> Self {
        Self {
            writer: input::start_with(writer),
            stop: super::mailbox::Stop::new(directory),
            stopped_at: None,
            failure: None,
        }
    }

    fn fail(&mut self, error: String) -> Result<(), String> {
        self.writer.cancel();
        self.failure = Some(error.clone());
        Err(error)
    }

    fn completed(&mut self, result: Completed) -> Result<(), String> {
        match result.result {
            Ok(()) => Ok(()),
            Err(Failure::Write(error)) => {
                self.fail(format!("Could not write turn output: {error}"))
            }
            Err(Failure::Expired) => self.fail("The turn output could not be written.".into()),
        }
    }

    fn check(&mut self) -> Result<(), String> {
        if let Some(error) = &self.failure {
            return Err(error.clone());
        }
        while let Some(completed) = self.writer.take_completed() {
            self.completed(completed)?;
        }
        Ok(())
    }

    fn wait(&mut self) -> Result<(), String> {
        match self.writer.wait_completed(Duration::from_millis(5)) {
            Ok(completed) => self.completed(completed)?,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return self.fail("The turn output channel closed.".into());
            }
        }
        if self.stop.requested()
            && self.stopped_at.get_or_insert_with(Instant::now).elapsed() >= STOP_FLUSH
        {
            return self.fail("The turn was stopped.".into());
        }
        Ok(())
    }

    pub(super) fn emit(&mut self, value: &Value) -> Result<(), String> {
        self.check()?;
        let mut frame = Some(input::frame(value)?);
        loop {
            self.check()?;
            match self.writer.try_frame(&mut frame) {
                Ok(true) => return Ok(()),
                Ok(false) => self.wait()?,
                Err(error) => return self.fail(format!("Could not write turn output: {error}")),
            }
        }
    }

    pub(super) fn finish(&mut self) -> Result<(), String> {
        loop {
            self.check()?;
            if !self.writer.busy() {
                return Ok(());
            }
            self.wait()?;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;
    use std::sync::{Arc, Mutex};

    struct Capture(Arc<Mutex<Vec<u8>>>);
    impl Write for Capture {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn flush_preserves_json_order_utf8_and_readable_output_after_stop() {
        let root = tempfile::tempdir().unwrap();
        fs::write(root.path().join("stop"), "").unwrap();
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let captured = Arc::clone(&bytes);
        let mut output = Emitter::new(move || Capture(captured), root.path());
        let frames: Vec<_> = (0..40)
            .map(|index| json!({"index":index,"text":"🌍 café"}))
            .collect();
        for frame in &frames {
            output.emit(frame).unwrap();
        }
        output.finish().unwrap();
        let bytes = bytes.lock().unwrap();
        let actual: Vec<Value> = std::str::from_utf8(&bytes)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(actual, frames);
    }

    #[test]
    fn stop_breaks_output_backpressure_and_discards_unstarted_writes() {
        struct Held {
            entered: mpsc::Sender<()>,
            release: mpsc::Receiver<()>,
            bytes: Arc<Mutex<Vec<u8>>>,
            finished: mpsc::Sender<()>,
        }
        impl Write for Held {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                self.entered.send(()).unwrap();
                self.release.recv().unwrap();
                self.bytes.lock().unwrap().extend_from_slice(bytes);
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        impl Drop for Held {
            fn drop(&mut self) {
                let _ = self.finished.send(());
            }
        }
        let root = tempfile::tempdir().unwrap();
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let (entered, was_entered) = mpsc::channel();
        let (release, released) = mpsc::channel();
        let (finished, was_finished) = mpsc::channel();
        let writer = Held {
            entered,
            release: released,
            bytes: Arc::clone(&bytes),
            finished,
        };
        let mut output = Emitter::new(move || writer, root.path());
        for index in 0..8 {
            output.emit(&json!({"index":index})).unwrap();
        }
        was_entered.recv_timeout(Duration::from_secs(2)).unwrap();
        fs::write(root.path().join("stop"), "").unwrap();
        let start = Instant::now();
        assert!(output.emit(&json!({"index":8})).is_err());
        assert!(start.elapsed() < Duration::from_secs(2));
        assert!(output.finish().is_err());
        assert!(output.emit(&json!({"late":true})).is_err());
        drop(output);
        release.send(()).unwrap();
        was_finished.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(&*bytes.lock().unwrap(), b"{\"index\":0}\n");
    }

    #[test]
    fn asynchronous_output_errors_fail_the_final_flush() {
        struct Broken;
        impl Write for Broken {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
                Err(std::io::Error::from(std::io::ErrorKind::BrokenPipe))
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let root = tempfile::tempdir().unwrap();
        let mut output = Emitter::new(|| Broken, root.path());
        let _ = output.emit(&json!({"type":"result"}));
        assert!(output.finish().is_err());
        assert!(output.emit(&json!({"late":true})).is_err());
    }
}
