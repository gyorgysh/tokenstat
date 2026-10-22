// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! OS-owned process lifetime for Team guardians. The trusted anchor waits for
//! private pipe admission before backend birth. No peer RPC accepts Program.
//! A process group/Job is not confinement against arbitrary OS-account code.

#[cfg(unix)]
#[path = "team_process/unix.rs"]
mod os;
#[cfg(windows)]
#[path = "team_process/windows.rs"]
mod os;

use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    io::{self, BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver},
    time::{Duration, Instant},
};

const FRAME: usize = 64 * 1024;
const STOP: Duration = Duration::from_secs(5);
pub(crate) const BIRTH: Duration = Duration::from_secs(2);

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BirthWindow {
    boot_start: u64,
    boot_end: u64,
    wall_end: u64,
}
impl BirthWindow {
    fn new() -> io::Result<Self> {
        let stamp = crate::lease_clock::Stamp::now().ok_or_else(invalid)?;
        let boot_start = u64::try_from(stamp.boot.as_nanos()).map_err(|_| invalid())?;
        let boot_end = boot_start
            .checked_add(BIRTH.as_nanos() as u64)
            .ok_or_else(invalid)?;
        let wall_end = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| invalid())?
            .as_millis()
            .checked_add(BIRTH.as_millis())
            .and_then(|n| u64::try_from(n).ok())
            .ok_or_else(invalid)?;
        Ok(Self {
            boot_start,
            boot_end,
            wall_end,
        })
    }
    fn ensure_live(&self) -> io::Result<()> {
        let stamp = crate::lease_clock::Stamp::now().ok_or_else(invalid)?;
        let boot = u64::try_from(stamp.boot.as_nanos()).map_err(|_| invalid())?;
        let wall = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| invalid())?
            .as_millis();
        if boot < self.boot_start
            || boot >= self.boot_end
            || wall >= u128::from(self.wall_end)
            || self.boot_end.checked_sub(self.boot_start) != Some(BIRTH.as_nanos() as u64)
        {
            return Err(invalid());
        }
        Ok(())
    }
}

/// Constructed only by the trusted backend adapter, never deserialized from
/// an incoming Team request. Control stays on a separate private pipe; raw
/// backend output goes only to fresh private files owned by the guardian.
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Program {
    pub executable: PathBuf,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub folder: PathBuf,
    pub input: PathBuf,
    pub output: PathBuf,
    pub errors: PathBuf,
}
impl Program {
    fn valid(&self) -> bool {
        self.executable.is_absolute()
            && self.folder.is_absolute()
            && self.input.is_absolute()
            && self.output.is_absolute()
            && self.errors.is_absolute()
            && self.args.len() <= 256
            && self.env.len() <= 256
            && self
                .env
                .keys()
                .all(|k| !k.is_empty() && !k.contains(['=', '\0']))
    }
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "camelCase", deny_unknown_fields)]
enum Event {
    Ready { pid: u32 },
    Started,
    Exited { code: Option<i32> },
    LaunchFailed,
}
#[derive(Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase", deny_unknown_fields)]
enum Control {
    Start {
        program: Program,
        window: BirthWindow,
    },
    Stop,
}
fn invalid() -> io::Error {
    io::Error::other("Team process ownership could not be verified.")
}
pub(crate) fn send(writer: &mut impl Write, value: &impl Serialize) -> io::Result<()> {
    let bytes = serde_json::to_vec(value).map_err(|_| invalid())?;
    if bytes.len() > FRAME {
        return Err(invalid());
    }
    writer.write_all(&bytes)?;
    writer.write_all(b"\n")?;
    writer.flush()
}
pub(crate) fn receive<T: serde::de::DeserializeOwned>(reader: &mut impl BufRead) -> io::Result<T> {
    let mut bytes = Vec::new();
    std::io::Read::take(&mut *reader, (FRAME + 1) as u64).read_until(b'\n', &mut bytes)?;
    if bytes.len() > FRAME || bytes.pop() != Some(b'\n') {
        return Err(invalid());
    }
    serde_json::from_slice(&bytes).map_err(|_| invalid())
}
fn fresh_file(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    options.open(path)
}
fn input_file(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000);
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > 8 * 1024 * 1024
    {
        return Err(invalid());
    }
    Ok(file)
}

/// Private hostd subcommand. It never opens an archive, serves a socket or
/// resolves a backend. An inherited pipe supplies one already-chosen program.
pub fn anchor_main() -> io::Result<()> {
    os::check_anchor()?;
    let mut out = io::stdout().lock();
    send(
        &mut out,
        &Event::Ready {
            pid: std::process::id(),
        },
    )?;
    let mut reader = BufReader::new(io::stdin());
    let Control::Start { program, window } = receive(&mut reader)? else {
        return Err(invalid());
    };
    if !program.valid() {
        return Err(invalid());
    }
    let spawned = (|| {
        let mut command = Command::new(&program.executable);
        command
            .args(&program.args)
            .env_clear()
            .envs(&program.env)
            .current_dir(&program.folder)
            .stdin(input_file(&program.input)?)
            .stdout(fresh_file(&program.output)?)
            .stderr(fresh_file(&program.errors)?);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000);
            if let Some(root) = std::env::var_os("SystemRoot") {
                command.env("SystemRoot", root);
            }
        }
        window.ensure_live()?;
        command.spawn()
    })();
    let mut child = match spawned {
        Ok(child) => {
            send(&mut out, &Event::Started)?;
            Some(child)
        }
        Err(_) => {
            send(&mut out, &Event::LaunchFailed)?;
            None
        }
    };
    let (sender, commands) = mpsc::sync_channel(1);
    std::thread::Builder::new()
        .name("team-anchor-control".into())
        .spawn(move || {
            // One Stop or pipe EOF is sufficient. A backend never inherits this
            // pipe as stdin, so its descendants cannot keep authority alive.
            let _command: io::Result<Control> = receive(&mut reader);
            let _ = sender.send(());
        })?;
    loop {
        if commands.try_recv() != Err(mpsc::TryRecvError::Empty) {
            return os::stop_self();
        }
        if let Some(process) = &mut child {
            match process.try_wait() {
                Ok(Some(status)) => {
                    send(
                        &mut out,
                        &Event::Exited {
                            code: status.code(),
                        },
                    )?;
                    child = None;
                }
                Ok(None) => {}
                Err(_) => return os::stop_self(),
            }
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}
/// What a recovery record names as the owner of a run's processes, given
/// the anchor's pid. On unix it is the anchor's session and group. On
/// Windows it is this guardian with its start time: its job is killed when
/// the guardian's last handle closes, so the guardian gone means the run gone.
pub(crate) fn run_owner(anchor: u32) -> (u32, u64) {
    os::run_owner(anchor)
}

/// Whether the owner recorded by `run_owner` is proven gone.
pub(crate) fn run_owner_gone(id: u32, born: u64) -> bool {
    os::run_owner_gone(id, born)
}

/// This boot of this computer. A run recorded under another boot cannot
/// have a process left.
pub(crate) fn boot_identity() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        let mut time = libc::timeval {
            tv_sec: 0,
            tv_usec: 0,
        };
        let mut size = std::mem::size_of::<libc::timeval>();
        // SAFETY: the name is NUL-terminated and the buffer is a timeval of
        // the size passed, which is what kern.boottime writes.
        let status = unsafe {
            libc::sysctlbyname(
                c"kern.boottime".as_ptr(),
                (&mut time as *mut libc::timeval).cast(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        (status == 0 && time.tv_sec > 0).then(|| format!("{}.{}", time.tv_sec, time.tv_usec))
    }
    #[cfg(target_os = "linux")]
    {
        std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
            .ok()
            .map(|id| id.trim().to_string())
            .filter(|id| !id.is_empty() && id.len() <= 64)
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        None
    }
}

pub fn guardian_main() -> Result<(), String> {
    crate::teams::guardian_main()
        .map_err(|_| "Team run needs recovery on its publishing computer.".into())
}

/// Owned by the trusted local runner. This value cannot be reconstructed from
/// a PID, serialized state or a peer-supplied stop target.
pub struct Owned {
    child: Child,
    input: Option<ChildStdin>,
    events: Receiver<io::Result<Event>>,
    os: os::Owner,
    finished: bool,
}
pub enum Poll {
    Running,
    Started,
    Exited(Option<i32>),
    LaunchFailed,
}
#[must_use]
pub struct Completion {
    _private: (),
}
impl Owned {
    pub fn start(
        helper: &Path,
        program: Program,
        before_birth: impl FnOnce(u32) -> io::Result<()>,
    ) -> io::Result<Self> {
        if !helper.is_absolute() || !program.valid() {
            return Err(invalid());
        }
        let mut command = Command::new(helper);
        command
            .arg("team-run-anchor")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        os::configure(&mut command);
        let mut child = command.spawn()?;
        let owned = os::Owner::attach(&child);
        let os = match owned {
            Ok(os) => os,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        };
        let input = child.stdin.take().ok_or_else(invalid)?;
        let output = child.stdout.take().ok_or_else(invalid)?;
        let (sender, events) = mpsc::sync_channel(8);
        let spawned = std::thread::Builder::new()
            .name("team-anchor-events".into())
            .spawn(move || {
                let mut reader = BufReader::new(output);
                loop {
                    let value = receive::<Event>(&mut reader);
                    let failed = value.is_err();
                    if sender.send(value).is_err() || failed {
                        break;
                    }
                }
            });
        let mut owner = Self {
            child,
            input: Some(input),
            events,
            os,
            finished: false,
        };
        spawned?;
        match owner
            .events
            .recv_timeout(Duration::from_secs(5))
            .map_err(|_| invalid())??
        {
            Event::Ready { pid } if pid == owner.child.id() => {}
            _ => return Err(invalid()),
        }
        owner.os.ensure_anchor(&owner.child)?;
        // Mint before the callback. Its authority check can then require at
        // least this much remaining time without a later scheduling gap
        // extending the one-shot window. Stamps stay only on private IPC.
        let window = BirthWindow::new()?;
        // The anchor leads the process group the backend is born into.
        before_birth(owner.child.id())?;
        window.ensure_live()?;
        send(
            owner.input.as_mut().ok_or_else(invalid)?,
            &Control::Start { program, window },
        )?;
        Ok(owner)
    }
    pub fn poll(&mut self) -> io::Result<Poll> {
        if self.finished {
            return Err(invalid());
        }
        match self.events.try_recv() {
            Ok(Ok(Event::Started)) => Ok(Poll::Started),
            Ok(Ok(Event::Exited { code })) => Ok(Poll::Exited(code)),
            Ok(Ok(Event::LaunchFailed)) => Ok(Poll::LaunchFailed),
            Err(mpsc::TryRecvError::Empty) => Ok(Poll::Running),
            _ => Err(invalid()),
        }
    }
    pub fn stop(&mut self) -> io::Result<Completion> {
        if self.finished {
            return Err(invalid());
        }
        if let Some(mut input) = self.input.take() {
            let _ = send(&mut input, &Control::Stop);
        }
        self.os.terminate(&self.child)?;
        let deadline = Instant::now() + STOP;
        loop {
            if self.os.stopped(&self.child)? {
                break;
            }
            if Instant::now() >= deadline {
                return Err(invalid());
            }
            // A concurrent fork may miss the first Unix signal sweep. The
            // unreaped anchor still pins the exact group for every retry.
            self.os.terminate(&self.child)?;
            std::thread::sleep(Duration::from_millis(10));
        }
        // Unix deliberately keeps the anchor waitable until group completion;
        // no signal ever uses a PID whose Child has already been reaped.
        self.child.wait()?;
        self.finished = true;
        Ok(Completion { _private: () })
    }
}
impl Drop for Owned {
    fn drop(&mut self) {
        if !self.finished {
            let _ = self.stop();
        }
    }
}
