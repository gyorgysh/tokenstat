// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Which daemon speaks for this machine.
//!
//! # Why this exists
//!
//! A machine identity is a single thing on the account: one key, one row in
//! the directory, one tunnel credential. Two daemons sharing one identity do
//! not share it, they fight over it, and the fight is silent and permanent.
//!
//! Minting a tunnel credential retires every other live one for the machine,
//! so each daemon's renewal expires the other's token. Each is denied
//! `token_expired`, each correctly mints a replacement, and each replacement
//! breaks the other. The relay makes it worse: a HELLO for a key that is
//! already live takes the slot and drops the old socket's channels, so the two
//! also knock each other off, and every dial that lands in the gap is answered
//! `no_such_peer`. A machine in this state reads as flaky to everybody who
//! tries to reach it, and no log line on either side names the cause.
//!
//! This is not hypothetical. It ran for four days here: a `--socket /tmp/...`
//! daemon left over from an afternoon's testing against the launchd one.
//!
//! # The rule
//!
//! The daemon listening on [`crate::server::default_socket_path`] is the
//! machine's host. That is the path launchd or the Windows task starts, the
//! path the app probes, and the path an installed tokenstat uses, so it is the
//! one that must always win. A daemon anywhere else is a second copy and
//! stands down.
//!
//! Standing down is decided by *identity*, not by existence. Two daemons with
//! separate `TOKENSTAT_IDENTITY_DIR`s are two machines, which is the supported
//! way to run a development host beside a real one, and neither is asked to
//! yield. Only a second daemon carrying the *same key* is a problem.

use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::time::Duration;

#[cfg(unix)]
use std::os::unix::net::UnixStream;

/// What a daemon is to this machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// On the default socket. The machine's host, and never asked to yield.
    Primary,
    /// On some other socket. Yields the machine to a primary carrying the same
    /// key.
    Secondary,
}

/// How long the probe waits for the other daemon to answer.
///
/// Short on purpose. This runs before the socket is bound, so it is time
/// nobody's daemon is up, and a primary too busy to answer `remote.status` in
/// two seconds is one this process should not assume owns anything.
const PROBE_PATIENCE: Duration = Duration::from_secs(2);

/// Which role a daemon on `socket` plays.
pub fn role_for(socket: &Path) -> Role {
    match crate::server::default_socket_path() {
        // Compared after resolving symlinks where both exist, so
        // `/tmp` against `/private/tmp` on macOS is not read as two paths.
        Ok(default) if same_path(socket, &default) => Role::Primary,
        _ => Role::Secondary,
    }
}

fn same_path(left: &Path, right: &Path) -> bool {
    if left == right {
        return true;
    }
    #[cfg(windows)]
    {
        return left
            .to_string_lossy()
            .eq_ignore_ascii_case(&right.to_string_lossy());
    }
    #[cfg(not(windows))]
    match (left.canonicalize(), right.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        // A socket that does not exist yet cannot be canonicalized, which is
        // the ordinary case at startup. Fall back to the parent directory,
        // which does exist, plus the file name.
        _ => match (
            left.parent().map(Path::canonicalize),
            right.parent().map(Path::canonicalize),
        ) {
            (Some(Ok(a)), Some(Ok(b))) => a == b && left.file_name() == right.file_name(),
            _ => false,
        },
    }
}

/// The public key of the daemon already answering on the default socket, if
/// one is.
///
/// `None` covers every way there is no primary to yield to: nothing listening,
/// a stale socket file, a daemon too busy to answer, an answer that will not
/// parse. All of them mean "carry on", because refusing to start on a probe
/// that failed for its own reasons would be a worse failure than the one this
/// guards against.
pub fn primary_key() -> Option<String> {
    let path = crate::server::default_socket_path().ok()?;
    let mut stream = connect_primary(&path)?;
    stream
        .write_all(b"{\"id\":0,\"method\":\"remote.status\"}\n")
        .ok()?;
    stream.flush().ok()?;
    let mut line = String::new();
    BufReader::new(&mut stream).read_line(&mut line).ok()?;
    let answer: serde_json::Value = serde_json::from_str(&line).ok()?;
    answer
        .get("result")?
        .get("key")?
        .as_str()
        .map(|key| key.to_ascii_lowercase())
}

#[cfg(unix)]
fn connect_primary(path: &Path) -> Option<UnixStream> {
    let stream = UnixStream::connect(path).ok()?;
    stream.set_read_timeout(Some(PROBE_PATIENCE)).ok()?;
    stream.set_write_timeout(Some(PROBE_PATIENCE)).ok()?;
    Some(stream)
}

#[cfg(windows)]
fn connect_primary(path: &Path) -> Option<std::fs::File> {
    let timeout = u32::try_from(PROBE_PATIENCE.as_millis()).unwrap_or(u32::MAX);
    crate::server::connect(path, timeout).ok()
}

/// Whether a primary daemon is already speaking for this key.
///
/// Compared on the key rather than on the socket existing, so a development
/// daemon under its own `TOKENSTAT_IDENTITY_DIR` is left alone: it is a
/// different machine and there is nothing for it to collide with.
pub fn owned_by_primary(my_key: &str) -> bool {
    primary_key().is_some_and(|key| key == my_key.to_ascii_lowercase())
}

/// The one call a daemon makes before it binds: may this process serve?
///
/// `Ok(role)` means carry on. `Err(message)` is a secondary that would collide
/// with the installed host, and the message is written to be read by the person
/// who just typed the command.
pub fn ensure_may_serve(socket: &Path) -> Result<Role, String> {
    let role = role_for(socket);
    hold_identity_lock().map_err(|_| refusal(socket))?;
    if role == Role::Primary {
        return Ok(role);
    }
    // Loaded rather than passed in: the key is what decides this, and a caller
    // that had to fetch it first could get the comparison wrong in a way this
    // module could not stop.
    //
    // Load, never create. A machine with no key yet cannot have another
    // process holding it, so the answer is already known, and minting one here
    // would leave identity material behind for a daemon that is about to
    // refuse to start.
    let Some(identity) = tokenstat_identity::MachineIdentity::load().map_err(|e| e.to_string())?
    else {
        return Ok(role);
    };
    if owned_by_primary(&identity.public_key_hex()) {
        return Err(refusal(socket));
    }
    Ok(role)
}

/// Exclusive lock on this identity directory.
///
/// An OS advisory lock on a file beside the key, held for the process
/// lifetime. A PID file plus unlink-if-empty let two starters both win
/// (the winner writes the pid after create, so the file is empty for a
/// real window) and a reused pid after a crash blocked a healthy restart.
/// `flock` (and `LockFileEx` on Windows) dies with the process, so a crash
/// cannot leave a stale owner. A separate `TOKENSTAT_IDENTITY_DIR` is still a
/// second machine.
fn hold_identity_lock() -> Result<(), String> {
    use std::fs::OpenOptions;
    use std::io::Write;
    #[cfg(unix)]
    use std::os::unix::io::AsRawFd;
    use std::sync::Mutex;

    static HELD: Mutex<Option<std::fs::File>> = Mutex::new(None);

    let path = tokenstat_identity::identity_dir()
        .map_err(|e| e.to_string())?
        .join("host.lock");
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(&path)
        .map_err(|e| e.to_string())?;

    #[cfg(unix)]
    {
        #[link(name = "c")]
        unsafe extern "C" {
            fn flock(fd: i32, operation: i32) -> i32;
        }
        // LOCK_EX | LOCK_NB. Same values on macOS and Linux.
        const LOCK_EX: i32 = 2;
        const LOCK_NB: i32 = 4;
        let rc = unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
        if rc != 0 {
            return Err("identity already served".into());
        }
    }
    #[cfg(windows)]
    {
        if !crate::win32::try_lock_exclusive(&file, false) {
            return Err("identity already served".into());
        }
    }
    let _ = writeln!(&mut file, "{}", std::process::id());
    *HELD.lock().unwrap_or_else(|e| e.into_inner()) = Some(file);
    Ok(())
}

/// What to print when a secondary refuses to start.
///
/// The message has to carry the repair, because the person reading it is
/// almost always in the middle of testing something and the obvious next move
/// (run it again) is the one that does not work.
pub fn refusal(socket: &std::path::Path) -> String {
    let endpoint = socket.display();
    #[cfg(windows)]
    let repair = format!(
        "To run a second host for development, give it its own identity:\n\
         \n    set TOKENSTAT_IDENTITY_DIR=%TEMP%\\tokenstat-dev\n\
         \n    tokenstat-hostd --pipe {endpoint}\n\
         \nOr stop the installed one first: schtasks /End /TN ai.tokenstat.hostd"
    );
    #[cfg(not(windows))]
    let repair = format!(
        "To run a second host for development, give it its own identity:\n\
         \n    TOKENSTAT_IDENTITY_DIR=/tmp/tokenstat-dev tokenstat-hostd --socket {endpoint}\n\
         \nOr stop the installed one first: launchctl bootout gui/$UID/ai.tokenstat.hostd"
    );
    format!(
        "another tokenstat host is already serving this machine's identity, so this one \
         will not start on {endpoint}.\n\
         Two daemons on one identity fight over the tunnel credential: each renewal expires \
         the other's, and the machine ends up unreachable for everybody.\n\
         {repair}"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The installed daemon's path is the one that must always win, whatever
    /// order the two happened to start in.
    #[test]
    fn the_default_socket_is_the_primary() {
        let default = crate::server::default_socket_path().expect("a data directory");
        assert_eq!(role_for(&default), Role::Primary);
        #[cfg(windows)]
        let other = std::path::Path::new(r"\\.\pipe\tokenstat-dev-other");
        #[cfg(not(windows))]
        let other = std::path::Path::new("/tmp/ts-new.sock");
        assert_eq!(role_for(other), Role::Secondary);
    }

    /// The message is read by somebody whose next instinct is to run the
    /// command again, so it has to name the two things that actually work.
    #[test]
    fn the_refusal_says_how_to_run_two_hosts() {
        #[cfg(windows)]
        let path = std::path::Path::new(r"\\.\pipe\tokenstat-dev-other");
        #[cfg(not(windows))]
        let path = std::path::Path::new("/tmp/ts-new.sock");
        let text = refusal(path);
        assert!(text.contains("TOKENSTAT_IDENTITY_DIR"), "{text}");
        #[cfg(windows)]
        {
            assert!(text.contains("schtasks"), "{text}");
            assert!(text.contains(r"\\.\pipe\tokenstat-dev-other"), "{text}");
        }
        #[cfg(not(windows))]
        {
            assert!(text.contains("launchctl bootout"), "{text}");
            assert!(text.contains("/tmp/ts-new.sock"), "{text}");
        }
    }
}
