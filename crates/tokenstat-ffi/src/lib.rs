// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! C ABI bridge exposing the tokenstat host to native front ends.
//!
//! # What lives here
//!
//! Only the transport. The protocol, the session, and every method live in
//! `tokenstat-host`, which also serves them over a unix socket. This crate is
//! the in-process door to the same dispatch, so the Mac app can read the
//! archive without a daemon running, and there is no second implementation to
//! keep in step.
//!
//! When the app moves to the socket, the method names and the response
//! envelope do not change, because they were never defined here.
//!
//! # Why JSON rather than a generated binding
//!
//! The host speaks versioned JSON so an iPad can drive a session running on a
//! Mac. Using the same shape across the C boundary makes moving a front end
//! from in-process to remote a change of transport rather than a rewrite of
//! the client layer. It also keeps the dependency budget at zero and needs no
//! codegen step in the build.

pub mod abi;
pub mod api;

/// Version of the wire contract. Re-exported so a C consumer has one place to
/// look, but owned by `tokenstat-host`.
pub const PROTOCOL_VERSION: &str = tokenstat_host::PROTOCOL_VERSION;
