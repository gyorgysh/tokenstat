// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Pseudoterminal sessions: the agent CLIs a workspace runs.
//!
//! The process lives here rather than in the front end, which is the whole
//! reason the host daemon exists. iOS cannot fork or exec, so a session an iPad
//! watches has to be owned by a machine that can, and a session that dies when
//! a window closes is no use to an automation either.
//!
//! # Reading
//!
//! Output accumulates into a bounded buffer and is read by byte offset rather
//! than pushed. A reader asks "what is there after offset N", so several
//! clients can watch one session independently and a client that reconnects
//! resumes where it left off instead of missing what happened in between.
//!
//! The buffer is capped, so a client that falls a long way behind loses the
//! oldest bytes. That is reported rather than hidden: silently skipping output
//! makes a command look like it produced less than it did.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::PathBuf;
#[cfg(unix)]
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use serde::Serialize;

/// How much output to keep per session.
///
/// Enough that a client polling a few times a second never loses anything, and
/// small enough that a runaway `yes` does not eat memory. The terminal emulator
/// keeps its own scrollback; this is only the handoff window.
const BUFFER_BYTES: usize = 512 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum PtyError {
    #[error("no session with id {0}")]
    NoSession(String),
    #[error("{0}")]
    Spawn(String),
    #[error("{0}")]
    Io(#[from] std::io::Error),
}

/// What a front end needs to know about a session.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionInfo {
    pub id: String,
    /// The command as launched, for a tab label.
    pub command: String,
    pub cwd: String,
    /// Workspace this belongs to, so sessions can be grouped by folder.
    pub workspace_id: Option<String>,
    pub rows: u16,
    pub cols: u16,
    pub alive: bool,
    /// Set once the process has exited. `None` while it still runs, which is
    /// not the same as having exited with status 0.
    pub exit_code: Option<i32>,
    /// Total bytes ever produced. A client's read offset is against this.
    pub total_bytes: u64,
}

/// Output that was waiting.
#[derive(Debug, Clone)]
pub struct Chunk {
    /// Raw terminal bytes. Not valid UTF-8 in general: an escape sequence can
    /// be cut in half at a read boundary, so this stays bytes and the transport
    /// decides how to encode it.
    pub bytes: Vec<u8>,
    /// Offset to ask for next time.
    pub next_offset: u64,
    /// Bytes dropped before this chunk because the reader fell behind the
    /// buffer. Zero in normal use, and never silently ignored.
    pub dropped: u64,
}

/// A Device Status Report asking where the cursor is.
const CURSOR_POSITION_REQUEST: &[u8] = b"\x1b[6n";

/// The answer: row 1, column 1.
///
/// A real terminal reports where its cursor actually is. Nothing here draws a
/// screen, so there is no cursor to report and the top left corner is the
/// honest answer for a session that has printed nothing yet.
const CURSOR_POSITION_REPLY: &[u8] = b"\x1b[1;1R";

/// Whether this output asked the terminal where the cursor is.
///
/// It has to be answered. Windows builds its pseudoconsole with
/// `PSEUDOCONSOLE_INHERIT_CURSOR`, so the console host asks this question
/// before it will let the program start, and waits for the reply. With nobody
/// answering, the command never runs at all: no output, no exit, a session that
/// looks alive until its budget kills it.
///
/// `tail` carries the last few bytes of the previous read, because a read
/// boundary can fall in the middle of the request.
fn wants_cursor_position(tail: &mut Vec<u8>, bytes: &[u8]) -> bool {
    let split = CURSOR_POSITION_REQUEST.len() - 1;
    tail.extend_from_slice(bytes);
    let found = tail
        .windows(CURSOR_POSITION_REQUEST.len())
        .any(|w| w == CURSOR_POSITION_REQUEST);
    if tail.len() > split {
        let keep = tail.len() - split;
        tail.drain(..keep);
    }
    found
}

/// A bounded window over one session's output.
struct Buffer {
    data: Vec<u8>,
    /// Total bytes ever written, including those since discarded.
    total: u64,
}

impl Buffer {
    fn new() -> Buffer {
        Buffer {
            data: Vec::with_capacity(8 * 1024),
            total: 0,
        }
    }

    fn push(&mut self, bytes: &[u8]) {
        self.data.extend_from_slice(bytes);
        self.total += bytes.len() as u64;
        if self.data.len() > BUFFER_BYTES {
            let excess = self.data.len() - BUFFER_BYTES;
            self.data.drain(..excess);
        }
    }

    /// Offset of the oldest byte still held.
    fn earliest(&self) -> u64 {
        self.total - self.data.len() as u64
    }

    fn read_from(&self, offset: u64) -> Chunk {
        let earliest = self.earliest();
        // A reader behind the window lost bytes. Say how many rather than
        // quietly resuming, so the UI can show that output is missing.
        let (start, dropped) = if offset < earliest {
            (0usize, earliest - offset)
        } else {
            ((offset - earliest) as usize, 0)
        };
        let start = start.min(self.data.len());
        Chunk {
            bytes: self.data[start..].to_vec(),
            next_offset: self.total,
            dropped,
        }
    }
}

struct Session {
    info: Mutex<SessionInfo>,
    buffer: Arc<Mutex<Buffer>>,
    /// Shared with the reader thread, which answers the terminal's own
    /// questions. See `wants_cursor_position`.
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    master: Mutex<Box<dyn portable_pty::MasterPty + Send>>,
    child: Mutex<Box<dyn portable_pty::Child + Send + Sync>>,
    alive: Arc<AtomicBool>,
    exit_code: Arc<AtomicI32>,
}

/// What to launch.
#[derive(Debug, Clone)]
pub struct Spawn {
    pub command: String,
    pub args: Vec<String>,
    pub cwd: PathBuf,
    pub workspace_id: Option<String>,
    pub rows: u16,
    pub cols: u16,
}

/// The process-wide manager.
///
/// Deliberately not owned by a host session. Reopening the archive against a
/// different database replaces that session, and terminals must not die
/// because someone changed a setting.
pub fn manager() -> &'static Manager {
    static MANAGER: std::sync::OnceLock<Manager> = std::sync::OnceLock::new();
    MANAGER.get_or_init(Manager::new)
}

/// Every live session in this process.
#[derive(Default)]
pub struct Manager {
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    next: Mutex<u64>,
}

impl Manager {
    pub fn new() -> Manager {
        Manager::default()
    }

    /// Launch a command in a pty.
    ///
    /// The reader runs on its own thread, and has to: a pty read blocks until
    /// there is output, and doing that on a request thread would freeze every
    /// other call for as long as the command stayed quiet.
    pub fn spawn(&self, req: &Spawn) -> Result<SessionInfo, PtyError> {
        let size = PtySize {
            rows: req.rows.max(1),
            cols: req.cols.max(1),
            pixel_width: 0,
            pixel_height: 0,
        };
        let pair = native_pty_system()
            .openpty(size)
            .map_err(|e| PtyError::Spawn(e.to_string()))?;

        let mut cmd = CommandBuilder::new(&req.command);
        for a in &req.args {
            cmd.arg(a);
        }
        cmd.cwd(&req.cwd);
        // Agent CLIs draw boxes and colour. Without this they fall back to
        // something far uglier, and some refuse interactive mode entirely.
        cmd.env("TERM", "xterm-256color");
        #[cfg(unix)]
        if let Some(path) = login_shell_path() {
            cmd.env("PATH", path);
        }

        let child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| PtyError::Spawn(e.to_string()))?;
        // The slave has to be dropped, or the reader never sees EOF when the
        // child exits and the session looks alive forever.
        drop(pair.slave);

        let mut reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| PtyError::Spawn(e.to_string()))?;
        let writer = pair
            .master
            .take_writer()
            .map_err(|e| PtyError::Spawn(e.to_string()))?;

        let id = {
            let mut n = self.next.lock().unwrap_or_else(PoisonError::into_inner);
            *n += 1;
            format!("pty-{n}")
        };

        let buffer = Arc::new(Mutex::new(Buffer::new()));
        let alive = Arc::new(AtomicBool::new(true));
        let exit_code = Arc::new(AtomicI32::new(i32::MIN));
        let writer = Arc::new(Mutex::new(writer));

        {
            let buffer = Arc::clone(&buffer);
            let alive = Arc::clone(&alive);
            let writer = Arc::clone(&writer);
            std::thread::spawn(move || {
                let mut chunk = [0u8; 8 * 1024];
                // Enough to catch a status request split across two reads.
                let mut tail: Vec<u8> = Vec::new();
                loop {
                    match reader.read(&mut chunk) {
                        Ok(0) => break,
                        Ok(n) => {
                            let bytes = &chunk[..n];
                            if wants_cursor_position(&mut tail, bytes) {
                                let mut w = writer.lock().unwrap_or_else(PoisonError::into_inner);
                                let _ = w.write_all(CURSOR_POSITION_REPLY);
                                let _ = w.flush();
                            }
                            buffer
                                .lock()
                                .unwrap_or_else(PoisonError::into_inner)
                                .push(bytes);
                        }
                        Err(_) => break,
                    }
                }
                alive.store(false, Ordering::SeqCst);
            });
        }

        let info = SessionInfo {
            id: id.clone(),
            command: req.command.clone(),
            cwd: req.cwd.display().to_string(),
            workspace_id: req.workspace_id.clone(),
            rows: size.rows,
            cols: size.cols,
            alive: true,
            exit_code: None,
            total_bytes: 0,
        };

        let session = Arc::new(Session {
            info: Mutex::new(info.clone()),
            buffer,
            writer,
            master: Mutex::new(pair.master),
            child: Mutex::new(child),
            alive,
            exit_code,
        });

        self.sessions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(id, session);

        Ok(info)
    }

    fn get(&self, id: &str) -> Result<Arc<Session>, PtyError> {
        self.sessions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id)
            .cloned()
            .ok_or_else(|| PtyError::NoSession(id.to_string()))
    }

    /// Send input. Bytes, not text: a keystroke may be an escape sequence.
    pub fn write(&self, id: &str, bytes: &[u8]) -> Result<(), PtyError> {
        let s = self.get(id)?;
        let mut w = s.writer.lock().unwrap_or_else(PoisonError::into_inner);
        w.write_all(bytes)?;
        w.flush()?;
        Ok(())
    }

    /// Tell the program its window changed, so it redraws at the new size.
    pub fn resize(&self, id: &str, rows: u16, cols: u16) -> Result<(), PtyError> {
        let s = self.get(id)?;
        let size = PtySize {
            rows: rows.max(1),
            cols: cols.max(1),
            pixel_width: 0,
            pixel_height: 0,
        };
        s.master
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .resize(size)
            .map_err(|e| PtyError::Spawn(e.to_string()))?;
        let mut info = s.info.lock().unwrap_or_else(PoisonError::into_inner);
        info.rows = size.rows;
        info.cols = size.cols;
        Ok(())
    }

    /// Output after `offset`. Returns immediately, empty when there is none.
    pub fn read(&self, id: &str, offset: u64) -> Result<Chunk, PtyError> {
        let s = self.get(id)?;
        let chunk = s
            .buffer
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .read_from(offset);
        Ok(chunk)
    }

    pub fn info(&self, id: &str) -> Result<SessionInfo, PtyError> {
        let s = self.get(id)?;
        Ok(self.snapshot(&s))
    }

    pub fn list(&self) -> Vec<SessionInfo> {
        let sessions = self.sessions.lock().unwrap_or_else(PoisonError::into_inner);
        let mut out: Vec<_> = sessions.values().map(|s| self.snapshot(s)).collect();
        out.sort_by(|a, b| a.id.cmp(&b.id));
        out
    }

    /// Current state, folding in whatever the reader thread and the child have
    /// since reported.
    fn snapshot(&self, s: &Arc<Session>) -> SessionInfo {
        // Reap here, so a finished process stops claiming to run. The lock is
        // only ever held long enough to ask, so waiting for it is cheap, and a
        // missed reap is not: nothing else ever asks the child again, so a
        // session whose reap was skipped looks alive until something kills it.
        // That is also why a poisoned lock is recovered rather than skipped.
        {
            let mut child = s.child.lock().unwrap_or_else(PoisonError::into_inner);
            if let Ok(Some(status)) = child.try_wait() {
                s.alive.store(false, Ordering::SeqCst);
                s.exit_code
                    .store(status.exit_code() as i32, Ordering::SeqCst);
            }
        }

        let mut info = s
            .info
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        info.alive = s.alive.load(Ordering::SeqCst);
        let code = s.exit_code.load(Ordering::SeqCst);
        // `None` while running is not the same as exiting with 0.
        info.exit_code = (code != i32::MIN).then_some(code);
        info.total_bytes = s
            .buffer
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .total;
        info
    }

    /// Stop the process. Killing an already dead session is not an error.
    pub fn kill(&self, id: &str) -> Result<(), PtyError> {
        let s = self.get(id)?;
        let _ = s
            .child
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .kill();
        s.alive.store(false, Ordering::SeqCst);
        Ok(())
    }

    /// Kill and forget. The buffer goes with it.
    pub fn close(&self, id: &str) -> Result<(), PtyError> {
        let _ = self.kill(id);
        self.sessions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(id);
        Ok(())
    }
}

/// A GUI app or launch agent does not inherit the interactive shell's PATH.
/// Ask the user's login shell for it so direct CLI launches work just like
/// they do from Terminal.app. The inherited PATH remains the fallback.
#[cfg(unix)]
fn login_shell_path() -> Option<String> {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
    let output = Command::new(shell)
        .args(["-ilc", "printf %s \"$PATH\""])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let path = String::from_utf8(output.stdout).ok()?;
    (!path.trim().is_empty()).then_some(path.trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wait_for(mut f: impl FnMut() -> bool) -> bool {
        for _ in 0..200 {
            if f() {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        false
    }

    /// Run a script in the platform's own shell.
    ///
    /// The two spellings are given side by side rather than hidden behind a
    /// helper per test, because a fixture that only runs on one platform is a
    /// fixture that stops being checked on the others.
    fn spawn(m: &Manager, unix: &str, windows: &str) -> SessionInfo {
        // Both are always passed, only one of them ever runs.
        let _ = (unix, windows);
        #[cfg(unix)]
        let (command, args) = {
            let _ = windows;
            ("/bin/sh".to_string(), vec!["-c".to_string(), unix.into()])
        };
        // `/V:ON` turns on `!var!` expansion, which a script needs when it sets
        // a variable and reads it back in the same line.
        #[cfg(windows)]
        let (command, args) = (
            "cmd.exe".to_string(),
            vec!["/V:ON".to_string(), "/C".to_string(), windows.into()],
        );

        m.spawn(&Spawn {
            command,
            args,
            cwd: std::env::temp_dir(),
            workspace_id: None,
            rows: 24,
            cols: 80,
        })
        .expect("spawn")
    }

    /// A script that stays busy for roughly a minute without needing input.
    fn stay_busy(m: &Manager) -> SessionInfo {
        spawn(m, "sleep 60", "ping -n 61 127.0.0.1 > nul")
    }

    #[test]
    fn output_is_captured_and_read_by_offset() {
        let m = Manager::new();
        let s = spawn(&m, "echo hello-from-pty", "echo hello-from-pty");

        assert!(wait_for(|| {
            m.read(&s.id, 0)
                .map(|c| String::from_utf8_lossy(&c.bytes).contains("hello-from-pty"))
                .unwrap_or(false)
        }));

        // Reading again from the returned offset does not repeat what the
        // reader already has, which is what lets a client poll without
        // reprocessing everything each time. Asserting on the payload rather
        // than on an empty chunk, because a terminal may still emit control
        // sequences of its own after the program has said its piece.
        let first = m.read(&s.id, 0).unwrap();
        let second = m.read(&s.id, first.next_offset).unwrap();
        assert!(!String::from_utf8_lossy(&second.bytes).contains("hello-from-pty"));
        assert_eq!(second.dropped, 0);
    }

    #[test]
    fn a_finished_process_reports_its_exit_code() {
        let m = Manager::new();
        let s = spawn(&m, "exit 3", "exit 3");
        assert!(
            wait_for(|| m.info(&s.id).map(|i| !i.alive).unwrap_or(false)),
            "a process that ended is not still reported as running"
        );
        assert_eq!(m.info(&s.id).unwrap().exit_code, Some(3));
    }

    #[test]
    fn a_running_process_has_no_exit_code() {
        // None while running is not the same as exiting with 0, and a UI that
        // conflates them reports "finished" for a live session.
        let m = Manager::new();
        let s = stay_busy(&m);
        let info = m.info(&s.id).unwrap();
        assert!(info.alive);
        assert_eq!(info.exit_code, None);
        m.close(&s.id).unwrap();
    }

    #[test]
    fn input_reaches_the_program() {
        let m = Manager::new();
        let s = spawn(
            &m,
            "read line; echo got:$line",
            "set /p line= & echo got:!line!",
        );
        std::thread::sleep(std::time::Duration::from_millis(250));
        // Carriage return, because that is what Return sends. A line feed is
        // not a line ending to a Windows console, so `set /p` waits for a key
        // that never comes, and a Unix terminal maps the return to a newline
        // for the program on the other side anyway.
        m.write(&s.id, b"ping\r").unwrap();

        assert!(wait_for(|| {
            m.read(&s.id, 0)
                .map(|c| String::from_utf8_lossy(&c.bytes).contains("got:ping"))
                .unwrap_or(false)
        }));
    }

    #[test]
    fn killing_stops_a_long_running_process() {
        let m = Manager::new();
        let s = stay_busy(&m);
        assert!(m.info(&s.id).unwrap().alive);
        m.kill(&s.id).unwrap();
        assert!(wait_for(|| m
            .info(&s.id)
            .map(|i| !i.alive)
            .unwrap_or(false)));
        // Killing twice is not an error: a UI may not know it already died.
        assert!(m.kill(&s.id).is_ok());
        m.close(&s.id).unwrap();
    }

    #[test]
    fn closing_forgets_the_session() {
        let m = Manager::new();
        let s = stay_busy(&m);
        assert_eq!(m.list().len(), 1);
        m.close(&s.id).unwrap();
        assert!(m.list().is_empty());
        assert!(matches!(m.read(&s.id, 0), Err(PtyError::NoSession(_))));
    }

    #[test]
    fn a_cursor_position_request_is_recognised_across_a_read_boundary() {
        // Windows will not start the command until this is answered, and the
        // request can arrive in two pieces, so a scan of one read alone would
        // miss it and hang the session for its whole budget.
        let mut tail = Vec::new();
        assert!(!wants_cursor_position(&mut tail, b"\x1b[6"));
        assert!(wants_cursor_position(&mut tail, b"n"));

        let mut tail = Vec::new();
        assert!(wants_cursor_position(&mut tail, b"before\x1b[6nafter"));
        assert!(!wants_cursor_position(&mut tail, b"plain output"));
    }

    #[test]
    fn a_reader_that_falls_behind_is_told_how_much_it_lost() {
        // Silently resuming would make a terminal look like the command
        // produced less output than it did.
        let mut b = Buffer::new();
        b.push(&vec![b'a'; BUFFER_BYTES + 1000]);
        let chunk = b.read_from(0);
        assert_eq!(chunk.dropped, 1000);
        assert_eq!(chunk.bytes.len(), BUFFER_BYTES);
        assert_eq!(chunk.next_offset, (BUFFER_BYTES + 1000) as u64);
    }

    #[test]
    fn resize_is_accepted_and_remembered() {
        let m = Manager::new();
        let s = stay_busy(&m);
        m.resize(&s.id, 40, 120).unwrap();
        let info = m.info(&s.id).unwrap();
        assert_eq!((info.rows, info.cols), (40, 120));
        m.close(&s.id).unwrap();
    }

    #[test]
    fn an_unknown_session_says_so() {
        let m = Manager::new();
        assert!(matches!(m.write("nope", b"x"), Err(PtyError::NoSession(_))));
        assert!(matches!(m.info("nope"), Err(PtyError::NoSession(_))));
    }
}
