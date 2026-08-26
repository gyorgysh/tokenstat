// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! The tokenstat host daemon.
//!
//! Serves the same dispatch the in-process bridge does, over a unix socket
//! (macOS, Linux) or a named pipe (Windows), so a client that is not in this
//! process can ask the same questions.
//!
//! Runs in the foreground and logs to stderr. Lifetime belongs to launchd or
//! the Windows scheduled task, not to this binary: a daemon that forks itself
//! is one the supervisor cannot see, restart, or stop.

use std::process::ExitCode;

use tokenstat_host::{Session, ownership, server};

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("tokenstat-hostd: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    // The daemon holds a connection per peer, a stream per screen session and
    // a socket per SSH session at once. See `open_files`.
    tokenstat_host::open_files::raise_open_file_limit();

    let mut args = std::env::args().skip(1);
    let mut socket = None;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--socket" | "-s" | "--pipe" => {
                socket = Some(args.next().ok_or("--socket / --pipe needs a path")?);
            }
            "--help" | "-h" => {
                println!("{USAGE}");
                return Ok(());
            }
            "--version" | "-V" => {
                println!("tokenstat-hostd {}", env!("CARGO_PKG_VERSION"));
                return Ok(());
            }
            other => return Err(format!("unexpected argument: {other}\n\n{USAGE}")),
        }
    }

    let path = match socket {
        Some(p) => std::path::PathBuf::from(p),
        None => server::default_socket_path()?,
    };

    // Before anything else, and before the archive is opened: one machine
    // identity, one daemon. Two hosts sharing a key expire each other's tunnel
    // credential on every renewal and knock each other off the relay, which
    // reads as an unreachable machine and names no cause anywhere. See
    // `ownership`.
    let role = ownership::ensure_may_serve(&path)?;
    if role == ownership::Role::Secondary {
        watch_for_the_installed_host();
    }

    // The login environment resolve is the one piece of a first spawn that can
    // take seconds (a loaded shell profile). Start it now, on a thread, so the
    // archive open and socket bind below overlap with it and the resolve is
    // finished by the time anybody can ask for a terminal.
    tokenstat_pty::warm_login_env();
    // The first Shell click should not pay a login-shell startup either, so a
    // fully-started shell is warmed beside the environment and handed over on
    // request.
    tokenstat_pty::warm_shell_pool();

    // Open the archive before binding. Failing after the socket exists would
    // leave clients connecting to something that answers every request with an
    // error, which is harder to diagnose than a daemon that refused to start.
    let session = Session::open_default()?;
    let listener = server::bind(&path)?;
    eprintln!("tokenstat-hostd listening on {}", path.display());

    server::serve(listener, session)
}

/// A second daemon that started while nothing else was running still has to
/// give the machine back when the installed host arrives.
///
/// The startup check only covers one order of events. Reboot, a `launchctl
/// kickstart`, a scheduled-task start, or simply opening the app is enough
/// to bring the installed host up behind a development one, and from that
/// moment the two are fighting over the same tunnel credential again.
///
/// Exiting rather than standing down in place. This process is by definition
/// the one nobody installed: nothing restarts it, the terminals it owns are a
/// test session's, and leaving it half alive would mean two daemons answering
/// two sockets with one archive between them. A loud exit is easier to
/// understand than a daemon that quietly stopped doing half its job.
fn watch_for_the_installed_host() {
    let Ok(identity) = tokenstat_identity::MachineIdentity::load_or_create() else {
        return;
    };
    let key = identity.public_key_hex();
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(std::time::Duration::from_secs(20));
            if ownership::owned_by_primary(&key) {
                eprintln!(
                    "tokenstat-hostd: the installed host has taken this machine's identity \
                     back, so this second daemon is stopping. Two hosts on one identity \
                     expire each other's tunnel credential."
                );
                std::process::exit(0);
            }
        }
    });
}

#[cfg(windows)]
const USAGE: &str = "\
tokenstat host daemon. Serves the local archive over a named pipe.

Usage: tokenstat-hostd [--pipe <name>]

Options:
  -s, --socket <name>  Same as --pipe
      --pipe <name>    Listen here instead of \\\\.\\pipe\\ai.tokenstat.hostd.<user>
  -h, --help           Print this
  -V, --version        Print the version

Runs in the foreground. Use a per-user scheduled task to keep it alive.
See scripts/install-host-task.ps1.
";

#[cfg(not(windows))]
const USAGE: &str = "\
tokenstat host daemon. Serves the local archive over a unix socket.

Usage: tokenstat-hostd [--socket <path>]

Options:
  -s, --socket <path>  Listen here instead of the default under the data dir
      --pipe <path>    Same as --socket
  -h, --help           Print this
  -V, --version        Print the version

Runs in the foreground. Use launchd to keep it alive; see docs/desktop-app.md.
";
