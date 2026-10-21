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

/// Installer work is bounded on desktop; clients must allow that full budget
/// while forwarding the request, since output arrives only after completion.
pub(crate) const INSTALLER_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20 * 60);

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
pub(crate) mod chat_activity;
#[cfg(feature = "local-host")]
pub mod chat_brain;
#[cfg(feature = "local-host")]
mod chat_edit_measure;
#[cfg(feature = "local-host")]
mod chat_fast;
#[cfg(feature = "local-host")]
pub mod chat_gate;
#[cfg(feature = "local-host")]
pub(crate) mod chat_images;
#[cfg(feature = "local-host")]
pub(crate) mod chat_inspection;
#[cfg(feature = "local-host")]
pub mod chat_live;
pub mod chat_question;
#[cfg(feature = "local-host")]
pub mod chat_receipts;
#[cfg(feature = "local-host")]
pub(crate) mod chat_sessions;
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
pub mod host_update;
pub(crate) mod identity_storage;
pub(crate) mod keep_awake;
#[cfg(feature = "local-host")]
pub(crate) mod launcher;
mod limits_refresh;
#[cfg(feature = "local-host")]
mod live_work;
#[cfg(feature = "local-host")]
pub(crate) mod local_models;
mod machine;
pub mod open_files;
#[cfg(feature = "local-host")]
mod opencode_cli;
pub mod ownership;
pub(crate) mod presence;
pub mod pricing;
pub(crate) mod provision;
mod proxy_http;
#[cfg(feature = "local-host")]
pub(crate) mod pulls;
pub mod remote;
/// Browser-side loopback proxy shared by desktop and mobile clients.
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
#[cfg(feature = "local-host")]
pub mod team_process;
#[cfg(feature = "local-host")]
pub mod team_sdk;
#[cfg(test)]
pub(crate) mod test_identity;
#[cfg(all(windows, feature = "local-host"))]
mod windows_screen;
#[cfg(feature = "local-host")]
pub(crate) mod workspace_clone;
pub mod workspace_policy;

pub(crate) mod account_session;
pub(crate) mod lease_clock;
#[cfg(feature = "local-host")]
pub(crate) mod provider_limit;
pub(crate) mod teams;
#[cfg(feature = "local-host")]
mod todo;
#[cfg(feature = "local-host")]
pub(crate) mod transcript;
pub mod vault;
#[cfg(windows)]
pub(crate) mod win32;
pub mod work_cache;
pub mod work_contracts;
pub mod work_handoff;
#[cfg(feature = "local-host")]
pub mod work_handoff_store;
pub mod work_search;
pub mod work_search_conversation;
pub mod work_search_cursor;
#[cfg(feature = "local-host")]
pub mod work_search_engine;
pub mod work_search_text;
pub mod work_transcript_identity;
#[cfg(feature = "local-host")]
pub mod workflows;
#[cfg(feature = "local-host")]
pub(crate) mod workspace_writer;
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
/// Version 13 makes acceptance durable and serialized, reports unresolved
/// launches as `needsRecovery`, and requires `clientMessageCreatedAtMs` for
/// previously unseen message IDs so expired receipts cannot authorize replay.
/// Version 14 adds `sendRevision` to conversations and requires
/// `expectedRevision` for unseen message IDs. Stale context is refused before
/// launch while existing receipts remain available for reconciliation.
/// Version 15 adds immutable selected-file commit reviews, outcome receipts
/// and explicit recovery while preserving unrelated staged entries.
/// Version 16 adds reviewed current-branch Push and durable outcome recovery.
/// Version 17 adds revision-checked task editing.
/// Version 18 adds revision-checked task deletion with active-run protection.
/// Version 19 adds create-once tasks and receipts retained after deletion.
/// Version 20 adds revision-checked task runs, exact-run stops and launch receipts.
/// Version 21 adds revision-checked automation edits and create/run receipts.
/// Version 23 repairs vault identity registration and persists Windows host
/// diagnostics. Desktop clients replace older helpers so these fixes also
/// reach an already-running always-on host.
/// Version 24 adds `workspace.worktrees` and `workspace.createWorktree`.
/// Version 25 adds `chat.steer`, `chat.steerClear` and `chat.steerDeliver`,
/// so a short note can ride the next tool step while a turn is still running.
/// Version 26 adds independent saved-transcript copies with `chat.fork`.
/// Version 28 adds guided agent setup checks and published-branch PR creation.
/// Version 29 adds agent questions in chat, answered with `chat.answerQuestion`.
/// Version 30 adds reviewed fast-forward pulls (`workspace.pullReview` and
/// `workspace.pullReviewed`) and `pulls.branch`, and conversations carry the
/// branch they last worked on with its cached pull request.
/// Version 31 adds Live Activity registration and stable chat turn identity.
/// Version 32 adds host-driven terminal Live Activity updates.
/// Version 33 adds `pulls.commitAvatars`, the public author pictures a
/// history list draws for everyone who has one.
/// Version 34 adds revision-checked chat recovery and cooperative runner stop.
/// Version 35 adds the opt-in work overview across chats and terminals.
/// Version 36 adds Git LFS preflight and explicitly consented repository setup.
/// Version 37 adds explicit agent reinstallation through `launcher.reinstall`.
/// Version 38 adds opt-in organization management.
/// Version 39 adds key-bound Team principals and their closed dispatch boundary.
/// Version 40 adds host-private checkout publication and scoped availability.
/// Version 41 adds the separate local scoped Team connection pool.
/// Version 42 adds reviewed shared-chat publication and private-send fences.
/// Version 43 adds local sharing inspection and recovery without an account.
/// Version 45 binds execution authority to a non-reused host-approved grant.
pub const PROTOCOL_VERSION: &str = "47";
