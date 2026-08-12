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

use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::path::PathBuf;
#[cfg(unix)]
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError};

use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use serde::Serialize;

/// How much output to keep per session.
///
/// Enough that a client polling a few times a second never loses anything, and
/// small enough that a runaway `yes` does not eat memory. The terminal emulator
/// keeps its own scrollback; this is only the handoff window.
const BUFFER_BYTES: usize = 8 * 1024 * 1024;

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
    /// When the process last produced output, epoch milliseconds. `None`
    /// until the first output, so "nothing seen yet" is not the same as
    /// "idle since launch".
    pub last_activity_at_ms: Option<u64>,
    /// The child's process id, which is the root of the subtree an activity
    /// detector measures. `None` once the process is gone.
    pub pid: Option<u32>,
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
    /// True while the producer is paused because the handoff window is full.
    pub paused: bool,
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
            paused: self.data.len() >= BUFFER_BYTES,
        }
    }

    fn discard_before(&mut self, offset: u64) {
        let earliest = self.earliest();
        if offset > earliest {
            let count = (offset - earliest).min(self.data.len() as u64) as usize;
            self.data.drain(..count);
        }
    }
}

struct Session {
    info: Mutex<SessionInfo>,
    buffer: Arc<Mutex<Buffer>>,
    buffer_space: Arc<Condvar>,
    /// Shared with the reader thread, which answers the terminal's own
    /// questions. See `wants_cursor_position`.
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    master: Mutex<Box<dyn portable_pty::MasterPty + Send>>,
    child: Mutex<Box<dyn portable_pty::Child + Send + Sync>>,
    alive: Arc<AtomicBool>,
    exit_code: Arc<AtomicI32>,
    last_activity: Arc<Mutex<Option<u64>>>,
    /// Front ends currently showing this session, by opaque client id.
    viewers: Mutex<HashMap<String, Viewer>>,
    read_offsets: Mutex<HashMap<String, u64>>,
    stream_readers: Mutex<HashSet<String>>,
}

/// One front end showing a session, and the geometry it can display.
///
/// A pty has exactly one size, so two front ends of different shapes cannot
/// each get their own. The size that works for both is the smaller one in each
/// axis: the program then wraps inside what the phone can show, and the Mac
/// draws that same content in part of a wider view, which is correct rather
/// than merely tolerable. A pty sized to the Mac and shown on a phone is not,
/// because the wrap points land off the side of the screen.
#[derive(Debug, Clone, Copy)]
struct Viewer {
    rows: u16,
    cols: u16,
    /// Last time this viewer was heard from. A front end that is killed, loses
    /// its network, or is swiped away never says goodbye, and a viewer that
    /// nobody can see must not keep the terminal small forever.
    seen_ms: u64,
}

/// How long a viewer counts without being heard from.
///
/// Every front end polls this session for output far more often than this, so
/// a live viewer refreshes many times over inside the window. It only decides
/// how long a *dead* one keeps constraining the size, and the explicit detach
/// on close is what handles the ordinary case, so this can be generous without
/// anybody waiting on it.
const VIEWER_TTL_MS: u64 = 15_000;

/// Epoch milliseconds, for activity timestamps.
fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
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
    /// The user asked for no colour: NO_COLOR=1 and nothing that overrides it.
    pub no_color: bool,
    /// The emulator is painting a dark background. `None` when the client did
    /// not say, which keeps an older front end's spawns exactly as they were.
    pub dark: Option<bool>,
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
    /// Fully-started login shells waiting to be handed over, so a Shell click
    /// does not pay a login-shell startup. Kept out of `sessions`: a pooled
    /// shell has no client until it is taken.
    pool: Mutex<Vec<Arc<Session>>>,
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
        // The Shell tile is the click a person watches. A shell that was
        // started when the daemon was, and kept idle since, hands over its
        // already-loaded process instead of making the click pay a full
        // login-shell startup. Colour is part of the deal: a pooled shell was
        // started with the colour defaults (and no COLORFGBG), so a no-colour
        // request, or a light-window request that needs COLORFGBG=0;15, takes
        // the fresh path rather than inheriting the wrong setting.
        if is_shell_profile(req) && !req.no_color && req.dark != Some(false) {
            let pooled = self
                .pool
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .pop();
            if let Some(shell) = pooled {
                match self.handoff_pooled(shell, req) {
                    Ok(info) => {
                        self.replenish_pool();
                        return Ok(info);
                    }
                    Err(_) => {
                        // The pooled shell was already gone or refused to
                        // answer. Fall through to a fresh spawn rather than
                        // losing the click.
                        self.replenish_pool();
                    }
                }
            }
        }
        self.spawn_fresh(req)
    }

    /// The ordinary spawn path: a brand-new pty and a brand-new process.
    fn spawn_fresh(&self, req: &Spawn) -> Result<SessionInfo, PtyError> {
        let id = self.next_session_id();
        let (session, info) = self.build_session(req, id)?;
        self.sessions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(info.id.clone(), session);
        Ok(info)
    }

    /// Open a pty, spawn the command and start its reader thread. Used by both
    /// the fresh path and the shell pool, so the two share one definition of
    /// what a session is.
    fn build_session(
        &self,
        req: &Spawn,
        id: String,
    ) -> Result<(Arc<Session>, SessionInfo), PtyError> {
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
        // Environment order matters. CommandBuilder starts from the process
        // env (launchd's thin set for hostd). The login shell's full env is
        // the interactive baseline; terminal claims (TERM, colour) must be
        // applied *after* it, or a profile that exports NO_COLOR / a dumb TERM
        // quietly undoes the emulator's settings.
        //
        // When the login resolve is ready: replace the base entirely so
        // launchd-only keys (CI leftovers, packaging vars) do not leak into
        // agent CLIs. That is the measured hostd-vs-Terminal gap: a hybrid
        // env made harnesses spend seconds on plugin/hook paths that a real
        // shell session never took.
        //
        // When it is not ready yet: do not block a Shell tile on a second
        // full profile startup. Harnesses get a short wait (warm thread is
        // usually done); if still pending, PATH is filled in and hostile
        // keys are stripped from the inherited base.
        #[cfg(unix)]
        {
            apply_login_environment(&mut cmd, req);
        }
        apply_terminal_environment(&mut cmd, req);

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

        let buffer = Arc::new(Mutex::new(Buffer::new()));
        let buffer_space = Arc::new(Condvar::new());
        let alive = Arc::new(AtomicBool::new(true));
        let exit_code = Arc::new(AtomicI32::new(i32::MIN));
        let last_activity = Arc::new(Mutex::new(None));
        let writer = Arc::new(Mutex::new(writer));

        {
            let buffer = Arc::clone(&buffer);
            let buffer_space = Arc::clone(&buffer_space);
            let alive = Arc::clone(&alive);
            let last_activity = Arc::clone(&last_activity);
            let writer = Arc::clone(&writer);
            std::thread::spawn(move || {
                let mut chunk = [0u8; 8 * 1024];
                // Enough to catch a status request split across two reads.
                let mut tail: Vec<u8> = Vec::new();
                loop {
                    let mut buffered = buffer.lock().unwrap_or_else(PoisonError::into_inner);
                    while buffered.data.len() >= BUFFER_BYTES && alive.load(Ordering::SeqCst) {
                        buffered = buffer_space
                            .wait(buffered)
                            .unwrap_or_else(PoisonError::into_inner);
                    }
                    drop(buffered);
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
                            *last_activity.lock().unwrap_or_else(PoisonError::into_inner) =
                                Some(now_ms());
                        }
                        Err(_) => break,
                    }
                }
                alive.store(false, Ordering::SeqCst);
                buffer_space.notify_all();
            });
        }

        let info = SessionInfo {
            id: id.clone(),
            pid: None,
            command: req.command.clone(),
            cwd: req.cwd.display().to_string(),
            workspace_id: req.workspace_id.clone(),
            rows: size.rows,
            cols: size.cols,
            alive: true,
            exit_code: None,
            total_bytes: 0,
            last_activity_at_ms: None,
        };

        let session = Arc::new(Session {
            info: Mutex::new(info.clone()),
            buffer,
            buffer_space,
            writer,
            master: Mutex::new(pair.master),
            child: Mutex::new(child),
            alive,
            exit_code,
            last_activity,
            viewers: Mutex::new(HashMap::new()),
            read_offsets: Mutex::new(HashMap::new()),
            stream_readers: Mutex::new(HashSet::new()),
        });

        Ok((session, info))
    }

    fn next_session_id(&self) -> String {
        let mut n = self.next.lock().unwrap_or_else(PoisonError::into_inner);
        *n += 1;
        format!("pty-{n}")
    }

    /// Hand a pooled shell over as a real session.
    ///
    /// The shell is already fully started and sitting at a prompt (see
    /// [`Self::build_pool_shell`]), so the click pays for a resize, a `cd`
    /// into the workspace and a registry insert instead of a full login-shell
    /// startup. The handoff is invisible in the transcript: the `cd` is
    /// followed by a unique marker, and once the marker is seen the whole
    /// pre-handoff buffer is discarded, so a client that reads from offset 0
    /// sees the shell as it is now, in the requested folder.
    ///
    /// If the marker never arrives the handoff **fails** rather than clearing
    /// the buffer and returning anyway. Clearing a half-started shell was how
    /// a Shell click became eight seconds of blank pane: the profile was still
    /// loading, the buffer was wiped, and nothing else printed until it
    /// finished. Falling through to a fresh spawn is better than a blank pane.
    fn handoff_pooled(&self, shell: Arc<Session>, req: &Spawn) -> Result<SessionInfo, PtyError> {
        let result = (|| {
            // A pooled shell that exited while idle is not a session to hand
            // over. (It is still killed on the way out, see below.)
            if !session_is_alive(&shell) {
                return Err(PtyError::Spawn(
                    "the pooled shell had already exited".into(),
                ));
            }

            let size = PtySize {
                rows: req.rows.max(1),
                cols: req.cols.max(1),
                pixel_width: 0,
                pixel_height: 0,
            };
            shell
                .master
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .resize(size)
                .map_err(|e| PtyError::Spawn(e.to_string()))?;

            // Point the shell at the workspace and prove it got there.
            let marker = format!("__TS_READY_{}__", next_marker());
            let quoted = shell_quote(&req.cwd.to_string_lossy());
            {
                let mut writer = shell.writer.lock().unwrap_or_else(PoisonError::into_inner);
                writer
                    .write_all(format!("cd {quoted}\recho {marker}\r").as_bytes())
                    .map_err(|e| PtyError::Spawn(e.to_string()))?;
                writer.flush().map_err(|e| PtyError::Spawn(e.to_string()))?;
            }

            // A ready pooled shell answers in milliseconds. A couple of
            // seconds is only a safety net for a slow `cd` on a network
            // volume; past that the shell is not the ready one we thought.
            if !wait_for_marker(&shell, &marker, HANDOFF_READY_TIMEOUT) {
                return Err(PtyError::Spawn(
                    "the pooled shell did not accept the handoff".into(),
                ));
            }

            // Discard everything before the handoff: the idle prompt, the cd
            // line, the marker. The client starts at offset 0 with the shell
            // already in the requested folder. The reader thread may push
            // while we clear; the buffer lock serializes, and nothing the
            // client reads predates the handoff.
            clear_session_buffer(&shell);

            // Reprint the prompt the clear just removed, so the pane opens on
            // a prompt rather than on blank space.
            {
                let mut writer = shell.writer.lock().unwrap_or_else(PoisonError::into_inner);
                let _ = writer.write_all(b"\r");
                let _ = writer.flush();
            }

            let id = self.next_session_id();
            {
                let mut info = shell.info.lock().unwrap_or_else(PoisonError::into_inner);
                info.id = id.clone();
                info.command = req.command.clone();
                info.cwd = req.cwd.display().to_string();
                info.workspace_id = req.workspace_id.clone();
                info.rows = size.rows;
                info.cols = size.cols;
                // The handoff itself counts as activity: the shell has just
                // answered and is about to print its prompt.
                *shell
                    .last_activity
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner) = Some(now_ms());
            }
            self.sessions
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(id.clone(), Arc::clone(&shell));
            Ok(self.snapshot(&shell))
        })();

        // A shell that failed to hand over must not keep running unowned.
        if result.is_err() {
            let _ = shell
                .child
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .kill();
        }
        result
    }

    /// Build one fully-started login shell for the pool, without registering
    /// it as a session. The shell sources its own profile, so it needs no
    /// login environment injected, exactly like the Shell tile it will serve.
    ///
    /// **Ready means at a prompt**, not merely forked. `build_session` returns
    /// as soon as the process exists; a loaded `.zshrc` can still take many
    /// seconds after that. Parking a half-started shell made every first
    /// Shell click clear that partial buffer and wait out the rest of the
    /// profile as a blank pane. The warm path pays that wait on a background
    /// thread instead, and only parks shells that have answered a marker.
    #[cfg(unix)]
    fn build_pool_shell(&self) -> Option<Arc<Session>> {
        let cwd = std::env::var("HOME").unwrap_or_else(|_| "/".into());
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
        let args: Vec<String> = if shell.ends_with("zsh") {
            vec!["-il".to_string()]
        } else {
            Vec::new()
        };
        let req = Spawn {
            command: shell,
            args,
            cwd: PathBuf::from(cwd),
            workspace_id: None,
            rows: 24,
            cols: 80,
            no_color: false,
            dark: None,
        };
        let (session, _) = self.build_session(&req, self.next_session_id()).ok()?;
        if !prove_shell_ready(&session, POOL_READY_TIMEOUT) {
            let _ = session
                .child
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .kill();
            return None;
        }
        Some(session)
    }

    /// Start a replacement pooled shell in the background after one was taken.
    ///
    /// Only the process-wide manager refills from a background thread; a test
    /// manager keeps exactly the pool the test put there, so tests never spawn
    /// login shells they did not ask for.
    fn replenish_pool(&self) {
        if !std::ptr::eq(self as *const Manager, manager() as *const Manager) {
            return;
        }
        #[cfg(unix)]
        std::thread::spawn(|| {
            let m = manager();
            if let Some(shell) = m.build_pool_shell() {
                park_pool_shell(m, shell);
            }
        });
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
        Self::apply_size(&s, rows, cols)
    }

    /// Resize on behalf of one named front end.
    ///
    /// The session is then set to the largest geometry every live viewer can
    /// show, which is the smallest one in each axis. This is what makes a phone
    /// and a Mac watching the same terminal both correct at once, and it is
    /// also what puts the Mac back to its own size the moment the phone lets
    /// go: the constraint leaves with the viewer that imposed it.
    pub fn resize_viewer(
        &self,
        id: &str,
        viewer: &str,
        rows: u16,
        cols: u16,
    ) -> Result<(), PtyError> {
        let s = self.get(id)?;
        {
            let mut viewers = s.viewers.lock().unwrap_or_else(PoisonError::into_inner);
            viewers.insert(
                viewer.to_string(),
                Viewer {
                    rows: rows.max(1),
                    cols: cols.max(1),
                    seen_ms: now_ms(),
                },
            );
        }
        Self::apply_agreed_size(&s)
    }

    /// Note that a viewer is still watching, and re-apply the agreed size if
    /// another viewer has since expired or let go.
    ///
    /// Called from the read path, which every front end drives continuously, so
    /// a viewer's lease is refreshed by the act of watching rather than by
    /// anything it has to remember to send.
    pub fn touch_viewer(&self, id: &str, viewer: &str) -> Result<(), PtyError> {
        let s = self.get(id)?;
        {
            let mut viewers = s.viewers.lock().unwrap_or_else(PoisonError::into_inner);
            // Only a viewer that has declared a geometry counts. A front end
            // that never resizes never constrains anything, which keeps an
            // older client exactly as it was.
            let Some(entry) = viewers.get_mut(viewer) else {
                return Ok(());
            };
            entry.seen_ms = now_ms();
        }
        Self::apply_agreed_size(&s)
    }

    /// A front end has stopped showing this session.
    ///
    /// The TTL would get here on its own; this is what makes the ordinary case
    /// immediate, so closing a session on the phone puts the Mac back at once
    /// instead of a quarter of a minute later.
    pub fn drop_viewer(&self, id: &str, viewer: &str) -> Result<(), PtyError> {
        // A session that is already gone has nothing to give back, and closing
        // one is exactly when this is called: the front end closes the pty and
        // then tears its own session down, in that order. Erroring there would
        // make the ordinary path report a failure that means nothing.
        let Ok(s) = self.get(id) else {
            return Ok(());
        };
        s.read_offsets
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(viewer);
        {
            let mut viewers = s.viewers.lock().unwrap_or_else(PoisonError::into_inner);
            if viewers.remove(viewer).is_none() {
                return Ok(());
            }
        }
        Self::apply_agreed_size(&s)
    }

    /// Set the session to the smallest geometry any live viewer needs.
    ///
    /// Expired viewers are pruned here rather than on a timer: every path that
    /// could change the answer already comes through this function.
    fn apply_agreed_size(s: &Arc<Session>) -> Result<(), PtyError> {
        let agreed = {
            let mut viewers = s.viewers.lock().unwrap_or_else(PoisonError::into_inner);
            let now = now_ms();
            viewers.retain(|_, v| now.saturating_sub(v.seen_ms) < VIEWER_TTL_MS);
            viewers
                .values()
                .fold(None::<(u16, u16)>, |acc, v| match acc {
                    None => Some((v.rows, v.cols)),
                    Some((r, c)) => Some((r.min(v.rows), c.min(v.cols))),
                })
        };
        let active_viewers: HashSet<String> = s
            .viewers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .keys()
            .cloned()
            .collect();
        let stream_readers = s
            .stream_readers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        s.read_offsets
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .retain(|reader, _| active_viewers.contains(reader) || stream_readers.contains(reader));
        // Nobody is watching. Leave the size alone: there is no geometry that
        // is more right than the last one, and resizing a terminal nothing is
        // showing would only make the program redraw for no reader.
        let Some((rows, cols)) = agreed else {
            return Ok(());
        };
        {
            let info = s.info.lock().unwrap_or_else(PoisonError::into_inner);
            if info.rows == rows && info.cols == cols {
                return Ok(());
            }
        }
        Self::apply_size(s, rows, cols)
    }

    fn apply_size(s: &Arc<Session>, rows: u16, cols: u16) -> Result<(), PtyError> {
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
        self.read_session(&s, offset)
    }

    /// Read for a named front end and acknowledge the bytes it has consumed.
    /// The slowest named reader keeps the shared window, so multiple viewers
    /// remain lossless while a single viewer can release memory and resume the
    /// PTY producer after backpressure.
    pub fn read_for_viewer(&self, id: &str, viewer: &str, offset: u64) -> Result<Chunk, PtyError> {
        let s = self.get(id)?;
        self.read_acknowledged(&s, viewer, offset, false)
    }

    /// Read for the daemon's persistent remote subscription. Stream readers
    /// have no geometry lease, so they are tracked separately from viewers and
    /// removed when the stream closes.
    pub fn read_for_stream(&self, id: &str, reader: &str, offset: u64) -> Result<Chunk, PtyError> {
        let s = self.get(id)?;
        self.read_acknowledged(&s, reader, offset, true)
    }

    /// Forget a stream reader so it cannot hold the shared output window.
    pub fn forget_reader(&self, id: &str, reader: &str) {
        let Ok(s) = self.get(id) else { return };
        s.stream_readers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(reader);
        s.read_offsets
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(reader);
        s.buffer_space.notify_all();
    }

    fn read_acknowledged(
        &self,
        s: &Arc<Session>,
        reader: &str,
        offset: u64,
        stream: bool,
    ) -> Result<Chunk, PtyError> {
        if stream {
            s.stream_readers
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(reader.to_string());
        }
        s.read_offsets
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(reader.to_string(), offset);
        let minimum = s
            .read_offsets
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .copied()
            .min()
            .unwrap_or(offset);
        s.buffer
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .discard_before(minimum);
        self.read_session(s, offset)
    }

    fn read_session(&self, s: &Arc<Session>, offset: u64) -> Result<Chunk, PtyError> {
        let guard = s.buffer.lock().unwrap_or_else(PoisonError::into_inner);
        let chunk = guard.read_from(offset);
        s.buffer_space.notify_all();
        Ok(chunk)
    }

    pub fn info(&self, id: &str) -> Result<SessionInfo, PtyError> {
        let s = self.get(id)?;
        Ok(self.snapshot(&s))
    }

    pub fn list(&self) -> Vec<SessionInfo> {
        // Clone the handles under the map lock, then snapshot outside it:
        // snapshot takes the per-session child/info/buffer locks, and holding
        // the map lock across all of them makes one slow session block every
        // spawn, close and list in the process.
        let sessions: Vec<Arc<Session>> = self
            .sessions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .cloned()
            .collect();
        let mut out: Vec<_> = sessions.iter().map(|s| self.snapshot(s)).collect();
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
                s.buffer_space.notify_all();
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
        info.pid = s
            .child
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .process_id();
        info.last_activity_at_ms = *s
            .last_activity
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
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
        s.buffer_space.notify_all();
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

/// Whether a request is the interactive shell profile rather than a harness.
///
/// The launcher's Shell tile asks for the user's own login shell with its
/// profile arguments. These requests are the hot path a person clicks, and the
/// one profile that genuinely does not need the cached login environment, so
/// they get the fast spawn path and the non-blocking env read.
#[cfg(unix)]
fn is_shell_profile(req: &Spawn) -> bool {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    if req.command != shell {
        return false;
    }
    // The Shell tile sends `-il` for zsh and nothing for other shells. Accept
    // the common reorderings (`-li`, split `-i -l`) so a small catalog drift
    // does not silently drop the pool path and force a cold startup.
    shell_args_are_login_interactive(&req.args)
}

#[cfg(unix)]
fn shell_args_are_login_interactive(args: &[String]) -> bool {
    if args.is_empty() {
        // Non-zsh shells (and a bare `zsh`) start with no flags. Bare zsh is
        // the slow path on some profiles; the catalog still uses it for non-
        // zsh shells, and the pool builds the same shape.
        return true;
    }
    let mut letters = String::new();
    for arg in args {
        if !arg.starts_with('-') || arg.starts_with("--") || arg == "-" {
            return false;
        }
        letters.extend(arg.chars().skip(1));
    }
    !letters.is_empty() && letters.chars().all(|c| c == 'i' || c == 'l')
}

#[cfg(not(unix))]
fn is_shell_profile(_req: &Spawn) -> bool {
    false
}

/// How many fully-started login shells to keep ready.
///
/// Two, so a second Shell click right after the first does not have to wait
/// for the pool to rebuild itself. Each is one idle process sitting at a
/// prompt until it is handed over, which is nothing on a machine that has a
/// daemon anyway.
#[cfg(unix)]
const POOL_SIZE: usize = 2;

/// How long a warm shell may take to reach a prompt before we give up on it.
///
/// A loaded interactive profile is the whole reason the pool exists; ten to
/// fifteen seconds is common on a cold machine with heavy plugins. The wait
/// runs on the warm thread, never on a click.
#[cfg(unix)]
const POOL_READY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// How long a handoff may wait for `cd` + marker from a shell that was already
/// proven ready when it entered the pool.
const HANDOFF_READY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);

/// True while the child process is still running.
fn session_is_alive(session: &Session) -> bool {
    if !session.alive.load(Ordering::SeqCst) {
        return false;
    }
    let mut child = session.child.lock().unwrap_or_else(PoisonError::into_inner);
    match child.try_wait() {
        Ok(None) => true,
        Ok(Some(_)) => {
            session.alive.store(false, Ordering::SeqCst);
            false
        }
        Err(_) => false,
    }
}

/// Wait until `needle` appears in the session buffer, or the timeout / exit.
fn wait_for_marker(session: &Session, needle: &str, timeout: std::time::Duration) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        {
            let buffer = session
                .buffer
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            if String::from_utf8_lossy(&buffer.data).contains(needle) {
                return true;
            }
        }
        if !session_is_alive(session) {
            return false;
        }
        if std::time::Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}

fn clear_session_buffer(session: &Session) {
    let mut buffer = session
        .buffer
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    buffer.data.clear();
    buffer.total = 0;
}

/// Drive a freshly forked shell until it accepts input, then clear its buffer.
///
/// The input is queued by the kernel while the profile is still running, and
/// is processed the moment the shell reaches a prompt. Seeing the marker is
/// therefore "the profile finished", which is exactly when the shell is safe
/// to park and later hand over without wiping a half-started startup.
#[cfg(unix)]
fn prove_shell_ready(session: &Session, timeout: std::time::Duration) -> bool {
    let marker = format!("__TS_POOL_READY_{}__", next_marker());
    {
        let mut writer = session
            .writer
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if writer
            .write_all(format!("echo {marker}\r").as_bytes())
            .is_err()
        {
            return false;
        }
        if writer.flush().is_err() {
            return false;
        }
    }
    if !wait_for_marker(session, &marker, timeout) {
        return false;
    }
    clear_session_buffer(session);
    true
}

/// Start the process-wide shell pool ahead of the first Shell click.
///
/// A login-shell startup is the slowest thing a terminal open can pay, and it
/// is the same startup for every Shell tile, so it is paid once at daemon
/// start on a thread nobody is waiting on and the first real request takes a
/// shell straight out of the pool. Called beside [`warm_login_env`], and
/// equally cheap and correct to call more than once: the pool caps itself.
pub fn warm_shell_pool() {
    #[cfg(unix)]
    {
        // Called from both the daemon's entry point and its serve loop; the
        // second call must not start a second set of profile startups.
        static WARMED: AtomicBool = AtomicBool::new(false);
        if WARMED.swap(true, Ordering::Relaxed) {
            return;
        }
        std::thread::spawn(|| {
            let m = manager();
            // Start the shells in parallel: on a loaded machine each is a full
            // profile startup, and doing them serially doubles the warm time.
            let handles: Vec<_> = (0..POOL_SIZE)
                .map(|_| std::thread::spawn(move || m.build_pool_shell()))
                .collect();
            for handle in handles {
                if let Some(shell) = handle.join().ok().flatten() {
                    park_pool_shell(m, shell);
                }
            }
        });
    }
}

/// Put a built shell into the pool, or kill it when the pool is already full.
///
/// The full case is rare (a replenish finishing while another replenish or the
/// warm already refilled), but a shell left running with nobody to hand it to
/// is a process the user did not ask for, so it is stopped rather than leaked.
#[cfg(unix)]
fn park_pool_shell(m: &'static Manager, shell: Arc<Session>) {
    let mut pool = m.pool.lock().unwrap_or_else(PoisonError::into_inner);
    if pool.len() < POOL_SIZE {
        pool.push(shell);
    } else {
        drop(pool);
        let _ = shell
            .child
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .kill();
    }
}

/// Monotonic suffix for handoff markers, so two handoffs in one process can
/// never confuse their markers.
fn next_marker() -> u64 {
    static MARKER: AtomicU64 = AtomicU64::new(0);
    MARKER.fetch_add(1, Ordering::Relaxed)
}

/// Single-quote a string for the shell, escaping an embedded quote so a path
/// like `O'Brien/` cannot break out of the quoting.
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// The user's interactive login environment, captured once per process.
#[derive(Debug, Clone)]
pub struct LoginEnv {
    pub path: String,
    pub vars: HashMap<String, String>,
}

/// PATH for a harness spawn when the login resolve has not finished yet.
///
/// launchd's PATH is too small to find Homebrew or `~/.local/bin`. This is
/// the same conventional list the launcher catalog uses, not a guess at the
/// user's full profile.
#[cfg(unix)]
fn fallback_path() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let mut parts: Vec<String> = std::env::var("PATH")
        .unwrap_or_default()
        .split(':')
        .filter(|p| !p.is_empty())
        .map(str::to_string)
        .collect();
    parts.extend([
        format!("{home}/.local/bin"),
        format!("{home}/.npm-global/bin"),
        format!("{home}/.volta/bin"),
        format!("{home}/.cargo/bin"),
        "/opt/homebrew/bin".into(),
        "/usr/local/bin".into(),
        "/usr/bin".into(),
        "/bin".into(),
    ]);
    let mut seen = std::collections::HashSet::new();
    parts.retain(|p| !p.is_empty() && seen.insert(p.clone()));
    parts.join(":")
}

/// How long a harness spawn may wait for the login-env warm thread.
///
/// Shells source their own profile and must not pay this. Harnesses do not,
/// and a cold spawn under launchd without the full env was measured at several
/// seconds of plugin work that a Terminal session skipped. The warm thread is
/// started at daemon boot; this is only a bridge across the first click.
#[cfg(unix)]
const LOGIN_ENV_BRIEF_WAIT: std::time::Duration = std::time::Duration::from_millis(400);

/// Keys that must not ride from a launchd / sandbox parent into a session when
/// the login resolve has not replaced the whole environment yet.
#[cfg(unix)]
const HOSTILE_INHERITED_KEYS: &[&str] = &[
    "CI",
    "CONTINUOUS_INTEGRATION",
    "GITHUB_ACTIONS",
    "GITLAB_CI",
    "BUILD_ID",
    "BUILD_NUMBER",
    "JENKINS_URL",
    "TEAMCITY_VERSION",
    "TF_BUILD",
    "NO_COLOR",
];

/// Apply the login-shell environment, or a usable fallback, before terminal
/// overrides. See the call site for why the order and the clear matter.
#[cfg(unix)]
fn apply_login_environment(cmd: &mut CommandBuilder, req: &Spawn) {
    // Shells are `$SHELL -il` (or bare interactive): they source the profile
    // themselves. Waiting here would double a cold startup.
    let env = if is_shell_profile(req) {
        login_env()
    } else {
        login_env().or_else(|| brief_login_env(LOGIN_ENV_BRIEF_WAIT))
    };

    if let Some(env) = env {
        // Pure interactive baseline: drop launchd-only keys that are not in
        // the user's shell, then write every login variable.
        cmd.env_clear();
        for (key, value) in &env.vars {
            cmd.env(key, value);
        }
        return;
    }

    if !is_shell_profile(req) {
        cmd.env("PATH", fallback_path());
    }
    for key in HOSTILE_INHERITED_KEYS {
        cmd.env_remove(*key);
    }
}

/// TERM and colour claims the emulator makes, always last so a profile cannot
/// undo them.
fn apply_terminal_environment(cmd: &mut CommandBuilder, req: &Spawn) {
    // Agent CLIs draw boxes and colour. Without this they fall back to
    // something far uglier, and some refuse interactive mode entirely.
    cmd.env("TERM", "xterm-256color");
    if req.no_color {
        // The user opted out of colour in settings. Honour it exactly:
        // NO_COLOR=1 and nothing that overrides it.
        cmd.env("NO_COLOR", "1");
        cmd.env_remove("COLORTERM");
        cmd.env_remove("FORCE_COLOR");
    } else {
        // macOS Terminal also advertises truecolor; TUIs like Claude Code
        // and the Antigravity CLI consult COLORTERM and switch to a
        // monochrome fallback when it is absent, even though the emulator
        // handles 24-bit sequences. Say what the terminal can do.
        cmd.env("COLORTERM", "truecolor");
        // The app's own launch environment can carry NO_COLOR (a sandbox
        // or CI shell sets it), and every session would inherit it:
        // Claude Code and Antigravity quietly render monochrome when
        // NO_COLOR is present. This terminal supports colour, so the
        // launcher's claim is dropped here. FORCE_COLOR is the Node-TUI
        // sledgehammer that wins even against a leftover NO_COLOR some
        // future launcher might smuggle in.
        cmd.env_remove("NO_COLOR");
        cmd.env("FORCE_COLOR", "3");
    }
    // Which way round the background is.
    //
    // A TUI has two ways to find out: query the emulator with OSC 11 and wait
    // for a reply, or read COLORFGBG. With neither answered, every one of them
    // assumes a dark terminal, which is why a light-themed window still opened
    // agents drawn for a black background: nothing had ever told them
    // otherwise. The value is the xterm convention, foreground;background as
    // ANSI colour indices.
    if let Some(dark) = req.dark {
        cmd.env("COLORFGBG", if dark { "15;0" } else { "0;15" });
    }
}

/// [`login_env`], waiting up to `timeout` if the warm resolve is still running.
///
/// Returns `None` when the wait expires still pending, or when the resolve
/// finished with a failed shell. Starts the warm work if nothing has yet.
#[cfg(unix)]
fn brief_login_env(timeout: std::time::Duration) -> Option<Arc<LoginEnv>> {
    warm_login_env();
    env_cache().wait_ready_timeout(timeout)
}

/// Ask the user's login shell for its whole environment, once per process.
///
/// A GUI app or launch agent does not inherit the interactive shell's
/// environment: the launchd daemon starts with `/usr/bin:/bin:/usr/sbin:/sbin`
/// plus HOME, and a harness that needs nvm, pyenv, an auth agent or any other
/// profile export would fail or require setup on every new session. Terminal.app
/// sessions look seamless because they *are* the login shell; these sessions
/// are not, so the shell is asked once and the answer is reused.
///
/// The cost is a full `$SHELL -ilc` run, which is why it is warmed ahead of
/// the first spawn (see [`warm_login_env`]) rather than paid there. The answer
/// is cached for the process's life, so a loaded shell costs seconds once and
/// nothing ever again. A shell that fails to answer keeps the inherited
/// environment as the fallback, exactly as before.
///
/// Two reads, deliberately different:
///
/// - [`login_env`] returns whatever the cache holds **right now**, without
///   waiting. An interactive shell profile is itself `$SHELL -il`, so it
///   sources its own environment and does not need this answer; making its
///   first spawn wait for a separate full shell startup on top of its own is
///   how a fresh daemon paid two loaded-profile startups for one terminal.
/// - [`login_env_ready`] blocks until the resolve has finished. The launcher
///   catalog and one-shot harness launches need the real PATH before they can
///   say what exists or find the command, so they keep paying the wait.
#[cfg(unix)]
pub fn login_env() -> Option<Arc<LoginEnv>> {
    env_cache().snapshot()
}

/// [`login_env`], waiting out a resolve that is still in flight.
///
/// Starts the resolve if nothing is working on it yet, so a caller can rely on
/// the answer being final when this returns. See [`login_env`] for which call
/// sites want which read.
#[cfg(unix)]
pub fn login_env_ready() -> Option<Arc<LoginEnv>> {
    // A caller may arrive before any warm call did. Start the resolver; the
    // once inside it guarantees a single `$SHELL -ilc` run process-wide.
    warm_login_env();
    env_cache().wait_ready()
}

/// No login shell on Windows: sessions inherit the process environment, which
/// is the closest equivalent to the user's interactive environment.
#[cfg(not(unix))]
pub fn login_env() -> Option<Arc<LoginEnv>> {
    None
}

/// No login shell on Windows; the blocking read is the same nothing.
#[cfg(not(unix))]
pub fn login_env_ready() -> Option<Arc<LoginEnv>> {
    None
}

/// What the cache holds while nobody has asked the login shell yet.
#[cfg(unix)]
enum EnvState {
    /// The resolve is still running, or has not started.
    Pending,
    /// The resolve finished. `None` means the shell failed to answer and the
    /// inherited environment stays in use.
    Done(Option<Arc<LoginEnv>>),
}

/// The one cache, shared by the blocking and non-blocking reads and the warm
/// thread. `Pending` while the resolve runs, so a spawn that does not want to
/// wait can see "not ready" instead of blocking on a mutex the resolve holds.
///
/// A plain struct rather than inline statics so the non-blocking contract is
/// testable without touching process-wide state.
#[cfg(unix)]
struct EnvCache {
    state: Mutex<EnvState>,
    condvar: std::sync::Condvar,
}

#[cfg(unix)]
impl EnvCache {
    fn new() -> EnvCache {
        EnvCache {
            state: Mutex::new(EnvState::Pending),
            condvar: std::sync::Condvar::new(),
        }
    }

    /// What is known right now. `None` while the resolve is still running:
    /// returning it is an answer, not a promise that no resolve is happening.
    fn snapshot(&self) -> Option<Arc<LoginEnv>> {
        match &*self.state.lock().unwrap_or_else(PoisonError::into_inner) {
            EnvState::Done(env) => env.clone(),
            EnvState::Pending => None,
        }
    }

    /// Wait for the resolve to finish and return its final answer.
    fn wait_ready(&self) -> Option<Arc<LoginEnv>> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            match &*state {
                EnvState::Done(env) => return env.clone(),
                EnvState::Pending => {
                    state = self
                        .condvar
                        .wait(state)
                        .unwrap_or_else(PoisonError::into_inner);
                }
            }
        }
    }

    /// Like [`Self::wait_ready`], but give up after `timeout` still pending.
    ///
    /// A timed-out wait returns `None` without marking the resolve failed: the
    /// warm thread may still finish and later callers can read the answer.
    fn wait_ready_timeout(&self, timeout: std::time::Duration) -> Option<Arc<LoginEnv>> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let deadline = std::time::Instant::now() + timeout;
        loop {
            match &*state {
                EnvState::Done(env) => return env.clone(),
                EnvState::Pending => {
                    let now = std::time::Instant::now();
                    if now >= deadline {
                        return None;
                    }
                    let (next, result) = self
                        .condvar
                        .wait_timeout(state, deadline - now)
                        .unwrap_or_else(PoisonError::into_inner);
                    state = next;
                    if result.timed_out() {
                        // Re-check: a notify and a timeout can race, and the
                        // answer may have landed in the same moment.
                        if let EnvState::Done(env) = &*state {
                            return env.clone();
                        }
                        return None;
                    }
                }
            }
        }
    }

    /// Store the resolve's answer and wake everyone waiting for it.
    fn store(&self, env: Option<Arc<LoginEnv>>) {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        *state = EnvState::Done(env);
        self.condvar.notify_all();
    }
}

#[cfg(unix)]
fn env_cache() -> &'static EnvCache {
    static CACHE: std::sync::OnceLock<EnvCache> = std::sync::OnceLock::new();
    CACHE.get_or_init(EnvCache::new)
}

/// Run `$SHELL -ilc env` and cache the answer. Called at most once per
/// process, from the warm thread.
#[cfg(unix)]
fn resolve_and_store() {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
    // `env` between two markers, rather than the whole stdout: profiles
    // print banners and prompts, and treating that noise as environment
    // corrupts every variable (the previous PATH-only version did exactly
    // that with a profile that printed anything).
    let output = Command::new(shell)
        .args([
            "-ilc",
            "printf '\\n__TOKENSTAT_ENV_START__\\n'; env; printf '__TOKENSTAT_ENV_END__\\n'",
        ])
        .output()
        .ok();
    let resolved = output.and_then(|output| {
        if !output.status.success() {
            return None;
        }
        let stdout = String::from_utf8(output.stdout).ok()?;
        let vars = parse_env(&stdout)?;
        let path = vars.get("PATH")?.trim().to_string();
        (!path.is_empty()).then(|| Arc::new(LoginEnv { path, vars }))
    });
    env_cache().store(resolved);
}

/// Resolve the login environment ahead of the first spawn.
///
/// Without this the cost lands inside the first `pty.spawn` of the process's
/// life, where a person is sitting waiting for a terminal to open, and it is
/// the largest single part of that wait. Called at daemon start, on a thread
/// nobody is waiting on. Cheap and correct to call more than once: the work
/// happens once and every later caller reads the answer.
pub fn warm_login_env() {
    #[cfg(unix)]
    {
        static WARMED: AtomicBool = AtomicBool::new(false);
        if WARMED.swap(true, Ordering::Relaxed) {
            return;
        }
        std::thread::spawn(|| {
            static ONCE: std::sync::Once = std::sync::Once::new();
            ONCE.call_once(resolve_and_store);
        });
    }
}

/// Parse `KEY=VALUE` lines between the sentinel markers, ignoring anything a
/// startup file printed before or after the real environment.
///
/// A variable whose value contains a newline (pathological, but legal in POSIX)
/// loses the continuation lines: the first line still parses and the rest are
/// skipped as non-`KEY=VALUE` noise. Better one truncated value than a corrupt
/// parse of everything after it.
#[cfg(unix)]
fn parse_env(stdout: &str) -> Option<HashMap<String, String>> {
    const START: &str = "__TOKENSTAT_ENV_START__";
    const END: &str = "__TOKENSTAT_ENV_END__";
    let body = stdout.split_once(START)?.1.split_once(END)?.0;
    let mut vars = HashMap::new();
    for line in body.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if key.is_empty() || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
            continue;
        }
        // The pty owns the working directory: the child chdirs to the
        // workspace, and a stale PWD from wherever the daemon was started
        // would make tools that trust $PWD over getcwd report the wrong
        // folder.
        if key == "PWD" {
            continue;
        }
        vars.insert(key.to_string(), value.to_string());
    }
    (!vars.is_empty()).then_some(vars)
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

    #[cfg(unix)]
    #[test]
    fn shell_login_flags_are_recognised() {
        assert!(shell_args_are_login_interactive(&[]));
        assert!(shell_args_are_login_interactive(&["-il".to_string()]));
        assert!(shell_args_are_login_interactive(&["-li".to_string()]));
        assert!(shell_args_are_login_interactive(&[
            "-i".to_string(),
            "-l".to_string()
        ]));
        assert!(!shell_args_are_login_interactive(&[
            "-c".to_string(),
            "true".to_string()
        ]));
        assert!(!shell_args_are_login_interactive(&["--login".to_string()]));
    }

    #[cfg(unix)]
    #[test]
    fn the_login_env_parse_ignores_profile_noise() {
        // A profile that prints a banner must not corrupt the environment: the
        // previous PATH-only version took the whole stdout, so one `echo` made
        // every spawn start with a garbage PATH.
        let out = concat!(
            "Last login: Tue Aug  1 12:00:00 on ttys000\n",
            "Welcome to your machine!\n",
            "__TOKENSTAT_ENV_START__\n",
            "PATH=/opt/homebrew/bin:/usr/bin:/bin\n",
            "NVM_DIR=/Users/x/.nvm\n",
            "AUTH_TOKEN=abc=def\n",
            "PWD=/somewhere/else\n",
            "not a variable line\n",
            "__TOKENSTAT_ENV_END__\n",
            "more banner text\n",
        );
        let vars = parse_env(out).expect("markers present");
        assert_eq!(
            vars.get("PATH").map(String::as_str),
            Some("/opt/homebrew/bin:/usr/bin:/bin")
        );
        assert_eq!(
            vars.get("NVM_DIR").map(String::as_str),
            Some("/Users/x/.nvm")
        );
        // split on the first `=`, so an `=` inside a value survives.
        assert_eq!(vars.get("AUTH_TOKEN").map(String::as_str), Some("abc=def"));
        // PWD is the pty's business, not the login shell's: the child chdirs
        // to the workspace, and a stale value would lie to tools that read it.
        assert!(!vars.contains_key("PWD"));
        assert!(!vars.contains_key("not a variable line"));
        assert_eq!(vars.len(), 3);
    }

    #[cfg(unix)]
    #[test]
    fn a_missing_marker_is_not_an_environment() {
        assert_eq!(parse_env("no markers here"), None);
        assert_eq!(
            parse_env("__TOKENSTAT_ENV_START__\n\n__TOKENSTAT_ENV_END__"),
            None
        );
    }

    #[cfg(unix)]
    #[test]
    fn the_env_snapshot_does_not_wait_for_a_pending_resolve() {
        // A shell profile sources its own environment, so its first spawn must
        // never block on the process-wide login resolve. The snapshot read is
        // the contract that makes that true: Pending answers None immediately.
        let cache = EnvCache::new();
        assert!(
            cache.snapshot().is_none(),
            "pending resolve answers nothing"
        );

        let env = Arc::new(LoginEnv {
            path: "/opt/homebrew/bin:/usr/bin:/bin".into(),
            vars: HashMap::from([("PATH".into(), "/opt/homebrew/bin:/usr/bin:/bin".into())]),
        });
        cache.store(Some(Arc::clone(&env)));
        let read = cache.snapshot().expect("done resolve answers a value");
        assert_eq!(read.path, env.path);
        assert_eq!(read.vars, env.vars);
    }

    #[cfg(unix)]
    #[test]
    fn the_env_brief_wait_times_out_while_pending() {
        // Harness spawns may wait briefly for the warm thread, but must not
        // hang when the resolve never finishes (tests, broken shell).
        let cache = EnvCache::new();
        let started = std::time::Instant::now();
        assert!(
            cache
                .wait_ready_timeout(std::time::Duration::from_millis(50))
                .is_none(),
            "pending resolve must time out"
        );
        assert!(
            started.elapsed() < std::time::Duration::from_millis(500),
            "timeout must not block for seconds"
        );
    }

    #[cfg(unix)]
    #[test]
    fn the_env_brief_wait_returns_when_ready() {
        let cache = Arc::new(EnvCache::new());
        let env = Arc::new(LoginEnv {
            path: "/bin".into(),
            vars: HashMap::from([("PATH".into(), "/bin".into())]),
        });
        {
            let cache = Arc::clone(&cache);
            let env = Arc::clone(&env);
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(30));
                cache.store(Some(env));
            });
        }
        let read = cache
            .wait_ready_timeout(std::time::Duration::from_secs(2))
            .expect("resolve should land inside the wait");
        assert_eq!(read.path, "/bin");
    }

    #[cfg(unix)]
    #[test]
    fn the_env_ready_read_wakes_when_the_resolve_finishes() {
        // The blocking read exists for callers that genuinely need the login
        // PATH (the launcher catalog, one-shot harness launches). It must wait
        // out a resolve that is still running and return the final answer.
        let cache = Arc::new(EnvCache::new());
        let waiting = {
            let cache = Arc::clone(&cache);
            std::thread::spawn(move || cache.wait_ready())
        };
        // Give the waiter time to park, then finish the resolve on this thread.
        std::thread::sleep(std::time::Duration::from_millis(100));
        let env = Arc::new(LoginEnv {
            path: "/usr/bin:/bin".into(),
            vars: HashMap::from([("PATH".into(), "/usr/bin:/bin".into())]),
        });
        cache.store(Some(Arc::clone(&env)));
        let read = waiting.join().expect("waiter").expect("a resolved value");
        assert_eq!(read.path, env.path);
        assert_eq!(read.vars, env.vars);
    }

    #[cfg(unix)]
    #[test]
    fn shell_quoting_survives_an_apostrophe() {
        // A path like O'Brien/ must stay inside the quotes, or the handoff cd
        // would split into two commands and the shell would run the tail.
        assert_eq!(shell_quote("plain"), "'plain'");
        assert_eq!(shell_quote("O'Brien"), "'O'\\''Brien'");
        assert_eq!(shell_quote("a b"), "'a b'");
    }

    /// The shell profile request a Shell tile produces.
    #[cfg(unix)]
    fn shell_req(cwd: std::path::PathBuf) -> Spawn {
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
        let args: Vec<String> = if shell.ends_with("zsh") {
            vec!["-il".to_string()]
        } else {
            Vec::new()
        };
        Spawn {
            command: shell,
            args,
            cwd,
            workspace_id: Some("ws-1".into()),
            rows: 30,
            cols: 100,
            no_color: false,
            dark: None,
        }
    }

    /// Wait until a pooled shell is sitting at a prompt, so a handoff test is
    /// testing the ready case and not the mid-startup fallback.
    ///
    /// Readiness is proved by echoing a marker and waiting for it, the same
    /// probe `prove_shell_ready` uses, rather than by waiting for "any new
    /// bytes". The bytes after a profile are racy: `prove_shell_ready` clears
    /// the buffer the moment its marker arrives, and the shell's following
    /// prompt is sometimes already inside that cleared chunk — on a loaded
    /// CI runner the buffer could then stay empty for the whole wait even
    /// though the shell is fine. A marker command always produces output if
    /// the shell is alive, so the probe cannot starve.
    #[cfg(unix)]
    fn wait_until_prompt(shell: &Arc<Session>) {
        let marker = format!("__TS_PROMPT_{}__", next_marker());
        {
            let mut writer = shell.writer.lock().unwrap_or_else(PoisonError::into_inner);
            writer
                .write_all(format!("echo {marker}\r").as_bytes())
                .expect("write prompt probe");
            writer.flush().expect("flush prompt probe");
        }
        assert!(
            wait_for_marker(shell, &marker, POOL_READY_TIMEOUT),
            "the pooled shell answered the prompt probe"
        );
        // Leave the handoff a clean transcript, like `prove_shell_ready` does.
        clear_session_buffer(shell);
    }

    #[cfg(unix)]
    fn close_pool(m: &Manager) {
        if let Some(shell) = m.pool.lock().unwrap_or_else(PoisonError::into_inner).pop() {
            let _ = shell
                .child
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .kill();
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_pooled_shell_handoff_lands_in_the_workspace() {
        let m = Manager::new();
        let ws = std::env::temp_dir().join(format!("ts-pool-ws-{}", std::process::id()));
        std::fs::create_dir_all(&ws).unwrap();

        let shell = m.build_pool_shell().expect("pool shell");
        wait_until_prompt(&shell);
        m.pool
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(shell);

        let info = m
            .spawn(&shell_req(ws.clone()))
            .expect("a pooled shell hands over");
        assert_eq!(info.cwd, ws.display().to_string());
        assert_eq!(info.workspace_id.as_deref(), Some("ws-1"));
        assert_eq!((info.rows, info.cols), (30, 100));

        // The handoff transcript starts clean: no cd line, no marker.
        let text = String::from_utf8_lossy(&m.read(&info.id, 0).unwrap().bytes).to_string();
        assert!(
            !text.contains("cd "),
            "handoff must not show the cd: {text:?}"
        );
        assert!(
            !text.contains("__TS_READY_"),
            "handoff must not show the marker: {text:?}"
        );

        // The shell really is in the workspace, not just labelled so.
        m.write(&info.id, b"pwd\r").unwrap();
        assert!(
            wait_for(|| m
                .read(&info.id, 0)
                .map(|c| String::from_utf8_lossy(&c.bytes).contains(&ws.display().to_string()))
                .unwrap_or(false)),
            "the pooled shell changed into the workspace"
        );

        m.close(&info.id).unwrap();
        // The pool gave its only shell away, so nothing is left behind.
        assert!(
            m.pool
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .is_empty()
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_harness_spawn_bypasses_the_pool() {
        let m = Manager::new();
        let shell = m.build_pool_shell().expect("pool shell");
        wait_until_prompt(&shell);
        m.pool
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(shell);

        // /bin/sh is not the user's login shell, so this is a harness-style
        // request and must spawn fresh even though a shell is waiting.
        let s = spawn(&m, "echo hello-from-fresh", "echo hello-from-fresh");
        assert!(wait_for(|| m
            .read(&s.id, 0)
            .map(|c| String::from_utf8_lossy(&c.bytes).contains("hello-from-fresh"))
            .unwrap_or(false)));
        assert_eq!(
            m.pool.lock().unwrap_or_else(PoisonError::into_inner).len(),
            1,
            "a harness spawn must not consume the pooled shell"
        );
        m.close(&s.id).unwrap();
        close_pool(&m);
    }

    #[cfg(unix)]
    #[test]
    fn a_no_colour_shell_spawn_bypasses_the_pool() {
        let m = Manager::new();
        let shell = m.build_pool_shell().expect("pool shell");
        wait_until_prompt(&shell);
        m.pool
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(shell);

        let mut req = shell_req(std::env::temp_dir());
        req.no_color = true;
        let info = m.spawn(&req).expect("fresh spawn honours no colour");
        assert_eq!(
            m.pool.lock().unwrap_or_else(PoisonError::into_inner).len(),
            1,
            "a no-colour request must not inherit a colour-enabled shell"
        );
        m.close(&info.id).unwrap();
        close_pool(&m);
    }

    #[cfg(unix)]
    #[test]
    fn a_light_mode_shell_spawn_bypasses_the_pool() {
        let m = Manager::new();
        let shell = m.build_pool_shell().expect("pool shell");
        wait_until_prompt(&shell);
        m.pool
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(shell);

        let mut req = shell_req(std::env::temp_dir());
        // Pooled shells are built without COLORFGBG. A light window needs
        // COLORFGBG=0;15, so it must not take a pre-started dark-default shell.
        req.dark = Some(false);
        let info = m.spawn(&req).expect("fresh spawn honours light mode");
        assert_eq!(
            m.pool.lock().unwrap_or_else(PoisonError::into_inner).len(),
            1,
            "a light-mode request must not inherit a pooled shell without COLORFGBG"
        );
        m.close(&info.id).unwrap();
        close_pool(&m);
    }

    #[cfg(unix)]
    #[test]
    fn a_dead_pooled_shell_falls_back_to_a_fresh_spawn() {
        let m = Manager::new();
        let shell = m.build_pool_shell().expect("pool shell");
        let _ = shell
            .child
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .kill();
        assert!(wait_for(|| shell
            .child
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .try_wait()
            .ok()
            .flatten()
            .is_some()));
        m.pool
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(shell);

        // The dead shell must not be handed over as a corpse; the click gets
        // a real spawn and still works.
        let info = m
            .spawn(&shell_req(std::env::temp_dir()))
            .expect("fresh spawn");
        m.write(&info.id, b"echo alive\r").unwrap();
        assert!(wait_for(|| m
            .read(&info.id, 0)
            .map(|c| String::from_utf8_lossy(&c.bytes).contains("alive"))
            .unwrap_or(false)));
        assert!(
            m.pool
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .is_empty(),
            "the dead shell was consumed and replaced by the fresh spawn"
        );
        m.close(&info.id).unwrap();
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
            no_color: false,
            dark: None,
        })
        .expect("spawn")
    }

    /// A script that stays busy for roughly a minute without needing input.
    fn stay_busy(m: &Manager) -> SessionInfo {
        spawn(m, "sleep 60", "ping -n 61 127.0.0.1 > nul")
    }

    // --- viewer-scoped sizing -----------------------------------------------
    //
    // A pty has one size and can have two front ends. These pin the rule that
    // makes a phone and a Mac watching the same session both correct: the
    // session is the smallest geometry any live viewer can show, and a viewer
    // that leaves takes its constraint with it.

    #[test]
    fn one_viewer_gets_exactly_what_it_asked_for() {
        let m = Manager::new();
        let s = stay_busy(&m);
        m.resize_viewer(&s.id, "mac", 50, 200).expect("resize");
        let info = m.info(&s.id).expect("info");
        assert_eq!((info.rows, info.cols), (50, 200));
        let _ = m.kill(&s.id);
    }

    #[test]
    fn two_viewers_agree_on_the_smaller_of_each_axis() {
        let m = Manager::new();
        let s = stay_busy(&m);
        m.resize_viewer(&s.id, "mac", 50, 200).expect("mac");
        m.resize_viewer(&s.id, "phone", 40, 60).expect("phone");
        let info = m.info(&s.id).expect("info");
        // Not the phone's rows and not the Mac's cols: each axis is decided on
        // its own, so nothing a program prints can run off either screen.
        assert_eq!((info.rows, info.cols), (40, 60));
        let _ = m.kill(&s.id);
    }

    #[test]
    fn the_agreement_holds_whichever_order_they_arrive_in() {
        let m = Manager::new();
        let s = stay_busy(&m);
        m.resize_viewer(&s.id, "phone", 40, 60).expect("phone");
        m.resize_viewer(&s.id, "mac", 50, 200).expect("mac");
        let info = m.info(&s.id).expect("info");
        assert_eq!((info.rows, info.cols), (40, 60));
        let _ = m.kill(&s.id);
    }

    #[test]
    fn a_viewer_that_detaches_takes_its_constraint_with_it() {
        // The reported bug: the phone shrank the Mac's terminal and closing it
        // left the Mac small.
        let m = Manager::new();
        let s = stay_busy(&m);
        m.resize_viewer(&s.id, "mac", 50, 200).expect("mac");
        m.resize_viewer(&s.id, "phone", 40, 60).expect("phone");
        m.drop_viewer(&s.id, "phone").expect("detach");
        let info = m.info(&s.id).expect("info");
        assert_eq!((info.rows, info.cols), (50, 200));
        let _ = m.kill(&s.id);
    }

    #[test]
    fn the_last_viewer_leaving_keeps_the_size_it_left_behind() {
        // Nothing is showing the session, so no geometry is more right than
        // another and resizing would make the program redraw for no reader.
        let m = Manager::new();
        let s = stay_busy(&m);
        m.resize_viewer(&s.id, "phone", 40, 60).expect("phone");
        m.drop_viewer(&s.id, "phone").expect("detach");
        let info = m.info(&s.id).expect("info");
        assert_eq!((info.rows, info.cols), (40, 60));
        let _ = m.kill(&s.id);
    }

    #[test]
    fn a_silent_viewer_expires_and_stops_constraining() {
        let m = Manager::new();
        let s = stay_busy(&m);
        let session = m.get(&s.id).expect("session");
        m.resize_viewer(&s.id, "mac", 50, 200).expect("mac");
        m.resize_viewer(&s.id, "phone", 40, 60).expect("phone");
        // A front end that was killed or lost its network never detaches.
        {
            let session = m.get(&s.id).expect("session");
            let mut viewers = session
                .viewers
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let phone = viewers.get_mut("phone").expect("phone viewer");
            phone.seen_ms = now_ms().saturating_sub(VIEWER_TTL_MS + 1);
        }
        session
            .read_offsets
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert("phone".into(), 12);
        // Any call that could change the answer prunes; the Mac's own poll is
        // what gets there first in practice.
        m.touch_viewer(&s.id, "mac").expect("touch");
        assert!(
            !session
                .read_offsets
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .contains_key("phone")
        );
        let info = m.info(&s.id).expect("info");
        assert_eq!((info.rows, info.cols), (50, 200));
        let _ = m.kill(&s.id);
    }

    #[test]
    fn touching_an_unknown_viewer_changes_nothing() {
        // An older front end never sends a viewer id, so it must not be able to
        // register itself with no geometry and pin the session to nothing.
        let m = Manager::new();
        let s = stay_busy(&m);
        m.resize_viewer(&s.id, "phone", 40, 60).expect("phone");
        m.touch_viewer(&s.id, "stranger").expect("touch");
        let info = m.info(&s.id).expect("info");
        assert_eq!((info.rows, info.cols), (40, 60));
        let _ = m.kill(&s.id);
    }

    #[test]
    fn a_viewerless_resize_still_sets_the_size_outright() {
        // The old client path, kept working on purpose.
        let m = Manager::new();
        let s = stay_busy(&m);
        m.resize(&s.id, 30, 100).expect("resize");
        let info = m.info(&s.id).expect("info");
        assert_eq!((info.rows, info.cols), (30, 100));
        let _ = m.kill(&s.id);
    }

    #[test]
    fn a_viewer_that_grows_releases_the_session_again() {
        // Rotating the phone to landscape, or the Mac window widening.
        let m = Manager::new();
        let s = stay_busy(&m);
        m.resize_viewer(&s.id, "mac", 50, 200).expect("mac");
        m.resize_viewer(&s.id, "phone", 40, 60).expect("phone");
        m.resize_viewer(&s.id, "phone", 45, 120).expect("rotate");
        let info = m.info(&s.id).expect("info");
        assert_eq!((info.rows, info.cols), (45, 120));
        let _ = m.kill(&s.id);
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
    fn a_stream_reader_can_acknowledge_and_release_its_offset() {
        let m = Manager::new();
        let s = stay_busy(&m);
        let session = m.get(&s.id).expect("session");
        m.read_for_stream(&s.id, "remote", 0).expect("stream read");
        assert!(
            session
                .stream_readers
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .contains("remote")
        );
        m.forget_reader(&s.id, "remote");
        assert!(
            !session
                .stream_readers
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .contains("remote")
        );
        m.close(&s.id).unwrap();
    }

    #[test]
    fn activity_time_is_reported_once_output_arrives() {
        let m = Manager::new();
        let s = spawn(&m, "echo activity", "echo activity");
        assert!(
            wait_for(|| {
                m.info(&s.id)
                    .map(|i| i.last_activity_at_ms.is_some())
                    .unwrap_or(false)
            }),
            "a process that printed is not reported as recently active"
        );
        m.close(&s.id).unwrap();
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
    fn a_full_buffer_is_reported_as_paused_without_loss() {
        let mut b = Buffer::new();
        let written = BUFFER_BYTES;
        b.push(&vec![b'a'; written]);
        let chunk = b.read_from(0);
        assert_eq!(chunk.dropped, 0);
        assert_eq!(chunk.bytes.len(), BUFFER_BYTES);
        assert_eq!(chunk.next_offset, written as u64);
        assert!(chunk.paused);
    }

    #[test]
    fn the_buffer_can_hold_exactly_the_reader_window() {
        let mut b = Buffer::new();
        b.push(&[b'x'; BUFFER_BYTES]);
        assert_eq!(b.data.len(), BUFFER_BYTES);
        assert_eq!(b.total, BUFFER_BYTES as u64);
    }

    #[test]
    fn acknowledging_a_reader_releases_prefix_without_changing_offsets() {
        let mut b = Buffer::new();
        b.push(b"0123456789");
        b.discard_before(4);
        let chunk = b.read_from(4);
        assert_eq!(chunk.bytes, b"456789");
        assert_eq!(chunk.next_offset, 10);
        assert_eq!(chunk.dropped, 0);
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
