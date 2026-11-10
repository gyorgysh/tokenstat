// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Keep the GUI a client of the one daemon that owns this machine's archive.

use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_json::{Value, json};

/// Insights snapshots and the host policy are checked before mounting the UI.
pub const MIN_PROTOCOL: u64 = 53;

/// A reader lock has the same lifetime and flock semantics as the other clients.
pub struct OwnerLock {
    _file: File,
}

impl OwnerLock {
    /// Hold the existing host owner lease, so laptop policy sees the open app.
    pub fn acquire(data_dir: &Path) -> Result<Self> {
        std::fs::create_dir_all(data_dir)?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(data_dir.join("host-owner.lock"))?;
        // SAFETY: the descriptor belongs to `file` and stays open in this guard.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(Self { _file: file })
    }
}

/// Only display values from the shared host. Unknown counters stay optional.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Counters {
    pub total: u64,
    pub input_fresh: Option<u64>,
    pub output: Option<u64>,
    pub cache_read: Option<u64>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Totals {
    pub counters: Counters,
    pub events: u64,
    pub sessions: u64,
    pub days: u64,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Bucket {
    pub key: String,
    pub counters: Counters,
    pub sessions: u64,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Info {
    pub core_version: String,
    pub timezone: String,
    pub last_scan_ms: Option<i64>,
    pub open_files: Option<u64>,
    pub open_file_limit: Option<u64>,
}

/// One internally consistent archive reading, rather than independent totals.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub info: Info,
    pub totals: Totals,
    pub by_model: Vec<Bucket>,
    pub by_source: Vec<Bucket>,
    pub by_project: Vec<Bucket>,
}

/// A socket override is useful for isolated development, never a second backend.
#[derive(Clone)]
pub struct Client {
    pub socket: PathBuf,
    pub allow_spawn: bool,
}

impl Client {
    pub(crate) fn call(&self, method: &str, params: Value) -> Result<Value> {
        self.call_with_timeout(method, params, Duration::from_secs(30))
    }
    pub(crate) fn call_with_timeout(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value> {
        let stream = UnixStream::connect(&self.socket)
            .with_context(|| format!("Cannot reach the host at {}", self.socket.display()))?;
        tokenstat_core::host_rpc::exchange_detailed(stream, method, params, timeout)
            .map_err(anyhow::Error::new)
    }

    /// Call this on a worker. The protocol check comes before feature requests.
    pub fn snapshot(&self, scan: bool) -> Result<Snapshot> {
        self.prepare()?;
        if scan {
            self.call("scan", json!({}))?;
        }
        serde_json::from_value(self.call("insights.snapshot", json!({}))?)
            .context("The host returned an incomplete Insights snapshot")
    }

    pub(crate) fn prepare(&self) -> Result<()> {
        self.ensure_host()?;
        check_protocol(&self.call("protocol", json!({}))?)
    }

    fn ensure_host(&self) -> Result<()> {
        if socket_available(&self.socket)? {
            return Ok(());
        }
        if !self.allow_spawn || !cfg!(target_os = "linux") {
            bail!("The host is offline. Start tokenstat-hostd, then choose Refresh.");
        }
        start_if_offline(&self.socket, || self.start_host())
    }

    fn start_host(&self) -> Result<()> {
        // A loaded service owns its own restart policy. Do not replace its unit,
        // enable remote access, or enable lingering from an ordinary GUI launch.
        let managed = probe_service("systemctl", Duration::from_secs(5))?;
        if managed {
            request_service_start("systemctl", Duration::from_secs(5))?;
        } else {
            let executable = std::env::current_exe()?;
            let binary = executable.with_file_name("tokenstat-hostd");
            if !binary.is_file() {
                bail!("tokenstat-hostd is missing beside the desktop executable.");
            }
            let state = crate::integration::state_dir()?;
            std::fs::create_dir_all(&state)?;
            let path = state.join("hostd.log");
            if path.metadata().is_ok_and(|m| m.len() > 5 * 1024 * 1024) {
                std::fs::rename(&path, state.join("hostd.previous.log"))?;
            }
            let log = OpenOptions::new()
                .create(true)
                .append(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&path)?;
            let mut child = Command::new(binary)
                .arg("--socket")
                .arg(&self.socket)
                .stdin(Stdio::null())
                .stdout(log.try_clone()?)
                .stderr(log)
                .spawn()?;
            // Reap without making window close terminate a host shared by others.
            std::thread::spawn(move || {
                let _ = child.wait();
            });
        }
        wait_for_socket(
            &self.socket,
            Duration::from_secs(10),
            Duration::from_millis(100),
        )
    }
}

struct CommandOutput {
    status: ExitStatus,
    stdout: Vec<u8>,
}

/// Only the short-lived systemctl client is killed on timeout, never the unit
/// or its host. Nonblocking reads keep a full pipe or inherited descriptor
/// from extending the deadline. Error paths reap the owned client off-thread.
fn bounded_command(command: &mut Command, timeout: Duration) -> io::Result<CommandOutput> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut stdout = child.stdout.take().expect("piped stdout");
    let result = (|| {
        // SAFETY: stdout owns this live descriptor; fcntl changes its flags only.
        let flags = unsafe { libc::fcntl(stdout.as_raw_fd(), libc::F_GETFL) };
        if flags == -1
            || unsafe { libc::fcntl(stdout.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) }
                == -1
        {
            return Err(io::Error::last_os_error());
        }
        let deadline = Instant::now() + timeout;
        let mut output = Vec::new();
        let mut buffer = [0; 1024];
        loop {
            let status = child.try_wait()?;
            loop {
                match stdout.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => {
                        if output.len() + count > 4096 {
                            return Err(io::Error::new(
                                io::ErrorKind::InvalidData,
                                "service manager output is too large",
                            ));
                        }
                        output.extend_from_slice(&buffer[..count]);
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) => return Err(error),
                }
            }
            if let Some(status) = status {
                return Ok(CommandOutput {
                    status,
                    stdout: output,
                });
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "service manager command timed out",
                ));
            }
            std::thread::sleep(Duration::from_millis(20).min(remaining));
        }
    })();
    if result.is_err() {
        let _ = child.kill();
        std::thread::spawn(move || {
            let _ = child.wait();
        });
    }
    result
}

fn service_is_managed(output: &CommandOutput) -> Result<bool> {
    let state = std::str::from_utf8(&output.stdout)
        .context("Invalid user service state")?
        .trim();
    match state {
        "loaded" if output.status.success() => Ok(true),
        "loaded" => bail!("The user host service could not be checked. Choose Refresh to retry."),
        "not-found" => Ok(false),
        "masked" | "bad-setting" | "error" => {
            bail!("The user host service is {state}. Check its configuration before retrying.")
        }
        // Preserve the existing unmanaged fallback when there is no usable
        // user manager, but never use it after a timeout or malformed success.
        _ if !output.status.success() => Ok(false),
        _ => bail!("The user host service returned an unrecognized state."),
    }
}

fn service_timeout() -> anyhow::Error {
    anyhow::anyhow!(
        "The user service manager did not respond. The host may still be starting; choose Refresh to retry."
    )
}

fn probe_service(program: impl AsRef<std::ffi::OsStr>, timeout: Duration) -> Result<bool> {
    let mut show = Command::new(program);
    show.args([
        "--user",
        "show",
        "-p",
        "LoadState",
        "--value",
        "tokenstat-host.service",
    ]);
    match bounded_command(&mut show, timeout) {
        Ok(output) => service_is_managed(&output),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) if error.kind() == io::ErrorKind::TimedOut => Err(service_timeout()),
        Err(error) => Err(error).context("Cannot check the user host service"),
    }
}

fn request_service_start(program: impl AsRef<std::ffi::OsStr>, timeout: Duration) -> Result<()> {
    let mut start = Command::new(program);
    start.args(["--user", "--no-block", "start", "tokenstat-host.service"]);
    let output = bounded_command(&mut start, timeout).map_err(|error| {
        if error.kind() == io::ErrorKind::TimedOut {
            service_timeout()
        } else {
            anyhow::Error::new(error).context("Cannot start the user host service")
        }
    })?;
    if !output.status.success() {
        bail!("The user host service could not start. Check its journal.");
    }
    Ok(())
}

fn socket_available(path: &Path) -> Result<bool> {
    match UnixStream::connect(path) {
        Ok(_) => Ok(true),
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
            ) =>
        {
            Ok(false)
        }
        Err(error) => Err(error.into()),
    }
}

fn wait_for_socket(path: &Path, timeout: Duration, interval: Duration) -> Result<()> {
    let deadline = Instant::now() + timeout;
    loop {
        if socket_available(path)
            .with_context(|| format!("Cannot reach the host at {}", path.display()))?
        {
            return Ok(());
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            bail!("The host did not become ready. Check the host log, then choose Refresh.");
        }
        std::thread::sleep(interval.min(remaining));
    }
}

type StartupResult = std::result::Result<(), std::sync::Arc<str>>;

#[derive(Default)]
struct StartupFlight {
    outcome: std::sync::Mutex<Option<StartupResult>>,
    completed: std::sync::Condvar,
}

fn startup_flights()
-> &'static std::sync::Mutex<std::collections::HashMap<PathBuf, std::sync::Weak<StartupFlight>>> {
    static FLIGHTS: std::sync::OnceLock<
        std::sync::Mutex<std::collections::HashMap<PathBuf, std::sync::Weak<StartupFlight>>>,
    > = std::sync::OnceLock::new();
    FLIGHTS.get_or_init(Default::default)
}

/// Concurrent panels within this process share one startup for each socket,
/// including its failure. Recheck after joining the flight: another process
/// might have started the host in the meantime. Completed flights are held
/// only by their callers, so a later request can retry a failure.
fn start_if_offline(socket: &Path, start: impl FnOnce() -> Result<()>) -> Result<()> {
    let mut flights = startup_flights()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let (flight, leader) = if let Some(flight) = flights.get(socket).and_then(|f| f.upgrade()) {
        (flight, false)
    } else {
        flights.retain(|_, flight| flight.strong_count() != 0);
        let flight = std::sync::Arc::new(StartupFlight::default());
        flights.insert(socket.to_path_buf(), std::sync::Arc::downgrade(&flight));
        (flight, true)
    };
    drop(flights);
    if !leader {
        let mut outcome = flight
            .outcome
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        while outcome.is_none() {
            outcome = flight
                .completed
                .wait(outcome)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
        let result = outcome.as_ref().unwrap().clone();
        drop(outcome);
        result.map_err(anyhow::Error::msg)?;
        if !socket_available(socket)? {
            bail!("The host stopped during startup. Choose Refresh to try again.");
        }
        return Ok(());
    }
    // A panic must release waiters, too; preserve the leader's panic behavior.
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if socket_available(socket)? {
            Ok(())
        } else {
            start()
        }
    }));
    let shared = match &result {
        Ok(Ok(())) => Ok(()),
        Ok(Err(error)) => Err(format!("{error:#}").into()),
        Err(_) => Err("The host startup task stopped unexpectedly.".into()),
    };
    *flight
        .outcome
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(shared);
    flight.completed.notify_all();
    match result {
        Ok(result) => result,
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

fn check_protocol(value: &Value) -> Result<()> {
    let version = value["protocolVersion"]
        .as_str()
        .and_then(|s| s.parse::<u64>().ok())
        .context("The host did not report a supported protocol version")?;
    if version < MIN_PROTOCOL {
        bail!(
            "This desktop needs host protocol {MIN_PROTOCOL} or newer. Update the host, then choose Refresh."
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;
    use std::sync::{
        Arc, Barrier, Mutex,
        atomic::{AtomicUsize, Ordering},
    };

    #[test]
    fn old_hosts_are_refused_before_feature_calls() {
        for value in [
            json!({}),
            json!({"protocolVersion":"52"}),
            json!({"protocolVersion":"bad"}),
        ] {
            assert!(check_protocol(&value).is_err());
        }
        assert!(check_protocol(&json!({"protocolVersion":"53"})).is_ok());
    }

    #[test]
    fn service_manager_commands_are_bounded_and_preserve_known_unit_states() {
        fn shell(script: &str, timeout: Duration) -> io::Result<CommandOutput> {
            let mut command = Command::new("/bin/sh");
            command.args(["-c", script]);
            bounded_command(&mut command, timeout)
        }
        let timeout = Duration::from_secs(5);
        let loaded = shell("printf 'loaded\\n'", timeout).unwrap();
        assert!(service_is_managed(&loaded).unwrap());
        let missing = shell("printf 'not-found\\n'", timeout).unwrap();
        assert!(!service_is_managed(&missing).unwrap());
        for state in ["masked", "bad-setting", "error", "unexpected"] {
            let output = shell(&format!("printf '{state}\\n'"), timeout).unwrap();
            assert!(service_is_managed(&output).is_err());
        }
        let unavailable = shell("exit 1", timeout).unwrap();
        assert!(!service_is_managed(&unavailable).unwrap());
        assert_eq!(
            shell("exec sleep 10", Duration::from_millis(100))
                .err()
                .unwrap()
                .kind(),
            io::ErrorKind::TimedOut
        );
        assert_eq!(
            shell("while :; do printf '%01024d' 0; done", timeout)
                .err()
                .unwrap()
                .kind(),
            io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn service_probe_and_start_use_owned_commands_and_do_not_fallback_on_timeout() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let fake = |name: &str, script: &str| {
            let path = dir.path().join(name);
            std::fs::write(&path, format!("#!/bin/sh\n{script}\n")).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
            path
        };
        let probe = fake(
            "probe",
            "[ \"$*\" = '--user show -p LoadState --value tokenstat-host.service' ] || exit 3\nprintf 'loaded\\n'",
        );
        assert!(probe_service(&probe, Duration::from_secs(5)).unwrap());
        assert!(!probe_service(dir.path().join("absent"), Duration::from_secs(5)).unwrap());
        let masked = fake("masked", "printf 'masked\\n'");
        assert!(probe_service(&masked, Duration::from_secs(5)).is_err());
        let hung = fake("hung", "exec sleep 10");
        assert!(
            probe_service(&hung, Duration::from_millis(100))
                .unwrap_err()
                .to_string()
                .contains("did not respond")
        );
        let start = fake(
            "start",
            "[ \"$*\" = '--user --no-block start tokenstat-host.service' ] || exit 3",
        );
        request_service_start(&start, Duration::from_secs(5)).unwrap();
        assert!(
            request_service_start(&hung, Duration::from_millis(100))
                .unwrap_err()
                .to_string()
                .contains("may still be starting")
        );
        let failed = fake("failed", "exit 1");
        assert!(request_service_start(&failed, Duration::from_secs(5)).is_err());
    }

    #[test]
    fn concurrent_offline_requests_share_start_and_a_failure_can_retry() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("host.sock");
        let offline = Client {
            socket: socket.clone(),
            allow_spawn: false,
        };
        assert!(
            offline
                .ensure_host()
                .unwrap_err()
                .to_string()
                .contains("offline")
        );
        assert!(start_if_offline(&socket, || bail!("synthetic failure")).is_err());
        let starts = Arc::new(AtomicUsize::new(0));
        let listener = Arc::new(Mutex::new(None));
        let barrier = Arc::new(Barrier::new(12));
        std::thread::scope(|scope| {
            for _ in 0..12 {
                let socket = &socket;
                let starts = starts.clone();
                let listener = listener.clone();
                let barrier = barrier.clone();
                scope.spawn(move || {
                    barrier.wait();
                    start_if_offline(socket, || {
                        starts.fetch_add(1, Ordering::SeqCst);
                        *listener.lock().unwrap() = Some(UnixListener::bind(socket)?);
                        Ok(())
                    })
                    .unwrap();
                });
            }
        });
        assert_eq!(starts.load(Ordering::SeqCst), 1);
        assert!(listener.lock().unwrap().is_some());
    }

    #[test]
    fn invalid_socket_path_does_not_trigger_startup() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("not-a-directory");
        std::fs::write(&file, b"synthetic").unwrap();
        assert!(
            start_if_offline(&file.join("host.sock"), || {
                panic!("invalid socket path must not launch a host")
            })
            .is_err()
        );
    }

    #[test]
    fn startup_readiness_preserves_socket_errors_and_reports_timeouts() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("not-a-directory");
        std::fs::write(&file, b"synthetic").unwrap();
        let invalid = file.join("host.sock");
        let failure = wait_for_socket(&invalid, Duration::from_secs(5), Duration::from_millis(5))
            .unwrap_err();
        assert!(failure.to_string().contains("Cannot reach the host"));
        assert!(format!("{failure:#}").contains(&invalid.display().to_string()));
        let missing = dir.path().join("missing.sock");
        assert!(
            wait_for_socket(&missing, Duration::ZERO, Duration::from_millis(1))
                .unwrap_err()
                .to_string()
                .contains("did not become ready")
        );
        let listener = UnixListener::bind(&missing).unwrap();
        assert!(wait_for_socket(&missing, Duration::ZERO, Duration::from_millis(1)).is_ok());
        drop(listener);
    }

    #[test]
    fn concurrent_failure_is_shared_and_a_later_request_retries() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("failed.sock");
        let attempts = Arc::new(AtomicUsize::new(0));
        let barrier = Arc::new(Barrier::new(13));
        let (started, started_rx) = std::sync::mpsc::channel();
        let (release, release_rx) = std::sync::mpsc::channel();
        let release_rx = Arc::new(Mutex::new(release_rx));
        std::thread::scope(|scope| {
            let mut workers = Vec::new();
            for _ in 0..12 {
                let attempts = attempts.clone();
                let barrier = barrier.clone();
                let started = started.clone();
                let release_rx = release_rx.clone();
                let socket = &socket;
                workers.push(scope.spawn(move || {
                    barrier.wait();
                    start_if_offline(socket, || {
                        attempts.fetch_add(1, Ordering::SeqCst);
                        started.send(()).unwrap();
                        let _ = release_rx.lock().unwrap().recv();
                        bail!("synthetic startup failure")
                    })
                    .unwrap_err()
                    .to_string()
                }));
            }
            barrier.wait();
            started_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            let deadline = Instant::now() + Duration::from_secs(5);
            let all_joined = loop {
                let count = startup_flights()
                    .lock()
                    .unwrap()
                    .get(&socket)
                    .map_or(0, std::sync::Weak::strong_count);
                if count == 12 {
                    break true;
                }
                if Instant::now() >= deadline {
                    break false;
                }
                std::thread::yield_now();
            };
            release.send(()).unwrap();
            drop(release);
            for worker in workers {
                assert_eq!(worker.join().unwrap(), "synthetic startup failure");
            }
            assert!(all_joined, "all callers must join the held startup");
        });
        assert_eq!(attempts.load(Ordering::SeqCst), 1);
        let mut listener = None;
        start_if_offline(&socket, || {
            listener = Some(UnixListener::bind(&socket)?);
            Ok(())
        })
        .unwrap();
        assert!(listener.is_some());
    }

    #[test]
    fn startup_of_another_socket_is_not_blocked() {
        let dir = tempfile::tempdir().unwrap();
        let first = dir.path().join("first.sock");
        let second = dir.path().join("second.sock");
        let (started, started_rx) = std::sync::mpsc::channel();
        let (release, release_rx) = std::sync::mpsc::channel();
        let (finished, finished_rx) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            scope.spawn(move || {
                start_if_offline(&first, || {
                    started.send(()).unwrap();
                    release_rx.recv().unwrap();
                    bail!("finished held startup")
                })
                .unwrap_err();
            });
            started_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            scope.spawn(move || {
                let mut listener = None;
                let result = start_if_offline(&second, || {
                    listener = Some(UnixListener::bind(&second)?);
                    Ok(())
                });
                finished.send(result.is_ok() && listener.is_some()).unwrap();
            });
            let completed = finished_rx.recv_timeout(Duration::from_secs(5));
            release.send(()).unwrap();
            assert!(completed.unwrap());
        });
    }

    #[test]
    fn panicking_startup_releases_waiters_and_allows_retry() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("panic.sock");
        let (started, started_rx) = std::sync::mpsc::channel();
        let (release, release_rx) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            let leader_socket = &socket;
            let leader = scope.spawn(move || {
                start_if_offline(leader_socket, || {
                    started.send(()).unwrap();
                    release_rx.recv().unwrap();
                    panic!("synthetic startup panic")
                })
            });
            started_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            let follower = scope.spawn(|| {
                start_if_offline(&socket, || panic!("follower must join the held startup"))
            });
            let deadline = Instant::now() + Duration::from_secs(5);
            let joined = loop {
                let count = startup_flights()
                    .lock()
                    .unwrap()
                    .get(&socket)
                    .map_or(0, std::sync::Weak::strong_count);
                if count == 2 {
                    break true;
                }
                if Instant::now() >= deadline {
                    break false;
                }
                std::thread::yield_now();
            };
            release.send(()).unwrap();
            assert!(leader.join().is_err());
            assert!(
                follower
                    .join()
                    .unwrap()
                    .unwrap_err()
                    .to_string()
                    .contains("stopped unexpectedly")
            );
            assert!(joined, "follower must join the held startup");
        });
        let mut listener = None;
        start_if_offline(&socket, || {
            listener = Some(UnixListener::bind(&socket)?);
            Ok(())
        })
        .unwrap();
        assert!(listener.is_some());
    }

    #[test]
    fn owner_lease_is_visible_to_the_existing_flock_probe() {
        let dir = tempfile::tempdir().unwrap();
        let guard = OwnerLock::acquire(dir.path()).unwrap();
        let probe = OpenOptions::new()
            .read(true)
            .write(true)
            .open(dir.path().join("host-owner.lock"))
            .unwrap();
        assert_ne!(
            unsafe { libc::flock(probe.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        drop(guard);
        assert_eq!(
            unsafe { libc::flock(probe.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
    }

    #[test]
    fn refresh_uses_host_framing_and_preserves_unknown_counters() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("host.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let worker = std::thread::spawn(move || {
            // Readiness connects once before the two actual calls.
            drop(listener.accept().unwrap());
            for (method, result) in [
                ("protocol", json!({"protocolVersion":"53"})),
                (
                    "insights.snapshot",
                    json!({"info":{"coreVersion":"test","timezone":"UTC","lastScanMs":null,"openFiles":12,"openFileLimit":1024},"totals":{"counters":{"total":42,"inputFresh":null,"output":2,"cacheRead":null},"events":1,"sessions":1,"days":1},"byModel":[],"bySource":[],"byProject":[]}),
                ),
            ] {
                let (stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream);
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(request["method"], method);
                writeln!(
                    reader.get_mut(),
                    "{}",
                    json!({"id":1,"ok":true,"result":result})
                )
                .unwrap();
            }
        });
        let result = Client {
            socket,
            allow_spawn: false,
        }
        .snapshot(false)
        .unwrap();
        assert_eq!(result.totals.counters.total, 42);
        assert_eq!(result.totals.counters.input_fresh, None);
        worker.join().unwrap();
    }
}
