// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! The tokenstat host daemon.
//!
//! Serves the same dispatch the in-process bridge does, over a unix socket, so
//! a client that is not in this process (an iPad today's plan aside, another
//! app, a script) can ask the same questions.
//!
//! Runs in the foreground and logs to stderr. Lifetime belongs to launchd, not
//! to this binary: a daemon that forks itself is one that launchd cannot see,
//! restart, or stop.

use std::process::ExitCode;

use tokenstat_host::{Session, server};

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
    let mut args = std::env::args().skip(1);
    let mut socket = None;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--socket" | "-s" => {
                socket = Some(args.next().ok_or("--socket needs a path")?);
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

    // Open the archive before binding. Failing after the socket exists would
    // leave clients connecting to something that answers every request with an
    // error, which is harder to diagnose than a daemon that refused to start.
    let session = Session::open_default()?;
    let listener = server::bind(&path)?;
    eprintln!("tokenstat-hostd listening on {}", path.display());

    server::serve(listener, session)
}

const USAGE: &str = "\
tokenstat host daemon. Serves the local archive over a unix socket.

Usage: tokenstat-hostd [--socket <path>]

Options:
  -s, --socket <path>  Listen here instead of the default under the data dir
  -h, --help           Print this
  -V, --version        Print the version

Runs in the foreground. Use launchd to keep it alive; see docs/desktop-app.md.
";
