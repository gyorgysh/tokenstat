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
//! - [`server`] over a local socket (unix) or named pipe (Windows), which is
//!   the same dispatch with a different way in.
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

pub(crate) mod access_audit;
pub mod account_activity;
#[cfg(feature = "local-host")]
pub mod activity;
#[cfg(feature = "local-host")]
pub mod agent_models;
#[cfg(feature = "local-host")]
pub(crate) mod agent_readiness;
#[cfg(feature = "local-host")]
pub mod automations;
pub mod base64;
#[cfg(feature = "local-host")]
pub mod chat;
#[cfg(feature = "local-host")]
pub mod chat_brain;
#[cfg(feature = "local-host")]
pub mod chat_gate;
#[cfg(feature = "local-host")]
pub mod chat_receipts;
#[cfg(feature = "local-host")]
pub mod chat_turn;
pub mod cloud_import;
pub mod dispatch;
pub mod dto;
pub mod error;
/// Descriptor headroom. See the module for why 256 is not enough.
#[cfg(feature = "local-host")]
pub(crate) mod fs_browse;
#[cfg(feature = "local-host")]
pub(crate) mod harness_config;
pub(crate) mod host_policy;
pub(crate) mod host_stats;
pub(crate) mod keep_awake;
#[cfg(feature = "local-host")]
pub(crate) mod launcher;
#[cfg(feature = "local-host")]
pub(crate) mod local_models;
mod machine;
pub mod open_files;
pub mod ownership;
pub(crate) mod presence;
pub mod pricing;
pub(crate) mod provision;
mod proxy_http;
#[cfg(feature = "local-host")]
pub(crate) mod pulls;
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
pub(crate) mod ssh_provision;
pub mod ssh_records;
pub(crate) mod ssh_suggest;
#[cfg(feature = "local-host")]
mod sync_scheduler;
#[cfg(test)]
pub(crate) mod test_identity;
#[cfg(feature = "local-host")]
pub(crate) mod workspace_clone;
pub mod workspace_policy;

#[cfg(feature = "local-host")]
mod todo;
#[cfg(feature = "local-host")]
pub(crate) mod transcript;
pub mod vault;
#[cfg(windows)]
pub(crate) mod win32;
pub mod work_cache;
pub mod work_contracts;
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
///
/// Bumped whenever methods are added, because a front end that finds a method
/// missing has no way to tell "this host is old" from "this call is wrong" and
/// used to print `unknown method: ssh.host.list` at a person. 2 was the SSH
/// library and screen input work. 3 is the password vault: `ssh.vault.password.set`,
/// `ssh.vault.lock`, `ssh.vault.recovery.rotate`, and enrollment gone from the
/// public methods. 4 adds `ssh.session.suggest` and `chat.eventPage`. 5 covers
/// the automation backend and Codex model-list work in the 0.8.3 cycle. 6 adds
/// the `refresh` parameter on `chat.backends` and `automation.backends`, and
/// `app.watching` / `app.stoppedWatching`. 7 is the machine somebody sets up
/// from a phone: `fs.browse` and `fs.mkdir` so a folder can be picked on a
/// machine with no file panel, `host.provisionStatus` so the wizard and the
/// empty states read the same answer, `host.logs` so a headless machine can
/// say why it is unhappy, `workspace.access.invite` / `.redeem` / `.log` for
/// letting a second device in from the console, and `workspace.clone` /
/// `.cloneStatus` so a repository can arrive on a machine that had none.
///
/// That last one is a parameter, not a method, which is the weaker case: an
/// older host deserializes the call, ignores the field it does not
/// know, and answers from its cache. Nothing errors, so nothing on screen can
/// notice. A client offers the Refresh control only above this version, which
/// is the whole reason a parameter still spends a number here.
///
/// The helper outlives the app that installed it, so forgetting this is not a
/// cosmetic miss: a new app talks to the old daemon on the same socket, every
/// new method answers `unknown method`, and the feature is simply absent with
/// nothing on screen to say why. `Bridge.connect` replaces a helper whose
/// number does not match, and that check is the only thing that notices.
/// Version 8 adds the local-only `ssh.provision.identity` handoff. The
/// remote workspace provisioning methods themselves remain available at 7.
/// Version 9 adds agent readiness to `launcher.catalog` and
/// `host.provisionStatus`: `readiness`, `expiresAt` and `checked` beside the
/// `signedIn` that older clients read. An older host omits them, which a
/// client must read as "not checked" rather than as signed out.
/// Version 10 adds `clientMessageId` on `chat.send` and the `chat.receipt`
/// read beside it, so a send whose answer went missing can be repeated
/// without running the agent twice. An older host ignores the field, so a
/// client must not repeat a send against one.
pub const PROTOCOL_VERSION: &str = "10";
