// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! The protocol every tokenstat front end speaks, and the daemon that serves it.
//!
//! # Why this crate exists
//!
//! iOS and iPadOS cannot fork or exec, so a mobile client can never run an
//! agent locally and is inherently a client of a machine that can. Building the
//! desktop app as a monolith would mean rewriting it when mobile lands.
//! Everything therefore goes through one dispatch, reachable over more than one
//! transport:
//!
//! - [`dispatch::call`] in process, which is what the C ABI in `tokenstat-ffi`
//!   wraps for the Mac app today.
//! - [`server`] over a unix socket, which is the same dispatch with a different
//!   way in.
//! - [`remote`] over an authenticated, encrypted connection to another machine,
//!   which is that seam now attached. See `docs/remote-transport.md`.
//!
//! There is deliberately no second implementation. A method cannot exist over
//! one transport and be missing from the other.
//!
//! # Layout
//!
//! - [`dto`] is the wire contract. Change it deliberately, it is public API.
//! - [`session`] is one open archive. A plain struct, not a global.
//! - [`dispatch`] maps a method name onto the core.
//! - `machine` answers who this machine is and which peers it trusts.
//! - [`remote`] serves other machines and reaches them, over the same dispatch.
//! - [`server`] is the socket listener.

pub mod account_activity;
pub mod automations;
pub mod base64;
pub mod dispatch;
pub mod dto;
pub(crate) mod launcher;
mod machine;
pub mod pricing;
pub mod remote;
pub(crate) mod remote_stream;
pub mod server;
pub mod session;
#[cfg(unix)]
mod sync_scheduler;
mod todo;
pub mod workspaces;

pub use dispatch::call;
pub use session::{OpenParams, Session};
/// Re-exported so a transport can warm the pty before its first spawn without
/// taking a dependency on the pty crate of its own. `server::serve` calls it;
/// the C ABI has no `serve` to call, so it needs this.
pub use tokenstat_pty::warm_login_shell_path;

/// Version of the wire contract, not of the crate.
///
/// A front end should refuse to talk to a host whose major version it does not
/// recognize, which is what makes the eventual remote transport safe to upgrade
/// independently at each end.
pub const PROTOCOL_VERSION: &str = "1";
