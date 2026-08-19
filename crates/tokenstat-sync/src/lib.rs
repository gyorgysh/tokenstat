// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Networked vendor fetches and tokenstat.ai profile sync.
//!
//! This is the only crate allowed to link a network stack. `tokenstat-core`
//! reads local logs and must stay offline. Cursor keeps usage on its servers.
//! Antigravity CLI DBs are offline; the IDE needs a local language-server RPC
//! (loopback) plus optional Cloud Code quota over the network.
//!
//! # Privacy
//!
//! Vendor tokens are used only on this machine to pull aggregate usage into the
//! local archive. They are never written into the SQLite store and are not
//! eligible for tokenstat.ai sync. Discovering a token the vendor app already
//! stored locally is convenience, not exfiltration.
//!
//! Profile sync (`login` / `sync`) uploads only the sealed day × source × model
//! rollup. Bearer tokens live in the OS keychain, keyed by host.

#![forbid(unsafe_code)]

pub mod antigravity;
pub mod antigravity_ide;
pub mod catalog;
pub mod claude_limits;
pub mod config;
pub mod creds;
pub mod cursor;
pub mod discover;
pub mod grok_limits;
pub mod host;
pub mod keychain;
pub mod opencode_limits;
mod power;
pub mod pricing;
pub mod profile;
pub mod push;
pub mod schema;
pub mod snapshot;
pub mod update;

use std::time::Duration;

use serde::Serialize;

use tokenstat_core::Store;

/// How long a successful vendor fetch is reused before the next network call.
pub const FETCH_TTL: Duration = Duration::from_secs(30 * 60);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Vendor {
    Cursor,
    Antigravity,
}

impl Vendor {
    pub fn as_str(self) -> &'static str {
        match self {
            Vendor::Cursor => "cursor",
            Vendor::Antigravity => "antigravity",
        }
    }
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FetchReport {
    pub vendor: &'static str,
    pub events: usize,
    pub from_cache: bool,
    pub skipped_no_token: bool,
    pub message: Option<String>,
}

/// Fetch every configured remote vendor into the archive, respecting TTL.
///
/// Each vendor soft-fails independently so one auth/network error cannot skip
/// the others.
pub fn fetch_remotes(
    store: &mut Store,
    tz: &jiff::tz::TimeZone,
    force: bool,
) -> anyhow::Result<Vec<FetchReport>> {
    let mut out = Vec::with_capacity(2);
    match cursor::fetch_into(store, tz, force) {
        Ok(r) => out.push(r),
        Err(e) => out.push(FetchReport {
            vendor: "cursor",
            message: Some(format!("fetch failed: {e}")),
            ..FetchReport::default()
        }),
    }
    match antigravity::fetch_into(store, tz, force) {
        Ok(r) => out.push(r),
        Err(e) => out.push(FetchReport {
            vendor: "antigravity",
            message: Some(format!("fetch failed: {e}")),
            ..FetchReport::default()
        }),
    }
    Ok(out)
}

pub use creds::{AuthStatus, clear_token, has_token, save_token, token_for};
pub use profile::{
    AccountLimitProvider, AccountLimitWindow, DeviceLogin, DeviceStatus, JITTER_WINDOW_SECS,
    LoginResult, ProfileError, ScheduledOutcome, SchedulingInfo, StatusResult, SyncOptions,
    SyncResult, TunnelToken, apple_activate, apple_renewal, cli_sync_schedule_active, device_poll,
    device_start, device_start_kind, fetch_account_limits, jitter_offset, login, login_with_code,
    logout, mint_tunnel_token, post_limits, publish_machine_profile, register_machine_identity,
    register_machine_identity_kind, rename_machine, scheduling_info, sync, sync_scheduled,
    sync_scheduled_now, sync_status,
};
pub use update::{
    ApplyReport, ScheduledUpdate, UPDATE_JITTER_WINDOW_SECS, UpdateCheck, UpdateError,
    UpdateOutcome, apply_update, auto_apply_enabled, check_latest, current_target,
    download_app_image, has_macos_signing_authority, maybe_auto_update, scheduled_update,
    version_cmp,
};

pub use power::scheduled_network_allowed;
