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
//! # The `local-host` feature
//!
//! On by default, and off for the mobile slices. It is the line between what a
//! machine does for itself (terminals, agent launches, registered folders,
//! automations, its own archive) and what a client does about an account or
//! about somebody else's machine. A build without it cannot express a spawn,
//! which is the only honest way to compile for a platform that has no fork.
//!
//! # Layout
//!
//! - [`dto`] is the wire contract. Change it deliberately, it is public API.
//! - [`session`] is a conversation's state, with an archive only where there is
//!   one. A plain struct, not a global.
//! - [`error`] is the code a failed call carries.
//! - [`dispatch`] maps a method name onto the core.
//! - `machine` answers who this machine is and which peers it trusts.
//! - [`remote`] serves other machines and reaches them, over the same dispatch.
//! - [`server`] is the socket listener.

pub mod account_activity;
#[cfg(feature = "local-host")]
pub mod activity;
#[cfg(feature = "local-host")]
pub(crate) mod agent_models;
#[cfg(feature = "local-host")]
pub mod automations;
pub mod base64;
pub mod cloud_import;
pub mod dispatch;
pub mod dto;
pub mod error;
#[cfg(feature = "local-host")]
pub(crate) mod harness_config;
pub(crate) mod host_policy;
pub(crate) mod keep_awake;
#[cfg(feature = "local-host")]
pub(crate) mod launcher;
#[cfg(feature = "local-host")]
pub(crate) mod local_models;
mod machine;
/// Which daemon speaks for this machine, when more than one is running.
pub mod ownership;
pub mod pricing;
mod proxy_http;
pub mod remote;
/// Loopback proxy for phones that dial a host service (no full stream stack).
/// Host builds use `remote_stream` instead.
#[cfg(not(feature = "local-host"))]
pub(crate) mod remote_proxy;
#[cfg(feature = "local-host")]
pub(crate) mod remote_stream;
pub(crate) mod request_context;
pub mod screen_policy;
#[cfg(feature = "local-host")]
pub(crate) mod screen_runtime;
pub mod screen_stream;
pub(crate) mod screen_transfer;
pub(crate) mod screen_viewer;
pub mod server;
pub mod session;
#[cfg(feature = "local-host")]
mod session_meter;
pub mod ssh_client;
pub mod ssh_records;
#[cfg(all(unix, feature = "local-host"))]
mod sync_scheduler;
#[cfg(feature = "local-host")]
mod todo;
#[cfg(feature = "local-host")]
pub(crate) mod transcript;
pub mod vault;
#[cfg(feature = "local-host")]
pub mod workflows;
#[cfg(feature = "local-host")]
pub mod workspaces;

pub use dispatch::call;
pub use error::DispatchError;
pub use session::{OpenParams, Session};
/// Re-exported so a transport can warm the pty before its first spawn without
/// taking a dependency on the pty crate of its own. `server::serve` calls it;
/// the C ABI has no `serve` to call, so it needs this.
#[cfg(feature = "local-host")]
pub use tokenstat_pty::warm_login_env;
/// The warm shell pool, re-exported for the same reason as [`warm_login_env`].
#[cfg(feature = "local-host")]
pub use tokenstat_pty::warm_shell_pool;

/// Version of the wire contract, not of the crate.
///
/// A front end should refuse to talk to a host whose major version it does not
/// recognize, which is what makes the eventual remote transport safe to upgrade
/// independently at each end.
pub const PROTOCOL_VERSION: &str = "1";
